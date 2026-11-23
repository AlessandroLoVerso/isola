import Foundation

/// Le cartelle di Isola, tutte in ~/Library/Application Support/Isola.
public enum AppPaths {
    public static let root: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Isola", isDirectory: true)
    }()

    public static var settings: URL { ensure(root.appendingPathComponent("settings", isDirectory: true)) }
    public static var logs: URL { ensure(root.appendingPathComponent("logs", isDirectory: true)) }
    public static var globalSettingsFile: URL { ensure(root).appendingPathComponent("settings.json") }

    public static func data(_ id: String) -> URL {
        ensure(root.appendingPathComponent("data", isDirectory: true).appendingPathComponent(id, isDirectory: true))
    }

    public static func settingsFile(_ id: String) -> URL { settings.appendingPathComponent("\(id).json") }

    @discardableResult
    public static func ensure(_ url: URL) -> URL {
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

/// JSON su disco, scritto in modo atomico. File mancante o rotto ⇒ `fallback`.
public enum JSONStore {
    public static func load<T: Decodable>(_ type: T.Type, from url: URL, fallback: T) -> T {
        guard let data = try? Data(contentsOf: url) else { return fallback }
        do { return try decoder.decode(T.self, from: data) }
        catch {
            Log.write("core", "File di impostazioni illeggibile, uso i valori predefiniti")
            return fallback
        }
    }

    public static func save<T: Encodable>(_ value: T, to url: URL) {
        do {
            let data = try encoder.encode(value)
            try data.write(to: url, options: .atomic)
        } catch {
            Log.write("core", "Salvataggio non riuscito: \(error.localizedDescription)")
        }
    }

    public static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    public static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()
}

/// Log in ~/Library/Application Support/Isola/logs/isola.log (ruota a 1 MB).
public enum Log {
    private static let queue = DispatchQueue(label: "isola.log")
    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f
    }()

    public static func write(_ source: String, _ message: String) {
        let line = "\(formatter.string(from: Date())) [\(source)] \(message)\n"
        queue.async {
            let url = AppPaths.logs.appendingPathComponent("isola.log")
            if let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
               let size = attrs[.size] as? Int, size > 1_000_000 {
                let old = AppPaths.logs.appendingPathComponent("isola.old.log")
                try? FileManager.default.removeItem(at: old)
                try? FileManager.default.moveItem(at: url, to: old)
            }
            if let h = try? FileHandle(forWritingTo: url) {
                h.seekToEndOfFile()
                h.write(Data(line.utf8))
                try? h.close()
            } else {
                try? Data(line.utf8).write(to: url)
            }
        }
    }
}
