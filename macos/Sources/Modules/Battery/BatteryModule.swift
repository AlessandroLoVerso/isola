import IOKit.ps
import IsolaCore
import SwiftUI

/// "Batteria": percentuale, stato, tempo rimasto, alimentatore, cicli e capacità. Mostra la carica
/// per qualche secondo quando colleghi l'alimentatore e avvisa con la batteria scarica.
/// Tutto a eventi (IOPowerSources): nessun timer gira a riposo.
public final class BatteryModule: IslandModule, RestingFaceProvider, PeekProvider {
    public init() {}
    public var id: String { "battery" }
    public var title: String { "Batteria" }
    public var symbol: String { "battery.100percent" }
    public var order: Int { 75 }
    public var enabledByDefault: Bool { true }

    private var host: IslandHost?
    private let model = BatteryModel()
    private var runLoopSource: CFRunLoopSource?
    private var powerStateObserver: NSObjectProtocol?
    private var flashTimer: Timer?
    /// Soglie già avvisate in questa scarica. Si azzerano quando colleghi l'alimentatore.
    private var warnedLevels = Set<Int>()
    private var lastPriority = 0

    static let flashSeconds: TimeInterval = 3

    // MARK: ciclo di vita

    public func start(host: IslandHost) throws {
        self.host = host
        model.settings = host.loadSettings(BatterySettings.self, fallback: BatterySettings())
        model.state = BatteryReader.read()
        model.flash = false
        warnedLevels = []
        // Già sotto una soglia all'avvio: niente avviso a sorpresa, la faccia rossa basta.
        if !model.state.pluggedIn {
            for level in model.settings.levels where model.state.percent <= level { warnedLevels.insert(level) }
        }

        let context = Unmanaged.passUnretained(self).toOpaque()
        if let source = IOPSNotificationCreateRunLoopSource({ context in
            guard let context else { return }
            let module = Unmanaged<BatteryModule>.fromOpaque(context).takeUnretainedValue()
            MainActor.assumeIsolated { module.powerSourcesChanged() }
        }, context)?.takeRetainedValue() {
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
            runLoopSource = source
        }

        powerStateObserver = NotificationCenter.default.addObserver(
            forName: .NSProcessInfoPowerStateDidChange, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.model.state.lowPowerMode = ProcessInfo.processInfo.isLowPowerModeEnabled
            }
        }
        lastPriority = restingPriority // Il core rivaluta le facce subito dopo l'avvio.
    }

    public func stop() {
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
            CFRunLoopSourceInvalidate(source)
        }
        runLoopSource = nil
        if let o = powerStateObserver { NotificationCenter.default.removeObserver(o) }
        powerStateObserver = nil
        flashTimer?.invalidate()
        flashTimer = nil
        model.flash = false
        host = nil
        lastPriority = 0
    }

    // MARK: eventi

    private func powerSourcesChanged() {
        guard host != nil else { return }
        let old = model.state
        let new = BatteryReader.read()
        if new != old { model.state = new }
        guard new.present else { refreshPriority(); return }

        if new.pluggedIn {
            warnedLevels = []
            if !old.pluggedIn, old.present, model.settings.peekOnPlug { flashCharging() }
        } else {
            checkLowBattery(new.percent)
        }
        refreshPriority()
    }

    private func flashCharging() {
        model.peek = .charging
        model.flash = true
        flashTimer?.invalidate()
        flashTimer = Timer.scheduledTimer(withTimeInterval: Self.flashSeconds, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.flashTimer = nil
                self.model.flash = false
                self.refreshPriority()
            }
        }
        refreshPriority()
        host?.attention(duration: Self.flashSeconds)
    }

    /// Un avviso per soglia e per scarica. Se si scende di colpo sotto entrambe, ne basta uno.
    private func checkLowBattery(_ percent: Int) {
        let crossed = model.settings.levels.filter { percent <= $0 && !warnedLevels.contains($0) }
        guard let level = crossed.min() else { return }
        for l in model.settings.levels where percent <= l { warnedLevels.insert(l) }
        guard model.settings.lowWarnings else { return }
        model.peek = .low(level: level)
        host?.attention(duration: 5)
    }

    private func refreshPriority() {
        let p = restingPriority
        guard p != lastPriority else { return }
        lastPriority = p
        host?.refreshRestingFace()
    }

    // MARK: faccia e peek

    public var restingPriority: Int {
        guard host != nil, model.state.present else { return 0 }
        if model.flash { return 60 }
        if !model.state.pluggedIn, model.state.percent <= model.settings.criticalLevel { return 65 }
        return 0
    }

    public func makeRestingFace() -> RestingFace {
        RestingFace(sideWidth: 64,
                    leading: BatteryFaceSide(model: model, leading: true),
                    trailing: BatteryFaceSide(model: model, leading: false))
    }

    public func makePeek() -> AnyView {
        AnyView(BatteryPeek(model: model, kind: model.peek))
    }

    // MARK: scheda e impostazioni

    public func makeCard() -> AnyView? {
        AnyView(BatteryCard(model: model))
    }

    public func makeSettings() -> AnyView? {
        AnyView(BatterySettingsView(model: model) { [weak self] in self?.settingsChanged() })
    }

    private func settingsChanged() {
        host?.saveSettings(model.settings)
        refreshPriority()
    }
}

// MARK: - Impostazioni

struct BatterySettings: Codable, Equatable {
    /// Mostra l'animazione di carica quando colleghi l'alimentatore.
    var peekOnPlug = true
    /// Avvisi a batteria scarica.
    var lowWarnings = true
    /// Primo avviso.
    var lowLevel = 20
    /// Avviso critico: sotto questa soglia la pillola mostra la batteria in rosso.
    var criticalLevel = 10

    var levels: [Int] { Array(Set([lowLevel, criticalLevel])) }

    static let lowChoices = [30, 25, 20, 15]
    static let criticalChoices = [10, 5]

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = BatterySettings()
        peekOnPlug = try c.decodeIfPresent(Bool.self, forKey: .peekOnPlug) ?? d.peekOnPlug
        lowWarnings = try c.decodeIfPresent(Bool.self, forKey: .lowWarnings) ?? d.lowWarnings
        lowLevel = try c.decodeIfPresent(Int.self, forKey: .lowLevel) ?? d.lowLevel
        criticalLevel = try c.decodeIfPresent(Int.self, forKey: .criticalLevel) ?? d.criticalLevel
        if !Self.lowChoices.contains(lowLevel) { lowLevel = d.lowLevel }
        if !Self.criticalChoices.contains(criticalLevel) { criticalLevel = d.criticalLevel }
    }
}

// MARK: - Modello

enum BatteryPeekKind: Equatable {
    case charging
    case low(level: Int)
}

@MainActor
final class BatteryModel: ObservableObject {
    @Published var state = BatteryState()
    @Published var settings = BatterySettings()
    /// I secondi dopo che hai collegato l'alimentatore.
    @Published var flash = false
    var peek: BatteryPeekKind = .charging
}
