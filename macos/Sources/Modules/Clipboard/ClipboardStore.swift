import Foundation

/// Cosa c'è in un elemento della cronologia.
enum ClipKind: String, Codable {
    case text, link, image, files
}

/// Un elemento ricordato, come sta in history.json.
struct ClipItem: Codable, Identifiable, Equatable {
    var id: String = UUID().uuidString
    var kind: ClipKind
    var text: String?
    /// Percorsi dei file copiati (solo per `files`).
    var files: [String]?
    /// Nome del PNG intero dentro images/; la miniatura è "<id>.thumb.png".
    var image: String?
    var imageWidth: Int = 0
    var imageHeight: Int = 0
    /// Impronta del contenuto, per non ripetere lo stesso elemento.
    var hash: String = ""
    var pinned: Bool = false
    var time: Date = Date()
}

/// Impostazioni del modulo. Le chiavi mancanti prendono il valore predefinito.
struct ClipboardSettings: Codable, Equatable {
    var enabled = true
    var maxItems = 200
    var ignoredApps: [IgnoredApp] = []
    var hotKeyEnabled = true
    var hotKey: ClipHotKey = .optionCommandV

    struct IgnoredApp: Codable, Equatable, Hashable {
        var bundleId: String
        var name: String
    }

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = ClipboardSettings()
        enabled = (try? c.decodeIfPresent(Bool.self, forKey: .enabled)) ?? d.enabled
        maxItems = (try? c.decodeIfPresent(Int.self, forKey: .maxItems)) ?? d.maxItems
        ignoredApps = (try? c.decodeIfPresent([IgnoredApp].self, forKey: .ignoredApps)) ?? d.ignoredApps
        hotKeyEnabled = (try? c.decodeIfPresent(Bool.self, forKey: .hotKeyEnabled)) ?? d.hotKeyEnabled
        hotKey = (try? c.decodeIfPresent(ClipHotKey.self, forKey: .hotKey)) ?? d.hotKey
    }

    static let sizeChoices = [50, 100, 200, 500]
}

/// Le combinazioni proposte per aprire gli Appunti.
enum ClipHotKey: String, Codable, CaseIterable, Identifiable {
    case optionCommandV, controlOptionV, controlCommandV, shiftOptionCommandV

    var id: String { rawValue }

    var label: String {
        switch self {
        case .optionCommandV: return "⌥⌘V"
        case .controlOptionV: return "⌃⌥V"
        case .controlCommandV: return "⌃⌘V"
        case .shiftOptionCommandV: return "⇧⌥⌘V"
        }
    }
}

/// history.json + images/ nella cartella dati del modulo, leggibili solo dall'utente
/// (cartelle 0700, file 0600). Le scritture avvengono fuori dal main thread, sempre l'ultima
/// istantanea e in ordine.
final class ClipboardStore {
    let dataDir: URL
    let imagesDir: URL
    private let file: URL
    private let queue = DispatchQueue(label: "isola.clipboard.store", qos: .utility)
    private let lock = NSLock()
    private var version = 0

    init(dataDir: URL) {
        self.dataDir = dataDir
        imagesDir = dataDir.appendingPathComponent("images", isDirectory: true)
        file = dataDir.appendingPathComponent("history.json")
        PrivateFiles.ensureDirectory(dataDir)
        PrivateFiles.ensureDirectory(imagesDir)
        PrivateFiles.excludeFromBackup(dataDir)
    }

    private struct History: Codable {
        var version = 1
        var items: [ClipItem] = []
    }

    func load() -> [ClipItem] {
        guard let data = try? Data(contentsOf: file) else { return [] }
        return (try? Self.decoder.decode(History.self, from: data))?.items ?? []
    }

    func save(_ items: [ClipItem], log: @escaping (String) -> Void) {
        lock.lock(); version += 1; let v = version; lock.unlock()
        let file = self.file
        queue.async { [weak self] in
            guard let self else { return }
            self.lock.lock(); let latest = self.version; self.lock.unlock()
            if v != latest { return } // ne arriva una più nuova
            do {
                let data = try Self.encoder.encode(History(items: items))
                try PrivateFiles.write(data, to: file)
            } catch {
                log("Salvataggio della cronologia non riuscito")
            }
        }
    }

    /// Aspetta che le scritture in coda siano finite (in `stop`).
    func flush() { queue.sync {} }

    func imageURL(_ name: String) -> URL { imagesDir.appendingPathComponent(name) }
    func thumbURL(_ item: ClipItem) -> URL { imagesDir.appendingPathComponent("\(item.id).thumb.png") }

    func deleteFiles(_ item: ClipItem) {
        guard item.kind == .image else { return }
        let fm = FileManager.default
        if let name = item.image { try? fm.removeItem(at: imageURL(name)) }
        try? fm.removeItem(at: thumbURL(item))
    }

    /// Toglie le immagini che nessun elemento usa più (rimaste dopo un crash).
    func sweepOrphans(_ items: [ClipItem]) {
        var keep = Set<String>()
        for i in items where i.kind == .image {
            if let n = i.image { keep.insert(n) }
            keep.insert("\(i.id).thumb.png")
        }
        let dir = imagesDir
        queue.async {
            let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
            for n in names where n.hasSuffix(".png") && !keep.contains(n) {
                try? FileManager.default.removeItem(at: dir.appendingPathComponent(n))
            }
        }
    }

    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()
}

/// File e cartelle che legge solo l'utente.
enum PrivateFiles {
    static func ensureDirectory(_ url: URL) {
        let fm = FileManager.default
        try? fm.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
    }

    /// Scrive in un file temporaneo 0600 e lo rinomina sopra quello vecchio (atomico).
    static func write(_ data: Data, to url: URL) throws {
        let dir = url.deletingLastPathComponent()
        let tmp = dir.appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).tmp")
        guard FileManager.default.createFile(atPath: tmp.path, contents: data,
                                             attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        if rename(tmp.path, url.path) != 0 {
            let code = errno
            unlink(tmp.path)
            throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
        }
    }

    /// La cronologia degli appunti non finisce nei backup di Time Machine.
    static func excludeFromBackup(_ url: URL) {
        var u = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? u.setResourceValues(values)
    }
}
