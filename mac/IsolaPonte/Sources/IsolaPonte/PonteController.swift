import AppKit
import Network
import PonteCore
import ServiceManagement
import UserNotifications

enum Tone { case neutral, ok, error }

/// State the network side reads from its own threads.
final class SharedState: @unchecked Sendable {
    private let lock = NSLock()
    private var _key: Data?
    private var _paused = false
    private var _name = "Mac"

    var key: Data? { get { lock.withLock { _key } } set { lock.withLock { _key = newValue } } }
    var paused: Bool { get { lock.withLock { _paused } } set { lock.withLock { _paused = newValue } } }
    var name: String { get { lock.withLock { _name } } set { lock.withLock { _name = newValue } } }
}

/// The whole app minus the windows: listening on the Tailscale address, watching the pasteboard,
/// sending and receiving clips, settings.
@MainActor
final class PonteController: ObservableObject {
    @Published var peer: String { didSet { peerChanged() } }
    @Published private(set) var paused: Bool
    @Published private(set) var notify: Bool
    @Published private(set) var hasKey = false
    @Published private(set) var listenStatus = "Avvio…"
    @Published private(set) var listening = false
    @Published private(set) var tailscaleUp = false
    @Published private(set) var peerStatus = ""
    @Published private(set) var peerTone = Tone.neutral
    @Published private(set) var launchAtLogin = false
    @Published var notice = ""

    private let defaults = UserDefaults.standard
    private let shared = SharedState()
    private var key: Data? { didSet { shared.key = key; hasKey = key != nil } }
    private var handler: PonteHandler!
    private var server: PonteServer?
    private var localIP: IPAddr?
    private var pathMonitor: NWPathMonitor?
    private var recheckTimer: Timer?
    private var recheckQueued = false
    private var pingVersion = 0
    private var peerName: String?
    private var lastPing = Date.distantPast
    private var pingDebounce: DispatchWorkItem?
    private let pasteboard = PasteboardBridge()
    private let sender = Sender()
    private let log = PonteLog.shared

    init() {
        peer = UserDefaults.standard.string(forKey: "peer") ?? ""
        paused = UserDefaults.standard.bool(forKey: "paused")
        notify = UserDefaults.standard.bool(forKey: "notify")
        shared.paused = paused
        key = Keychain.load()
        shared.key = key
        hasKey = key != nil
    }

    func start() {
        let shared = self.shared
        handler = PonteHandler(hooks: .init(
            key: { shared.key },
            name: { shared.name },
            paused: { shared.paused },
            deliver: { clip in DispatchQueue.main.async { MainActor.assumeIsolated { self.receive(clip) } } }
        ))
        DispatchQueue.global(qos: .utility).async {
            let n = Ponte.cleanName(Host.current().localizedName)
            if !n.isEmpty { shared.name = n }
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled

        pasteboard.onCopy = { [weak self] item in self?.localCopy(item) }
        pasteboard.start()

        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.queueRecheck() } }
        }
        monitor.start(queue: DispatchQueue(label: "it.isola.ponte.path"))
        pathMonitor = monitor
        recheckTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.recheck() }
        }
        recheck()
        test()
    }

    // MARK: - Listening

    /// Bursts of path events while an interface comes up: one re-check shortly after.
    private func queueRecheck() {
        if recheckQueued { return }
        recheckQueued = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
            MainActor.assumeIsolated {
                self?.recheckQueued = false
                self?.recheck()
            }
        }
    }

    private func recheck() {
        guard let ip = LocalAddresses.tailscaleIPv4() else {
            server?.stop()
            server = nil
            localIP = nil
            listening = false
            tailscaleUp = false
            listenStatus = "Tailscale non attivo"
            return
        }
        tailscaleUp = true
        if server != nil && ip == localIP { return }
        let wasDown = localIP == nil
        server?.stop()
        let s = PonteServer(bind: ip, handler: handler)
        server = s
        localIP = ip
        listening = false
        s.start { result in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { [weak self] in
                    guard let self, self.server === s else { return }
                    switch result {
                    case .success:
                        self.listening = true
                        self.listenStatus = "Questo Mac è \(ip) su Tailscale"
                        if wasDown { self.test() }
                    case .failure(let err):
                        self.server = nil
                        self.localIP = nil
                        self.log.error(err.reason)
                        self.listenStatus = err.reason == "porta occupata"
                            ? "Porta \(Ponte.port) occupata da un'altra app"
                            : "Non riesco ad ascoltare: \(err.reason)"
                    }
                }
            }
        }
    }

    // MARK: - Status line in the menu

    var menuStatus: String {
        if !tailscaleUp { return "Tailscale non attivo" }
        if server == nil, !listenStatus.isEmpty, listenStatus != "Avvio…" { return listenStatus }
        return peerStatus.isEmpty ? "Verifico…" : peerStatus
    }

    func menuOpened() {
        if Date().timeIntervalSince(lastPing) > 10 { test() }
    }

    // MARK: - Settings

    func setPaused(_ on: Bool) {
        paused = on
        shared.paused = on
        defaults.set(on, forKey: "paused")
    }

    private func peerChanged() {
        let trimmed = peer.trimmingCharacters(in: .whitespacesAndNewlines)
        defaults.set(trimmed, forKey: "peer")
        peerName = nil
        pingDebounce?.cancel()
        let work = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.test() } }
        pingDebounce = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: work)
    }

    /// New random key, saved. Returns it formatted.
    func generateKey() -> String {
        let k = Ponte.generateKey()
        saveKey(k)
        return Ponte.formatKey(k)
    }

    /// Saves a typed/pasted key. False if it isn't a valid key.
    func setKey(_ text: String) -> Bool {
        guard let k = Ponte.parseKey(text) else { return false }
        if k != key { saveKey(k) }
        return true
    }

    private func saveKey(_ k: Data) {
        key = k
        if !Keychain.save(k) { log.error("chiave non salvata") }
        test()
    }

    var formattedKey: String? { key.map(Ponte.formatKey) }

    /// "Copia": on the pasteboard with the "concealed" and "transient" marks, so it is neither kept in
    /// clipboard histories nor sent to the other computer.
    func copyKey() {
        guard let k = formattedKey else { return }
        pasteboard.writeConcealed(k)
    }

    func setLaunchAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            notice = on ? "macOS non ha permesso l'apertura all'avvio." : "Non riesco a togliere l'apertura all'avvio."
        }
        let status = SMAppService.mainApp.status
        launchAtLogin = status == .enabled
        if on && status == .requiresApproval {
            notice = "Da approvare in Impostazioni di Sistema → Generali → Elementi login."
        }
    }

    /// Notifications are opt-in: permission is asked only when this is turned on.
    func setNotify(_ on: Bool) {
        guard on else {
            notify = false
            defaults.set(false, forKey: "notify")
            return
        }
        guard Bundle.main.bundleIdentifier != nil else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert]) { granted, _ in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { [weak self] in
                    guard let self else { return }
                    self.notify = granted
                    self.defaults.set(granted, forKey: "notify")
                    if !granted { self.notice = "Le notifiche sono spente per Isola Ponte in Impostazioni di Sistema." }
                }
            }
        }
    }

    // MARK: - Ping

    /// GET /ping, for the status line and the "Prova" button.
    func test() {
        pingVersion += 1
        let version = pingVersion
        let peer = self.peer.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !peer.isEmpty else { setPeerStatus("Scrivi il nome dell'altro computer", .neutral); return }
        guard let key else { setPeerStatus("Manca la chiave di abbinamento", .neutral); return }
        if peerStatus.isEmpty || peerTone != .ok { setPeerStatus("Verifico…", .neutral) }
        lastPing = Date()
        let selfAddresses = LocalAddresses.set()
        Task {
            let (result, name) = await PonteClient.shared.ping(peer: peer, key: key, selfAddresses: selfAddresses)
            guard version == self.pingVersion else { return } // a newer test is running
            if result == .ok { self.peerName = (name?.isEmpty ?? true) ? nil : name }
            self.show(result)
        }
    }

    private func show(_ result: PonteResult) {
        switch result {
        case .ok: setPeerStatus(peerName.map { "Collegato a \($0)" } ?? "Collegato", .ok)
        case .wrongKey: setPeerStatus("Chiave sbagliata", .error)
        case .refused: setPeerStatus("L'altro computer ha la condivisione in pausa", .neutral)
        case .selfAddress: setPeerStatus("Quel nome è questo Mac: scrivi quello dell'altro", .error)
        case .error: setPeerStatus("Risposta non valida", .error)
        case .unreachable: setPeerStatus("Non raggiungibile", .error)
        }
    }

    private func setPeerStatus(_ s: String, _ tone: Tone) {
        peerStatus = s
        peerTone = tone
    }

    // MARK: - Sending

    private var canSend: Bool {
        !paused && key != nil && !peer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func localCopy(_ item: PasteboardBridge.Item) {
        guard canSend, let key else { return }
        let peer = self.peer.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = shared.name
        let selfAddresses = LocalAddresses.set()
        let log = self.log
        let build: @Sendable () -> (Data, Int64)?
        switch item {
        case .text(let text):
            let wire = Ponte.toWire(text)
            let count = wire.utf16.count
            if count == 0 { return }
            if count > Ponte.maxTextChars { log.error("troppo grande"); return }
            build = {
                let ts = Ponte.nowMs()
                return (Ponte.buildClipBody(id: Ponte.newId(), from: name, ts: ts, kind: .text, text: wire, png: nil), ts)
            }
        case .image(let raw):
            build = {
                guard let png = PasteboardBridge.pngData(raw) else { return nil }
                if png.count > Ponte.maxPngBytes { log.error("troppo grande"); return nil }
                let ts = Ponte.nowMs()
                return (Ponte.buildClipBody(id: Ponte.newId(), from: name, ts: ts, kind: .image, text: nil, png: png), ts)
            }
        }
        sender.enqueue(.init(peer: peer, key: key, selfAddresses: selfAddresses, build: build)) { result in
            DispatchQueue.main.async { MainActor.assumeIsolated { [weak self] in self?.sent(result) } }
        }
    }

    private func sent(_ result: PonteResult) {
        if result == .ok {
            log.info("inviato")
            if peerTone == .error { show(result) }
            return
        }
        switch result {
        case .wrongKey: log.error("chiave sbagliata")
        case .refused: log.error("rifiutato (in pausa)")
        case .selfAddress: log.error("destinatario è questo Mac")
        case .error: log.error("risposta non valida")
        default: log.error("non raggiungibile")
        }
        show(result)
    }

    // MARK: - Receiving

    private func receive(_ clip: ClipPayload) {
        let ok: Bool
        switch clip.kind {
        case .text: ok = pasteboard.writeIncoming(text: clip.text ?? "")
        case .image: ok = pasteboard.writeIncoming(png: clip.png ?? Data())
        }
        guard ok else { log.error("consegna non riuscita"); return }
        log.info("ricevuto")
        if notify { postNotification(clip) }
    }

    private func postNotification(_ clip: ClipPayload) {
        guard Bundle.main.bundleIdentifier != nil else { return }
        let content = UNMutableNotificationContent()
        content.title = "Appunti da " + (clip.from.isEmpty ? "altro computer" : clip.from)
        content.body = clip.kind == .text ? "Testo" : "Immagine"
        content.sound = nil
        let req = UNNotificationRequest(identifier: "ponte-ricevuto", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(req)
    }
}

/// One send at a time; if more copies happen meanwhile only the latest is sent.
final class Sender: @unchecked Sendable {
    struct Job: Sendable {
        let peer: String
        let key: Data
        let selfAddresses: Set<IPAddr>
        let build: @Sendable () -> (Data, Int64)?
    }

    private let lock = NSLock()
    private var pending: (Job, @Sendable (PonteResult) -> Void)?
    private var sending = false

    func enqueue(_ job: Job, done: @escaping @Sendable (PonteResult) -> Void) {
        lock.lock()
        pending = (job, done)
        if sending { lock.unlock(); return }
        sending = true
        lock.unlock()
        Task.detached(priority: .utility) { await self.loop() }
    }

    /// The latest job, or nil (and not sending any more) when there is none.
    private func next() -> (Job, @Sendable (PonteResult) -> Void)? {
        lock.lock()
        defer { lock.unlock() }
        guard let p = pending else { sending = false; return nil }
        pending = nil
        return p
    }

    private func loop() async {
        while let (job, done) = next() {
            guard let (body, ts) = job.build() else { continue }
            let result = await PonteClient.shared.send(peer: job.peer, key: job.key, body: body, ts: ts, selfAddresses: job.selfAddresses)
            done(result)
        }
    }
}
