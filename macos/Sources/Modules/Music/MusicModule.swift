import AppKit
import IsolaCore
import SwiftUI

struct MusicSettings: Codable, Equatable {
    var lyricsEnabled = false
    var peekOnChange = true
    var spotifyClientId = ""

    init() {}

    /// Tollerante: chiavi mancanti o di tipo sbagliato prendono il valore predefinito.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        lyricsEnabled = (try? c.decode(Bool.self, forKey: .lyricsEnabled)) ?? false
        peekOnChange = (try? c.decode(Bool.self, forKey: .peekOnChange)) ?? true
        spotifyClientId = (try? c.decode(String.self, forKey: .spotifyClientId)) ?? ""
    }
}

/// Musica: cosa suona in qualsiasi app (mediaremote-adapter, con AppleScript come ripiego),
/// comandi, testi sincronizzati (LRCLIB, se accesi) e Spotify (se collegato).
public final class MusicModule: IslandModule, RestingFaceProvider, PeekProvider {
    public init() {}
    public var id: String { "music" }
    public var title: String { "Musica" }
    public var symbol: String { "music.note" }
    public var order: Int { 10 }
    public var enabledByDefault: Bool { true }

    /// In pausa da più di così: la pillola torna alle altre facce.
    private static let pauseGrace: TimeInterval = 30

    private let model = MusicModel()
    private let spotifyModel = SpotifyModel()
    private let logBox = LogBox()
    private lazy var spotify = SpotifyController(model: spotifyModel, log: logBox.log) { [weak self] id in
        self?.setClientId(id)
    }

    private weak var host: IslandHost?
    private var running = false
    private var settings = MusicSettings()
    private var adapter: AdapterSource?
    private var fallback: AppleScriptSource?
    private var lyricsService: LyricsService?
    private var lyricsTask: Task<Void, Never>?
    private var lyricsKey = ""

    private var currentKey: String?
    private var gotFirst = false
    private var pendingPeek: (key: String, until: Date)?
    private var reportedPlaying = false
    private var pausedLong = true
    private var pauseExpiry: DispatchWorkItem?
    private var lastPriority = 0
    private var artworkToken = -1
    private var iconBundle: String?
    private var launcher: MusicLauncher?

    // MARK: - Ciclo di vita

    public func start(host: IslandHost) throws {
        guard !running else { return }
        running = true
        self.host = host
        logBox.host = host
        settings = host.loadSettings(MusicSettings.self, fallback: MusicSettings())
        model.lyricsEnabled = settings.lyricsEnabled
        model.peekOnChange = settings.peekOnChange
        model.clientId = settings.spotifyClientId
        model.cardVisible = host.isCardVisible
        wireActions()
        lyricsService = LyricsService(dir: host.dataDirectory.appendingPathComponent("lyrics", isDirectory: true),
                                      log: logBox.log)
        host.onCardVisibilityChange { [weak self] visible in self?.model.cardVisible = visible }
        spotify.start(loadStored: SpotifyPKCE.isValidClientId(settings.spotifyClientId))

        if let paths = AdapterSource.locate() {
            startAdapter(paths)
        } else {
            host.log("Musica: adattatore non trovato, uso AppleScript")
            startFallback()
        }
    }

    public func stop() {
        guard running else { return }
        running = false
        launcher?.cancel()
        launcher = nil
        model.launching = nil
        model.launchMessage = ""
        adapter?.stop()
        adapter = nil
        fallback?.stop()
        fallback = nil
        spotify.stop()
        lyricsTask?.cancel()
        lyricsTask = nil
        lyricsKey = ""
        lyricsService = nil
        pauseExpiry?.cancel()
        pauseExpiry = nil
        pendingPeek = nil
        currentKey = nil
        gotFirst = false
        reportedPlaying = false
        pausedLong = true
        lastPriority = 0
        artworkToken = -1
        iconBundle = nil
        model.clear()
        model.source = .none
        model.needsConsent = false
        model.cardVisible = false
        host = nil
        logBox.host = nil
    }

    public func makeCard() -> AnyView? {
        AnyView(MusicCard(model: model, spotify: spotifyModel, controller: spotify))
    }

    public func makeSettings() -> AnyView? {
        AnyView(MusicSettingsView(model: model, spotify: spotifyModel, controller: running ? spotify : nil))
    }

    // MARK: - Pillola e avviso

    public var restingPriority: Int {
        guard running, model.hasSession else { return 0 }
        return reportedPlaying || !pausedLong ? 50 : 0
    }

    public func makeRestingFace() -> RestingFace {
        // Copertina ed equalizzatore sono piccoli: ali strette, l'isola resta poco più larga della notch.
        RestingFace(sideWidth: 34, leading: MusicFaceLeading(model: model), trailing: MusicFaceTrailing(model: model))
    }

    public func makePeek() -> AnyView {
        AnyView(MusicPeek(model: model))
    }

    private func refreshPriority() {
        let p = restingPriority
        guard p != lastPriority else { return }
        lastPriority = p
        host?.refreshRestingFace()
    }

    // MARK: - Sorgenti

    private func startAdapter(_ paths: AdapterSource.Paths) {
        model.source = .adapter
        let a = AdapterSource(paths: paths, log: { [weak self] in self?.host?.log($0) },
                              onUpdate: { [weak self] in self?.apply($0) },
                              onGiveUp: { [weak self] in self?.adapterGaveUp() })
        adapter = a
        a.start()
    }

    private func adapterGaveUp() {
        guard running else { return }
        adapter = nil
        apply(nil)
        resetSourceState()
        startFallback()
    }

    private func startFallback() {
        model.source = .fallback
        let f = AppleScriptSource(log: { [weak self] in self?.host?.log($0) },
                                  onUpdate: { [weak self] in self?.apply($0) },
                                  onConsentChange: { [weak self] in self?.model.needsConsent = $0 })
        fallback = f
        f.start()
    }

    private func resetSourceState() {
        gotFirst = false
        currentKey = nil
        pendingPeek = nil
        artworkToken = -1
    }

    private func wireActions() {
        model.onCommand = { [weak self] cmd in self?.send(cmd) }
        model.onSeek = { [weak self] s in self?.seek(to: s) }
        model.onRequestConsent = { [weak self] in self?.fallback?.requestConsent() }
        model.onKeyboardFocus = { [weak self] in self?.host?.requestKeyboardFocus() }
        model.onLyricsToggle = { [weak self] on in
            guard let self else { return }
            self.settings.lyricsEnabled = on
            self.model.lyricsEnabled = on
            self.save()
            self.updateLyrics()
        }
        model.onPeekToggle = { [weak self] on in
            guard let self else { return }
            self.settings.peekOnChange = on
            self.model.peekOnChange = on
            self.save()
        }
        model.onClientIdChange = { [weak self] id in self?.setClientId(id) }
        model.onLaunch = { [weak self] p in self?.launch(p) }
        model.onPlayShortcut = { [weak self] s in self?.launch(MusicLauncher.spotify, uri: s.uri, key: s.id) }
    }

    /// `key`: cosa mostra la rotellina (l'app o la playlist premuta).
    private func launch(_ player: MusicLauncher.Player, uri: String? = nil, key: String? = nil) {
        guard running else { return }
        let l = launcher ?? MusicLauncher(log: { [weak self] in self?.host?.log($0) })
        launcher = l
        model.launchMessage = ""
        model.launching = key ?? player.id
        l.play(player, uri: uri) { [weak self] message in
            guard let self, self.running else { return }
            self.model.launching = nil
            self.model.launchMessage = message ?? ""
        }
    }

    private func setClientId(_ raw: String) {
        model.clientId = raw
        let id = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard id != settings.spotifyClientId else { return }
        settings.spotifyClientId = id
        save()
    }

    private func save() {
        guard running else { return }
        host?.saveSettings(settings)
    }

    // MARK: - Comandi

    private func send(_ cmd: MediaCommand) {
        guard running, model.hasSession else { return }
        if cmd == .togglePlayPause {
            // Subito nella scheda; il prossimo aggiornamento della sorgente conferma o corregge.
            let now = Date()
            model.basePos = model.position(at: now)
            model.baseAt = now
            model.isPlaying.toggle()
        }
        if let adapter { adapter.send(cmd) } else { fallback?.send(cmd) }
    }

    private func seek(to seconds: Double) {
        guard running, model.canSeek else { return }
        let s = max(0, min(seconds, model.duration ?? seconds))
        model.basePos = s
        model.baseAt = Date()
        if let adapter { adapter.seek(to: s) } else { fallback?.seek(to: s) }
    }

    // MARK: - Aggiornamenti

    private func apply(_ info: NowPlayingInfo?) {
        guard running else { return }
        guard let info else {
            if model.hasSession { model.clear() }
            currentKey = nil
            artworkToken = -1
            iconBundle = nil
            pendingPeek = nil
            gotFirst = true
            setPlaying(false, hadSession: false)
            spotify.setSource(nil)
            updateLyrics()
            return
        }

        let hadSession = model.hasSession
        let key = info.trackKey
        let changed = key != currentKey
        currentKey = key

        if !model.hasSession { model.hasSession = true }
        if model.title != info.title { model.title = info.title }
        if model.artist != info.artist { model.artist = info.artist }
        if model.album != info.album { model.album = info.album }
        if model.bundleId != info.bundleId { model.bundleId = info.bundleId }
        if iconBundle != info.bundleId {
            iconBundle = info.bundleId
            model.sourceIcon = info.bundleId.flatMap { id in
                NSWorkspace.shared.urlForApplication(withBundleIdentifier: id).map {
                    NSWorkspace.shared.icon(forFile: $0.path)
                }
            }
        }
        if changed || info.artworkToken != artworkToken {
            artworkToken = info.artworkToken
            model.artwork = info.artwork
            model.accent = info.artworkAccent.map { Color(nsColor: $0) }
        }

        let now = Date()
        if let e = info.elapsed {
            model.basePos = e
            model.baseAt = info.timestamp ?? now
        } else if changed {
            model.basePos = 0
            model.baseAt = now
        }
        model.rate = info.rate
        if model.isPlaying != info.playing { model.isPlaying = info.playing }
        let duration = (info.duration ?? 0) > 0 ? info.duration : nil
        if model.duration != duration { model.duration = duration }
        let canSeek = info.canSeek && duration != nil
        if model.canSeek != canSeek { model.canSeek = canSeek }
        if changed, model.lyrics != nil { model.lyrics = nil }

        // Avviso al cambio brano: non al primo caricamento; aspetta (poco) che il brano suoni.
        if changed, gotFirst { pendingPeek = (key, now.addingTimeInterval(5)) }
        gotFirst = true
        if let p = pendingPeek, p.key == key, info.playing {
            pendingPeek = nil
            if p.until > now, settings.peekOnChange, let host, !host.isCardVisible, !host.isFullscreenAppActive {
                host.attention(duration: 3)
            }
        }

        setPlaying(info.playing, hadSession: hadSession)
        spotify.setSource(info.bundleId)
        spotify.onTrack(title: info.title, artist: info.artist)
        updateLyrics()
    }

    /// Priorità 50 mentre suona e per 30 s di pausa, poi 0. Una sessione già in pausa quando la
    /// scopriamo non occupa la pillola.
    private func setPlaying(_ playing: Bool, hadSession: Bool) {
        if playing {
            pauseExpiry?.cancel()
            pauseExpiry = nil
            pausedLong = false
        } else if reportedPlaying {
            pausedLong = false
            pauseExpiry?.cancel()
            let item = DispatchWorkItem { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, self.running else { return }
                    self.pauseExpiry = nil
                    self.pausedLong = true
                    self.refreshPriority()
                }
            }
            pauseExpiry = item
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.pauseGrace, execute: item)
        } else if pauseExpiry == nil || !hadSession {
            pauseExpiry?.cancel()
            pauseExpiry = nil
            pausedLong = true
        }
        reportedPlaying = playing
        refreshPriority()
    }

    // MARK: - Testi

    private func updateLyrics() {
        guard settings.lyricsEnabled, model.hasSession, let service = lyricsService,
              let duration = model.duration, let key = currentKey else {
            if lyricsTask != nil || !lyricsKey.isEmpty {
                lyricsTask?.cancel()
                lyricsTask = nil
                lyricsKey = ""
            }
            if !settings.lyricsEnabled || !model.hasSession, model.lyrics != nil { model.lyrics = nil }
            return
        }
        let seconds = Int(duration.rounded())
        let k = key + "\n\(seconds)"
        guard k != lyricsKey else { return }
        lyricsKey = k
        lyricsTask?.cancel()
        if model.lyrics != nil { model.lyrics = nil }
        let artist = model.artist, title = model.title, album = model.album
        lyricsTask = Task { [weak self] in
            let lines = await service.lines(artist: artist, title: title, album: album, duration: seconds)
            guard !Task.isCancelled, let self, self.running, self.lyricsKey == k else { return }
            self.model.lyrics = lines
            self.lyricsTask = nil
        }
    }
}

/// Il log del modulo, usabile da qualsiasi thread (rete, Portachiavi). Mai nomi di brani.
private final class LogBox: @unchecked Sendable {
    @MainActor weak var host: IslandHost?

    var log: @Sendable (String) -> Void {
        { [weak self] message in
            onMain { self?.host?.log(message) }
        }
    }
}
