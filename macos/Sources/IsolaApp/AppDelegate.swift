import AppKit
import Combine
import IsolaCore
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    static weak var shared: AppDelegate?

    private(set) var manager: ModuleManager!
    private(set) var island: IslandController!
    private var statusItem: NSStatusItem?
    private var settingsWindow: NSWindow?
    private var cancellables: Set<AnyCancellable> = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppDelegate.shared = self
        NSApp.setActivationPolicy(.accessory)
        Log.write("core", "Avvio di Isola \(Self.version)")

        manager = ModuleManager(types: ModuleRegistry.all)
        island = IslandController(manager: manager)
        manager.island = island
        island.start()
        manager.startEnabled()

        SettingsStore.shared.$current
            .map(\.showStatusItem)
            .removeDuplicates()
            .sink { [weak self] show in
                DispatchQueue.main.async { self?.setStatusItem(visible: show) }
            }
            .store(in: &cancellables)

        if !UserDefaults.standard.bool(forKey: "isola.welcomed") {
            UserDefaults.standard.set(true, forKey: "isola.welcomed")
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
                self?.island.openTab(self?.manager.tabs.first?.moduleId ?? "")
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        manager?.stopAll()
    }

    /// Riaprire l'app dal Finder (o dal Launchpad) mostra le impostazioni.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showSettings()
        return false
    }

    /// Link isola:// (Comandi rapidi, Raycast, Terminale):
    /// isola://open/<modulo>, isola://toggle, isola://close, isola://settings
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls where url.scheme == "isola" {
            let parts = ([url.host ?? ""] + url.pathComponents.filter { $0 != "/" }).filter { !$0.isEmpty }
            switch parts.first {
            case "open": island.openTab(parts.count > 1 ? parts[1] : (island.selectedTab ?? ""))
            case "toggle": island.toggle()
            case "close": island.close()
            case "settings": showSettings()
            case "debug" where parts.count > 1 && parts[1] == "snapshot":
                // isola://debug/snapshot/<nome>: PNG in ~/Library/Caches/isola-build/snapshots
                let dir = FileManager.default.homeDirectoryForCurrentUser
                    .appendingPathComponent("Library/Caches/isola-build/snapshots")
                try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                let name = parts.count > 2 ? parts[2] : "isola"
                try? island.snapshotPNG()?.write(to: dir.appendingPathComponent("\(name).png"))
            default: break
            }
        }
    }

    static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    }

    // MARK: icona nella barra dei menu

    private func setStatusItem(visible: Bool) {
        if !visible {
            if let s = statusItem { NSStatusBar.system.removeStatusItem(s) }
            statusItem = nil
            return
        }
        guard statusItem == nil else { return }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "capsule.fill", accessibilityDescription: "Isola")
        item.button?.image?.isTemplate = true
        let menu = NSMenu()
        menu.addItem(withTitle: "Apri l'isola", action: #selector(openIsland), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Impostazioni…", action: #selector(openSettings), keyEquivalent: ",").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Esci da Isola", action: #selector(quit), keyEquivalent: "q").target = self
        item.menu = menu
        statusItem = item
    }

    @objc private func openIsland() { island.toggle() }
    @objc private func openSettings() { showSettings() }
    @objc private func quit() { NSApp.terminate(nil) }

    // MARK: impostazioni

    func showSettings() {
        if settingsWindow == nil {
            let view = SettingsView(manager: manager, island: island)
            let w = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 760, height: 540),
                             styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                             backing: .buffered, defer: false)
            w.title = "Isola"
            w.titlebarAppearsTransparent = true
            w.contentViewController = NSHostingController(rootView: view)
            w.setContentSize(CGSize(width: 760, height: 540))
            w.minSize = CGSize(width: 640, height: 420)
            w.isReleasedWhenClosed = false
            w.center()
            settingsWindow = w
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }
}
