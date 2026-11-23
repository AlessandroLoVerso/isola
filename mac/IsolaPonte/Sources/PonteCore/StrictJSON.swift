import Foundation

/// A strict JSON reader that behaves like .NET's JsonDocument (default options) as far as the
/// protocol needs: RFC 8259 grammar only (no comments, no trailing commas, no BOM), a depth limit,
/// duplicate keys allowed with the last one winning, numbers kept as written (so `1.0` is not an
/// integer), strings decoded only when read (invalid UTF-8 or a lone surrogate fails at that point).
struct JSONDoc {
    let bytes: [UInt8]
    let root: JNode

    /// TryGetInt32: an integer literal (no fraction, no exponent) that fits.
    func int32(_ n: JNode) -> Int32? {
        guard let s = integerLiteral(n) else { return nil }
        return Int32(s)
    }

    /// TryGetInt64.
    func int64(_ n: JNode) -> Int64? {
        guard let s = integerLiteral(n) else { return nil }
        return Int64(s)
    }

    private func integerLiteral(_ n: JNode) -> String? {
        guard case .number(let r) = n else { return nil }
        let lit = bytes[r]
        if lit.contains(where: { $0 == UInt8(ascii: ".") || $0 == UInt8(ascii: "e") || $0 == UInt8(ascii: "E") }) { return nil }
        return String(decoding: lit, as: UTF8.self)
    }

    /// GetString as UTF-16 units; nil on invalid UTF-8 or a lone surrogate.
    func stringUnits(_ n: JNode) -> [UInt16]? {
        guard case .string(let r, _) = n else { return nil }
        return StrictJSON.decodeUnits(bytes, r)
    }

    /// TryGetBytesFromBase64 (standard alphabet, padding required; ASCII whitespace ignored as in .NET 8+).
    func base64Bytes(_ n: JNode) -> Data? {
        guard case .string(let r, let escaped) = n else { return nil }
        if !escaped { return Base64Strict.decode(bytes[r]) }
        guard let units = StrictJSON.decodeUnits(bytes, r) else { return nil }
        var ascii = [UInt8]()
        ascii.reserveCapacity(units.count)
        for u in units {
            guard u < 0x80 else { return nil }
            ascii.append(UInt8(u))
        }
        return Base64Strict.decode(ascii[...])
    }
}

indirect enum JNode {
    case object([JMember])
    case array([JNode])
    /// Range of the raw content between the quotes; true if it contains escapes.
    case string(Range<Int>, Bool)
    case number(Range<Int>)
    case bool(Bool)
    case null

    /// TryGetProperty: the last member with this name (keys compared after unescaping).
    func member(_ name: String) -> JNode? {
        guard case .object(let members) = self else { return nil }
        let key = Array(name.utf16)
        return members.last(where: { $0.key == key })?.value
    }
}

struct JMember {
    /// Unescaped key; nil if the key bytes are not valid text (it then matches nothing).
    let key: [UInt16]?
    let value: JNode
}

enum StrictJSON {
    struct Invalid: Error {}

    static func parse(_ data: Data, maxDepth: Int) throws -> JSONDoc {
        var p = Parser(b: [UInt8](data), maxDepth: maxDepth)
        let root = try p.document()
        return JSONDoc(bytes: p.b, root: root)
    }

    private struct Parser {
        let b: [UInt8]
        let maxDepth: Int
        var i = 0
        var depth = 0

        init(b: [UInt8], maxDepth: Int) {
            self.b = b
            self.maxDepth = maxDepth
        }

        mutating func document() throws -> JNode {
            skipWS()
            let v = try value()
            skipWS()
            guard i == b.count else { throw Invalid() }
            return v
        }

        mutating func skipWS() {
            while i < b.count, b[i] == 0x20 || b[i] == 0x09 || b[i] == 0x0A || b[i] == 0x0D { i += 1 }
        }

        mutating func value() throws -> JNode {
            guard i < b.count else { throw Invalid() }
            switch b[i] {
            case UInt8(ascii: "{"): return try object()
            case UInt8(ascii: "["): return try array()
            case UInt8(ascii: "\""):
                let (r, esc) = try string()
                return .string(r, esc)
            case UInt8(ascii: "t"): try literal("true"); return .bool(true)
            case UInt8(ascii: "f"): try literal("false"); return .bool(false)
            case UInt8(ascii: "n"): try literal("null"); return .null
            case UInt8(ascii: "-"), UInt8(ascii: "0")...UInt8(ascii: "9"): return try number()
            default: throw Invalid()
            }
        }

        mutating func literal(_ word: String) throws {
            for c in word.utf8 {
                guard i < b.count, b[i] == c else { throw Invalid() }
                i += 1
            }
        }

        mutating func enter() throws {
            guard depth < maxDepth else { throw Invalid() }
            depth += 1
        }

        mutating func object() throws -> JNode {
            try enter()
            i += 1
            var members: [JMember] = []
            skipWS()
            if i < b.count, b[i] == UInt8(ascii: "}") {
                i += 1
                depth -= 1
                return .object(members)
            }
            while true {
                skipWS()
                guard i < b.count, b[i] == UInt8(ascii: "\"") else { throw Invalid() }
                let (kr, _) = try string()
                let key = StrictJSON.decodeUnits(b, kr)
                skipWS()
                guard i < b.count, b[i] == UInt8(ascii: ":") else { throw Invalid() }
                i += 1
                skipWS()
                let v = try value()
                members.append(JMember(key: key, value: v))
                skipWS()
                guard i < b.count else { throw Invalid() }
                if b[i] == UInt8(ascii: ",") { i += 1; continue }
                if b[i] == UInt8(ascii: "}") { i += 1; break }
                throw Invalid()
            }
            depth -= 1
            return .object(members)
        }

        mutating func array() throws -> JNode {
            try enter()
            i += 1
            var items: [JNode] = []
            skipWS()
            if i < b.count, b[i] == UInt8(ascii: "]") {
                i += 1
                depth -= 1
                return .array(items)
            }
            while true {
                skipWS()
                items.append(try value())
                skipWS()
                guard i < b.count else { throw Invalid() }
                if b[i] == UInt8(ascii: ",") { i += 1; continue }
                if b[i] == UInt8(ascii: "]") { i += 1; break }
                throw Invalid()
            }
            depth -= 1
            return .array(items)
        }

        /// i is on the opening quote. Checks the escapes' syntax and forbids raw control characters.
        mutating func string() throws -> (Range<Int>, Bool) {
            i += 1
            let start = i
            var escaped = false
            while i < b.count {
                let c = b[i]
                if c == UInt8(ascii: "\"") {
                    let r = start..<i
                    i += 1
                    return (r, escaped)
                }
                if c == UInt8(ascii: "\\") {
                    escaped = true
                    i += 1
                    guard i < b.count else { throw Invalid() }
                    switch b[i] {
                    case UInt8(ascii: "\""), UInt8(ascii: "\\"), UInt8(ascii: "/"), UInt8(ascii: "b"),
                         UInt8(ascii: "f"), UInt8(ascii: "n"), UInt8(ascii: "r"), UInt8(ascii: "t"):
                        i += 1
                    case UInt8(ascii: "u"):
                        guard i + 4 < b.count else { throw Invalid() }
                        for k in 1...4 where StrictJSON.hex(b[i + k]) == nil { throw Invalid() }
                        i += 5
                    default:
                        throw Invalid()
                    }
                    continue
                }
                if c < 0x20 { throw Invalid() }
                i += 1
            }
            throw Invalid()
        }

        mutating func number() throws -> JNode {
            let start = i
            if b[i] == UInt8(ascii: "-") { i += 1 }
            guard i < b.count else { throw Invalid() }
            if b[i] == UInt8(ascii: "0") {
                i += 1
            } else if b[i] >= UInt8(ascii: "1") && b[i] <= UInt8(ascii: "9") {
                while i < b.count, isDigit(b[i]) { i += 1 }
            } else {
                throw Invalid()
            }
            if i < b.count, b[i] == UInt8(ascii: ".") {
                i += 1
                guard i < b.count, isDigit(b[i]) else { throw Invalid() }
                while i < b.count, isDigit(b[i]) { i += 1 }
            }
            if i < b.count, b[i] == UInt8(ascii: "e") || b[i] == UInt8(ascii: "E") {
                i += 1
                if i < b.count, b[i] == UInt8(ascii: "+") || b[i] == UInt8(ascii: "-") { i += 1 }
                guard i < b.count, isDigit(b[i]) else { throw Invalid() }
                while i < b.count, isDigit(b[i]) { i += 1 }
            }
            return .number(start..<i)
        }

        func isDigit(_ c: UInt8) -> Bool { c >= 0x30 && c <= 0x39 }
    }

    static func hex(_ c: UInt8) -> UInt16? {
        switch c {
        case 0x30...0x39: return UInt16(c - 0x30)
        case 0x41...0x46: return UInt16(c - 0x41 + 10)
        case 0x61...0x66: return UInt16(c - 0x61 + 10)
        default: return nil
        }
    }

    /// Unescapes a string's raw content into UTF-16 units. Strict UTF-8 (no overlongs, no encoded
    /// surrogates, nothing over U+10FFFF); surrogates from \u escapes must come in pairs.
    static func decodeUnits(_ b: [UInt8], _ r: Range<Int>) -> [UInt16]? {
        var out = [UInt16]()
        out.reserveCapacity(r.count)
        var i = r.lowerBound
        let end = r.upperBound
        func cont(_ k: Int) -> UInt32? {
            guard k < end, b[k] & 0xC0 == 0x80 else { return nil }
            return UInt32(b[k] & 0x3F)
        }
        while i < end {
            let c = b[i]
            if c == UInt8(ascii: "\\") {
                let e = b[i + 1]
                switch e {
                case UInt8(ascii: "\""): out.append(0x22)
                case UInt8(ascii: "\\"): out.append(0x5C)
                case UInt8(ascii: "/"): out.append(0x2F)
                case UInt8(ascii: "b"): out.append(0x08)
                case UInt8(ascii: "f"): out.append(0x0C)
                case UInt8(ascii: "n"): out.append(0x0A)
                case UInt8(ascii: "r"): out.append(0x0D)
                case UInt8(ascii: "t"): out.append(0x09)
                case UInt8(ascii: "u"):
                    var v: UInt16 = 0
                    for k in 2...5 { v = v << 4 | (hex(b[i + k]) ?? 0) }
                    out.append(v)
                    i += 6
                    continue
                default: return nil
                }
                i += 2
                continue
            }
            if c < 0x80 {
                out.append(UInt16(c))
                i += 1
                continue
            }
            var scalar: UInt32
            switch c {
            case 0xC2...0xDF:
                guard let c1 = cont(i + 1) else { return nil }
                scalar = UInt32(c & 0x1F) << 6 | c1
                i += 2
            case 0xE0...0xEF:
                guard i + 1 < end else { return nil }
                let b1 = b[i + 1]
                if c == 0xE0 && b1 < 0xA0 { return nil }      // overlong
                if c == 0xED && b1 > 0x9F { return nil }      // UTF-16 surrogate
                guard let c1 = cont(i + 1), let c2 = cont(i + 2) else { return nil }
                scalar = UInt32(c & 0x0F) << 12 | c1 << 6 | c2
                i += 3
            case 0xF0...0xF4:
                guard i + 1 < end else { return nil }
                let b1 = b[i + 1]
                if c == 0xF0 && b1 < 0x90 { return nil }      // overlong
                if c == 0xF4 && b1 > 0x8F { return nil }      // over U+10FFFF
                guard let c1 = cont(i + 1), let c2 = cont(i + 2), let c3 = cont(i + 3) else { return nil }
                scalar = UInt32(c & 0x07) << 18 | c1 << 12 | c2 << 6 | c3
                i += 4
            default:
                return nil
            }
            if scalar >= 0x10000 {
                let v = scalar - 0x10000
                out.append(UInt16(0xD800 + (v >> 10)))
                out.append(UInt16(0xDC00 + (v & 0x3FF)))
            } else {
                out.append(UInt16(scalar))
            }
        }
        var k = 0
        while k < out.count {
            let u = out[k]
            if u >= 0xD800 && u <= 0xDBFF {
                guard k + 1 < out.count, out[k + 1] >= 0xDC00 && out[k + 1] <= 0xDFFF else { return nil }
                k += 2
            } else if u >= 0xDC00 && u <= 0xDFFF {
                return nil
            } else {
                k += 1
            }
        }
        return out
    }
}

/// Standard RFC 4648 base64 with '=' padding. ASCII whitespace is skipped (like .NET 8+'s
/// Base64.DecodeFromUtf8); anything else outside the alphabet is invalid.
enum Base64Strict {
    private static let table: [Int8] = {
        var t = [Int8](repeating: -1, count: 256)
        for (i, c) in "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/".utf8.enumerated() { t[Int(c)] = Int8(i) }
        return t
    }()

    static func decode(_ input: ArraySlice<UInt8>) -> Data? {
        var chars = [UInt8]()
        chars.reserveCapacity(input.count)
        for c in input where !(c == 0x20 || c == 0x09 || c == 0x0A || c == 0x0D) { chars.append(c) }
        guard chars.count % 4 == 0 else { return nil }
        var out = [UInt8]()
        out.reserveCapacity(chars.count / 4 * 3)
        var i = 0
        while i < chars.count {
            let last = i + 4 == chars.count
            let c0 = chars[i], c1 = chars[i + 1], c2 = chars[i + 2], c3 = chars[i + 3]
            let v0 = table[Int(c0)], v1 = table[Int(c1)]
            guard v0 >= 0, v1 >= 0 else { return nil }
            let pad = UInt8(ascii: "=")
            if last && c3 == pad {
                if c2 == pad {
                    out.append(UInt8(v0) << 2 | UInt8(v1) >> 4)
                } else {
                    let v2 = table[Int(c2)]
                    guard v2 >= 0 else { return nil }
                    out.append(UInt8(v0) << 2 | UInt8(v1) >> 4)
                    out.append(UInt8(v1 & 0x0F) << 4 | UInt8(v2) >> 2)
                }
            } else {
                let v2 = table[Int(c2)], v3 = table[Int(c3)]
                guard v2 >= 0, v3 >= 0 else { return nil }
                out.append(UInt8(v0) << 2 | UInt8(v1) >> 4)
                out.append(UInt8(v1 & 0x0F) << 4 | UInt8(v2) >> 2)
                out.append(UInt8(v2 & 0x03) << 6 | UInt8(v3))
            }
            i += 4
        }
        return Data(out)
    }
}

/// Compact JSON writer that escapes like System.Text.Json with JavaScriptEncoder.UnsafeRelaxedJsonEscaping:
/// short escapes for \b \t \n \f \r \" \\, \uXXXX (uppercase hex) for other control, format, separator,
/// private-use and unassigned characters and for characters outside the BMP; everything else raw UTF-8.
struct JSONWriter {
    private(set) var data = Data()
    private var needsComma = false

    mutating func startObject() { data.append(UInt8(ascii: "{")); needsComma = false }
    mutating func endObject() { data.append(UInt8(ascii: "}")); needsComma = true }

    private mutating func name(_ n: String) {
        if needsComma { data.append(UInt8(ascii: ",")) }
        writeString(n)
        data.append(UInt8(ascii: ":"))
        needsComma = true
    }

    mutating func number(_ n: String, _ v: Int64) {
        name(n)
        data.append(contentsOf: Array(String(v).utf8))
    }

    mutating func string(_ n: String, _ v: String) {
        name(n)
        writeString(v)
    }

    mutating func base64(_ n: String, _ v: Data) {
        name(n)
        data.append(UInt8(ascii: "\""))
        data.append(contentsOf: Array(v.base64EncodedString().utf8))
        data.append(UInt8(ascii: "\""))
    }

    private mutating func writeString(_ s: String) {
        data.append(UInt8(ascii: "\""))
        for scalar in s.unicodeScalars {
            switch scalar.value {
            case 0x08: data.append(contentsOf: [0x5C, UInt8(ascii: "b")])
            case 0x09: data.append(contentsOf: [0x5C, UInt8(ascii: "t")])
            case 0x0A: data.append(contentsOf: [0x5C, UInt8(ascii: "n")])
            case 0x0C: data.append(contentsOf: [0x5C, UInt8(ascii: "f")])
            case 0x0D: data.append(contentsOf: [0x5C, UInt8(ascii: "r")])
            case 0x22: data.append(contentsOf: [0x5C, 0x22])
            case 0x5C: data.append(contentsOf: [0x5C, 0x5C])
            default:
                if Self.mustEscape(scalar) {
                    for u in String(scalar).utf16 { data.append(contentsOf: Array(String(format: "\\u%04X", u).utf8)) }
                } else {
                    data.append(contentsOf: Array(String(scalar).utf8))
                }
            }
        }
        data.append(UInt8(ascii: "\""))
    }

    private static func mustEscape(_ s: Unicode.Scalar) -> Bool {
        if s.value > 0xFFFF { return true }
        switch s.properties.generalCategory {
        case .control, .format, .surrogate, .privateUse, .unassigned, .lineSeparator, .paragraphSeparator:
            return true
        case .spaceSeparator:
            return s.value != 0x20
        default:
            return false
        }
    }
}
