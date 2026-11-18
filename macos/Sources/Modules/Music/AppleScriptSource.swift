import AppKit
import CoreServices

/// Ripiego quando mediaremote-adapter manca o non funziona: Spotify e Musica via AppleScript.
/// Interroga ogni 2 s **solo mentre una delle due app è aperta** (avvisi di NSWorkspace) e non
/// la avvia mai: gli script partono solo per app già in esecuzione.
@MainActor
final class AppleScriptSource {
    enum Consent { case unknown, granted, needed, denied }

    struct Player {
        let bundleId: String
        let name: String
    }

    static let players = [
        Player(bundleId: "com.spotify.client", name: "Spotify"),
        Player(bundleId: "com.apple.Music", name: "Musica"),
    ]

    private let onUpdate: (NowPlayingInfo?) -> Void
    private let onConsentChange: (Bool) -> Void
    private let log: (String) -> Void
    private let worker: AppleScriptWorker
    private var observers: [NSObjectProtocol] = []
    private var timer: Timer?
    private var consent: [String: Consent] = [:]
    private var running = false
    private var generation = 0
    private var polling = false

    init(log: @escaping (String) -> Void, onUpdate: @escaping (NowPlayingInfo?) -> Void,
         onConsentChange: @escaping (Bool) -> Void) {
        self.log = log
        self.onUpdate = onUpdate
        self.onConsentChange = onConsentChange
        self.worker = AppleScriptWorker()
    }

    /// `true` se un'app aperta aspetta il permesso di Automazione (la scheda mostra un pulsante).
    var needsConsent: Bool {
        runningPlayers().contains { consent[$0.bundleId] == .needed }
    }

    func start() {
        guard !running else { return }
        running = true
        generation += 1
        let nc = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            observers.append(nc.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                let id = (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.bundleIdentifier
                MainActor.assumeIsolated {
                    guard let self, let id, Self.players.contains(where: { $0.bundleId == id }) else { return }
                    if note.name == NSWorkspace.didTerminateApplicationNotification { self.consent[id] = nil }
                    self.refreshConsent()
                }
            })
        }
        refreshConsent()
    }

    func stop() {
        running = false
        generation += 1
        let nc = NSWorkspace.shared.notificationCenter
        observers.forEach { nc.removeObserver($0) }
        observers = []
        timer?.invalidate()
        timer = nil
        consent = [:]
        polling = false
    }

    /// Chiede il permesso di Automazione (macOS mostra il suo avviso). Solo dal pulsante della scheda
    /// o delle impostazioni: mai a sorpresa.
    func requestConsent() {
        let ids = runningPlayers().map(\.bundleId)
        let gen = generation
        worker.queue.async { [worker] in
            var result: [String: Consent] = [:]
            for id in ids { result[id] = worker.consent(for: id, ask: true) }
            onMain { [weak self] in
                guard let self, self.generation == gen else { return }
                for (k, v) in result { self.consent[k] = v }
                self.consentChanged()
            }
        }
    }

    // MARK: - Comandi

    func send(_ command: MediaCommand) {
        guard let p = activePlayer() else { return }
        let verb: String
        switch command {
        case .togglePlayPause: verb = "playpause"
        case .next: verb = "next track"
        case .previous: verb = "previous track"
        }
        runCommand("tell application id \"\(p.bundleId)\" to \(verb)")
    }

    func seek(to seconds: Double) {
        guard let p = activePlayer() else { return }
        let s = String(format: "%.2f", locale: Locale(identifier: "en_US_POSIX"), max(0, seconds))
        runCommand("tell application id \"\(p.bundleId)\" to set player position to \(s)")
    }

    private var lastPlayer: String?

    private func activePlayer() -> Player? {
        let open = runningPlayers().filter { consent[$0.bundleId] == .granted }
        return open.first { $0.bundleId == lastPlayer } ?? open.first
    }

    private func runCommand(_ source: String) {
        let gen = generation
        worker.queue.async { [worker] in
            worker.run(source)
            // Lo stato nuovo subito, senza aspettare il prossimo giro.
            onMain { [weak self] in
                guard let self, self.generation == gen else { return }
                self.poll()
            }
        }
    }

    // MARK: - Polling solo con un'app aperta

    private func runningPlayers() -> [Player] {
        let apps = NSWorkspace.shared.runningApplications
        return Self.players.filter { p in apps.contains { $0.bundleIdentifier == p.bundleId && !$0.isTerminated } }
    }

    private func refreshConsent() {
        guard running else { return }
        let unknown = runningPlayers().map(\.bundleId).filter { consent[$0] == nil || consent[$0] == .unknown }
        guard !unknown.isEmpty else { consentChanged(); return }
        let gen = generation
        worker.queue.async { [worker] in
            var result: [String: Consent] = [:]
            for id in unknown { result[id] = worker.consent(for: id, ask: false) }
            onMain { [weak self] in
                guard let self, self.generation == gen else { return }
                for (k, v) in result { self.consent[k] = v }
                self.consentChanged()
            }
        }
    }

    private func consentChanged() {
        onConsentChange(needsConsent)
        updateTimer()
    }

    private func updateTimer() {
        let want = running && !runningPlayers().filter { consent[$0.bundleId] == .granted }.isEmpty
        if want, timer == nil {
            let t = Timer(timeInterval: 2, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.poll() }
            }
            t.tolerance = 0.5
            RunLoop.main.add(t, forMode: .common)
            timer = t
            poll()
        } else if !want, let t = timer {
            t.invalidate()
            timer = nil
            onUpdate(nil)
        }
    }

    private func poll() {
        guard running, !polling else { return }
        let targets = runningPlayers().filter { consent[$0.bundleId] == .granted }
        guard !targets.isEmpty else { updateTimer(); return }
        polling = true
        let gen = generation
        let preferred = lastPlayer
        worker.queue.async { [worker] in
            var results: [(String, NowPlayingInfo)] = []
            for p in targets {
                if let info = worker.read(p.bundleId) { results.append((p.bundleId, info)) }
            }
            // Quella che suona, altrimenti l'ultima usata, altrimenti la prima in pausa.
            let pick = results.first { $0.1.playing }
                ?? results.first { $0.0 == preferred }
                ?? results.first
            onMain { [weak self] in
                guard let self, self.generation == gen else { return }
                self.polling = false
                if let pick { self.lastPlayer = pick.0 }
                self.onUpdate(pick?.1)
            }
        }
    }
}

/// Tutto quello che tocca NSAppleScript, su una coda seriale sua (un'app bloccata non ferma l'isola).
private final class AppleScriptWorker: @unchecked Sendable {
    let queue = DispatchQueue(label: "isola.music.applescript", qos: .utility)
    private var scripts: [String: NSAppleScript] = [:]
    private var lastArtworkKey: [String: String] = [:]
    private var lastArtwork: [String: (NSImage?, NSColor?, Int)] = [:]
    private var token = 0
    private static let sep = "\u{1E}"

    func consent(for bundleId: String, ask: Bool) -> AppleScriptSource.Consent {
        let target = NSAppleEventDescriptor(bundleIdentifier: bundleId)
        guard let desc = target.aeDesc else { return .unknown }
        let status = AEDeterminePermissionToAutomateTarget(desc, AEEventClass(typeWildCard), AEEventID(typeWildCard), ask)
        switch status {
        case noErr: return .granted
        case OSStatus(errAEEventNotPermitted): return .denied
        case OSStatus(errAEEventWouldRequireUserConsent): return .needed
        default: return .unknown
        }
    }

    func run(_ source: String) {
        var err: NSDictionary?
        NSAppleScript(source: source)?.executeAndReturnError(&err)
    }

    private func script(_ key: String, _ source: String) -> NSAppleScript? {
        if let s = scripts[key] { return s }
        guard let s = NSAppleScript(source: source) else { return nil }
        var err: NSDictionary?
        guard s.compileAndReturnError(&err) else { return nil }
        scripts[key] = s
        return s
    }

    /// Stato, titolo, artista, album, durata (s), posizione (s). Numeri con il punto decimale
    /// indipendentemente dalla lingua del Mac.
    func read(_ bundleId: String) -> NowPlayingInfo? {
        let isSpotify = bundleId == "com.spotify.client"
        let durationExpr = isSpotify ? "((duration of t) / 1000)" : "(duration of t)"
        let src = """
        on num(x)
            set s to x as string
            set AppleScript's text item delimiters to ","
            set parts to text items of s
            set AppleScript's text item delimiters to "."
            set s to parts as string
            set AppleScript's text item delimiters to ""
            return s
        end num
        tell application id "\(bundleId)"
            set st to player state as string
            if st is "stopped" then return "stopped"
            set t to current track
            set d to \(durationExpr)
            set sep to (ASCII character 30)
            return st & sep & (name of t) & sep & (artist of t) & sep & (album of t) & sep & my num(d) & sep & my num(player position)
        end tell
        """
        guard let s = script("read-\(bundleId)", src) else { return nil }
        var err: NSDictionary?
        let out = s.executeAndReturnError(&err)
        guard err == nil, let str = out.stringValue, str != "stopped" else { return nil }
        let f = str.components(separatedBy: Self.sep)
        guard f.count >= 6, !f[1].isEmpty else { return nil }
        var info = NowPlayingInfo()
        info.bundleId = bundleId
        info.playing = f[0] == "playing" || f[0] == "kPSP"
        info.title = f[1]
        info.artist = f[2]
        info.album = f[3]
        if let d = Double(f[4]), d > 0 { info.duration = d }
        info.elapsed = Double(f[5])
        info.timestamp = Date()
        info.canSeek = info.duration != nil
        if !isSpotify { attachArtwork(&info, bundleId: bundleId) }
        return info
    }

    /// Musica dà i byte della copertina; la chiediamo solo quando cambia brano.
    /// (Spotify dà solo un URL su internet: niente copertina nel ripiego.)
    private func attachArtwork(_ info: inout NowPlayingInfo, bundleId: String) {
        let key = info.trackKey
        if lastArtworkKey[bundleId] != key {
            lastArtworkKey[bundleId] = key
            token += 1
            var image: NSImage?
            let src = """
            tell application id "\(bundleId)"
                try
                    return raw data of artwork 1 of current track
                end try
                try
                    return data of artwork 1 of current track
                end try
            end tell
            """
            if let s = script("art-\(bundleId)", src) {
                var err: NSDictionary?
                let out = s.executeAndReturnError(&err)
                if err == nil, !out.data.isEmpty { image = NSImage(data: out.data) }
            }
            lastArtwork[bundleId] = (image, image.flatMap(CoverArt.accent(of:)), token)
        }
        if let a = lastArtwork[bundleId] {
            info.artwork = a.0
            info.artworkAccent = a.1
            info.artworkToken = a.2
        }
    }
}
