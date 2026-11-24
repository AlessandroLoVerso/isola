import Darwin
import Foundation

public enum PonteResult: Equatable, Sendable {
    case ok
    /// Name not found, not a Tailscale address, refused, timed out.
    case unreachable
    /// 401: different pairing key (or clocks more than 5 minutes apart).
    case wrongKey
    /// 503: the other computer has sharing paused (or is busy).
    case refused
    /// Any other answer (400, 413, 404...).
    case error
    /// The name resolves to this Mac.
    case selfAddress
}

/// The sending side: one attempt, 3 s to resolve and connect (plus 1 s per MiB of body), no retries,
/// no queue. Only Tailscale addresses are ever contacted. Same rules as ClipSyncClient on Windows.
public final class PonteClient: @unchecked Sendable {
    public static let shared = PonteClient()

    private let session: URLSession
    private static let budget: TimeInterval = 3

    public init() {
        let c = URLSessionConfiguration.ephemeral
        c.connectionProxyDictionary = [:]          // a system proxy must never see the clipboard
        c.httpCookieStorage = nil
        c.httpShouldSetCookies = false
        c.urlCache = nil
        c.urlCredentialStorage = nil
        c.requestCachePolicy = .reloadIgnoringLocalCacheData
        c.waitsForConnectivity = false
        c.httpMaximumConnectionsPerHost = 2
        session = URLSession(configuration: c, delegate: NoRedirects(), delegateQueue: nil)
    }

    /// MagicDNS name or 100.x address → a Tailscale address (IPv4 first), or nil.
    public static func resolve(_ peer: String, allowLoopbackForTests: Bool = false) async -> IPAddr? {
        let peer = peer.trimmingCharacters(in: .whitespacesAndNewlines)
        if peer.isEmpty { return nil }
        func ok(_ ip: IPAddr) -> Bool { ip.isTailscale || (allowLoopbackForTests && ip.isLoopback) }
        if let literal = IPAddr(peer.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))) {
            return ok(literal) ? literal.unmapped : nil
        }
        let all = await lookup(peer)
        return all.first(where: { $0.isV4 && ok($0) }) ?? all.first(where: ok)
    }

    /// getaddrinfo on a background thread (it cannot be cancelled; the caller's deadline abandons it).
    private static func lookup(_ name: String) async -> [IPAddr] {
        await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .utility).async {
                var hints = addrinfo()
                hints.ai_family = AF_UNSPEC
                hints.ai_socktype = SOCK_STREAM
                var res: UnsafeMutablePointer<addrinfo>?
                guard getaddrinfo(name, nil, &hints, &res) == 0, let first = res else {
                    cont.resume(returning: [])
                    return
                }
                defer { freeaddrinfo(res) }
                var out: [IPAddr] = []
                var p: UnsafeMutablePointer<addrinfo>? = first
                while let ai = p {
                    if let sa = ai.pointee.ai_addr {
                        if ai.pointee.ai_family == AF_INET {
                            let a = sa.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr }
                            if let ip = IPAddr(bytes: withUnsafeBytes(of: a) { Array($0) }) { out.append(ip) }
                        } else if ai.pointee.ai_family == AF_INET6 {
                            let a = sa.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { $0.pointee.sin6_addr }
                            if let ip = IPAddr(bytes: withUnsafeBytes(of: a) { Array($0) }) { out.append(ip.unmapped) }
                        }
                    }
                    p = ai.pointee.ai_next
                }
                cont.resume(returning: out)
            }
        }
    }

    private func signed(method: String, ip: IPAddr, port: UInt16, path: String, key: Data, body: Data, ts: Int64, timeout: TimeInterval) -> URLRequest {
        let tsText = String(ts)
        var req = URLRequest(url: URL(string: "http://\(ip.urlHost):\(port)\(path)")!)
        req.httpMethod = method
        req.timeoutInterval = timeout
        req.httpShouldHandleCookies = false
        req.setValue("close", forHTTPHeaderField: "Connection")
        req.setValue(tsText, forHTTPHeaderField: Ponte.tsHeader)
        req.setValue(Ponte.sign(key: key, ts: tsText, body: body), forHTTPHeaderField: Ponte.sigHeader)
        if method == "POST" {
            req.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
            req.httpBody = body
        }
        return req
    }

    private static func map(_ code: Int) -> PonteResult {
        switch code {
        case 200, 204: return .ok
        case 401: return .wrongKey
        case 503: return .refused
        default: return .error
        }
    }

    /// POST /clip with a body built by Ponte.buildClipBody (ts must match).
    public func send(peer: String, key: Data, body: Data, ts: Int64, selfAddresses: Set<IPAddr>,
                     port: UInt16 = Ponte.port, allowLoopbackForTests: Bool = false) async -> PonteResult {
        let timeout = Self.budget + Double(body.count) / (1024 * 1024)
        let result = await withDeadline(timeout) { [self] () -> PonteResult in
            guard let ip = await Self.resolve(peer, allowLoopbackForTests: allowLoopbackForTests) else { return .unreachable }
            if selfAddresses.contains(ip) { return .selfAddress }
            let req = signed(method: "POST", ip: ip, port: port, path: "/clip", key: key, body: body, ts: ts, timeout: timeout)
            guard let (_, res) = try? await session.data(for: req), let http = res as? HTTPURLResponse else { return .unreachable }
            return Self.map(http.statusCode)
        }
        return result ?? .unreachable
    }

    /// GET /ping. On .ok, name is the other computer's name.
    public func ping(peer: String, key: Data, selfAddresses: Set<IPAddr>, port: UInt16 = Ponte.port,
                     allowLoopbackForTests: Bool = false) async -> (PonteResult, String?) {
        let result = await withDeadline(Self.budget) { [self] () -> (PonteResult, String?) in
            guard let ip = await Self.resolve(peer, allowLoopbackForTests: allowLoopbackForTests) else { return (.unreachable, nil) }
            if selfAddresses.contains(ip) { return (.selfAddress, nil) }
            let req = signed(method: "GET", ip: ip, port: port, path: "/ping", key: key, body: Data(), ts: Ponte.nowMs(), timeout: Self.budget)
            guard let (data, res) = try? await session.data(for: req), let http = res as? HTTPURLResponse else { return (.unreachable, nil) }
            let r = Self.map(http.statusCode)
            if r != .ok { return (r, nil) }
            return Self.readPing(data)
        }
        return result ?? (.unreachable, nil)
    }

    /// The ping answer: at most 4 KiB, {"v":1,"name":"…",…}.
    static func readPing(_ data: Data) -> (PonteResult, String?) {
        if data.count > 4096 { return (.error, nil) }
        guard let doc = try? StrictJSON.parse(data, maxDepth: 64) else { return (.error, nil) }
        guard case .object = doc.root else { return (.unreachable, nil) } // TryGetProperty on a non-object throws on Windows
        guard let v = doc.root.member("v") else { return (.error, nil) }
        guard case .number = v else { return (.unreachable, nil) }
        guard doc.int32(v) == Int32(Ponte.version) else { return (.error, nil) }
        var name = ""
        if let n = doc.root.member("name"), case .string = n {
            guard let units = doc.stringUnits(n) else { return (.unreachable, nil) }
            name = Ponte.cleanName(units)
        }
        return (.ok, name)
    }
}

/// Runs `work` with an overall deadline; nil if the deadline came first (the work is then cancelled
/// and abandoned, even if part of it, like getaddrinfo, cannot stop).
func withDeadline<T: Sendable>(_ seconds: TimeInterval, _ work: @escaping @Sendable () async -> T) async -> T? {
    let once = Once<T?>()
    return await withCheckedContinuation { (cont: CheckedContinuation<T?, Never>) in
        once.arm(cont)
        let task = Task { once.resume(await work()) }
        DispatchQueue.global().asyncAfter(deadline: .now() + seconds) {
            task.cancel()
            once.resume(nil)
        }
    }
}

private final class Once<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var cont: CheckedContinuation<T, Never>?
    private var pending: T?
    private var done = false

    func arm(_ c: CheckedContinuation<T, Never>) {
        lock.lock()
        defer { lock.unlock() }
        if done, let v = pending { pending = nil; c.resume(returning: v); return }
        cont = c
    }

    func resume(_ value: T) {
        lock.lock()
        defer { lock.unlock() }
        if done { return }
        done = true
        if let c = cont { cont = nil; c.resume(returning: value) } else { pending = value }
    }
}

private final class NoRedirects: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
