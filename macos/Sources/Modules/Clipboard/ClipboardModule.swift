import AppKit
import Carbon.HIToolbox
import IsolaCore
import SwiftUI

/// "Appunti": la cronologia di testi, link, immagini e file copiati, con i fissati.
/// Un clic rimette l'elemento negli appunti. I segreti dei gestori di password non si salvano.
public final class ClipboardModule: IslandModule {
    public init() {}
    public var id: String { "clipboard" }
    public var title: String { "Appunti" }
    public var symbol: String { "doc.on.clipboard" }
    public var order: Int { 20 }
    public var enabledByDefault: Bool { true }

    private let history = ClipboardHistory()
    private weak var host: IslandHost?
    private var timer: Timer?
    private var hotKey: HotKey?

    public func start(host: IslandHost) throws {
        self.host = host
        history.start(host: host)
        history.onSettingsChanged = { [weak self] old, new in
            guard let self else { return }
            if old.enabled != new.enabled { self.updateTimer() }
            if old.hotKeyEnabled != new.hotKeyEnabled || old.hotKey != new.hotKey { self.updateHotKey() }
        }
        host.onCardVisibilityChange { [weak self] visible in self?.history.cardBecameVisible(visible) }
        updateTimer()
        updateHotKey()
    }

    public func stop() {
        timer?.invalidate()
        timer = nil
        hotKey?.unregister()
        hotKey = nil
        history.onSettingsChanged = nil
        history.setHotKeyRegistered(false)
        history.stop()
        host = nil
    }

    public func makeCard() -> AnyView? {
        AnyView(ClipboardCard(model: history))
    }

    public func makeSettings() -> AnyView? {
        AnyView(ClipboardSettingsView(model: history))
    }

    // MARK: -

    /// macOS non avvisa quando gli appunti cambiano: si guarda `changeCount` ogni mezzo secondo.
    /// A riposo è un solo confronto tra due interi (nessuna lettura degli appunti), quindi la CPU
    /// resta a ~0%; con la tolleranza il sistema accorpa il risveglio con gli altri timer.
    /// Con la cronologia spenta il timer non gira affatto.
    private func updateTimer() {
        let enabled = history.settings.enabled
        if enabled, timer == nil {
            history.resync()
            let t = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.history.poll() }
            }
            t.tolerance = 0.25
            RunLoop.main.add(t, forMode: .common)
            timer = t
        } else if !enabled, let t = timer {
            t.invalidate()
            timer = nil
        }
    }

    private func updateHotKey() {
        hotKey?.unregister()
        hotKey = nil
        let s = history.settings
        guard s.hotKeyEnabled else { history.setHotKeyRegistered(false); return }
        let (code, mods) = Self.keys(for: s.hotKey)
        let key = HotKey(keyCode: code, modifiers: mods) { [weak self] in
            guard let self, let host = self.host else { return }
            host.openTab(self.id)
        }
        hotKey = key
        history.setHotKeyRegistered(key.isRegistered)
        if !key.isRegistered { host?.log("Scorciatoia degli appunti già usata da un'altra app") }
    }

    private static func keys(for k: ClipHotKey) -> (UInt32, UInt32) {
        let v = UInt32(kVK_ANSI_V)
        switch k {
        case .optionCommandV: return (v, UInt32(optionKey | cmdKey))
        case .controlOptionV: return (v, UInt32(controlKey | optionKey))
        case .controlCommandV: return (v, UInt32(controlKey | cmdKey))
        case .shiftOptionCommandV: return (v, UInt32(shiftKey | optionKey | cmdKey))
        }
    }
}
