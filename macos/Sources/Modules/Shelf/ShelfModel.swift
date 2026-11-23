import AppKit
import IsolaCore
import QuickLookThumbnailing
import QuickLookUI
import SwiftUI
import UniformTypeIdentifiers

/// Un file o una cartella sulla mensola. Si tiene solo il riferimento (percorso + segnalibro):
/// i file non vengono mai copiati né cancellati.
struct ShelfItem: Codable, Identifiable, Equatable {
    var id: String = UUID().uuidString
    var path: String
    /// Segnalibro del file (non "security-scoped"): segue il file se viene spostato o rinominato.
    var bookmark: Data?
    var added: Date = Date()

    var url: URL { URL(fileURLWithPath: path) }
    var name: String {
        let n = (path as NSString).lastPathComponent
        return n.isEmpty ? path : n
    }
}

/// Lo stato della mensola: elementi, selezione, miniature, trascinamenti.
@MainActor
final class ShelfModel: ObservableObject {
    static let maxItems = 200

    /// Il più recente per primo.
    @Published private(set) var items: [ShelfItem] = []
    @Published var selection: Set<String> = []
    /// Elementi su un disco esterno o di rete non collegato: restano, ma in grigio.
    @Published private(set) var offline: Set<String> = []
    @Published private(set) var thumbnails: [String: NSImage] = [:]
    /// Un trascinamento di file è sopra la scheda.
    @Published var dropTargeted = false

    weak var host: IslandHost?
    /// Chiamata quando cambia il numero di elementi (faccia sulla pillola).
    var onCountChanged: (() -> Void)?

    private var file: URL?
    private let saveQueue = DispatchQueue(label: "isola.shelf.save", qos: .utility)
    private let probeQueue = DispatchQueue(label: "isola.shelf.probe", qos: .utility)
    private var probeVersion = 0
    private var generation = 0
    private var cardVisible = false
    private var iconCache: [String: NSImage] = [:]
    let dragSource = ShelfDragSource()
    private let preview = ShelfPreview()

    /// Vero mentre un trascinamento parte dalla mensola (per non riprenderselo).
    var draggingOut: Bool { dragSource.active }

    // MARK: ciclo di vita

    func start(host: IslandHost) {
        self.host = host
        generation += 1
        let dir = host.dataDirectory
        ShelfFiles.ensureDirectory(dir)
        file = dir.appendingPathComponent("shelf.json")
        items = load()
        dragSource.onEnded = { [weak self] urls, op in self?.dragEnded(urls: urls, operation: op) }
        refreshExistence()
    }

    func stop() {
        generation += 1
        probeVersion += 1
        saveQueue.sync {}
        preview.close()
        dragSource.onEnded = nil
        items = []
        selection = []
        offline = []
        thumbnails = [:]
        iconCache = [:]
        dropTargeted = false
        cardVisible = false
        file = nil
        host = nil
    }

    func cardBecameVisible(_ visible: Bool) {
        cardVisible = visible
        if visible { refreshExistence() } else { dropTargeted = false }
    }

    // MARK: aggiungere

    /// I file lasciati sulla scheda. I segnalibri si creano fuori dal main thread.
    func add(providers: [NSItemProvider]) -> Bool {
        let fileProviders = providers.filter { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }
        guard !fileProviders.isEmpty, host != nil else { return false }
        let gen = generation
        let group = DispatchGroup()
        let lock = NSLock()
        var found: [(Int, URL, Data?)] = []
        for (i, p) in fileProviders.enumerated() {
            group.enter()
            _ = p.loadObject(ofClass: NSURL.self) { obj, _ in
                defer { group.leave() }
                guard let url = (obj as? NSURL) as URL?, url.isFileURL else { return }
                let std = url.standardizedFileURL
                let bookmark = try? std.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
                lock.lock(); found.append((i, std, bookmark)); lock.unlock()
            }
        }
        group.notify(queue: .main) { [weak self] in
            guard let self, gen == self.generation else { return }
            let sorted = found.sorted { $0.0 < $1.0 }
            self.add(sorted.map { ($0.1, $0.2) })
        }
        return true
    }

    private func add(_ entries: [(URL, Data?)]) {
        var known = Set(items.map(\.path))
        var new: [ShelfItem] = []
        for (url, bookmark) in entries {
            let path = url.path
            guard !path.isEmpty, known.insert(path).inserted else { continue }
            new.append(ShelfItem(path: path, bookmark: bookmark, added: Date()))
        }
        guard !new.isEmpty else { return }
        items.insert(contentsOf: new.reversed(), at: 0)
        if items.count > Self.maxItems {
            for gone in items[Self.maxItems...] { forget(gone.id) }
            items.removeLast(items.count - Self.maxItems)
        }
        for item in new { loadThumbnail(item) }
        changed()
    }

    // MARK: togliere

    func remove(_ ids: Set<String>) {
        guard !ids.isEmpty else { return }
        let before = items.count
        items.removeAll { ids.contains($0.id) }
        for id in ids { forget(id) }
        if items.count != before { changed() }
    }

    func clear() { remove(Set(items.map(\.id))) }

    private func forget(_ id: String) {
        selection.remove(id)
        offline.remove(id)
        thumbnails[id] = nil
    }

    // MARK: azioni

    var selectedItems: [ShelfItem] { items.filter { selection.contains($0.id) } }

    /// La selezione, oppure tutti se non c'è selezione. Solo i file raggiungibili.
    var targetItems: [ShelfItem] {
        let base = selection.isEmpty ? items : selectedItems
        return base.filter { !offline.contains($0.id) }
    }

    func toggleSelection(_ item: ShelfItem) {
        guard !offline.contains(item.id) else { return }
        if selection.contains(item.id) { selection.remove(item.id) } else { selection.insert(item.id) }
    }

    func toggleSelectAll() {
        if selection.isEmpty {
            selection = Set(items.filter { !offline.contains($0.id) }.map(\.id))
        } else {
            selection = []
        }
    }

    /// Cosa trascinare partendo da `item`: il gruppo selezionato se ne fa parte, altrimenti solo lui.
    func dragURLs(from item: ShelfItem) -> [URL] {
        let group = selection.contains(item.id) ? selectedItems : [item]
        return group.filter { !offline.contains($0.id) && FileManager.default.fileExists(atPath: $0.path) }
            .map(\.url)
    }

    func open(_ item: ShelfItem) {
        guard FileManager.default.fileExists(atPath: item.path) else { refreshExistence(); return }
        NSWorkspace.shared.open(item.url)
    }

    func reveal(_ list: [ShelfItem]) {
        let urls = list.map(\.url).filter { FileManager.default.fileExists(atPath: $0.path) }
        guard !urls.isEmpty else { return }
        NSWorkspace.shared.activateFileViewerSelecting(urls)
    }

    static var airDrop: NSSharingService? { NSSharingService(named: .sendViaAirDrop) }

    func airDrop(_ list: [ShelfItem]) {
        let urls = list.map(\.url)
        guard !urls.isEmpty, let service = Self.airDrop, service.canPerform(withItems: urls) else {
            host?.log("AirDrop non disponibile")
            return
        }
        service.perform(withItems: urls)
    }

    func quickLook(_ list: [ShelfItem]) {
        let urls = list.map(\.url).filter { FileManager.default.fileExists(atPath: $0.path) }
        guard !urls.isEmpty else { return }
        preview.show(urls)
    }

    func icon(_ item: ShelfItem) -> NSImage {
        if let i = iconCache[item.path] { return i }
        let icon = NSWorkspace.shared.icon(forFile: item.path)
        iconCache[item.path] = icon
        return icon
    }

    private func dragEnded(urls: [URL], operation: NSDragOperation) {
        // Spostati altrove (es. nel Finder sullo stesso disco): non sono più sulla mensola.
        if operation.contains(.move) || operation.contains(.delete) {
            let paths = Set(urls.map(\.path))
            remove(Set(items.filter { paths.contains($0.path) }.map(\.id)))
        }
        refreshExistence()
    }

    // MARK: esistenza

    /// Ricontrolla i file fuori dal main thread (un disco di rete può rispondere lentamente).
    /// Un file spostato o rinominato si ritrova col segnalibro; uno sparito (o nel Cestino) si toglie.
    func refreshExistence() {
        guard host != nil, !items.isEmpty else { return }
        probeVersion += 1
        let version = probeVersion
        let snapshot = items
        probeQueue.async { [weak self] in
            let results = snapshot.map { ShelfProbe.check($0) }
            DispatchQueue.main.async {
                guard let self, version == self.probeVersion, self.host != nil else { return }
                self.apply(results)
            }
        }
    }

    private func apply(_ results: [ShelfProbe.Result]) {
        var changedAny = false
        var gone = Set<String>()
        var off = offline
        for r in results {
            switch r.state {
            case .ok(let path, let bookmark):
                off.remove(r.id)
                if let i = items.firstIndex(where: { $0.id == r.id }) {
                    if items[i].path != path { items[i].path = path; changedAny = true; thumbnails[r.id] = nil }
                    if let bookmark, bookmark != items[i].bookmark { items[i].bookmark = bookmark; changedAny = true }
                    // Miniature solo a scheda aperta: niente lavoro a vuoto all'avvio.
                    if thumbnails[r.id] == nil, cardVisible { loadThumbnail(items[i]) }
                }
            case .offline:
                off.insert(r.id)
            case .gone:
                gone.insert(r.id)
            }
        }
        if off != offline { offline = off }
        if !gone.isEmpty {
            items.removeAll { gone.contains($0.id) }
            for id in gone { forget(id) }
            changedAny = true
        }
        if changedAny { changed() }
    }

    // MARK: miniature

    private func loadThumbnail(_ item: ShelfItem) {
        let id = item.id
        let gen = generation
        let request = QLThumbnailGenerator.Request(fileAt: item.url, size: CGSize(width: 48, height: 48),
                                                   scale: 2, representationTypes: .thumbnail)
        QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { [weak self] rep, _ in
            guard let rep else { return }
            let image = rep.nsImage
            DispatchQueue.main.async {
                guard let self, gen == self.generation, self.items.contains(where: { $0.id == id }) else { return }
                self.thumbnails[id] = image
            }
        }
    }

    // MARK: salvataggio

    private struct Stored: Codable {
        var version = 1
        var items: [ShelfItem] = []
    }

    private func load() -> [ShelfItem] {
        guard let file, let data = try? Data(contentsOf: file) else { return [] }
        guard let stored = try? ShelfFiles.decoder.decode(Stored.self, from: data) else {
            host?.log("shelf.json illeggibile, mensola vuota")
            return []
        }
        return Array(stored.items.filter { !$0.path.isEmpty }.prefix(Self.maxItems))
    }

    private func changed() {
        save()
        onCountChanged?()
    }

    private func save() {
        guard let file else { return }
        let snapshot = Stored(items: items)
        saveQueue.async { [weak self] in
            do {
                try ShelfFiles.write(try ShelfFiles.encoder.encode(snapshot), to: file)
            } catch {
                DispatchQueue.main.async { self?.host?.log("Salvataggio della mensola non riuscito") }
            }
        }
    }
}

// MARK: - Controllo dei file

enum ShelfProbe {
    enum State {
        case ok(path: String, bookmark: Data?)
        case offline
        case gone
    }

    struct Result {
        var id: String
        var state: State
    }

    /// Tocca il disco: fuori dal main thread.
    static func check(_ item: ShelfItem) -> Result {
        let fm = FileManager.default
        if let data = item.bookmark {
            var stale = false
            if let url = try? URL(resolvingBookmarkData: data, options: [.withoutUI, .withoutMounting],
                                  relativeTo: nil, bookmarkDataIsStale: &stale) {
                let path = url.standardizedFileURL.path
                if isInTrash(path) { return Result(id: item.id, state: .gone) }
                if fm.fileExists(atPath: path) {
                    let fresh = stale ? try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil) : nil
                    return Result(id: item.id, state: .ok(path: path, bookmark: fresh))
                }
            }
        }
        if fm.fileExists(atPath: item.path) {
            let fresh = item.bookmark == nil
                ? try? item.url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
                : nil
            return Result(id: item.id, state: .ok(path: item.path, bookmark: fresh))
        }
        // Disco esterno o di rete scollegato: il file c'è ancora, il disco no.
        let parts = item.path.split(separator: "/", omittingEmptySubsequences: true)
        if parts.count >= 2, parts[0] == "Volumes", !fm.fileExists(atPath: "/Volumes/\(parts[1])") {
            return Result(id: item.id, state: .offline)
        }
        return Result(id: item.id, state: .gone)
    }

    private static func isInTrash(_ path: String) -> Bool {
        path.contains("/.Trash/") || path.contains("/.Trashes/")
    }
}

// MARK: - Trascinare fuori

/// La sorgente dei trascinamenti: vive nel modello, così il trascinamento continua anche se
/// l'isola si richiude mentre il puntatore va verso il Finder.
final class ShelfDragSource: NSObject, NSDraggingSource {
    var active = false
    var urls: [URL] = []
    var onEnded: (([URL], NSDragOperation) -> Void)?

    func draggingSession(_ session: NSDraggingSession,
                         sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        // Dentro Isola niente (la mensola non riprende i suoi file); fuori come dal Finder.
        context == .outsideApplication ? [.copy, .move, .link, .generic] : []
    }

    func draggingSession(_ session: NSDraggingSession, willBeginAt screenPoint: NSPoint) {
        active = true
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        active = false
        let done = urls
        urls = []
        let handler = onEnded
        DispatchQueue.main.async { handler?(done, operation) }
    }
}

// MARK: - Quick Look

final class ShelfPreview: NSObject, QLPreviewPanelDataSource {
    private var urls: [URL] = []

    @MainActor
    func show(_ urls: [URL]) {
        self.urls = urls
        guard let panel = QLPreviewPanel.shared() else { return }
        panel.dataSource = self
        panel.reloadData()
        panel.currentPreviewItemIndex = 0
        // L'isola non attiva l'app; l'anteprima deve stare davanti alle altre finestre.
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
    }

    @MainActor
    func close() {
        guard QLPreviewPanel.sharedPreviewPanelExists(), let panel = QLPreviewPanel.shared() else { urls = []; return }
        if panel.dataSource === self {
            if panel.isVisible { panel.orderOut(nil) }
            panel.dataSource = nil
        }
        urls = []
    }

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { urls.count }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! {
        urls.indices.contains(index) ? urls[index] as NSURL : nil
    }
}

// MARK: - File privati

enum ShelfFiles {
    static func ensureDirectory(_ url: URL) {
        let fm = FileManager.default
        try? fm.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
    }

    /// File temporaneo 0600 rinominato sopra il vecchio (atomico).
    static func write(_ data: Data, to url: URL) throws {
        let tmp = url.deletingLastPathComponent()
            .appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).tmp")
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
