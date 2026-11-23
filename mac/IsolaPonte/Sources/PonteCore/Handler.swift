import Foundation
import os

/// "condivisione: inviato / ricevuto / errore <motivo>": never content, keys, names or addresses.
/// Errors are written at most once a minute per reason.
public final class PonteLog: @unchecked Sendable {
    public static let shared = PonteLog()

    private let logger = Logger(subsystem: "it.isola.ponte", category: "condivisione")
    private let lock = NSLock()
    private var lastError: [String: Date] = [:]
    /// Test hook: every line also goes here.
    public var sink: ((String) -> Void)?

    public init() {}

    public func info(_ what: String) { write("condivisione: " + what) }

    public func error(_ reason: String) {
        lock.lock()
        let now = Date()
        if let last = lastError[reason], now.timeIntervalSince(last) < 60 {
            lock.unlock()
            return
        }
        lastError[reason] = now
        lock.unlock()
        write("condivisione: errore " + reason)
    }

    private func write(_ line: String) {
        logger.info("\(line, privacy: .public)")
        sink?(line)
    }
}

/// Request line and headers of one HTTP/1.1 request.
public struct RequestHead: Equatable {
    public let method: String
    /// Target without the query string.
    public let path: String
    /// Names lowercased (ASCII); the first of repeated headers wins.
    public let headers: [String: String]
    public let contentLength: Int64?

    public var chunked: Bool { headers["transfer-encoding"] != nil }
    public var expectContinue: Bool { headers["expect"].map { asciiLower($0) == "100-continue" } ?? false }
    public func header(_ name: String) -> String? { headers[asciiLower(name)] }
}

func asciiLower(_ s: String) -> String {
    String(decoding: s.utf8.map { $0 >= 0x41 && $0 <= 0x5A ? $0 + 0x20 : $0 }, as: UTF8.self)
}

public enum HTTPHead {
    /// Index of "\r\n\r\n" in the first `count` bytes, or nil.
    public static func endOfHead(_ b: [UInt8], count: Int) -> Int? {
        var i = 3
        while i < count {
            if b[i] == 0x0A && b[i - 1] == 0x0D && b[i - 2] == 0x0A && b[i - 3] == 0x0D { return i - 3 }
            i += 1
        }
        return nil
    }

    /// Parses the bytes before "\r\n\r\n" (Latin-1). nil = malformed (400).
    public static func parse(_ head: ArraySlice<UInt8>) -> RequestHead? {
        var lines: [String] = []
        var start = head.startIndex
        var i = head.startIndex
        while i < head.endIndex {
            if head[i] == 0x0D, i + 1 < head.endIndex, head[i + 1] == 0x0A {
                lines.append(latin1(head[start..<i]))
                i += 2
                start = i
            } else {
                i += 1
            }
        }
        lines.append(latin1(head[start..<head.endIndex]))

        let parts = lines[0].split(separator: " ", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[2].hasPrefix("HTTP/1.") else { return nil }
        let method = String(parts[0])
        let target = String(parts[1])
        let path = target.firstIndex(of: "?").map { String(target[..<$0]) } ?? target

        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            let u = Array(line.unicodeScalars)
            guard let colon = u.firstIndex(of: ":"), colon > 0 else { return nil }
            let name = trim(String(String.UnicodeScalarView(u[..<colon])))
            let value = trim(String(String.UnicodeScalarView(u[(colon + 1)...])))
            let key = asciiLower(name)
            if let existing = headers[key] {
                if key == "content-length" && existing != value { return nil }
                continue
            }
            headers[key] = value
        }

        var contentLength: Int64?
        if let cl = headers["content-length"] {
            guard !cl.isEmpty, cl.utf8.allSatisfy({ $0 >= 0x30 && $0 <= 0x39 }), let n = Int64(cl) else { return nil }
            contentLength = n
        }
        return RequestHead(method: method, path: path, headers: headers, contentLength: contentLength)
    }

    private static func latin1(_ b: ArraySlice<UInt8>) -> String {
        var s = String.UnicodeScalarView()
        for c in b { s.append(Unicode.Scalar(c)) }
        return String(s)
    }

    /// .NET String.Trim() (Unicode white space; only Latin-1 can occur here).
    private static func trim(_ s: String) -> String {
        let u = Array(s.utf16)
        var lo = 0, hi = u.count
        while lo < hi && Ponte.isWhiteSpace(u[lo]) { lo += 1 }
        while hi > lo && Ponte.isWhiteSpace(u[hi - 1]) { hi -= 1 }
        return String(decoding: u[lo..<hi], as: UTF16.self)
    }
}

public struct Reply: Equatable {
    public let status: Int
    public let json: Data?

    public init(_ status: Int, json: Data? = nil) {
        self.status = status
        self.json = json
    }

    public static func reason(_ status: Int) -> String {
        switch status {
        case 100: return "Continue"
        case 200: return "OK"
        case 204: return "No Content"
        case 400: return "Bad Request"
        case 401: return "Unauthorized"
        case 403: return "Forbidden"
        case 404: return "Not Found"
        case 405: return "Method Not Allowed"
        case 408: return "Request Timeout"
        case 411: return "Length Required"
        case 413: return "Payload Too Large"
        case 503: return "Service Unavailable"
        default: return "Error"
        }
    }

    /// Status line, Content-Type (only with a JSON body), Content-Length, Connection: close.
    public var bytes: Data {
        var s = "HTTP/1.1 \(status) \(Reply.reason(status))\r\n"
        if json != nil { s += "Content-Type: application/json; charset=utf-8\r\n" }
        s += "Content-Length: \(json?.count ?? 0)\r\n"
        s += "Connection: close\r\n\r\n"
        var d = Data(s.utf8)
        if let json { d.append(json) }
        return d
    }

    public static let busy = Data("HTTP/1.1 503 Service Unavailable\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8)
    public static let continue100 = Data("HTTP/1.1 100 Continue\r\n\r\n".utf8)
}

/// The receiving rules of the protocol, without any I/O: same checks, codes and order as
/// ClipSyncServer.PreCheck / Process on Windows.
public final class PonteHandler: @unchecked Sendable {
    public struct Hooks {
        public var key: () -> Data?
        public var name: () -> String
        public var paused: () -> Bool
        public var deliver: (ClipPayload) -> Void
        public var now: () -> Int64

        public init(key: @escaping () -> Data?, name: @escaping () -> String, paused: @escaping () -> Bool,
                    deliver: @escaping (ClipPayload) -> Void, now: @escaping () -> Int64 = Ponte.nowMs) {
            self.key = key
            self.name = name
            self.paused = paused
            self.deliver = deliver
            self.now = now
        }
    }

    private let hooks: Hooks
    private let allowLoopback: Bool
    private let log: PonteLog
    private let idsLock = NSLock()
    private var idOrder: [String] = []
    private var ids = Set<String>()

    /// allowLoopbackForTests also accepts 127.0.0.1 / ::1 (never set by the app).
    public init(hooks: Hooks, allowLoopbackForTests: Bool = false, log: PonteLog = .shared) {
        self.hooks = hooks
        self.allowLoopback = allowLoopbackForTests
        self.log = log
    }

    func allowed(_ ip: IPAddr) -> Bool { ip.isTailscale || (allowLoopback && ip.isLoopback) }

    /// Both ends of the connection must be Tailscale addresses.
    public func sourceAllowed(remote: IPAddr?, local: IPAddr?) -> Bool {
        guard let remote, let local, allowed(remote), allowed(local) else {
            log.error("origine non ammessa")
            return false
        }
        return true
    }

    /// Checks done before reading the body. nil = go on.
    public func preCheck(_ head: RequestHead) -> Int? {
        let clip = head.path == "/clip", ping = head.path == "/ping"
        if !clip && !ping { return 404 }
        if clip && head.method != "POST" { return 405 }
        if ping && head.method != "GET" { return 405 }
        if head.chunked { return 411 }
        if clip {
            guard let cl = head.contentLength else { return 411 }
            if cl > Int64(Ponte.maxBodyBytes) { log.error("troppo grande"); return 413 }
        } else if let cl = head.contentLength, cl > 0 {
            return 400 // ping has an empty body
        }
        return nil
    }

    public func process(path: String, ts tsHeader: String?, sig: String?, body: Data) -> Reply {
        guard let key = hooks.key() else { log.error("chiave mancante"); return Reply(401) }
        guard let ts = Ponte.parseTs(tsHeader), let tsHeader, Ponte.verify(key: key, ts: tsHeader, body: body, sigHex: sig) else {
            log.error("firma non valida")
            return Reply(401)
        }
        if !Ponte.tsInWindow(ts, now: hooks.now()) { log.error("orario fuori tolleranza"); return Reply(401) }
        if path == "/ping" { return Reply(200, json: Ponte.buildPingResponse(name: hooks.name())) }

        let clip: ClipPayload
        switch Ponte.parseClip(body) {
        case .failure(.badJson): log.error("JSON non valido"); return Reply(400)
        case .failure(.tooLarge): log.error("troppo grande"); return Reply(413)
        case .success(let c): clip = c
        }
        if clip.ts != ts { log.error("firma non valida"); return Reply(401) }
        if hooks.paused() { return Reply(503) }
        if !remember(clip.id) { return Reply(204) } // already received: ignored
        hooks.deliver(clip)
        return Reply(204)
    }

    /// False if the id was among the last 200.
    private func remember(_ id: String) -> Bool {
        idsLock.lock()
        defer { idsLock.unlock() }
        guard ids.insert(id).inserted else { return false }
        idOrder.append(id)
        while idOrder.count > Ponte.rememberedIds { ids.remove(idOrder.removeFirst()) }
        return true
    }
}
