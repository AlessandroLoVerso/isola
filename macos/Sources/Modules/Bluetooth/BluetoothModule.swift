import AppKit
import CoreBluetooth
import IOBluetooth
import IsolaCore
import SwiftUI

/// Impostazioni del modulo Bluetooth (`bluetooth.json`).
struct BluetoothSettings: Codable, Equatable {
    /// Peek sotto la notch quando si collegano cuffie o casse.
    var peekOnConnect = true
    var showBattery = true
    /// Cuffie e batteria accanto alla notch (priorità bassa).
    var showFace = false

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = BluetoothSettings()
        peekOnConnect = try c.decodeIfPresent(Bool.self, forKey: .peekOnConnect) ?? d.peekOnConnect
        showBattery = try c.decodeIfPresent(Bool.self, forKey: .showBattery) ?? d.showBattery
        showFace = try c.decodeIfPresent(Bool.self, forKey: .showFace) ?? d.showFace
    }
}

enum BluetoothPermission { case allowed, denied, notAsked }

@MainActor
final class BluetoothModel: ObservableObject {
    @Published var devices: [BTDevice] = []
    @Published var peekID: String?
    @Published var settings = BluetoothSettings()
    @Published var permission = BluetoothPermission.notAsked
    var disconnect: (String) -> Void = { _ in }

    var peekDevice: BTDevice? {
        devices.first { $0.id == peekID } ?? devices.first { $0.isAudio }
    }

    var faceDevice: BTDevice? { devices.first { $0.isAudio } }
}

/// Cuffie, AirPods e casse Bluetooth: un avviso quando si collegano, con la batteria se macOS
/// la rende disponibile, e l'elenco dei dispositivi collegati nella scheda.
@MainActor
public final class BluetoothModule: IslandModule, PeekProvider, RestingFaceProvider {
    public init() {}
    public var id: String { "bluetooth" }
    public var title: String { "Bluetooth" }
    public var symbol: String { "airpodspro" }
    public var order: Int { 80 }
    public var enabledByDefault: Bool { true }

    let model = BluetoothModel()
    private var host: IslandHost?
    private var watcher: BluetoothWatcher?
    private let profiler = ProfilerBattery()
    private var generation = 0
    /// Ultimo avviso per dispositivo: le AirPods a volte si ricollegano subito.
    private var lastPeek: [String: Date] = [:]
    /// Dispositivi per cui `system_profiler` è già stato chiesto in questa connessione.
    private var profiled = Set<String>()

    private var settings: BluetoothSettings {
        get { model.settings }
        set { model.settings = newValue }
    }

    // MARK: - Ciclo di vita

    public func start(host: IslandHost) throws {
        self.host = host
        generation += 1
        settings = host.loadSettings(BluetoothSettings.self, fallback: BluetoothSettings())
        model.disconnect = { [weak self] key in self?.disconnect(key) }

        // Il permesso Bluetooth non si chiede all'avvio: se non è mai stato chiesto,
        // si comincia ad ascoltare solo quando l'utente apre la scheda.
        if CBManager.authorization != .notDetermined { startWatcher() }
        updatePermission()

        host.onCardVisibilityChange { [weak self] visible in
            MainActor.assumeIsolated {
                guard visible, let self else { return }
                if self.watcher == nil { self.startWatcher() }
                self.updatePermission()
                self.watcher?.resync()
                self.refreshBatteries()
            }
        }
        host.log("bluetooth avviato: \(model.devices.count) dispositivi collegati")
        host.refreshRestingFace()
    }

    /// Qui macOS può chiedere il permesso Bluetooth (NSBluetoothAlwaysUsageDescription).
    private func startWatcher() {
        let w = BluetoothWatcher()
        w.onConnect = { [weak self] device, isNew in self?.connected(device, isNew: isNew) }
        w.onDisconnect = { [weak self] key in self?.disconnected(key) }
        watcher = w
        w.start()
    }

    public func stop() {
        generation += 1
        watcher?.onConnect = nil
        watcher?.onDisconnect = nil
        watcher?.stop()
        watcher = nil
        profiler.cancel()
        model.devices = []
        model.peekID = nil
        lastPeek = [:]
        profiled = []
        host = nil
    }

    // MARK: - Connessioni

    private func connected(_ device: IOBluetoothDevice, isNew: Bool) {
        guard let host else { return }
        let snap = BTInfo.snapshot(device, readBattery: settings.showBattery)
        if let i = model.devices.firstIndex(where: { $0.id == snap.id }) {
            var merged = snap
            merged.battery = snap.battery.filling(with: model.devices[i].battery)
            model.devices[i] = merged
        } else {
            model.devices.append(snap)
            sortDevices()
        }
        guard isNew else {
            host.refreshRestingFace()
            return
        }
        profiled.remove(snap.id)
        host.log("dispositivo Bluetooth collegato (\(snap.isAudio ? "audio" : "altro"))")
        host.refreshRestingFace()

        if snap.isAudio, settings.peekOnConnect {
            let now = Date()
            if let last = lastPeek[snap.id], now.timeIntervalSince(last) < 30 {
                // Ricollegato subito: niente secondo avviso.
            } else {
                lastPeek[snap.id] = now
                model.peekID = snap.id
                host.attention(duration: 4)
            }
        }
        // La batteria arriva qualche secondo dopo la connessione: poche letture a tempo, poi basta.
        guard settings.showBattery else { return }
        let gen = generation
        let key = snap.id
        for delay in [1.5, 4.0, 10.0] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, gen == self.generation else { return }
                    self.refreshBattery(key, allowProfiler: delay >= 4)
                }
            }
        }
    }

    private func disconnected(_ key: String) {
        guard let host else { return }
        model.devices.removeAll { $0.id == key }
        profiled.remove(key)
        if model.peekID == key { model.peekID = nil }
        host.log("dispositivo Bluetooth scollegato")
        host.refreshRestingFace()
    }

    private func disconnect(_ key: String) {
        watcher?.disconnect(key)
    }

    private func sortDevices() {
        model.devices.sort { a, b in
            if a.isAudio != b.isAudio { return a.isAudio }
            return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
        }
    }

    // MARK: - Batteria

    private func refreshBatteries() {
        guard settings.showBattery else { return }
        for d in model.devices { refreshBattery(d.id, allowProfiler: false) }
    }

    private func refreshBattery(_ key: String, allowProfiler: Bool) {
        guard settings.showBattery, let device = watcher?.devices[key],
              let i = model.devices.firstIndex(where: { $0.id == key }) else { return }
        let fresh = BTInfo.battery(device)
        let merged = fresh.filling(with: model.devices[i].battery)
        if merged != model.devices[i].battery {
            model.devices[i].battery = merged
            host?.refreshRestingFace()
        }
        // Ultima spiaggia, una volta per connessione e solo per l'audio: system_profiler.
        guard allowProfiler, merged.isEmpty, model.devices[i].isAudio, !profiled.contains(key) else { return }
        profiled.insert(key)
        let gen = generation
        profiler.fetch { [weak self] result in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, gen == self.generation else { return }
                    self.applyProfiler(result)
                }
            }
        }
    }

    private func applyProfiler(_ result: [String: BTBattery]) {
        var changed = false
        for (key, battery) in result {
            guard let i = model.devices.firstIndex(where: { $0.id == key }) else { continue }
            let merged = model.devices[i].battery.filling(with: battery)
            if merged != model.devices[i].battery {
                model.devices[i].battery = merged
                changed = true
            }
        }
        if changed { host?.refreshRestingFace() }
    }

    private func updatePermission() {
        switch CBManager.authorization {
        case .allowedAlways: model.permission = .allowed
        case .denied, .restricted: model.permission = .denied
        default: model.permission = .notAsked
        }
    }

    // MARK: - Viste

    public func makeCard() -> AnyView? {
        AnyView(BluetoothCard(model: model))
    }

    public func makePeek() -> AnyView {
        AnyView(BluetoothPeek(model: model))
    }

    public var restingPriority: Int {
        guard host != nil, settings.showFace, model.faceDevice != nil else { return 0 }
        return 20
    }

    public func makeRestingFace() -> RestingFace {
        RestingFace(leading: BluetoothFaceLeading(model: model), trailing: BluetoothFaceTrailing(model: model))
    }

    public func makeSettings() -> AnyView? {
        AnyView(BluetoothSettingsView(model: model, module: self))
    }

    func updateSettings(_ change: (inout BluetoothSettings) -> Void) {
        var s = settings
        change(&s)
        guard s != settings else { return }
        let batteryTurnedOn = s.showBattery && !settings.showBattery
        settings = s
        host?.saveSettings(s)
        if !s.showBattery {
            for i in model.devices.indices { model.devices[i].battery = BTBattery() }
        } else if batteryTurnedOn {
            refreshBatteries()
        }
        host?.refreshRestingFace()
    }

    static func openPrivacySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Bluetooth") {
            NSWorkspace.shared.open(url)
        }
    }
}
