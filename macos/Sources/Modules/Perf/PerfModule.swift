import IsolaCore
import SwiftUI

/// "Prestazioni": CPU, GPU, memoria e rete. Una striscia sottile accanto alla notch sopra le app a
/// schermo intero e una scheda con l'ultimo minuto. Legge i contatori una volta al secondo solo
/// mentre la scheda o la striscia sono sullo schermo; altrimenti non esiste nessun timer.
public final class PerfModule: IslandModule, StripProvider {
    public init() {}
    public var id: String { "perf" }
    public var title: String { "Prestazioni" }
    public var symbol: String { "gauge.with.dots.needle.67percent" }
    public var order: Int { 70 }
    public var enabledByDefault: Bool { true }

    private var host: IslandHost?
    private let model = PerfModel()
    private var sampler: PerfSampler?
    private var timer: Timer?
    private var cardVisible = false
    private var visibleStrips = 0
    private var lastWantsStrip = false

    // MARK: ciclo di vita

    public func start(host: IslandHost) throws {
        self.host = host
        model.settings = host.loadSettings(PerfSettings.self, fallback: PerfSettings())
        let sampler = PerfSampler()
        self.sampler = sampler
        model.efficiencyCores = sampler.efficiencyCores
        model.logicalCores = sampler.logicalCores
        cardVisible = host.isCardVisible
        visibleStrips = 0
        lastWantsStrip = wantsStrip

        host.onFullscreenChange { [weak self] _ in
            self?.refreshWantsStrip()
            self?.updateDemand()
        }
        host.onCardVisibilityChange { [weak self] visible in
            self?.cardVisible = visible
            self?.updateDemand()
        }
        updateDemand()
    }

    public func stop() {
        stopSampling()
        sampler?.close()
        sampler = nil
        host = nil
        cardVisible = false
        visibleStrips = 0
        lastWantsStrip = false
    }

    // MARK: domanda

    /// Si legge solo con la scheda aperta, o con la striscia visibile sopra un'app a schermo intero.
    private func updateDemand() {
        guard let host else { return }
        let stripOn = host.isFullscreenAppActive && visibleStrips > 0 && wantsStrip
        let want = cardVisible || stripOn
        if want, timer == nil { startSampling() } else if !want, timer != nil { stopSampling() }
    }

    private func startSampling() {
        guard let sampler else { return }
        sampler.reset()
        _ = sampler.sample() // Prima lettura: fa da base per le differenze.
        // La seconda arriva presto, così la scheda non resta vuota per un secondo intero.
        let t = Timer(fire: Date().addingTimeInterval(0.35), interval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        t.tolerance = 0.1
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func stopSampling() {
        timer?.invalidate()
        timer = nil
    }

    private func tick() {
        guard let sampler else { return }
        model.apply(sampler.sample())
    }

    fileprivate func stripVisibility(_ visible: Bool) {
        visibleStrips = max(0, visibleStrips + (visible ? 1 : -1))
        updateDemand()
    }

    // MARK: striscia

    public var wantsStrip: Bool {
        guard let host else { return false }
        return model.settings.strip && model.settings.anyStripMetric && host.isFullscreenAppActive
    }

    private func refreshWantsStrip() {
        let w = wantsStrip
        guard w != lastWantsStrip else { return }
        lastWantsStrip = w
        host?.refreshRestingFace()
    }

    public func makeStrip() -> RestingFace {
        let report: (Bool) -> Void = { [weak self] visible in self?.stripVisibility(visible) }
        return RestingFace(
            sideWidth: PerfStripMetrics.sideWidth,
            leading: PerfStripSide(model: model, leading: true, report: report),
            trailing: PerfStripSide(model: model, leading: false, report: nil))
    }

    // MARK: scheda e impostazioni

    public func makeCard() -> AnyView? {
        AnyView(PerfCard(model: model))
    }

    public func makeSettings() -> AnyView? {
        AnyView(PerfSettingsView(model: model) { [weak self] in self?.settingsChanged() })
    }

    private func settingsChanged() {
        host?.saveSettings(model.settings)
        refreshWantsStrip()
        updateDemand()
    }
}

// MARK: - Impostazioni

struct PerfSettings: Codable, Equatable {
    /// Mostra la striscia sopra le app a schermo intero.
    var strip = true
    var stripCPU = true
    var stripGPU = true
    var stripRAM = true
    var stripNet = true
    /// Barre sottili sotto i numeri della striscia.
    var bars = true

    var anyStripMetric: Bool { stripCPU || stripGPU || stripRAM || stripNet }

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = PerfSettings.defaults
        strip = try c.decodeIfPresent(Bool.self, forKey: .strip) ?? d.strip
        stripCPU = try c.decodeIfPresent(Bool.self, forKey: .stripCPU) ?? d.stripCPU
        stripGPU = try c.decodeIfPresent(Bool.self, forKey: .stripGPU) ?? d.stripGPU
        stripRAM = try c.decodeIfPresent(Bool.self, forKey: .stripRAM) ?? d.stripRAM
        stripNet = try c.decodeIfPresent(Bool.self, forKey: .stripNet) ?? d.stripNet
        bars = try c.decodeIfPresent(Bool.self, forKey: .bars) ?? d.bars
    }

    private static let defaults = PerfSettings()
}

// MARK: - Modello

/// Valori pronti per le viste. Aggiornato al massimo una volta al secondo, solo mentre si legge.
@MainActor
final class PerfModel: ObservableObject {
    static let historyLength = 60

    @Published var settings = PerfSettings()
    @Published private(set) var snapshot = PerfSnapshot()
    @Published private(set) var cpuHistory: [Double] = []
    @Published private(set) var gpuHistory: [Double] = []
    @Published private(set) var ramHistory: [Double] = []
    @Published private(set) var downHistory: [Double] = []
    @Published private(set) var upHistory: [Double] = []
    var efficiencyCores = 0
    var logicalCores = 0

    private var lastPointAt: TimeInterval = -.infinity

    func apply(_ s: PerfSnapshot) {
        let now = ProcessInfo.processInfo.systemUptime
        // Dopo una lunga pausa (niente sullo schermo) i punti vecchi disegnerebbero una linea falsa.
        if now - lastPointAt > 30 {
            cpuHistory = []; gpuHistory = []; ramHistory = []; downHistory = []; upHistory = []
        }
        lastPointAt = now
        snapshot = s
        Self.push(s.cpu, to: &cpuHistory)
        Self.push(s.gpu, to: &gpuHistory)
        Self.push(s.ramPercent, to: &ramHistory)
        Self.push(s.down, to: &downHistory)
        Self.push(s.up, to: &upHistory)
    }

    private static func push(_ value: Double?, to history: inout [Double]) {
        guard let value else { return }
        history.append(value)
        if history.count > historyLength { history.removeFirst(history.count - historyLength) }
    }
}
