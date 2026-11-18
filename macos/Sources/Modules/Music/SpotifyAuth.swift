import CryptoKit
import Foundation
import Network
import Security

/// Authorization Code con PKCE (niente client secret): verifier, challenge, state, URL.
enum SpotifyPKCE {
    /// Deve restare identico a quello registrato nell'app Spotify dell'utente.
    static let redirectURI = "http://127.0.0.1:47322/callback"
    static let port: UInt16 = 47322
    static let scopes = "user-read-playback-state user-modify-playback-state user-read-currently-playing "
        + "user-library-read user-library-modify playlist-read-private playlist-read-collaborative "
        + "playlist-modify-private playlist-modify-public"

    static func isValidClientId(_ id: String) -> Bool {
        id.count == 32 && id.allSatisfy(\.isHexDigit)
    }

    /// 64 byte casuali → 86 caratteri base64url (RFC 7636: 43–128).
    static func makeVerifier() -> String { base64URL(randomBytes(64)) }
    static func challenge(_ verifier: String) -> String { base64URL(Data(SHA256.hash(data: Data(verifier.utf8)))) }
    static func makeState() -> String { base64URL(randomBytes(24)) }

    static func stateMatches(_ expected: String, _ actual: String?) -> Bool {
        guard let actual, !expected.isEmpty else { return false }
        let a = Array(expected.utf8), b = Array(actual.utf8)
        guard a.count == b.count else { return false }
        var diff: UInt8 = 0
        for i in 0..<a.count { diff |= a[i] ^ b[i] }
        return diff == 0
    }

    static func authorizeURL(clientId: String, challenge: String, state: String) -> URL {
        var c = URLComponents(string: "https://accounts.spotify.com/authorize")!
        c.queryItems = [
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "client_id", value: clientId),
            URLQueryItem(name: "scope", value: scopes),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "state", value: state),
        ]
        return c.url!
    }

    static func parseQuery(_ query: String) -> [String: String] {
        var out: [String: String] = [:]
        for part in query.split(separator: "&") {
            let kv = part.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            func dec(_ s: Substring) -> String {
                String(s).replacingOccurrences(of: "+", with: " ").removingPercentEncoding ?? String(s)
            }
            let k = dec(kv[0])
            if out[k] == nil { out[k] = kv.count > 1 ? dec(kv[1]) : "" }
        }
        return out
    }

    private static func randomBytes(_ n: Int) -> Data {
        var d = Data(count: n)
        let ok = d.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, n, $0.baseAddress!) }
        if ok != errSecSuccess { d = Data((0..<n).map { _ in UInt8.random(in: 0...255) }) }
        return d
    }

    static func base64URL(_ d: Data) -> String {
        d.base64EncodedString()
            .replacingOccurrences(of: "=", with: "")
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
    }
}

enum LoginOutcome: Sendable { case code(String, verifier: String), denied, portBusy, timeout, cancelled, failed }

/// Un accesso: apre il browser sulla pagina di Spotify e aspetta (max 5 minuti) il ritorno su un
/// piccolo server HTTP locale (`NWListener` solo su 127.0.0.1). Il server esiste solo qui dentro.
final class SpotifyLogin: @unchecked Sendable {
    private let queue = DispatchQueue(label: "isola.music.spotify-login")
    private var listener: NWListener?
    private var continuation: CheckedContinuation<LoginOutcome, Never>?
    private var timeout: DispatchWorkItem?
    private var cancelled = false
    private let verifier = SpotifyPKCE.makeVerifier()
    private let state = SpotifyPKCE.makeState()

    static func run(clientId: String, openBrowser: @escaping @Sendable (URL) -> Bool) async -> LoginOutcome {
        let login = SpotifyLogin()
        return await withTaskCancellationHandler {
            await login.start(clientId: clientId, openBrowser: openBrowser)
        } onCancel: {
            login.queue.async {
                login.cancelled = true
                login.finish(.cancelled)
            }
        }
    }

    private func start(clientId: String, openBrowser: @escaping @Sendable (URL) -> Bool) async -> LoginOutcome {
        await withCheckedContinuation { (cont: CheckedContinuation<LoginOutcome, Never>) in
            queue.async { [self] in
                continuation = cont
                if cancelled { finish(.cancelled); return }
                let params = NWParameters.tcp
                params.allowLocalEndpointReuse = true
                params.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: SpotifyPKCE.port)!)
                guard let l = try? NWListener(using: params) else { finish(.portBusy); return }
                listener = l
                let url = SpotifyPKCE.authorizeURL(clientId: clientId, challenge: SpotifyPKCE.challenge(verifier), state: state)
                var opened = false
                l.stateUpdateHandler = { [weak self] st in
                    guard let self else { return }
                    switch st {
                    case .ready:
                        if !opened {
                            opened = true
                            if !openBrowser(url) { self.finish(.failed) }
                        }
                    case .failed(let err):
                        if case .posix(let code) = err, code == .EADDRINUSE { self.finish(.portBusy) } else { self.finish(.failed) }
                    default: break
                    }
                }
                l.newConnectionHandler = { [weak self] conn in self?.accept(conn) }
                l.start(queue: queue)
                let t = DispatchWorkItem { [weak self] in self?.finish(.timeout) }
                timeout = t
                queue.asyncAfter(deadline: .now() + 300, execute: t)
            }
        }
    }

    /// Sempre sulla coda `queue`.
    private func finish(_ outcome: LoginOutcome) {
        timeout?.cancel()
        timeout = nil
        listener?.cancel()
        listener = nil
        continuation?.resume(returning: outcome)
        continuation = nil
    }

    private func accept(_ conn: NWConnection) {
        // Solo connessioni dal Mac stesso (il listener è già legato a 127.0.0.1).
        if case .hostPort(let host, _) = conn.endpoint {
            let h = "\(host)"
            if !(h == "127.0.0.1" || h == "::1" || h.hasPrefix("127.")) { conn.cancel(); return }
        }
        conn.start(queue: queue)
        receive(conn, buffer: Data())
    }

    private func receive(_ conn: NWConnection, buffer: Data) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, done, error in
            guard let self else { conn.cancel(); return }
            var buf = buffer
            if let data { buf.append(data) }
            if let end = buf.range(of: Data("\r\n\r\n".utf8)) {
                self.handle(conn, head: buf.subdata(in: buf.startIndex..<end.lowerBound))
            } else if done || error != nil || buf.count > 16_384 {
                conn.cancel()
            } else {
                self.receive(conn, buffer: buf)
            }
        }
    }

    private func handle(_ conn: NWConnection, head: Data) {
        let firstLine = String(decoding: head, as: UTF8.self).components(separatedBy: "\r\n").first ?? ""
        let parts = firstLine.split(separator: " ")
        guard parts.count >= 2, parts[0] == "GET" else {
            respond(conn, 400, "Richiesta non valida", "")
            return
        }
        let target = String(parts[1])
        let path = target.split(separator: "?", maxSplits: 1).first.map(String.init) ?? target
        guard path == "/callback" || path == "/callback/" else {
            respond(conn, 404, "Pagina non trovata", "")
            return
        }
        let query = target.contains("?") ? String(target.split(separator: "?", maxSplits: 1)[1]) : ""
        let q = SpotifyPKCE.parseQuery(query)
        guard SpotifyPKCE.stateMatches(state, q["state"]) else {
            // Non è la nostra richiesta (o è falsa): la ignoriamo e aspettiamo quella vera.
            respond(conn, 400, "Richiesta non valida", "Torna su Isola e riprova a collegare Spotify.")
            return
        }
        if q["error"] != nil {
            respond(conn, 200, "Accesso annullato", "Spotify non è stato collegato. Puoi chiudere questa scheda.")
            finish(.denied)
            return
        }
        if let code = q["code"], !code.isEmpty {
            respond(conn, 200, "Spotify collegato, puoi chiudere questa scheda", "Torna pure su Isola.")
            finish(.code(code, verifier: verifier))
            return
        }
        respond(conn, 400, "Richiesta non valida", "Torna su Isola e riprova a collegare Spotify.")
    }

    private func respond(_ conn: NWConnection, _ status: Int, _ title: String, _ text: String) {
        func esc(_ s: String) -> String {
            s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
                .replacingOccurrences(of: ">", with: "&gt;")
        }
        let html = "<!doctype html><html lang=\"it\"><head><meta charset=\"utf-8\"><title>Isola</title>"
            + "<style>body{margin:0;height:100vh;display:flex;align-items:center;justify-content:center;"
            + "background:#0b0b0d;color:#f2f2f5;font-family:-apple-system,BlinkMacSystemFont,sans-serif}"
            + "div{text-align:center}h1{font-size:20px;font-weight:600;margin:0 0 8px}p{color:#9a9aa3;font-size:14px;margin:0}</style>"
            + "</head><body><div><h1>\(esc(title))</h1><p>\(esc(text))</p></div></body></html>"
        let body = Data(html.utf8)
        let reason = status == 200 ? "OK" : status == 404 ? "Not Found" : "Bad Request"
        let headers = "HTTP/1.1 \(status) \(reason)\r\nContent-Type: text/html; charset=utf-8\r\n"
            + "Cache-Control: no-store\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
        conn.send(content: Data(headers.utf8) + body, isComplete: true, completion: .contentProcessed { _ in conn.cancel() })
    }
}

/// Client ID e refresh token nel Portachiavi (password generica). Il token di accesso resta in memoria.
enum SpotifyKeychain {
    static let service = "com.alessandroloverso.isola.spotify"
    private static let account = "refresh-token"

    struct Credentials: Codable, Equatable, Sendable {
        var clientId: String
        var refreshToken: String
    }

    private static var baseQuery: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    static func load() -> Credentials? {
        var q = baseQuery
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let data = out as? Data,
              let c = try? JSONDecoder().decode(Credentials.self, from: data),
              !c.clientId.isEmpty, !c.refreshToken.isEmpty else { return nil }
        return c
    }

    @discardableResult
    static func save(_ c: Credentials) -> Bool {
        guard let data = try? JSONEncoder().encode(c) else { return false }
        let update: [String: Any] = [kSecValueData as String: data]
        var status = SecItemUpdate(baseQuery as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            var add = baseQuery
            add[kSecValueData as String] = data
            add[kSecAttrLabel as String] = "Isola – Spotify"
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            status = SecItemAdd(add as CFDictionary, nil)
        }
        return status == errSecSuccess
    }

    static func delete() {
        SecItemDelete(baseQuery as CFDictionary)
    }
}
