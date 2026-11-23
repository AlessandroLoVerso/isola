import Foundation
import IsolaCore
import SwiftUI

/// Un modulo con il suo stato: acceso, errore, scheda già creata.
@MainActor
final class ModuleRecord: ObservableObject, Identifiable {
    let module: IslandModule
    let host: ModuleHost
    @Published var running = false
    @Published var error: String?
    var card: AnyView?

    nonisolated var id: ObjectIdentifier { ObjectIdentifier(self) }
    var moduleId: String { module.id }

    init(module: IslandModule, host: ModuleHost) {
        self.module = module
        self.host = host
    }
}

/// Trova, accende e spegne i moduli. Il core non conosce i moduli: li riceve dal registro.
@MainActor
final class ModuleManager: ObservableObject {
    @Published private(set) var records: [ModuleRecord] = []
    weak var island: IslandController?

    private let settings = SettingsStore.shared

    init(types: [IslandModule.Type]) {
        var seen = Set<String>()
        for type in types {
            let module = type.init()
            guard seen.insert(module.id).inserted else {
                Log.write("core", "Modulo con id doppio ignorato: \(module.id)")
                continue
            }
            records.append(ModuleRecord(module: module, host: ModuleHost(moduleId: module.id)))
        }
        records.sort { $0.module.order < $1.module.order }
    }

    var running: [ModuleRecord] { records.filter(\.running) }
    var tabs: [ModuleRecord] { records.filter { $0.running && $0.card != nil } }

    func record(_ id: String) -> ModuleRecord? { records.first { $0.moduleId == id } }

    func isEnabled(_ r: ModuleRecord) -> Bool {
        settings.current.modules[r.moduleId] ?? r.module.enabledByDefault
    }

    func startEnabled() {
        for r in records where isEnabled(r) { start(r) }
        island?.modulesChanged()
    }

    func setEnabled(_ r: ModuleRecord, _ on: Bool) {
        settings.update { $0.modules[r.moduleId] = on }
        if on { start(r) } else { stop(r) }
        island?.modulesChanged()
    }

    private func start(_ r: ModuleRecord) {
        guard !r.running else { return }
        r.host.island = island
        do {
            try r.module.start(host: r.host)
            r.running = true
            r.error = nil
            r.card = r.module.makeCard()
            r.objectWillChange.send()
        } catch {
            r.error = error.localizedDescription
            r.host.reset()
            Log.write(r.moduleId, "Non avviato: \(error.localizedDescription)")
        }
    }

    private func stop(_ r: ModuleRecord) {
        guard r.running else { return }
        r.module.stop()
        r.running = false
        r.card = nil
        r.host.reset()
        r.objectWillChange.send()
    }

    func stopAll() {
        for r in records { stop(r) }
    }

    // MARK: notifiche ai moduli

    func notifyFullscreen(_ on: Bool) {
        for r in running { r.host.fullscreenHandlers.forEach { $0(on) } }
    }

    func notifyCardVisibility(old: String?, new: String?) {
        guard old != new else { return }
        if let old, let r = record(old), r.running { r.host.visibilityHandlers.forEach { $0(false) } }
        if let new, let r = record(new), r.running { r.host.visibilityHandlers.forEach { $0(true) } }
    }
}

/// L'`IslandHost` che riceve ogni modulo.
@MainActor
final class ModuleHost: IslandHost {
    let moduleId: String
    weak var island: IslandController?
    fileprivate(set) var fullscreenHandlers: [(Bool) -> Void] = []
    fileprivate(set) var visibilityHandlers: [(Bool) -> Void] = []

    init(moduleId: String) { self.moduleId = moduleId }

    func reset() {
        fullscreenHandlers = []
        visibilityHandlers = []
    }

    func refreshRestingFace() { island?.refreshFaces() }
    func openTab(_ moduleId: String) { island?.openTab(moduleId) }
    func attention(duration: TimeInterval) { island?.attention(moduleId, duration: duration) }
    func requestKeyboardFocus() { island?.requestKeyboardFocus() }
    var isCardVisible: Bool { island?.isCardVisible(moduleId) ?? false }
    var isFullscreenAppActive: Bool { island?.isFullscreen ?? false }
    var screenHasNotch: Bool { island?.geometry.hasNotch ?? false }
    func onFullscreenChange(_ handler: @escaping (Bool) -> Void) { fullscreenHandlers.append(handler) }
    func onCardVisibilityChange(_ handler: @escaping (Bool) -> Void) { visibilityHandlers.append(handler) }

    func loadSettings<T: Codable>(_ type: T.Type, fallback: T) -> T {
        JSONStore.load(type, from: AppPaths.settingsFile(moduleId), fallback: fallback)
    }

    func saveSettings<T: Codable>(_ value: T) {
        JSONStore.save(value, to: AppPaths.settingsFile(moduleId))
    }

    var dataDirectory: URL { AppPaths.data(moduleId) }
    func log(_ message: String) { Log.write(moduleId, message) }
}
