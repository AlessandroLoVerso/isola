import Foundation
@testable import PonteCore
import XCTest

/// docs/appunti-condivisi.esempio.json, read straight from the repo.
struct Examples {
    struct Example {
        let name: String
        let method: String
        let path: String
        let headers: [String: String]
        let body: Data
        let bodyText: String
        let signed: Data
        let expected: Int
        let responseBody: String?
    }

    let keyText: String
    let keyHex: String
    let all: [Example]

    static let url: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("docs/appunti-condivisi.esempio.json")

    static func load() throws -> Examples {
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let key = try XCTUnwrap(root["chiave_di_prova"] as? [String: Any])
        let list = try XCTUnwrap(root["esempi"] as? [[String: Any]])
        let all = try list.map { e -> Example in
            Example(name: try XCTUnwrap(e["nome"] as? String),
                    method: try XCTUnwrap(e["metodo"] as? String),
                    path: try XCTUnwrap(e["percorso"] as? String),
                    headers: try XCTUnwrap(e["intestazioni"] as? [String: String]),
                    body: try XCTUnwrap(Data(base64Encoded: try XCTUnwrap(e["corpo_base64"] as? String))),
                    bodyText: try XCTUnwrap(e["corpo"] as? String),
                    signed: try XCTUnwrap(Data(base64Encoded: try XCTUnwrap(e["messaggio_firmato_base64"] as? String))),
                    expected: try XCTUnwrap(e["risposta_attesa"] as? Int),
                    responseBody: e["corpo_risposta"] as? String)
        }
        return Examples(keyText: try XCTUnwrap(key["testo"] as? String), keyHex: try XCTUnwrap(key["byte_hex"] as? String), all: all)
    }

    var key: Data { Data(hex: keyHex) }
}

extension Data {
    init(hex: String) {
        var bytes = [UInt8]()
        var it = hex.makeIterator()
        while let a = it.next(), let b = it.next() { bytes.append(UInt8(String([a, b]), radix: 16)!) }
        self.init(bytes)
    }

    var hex: String { map { String(format: "%02x", $0) }.joined() }
}

final class Base32Tests: XCTestCase {
    /// RFC 4648 section 10, without the padding (the protocol never pads).
    let vectors: [(String, String)] = [
        ("", ""), ("f", "MY"), ("fo", "MZXQ"), ("foo", "MZXW6"), ("foob", "MZXW6YQ"),
        ("fooba", "MZXW6YTB"), ("foobar", "MZXW6YTBOI"),
    ]

    func testRfc4648Vectors() {
        for (plain, encoded) in vectors {
            XCTAssertEqual(Ponte.base32Encode(Data(plain.utf8)), encoded, plain)
        }
    }

    func testDecodeRoundTripOn40BitMultiples() {
        // Without padding, only lengths that are multiples of 5 bytes decode back exactly.
        XCTAssertEqual(Ponte.base32Decode("MZXW6YTB"), Data("fooba".utf8))
        XCTAssertEqual(Ponte.base32Decode(""), Data())
        let random = Ponte.generateKey()
        XCTAssertEqual(Ponte.base32Decode(Ponte.base32Encode(random)), random)
    }

    func testDecodeIsStrict() {
        XCTAssertNil(Ponte.base32Decode("mzxw6ytb"))   // lowercase is for parseKey only
        XCTAssertNil(Ponte.base32Decode("MZXW6YT1"))   // 1 is not in the alphabet
        XCTAssertNil(Ponte.base32Decode("MZXW6YT="))   // no padding
    }

    func testTestKey() throws {
        let ex = try Examples.load()
        XCTAssertEqual(Ponte.formatKey(ex.key), ex.keyText)
        XCTAssertEqual(Ponte.parseKey(ex.keyText), ex.key)
    }

    func testParseKeyIgnoresCaseSpacesAndDashes() throws {
        let ex = try Examples.load()
        XCTAssertEqual(Ponte.parseKey("aaaq eaye-auda\tocaj\nbifq\u{00A0}ydio b4ib ceqt  "), ex.key)
        XCTAssertEqual(Ponte.parseKey(ex.keyText.replacingOccurrences(of: "-", with: "")), ex.key)
    }

    func testParseKeyRejects() {
        XCTAssertNil(Ponte.parseKey(nil))
        XCTAssertNil(Ponte.parseKey("   "))
        XCTAssertNil(Ponte.parseKey("AAAQ-EAYE-AUDA-OCAJ-BIFQ-YDIO-B4IB-CEQ"))     // 31
        XCTAssertNil(Ponte.parseKey("AAAQ-EAYE-AUDA-OCAJ-BIFQ-YDIO-B4IB-CEQTA"))   // 33
        XCTAssertNil(Ponte.parseKey("AAAQ-EAYE-AUDA-OCAJ-BIFQ-YDIO-B4IB-CEQ1"))    // 1
        XCTAssertNil(Ponte.parseKey("AAAQ-EAYE-AUDA-OCAJ-BIFQ-YDIO-B4IB-CEQ0"))    // 0
        XCTAssertNil(Ponte.parseKey("AAAQ_EAYE_AUDA_OCAJ_BIFQ_YDIO_B4IB_CEQT"))    // _ is not ignored
    }

    func testGeneratedKeyFormat() {
        let k = Ponte.generateKey()
        XCTAssertEqual(k.count, 20)
        let text = Ponte.formatKey(k)
        XCTAssertEqual(text.count, 39)
        XCTAssertEqual(text.split(separator: "-").count, 8)
        XCTAssertTrue(text.split(separator: "-").allSatisfy { $0.count == 4 })
        XCTAssertEqual(Ponte.parseKey(text), k)
    }
}

final class SignatureTests: XCTestCase {
    /// Every example: same signed bytes, same signature as Isola for Windows.
    func testEveryExampleSignatureMatches() throws {
        let ex = try Examples.load()
        XCTAssertEqual(ex.all.map(\.name), ["testo", "immagine", "ping"])
        for e in ex.all {
            let ts = try XCTUnwrap(e.headers["X-Isola-Ts"])
            let sig = try XCTUnwrap(e.headers["X-Isola-Sig"])
            XCTAssertEqual(Data(e.bodyText.utf8), e.body, e.name)
            var message = Data(ts.utf8)
            message.append(0x0A)
            message.append(e.body)
            XCTAssertEqual(message, e.signed, e.name)
            XCTAssertEqual(Ponte.sign(key: ex.key, ts: ts, body: e.body), sig, e.name)
            XCTAssertTrue(Ponte.verify(key: ex.key, ts: ts, body: e.body, sigHex: sig), e.name)
            XCTAssertTrue(Ponte.verify(key: ex.key, ts: ts, body: e.body, sigHex: sig.uppercased()), e.name)
            if let cl = e.headers["Content-Length"] { XCTAssertEqual(Int(cl), e.body.count, e.name) }
        }
    }

    /// The Mac writes the same bytes Windows wrote for the same clip.
    func testBuildClipBodyMatchesWindowsBytes() throws {
        let ex = try Examples.load()
        for e in ex.all where e.path == "/clip" {
            guard case .success(let clip) = Ponte.parseClip(e.body) else { return XCTFail(e.name) }
            let rebuilt = Ponte.buildClipBody(id: clip.id, from: clip.from, ts: clip.ts, kind: clip.kind, text: clip.text, png: clip.png)
            XCTAssertEqual(rebuilt, e.body, e.name)
        }
    }

    func testPingResponseShape() throws {
        let ex = try Examples.load()
        let ping = try XCTUnwrap(ex.all.first { $0.name == "ping" })
        let windows = try XCTUnwrap(ping.responseBody)
        XCTAssertEqual(String(decoding: Ponte.buildPingResponse(name: "PC-DI-PROVA"), as: UTF8.self),
                       windows.replacingOccurrences(of: "isola-windows", with: "isola-ponte-mac"))
    }

    func testVerifyRejects() throws {
        let ex = try Examples.load()
        let e = ex.all[0]
        let ts = e.headers["X-Isola-Ts"]!, sig = e.headers["X-Isola-Sig"]!
        XCTAssertFalse(Ponte.verify(key: ex.key, ts: ts, body: e.body, sigHex: nil))
        XCTAssertFalse(Ponte.verify(key: ex.key, ts: ts, body: e.body, sigHex: String(sig.dropLast())))
        XCTAssertFalse(Ponte.verify(key: ex.key, ts: ts, body: e.body, sigHex: String(sig.dropLast()) + "g"))
        XCTAssertFalse(Ponte.verify(key: ex.key, ts: ts, body: e.body, sigHex: String(sig.dropLast()) + (sig.last == "0" ? "1" : "0")))
        XCTAssertFalse(Ponte.verify(key: ex.key, ts: ts + "1", body: e.body, sigHex: sig))
        XCTAssertFalse(Ponte.verify(key: Data(repeating: 0, count: 20), ts: ts, body: e.body, sigHex: sig))
        var tampered = e.body
        tampered[tampered.count - 3] ^= 1
        XCTAssertFalse(Ponte.verify(key: ex.key, ts: ts, body: tampered, sigHex: sig))
    }

    func testParseTs() {
        XCTAssertEqual(Ponte.parseTs("1795400000000"), 1_795_400_000_000)
        XCTAssertEqual(Ponte.parseTs("0"), 0)
        XCTAssertEqual(Ponte.parseTs("9999999999999999"), 9_999_999_999_999_999)
        for bad in [nil, "", "+1795400000000", "-1", " 1795400000000", "1795400000000 ", "1e12", "17954000000000000", "1795400000000.0", "١٢"] {
            XCTAssertNil(Ponte.parseTs(bad), bad ?? "nil")
        }
    }

    func testTsWindow() {
        let now: Int64 = 1_795_400_000_000
        XCTAssertTrue(Ponte.tsInWindow(now - 300_000, now: now))
        XCTAssertTrue(Ponte.tsInWindow(now + 300_000, now: now))
        XCTAssertFalse(Ponte.tsInWindow(now - 300_001, now: now))
        XCTAssertFalse(Ponte.tsInWindow(now + 300_001, now: now))
    }
}

final class NamesTests: XCTestCase {
    func testCleanName() {
        XCTAssertEqual(Ponte.cleanName("  MacBook Air di Alessandro  "), "MacBook Air di Alessandro")
        XCTAssertEqual(Ponte.cleanName("PC\u{0007}-\u{0085}ALE\n"), "PC-ALE")
        XCTAssertEqual(Ponte.cleanName(String(repeating: "a", count: 100)), String(repeating: "a", count: 64))
        XCTAssertEqual(Ponte.cleanName(" \t "), "")
        XCTAssertEqual(Ponte.cleanName(nil), "")
    }

    func testFromLabel() {
        XCTAssertEqual(Ponte.fromLabel("MacBook Air"), "dal MacBook Air")
        XCTAssertEqual(Ponte.fromLabel("iMac"), "dall'iMac")
        XCTAssertEqual(Ponte.fromLabel("Ufficio"), "dall'Ufficio")
        XCTAssertEqual(Ponte.fromLabel(""), "dall'altro computer")
        XCTAssertEqual(Ponte.fromLabel(nil), "dall'altro computer")
    }

    func testToWire() {
        XCTAssertEqual(Ponte.toWire("a\r\nb\nc"), "a\nb\nc")
    }

    func testTailscaleAddresses() {
        XCTAssertTrue(IPAddr("100.64.0.1")!.isTailscale)
        XCTAssertTrue(IPAddr("100.69.76.44")!.isTailscale)
        XCTAssertTrue(IPAddr("100.127.255.255")!.isTailscale)
        XCTAssertFalse(IPAddr("100.63.255.255")!.isTailscale)
        XCTAssertFalse(IPAddr("100.128.0.1")!.isTailscale)
        XCTAssertFalse(IPAddr("192.168.1.10")!.isTailscale)
        XCTAssertTrue(IPAddr("fd7a:115c:a1e0::1")!.isTailscale)
        XCTAssertTrue(IPAddr("fd7a:115c:a1e0:ab12:4843:cd96:6258:b240")!.isTailscale)
        XCTAssertFalse(IPAddr("fd7a:115c:a1e1::1")!.isTailscale)
        XCTAssertTrue(IPAddr("::ffff:100.69.76.44")!.isTailscale)
        XCTAssertFalse(IPAddr("::ffff:127.0.0.1")!.isTailscale)
        XCTAssertTrue(IPAddr("::ffff:127.0.0.1")!.isLoopback)
        XCTAssertNil(IPAddr("pcale"))
        XCTAssertEqual(IPAddr("fd7a:115c:a1e0::1")!.urlHost, "[fd7a:115c:a1e0::1]")
    }
}
