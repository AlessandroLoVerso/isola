import Foundation

enum SpotifyError: Sendable { case none, notConnected, premiumRequired, forbidden, rateLimited, notFound, network, failed }

struct SpotifyTrack: Sendable, Equatable, Identifiable {
    let id: String?
    let uri: String
    let name: String
    let artist: String
    let imageURL: URL?
}

struct SpotifyQueueEntry: Sendable, Hashable {
    let name: String
    let artist: String
}

struct SpotifyPlaylist: Sendable, Identifiable, Equatable {
    let id: String
    let name: String
    let count: Int
    let ownerId: String
    let collaborative: Bool
}

struct SpotifyMe: Sendable {
    let id: String
    let displayName: String
}

/// Client della Web API di Spotify. Tiene il token di accesso in memoria, lo rinnova una volta su
/// 401, rispetta Retry-After su 429, riconosce 403 PREMIUM_REQUIRED. Nel log solo righe di stato
/// "Spotify: …", mai token o dati dell'account.
actor SpotifyAPI {
    private static let apiBase = "https://api.spotify.com/v1"
    private static let tokenURL = URL(string: "https://accounts.spotify.com/api/token")!

    private static let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 8
        c.httpAdditionalHeaders = ["User-Agent": "Isola/0.1 (macOS)"]
        return URLSession(configuration: c)
    }()

    private var creds: SpotifyKeychain.Credentials?
    private var access: String?
    private var accessExpires = Date.distantPast
    private var blockedUntil = Date.distantPast
    private let log: @Sendable (String) -> Void
    private let onRevoked: @Sendable () -> Void

    init(log: @escaping @Sendable (String) -> Void, onRevoked: @escaping @Sendable () -> Void) {
        self.log = log
        self.onRevoked = onRevoked
    }

    var isConnected: Bool { creds != nil }

    /// Legge il Portachiavi. Niente rete.
    func loadStored() -> Bool {
        creds = SpotifyKeychain.load()
        return creds != nil
    }

    /// Dimentica i token in memoria (il Portachiavi resta com'è).
    func forget() {
        creds = nil
        access = nil
        accessExpires = .distantPast
    }

    func disconnect() {
        creds = nil
        access = nil
        accessExpires = .distantPast
        SpotifyKeychain.delete()
    }

    // MARK: - Token

    func exchangeCode(clientId: String, code: String, verifier: String) async -> Bool {
        let (status, body) = await postToken([
            "grant_type": "authorization_code",
            "code": code,
            "redirect_uri": SpotifyPKCE.redirectURI,
            "client_id": clientId,
            "code_verifier": verifier,
        ])
        guard status == 200 else { log("Spotify: errore \(status == 0 ? "rete" : String(status))"); return false }
        guard let t = Self.parseTokens(body), let refresh = t.refresh else { log("Spotify: errore risposta"); return false }
        let c = SpotifyKeychain.Credentials(clientId: clientId, refreshToken: refresh)
        guard SpotifyKeychain.save(c) else { log("Spotify: errore Portachiavi"); return false }
        creds = c
        access = t.access
        accessExpires = Date().addingTimeInterval(max(60, Double(t.expiresIn - 60)))
        return true
    }

    private var refreshing: Task<Bool, Never>?

    private func refresh() async -> Bool {
        if let r = refreshing { return await r.value }
        let task = Task { await doRefresh() }
        refreshing = task
        let ok = await task.value
        refreshing = nil
        return ok
    }

    private func doRefresh() async -> Bool {
        guard let c = creds else { return false }
        let (status, body) = await postToken([
            "grant_type": "refresh_token",
            "refresh_token": c.refreshToken,
            "client_id": c.clientId,
        ])
        if status == 200, let t = Self.parseTokens(body) {
            guard creds != nil else { return false } // scollegato nel frattempo
            access = t.access
            accessExpires = Date().addingTimeInterval(max(60, Double(t.expiresIn - 60)))
            // I refresh token PKCE ruotano: il vecchio può smettere di funzionare.
            if let r = t.refresh, r != c.refreshToken {
                let next = SpotifyKeychain.Credentials(clientId: c.clientId, refreshToken: r)
                creds = next
                SpotifyKeychain.save(next)
            }
            return true
        }
        if status == 400 || status == 401, body.contains("invalid_grant") || body.contains("invalid_client") {
            disconnect()
            log("Spotify: scollegato")
            onRevoked()
            return false
        }
        log("Spotify: errore \(status == 0 ? "rete" : String(status))")
        return false
    }

    private func postToken(_ form: [String: String]) async -> (Int, String) {
        var req = URLRequest(url: Self.tokenURL)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        req.httpBody = form.map { k, v in
            "\(k)=\(v.addingPercentEncoding(withAllowedCharacters: allowed) ?? v)"
        }.joined(separator: "&").data(using: .utf8)
        do {
            let (data, resp) = try await Self.session.data(for: req)
            return ((resp as? HTTPURLResponse)?.statusCode ?? 0, String(decoding: data, as: UTF8.self))
        } catch {
            return (0, "")
        }
    }

    // MARK: - Chiamata generica

    struct Result: Sendable {
        let status: Int
        let body: Data
        let error: SpotifyError
        var ok: Bool { error == .none }
    }

    func send(_ method: String, _ pathAndQuery: String, json: Any? = nil) async -> Result {
        guard creds != nil else { return Result(status: 0, body: Data(), error: .notConnected) }
        var refreshed = false, waited = false
        let payload = json.flatMap { try? JSONSerialization.data(withJSONObject: $0) }
        while true {
            if Date() < blockedUntil { return Result(status: 429, body: Data(), error: .rateLimited) }
            guard let token = access, Date() < accessExpires else {
                if refreshed { return Result(status: 0, body: Data(), error: creds != nil ? .failed : .notConnected) }
                refreshed = true
                if !(await refresh()) { return Result(status: 0, body: Data(), error: creds != nil ? .failed : .notConnected) }
                continue
            }
            guard let url = URL(string: Self.apiBase + pathAndQuery) else { return Result(status: 0, body: Data(), error: .failed) }
            var req = URLRequest(url: url)
            req.httpMethod = method
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            if let payload {
                req.httpBody = payload
                req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            } else if method != "GET" {
                req.httpBody = Data()
                req.setValue("0", forHTTPHeaderField: "Content-Length")
            }
            let data: Data, http: HTTPURLResponse
            do {
                let (d, r) = try await Self.session.data(for: req)
                guard let h = r as? HTTPURLResponse else { return Result(status: 0, body: Data(), error: .failed) }
                data = d
                http = h
            } catch {
                log("Spotify: errore rete")
                return Result(status: 0, body: Data(), error: .network)
            }
            let status = http.statusCode
            if (200..<300).contains(status) { return Result(status: status, body: data, error: .none) }
            if status == 401, !refreshed {
                refreshed = true
                access = nil
                if !(await refresh()) { return Result(status: 401, body: Data(), error: creds != nil ? .failed : .notConnected) }
                continue
            }
            if status == 429 {
                let wait = Self.retryAfter(http)
                blockedUntil = Date().addingTimeInterval(wait)
                if !waited, wait <= 3 {
                    waited = true
                    try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
                    blockedUntil = .distantPast
                    continue
                }
                log("Spotify: errore 429")
                return Result(status: 429, body: Data(), error: .rateLimited)
            }
            if status == 403 { return Result(status: 403, body: data, error: Self.isPremiumRequired(data) ? .premiumRequired : .forbidden) }
            if status == 404 { return Result(status: 404, body: data, error: .notFound) }
            log("Spotify: errore \(status)")
            return Result(status: status, body: data, error: .failed)
        }
    }

    private static func retryAfter(_ r: HTTPURLResponse) -> TimeInterval {
        let v = (r.value(forHTTPHeaderField: "Retry-After")).flatMap(Double.init) ?? 5
        return min(3600, max(1, v))
    }

    // MARK: - Endpoint

    func me() async -> (SpotifyMe?, SpotifyError) {
        let r = await send("GET", "/me")
        return r.ok ? (Self.parseMe(r.body), .none) : (nil, r.error)
    }

    func currentlyPlaying() async -> (SpotifyTrack?, SpotifyError) {
        let r = await send("GET", "/me/player/currently-playing")
        guard r.ok else { return (nil, r.error) }
        return (r.status == 204 ? nil : Self.parseCurrentlyPlaying(r.body), .none)
    }

    /// GET /me/library/contains (API di febbraio 2026); ripiego su /me/tracks/contains.
    func isSaved(_ t: SpotifyTrack) async -> Bool? {
        var r = await send("GET", "/me/library/contains?uris=" + Self.esc(t.uri))
        if r.error == .notFound, let id = t.id { r = await send("GET", "/me/tracks/contains?ids=" + Self.esc(id)) }
        return r.ok ? Self.parseContains(r.body) : nil
    }

    /// PUT/DELETE /me/library?uris= (febbraio 2026); ripiego su /me/tracks?ids=.
    func setSaved(_ t: SpotifyTrack, _ save: Bool) async -> SpotifyError {
        let m = save ? "PUT" : "DELETE"
        var r = await send(m, "/me/library?uris=" + Self.esc(t.uri))
        if r.error == .notFound, let id = t.id { r = await send(m, "/me/tracks?ids=" + Self.esc(id)) }
        return r.error
    }

    /// Le playlist dell'utente (sue o collaborative), fino a 200.
    func editablePlaylists(meId: String) async -> ([SpotifyPlaylist]?, SpotifyError) {
        var all: [SpotifyPlaylist] = []
        var offset = 0
        while offset < 200 {
            let r = await send("GET", "/me/playlists?limit=50&offset=\(offset)")
            guard r.ok else { return all.isEmpty ? (nil, r.error) : (all, .none) }
            let (page, more) = Self.parsePlaylists(r.body)
            all += page.filter { $0.collaborative || $0.ownerId == meId }
            if !more { break }
            offset += 50
        }
        return (all, .none)
    }

    /// POST /playlists/{id}/items (febbraio 2026); ripiego su /tracks.
    func addToPlaylist(_ playlistId: String, uri: String) async -> SpotifyError {
        let id = Self.esc(playlistId)
        var r = await send("POST", "/playlists/\(id)/items", json: ["uris": [uri]])
        if r.error == .notFound { r = await send("POST", "/playlists/\(id)/tracks", json: ["uris": [uri]]) }
        return r.error
    }

    func queue() async -> ([SpotifyQueueEntry]?, SpotifyError) {
        let r = await send("GET", "/me/player/queue")
        return r.ok ? (Self.parseQueue(r.body, max: 5), .none) : (nil, r.error)
    }

    func search(_ q: String) async -> ([SpotifyTrack]?, SpotifyError) {
        let r = await send("GET", "/search?type=track&limit=6&q=" + Self.esc(q))
        return r.ok ? (Self.parseSearch(r.body), .none) : (nil, r.error)
    }

    func play(_ uri: String) async -> SpotifyError {
        await send("PUT", "/me/player/play", json: ["uris": [uri]]).error
    }

    func enqueue(_ uri: String) async -> SpotifyError {
        await send("POST", "/me/player/queue?uri=" + Self.esc(uri)).error
    }

    // MARK: - Parsing

    private static func esc(_ s: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s
    }

    private static func obj(_ d: Data) -> [String: Any]? { (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] }
    private static func str(_ d: [String: Any]?, _ k: String) -> String? { d?[k] as? String }

    static func parseTokens(_ body: String) -> (access: String, expiresIn: Int, refresh: String?)? {
        guard let d = obj(Data(body.utf8)), let a = str(d, "access_token"), !a.isEmpty else { return nil }
        return (a, (d["expires_in"] as? NSNumber)?.intValue ?? 3600, str(d, "refresh_token"))
    }

    static func parseMe(_ data: Data) -> SpotifyMe? {
        guard let d = obj(data), let id = str(d, "id"), !id.isEmpty else { return nil }
        let name = str(d, "display_name")?.trimmingCharacters(in: .whitespaces) ?? ""
        return SpotifyMe(id: id, displayName: name.isEmpty ? id : name)
    }

    static func parseCurrentlyPlaying(_ data: Data) -> SpotifyTrack? {
        guard let d = obj(data) else { return nil }
        if let type = str(d, "currently_playing_type"), type != "track" { return nil }
        return (d["item"] as? [String: Any]).flatMap(parseTrack)
    }

    static func parseQueue(_ data: Data, max: Int) -> [SpotifyQueueEntry] {
        guard let d = obj(data), let q = d["queue"] as? [[String: Any]] else { return [] }
        var out: [SpotifyQueueEntry] = []
        for it in q where out.count < max {
            guard let name = str(it, "name"), !name.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
            var artist = artists(it)
            if artist.isEmpty { artist = str(it["show"] as? [String: Any], "name") ?? "" }
            out.append(SpotifyQueueEntry(name: name, artist: artist))
        }
        return out
    }

    static func parsePlaylists(_ data: Data) -> ([SpotifyPlaylist], Bool) {
        guard let d = obj(data) else { return ([], false) }
        let more = d["next"] is String
        guard let items = d["items"] as? [Any] else { return ([], more) }
        var out: [SpotifyPlaylist] = []
        for case let p as [String: Any] in items {
            guard let id = str(p, "id"), !id.isEmpty else { continue }
            let owner = str(p["owner"] as? [String: Any], "id") ?? ""
            let collab = p["collaborative"] as? Bool ?? false
            // Febbraio 2026: "tracks" è diventato "items"; leggiamo quello che c'è.
            let t = (p["items"] as? [String: Any]) ?? (p["tracks"] as? [String: Any])
            let count = (t?["total"] as? NSNumber)?.intValue ?? 0
            out.append(SpotifyPlaylist(id: id, name: str(p, "name") ?? "", count: count, ownerId: owner, collaborative: collab))
        }
        return (out, more)
    }

    static func parseSearch(_ data: Data) -> [SpotifyTrack] {
        guard let d = obj(data), let tracks = d["tracks"] as? [String: Any], let items = tracks["items"] as? [Any] else { return [] }
        return items.compactMap { ($0 as? [String: Any]).flatMap(parseTrack) }
    }

    static func parseContains(_ data: Data) -> Bool? {
        guard let arr = (try? JSONSerialization.jsonObject(with: data)) as? [Any], let first = arr.first as? Bool else { return nil }
        return first
    }

    static func isPremiumRequired(_ data: Data) -> Bool {
        str(obj(data)?["error"] as? [String: Any], "reason") == "PREMIUM_REQUIRED"
    }

    private static func parseTrack(_ it: [String: Any]) -> SpotifyTrack? {
        if let type = str(it, "type"), type != "track" { return nil }
        guard let uri = str(it, "uri"), !uri.isEmpty, let name = str(it, "name") else { return nil }
        let local = it["is_local"] as? Bool ?? false
        var image: String?
        if let album = it["album"] as? [String: Any], let imgs = album["images"] as? [[String: Any]] {
            // La più piccola che sia almeno 48 px (Spotify le elenca dalla più grande).
            var best = Int.max
            for img in imgs {
                guard let url = str(img, "url") else { continue }
                let w = (img["width"] as? NSNumber)?.intValue ?? 300
                if w >= 48, w < best { best = w; image = url }
                if image == nil { image = url }
            }
        }
        let imageURL = image.flatMap(URL.init(string:)).flatMap { $0.scheme == "https" ? $0 : nil }
        return SpotifyTrack(id: local ? nil : str(it, "id"), uri: uri, name: name, artist: artists(it), imageURL: imageURL)
    }

    private static func artists(_ it: [String: Any]) -> String {
        guard let a = it["artists"] as? [[String: Any]] else { return "" }
        return a.compactMap { str($0, "name") }.filter { !$0.isEmpty }.joined(separator: ", ")
    }
}
