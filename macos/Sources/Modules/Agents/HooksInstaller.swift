import Foundation

/// Aggiunge e toglie gli hook "curl" di Isola in un settings.json di Claude Code, lasciando
/// intatto tutto il resto. Solo logica sui file (percorso in, risultato out): si prova su una copia.
enum HooksInstaller {
    static let command = "curl -s -m 1 -X POST http://127.0.0.1:47321/agent --data-binary @-"

    /// Evento → matcher (nil = senza matcher).
    static let events: [(event: String, matcher: String?)] = [
        ("UserPromptSubmit", nil), ("PreToolUse", "*"), ("PostToolUse", "*"),
        ("Notification", nil), ("Stop", nil), ("SessionEnd", nil),
    ]

    static var defaultURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude", isDirectory: true)
            .appendingPathComponent("settings.json")
    }

    /// Il percorso da mostrare, con "~" al posto della cartella Inizio.
    static func displayPath(_ url: URL) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let p = url.path
        return p.hasPrefix(home + "/") ? "~" + p.dropFirst(home.count) : p
    }

    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    enum Status: Equatable {
        case connected
        case partial
        case disconnected
        case unreadable(String)
    }

    static func status(at url: URL) -> Status {
        guard FileManager.default.fileExists(atPath: url.path) else { return .disconnected }
        do {
            guard let hooks = try load(url)["hooks"] as? [String: Any] else { return .disconnected }
            let found = events.filter { (hooks[$0.event] as? [Any]).map(contains) ?? false }.count
            return found == events.count ? .connected : (found == 0 ? .disconnected : .partial)
        } catch {
            return .unreadable(error.localizedDescription)
        }
    }

    /// Aggiunge i nostri hook. Ritorna quanti ne ha aggiunti; prima fa una copia del file.
    @discardableResult
    static func install(at url: URL) throws -> Int {
        var root = FileManager.default.fileExists(atPath: url.path) ? try load(url) : [:]
        // Mai sostituire quello che non si capisce: un "hooks" che non è un oggetto (o un evento
        // che non è una lista) ferma tutto invece di essere sovrascritto.
        var hooks: [String: Any]
        if root["hooks"] == nil || root["hooks"] is NSNull {
            hooks = [:]
        } else if let h = root["hooks"] as? [String: Any] {
            hooks = h
        } else {
            throw Failure(message: "\"hooks\" in settings.json non è un oggetto")
        }
        var added = 0
        for (event, matcher) in events {
            var groups: [Any]
            if hooks[event] == nil || hooks[event] is NSNull {
                groups = []
            } else if let g = hooks[event] as? [Any] {
                groups = g
            } else {
                throw Failure(message: "\"hooks.\(event)\" in settings.json non è una lista")
            }
            if contains(groups) { continue }
            var group: [String: Any] = [:]
            if let matcher { group["matcher"] = matcher }
            group["hooks"] = [["type": "command", "command": command] as [String: Any]]
            groups.append(group)
            hooks[event] = groups
            added += 1
        }
        if added > 0 {
            root["hooks"] = hooks
            try save(root, to: url)
        }
        return added
    }

    /// Toglie solo le nostre voci (e i gruppi o eventi rimasti vuoti per questo). Ritorna quante.
    @discardableResult
    static func uninstall(at url: URL) throws -> Int {
        guard FileManager.default.fileExists(atPath: url.path) else { return 0 }
        var root = try load(url)
        guard var hooks = root["hooks"] as? [String: Any] else { return 0 }
        var removed = 0
        for (event, _) in events {
            guard var groups = hooks[event] as? [Any] else { continue }
            var changed = false
            for g in stride(from: groups.count - 1, through: 0, by: -1) {
                guard var group = groups[g] as? [String: Any], let list = group["hooks"] as? [Any] else { continue }
                let kept = list.filter { !isOurs($0) }
                guard kept.count != list.count else { continue }
                removed += list.count - kept.count
                changed = true
                if kept.isEmpty {
                    groups.remove(at: g)
                } else {
                    group["hooks"] = kept
                    groups[g] = group
                }
            }
            guard changed else { continue }
            if groups.isEmpty { hooks.removeValue(forKey: event) } else { hooks[event] = groups }
        }
        guard removed > 0 else { return 0 }
        if hooks.isEmpty { root.removeValue(forKey: "hooks") } else { root["hooks"] = hooks }
        try save(root, to: url)
        return removed
    }

    // MARK: interni

    private static func contains(_ groups: [Any]) -> Bool {
        groups.contains { g in
            guard let list = (g as? [String: Any])?["hooks"] as? [Any] else { return false }
            return list.contains(where: isOurs)
        }
    }

    private static func isOurs(_ item: Any) -> Bool {
        (item as? [String: Any])?["command"] as? String == command
    }

    private static func load(_ url: URL) throws -> [String: Any] {
        let data = try Data(contentsOf: url)
        if data.allSatisfy({ $0 == 0x20 || $0 == 0x0A || $0 == 0x0D || $0 == 0x09 }) { return [:] }
        let obj: Any
        do {
            obj = try JSONSerialization.jsonObject(with: data, options: [])
        } catch {
            // Con commenti o virgole in più il file si legge, ma riscriverlo li perderebbe.
            if (try? JSONSerialization.jsonObject(with: data, options: [.json5Allowed])) != nil {
                throw Failure(message: "settings.json contiene commenti: Isola non lo modifica per non perderli")
            }
            throw Failure(message: "settings.json non è un JSON valido")
        }
        guard let root = obj as? [String: Any] else {
            throw Failure(message: "settings.json non è un oggetto JSON")
        }
        return root
    }

    private static func save(_ root: [String: Any], to url: URL) throws {
        let fm = FileManager.default
        // Se settings.json è un collegamento (dotfiles), si scrive il file vero e si lascia il link.
        let target = url.resolvingSymlinksInPath()
        let dir = target.deletingLastPathComponent()
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)

        var mode: mode_t = 0o644
        if fm.fileExists(atPath: target.path) {
            if let p = (try? fm.attributesOfItem(atPath: target.path))?[.posixPermissions] as? NSNumber {
                mode = mode_t(p.uint16Value)
            }
            let stamp = backupStamp()
            let backup = URL(fileURLWithPath: url.path + ".isola-backup-" + stamp)
            if fm.fileExists(atPath: backup.path) { try fm.removeItem(at: backup) }
            try fm.copyItem(at: target, to: backup)
        }

        var data = try JSONSerialization.data(withJSONObject: root,
                                              options: [.prettyPrinted, .withoutEscapingSlashes, .sortedKeys])
        data.append(0x0A)
        _ = try JSONSerialization.jsonObject(with: data) // controllo prima di sostituire

        let tmp = dir.appendingPathComponent(target.lastPathComponent + ".isola-tmp")
        do {
            try writeSynced(data, to: tmp, mode: mode)
            // rename è atomico: c'è il file vecchio o quello nuovo, mai mezzo.
            guard rename(tmp.path, target.path) == 0 else {
                throw Failure(message: "impossibile sostituire settings.json (errore \(errno))")
            }
        } catch {
            try? fm.removeItem(at: tmp)
            throw error
        }
    }

    private static func writeSynced(_ data: Data, to url: URL, mode: mode_t) throws {
        let fd = open(url.path, O_WRONLY | O_CREAT | O_TRUNC | O_NOFOLLOW, mode)
        guard fd >= 0 else { throw Failure(message: "impossibile scrivere accanto a settings.json (errore \(errno))") }
        defer { close(fd) }
        _ = fchmod(fd, mode)
        try data.withUnsafeBytes { (buf: UnsafeRawBufferPointer) in
            var offset = 0
            while offset < buf.count {
                let n = write(fd, buf.baseAddress! + offset, buf.count - offset)
                if n < 0 {
                    if errno == EINTR { continue }
                    throw Failure(message: "scrittura non riuscita (errore \(errno))")
                }
                offset += n
            }
        }
        guard fsync(fd) == 0 else { throw Failure(message: "scrittura non riuscita (errore \(errno))") }
    }

    private static func backupStamp() -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd-HHmmss-SSS"
        return f.string(from: Date())
    }
}
