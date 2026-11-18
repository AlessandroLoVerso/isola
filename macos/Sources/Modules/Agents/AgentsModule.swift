import AppKit
import IsolaCore
import SwiftUI

/// Scheda "Agenti": lo stato delle sessioni di Claude Code, che arriva dagli hook di Claude Code
/// con un POST del loro JSON a http://127.0.0.1:47321/agent. La pillola si accende quando una
/// sessione ti aspetta.
@MainActor
public final class AgentsModule: IslandModule, RestingFaceProvider, PeekProvider {
    static let port: UInt16 = 47321
    static let maxSessions = 32
    static let idleTimeout: TimeInterval = 30 * 60
    static let doneWindow: TimeInterval = 60

    let model = AgentsModel()
    private var host: IslandHost?
    private var server: AgentServer?
    /// Cresce a ogni avvio o arresto del server: i messaggi di un server vecchio si scartano.
    private var generation = 0
    private var sessions: [String: AgentSession] = [:]
    private var timer: Timer?
    private var timerDeadline: Date?
    private var priority = 0

    public init() {}
    public var id: String { "agents" }
    public var title: String { "Agenti" }
    public var symbol: String { "sparkles" }
    public var order: Int { 15 }
    public var enabledByDefault: Bool { true }
    public var restingPriority: Int { priority }

    // MARK: ciclo di vita

    public func start(host: IslandHost) throws {
        self.host = host
        host.onCardVisibilityChange { [weak self] _ in self?.refresh() }
        model.restartServer = { [weak self] in self?.restartServer() }
        model.log = { [weak host] in host?.log($0) }
        startServer()
    }

    public func stop() {
        stopServer()
        timer?.invalidate()
        timer = nil
        timerDeadline = nil
        sessions.removeAll()
        priority = 0
        model.reset()
        model.restartServer = nil
        model.log = nil
        host = nil
    }

    private func startServer() {
        generation += 1
        let gen = generation
        let ref = WeakModule(self)
        let server = AgentServer(
            port: Self.port,
            onState: { state in
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        guard let self = ref.module, self.generation == gen else { return }
                        self.serverStateChanged(state)
                    }
                }
            },
            onBody: { body in
                // Il JSON si legge sulla coda del server; al main thread arriva solo l'essenziale.
                guard let event = HookEvent.parse(body) else { return }
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        guard let self = ref.module, self.generation == gen else { return }
                        self.handle(event)
                    }
                }
            })
        self.server = server
        model.serverState = .starting
        server.start()
    }

    private func stopServer() {
        generation += 1
        server?.stop()
        server = nil
    }

    private func restartServer() {
        guard host != nil else { return }
        stopServer()
        startServer()
    }

    private func serverStateChanged(_ state: AgentServer.State) {
        model.serverState = state
        switch state {
        case .portBusy: host?.log("Server non avviato: porta \(Self.port) occupata")
        case .failed(let why): host?.log("Server non avviato: \(why)")
        default: break
        }
    }

    // MARK: stato

    private func handle(_ e: HookEvent) {
        guard let host else { return }
        let now = Date()
        if e.name == "SessionEnd" {
            sessions.removeValue(forKey: e.sessionId)
            refresh()
            return
        }

        var s: AgentSession
        if let existing = sessions[e.sessionId] {
            s = existing
        } else {
            // Memoria limitata: si dimentica la sessione più vecchia.
            if sessions.count >= Self.maxSessions,
               let stalest = sessions.min(by: { $0.value.lastEvent < $1.value.lastEvent })?.key {
                sessions.removeValue(forKey: stalest)
            }
            s = AgentSession(id: e.sessionId, lastEvent: now, since: now)
        }
        if !e.cwd.isEmpty { s.folder = HookEvent.folderName(e.cwd) }
        let before = s.state
        let isNew = sessions[e.sessionId] == nil
        switch e.name {
        case "UserPromptSubmit", "PostToolUse":
            s.state = .working
            s.detail = "Al lavoro"
        case "PreToolUse":
            s.state = .working
            s.detail = e.tool.isEmpty ? "Al lavoro" : "Usa " + e.tool
        case "Notification":
            s.state = .waiting
            s.detail = e.message.isEmpty ? "Ti aspetta" : e.message
        case "Stop":
            s.state = .done
            s.detail = "Finito"
        default:
            s.lastEvent = now
            sessions[e.sessionId] = s
            refresh()
            return
        }
        s.lastEvent = now
        if s.state != before || isNew { s.since = now }
        sessions[e.sessionId] = s
        refresh()

        let started = s.state != before || isNew
        if started && (s.state == .waiting || s.state == .done) {
            model.peek = AgentPeek(folder: s.folder, state: s.state, detail: s.detail)
            host.attention(duration: s.state == .waiting ? 6 : 4)
        }
    }

    /// Toglie le sessioni scadute, ricalcola la pillola e le righe e (ri)arma il timer.
    private func refresh() {
        guard let host else { return }
        let now = Date()
        sessions = sessions.filter { now.timeIntervalSince($0.value.lastEvent) <= Self.idleTimeout }

        let all = Array(sessions.values)
        let waiting = all.filter { $0.state == .waiting }.sorted { $0.since > $1.since }
        let working = all.filter { $0.state == .working }.sorted { $0.lastEvent > $1.lastEvent }
        let done = all.filter { $0.state == .done && now.timeIntervalSince($0.since) < Self.doneWindow }
            .sorted { $0.since > $1.since }

        let face: AgentFace
        let newPriority: Int
        if let first = waiting.first {
            newPriority = 90
            face = AgentFace(state: .waiting, folder: first.folder, count: waiting.count)
        } else if let first = working.first {
            newPriority = 20
            face = AgentFace(state: .working, folder: first.folder, count: working.count)
        } else if let first = done.first {
            newPriority = 15
            face = AgentFace(state: .done, folder: first.folder, count: done.count)
        } else {
            newPriority = 0
            face = AgentFace(state: nil, folder: "", count: 0)
        }
        if model.face != face { model.face = face }

        let rows = all.sorted {
            if $0.state.rank != $1.state.rank { return $0.state.rank < $1.state.rank }
            return $0.lastEvent > $1.lastEvent
        }
        if model.rows != rows { model.rows = rows }
        let cardVisible = host.isCardVisible
        if cardVisible { model.now = now }

        if newPriority != priority {
            priority = newPriority
            host.refreshRestingFace()
        }

        // Un solo timer, e solo se c'è qualcosa da tenere aggiornato: ogni secondo per i tempi
        // nella scheda aperta, altrimenti alla prossima scadenza (fine di un "Finito" o sessione
        // scaduta). A isola ferma e senza sessioni non gira niente.
        guard !sessions.isEmpty else {
            timer?.invalidate()
            timer = nil
            timerDeadline = nil
            return
        }
        var interval: TimeInterval = cardVisible ? 1 : 3600
        for d in done {
            let left = Self.doneWindow - now.timeIntervalSince(d.since)
            if left > 0 && left < interval { interval = left }
        }
        for s in all {
            let left = Self.idleTimeout - now.timeIntervalSince(s.lastEvent)
            if left < interval { interval = left }
        }
        interval = max(0.2, interval + 0.1)
        let deadline = now.addingTimeInterval(interval)
        // Molti eventi al secondo: si riarma solo se la scadenza cambia davvero.
        if let current = timerDeadline, timer != nil, abs(current.timeIntervalSince(deadline)) < 0.25 { return }
        timer?.invalidate()
        let t = Timer(fire: deadline, interval: 0, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.timer = nil
                self.timerDeadline = nil
                self.refresh()
            }
        }
        t.tolerance = cardVisible ? 0.1 : 1
        RunLoop.main.add(t, forMode: .common)
        timer = t
        timerDeadline = deadline
    }

    // MARK: viste

    public func makeCard() -> AnyView? {
        AnyView(AgentsCard(model: model))
    }

    public func makeRestingFace() -> RestingFace {
        RestingFace(sideWidth: 84,
                    leading: AgentFaceLeading(model: model),
                    trailing: AgentFaceTrailing(model: model))
    }

    public func makePeek() -> AnyView {
        AnyView(AgentPeekView(model: model))
    }

    public func makeSettings() -> AnyView? {
        AnyView(AgentsSettings(model: model))
    }
}

// MARK: - Modello

/// Riferimento debole al modulo da passare alla coda del server; si legge solo sul main thread.
private final class WeakModule: @unchecked Sendable {
    weak var module: AgentsModule?
    init(_ module: AgentsModule) { self.module = module }
}

enum AgentState: Equatable {
    case working, waiting, done

    /// Ordine nella scheda: prima chi ti aspetta.
    var rank: Int {
        switch self {
        case .waiting: return 0
        case .working: return 1
        case .done: return 2
        }
    }
}

struct AgentSession: Identifiable, Equatable {
    let id: String
    var folder = "Claude"
    var state = AgentState.working
    var detail = "Al lavoro"
    var lastEvent: Date
    var since: Date
}

/// Cosa mostra la pillola chiusa. `state == nil`: niente.
struct AgentFace: Equatable {
    var state: AgentState?
    var folder: String
    var count: Int
}

struct AgentPeek: Equatable {
    var folder: String
    var state: AgentState
    var detail: String
}

@MainActor
final class AgentsModel: ObservableObject {
    @Published var rows: [AgentSession] = []
    @Published var now = Date()
    @Published var face = AgentFace(state: nil, folder: "", count: 0)
    @Published var peek: AgentPeek?
    @Published var serverState: AgentServer.State?
    var restartServer: (() -> Void)?
    /// Una riga nel log dell'isola (mai percorsi o contenuti).
    var log: ((String) -> Void)?

    func reset() {
        rows = []
        face = AgentFace(state: nil, folder: "", count: 0)
        peek = nil
        serverState = nil
    }

    var serverOK: Bool { serverState == .listening }

    var serverText: String {
        switch serverState {
        case nil: return "Spento"
        case .starting: return "Avvio…"
        case .listening: return "In ascolto su 127.0.0.1:\(AgentsModule.port)"
        case .portBusy: return "Porta \(AgentsModule.port) occupata da un altro programma"
        case .failed(let why): return "Non avviato (\(why))"
        }
    }
}
