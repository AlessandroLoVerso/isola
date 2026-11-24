import Foundation
@testable import PonteCore
import XCTest

let exampleNow: Int64 = 1_795_400_000_000
let tinyPng = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00])

func clipJSON(_ fields: String) -> Data { Data(("{" + fields + "}").utf8) }

final class ParseClipTests: XCTestCase {
    func parse(_ s: String) -> Result<ClipPayload, Ponte.ParseError> { Ponte.parseClip(Data(s.utf8)) }
    func bad(_ s: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(parse(s).failureValue, .badJson, s, file: file, line: line)
    }

    let base = #""v":1,"id":"a","ts":1795400000000"#

    func testExamples() throws {
        let ex = try Examples.load()
        guard case .success(let text) = Ponte.parseClip(ex.all[0].body) else { return XCTFail() }
        XCTAssertEqual(text.kind, .text)
        XCTAssertEqual(text.ts, exampleNow)
        XCTAssertNotNil(text.text)
        guard case .success(let image) = Ponte.parseClip(ex.all[1].body) else { return XCTFail() }
        XCTAssertEqual(image.kind, .image)
        XCTAssertTrue(Ponte.isPng(image.png!))
    }

    func testMinimalText() {
        guard case .success(let c) = parse("{\(base),\"kind\":\"text\",\"text\":\"ciao\\r\\n\\u00e8\"}") else { return XCTFail() }
        XCTAssertEqual(c.id, "a")
        XCTAssertEqual(c.from, "")
        XCTAssertEqual(c.text, "ciao\r\nè")
    }

    func testRejected() {
        bad("")
        bad("[]")
        bad("\u{FEFF}{\(base),\"kind\":\"text\",\"text\":\"x\"}")              // BOM
        bad("{\(base),\"kind\":\"text\",\"text\":\"x\"} x")                     // trailing garbage
        bad("{\(base),\"kind\":\"text\",\"text\":\"x\",}")                       // trailing comma
        bad(#"{"v":1.0,"id":"a","ts":1795400000000,"kind":"text","text":"x"}"#)
        bad(#"{"v":2,"id":"a","ts":1795400000000,"kind":"text","text":"x"}"#)
        bad(#"{"v":"1","id":"a","ts":1795400000000,"kind":"text","text":"x"}"#)
        bad(#"{"id":"a","ts":1795400000000,"kind":"text","text":"x"}"#)
        bad(#"{"v":1,"id":"","ts":1795400000000,"kind":"text","text":"x"}"#)
        bad("{\"v\":1,\"id\":\"\(String(repeating: "a", count: 65))\",\"ts\":1795400000000,\"kind\":\"text\",\"text\":\"x\"}")
        bad(#"{"v":1,"id":1,"ts":1795400000000,"kind":"text","text":"x"}"#)
        bad(#"{"v":1,"id":"a","ts":1.5,"kind":"text","text":"x"}"#)
        bad(#"{"v":1,"id":"a","ts":1e3,"kind":"text","text":"x"}"#)
        bad(#"{"v":1,"id":"a","ts":"1795400000000","kind":"text","text":"x"}"#)
        bad("{\(base),\"from\":5,\"kind\":\"text\",\"text\":\"x\"}")
        bad("{\(base),\"kind\":\"file\",\"text\":\"x\"}")
        bad("{\(base),\"kind\":\"TEXT\",\"text\":\"x\"}")
        bad("{\(base),\"kind\":\"text\",\"text\":\"\"}")
        bad("{\(base),\"kind\":\"text\"}")
        bad("{\(base),\"kind\":\"text\",\"text\":\"\\ud800\"}")                // lone surrogate
        bad("{\(base),\"kind\":\"text\",\"text\":\"\\udc00\\ud800\"}")
        bad("{\(base),\"kind\":\"text\",\"text\":\"a\u{01}b\"}")                // raw control character
        bad("{\(base),\"kind\":\"text\",\"text\":\"\\x\"}")                     // bad escape
        bad("{\(base),\"kind\":\"image\",\"png\":\"!!!\"}")
        bad("{\(base),\"kind\":\"image\",\"png\":\"iVBORw0KGgo\"}")             // missing padding
        bad("{\(base),\"kind\":\"image\",\"png\":\"\(Data("not a png at all".utf8).base64EncodedString())\"}")
        bad("{\(base),\"kind\":\"image\",\"png\":\"\(Data(tinyPng.prefix(8)).base64EncodedString())\"}") // just the signature
        XCTAssertEqual(Ponte.parseClip(Data([0x7B, 0x22, 0xFF, 0x22, 0x3A, 0x31, 0x7D])).failureValue, .badJson) // invalid UTF-8
    }

    func testLoneSurrogateInUnreadMemberIsIgnored() {
        // Like JsonDocument: a string is only decoded when read.
        guard case .success = parse("{\(base),\"x\":\"\\ud800\",\"kind\":\"text\",\"text\":\"ok\"}") else { return XCTFail() }
    }

    func testDepth() {
        let deep8 = String(repeating: "[", count: 7) + String(repeating: "]", count: 7)
        let deep9 = String(repeating: "[", count: 8) + String(repeating: "]", count: 8)
        guard case .success = parse("{\(base),\"x\":\(deep8),\"kind\":\"text\",\"text\":\"ok\"}") else { return XCTFail("depth 8") }
        bad("{\(base),\"x\":\(deep9),\"kind\":\"text\",\"text\":\"ok\"}")
    }

    func testTooLarge() {
        let big = String(repeating: "a", count: Ponte.maxTextChars + 1)
        XCTAssertEqual(parse("{\(base),\"kind\":\"text\",\"text\":\"\(big)\"}").failureValue, .tooLarge)
        let max = String(repeating: "a", count: Ponte.maxTextChars)
        XCTAssertNotNil(try? parse("{\(base),\"kind\":\"text\",\"text\":\"\(max)\"}").get())
        // Limit is in UTF-16 units: 500 001 emoji = 1 000 002 units.
        let emoji = String(repeating: "😀", count: Ponte.maxTextChars / 2 + 1)
        XCTAssertEqual(parse("{\(base),\"kind\":\"text\",\"text\":\"\(emoji)\"}").failureValue, .tooLarge)
        var png = tinyPng
        png.append(Data(count: Ponte.maxPngBytes))
        XCTAssertEqual(parse("{\(base),\"kind\":\"image\",\"png\":\"\(png.base64EncodedString())\"}").failureValue, .tooLarge)
    }

    func testDuplicateKeysLastWins() {
        guard case .success(let c) = parse("{\(base),\"kind\":\"text\",\"text\":\"one\",\"text\":\"two\"}") else { return XCTFail() }
        XCTAssertEqual(c.text, "two")
        bad("{\(base),\"kind\":\"text\",\"text\":\"one\",\"text\":5}")
    }

    func testEscapedKeysAndBase64Whitespace() {
        let png = tinyPng.base64EncodedString()
        let spaced = png.prefix(4) + " \\r\\n\\t" + png.dropFirst(4) // JSON escapes: the decoded string has the whitespace
        guard case .success(let c) = parse("{\"\\u0076\":1,\"id\":\"a\",\"ts\":1795400000000,\"k\\u0069nd\":\"image\",\"png\":\"\(spaced)\"}") else { return XCTFail() }
        XCTAssertEqual(c.png, tinyPng)
    }

    func testFromIsCleaned() {
        guard case .success(let c) = parse("{\(base),\"from\":\"  PC\\u0007\\nALE  \",\"kind\":\"text\",\"text\":\"x\"}") else { return XCTFail() }
        XCTAssertEqual(c.from, "PCALE")
    }

    func testIntegerForms() {
        guard case .success(let c) = parse(#"{"v":1,"id":"a","ts":-0,"kind":"text","text":"x"}"#) else { return XCTFail() }
        XCTAssertEqual(c.ts, 0)
        bad(#"{"v":1,"id":"a","ts":01,"kind":"text","text":"x"}"#)
        bad(#"{"v":1,"id":"a","ts":9223372036854775808,"kind":"text","text":"x"}"#)
        bad(#"{"v":4294967297,"id":"a","ts":1,"kind":"text","text":"x"}"#)
    }

    func testWriterEscaping() {
        let body = Ponte.buildClipBody(id: "a", from: "Mac \"di\" Ale", ts: 1, kind: .text,
                                       text: "<b>&'è\n\t\u{0001}\u{2028}\u{00A0}😀\\", png: nil)
        XCTAssertEqual(String(decoding: body, as: UTF8.self),
                       #"{"v":1,"id":"a","from":"Mac \"di\" Ale","ts":1,"kind":"text","text":"<b>&'è\n\t\u0001\u2028\u00A0\uD83D\uDE00\\"}"#)
        guard case .success(let back) = Ponte.parseClip(body) else { return XCTFail() }
        XCTAssertEqual(back.text, "<b>&'è\n\t\u{0001}\u{2028}\u{00A0}😀\\")
    }
}

extension Result {
    var failureValue: Failure? { if case .failure(let f) = self { return f } else { return nil } }
}

final class HandlerTests: XCTestCase {
    var key: Data!
    var delivered: [ClipPayload] = []
    var paused = false
    var keyMissing = false

    override func setUpWithError() throws {
        key = try Examples.load().key
        delivered = []
        paused = false
        keyMissing = false
    }

    func handler() -> PonteHandler {
        PonteHandler(hooks: .init(key: { [unowned self] in keyMissing ? nil : key },
                                  name: { "MAC-DI-PROVA" },
                                  paused: { [unowned self] in paused },
                                  deliver: { [unowned self] in delivered.append($0) },
                                  now: { exampleNow }),
                     log: PonteLog())
    }

    func send(_ h: PonteHandler, path: String = "/clip", ts: String = "1795400000000", body: Data, sig: String? = nil) -> Reply {
        h.process(path: path, ts: ts, sig: sig ?? Ponte.sign(key: key, ts: ts, body: body), body: body)
    }

    func testExamplesGiveTheExpectedCodes() throws {
        let ex = try Examples.load()
        let h = handler()
        for e in ex.all {
            let r = h.process(path: e.path, ts: e.headers["X-Isola-Ts"], sig: e.headers["X-Isola-Sig"], body: e.body)
            XCTAssertEqual(r.status, e.expected, e.name)
        }
        XCTAssertEqual(delivered.count, 2)
        // Sent again: accepted, not delivered twice.
        for e in ex.all where e.path == "/clip" {
            XCTAssertEqual(h.process(path: e.path, ts: e.headers["X-Isola-Ts"], sig: e.headers["X-Isola-Sig"], body: e.body).status, 204)
        }
        XCTAssertEqual(delivered.count, 2)
    }

    func testPingReply() throws {
        let r = send(handler(), path: "/ping", body: Data())
        XCTAssertEqual(r.status, 200)
        XCTAssertEqual(r.json.map { String(decoding: $0, as: UTF8.self) }, #"{"v":1,"name":"MAC-DI-PROVA","app":"isola-ponte-mac"}"#)
    }

    func testAuthFailures() throws {
        let h = handler()
        let body = Ponte.buildClipBody(id: "x", from: "", ts: exampleNow, kind: .text, text: "x", png: nil)
        XCTAssertEqual(send(h, body: body, sig: String(repeating: "0", count: 64)).status, 401)
        XCTAssertEqual(h.process(path: "/clip", ts: "1795400000000", sig: nil, body: body).status, 401)
        XCTAssertEqual(h.process(path: "/clip", ts: nil, sig: Ponte.sign(key: key, ts: "", body: body), body: body).status, 401)
        XCTAssertEqual(send(h, ts: " 1795400000000", body: body).status, 401)
        keyMissing = true
        XCTAssertEqual(send(h, body: body).status, 401)
        XCTAssertTrue(delivered.isEmpty)
    }

    func testClockSkew() {
        let h = handler()
        for (offset, code) in [(-300_000, 204), (300_000, 204), (-300_001, 401), (300_001, 401)] as [(Int64, Int)] {
            let ts = exampleNow + offset
            let body = Ponte.buildClipBody(id: "id\(offset)", from: "", ts: ts, kind: .text, text: "x", png: nil)
            XCTAssertEqual(send(h, ts: String(ts), body: body).status, code, "\(offset)")
            XCTAssertEqual(send(h, path: "/ping", ts: String(ts), body: Data()).status, code == 204 ? 200 : 401)
        }
    }

    func testTsMismatchBetweenHeaderAndBody() {
        let body = Ponte.buildClipBody(id: "x", from: "", ts: exampleNow + 1, kind: .text, text: "x", png: nil)
        XCTAssertEqual(send(handler(), ts: "1795400000000", body: body).status, 401)
    }

    func testBadBodies() {
        let h = handler()
        XCTAssertEqual(send(h, body: Data("{}".utf8)).status, 400)
        var png = tinyPng
        png.append(Data(count: Ponte.maxPngBytes))
        let big = Ponte.buildClipBody(id: "x", from: "", ts: exampleNow, kind: .image, text: nil, png: png)
        XCTAssertEqual(send(h, body: big).status, 413)
    }

    func testPaused() throws {
        paused = true
        let h = handler()
        let body = Ponte.buildClipBody(id: "x", from: "", ts: exampleNow, kind: .text, text: "x", png: nil)
        XCTAssertEqual(send(h, body: body).status, 503)
        XCTAssertEqual(send(h, path: "/ping", body: Data()).status, 200)
        XCTAssertTrue(delivered.isEmpty)
        paused = false
        XCTAssertEqual(send(h, body: body).status, 204) // not remembered while paused
        XCTAssertEqual(delivered.count, 1)
    }

    func testRemembers200Ids() {
        let h = handler()
        func clip(_ i: Int) -> Data { Ponte.buildClipBody(id: "id\(i)", from: "", ts: exampleNow, kind: .text, text: "x", png: nil) }
        for i in 0...200 { XCTAssertEqual(send(h, body: clip(i)).status, 204) }
        XCTAssertEqual(delivered.count, 201)
        _ = send(h, body: clip(200)) // still remembered
        XCTAssertEqual(delivered.count, 201)
        _ = send(h, body: clip(0))   // forgotten (201 ids ago)
        XCTAssertEqual(delivered.count, 202)
    }

    func head(_ s: String) -> RequestHead? { HTTPHead.parse(ArraySlice(Array(s.utf8))) }

    func testPreCheck() {
        let h = handler()
        func code(_ s: String) -> Int? { head(s).flatMap { h.preCheck($0) } }
        XCTAssertNil(code("POST /clip HTTP/1.1\r\nContent-Length: 10"))
        XCTAssertNil(code("POST /clip?x=1 HTTP/1.1\r\nContent-Length: 10"))
        XCTAssertNil(code("GET /ping HTTP/1.1\r\nHost: x"))
        XCTAssertNil(code("GET /ping HTTP/1.1\r\nContent-Length: 0"))
        XCTAssertEqual(code("GET / HTTP/1.1"), 404)
        XCTAssertEqual(code("GET /CLIP HTTP/1.1"), 404)
        XCTAssertEqual(code("GET /clip HTTP/1.1"), 405)
        XCTAssertEqual(code("post /clip HTTP/1.1\r\nContent-Length: 1"), 405)
        XCTAssertEqual(code("POST /ping HTTP/1.1"), 405)
        XCTAssertEqual(code("POST /clip HTTP/1.1"), 411)
        XCTAssertEqual(code("POST /clip HTTP/1.1\r\nTransfer-Encoding: chunked\r\nContent-Length: 5"), 411)
        XCTAssertEqual(code("GET /ping HTTP/1.1\r\nTransfer-Encoding: identity"), 411)
        XCTAssertEqual(code("POST /clip HTTP/1.1\r\nContent-Length: \(Ponte.maxBodyBytes + 1)"), 413)
        XCTAssertNil(code("POST /clip HTTP/1.1\r\nContent-Length: \(Ponte.maxBodyBytes)"))
        XCTAssertEqual(code("GET /ping HTTP/1.1\r\nContent-Length: 1"), 400)
    }

    func testHeadParsing() {
        let h = head("POST /clip?a=b HTTP/1.1\r\ncontent-LENGTH:  12 \r\nX-Isola-Ts:1\r\nx-isola-ts: 2\r\nExpect: 100-Continue")
        XCTAssertEqual(h?.method, "POST")
        XCTAssertEqual(h?.path, "/clip")
        XCTAssertEqual(h?.contentLength, 12)
        XCTAssertEqual(h?.header("X-Isola-Ts"), "1")
        XCTAssertEqual(h?.expectContinue, true)
        XCTAssertNotNil(head("POST /clip HTTP/1.1\r\nContent-Length: 5\r\nContent-Length: 5"))
        XCTAssertNotNil(head("GET /ping HTTP/1.0"))
        for bad in [
            "GET /ping", "GET  /ping HTTP/1.1", "GET /ping HTTP/2", "GET /ping HTTP/1.1 x",
            "GET /ping HTTP/1.1\r\n: x", "GET /ping HTTP/1.1\r\nNoColon",
            "POST /clip HTTP/1.1\r\nContent-Length: 5\r\nContent-Length: 6",
            "POST /clip HTTP/1.1\r\nContent-Length: +5", "POST /clip HTTP/1.1\r\nContent-Length: 5 5",
            "POST /clip HTTP/1.1\r\nContent-Length: ", "POST /clip HTTP/1.1\r\nContent-Length: 99999999999999999999",
        ] {
            XCTAssertNil(head(bad), bad)
        }
    }

    func testSourceAllowed() {
        let h = handler()
        let ts = IPAddr("100.69.76.44"), lan = IPAddr("192.168.1.5"), lo = IPAddr("127.0.0.1")
        XCTAssertTrue(h.sourceAllowed(remote: IPAddr("100.101.1.2"), local: ts))
        XCTAssertTrue(h.sourceAllowed(remote: IPAddr("::ffff:100.101.1.2"), local: ts))
        XCTAssertFalse(h.sourceAllowed(remote: lan, local: ts))
        XCTAssertFalse(h.sourceAllowed(remote: IPAddr("100.101.1.2"), local: lan))
        XCTAssertFalse(h.sourceAllowed(remote: lo, local: lo))
        XCTAssertFalse(h.sourceAllowed(remote: nil, local: ts))
    }

    func testLogNeverCarriesContent() throws {
        let log = PonteLog()
        var lines: [String] = []
        log.sink = { lines.append($0) }
        let h = PonteHandler(hooks: .init(key: { self.key }, name: { "" }, paused: { false }, deliver: { _ in }, now: { exampleNow }), log: log)
        let body = Ponte.buildClipBody(id: "x", from: "SEGRETO", ts: exampleNow, kind: .text, text: "SEGRETO", png: nil)
        _ = send(h, body: body, sig: String(repeating: "0", count: 64))
        _ = send(h, body: body, sig: String(repeating: "1", count: 64)) // same reason within a minute: not repeated
        XCTAssertEqual(lines, ["condivisione: errore firma non valida"])
    }

    func testReplyBytes() {
        XCTAssertEqual(String(decoding: Reply(204).bytes, as: UTF8.self), "HTTP/1.1 204 No Content\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")
        XCTAssertEqual(String(decoding: Reply(200, json: Data("{}".utf8)).bytes, as: UTF8.self),
                       "HTTP/1.1 200 OK\r\nContent-Type: application/json; charset=utf-8\r\nContent-Length: 2\r\nConnection: close\r\n\r\n{}")
    }

    func testReadPing() {
        XCTAssertEqual(PonteClient.readPing(Data(#"{"v":1,"name":"PC-DI-PROVA","app":"isola-windows"}"#.utf8)).0, .ok)
        XCTAssertEqual(PonteClient.readPing(Data(#"{"v":1,"name":"PC-DI-PROVA","app":"isola-windows"}"#.utf8)).1, "PC-DI-PROVA")
        XCTAssertEqual(PonteClient.readPing(Data(#"{"v":1}"#.utf8)).1, "")
        XCTAssertEqual(PonteClient.readPing(Data(#"{"v":2,"name":"x"}"#.utf8)).0, .error)
        XCTAssertEqual(PonteClient.readPing(Data(#"{"name":"x"}"#.utf8)).0, .error)
        XCTAssertEqual(PonteClient.readPing(Data(#"{"v":"1"}"#.utf8)).0, .unreachable)
        XCTAssertEqual(PonteClient.readPing(Data("[1]".utf8)).0, .unreachable)
        XCTAssertEqual(PonteClient.readPing(Data("not json".utf8)).0, .error)
        XCTAssertEqual(PonteClient.readPing(Data(("{\"v\":1,\"pad\":\"" + String(repeating: "a", count: 4100) + "\"}").utf8)).0, .error)
    }
}
