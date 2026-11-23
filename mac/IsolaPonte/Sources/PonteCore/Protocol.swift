import CryptoKit
import Foundation
import Security

public enum ClipKind: Equatable, Sendable { case text, image }

/// One clip on the wire (POST /clip), already validated.
public struct ClipPayload: Equatable, Sendable {
    public let id: String
    /// Cleaned display name ("" if missing or empty).
    public let from: String
    public let ts: Int64
    public let kind: ClipKind
    /// Text with "\n" line endings (wire form).
    public let text: String?
    public let png: Data?
}

/// The "ponte" v1 protocol of docs/appunti-condivisi.md, written to match Isola for Windows
/// (src/Isola/Modules/Clipboard/ClipSyncProtocol.cs) byte for byte. Pure functions.
public enum Ponte {
    public static let version = 1
    public static let port: UInt16 = 47323
    public static let appName = "isola-ponte-mac"

    /// Pairing key: 20 random bytes = 32 base32 characters = 8 groups of 4.
    public static let keyBytes = 20
    public static let keyChars = 32
    public static let maxTextChars = 1_000_000          // UTF-16 code units, wire form ("\n")
    public static let maxPngBytes = 10 * 1024 * 1024     // decoded PNG
    public static let maxBodyBytes = 14 * 1024 * 1024    // whole JSON body
    public static let maxHeaderBytes = 16 * 1024         // request line + headers
    public static let maxIdChars = 64
    public static let maxFromChars = 64
    public static let maxSkewMs: Int64 = 5 * 60 * 1000
    public static let rememberedIds = 200
    public static let tsHeader = "X-Isola-Ts"
    public static let sigHeader = "X-Isola-Sig"

    private static let base32Alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ234567".utf8)

    // MARK: - Pairing key

    public static func generateKey() -> Data {
        var bytes = [UInt8](repeating: 0, count: keyBytes)
        let status = SecRandomCopyBytes(kSecRandomDefault, keyBytes, &bytes)
        precondition(status == errSecSuccess, "SecRandomCopyBytes")
        return Data(bytes)
    }

    /// "ABCD-EFGH-..." (8 groups of 4, RFC 4648 base32, no padding).
    public static func formatKey(_ key: Data) -> String {
        var out = ""
        for (i, c) in base32Encode(key).enumerated() {
            if i > 0 && i % 4 == 0 { out.append("-") }
            out.append(c)
        }
        return out
    }

    /// Accepts the key as typed or pasted: case, spaces and dashes don't matter.
    /// Nil unless exactly 32 base32 characters remain.
    public static func parseKey(_ text: String?) -> Data? {
        guard let text, !isNullOrWhiteSpace(text) else { return nil }
        var units: [UInt16] = []
        for u in text.utf16 {
            switch u {
            case 0x2D, 0x20, 0x09, 0x0D, 0x0A, 0xA0: continue // - space \t \r \n NBSP
            default: units.append(upperInvariant(u))
            }
        }
        guard units.count == keyChars else { return nil }
        return base32Decode(String(decoding: units, as: UTF16.self))
    }

    /// char.ToUpperInvariant for the characters that can end up in the alphabet.
    private static func upperInvariant(_ u: UInt16) -> UInt16 {
        switch u {
        case 0x61...0x7A: return u - 0x20
        case 0x0131: return 0x49 // dotless i → I
        case 0x017F: return 0x53 // long s → S
        default: return u
        }
    }

    public static func base32Encode(_ data: Data) -> String {
        var out = [UInt8]()
        out.reserveCapacity((data.count * 8 + 4) / 5)
        var buffer = 0, bits = 0
        for b in data {
            buffer = (buffer << 8) | Int(b)
            bits += 8
            while bits >= 5 {
                out.append(base32Alphabet[(buffer >> (bits - 5)) & 31])
                bits -= 5
            }
            buffer &= (1 << bits) - 1
        }
        if bits > 0 { out.append(base32Alphabet[(buffer << (5 - bits)) & 31]) }
        return String(decoding: out, as: UTF8.self)
    }

    /// Strict RFC 4648 base32 (uppercase, no padding). Nil on any other character.
    public static func base32Decode(_ s: String) -> Data? {
        var bytes = [UInt8]()
        var buffer = 0, bits = 0
        for u in s.utf16 {
            guard u < 0x80, let v = base32Alphabet.firstIndex(of: UInt8(u)) else { return nil }
            buffer = (buffer << 5) | v
            bits += 5
            if bits >= 8 {
                bytes.append(UInt8((buffer >> (bits - 8)) & 0xFF))
                bits -= 8
            }
            buffer &= (1 << bits) - 1
        }
        return Data(bytes)
    }

    // MARK: - Signature

    /// Lowercase hex HMAC-SHA256 of ASCII(ts) + "\n" + body.
    public static func sign(key: Data, ts: String, body: Data) -> String {
        mac(key: key, ts: ts, body: body).map { String(format: "%02x", $0) }.joined()
    }

    private static func mac(key: Data, ts: String, body: Data) -> [UInt8] {
        var h = HMAC<SHA256>(key: SymmetricKey(data: key))
        h.update(data: Data(ts.utf8))
        h.update(data: Data([0x0A]))
        h.update(data: body)
        return Array(h.finalize())
    }

    /// Constant-time check of the X-Isola-Sig header (hex, either case).
    public static func verify(key: Data, ts: String, body: Data, sigHex: String?) -> Bool {
        guard let sigHex, sigHex.utf16.count == 64, let given = hexDecode(sigHex) else { return false }
        let expected = mac(key: key, ts: ts, body: body)
        guard expected.count == given.count else { return false }
        var diff: UInt8 = 0
        for i in 0..<expected.count { diff |= expected[i] ^ given[i] }
        return diff == 0
    }

    private static func hexDecode(_ s: String) -> [UInt8]? {
        let u = Array(s.utf16)
        guard u.count % 2 == 0 else { return nil }
        func nibble(_ c: UInt16) -> UInt8? {
            switch c {
            case 0x30...0x39: return UInt8(c - 0x30)
            case 0x41...0x46: return UInt8(c - 0x41 + 10)
            case 0x61...0x66: return UInt8(c - 0x61 + 10)
            default: return nil
            }
        }
        var out = [UInt8]()
        out.reserveCapacity(u.count / 2)
        var i = 0
        while i < u.count {
            guard let hi = nibble(u[i]), let lo = nibble(u[i + 1]) else { return nil }
            out.append(hi << 4 | lo)
            i += 2
        }
        return out
    }

    /// The ts header must be plain decimal digits (no sign, no spaces), at most 16 of them.
    public static func parseTs(_ s: String?) -> Int64? {
        guard let s, !s.isEmpty, s.utf16.count <= 16 else { return nil }
        for u in s.utf16 where u < 0x30 || u > 0x39 { return nil }
        return Int64(s)
    }

    public static func nowMs() -> Int64 { Int64((Date().timeIntervalSince1970 * 1000).rounded(.down)) }

    public static func tsInWindow(_ ts: Int64, now: Int64) -> Bool { abs(now - ts) <= maxSkewMs }

    // MARK: - Body

    /// A new id for every clip: UUID, lowercase with dashes.
    public static func newId() -> String { UUID().uuidString.lowercased() }

    /// Compact JSON, keys in this order: v, id, from, ts, kind, text|png (like Utf8JsonWriter with
    /// UnsafeRelaxedJsonEscaping on Windows).
    public static func buildClipBody(id: String, from: String, ts: Int64, kind: ClipKind, text: String?, png: Data?) -> Data {
        var w = JSONWriter()
        w.startObject()
        w.number("v", Int64(version))
        w.string("id", id)
        w.string("from", from)
        w.number("ts", ts)
        switch kind {
        case .text:
            w.string("kind", "text")
            w.string("text", text ?? "")
        case .image:
            w.string("kind", "image")
            w.base64("png", png ?? Data())
        }
        w.endObject()
        return w.data
    }

    public static func buildPingResponse(name: String) -> Data {
        var w = JSONWriter()
        w.startObject()
        w.number("v", Int64(version))
        w.string("name", name)
        w.string("app", appName)
        w.endObject()
        return w.data
    }

    public enum ParseError: Error, Equatable { case badJson, tooLarge }

    /// Parses and validates a POST /clip body (same rules and order as Windows' TryParseClip).
    public static func parseClip(_ body: Data) -> Result<ClipPayload, ParseError> {
        guard let doc = try? StrictJSON.parse(body, maxDepth: 8) else { return .failure(.badJson) }
        guard case .object = doc.root else { return .failure(.badJson) }
        let root = doc.root

        guard let v = root.member("v"), let ver = doc.int32(v), ver == version else { return .failure(.badJson) }
        guard let idEl = root.member("id"), case .string = idEl, let idUnits = doc.stringUnits(idEl) else { return .failure(.badJson) }
        guard !idUnits.isEmpty, idUnits.count <= maxIdChars else { return .failure(.badJson) }
        guard let tsEl = root.member("ts"), let ts = doc.int64(tsEl) else { return .failure(.badJson) }
        var from = ""
        if let fromEl = root.member("from") {
            guard case .string = fromEl, let units = doc.stringUnits(fromEl) else { return .failure(.badJson) }
            from = cleanName(units)
        }
        guard let kindEl = root.member("kind"), case .string = kindEl, let kindUnits = doc.stringUnits(kindEl) else { return .failure(.badJson) }
        let id = String(decoding: idUnits, as: UTF16.self)
        switch String(decoding: kindUnits, as: UTF16.self) {
        case "text":
            guard let t = root.member("text"), case .string = t, let units = doc.stringUnits(t) else { return .failure(.badJson) }
            if units.count > maxTextChars { return .failure(.tooLarge) }
            if units.isEmpty { return .failure(.badJson) }
            return .success(ClipPayload(id: id, from: from, ts: ts, kind: .text,
                                        text: String(decoding: units, as: UTF16.self), png: nil))
        case "image":
            guard let p = root.member("png"), case .string = p, let png = doc.base64Bytes(p) else { return .failure(.badJson) }
            if png.count > maxPngBytes { return .failure(.tooLarge) }
            if !isPng(png) { return .failure(.badJson) }
            return .success(ClipPayload(id: id, from: from, ts: ts, kind: .image, text: nil, png: png))
        default:
            return .failure(.badJson)
        }
    }

    private static let pngSignature: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]

    public static func isPng(_ b: Data) -> Bool {
        b.count > 8 && b.prefix(8).elementsEqual(pngSignature)
    }

    /// Display name of a computer: no control characters, at most 64 UTF-16 units, trimmed.
    public static func cleanName(_ s: String?) -> String {
        guard let s else { return "" }
        return cleanName(Array(s.utf16))
    }

    static func cleanName(_ units: [UInt16]) -> String {
        if units.allSatisfy(isWhiteSpace) { return "" }
        var out = [UInt16]()
        out.reserveCapacity(min(units.count, maxFromChars))
        for u in units {
            if isControl(u) { continue }
            out.append(u)
            if out.count >= maxFromChars { break }
        }
        var lo = 0, hi = out.count
        while lo < hi && isWhiteSpace(out[lo]) { lo += 1 }
        while hi > lo && isWhiteSpace(out[hi - 1]) { hi -= 1 }
        return String(decoding: out[lo..<hi], as: UTF16.self)
    }

    /// "dal MacBook Air", "dall'iMac", "dall'altro computer".
    public static func fromLabel(_ from: String?) -> String {
        guard let from, !isNullOrWhiteSpace(from), let first = from.utf16.first else { return "dall'altro computer" }
        return Array("aeiouAEIOU".utf16).contains(first) ? "dall'" + from : "dal " + from
    }

    /// Wire text uses "\n" only.
    public static func toWire(_ text: String) -> String { text.replacingOccurrences(of: "\r\n", with: "\n") }

    // char.IsControl / char.IsWhiteSpace of .NET, per UTF-16 unit.
    static func isControl(_ u: UInt16) -> Bool { u < 0x20 || (u >= 0x7F && u <= 0x9F) }

    static func isWhiteSpace(_ u: UInt16) -> Bool {
        switch u {
        case 0x09...0x0D, 0x20, 0x85, 0xA0, 0x1680, 0x2000...0x200A, 0x2028, 0x2029, 0x202F, 0x205F, 0x3000: return true
        default: return false
        }
    }

    static func isNullOrWhiteSpace(_ s: String) -> Bool { s.utf16.allSatisfy(isWhiteSpace) }
}
