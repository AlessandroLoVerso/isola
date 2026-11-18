import Foundation
import Network

/// Il piccolo server HTTP su 127.0.0.1 che riceve il JSON degli hook di Claude Code.
/// Tutto lo stato vive sulla coda privata `queue`; i callback arrivano su quella coda.
final class AgentServer: @unchecked Sendable {
    enum State: Equatable, Sendable {
        case starting
        case listening
        case portBusy
        case failed(String)
    }

    static let maxBody = 256 * 1024
    static let maxConnections = 64
    /// Tempo massimo di una connessione, dalla prima riga alla risposta.
    static let connectionTimeout: TimeInterval = 5

    let port: UInt16
    private let queue = DispatchQueue(label: "isola.agents.server", qos: .utility)
    private let onState: @Sendable (State) -> Void
    private let onBody: @Sendable (Data) -> Void

    private var listener: NWListener?
    private var clients: [ObjectIdentifier: Client] = [:]
    private var stopped = false

    init(port: UInt16, onState: @escaping @Sendable (State) -> Void, onBody: @escaping @Sendable (Data) -> Void) {
        self.port = port
        self.onState = onState
        self.onBody = onBody
    }

    func start() { queue.async { self.startOnQueue() } }

    /// Chiude il listener e tutte le connessioni. Dopo, nessun callback.
    func stop() {
        queue.async {
            self.stopped = true
            self.listener?.newConnectionHandler = nil
            self.listener?.stateUpdateHandler = nil
            self.listener?.cancel()
            self.listener = nil
            for c in self.clients.values { self.close(c) }
            self.clients.removeAll()
        }
    }

    // MARK: listener

    private func startOnQueue() {
        guard !stopped, listener == nil else { return }
        onState(.starting)
        guard let nwPort = NWEndpoint.Port(rawValue: port) else { onState(.failed("porta non valida")); return }
        let params = NWParameters.tcp
        // Solo l'interfaccia di loopback: dalla rete non si arriva.
        params.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: nwPort)
        params.includePeerToPeer = false
        let l: NWListener
        do {
            l = try NWListener(using: params)
        } catch {
            onState(Self.state(for: error))
            return
        }
        l.stateUpdateHandler = { [weak self, weak l] state in
            guard let self, let l, !self.stopped, self.listener === l else { return }
            switch state {
            case .ready:
                self.onState(.listening)
            case .failed(let error), .waiting(let error):
                self.onState(Self.state(for: error))
                l.newConnectionHandler = nil
                l.stateUpdateHandler = nil
                l.cancel()
                self.listener = nil
            default:
                break
            }
        }
        l.newConnectionHandler = { [weak self] conn in self?.accept(conn) }
        listener = l
        l.start(queue: queue)
    }

    private static func state(for error: Error) -> State {
        if let nw = error as? NWError {
            if case .posix(let code) = nw, code == .EADDRINUSE { return .portBusy }
            if case .posix(let code) = nw { return .failed("errore \(code.rawValue)") }
        }
        return .failed("errore di rete")
    }

    // MARK: connessioni

    /// Vive solo sulla coda del server.
    private final class Client: @unchecked Sendable {
        let conn: NWConnection
        var parser = HTTPRequestParser(maxBody: AgentServer.maxBody)
        var answered = false
        var timeout: DispatchWorkItem?
        init(_ conn: NWConnection) { self.conn = conn }
    }

    private func accept(_ conn: NWConnection) {
        guard !stopped, clients.count < Self.maxConnections, Self.isLoopback(conn.endpoint) else {
            conn.cancel()
            return
        }
        let client = Client(conn)
        clients[ObjectIdentifier(client)] = client
        conn.stateUpdateHandler = { [weak self, weak client] state in
            guard let self, let client else { return }
            switch state {
            case .failed, .cancelled: self.close(client)
            default: break
            }
        }
        let item = DispatchWorkItem { [weak self, weak client] in
            guard let self, let client else { return }
            self.close(client)
        }
        client.timeout = item
        queue.asyncAfter(deadline: .now() + Self.connectionTimeout, execute: item)
        conn.start(queue: queue)
        receive(client)
    }

    private static func isLoopback(_ endpoint: NWEndpoint) -> Bool {
        guard case .hostPort(let host, _) = endpoint else { return false }
        switch host {
        case .ipv4(let a): return a.isLoopback
        case .ipv6(let a): return a.isLoopback || a.asIPv4?.isLoopback == true
        case .name(let n, _): return n == "localhost"
        @unknown default: return false
        }
    }

    private func receive(_ client: Client) {
        client.conn.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) {
            [weak self, weak client] data, _, isComplete, error in
            guard let self, let client, !self.stopped, !client.answered else { return }
            if let data, !data.isEmpty { client.parser.append(data) }
            if error != nil && (data?.isEmpty ?? true) {
                self.close(client)
                return
            }
            self.advance(client, eof: isComplete)
        }
    }

    private func advance(_ client: Client, eof: Bool) {
        while true {
            switch client.parser.step(eof: eof) {
            case .needMore:
                if eof { close(client) } else { receive(client) }
                return
            case .sendContinue:
                client.conn.send(content: Data("HTTP/1.1 100 Continue\r\n\r\n".utf8),
                                 completion: .contentProcessed { _ in })
            case .finished(let status, let body):
                respond(client, status: status)
                if status == 200, let body, !body.isEmpty { onBody(body) }
                return
            }
        }
    }

    private func respond(_ client: Client, status: Int) {
        client.answered = true
        let reason: String
        switch status {
        case 200: reason = "OK"
        case 400: reason = "Bad Request"
        case 413: reason = "Payload Too Large"
        case 431: reason = "Request Header Fields Too Large"
        default: reason = "Not Found"
        }
        let text = "HTTP/1.1 \(status) \(reason)\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
        client.conn.send(content: Data(text.utf8), contentContext: .finalMessage, isComplete: true,
                         completion: .contentProcessed { [weak self, weak client] _ in
            guard let self, let client else { return }
            self.close(client)
        })
    }

    private func close(_ client: Client) {
        client.timeout?.cancel()
        client.timeout = nil
        client.conn.stateUpdateHandler = nil
        client.conn.cancel()
        clients.removeValue(forKey: ObjectIdentifier(client))
    }
}
