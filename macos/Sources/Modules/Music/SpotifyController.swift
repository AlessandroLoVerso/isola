import AppKit
import SwiftUI

@MainActor
/// Una cosa da far partire dalla scheda vuota: "Brani che ti piacciono" o una playlist.
struct SpotifyShortcut: Identifiable, Equatable {
    let id: String
    let name: String
    let detail: String
    let uri: String
    let imageURL: URL?
    let liked: Bool
}

final class SpotifyModel: ObservableObject {
    enum Link { case disconnected, connecting, connected }
    enum Segment: CaseIterable { case playlist, queue, search
        var title: String {
            switch self {
            case .playlist: "Playlist"
            case .queue: "Coda"
            case .search: "Cerca"
            }
        }
    }

    nonisolated static let premiumTip = "Serve Spotify Premium"

    @Published var link = Link.disconnected
    @Published var linkMessage = ""
    @Published var displayName: String?
    /// Spotify collegato e la musica arriva da Spotify: cuore e "…" nella scheda.
    @Published var isActive = false
    @Published var isLiked = false
    @Published var canLike = false
    @Published var panelOpen = false
    @Published var segment = Segment.playlist
    @Published var playlists: [SpotifyPlaylist] = []
    @Published var playlistStatus = ""
    @Published var playlistFilter = ""
    @Published var queue: [SpotifyQueueEntry] = []
    @Published var queueStatus = ""
    @Published var searchText = ""
    @Published var results: [SpotifyTrack] = []
    @Published var searchStatus = ""
    @Published var message = ""
    @Published var playBlocked = false
    @Published var queueBlocked = false
    @Published var trackTitle = ""
    /// Scheda vuota: preferiti e playlist da far partire.
    @Published var shortcuts: [SpotifyShortcut] = []
    @Published var shortcutsLoading = false

    func resetTrack() {
        isLiked = false
        canLike = false
    }

    func resetAll() {
        link = .disconnected
        linkMessage = ""
        displayName = nil
        isActive = false
        resetTrack()
        panelOpen = false
        playlists = []
        playlistStatus = ""
        queue = []
        queueStatus = ""
        results = []
        searchStatus = ""
        message = ""
        playBlocked = false
        queueBlocked = false
        trackTitle = ""
        shortcuts = []
        shortcutsLoading = false
    }
}

/// Le funzioni Spotify sopra al Now Playing. Vive da `start` a `stop` del modulo. Niente polling:
/// l'API viene chiamata solo quando cambia brano di Spotify o quando l'utente usa il pannello.
@MainActor
final class SpotifyController {
    static let bundleId = "com.spotify.client"
    private static let playlistCacheAge: TimeInterval = 600

    let model: SpotifyModel
    private let api: SpotifyAPI
    private let log: (String) -> Void
    private let saveClientId: (String) -> Void
    private var alive = false

    private var connected = false
    private var sourceIsSpotify = false
    private var npTitle = "", npArtist = ""
    private var trackKey = ""
    private var trackVersion = 0
    private var track: SpotifyTrack?
    private var likeBusy = false, adding = false
    private var me: SpotifyMe?
    private var fetchingMe = false
    private var allPlaylists: [SpotifyPlaylist]?
    private var playlistsAt = Date.distantPast
    private var playlistsLoading = false
    private var shortcutsAt = Date.distantPast
    private var queueVersion = 0, searchVersion = 0
    private var lastQuery = ""
    private var login: Task<Void, Never>?
    private var messageReset: DispatchWorkItem?
    private var searchDebounce: DispatchWorkItem?
    private var tasks: [Task<Void, Never>] = []
    private var fetchTask: Task<Void, Never>?

    init(model: SpotifyModel, log: @escaping @Sendable (String) -> Void, saveClientId: @escaping (String) -> Void) {
        self.model = model
        self.log = log
        self.saveClientId = saveClientId
        let box = RevokeBox()
        api = SpotifyAPI(log: log, onRevoked: { box.fire() })
        box.handler = { [weak self] in
            onMain {
                guard let self, self.alive else { return }
                self.connected = false
                self.me = nil
                self.allPlaylists = nil
                self.clearShortcuts()
                self.setLink(.disconnected, "Spotify ha revocato l'accesso: collegalo di nuovo.")
                self.updateActive()
            }
        }
    }

    /// `loadStored`: leggere il Portachiavi (solo se un Client ID è già stato salvato).
    func start(loadStored: Bool) {
        alive = true
        model.resetAll()
        guard loadStored else { return }
        // Portachiavi fuori dal main thread. Niente rete qui.
        run({ [api] in await api.loadStored() }) { [weak self] loaded in
            guard let self, loaded else { return }
            self.connected = true
            self.setLink(.connected, "")
            self.updateActive()
        }
    }

    func stop() {
        alive = false
        login?.cancel()
        login = nil
        tasks.forEach { $0.cancel() }
        tasks = []
        fetchTask = nil
        messageReset?.cancel()
        messageReset = nil
        searchDebounce?.cancel()
        searchDebounce = nil
        connected = false
        sourceIsSpotify = false
        npTitle = ""; npArtist = ""; trackKey = ""
        trackVersion += 1
        track = nil
        likeBusy = false; adding = false
        me = nil
        fetchingMe = false
        allPlaylists = nil
        playlistsLoading = false
        shortcutsAt = .distantPast
        lastQuery = ""
        Task { [api] in await api.forget() }
        model.resetAll()
    }

    // MARK: - Dal Now Playing

    func setSource(_ bundleId: String?) {
        let spotify = bundleId == Self.bundleId
        guard spotify != sourceIsSpotify else { return }
        sourceIsSpotify = spotify
        trackKey = ""
        if !spotify { npTitle = ""; npArtist = ""; model.trackTitle = "" }
        updateActive()
    }

    /// Titolo e artista del brano di Spotify; deduplicati (arrivano più aggiornamenti per brano).
    func onTrack(title: String, artist: String) {
        guard sourceIsSpotify else { return }
        npTitle = title
        npArtist = artist
        model.trackTitle = title
        let key = title + "\n" + artist
        guard key != trackKey else { return }
        trackKey = key
        track = nil
        model.resetTrack()
        trackVersion += 1
        fetchTask?.cancel()
        if model.isActive, !title.isEmpty { fetchTrack(trackVersion, title: title) }
    }

    private func updateActive() {
        let active = sourceIsSpotify && connected
        guard active != model.isActive else { return }
        model.isActive = active
        if !active {
            model.panelOpen = false
            track = nil
            trackVersion += 1
            model.resetTrack()
        } else {
            trackKey = ""
            onTrack(title: npTitle, artist: npArtist)
        }
    }

    private func fetchTrack(_ v: Int, title: String) {
        fetchTask?.cancel()
        fetchTask = run({ [api] () async -> (SpotifyTrack?, Bool?) in
            // L'API può restare un attimo indietro rispetto al Now Playing: riprova un paio di volte.
            for attempt in 0..<3 {
                if attempt > 0 { try? await Task.sleep(nanoseconds: 1_500_000_000) }
                if Task.isCancelled { return (nil, nil) }
                let (t, err) = await api.currentlyPlaying()
                if err != .none { break }
                if let t, Self.sameTitle(t.name, title) {
                    return (t, t.id != nil ? await api.isSaved(t) : nil)
                }
            }
            return (nil, nil)
        }) { [weak self] r in
            guard let self, v == self.trackVersion else { return }
            self.track = r.0
            self.model.canLike = r.0?.id != nil && r.1 != nil
            self.model.isLiked = r.1 == true
            if self.model.panelOpen, self.model.segment == .queue { self.loadQueue() }
        }
    }

    nonisolated static func sameTitle(_ a: String, _ b: String) -> Bool {
        let x = a.trimmingCharacters(in: .whitespaces).lowercased(), y = b.trimmingCharacters(in: .whitespaces).lowercased()
        guard !x.isEmpty, !y.isEmpty else { return false }
        return x == y || x.hasPrefix(y) || y.hasPrefix(x)
    }

    // MARK: - Cuore

    func toggleLike() {
        guard let t = track, model.canLike, !likeBusy else { return }
        let target = !model.isLiked
        model.isLiked = target // ottimista
        likeBusy = true
        let v = trackVersion
        run({ [api] in await api.setSaved(t, target) }) { [weak self] err in
            guard let self else { return }
            self.likeBusy = false
            guard err != .none else { return }
            if v == self.trackVersion { self.model.isLiked = !target }
            self.showMessage(Self.errorText(err, "Non riuscito"))
        }
    }

    // MARK: - Pannello

    func openPanel() {
        guard model.isActive else { return }
        model.panelOpen = true
        if track == nil, !npTitle.isEmpty { trackKey = ""; onTrack(title: npTitle, artist: npArtist) }
        loadSegment()
    }

    func closePanel() { model.panelOpen = false }

    func select(_ s: SpotifyModel.Segment) {
        model.segment = s
        if model.panelOpen { loadSegment() }
    }

    private func loadSegment() {
        switch model.segment {
        case .playlist: loadPlaylists()
        case .queue: loadQueue()
        case .search: break
        }
    }

    // MARK: - Playlist

    private func loadPlaylists() {
        if allPlaylists != nil, Date().timeIntervalSince(playlistsAt) < Self.playlistCacheAge { applyFilter(); return }
        guard !playlistsLoading else { return }
        playlistsLoading = true
        if allPlaylists == nil { model.playlistStatus = "Carico le playlist…" }
        let known = me
        run({ [api] () async -> (SpotifyMe?, [SpotifyPlaylist]?, SpotifyError) in
            var m = known
            if m == nil {
                let (got, err) = await api.me()
                guard let got else { return (nil, nil, err == .none ? .failed : err) }
                m = got
            }
            let (list, e2) = await api.editablePlaylists(meId: m!.id)
            return (m, list, e2)
        }) { [weak self] r in
            guard let self else { return }
            self.playlistsLoading = false
            if let m = r.0, self.me == nil { self.me = m; self.model.displayName = m.displayName }
            if let list = r.1 {
                self.allPlaylists = list.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
                self.playlistsAt = Date()
                self.applyFilter()
            } else if self.allPlaylists == nil {
                self.model.playlistStatus = Self.errorText(r.2, "Playlist non disponibili")
            }
        }
    }

    // MARK: - Scheda vuota

    /// Preferiti e playlist per la scheda vuota. Una chiamata ogni 10 minuti al massimo.
    func loadShortcuts() {
        guard connected, !model.shortcutsLoading else { return }
        if !model.shortcuts.isEmpty, Date().timeIntervalSince(shortcutsAt) < Self.playlistCacheAge { return }
        model.shortcutsLoading = true
        let known = me
        run({ [api] () async -> (SpotifyMe?, [SpotifyPlaylist]?) in
            var m = known
            if m == nil { m = await api.me().0 }
            guard m != nil else { return (nil, nil) }
            return (m, await api.libraryPlaylists().0)
        }) { [weak self] r in
            guard let self else { return }
            self.model.shortcutsLoading = false
            if let m = r.0, self.me == nil { self.me = m; self.model.displayName = m.displayName }
            guard let m = r.0, let list = r.1 else { return }
            self.shortcutsAt = Date()
            var out = [SpotifyShortcut(id: "liked", name: "Brani che ti piacciono", detail: "Preferiti",
                                       uri: Self.likedURI(m.id), imageURL: nil, liked: true)]
            for p in list where Self.isSafeURI(p.uri) {
                out.append(SpotifyShortcut(id: p.id, name: p.name.isEmpty ? "Playlist" : p.name,
                                           detail: p.count == 1 ? "1 brano" : "\(p.count) brani",
                                           uri: p.uri, imageURL: p.imageURL, liked: false))
            }
            self.model.shortcuts = out
        }
    }

    private func clearShortcuts() {
        shortcutsAt = .distantPast
        model.shortcuts = []
    }

    /// Finisce dentro un AppleScript: solo caratteri di un URI Spotify.
    nonisolated static func isSafeURI(_ s: String) -> Bool {
        s.hasPrefix("spotify:") && s.count < 200
            && s.unicodeScalars.allSatisfy { $0.isASCII && CharacterSet.alphanumerics.contains($0) || ":._-".unicodeScalars.contains($0) }
    }

    nonisolated static func likedURI(_ userId: String) -> String {
        let u = "spotify:user:\(userId):collection"
        return isSafeURI(u) ? u : "spotify:collection:tracks"
    }

    func applyFilter() {
        guard let all = allPlaylists else { return }
        let f = model.playlistFilter.trimmingCharacters(in: .whitespaces)
        model.playlists = f.isEmpty ? all : all.filter {
            $0.name.range(of: f, options: [.caseInsensitive, .diacriticInsensitive]) != nil
        }
        model.playlistStatus = !model.playlists.isEmpty ? ""
            : all.isEmpty ? "Nessuna playlist tua o collaborativa" : "Nessuna playlist trovata"
    }

    func addToPlaylist(_ p: SpotifyPlaylist) {
        guard let t = track else { showMessage("Brano non riconosciuto su Spotify"); return }
        guard !adding else { return }
        adding = true
        let name = p.name.isEmpty ? "playlist" : p.name
        run({ [api] in await api.addToPlaylist(p.id, uri: t.uri) }) { [weak self] err in
            guard let self else { return }
            self.adding = false
            self.showMessage(err == .none ? "Aggiunta a \(name)" : Self.errorText(err, "Non riuscito"))
        }
    }

    // MARK: - Coda

    private func loadQueue() {
        queueVersion += 1
        let v = queueVersion
        if model.queue.isEmpty { model.queueStatus = "Carico la coda…" }
        run({ [api] in await api.queue() }) { [weak self] r in
            guard let self, v == self.queueVersion else { return }
            guard let list = r.0 else {
                if self.model.queue.isEmpty { self.model.queueStatus = Self.errorText(r.1, "Coda non disponibile") }
                return
            }
            self.model.queue = list
            self.model.queueStatus = list.isEmpty ? "La coda è vuota" : ""
        }
    }

    // MARK: - Cerca

    /// Mentre si scrive: aspetta 400 ms di pausa.
    func searchTextChanged() {
        searchDebounce?.cancel()
        let item = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.search() }
        }
        searchDebounce = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: item)
    }

    func search() {
        searchDebounce?.cancel()
        let q = model.searchText.trimmingCharacters(in: .whitespaces)
        if q.isEmpty {
            lastQuery = ""
            searchVersion += 1
            model.results = []
            model.searchStatus = ""
            return
        }
        guard q != lastQuery else { return }
        lastQuery = q
        searchVersion += 1
        let v = searchVersion
        if model.results.isEmpty { model.searchStatus = "Cerco…" }
        run({ [api] in await api.search(q) }) { [weak self] r in
            guard let self, v == self.searchVersion else { return }
            guard let list = r.0 else {
                self.lastQuery = "" // si può riprovare lo stesso testo
                self.model.results = []
                self.model.searchStatus = Self.errorText(r.1, "Ricerca non riuscita")
                return
            }
            self.model.results = list
            self.model.searchStatus = list.isEmpty ? "Nessun risultato" : ""
        }
    }

    func play(_ t: SpotifyTrack) {
        if model.playBlocked { showMessage(SpotifyModel.premiumTip); return }
        run({ [api] in await api.play(t.uri) }) { [weak self] err in
            guard let self else { return }
            if err == .premiumRequired { self.model.playBlocked = true }
            self.showMessage(err == .none ? "In riproduzione" : Self.errorText(err, "Non riuscito", player: true))
        }
    }

    func enqueue(_ t: SpotifyTrack) {
        if model.queueBlocked { showMessage(SpotifyModel.premiumTip); return }
        run({ [api] in await api.enqueue(t.uri) }) { [weak self] err in
            guard let self else { return }
            if err == .premiumRequired { self.model.queueBlocked = true }
            self.showMessage(err == .none ? "Aggiunto alla coda" : Self.errorText(err, "Non riuscito", player: true))
        }
    }

    // MARK: - Collegamento (impostazioni)

    func connect(clientId raw: String) {
        let clientId = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard model.link == .disconnected else { return }
        guard SpotifyPKCE.isValidClientId(clientId) else {
            setLink(.disconnected, "Il Client ID è lungo 32 caratteri (cifre e lettere a-f).")
            return
        }
        saveClientId(clientId)
        setLink(.connecting, "")
        let api = self.api
        login = Task { [weak self] in
            let outcome = await SpotifyLogin.run(clientId: clientId) { url in
                NSWorkspace.shared.open(url)
            }
            var ok = false
            var me: SpotifyMe?
            if case .code(let code, let verifier) = outcome {
                ok = await api.exchangeCode(clientId: clientId, code: code, verifier: verifier)
                if ok { me = await api.me().0 }
            }
            guard let self, self.alive else { return }
            self.login = nil
            if ok {
                self.connected = true
                self.me = me
                self.model.displayName = me?.displayName
                self.allPlaylists = nil
                self.clearShortcuts()
                self.model.playBlocked = false
                self.model.queueBlocked = false
                self.log("Spotify: collegato")
                self.setLink(.connected, "")
                self.updateActive()
                return
            }
            let text: String
            switch outcome {
            case .code: text = "Spotify non ha accettato l'accesso. Controlla Client ID e Redirect URI."
            case .denied: text = "Accesso annullato su Spotify."
            case .portBusy: text = "La porta 47322 è occupata da un altro programma."
            case .timeout: text = "Tempo scaduto (5 minuti). Riprova."
            case .cancelled: text = ""
            case .failed: text = "Non riesco ad aprire il browser."
            }
            self.setLink(.disconnected, text)
        }
    }

    func cancelConnect() { login?.cancel() }

    func disconnect() {
        login?.cancel()
        connected = false
        me = nil
        allPlaylists = nil
        clearShortcuts()
        track = nil
        model.displayName = nil
        model.playBlocked = false
        model.queueBlocked = false
        run({ [api] in await api.disconnect() }) { _ in }
        log("Spotify: scollegato")
        setLink(.disconnected, "")
        updateActive()
    }

    /// Solo per "Collegato come …" (in memoria, mai salvato).
    func ensureDisplayName() {
        guard connected, me == nil, !fetchingMe else { return }
        fetchingMe = true
        run({ [api] in await api.me() }) { [weak self] r in
            guard let self else { return }
            self.fetchingMe = false
            if let m = r.0 { self.me = m; self.model.displayName = m.displayName }
        }
    }

    private func setLink(_ l: SpotifyModel.Link, _ message: String) {
        model.link = l
        model.linkMessage = message
    }

    // MARK: - Aiuti

    private func showMessage(_ text: String) {
        messageReset?.cancel()
        model.message = text
        guard !text.isEmpty else { return }
        let item = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.model.message = "" }
        }
        messageReset = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.6, execute: item)
    }

    nonisolated static func errorText(_ err: SpotifyError, _ fallback: String, player: Bool = false) -> String {
        switch err {
        case .premiumRequired: return SpotifyModel.premiumTip
        case .rateLimited: return "Spotify è occupato, riprova tra poco"
        case .network: return "Spotify non risponde"
        case .notConnected: return "Spotify non è collegato"
        case .forbidden: return "Spotify non lo permette"
        case .notFound where player: return "Nessun dispositivo Spotify attivo"
        default: return fallback
        }
    }

    /// Lavoro asincrono (rete, Portachiavi) e risultato sul main actor, scartato se il modulo si è spento.
    @discardableResult
    private func run<T: Sendable>(_ work: @escaping @Sendable () async -> T, done: @escaping @MainActor (T) -> Void) -> Task<Void, Never> {
        let t = Task { [weak self] in
            let r = await work()
            guard let self, self.alive, !Task.isCancelled else { return }
            done(r)
        }
        tasks.removeAll { $0.isCancelled }
        tasks.append(t)
        if tasks.count > 32 { tasks.removeFirst(tasks.count - 32) }
        return t
    }
}

/// Il callback di revoca nasce prima del controller che lo gestisce.
private final class RevokeBox: @unchecked Sendable {
    var handler: (() -> Void)?
    func fire() { handler?() }
}
