import Darwin
import Foundation
@testable import PonteCore
import XCTest

/// A blocking BSD-socket client, to see the exact bytes the server writes.
final class RawClient {
    let fd: Int32

    init(port: UInt16) throws {
        fd = socket(AF_INET, SOCK_STREAM, 0)
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        var tv = timeval(tv_sec: 5, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        let r = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        if r != 0 { close(fd); throw NSError(domain: "connect", code: Int(errno)) }
    }

    deinit { close(fd) }

    func write(_ d: Data) {
        d.withUnsafeBytes { p in
            var off = 0
            while off < d.count {
                let n = Darwin.send(fd, p.baseAddress! + off, d.count - off, 0)
                if n <= 0 { return }
                off += n
            }
        }
    }

    func write(_ s: String) { write(Data(s.utf8)) }

    /// Reads until `until` bytes arrived, EOF, or the 5 s timeout.
    func read(until: Int = .max) -> Data {
        var out = Data()
        var buf = [UInt8](repeating: 0, count: 65536)
        while out.count < until {
            let n = recv(fd, &buf, buf.count, 0)
            if n <= 0 { break }
            out.append(contentsOf: buf[0..<n])
        }
        return out
    }

    func readText(until: Int = .max) -> String { String(decoding: read(until: until), as: UTF8.self) }
}

final class ServerTests: XCTestCase {
    var server: PonteServer!
    var port: UInt16 = 0
    var key: Data!
    let deliveredLock = NSLock()
    var delivered: [ClipPayload] = []
    var paused = false

    func startServer(allowLoopback: Bool = true) throws {
        key = try Examples.load().key
        let handler = PonteHandler(hooks: .init(key: { [unowned self] in key },
                                                name: { "MAC-DI-PROVA" },
                                                paused: { [unowned self] in paused },
                                                deliver: { [unowned self] c in deliveredLock.lock(); delivered.append(c); deliveredLock.unlock() },
                                                now: { exampleNow }),
                                   allowLoopbackForTests: allowLoopback, log: PonteLog())
        server = PonteServer(bind: IPAddr("127.0.0.1")!, port: 0, handler: handler)
        let ready = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var result: Result<UInt16, PonteServerError>?
        server.start { r in result = r; ready.signal() }
        _ = ready.wait(timeout: .now() + 5)
        port = try XCTUnwrap(try result?.get())
        XCTAssertNotEqual(port, 0)
    }

    override func tearDown() {
        server?.stop()
        server = nil
    }

    func request(_ e: Examples.Example) -> Data {
        var s = "\(e.method) \(e.path) HTTP/1.1\r\nHost: x\r\n"
        for (k, v) in e.headers.sorted(by: { $0.key < $1.key }) { s += "\(k): \(v)\r\n" }
        if e.headers["Content-Length"] == nil && e.method == "POST" { s += "Content-Length: \(e.body.count)\r\n" }
        s += "\r\n"
        var d = Data(s.utf8)
        d.append(e.body)
        return d
    }

    func testExamplesOverTheWire() throws {
        try startServer()
        let ex = try Examples.load()
        for e in ex.all {
            let c = try RawClient(port: port)
            c.write(request(e))
            let reply = c.readText()
            if e.path == "/ping" {
                let json = #"{"v":1,"name":"MAC-DI-PROVA","app":"isola-ponte-mac"}"#
                XCTAssertEqual(reply, "HTTP/1.1 200 OK\r\nContent-Type: application/json; charset=utf-8\r\nContent-Length: \(json.utf8.count)\r\nConnection: close\r\n\r\n" + json)
            } else {
                XCTAssertEqual(reply, "HTTP/1.1 204 No Content\r\nContent-Length: 0\r\nConnection: close\r\n\r\n", e.name)
            }
        }
        deliveredLock.lock()
        XCTAssertEqual(delivered.map(\.kind), [.text, .image])
        deliveredLock.unlock()
    }

    func testBodyInSmallPieces() throws {
        try startServer()
        let e = try Examples.load().all[1]
        let c = try RawClient(port: port)
        let req = request(e)
        var i = 0
        while i < req.count {
            c.write(req.subdata(in: i..<min(i + 997, req.count)))
            i += 997
            usleep(200)
        }
        XCTAssertTrue(c.readText().hasPrefix("HTTP/1.1 204 No Content\r\n"))
    }

    func testExpectContinue() throws {
        try startServer()
        let e = try Examples.load().all[0]
        let c = try RawClient(port: port)
        var head = "POST /clip HTTP/1.1\r\nExpect: 100-continue\r\nContent-Length: \(e.body.count)\r\n"
        head += "X-Isola-Ts: \(e.headers["X-Isola-Ts"]!)\r\nX-Isola-Sig: \(e.headers["X-Isola-Sig"]!)\r\n\r\n"
        c.write(head)
        XCTAssertEqual(c.readText(until: Reply.continue100.count), "HTTP/1.1 100 Continue\r\n\r\n")
        c.write(e.body)
        XCTAssertTrue(c.readText().hasPrefix("HTTP/1.1 204 No Content\r\n"))
    }

    func testEarlyRefusals() throws {
        try startServer()
        let cases: [(String, Int)] = [
            ("GET /nope HTTP/1.1\r\n\r\n", 404),
            ("GET /clip HTTP/1.1\r\n\r\n", 405),
            ("POST /clip HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n", 411),
            ("POST /clip HTTP/1.1\r\n\r\n", 411),
            ("POST /clip HTTP/1.1\r\nContent-Length: \(Ponte.maxBodyBytes + 1)\r\n\r\n", 413),
            ("GET /ping HTTP/1.1\r\nContent-Length: 3\r\n\r\nabc", 400),
            ("BROKEN\r\n\r\n", 400),
            ("GET /ping HTTP/1.1\r\n\r\n", 401),
        ]
        for (req, code) in cases {
            let c = try RawClient(port: port)
            c.write(req)
            XCTAssertEqual(c.readText(), "HTTP/1.1 \(code) \(Reply.reason(code))\r\nContent-Length: 0\r\nConnection: close\r\n\r\n", req)
        }
    }

    func testHeadTooLarge() throws {
        try startServer()
        let c = try RawClient(port: port)
        c.write("GET /ping HTTP/1.1\r\nX-Pad: " + String(repeating: "a", count: 17 * 1024))
        XCTAssertTrue(c.readText().hasPrefix("HTTP/1.1 400 Bad Request\r\n"))
    }

    func testLoopbackRefusedWhenNotAllowed() throws {
        try startServer(allowLoopback: false)
        let c = try RawClient(port: port)
        c.write("GET /ping HTTP/1.1\r\n\r\n")
        XCTAssertEqual(c.readText(), "HTTP/1.1 403 Forbidden\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")
    }

    func testThirdConnectionIsBusy() throws {
        try startServer()
        let a = try RawClient(port: port), b = try RawClient(port: port)
        a.write("POST /clip HTTP/1.1\r\n")   // both stay open, waiting for the rest
        b.write("POST /clip HTTP/1.1\r\n")
        usleep(300_000)
        let third = try RawClient(port: port)
        XCTAssertEqual(third.readText(), "HTTP/1.1 503 Service Unavailable\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")
    }

    // MARK: - Client against the server

    func testClientSendAndPing() async throws {
        try startServerAsync()
        let ex = try Examples.load()
        let client = PonteClient()
        let ts = Ponte.nowMs()
        // The handler's clock is fixed at the example time; the client uses the real clock for ping.
        // So: the clip uses the example ts and must be accepted; the ping must come back "wrong key".
        let body = Ponte.buildClipBody(id: Ponte.newId(), from: "Mac", ts: exampleNow, kind: .text, text: "ciao", png: nil)
        let sent = await client.send(peer: "127.0.0.1", key: ex.key, body: body, ts: exampleNow, selfAddresses: [],
                                     port: port, allowLoopbackForTests: true)
        XCTAssertEqual(sent, .ok)
        let wrong = await client.send(peer: "127.0.0.1", key: Data(repeating: 7, count: 20), body: body, ts: exampleNow,
                                      selfAddresses: [], port: port, allowLoopbackForTests: true)
        XCTAssertEqual(wrong, .wrongKey)
        _ = ts
        let (pinged, _) = await client.ping(peer: "127.0.0.1", key: ex.key, selfAddresses: [], port: port, allowLoopbackForTests: true)
        XCTAssertEqual(pinged, .wrongKey) // skew vs the fixed clock
        paused = true
        let refused = await client.send(peer: "127.0.0.1", key: ex.key,
                                        body: Ponte.buildClipBody(id: Ponte.newId(), from: "", ts: exampleNow, kind: .text, text: "x", png: nil),
                                        ts: exampleNow, selfAddresses: [], port: port, allowLoopbackForTests: true)
        XCTAssertEqual(refused, .refused)
        let selfHit = await client.send(peer: "127.0.0.1", key: ex.key, body: body, ts: exampleNow,
                                        selfAddresses: [IPAddr("127.0.0.1")!], port: port, allowLoopbackForTests: true)
        XCTAssertEqual(selfHit, .selfAddress)
    }

    func testClientPingWithLiveClock() async throws {
        key = try Examples.load().key
        let handler = PonteHandler(hooks: .init(key: { [unowned self] in key }, name: { "MAC-DI-PROVA" }, paused: { false }, deliver: { _ in }),
                                   allowLoopbackForTests: true, log: PonteLog())
        server = PonteServer(bind: IPAddr("127.0.0.1")!, port: 0, handler: handler)
        port = try await withCheckedThrowingContinuation { cont in server.start { cont.resume(with: $0.mapError { $0 as Error }) } }
        let (r, name) = await PonteClient().ping(peer: "127.0.0.1", key: key, selfAddresses: [], port: port, allowLoopbackForTests: true)
        XCTAssertEqual(r, .ok)
        XCTAssertEqual(name, "MAC-DI-PROVA")
    }

    func testClientUnreachable() async throws {
        let k = Data(repeating: 1, count: 20)
        // Nothing listens on port 9 of loopback; a name that is not Tailscale is refused before connecting.
        let r1 = await PonteClient().send(peer: "127.0.0.1", key: k, body: Data("{}".utf8), ts: 0, selfAddresses: [], port: 9, allowLoopbackForTests: true)
        XCTAssertEqual(r1, .unreachable)
        let r2 = await PonteClient().send(peer: "192.168.1.1", key: k, body: Data("{}".utf8), ts: 0, selfAddresses: [])
        XCTAssertEqual(r2, .unreachable)
    }

    func startServerAsync() throws { try startServer() }

    func testPortInUse() throws {
        try startServer()
        let other = PonteServer(bind: IPAddr("127.0.0.1")!, port: port,
                                handler: PonteHandler(hooks: .init(key: { nil }, name: { "" }, paused: { false }, deliver: { _ in }), log: PonteLog()))
        let done = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var result: Result<UInt16, PonteServerError>?
        other.start { result = $0; done.signal() }
        _ = done.wait(timeout: .now() + 5)
        other.stop()
        XCTAssertEqual(result.flatMap { if case .failure(let e) = $0 { return e.reason } else { return nil } }, "porta occupata")
    }

    /// Regression: the listener must see connections that come through the Tailscale tunnel
    /// (NWListener did not). Here the "other computer" is this Mac, talking to its own 100.x address.
    func testListensOnTailscaleAddress() async throws {
        guard let ts = LocalAddresses.tailscaleIPv4() else { throw XCTSkip("Tailscale non attivo") }
        let k = try Examples.load().key
        let handler = PonteHandler(hooks: .init(key: { k }, name: { "MAC-DI-PROVA" }, paused: { false }, deliver: { _ in }), log: PonteLog())
        server = PonteServer(bind: ts, port: 0, handler: handler)
        let bound: UInt16 = try await withCheckedThrowingContinuation { cont in server.start { cont.resume(with: $0.mapError { $0 as Error }) } }
        let (r, name) = await PonteClient().ping(peer: ts.description, key: k, selfAddresses: [], port: bound)
        XCTAssertEqual(r, .ok)
        XCTAssertEqual(name, "MAC-DI-PROVA")
    }
}
