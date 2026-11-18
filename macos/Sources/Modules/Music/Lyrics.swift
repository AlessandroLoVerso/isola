import CryptoKit
import Foundation

struct LrcLine: Equatable, Sendable {
    let time: Double
    let text: String
}

/// Testi sincronizzati da LRCLIB (lrclib.net), salvati in `data/music/lyrics/`. Solo se l'utente
/// li accende. Ogni errore è silenzioso: la scheda semplicemente non mostra il testo.
final class LyricsService: Sendable {
    private let dir: URL
    private let log: @Sendable (String) -> Void
    private static let negativeCacheAge: TimeInterval = 3 * 24 * 3600

    private static let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 8
        c.httpAdditionalHeaders = ["User-Agent": "Isola/0.1 (macOS)"]
        return URLSession(configuration: c)
    }()

    init(dir: URL, log: @escaping @Sendable (String) -> Void) {
        self.dir = dir
        self.log = log
    }

    /// Le righe, oppure `nil` se non ci sono (o la rete non risponde).
    func lines(artist: String, title: String, album: String, duration: Int) async -> [LrcLine]? {
        let file = dir.appendingPathComponent(Self.hash("\(artist)\n\(title)\n\(album)\n\(duration)") + ".lrc")
        if let cached = try? String(contentsOf: file, encoding: .utf8) {
            if !cached.isEmpty { return Self.parse(cached) }
            let age = (try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
                .map { Date().timeIntervalSince($0) } ?? .infinity
            if age < Self.negativeCacheAge { return nil }
        }

        var lrc: String?
        do {
            lrc = try await fetchGet(artist, title, album, duration)
            let (a2, t2) = Self.cleanUp(artist: artist, title: title)
            if lrc == nil, a2 != artist || t2 != title {
                lrc = try await fetchGet(a2, t2, album, duration)
                if lrc == nil { lrc = try await fetchGet(a2, t2, "", duration) }
            }
            if lrc == nil { lrc = try await fetchSearch(a2, t2, duration) }
        } catch {
            if !Task.isCancelled { log("Musica: testi non disponibili") }
            return nil // problema di rete: niente cache, si riprova la prossima volta
        }
        if Task.isCancelled { return nil }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? (lrc ?? "").write(to: file, atomically: true, encoding: .utf8)
        return lrc.flatMap(Self.parse)
    }

    private func fetchGet(_ artist: String, _ title: String, _ album: String, _ dur: Int) async throws -> String? {
        let t = title.trimmingCharacters(in: .whitespaces), a = artist.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty, !a.isEmpty else { return nil }
        var c = URLComponents(string: "https://lrclib.net/api/get")!
        c.queryItems = [
            URLQueryItem(name: "artist_name", value: artist),
            URLQueryItem(name: "track_name", value: title),
            URLQueryItem(name: "album_name", value: album),
            URLQueryItem(name: "duration", value: String(dur)),
        ]
        guard let obj = try await getJSON(c) else { return nil }
        return Self.synced(obj)
    }

    private func fetchSearch(_ artist: String, _ title: String, _ dur: Int) async throws -> String? {
        guard !title.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        var c = URLComponents(string: "https://lrclib.net/api/search")!
        c.queryItems = [URLQueryItem(name: "track_name", value: title)]
        if !artist.isEmpty { c.queryItems?.append(URLQueryItem(name: "artist_name", value: artist)) }
        guard let arr = try await getJSON(c) as? [Any] else { return nil }
        for item in arr {
            guard let d = item as? [String: Any], let dd = (d["duration"] as? NSNumber)?.doubleValue,
                  abs(dd - Double(dur)) <= 3 else { continue }
            if let s = Self.synced(d) { return s }
        }
        return nil
    }

    private func getJSON(_ c: URLComponents) async throws -> Any? {
        // URLComponents non codifica "+": LRCLIB lo leggerebbe come spazio.
        var comps = c
        comps.percentEncodedQuery = comps.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        guard let url = comps.url else { return nil }
        let (data, resp) = try await Self.session.data(from: url)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        if status == 404 { return nil }
        guard (200..<300).contains(status) else { throw URLError(.badServerResponse) }
        return try? JSONSerialization.jsonObject(with: data)
    }

    private static func synced(_ obj: Any) -> String? {
        guard let d = obj as? [String: Any], let s = d["syncedLyrics"] as? String,
              !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return s
    }

    // MARK: - Pulizia dei titoli in stile YouTube ("Artista - Brano (Official Video)")

    static func cleanUp(artist: String, title: String) -> (String, String) {
        var a = replace(artist, #"\s*-\s*Topic$|VEVO$|\s+Official$"#, caseInsensitive: true)
            .trimmingCharacters(in: .whitespaces)
        var t = replace(title, #"\s*[\(\[][^\)\]]*[\)\]]"#).trimmingCharacters(in: .whitespaces)
        t = replace(t, #"\s*\|.*$"#).trimmingCharacters(in: .whitespaces)
        if let r = t.range(of: " - ") ?? t.range(of: " – "), r.lowerBound > t.startIndex {
            a = String(t[..<r.lowerBound]).trimmingCharacters(in: .whitespaces)
            t = String(t[r.upperBound...]).trimmingCharacters(in: .whitespaces)
        }
        t = replace(t, #"\s+(ft\.?|feat\.?)\s.*$"#, caseInsensitive: true).trimmingCharacters(in: .whitespaces)
        return (a.isEmpty ? artist : a, t.isEmpty ? title : t)
    }

    private static func replace(_ s: String, _ pattern: String, caseInsensitive: Bool = false) -> String {
        guard let re = try? NSRegularExpression(pattern: pattern, options: caseInsensitive ? [.caseInsensitive] : []) else { return s }
        return re.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: "")
    }

    // MARK: - LRC

    private static let timeTag = try! NSRegularExpression(pattern: #"\[(\d{1,3}):(\d{1,2})(?:[.:](\d{1,3}))?\]"#)

    static func parse(_ lrc: String) -> [LrcLine]? {
        var out: [LrcLine] = []
        for raw in lrc.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = String(raw)
            let ns = line as NSString
            let matches = timeTag.matches(in: line, range: NSRange(location: 0, length: ns.length))
            guard let last = matches.last else { continue }
            let text = ns.substring(from: last.range.location + last.range.length).trimmingCharacters(in: .whitespacesAndNewlines)
            for m in matches {
                let min = Double(ns.substring(with: m.range(at: 1))) ?? 0
                let sec = Double(ns.substring(with: m.range(at: 2))) ?? 0
                var frac = 0.0
                if m.range(at: 3).location != NSNotFound {
                    let f = ns.substring(with: m.range(at: 3))
                    frac = (Double(f) ?? 0) / pow(10, Double(f.count))
                }
                out.append(LrcLine(time: min * 60 + sec + frac, text: text))
            }
        }
        guard !out.isEmpty else { return nil }
        return out.sorted { $0.time < $1.time }
    }

    /// Indice della riga cantata a `pos`, -1 prima della prima.
    static func index(in lines: [LrcLine], at pos: Double) -> Int {
        var lo = 0, hi = lines.count - 1, found = -1
        while lo <= hi {
            let mid = (lo + hi) / 2
            if lines[mid].time <= pos { found = mid; lo = mid + 1 } else { hi = mid - 1 }
        }
        return found
    }

    private static func hash(_ s: String) -> String {
        Insecure.SHA1.hash(data: Data(s.utf8)).prefix(10).map { String(format: "%02x", $0) }.joined()
    }
}
