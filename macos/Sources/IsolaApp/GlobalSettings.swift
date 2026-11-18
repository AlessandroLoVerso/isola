import Foundation
import IsolaCore
import SwiftUI

enum IslandShapeKind: String, Codable, CaseIterable {
    /// Attaccata al bordo in alto, con le curve verso l'esterno come la notch vera.
    case notch
    /// Pillola staccata dal bordo (solo sugli schermi senza notch).
    case isola
}

enum FullscreenBehavior: String, Codable, CaseIterable {
    case striscia, nascondi, normale
}

enum ThemeKind: String, Codable, CaseIterable {
    case nero, grafite, vetro, liquido

    var label: String {
        switch self {
        case .nero: "Nero"
        case .grafite: "Grafite"
        case .vetro: "Vetro"
        case .liquido: "Liquido"
        }
    }

    var colors: IslandTheme {
        switch self {
        case .nero: .nero
        case .grafite: .grafite
        case .vetro, .liquido: .vetro
        }
    }
}

/// Impostazioni generali, in ~/Library/Application Support/Isola/settings.json.
struct GlobalSettings: Codable, Equatable {
    var shape: IslandShapeKind = .notch
    var theme: ThemeKind = .nero
    /// "auto" = lo schermo con la notch se c'è, altrimenti il principale; "main" = il principale;
    /// altrimenti il nome dello schermo.
    var screen: String = "auto"
    var fullscreen: FullscreenBehavior = .striscia
    /// Ritardo prima di aprirsi al passaggio del puntatore, in millisecondi.
    var openDelayMs: Double = 250
    /// Vibrazione del trackpad quando la scheda si apre.
    var haptics: Bool = true
    var showStatusItem: Bool = true
    /// Ultima scheda aperta.
    var lastTab: String?
    /// Modulo → acceso. Mancante = `enabledByDefault` del modulo.
    var modules: [String: Bool] = [:]

    init() {}

    // Decodifica tollerante: un campo mancante o nuovo non butta via il resto.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = GlobalSettings()
        shape = (try? c.decode(IslandShapeKind.self, forKey: .shape)) ?? d.shape
        theme = (try? c.decode(ThemeKind.self, forKey: .theme)) ?? d.theme
        screen = (try? c.decode(String.self, forKey: .screen)) ?? d.screen
        fullscreen = (try? c.decode(FullscreenBehavior.self, forKey: .fullscreen)) ?? d.fullscreen
        openDelayMs = min(1000, max(0, (try? c.decode(Double.self, forKey: .openDelayMs)) ?? d.openDelayMs))
        haptics = (try? c.decode(Bool.self, forKey: .haptics)) ?? d.haptics
        showStatusItem = (try? c.decode(Bool.self, forKey: .showStatusItem)) ?? d.showStatusItem
        lastTab = try? c.decode(String.self, forKey: .lastTab)
        modules = (try? c.decode([String: Bool].self, forKey: .modules)) ?? [:]
    }
}

@MainActor
final class SettingsStore: ObservableObject {
    static let shared = SettingsStore()

    @Published private(set) var current: GlobalSettings

    private init() {
        current = JSONStore.load(GlobalSettings.self, from: AppPaths.globalSettingsFile, fallback: GlobalSettings())
    }

    func update(_ change: (inout GlobalSettings) -> Void) {
        var s = current
        change(&s)
        guard s != current else { return }
        current = s
        JSONStore.save(s, to: AppPaths.globalSettingsFile)
    }

    /// Binding per i controlli della finestra impostazioni.
    func binding<V>(_ keyPath: WritableKeyPath<GlobalSettings, V>) -> Binding<V> {
        Binding(get: { self.current[keyPath: keyPath] },
                set: { v in self.update { $0[keyPath: keyPath] = v } })
    }
}
