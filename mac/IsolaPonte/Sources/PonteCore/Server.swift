import Darwin
import Foundation

/// The listening side of docs/appunti-condivisi.md: a TCP socket bound to one address (this Mac's
/// Tailscale IPv4) running a minimal HTTP/1.1 server, one request per connection, Content-Length
/// bodies only. At most 2 connections at once (the third gets 503), 10 s per read, 60 s per request.
///
/// BSD sockets, not NWListener: an NWListener never sees connections that arrive through the
/// Tailscale tunnel (utun) on this Mac (the SYN is dropped), while a plain socket does.
public final class PonteServer: @unchecked Sendable {
    public static let maxConnections = 2

    private let bind: IPAddr
    private let port: UInt16
    private let handler: PonteHandler
    private let queue = DispatchQueue(label: "it.isola.ponte.listener")
    private var source: DispatchSourceRead?
    private var active = 0
    private var stopped = false

    public var readTimeout: TimeInterval = 10
    public var requestTimeout: TimeInterval = 60

    /// port 0 picks a free port (tests).
    public init(bind: IPAddr, port: UInt16 = Ponte.port, handler: PonteHandler) {
        self.bind = bind
        self.port = port
        self.handler = handler
    }

    /// Starts listening. `done` (on a background queue) gets the bound port, or a short Italian reason.
    public func start(_ done: @escaping @Sendable (Result<UInt16, PonteServerError>) -> Void) {
        queue.async { [self] in
            switch open() {
            case .failure(let e): done(.failure(e))
            case .success(let (fd, bound)):
                let src = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
                src.setEventHandler { [weak self] in self?.acceptAll(fd) }
                src.setCancelHandler { Darwin.close(fd) }
                source = src
                src.resume()
                done(.success(bound))
            }
        }
    }

    public func stop() {
        queue.async { [self] in
            stopped = true
            source?.cancel()
            source = nil
        }
    }

    private func open() -> Result<(Int32, UInt16), PonteServerError> {
        let family = bind.isV4 ? AF_INET : AF_INET6
        let fd = socket(family, SOCK_STREAM, IPPROTO_TCP)
        if fd < 0 { return .failure(PonteServerError(errno: errno)) }
        var one: Int32 = 1
        // Lets the app listen again right after a restart (old connections in TIME_WAIT); on macOS
        // it does not let two sockets listen on the same address and port (that is SO_REUSEPORT).
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, socklen_t(MemoryLayout<Int32>.size))
        var storage = sockaddr_storage()
        let len = SocketAddress.fill(&storage, bind, port)
        let r = withUnsafePointer(to: &storage) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, len) } }
        if r != 0 || listen(fd, 16) != 0 {
            let e = errno
            Darwin.close(fd)
            return .failure(PonteServerError(errno: e))
        }
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        let bound = SocketAddress.local(fd)?.port ?? port
        return .success((fd, bound))
    }

    private func acceptAll(_ listenFd: Int32) {
        while true {
            let fd = accept(listenFd, nil, nil)
            if fd < 0 { return } // EAGAIN: nothing more for now
            Socket.prepare(fd)
            if stopped { Darwin.close(fd); continue }
            if active >= Self.maxConnections {
                Thread.detachNewThread { Socket.replyAndClose(fd, Reply.busy, drainFor: 2) }
                continue
            }
            active += 1
            let session = Session(fd: fd, handler: handler, readTimeout: readTimeout, requestTimeout: requestTimeout)
            Thread.detachNewThread { [weak self] in
                session.run()
                self?.queue.async { self?.active -= 1 }
            }
        }
    }
}

public struct PonteServerError: Error, Equatable {
    /// "porta occupata", "indirizzo non disponibile", "rete non disponibile".
    public let reason: String

    init(errno code: Int32) {
        switch code {
        case EADDRINUSE, EACCES: reason = "porta occupata"
        case EADDRNOTAVAIL: reason = "indirizzo non disponibile"
        default: reason = "rete non disponibile"
        }
    }
}

enum SocketAddress {
    static func fill(_ s: inout sockaddr_storage, _ ip: IPAddr, _ port: UInt16) -> socklen_t {
        withUnsafeMutablePointer(to: &s) { p -> socklen_t in
            if ip.isV4 {
                return p.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { a in
                    a.pointee.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
                    a.pointee.sin_family = sa_family_t(AF_INET)
                    a.pointee.sin_port = port.bigEndian
                    withUnsafeMutableBytes(of: &a.pointee.sin_addr) { $0.copyBytes(from: ip.bytes) }
                    return socklen_t(MemoryLayout<sockaddr_in>.size)
                }
            }
            return p.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { a in
                a.pointee.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
                a.pointee.sin6_family = sa_family_t(AF_INET6)
                a.pointee.sin6_port = port.bigEndian
                withUnsafeMutableBytes(of: &a.pointee.sin6_addr) { $0.copyBytes(from: ip.bytes) }
                return socklen_t(MemoryLayout<sockaddr_in6>.size)
            }
        }
    }

    static func local(_ fd: Int32) -> (ip: IPAddr, port: UInt16)? { read(fd, getsockname) }
    static func remote(_ fd: Int32) -> (ip: IPAddr, port: UInt16)? { read(fd, getpeername) }

    private static func read(_ fd: Int32, _ get: (Int32, UnsafeMutablePointer<sockaddr>, UnsafeMutablePointer<socklen_t>) -> Int32) -> (ip: IPAddr, port: UInt16)? {
        var s = sockaddr_storage()
        var len = socklen_t(MemoryLayout<sockaddr_storage>.size)
        let ok = withUnsafeMutablePointer(to: &s) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { get(fd, $0, &len) } } == 0
        guard ok else { return nil }
        return withUnsafePointer(to: &s) { p in
            switch Int32(p.pointee.ss_family) {
            case AF_INET:
                return p.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { a in
                    IPAddr(bytes: withUnsafeBytes(of: a.pointee.sin_addr) { Array($0) }).map { ($0, UInt16(bigEndian: a.pointee.sin_port)) }
                }
            case AF_INET6:
                return p.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { a in
                    IPAddr(bytes: withUnsafeBytes(of: a.pointee.sin6_addr) { Array($0) }).map { ($0, UInt16(bigEndian: a.pointee.sin6_port)) }
                }
            default:
                return nil
            }
        }
    }
}

/// Blocking I/O on an accepted socket, with timeouts set on the socket.
enum Socket {
    static func prepare(_ fd: Int32) {
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) & ~O_NONBLOCK) // accepted sockets inherit it
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, socklen_t(MemoryLayout<Int32>.size))
        setTimeout(fd, SO_SNDTIMEO, 10)
    }

    static func setTimeout(_ fd: Int32, _ option: Int32, _ seconds: TimeInterval) {
        let s = max(seconds, 0.001)
        var tv = timeval(tv_sec: Int(s), tv_usec: Int32((s - s.rounded(.down)) * 1_000_000))
        setsockopt(fd, SOL_SOCKET, option, &tv, socklen_t(MemoryLayout<timeval>.size))
    }

    @discardableResult
    static func writeAll(_ fd: Int32, _ data: Data) -> Bool {
        data.withUnsafeBytes { raw -> Bool in
            guard let base = raw.baseAddress else { return true }
            var off = 0
            while off < raw.count {
                let n = send(fd, base + off, raw.count - off, 0)
                if n < 0 && errno == EINTR { continue }
                if n <= 0 { return false }
                off += n
            }
            return true
        }
    }

    /// Writes the reply, closes our side, then reads what the peer still sends for up to `drainFor`
    /// seconds (at most 14 MiB), so it can read the reply before the socket goes away (closing with
    /// unread input would reset the connection).
    static func replyAndClose(_ fd: Int32, _ bytes: Data, drainFor: TimeInterval) {
        defer { Darwin.close(fd) }
        guard writeAll(fd, bytes) else { return }
        shutdown(fd, SHUT_WR)
        let deadline = Date().addingTimeInterval(drainFor)
        var drained = 0
        var buf = [UInt8](repeating: 0, count: 16 * 1024)
        while drained < Ponte.maxBodyBytes {
            let left = deadline.timeIntervalSinceNow
            if left <= 0 { return }
            setTimeout(fd, SO_RCVTIMEO, left)
            let n = recv(fd, &buf, buf.count, 0)
            if n < 0 && errno == EINTR { continue }
            if n <= 0 { return }
            drained += n
        }
    }
}

/// One connection, one request.
private final class Session: @unchecked Sendable {
    private let fd: Int32
    private let handler: PonteHandler
    private let readTimeout: TimeInterval
    private let deadline: Date

    init(fd: Int32, handler: PonteHandler, readTimeout: TimeInterval, requestTimeout: TimeInterval) {
        self.fd = fd
        self.handler = handler
        self.readTimeout = readTimeout
        self.deadline = Date().addingTimeInterval(requestTimeout)
    }

    func run() {
        guard handler.sourceAllowed(remote: SocketAddress.remote(fd)?.ip, local: SocketAddress.local(fd)?.ip) else {
            return finish(Reply(403))
        }

        // Request line and headers: at most 16 KiB.
        var buf = [UInt8](repeating: 0, count: Ponte.maxHeaderBytes)
        var filled = 0
        var headEnd: Int?
        while true {
            if let end = HTTPHead.endOfHead(buf, count: filled) { headEnd = end; break }
            if filled == buf.count { return finish(Reply(400)) }
            let n = buf.withUnsafeMutableBytes { read(into: $0.baseAddress! + filled, max: $0.count - filled) }
            if n <= 0 { Darwin.close(fd); return } // closed early or timed out: nothing to answer
            filled += n
        }
        guard let end = headEnd, let head = HTTPHead.parse(buf[0..<end]) else { return finish(Reply(400)) }
        if let status = handler.preCheck(head) { return finish(Reply(status)) }

        let length = Int(head.contentLength ?? 0)
        if head.expectContinue, length > 0 { Socket.writeAll(fd, Reply.continue100) }
        var body = Data(capacity: length)
        let have = min(length, filled - (end + 4))
        if have > 0 { body.append(contentsOf: buf[(end + 4)..<(end + 4 + have)]) }
        var chunk = [UInt8](repeating: 0, count: 64 * 1024)
        while body.count < length {
            let n = chunk.withUnsafeMutableBytes { read(into: $0.baseAddress!, max: min($0.count, length - body.count)) }
            if n <= 0 { Darwin.close(fd); return }
            body.append(contentsOf: chunk[0..<n])
        }
        finish(handler.process(path: head.path, ts: head.header(Ponte.tsHeader), sig: head.header(Ponte.sigHeader), body: body))
    }

    /// One read with the per-read timeout, within the whole-request deadline. 0 = closed or timed out.
    private func read(into p: UnsafeMutableRawPointer, max: Int) -> Int {
        while true {
            let left = deadline.timeIntervalSinceNow
            if left <= 0 { return 0 }
            Socket.setTimeout(fd, SO_RCVTIMEO, min(readTimeout, left))
            let n = recv(fd, p, max, 0)
            if n < 0 && errno == EINTR { continue }
            return n < 0 ? 0 : n
        }
    }

    private func finish(_ r: Reply) { Socket.replyAndClose(fd, r.bytes, drainFor: 2) }
}
