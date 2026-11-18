import Foundation

/// Parser HTTP/1.1 minimo e incrementale per una sola richiesta per connessione.
/// Accetta solo `POST /agent` da un client locale come curl: chi manda `Origin` o `Sec-Fetch-*`
/// (un browser, cioè una pagina web che prova a raggiungere 127.0.0.1) riceve 404.
/// Corpo: `Content-Length`, `Transfer-Encoding: chunked`, oppure fino alla chiusura.
struct HTTPRequestParser {
    enum Step: Equatable {
        /// Servono altri byte.
        case needMore
        /// Il client ha chiesto `Expect: 100-continue`: rispondi "100 Continue" e continua.
        case sendContinue
        /// Fine: lo stato da rispondere e, solo con 200, il corpo.
        case finished(status: Int, body: Data?)
    }

    static let maxHead = 16 * 1024
    let maxBody: Int

    private var buffer: [UInt8] = []
    private var phase: Phase = .head
    private var bodyStart = 0
    private var wantsContinue = false

    private enum Phase { case head, fixed(Int), chunked, untilClose, done(Step) }

    init(maxBody: Int) { self.maxBody = maxBody }

    mutating func append(_ data: Data) { buffer.append(contentsOf: data) }

    /// Avanza con i byte ricevuti finora. `eof`: il client ha chiuso il suo lato.
    mutating func step(eof: Bool) -> Step {
        switch phase {
        case .done(let s):
            return s
        case .head:
            guard let end = headEnd() else {
                if buffer.count > Self.maxHead { return finish(431) }
                return eof ? finish(400) : .needMore
            }
            if end > Self.maxHead { return finish(431) }
            bodyStart = end
            if let status = parseHead(buffer[0..<end]) { return finish(status) }
            if wantsContinue && buffer.count == bodyStart && !eof {
                wantsContinue = false
                return .sendContinue
            }
            return step(eof: eof)
        case .fixed(let n):
            if buffer.count - bodyStart >= n {
                return finish(200, Data(buffer[bodyStart..<(bodyStart + n)]))
            }
            return eof ? finish(400) : .needMore
        case .untilClose:
            if buffer.count - bodyStart > maxBody { return finish(413) }
            return eof ? finish(200, Data(buffer[bodyStart...])) : .needMore
        case .chunked:
            switch decodeChunked() {
            case .complete(let body): return finish(200, body)
            case .invalid: return finish(400)
            case .tooLarge: return finish(413)
            case .incomplete:
                if buffer.count - bodyStart > maxBody + 64 * 1024 { return finish(413) }
                return eof ? finish(400) : .needMore
            }
        }
    }

    private mutating func finish(_ status: Int, _ body: Data? = nil) -> Step {
        let s = Step.finished(status: status, body: status == 200 ? (body ?? Data()) : nil)
        phase = .done(s)
        return s
    }

    // MARK: testa

    /// Indice subito dopo la riga vuota che chiude la testa (CRLF o solo LF), o nil.
    private func headEnd() -> Int? {
        var lineStart = 0
        var sawRequestLine = false
        var i = 0
        let limit = min(buffer.count, Self.maxHead + 1)
        while i < limit {
            if buffer[i] == 0x0A {
                var lineEnd = i
                if lineEnd > lineStart && buffer[lineEnd - 1] == 0x0D { lineEnd -= 1 }
                if lineEnd == lineStart {
                    if sawRequestLine { return i + 1 }
                    // Righe vuote prima della richiesta: si ignorano (RFC 9112 §2.2).
                } else {
                    sawRequestLine = true
                }
                lineStart = i + 1
            }
            i += 1
        }
        return nil
    }

    /// Controlla la testa e sceglie come leggere il corpo. Ritorna uno stato se la richiesta
    /// va chiusa subito, nil se si continua con il corpo.
    private mutating func parseHead(_ bytes: ArraySlice<UInt8>) -> Int? {
        // Righe divise sui byte: in una String "\r\n" è un solo carattere.
        var lines: [Substring] = []
        for raw in bytes.split(separator: 0x0A, omittingEmptySubsequences: false) {
            let trimmed = raw.last == 0x0D ? raw.dropLast() : raw
            guard let line = String(bytes: trimmed, encoding: .isoLatin1) else { return 400 }
            lines.append(Substring(line))
        }
        while let first = lines.first, first.isEmpty { lines.removeFirst() }
        guard let requestLine = lines.first else { return 400 }

        let parts = requestLine.split(separator: " ", omittingEmptySubsequences: true)
        guard parts.count == 3, parts[2].hasPrefix("HTTP/1.") else { return 400 }
        let method = parts[0]
        var target = Substring(parts[1])

        var headers: [String: [String]] = [:]
        for line in lines.dropFirst() where !line.isEmpty {
            guard let colon = line.firstIndex(of: ":") else { return 400 }
            let name = line[..<colon].lowercased()
            guard !name.isEmpty, !name.contains(" "), !name.contains("\t") else { return 400 }
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            headers[name, default: []].append(value)
        }

        // Un browser manda sempre Origin o Sec-Fetch-* in una richiesta del genere; curl mai.
        if headers["origin"] != nil { return 404 }
        if headers.keys.contains(where: { $0.hasPrefix("sec-fetch-") }) { return 404 }
        // Host diverso da un nome locale = DNS rebinding o richiesta non nostra.
        if let host = headers["host"] {
            guard host.count == 1, Self.isLoopbackHost(host[0]) else { return 404 }
        }

        // Forma assoluta "http://127.0.0.1:47321/agent": tieni solo il percorso.
        if target.lowercased().hasPrefix("http://") {
            let rest = target.dropFirst("http://".count)
            target = rest.firstIndex(of: "/").map { rest[$0...] } ?? "/"
        }
        if let q = target.firstIndex(where: { $0 == "?" || $0 == "#" }) { target = target[..<q] }
        while target.count > 1 && target.hasSuffix("/") { target = target.dropLast() }
        guard method == "POST", target == "/agent" else { return 404 }

        if let te = headers["transfer-encoding"] {
            let codings = te.joined(separator: ",").split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            guard codings.last == "chunked" && codings.allSatisfy({ $0 == "chunked" || $0 == "identity" }) else {
                return 400
            }
            phase = .chunked
        } else if let cl = headers["content-length"] {
            let values = Set(cl.joined(separator: ",").split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespaces) })
            guard values.count == 1, let v = values.first, !v.isEmpty, v.count <= 12,
                  v.allSatisfy({ $0.isASCII && $0.isNumber }), let n = Int(v) else { return 400 }
            if n > maxBody { return 413 }
            phase = .fixed(n)
        } else {
            phase = .untilClose
        }
        if let expect = headers["expect"], expect.contains(where: { $0.lowercased() == "100-continue" }) {
            wantsContinue = true
        }
        return nil
    }

    static func isLoopbackHost(_ value: String) -> Bool {
        var host = value.lowercased()
        if host.hasPrefix("[") {
            guard let close = host.firstIndex(of: "]") else { return false }
            host = String(host[host.index(after: host.startIndex)..<close])
        } else if let colon = host.lastIndex(of: ":") {
            host = String(host[..<colon])
        }
        return host == "127.0.0.1" || host == "localhost" || host == "::1"
    }

    // MARK: corpo a pezzi

    private enum Chunked { case incomplete, invalid, tooLarge, complete(Data) }

    private func lineEnd(from start: Int) -> Int? {
        var i = start
        while i < buffer.count {
            if buffer[i] == 0x0A { return i }
            i += 1
        }
        return nil
    }

    private func line(_ start: Int, _ end: Int) -> ArraySlice<UInt8> {
        var e = end
        if e > start && buffer[e - 1] == 0x0D { e -= 1 }
        return buffer[start..<e]
    }

    private func decodeChunked() -> Chunked {
        var i = bodyStart
        var out = Data()
        while true {
            guard let le = lineEnd(from: i) else { return .incomplete }
            let sizeLine = line(i, le)
            guard sizeLine.count <= 1024 else { return .invalid }
            let sizeText = (String(bytes: sizeLine, encoding: .isoLatin1) ?? "")
                .split(separator: ";", maxSplits: 1, omittingEmptySubsequences: false).first ?? ""
            let hex = sizeText.trimmingCharacters(in: .whitespaces)
            guard !hex.isEmpty, hex.count <= 8, hex.allSatisfy({ $0.isHexDigit }),
                  let size = Int(hex, radix: 16) else { return .invalid }
            i = le + 1
            if size == 0 {
                // Trailer facoltativi, poi la riga vuota.
                while true {
                    guard let te = lineEnd(from: i) else { return .incomplete }
                    let isEmpty = line(i, te).isEmpty
                    i = te + 1
                    if isEmpty { return .complete(out) }
                }
            }
            if out.count + size > maxBody { return .tooLarge }
            guard buffer.count > i + size else { return .incomplete }
            out.append(contentsOf: buffer[i..<(i + size)])
            i += size
            if buffer[i] == 0x0D {
                guard buffer.count > i + 1 else { return .incomplete }
                guard buffer[i + 1] == 0x0A else { return .invalid }
                i += 2
            } else if buffer[i] == 0x0A {
                i += 1
            } else {
                return .invalid
            }
        }
    }
}
