import AppKit
import Carbon.HIToolbox
import CoreAudio
import CoreWLAN
import IsolaCore
import SwiftUI

/// "Controlli": muto globale del microfono (⌃⌥M, oppure ⌃⇧⌥M se occupata), timer delle
/// chiamate e scheda con volume, dispositivi audio, luminosità, Wi-Fi e Bluetooth.
/// Tutto a eventi (listener CoreAudio, CoreWLAN): l'unico timer gira durante una chiamata
/// (1 s) o a scheda aperta (luminosità e Bluetooth, che non mandano notifiche).
@MainActor
public final class ControlsModule: IslandModule, RestingFaceProvider, PeekProvider {
    public init() {}
    public var id: String { "controls" }
    public var title: String { "Controlli" }
    public var symbol: String { "slider.horizontal.3" }
    public var order: Int { 40 }
    public var enabledByDefault: Bool { true }

    let model = ControlsModel()
    private var host: IslandHost?
    private var generation = 0

    // Scorciatoia
    private enum HotkeyStatus { case off, active, taken }
    private var hotKey: HotKey?
    private var hotkeyStatus = HotkeyStatus.off
    private var activeVariant = 0

    // CoreAudio
    private var systemListeners: [HALListener] = []
    private var inputListeners: [HALListener] = []
    private var outputListeners: [HALListener] = []
    private var inputDevice: AudioObjectID?
    private var outputDevice: AudioObjectID?
    /// Microfoni a cui abbiamo messo il muto vero (`kAudioDevicePropertyMute`).
    private var mutedDevices = Set<AudioObjectID>()

    // Chiamata
    private var micRunning = false
    private var runningSince: Date?
    private var callStart: Date?
    private var callTimer: Timer?
    private var callConfirm: DispatchWorkItem?

    // Sistema
    private var brightness: BrightnessControl?
    private var bluetoothPower: BluetoothPower?
    private var wifi: WiFiWatcher?
    private let location = LocationAccess()
    private var cardTimer: Timer?

    private var settings: ControlsSettings {
        get { model.settings }
        set { model.settings = newValue }
    }

    // MARK: - Ciclo di vita

    public func start(host: IslandHost) throws {
        self.host = host
        generation += 1
        settings = host.loadSettings(ControlsSettings.self, fallback: ControlsSettings())
        model.showBrightness = settings.showBrightness
        model.showRadios = settings.showRadios
        wireActions()

        // CoreAudio: dispositivi predefiniti ed elenco.
        systemListeners = [
            HALListener(object: HAL.system, address: HAL.address(kAudioHardwarePropertyDefaultInputDevice)) { [weak self] in
                MainActor.assumeIsolated { self?.defaultInputChanged() }
            },
            HALListener(object: HAL.system, address: HAL.address(kAudioHardwarePropertyDefaultOutputDevice)) { [weak self] in
                MainActor.assumeIsolated { self?.bindOutput() }
            },
            HALListener(object: HAL.system, address: HAL.address(kAudioHardwarePropertyDevices)) { [weak self] in
                MainActor.assumeIsolated { self?.refreshDeviceLists() }
            },
        ]
        refreshDeviceLists()
        bindOutput()
        bindInput()
        // Lo stato muto sopravvive al riavvio di Isola: lo rileggiamo dal dispositivo.
        model.muted = readCurrentMute()

        registerHotkey()

        // Luminosità, Bluetooth, Wi-Fi.
        let b = BrightnessControl()
        brightness = b
        if let level = b.read() {
            model.brightnessAvailable = true
            model.brightness = level
        } else {
            model.brightnessAvailable = false
        }
        let bt = BluetoothPower()
        bluetoothPower = bt
        model.bluetoothToggleAvailable = bt.isAvailable
        model.bluetoothOn = nil // letto quando si apre la scheda (può chiedere il permesso)

        let w = WiFiWatcher { [weak self] in self?.readWiFi() }
        wifi = w
        w.start()
        location.onChange = { [weak self] in
            self?.readWiFi()
            self?.updateLocationState()
        }
        location.start()
        readWiFi()
        updateLocationState()

        host.onCardVisibilityChange { [weak self] visible in
            MainActor.assumeIsolated { self?.cardVisibilityChanged(visible) }
        }

        host.log("controlli avviati: muto \(model.muted ? "sì" : "no"), luminosità \(model.brightnessAvailable ? "sì" : "no"), Bluetooth \(bt.isAvailable ? "sì" : "no")")
        host.refreshRestingFace()
    }

    public func stop() {
        generation += 1
        unregisterHotkey()
        (systemListeners + inputListeners + outputListeners).forEach { $0.remove() }
        systemListeners = []
        inputListeners = []
        outputListeners = []
        inputDevice = nil
        outputDevice = nil
        mutedDevices = []
        stopCall()
        micRunning = false
        callConfirm?.cancel()
        callConfirm = nil
        cardTimer?.invalidate()
        cardTimer = nil
        wifi?.stop()
        wifi = nil
        location.onChange = nil
        location.stop()
        brightness = nil
        bluetoothPower = nil
        host = nil
    }

    // MARK: - Scheda, faccia, peek

    public func makeCard() -> AnyView? {
        AnyView(ControlsCard(model: model))
    }

    public var restingPriority: Int {
        guard host != nil else { return 0 }
        if model.muted && settings.showMutedFace { return 80 }
        if model.inCall && settings.showCallFace { return 80 }
        return 0
    }

    public func makeRestingFace() -> RestingFace {
        let wide = model.muted && model.inCall
        return RestingFace(sideWidth: wide ? 92 : 72,
                           leading: ControlsFaceLeading(model: model),
                           trailing: ControlsFaceTrailing(model: model))
    }

    public func makePeek() -> AnyView {
        AnyView(ControlsPeek(model: model))
    }

    public func makeSettings() -> AnyView? {
        AnyView(ControlsSettingsView(model: model, module: self))
    }

    private func wireActions() {
        model.toggleMute = { [weak self] in self?.toggleMute(source: "scheda") }
        model.setVolume = { [weak self] v in self?.setVolume(v) }
        model.toggleOutputMute = { [weak self] in self?.toggleOutputMute() }
        model.selectOutput = { id in HAL.setDefaultDevice(id, input: false) }
        model.selectInput = { id in HAL.setDefaultDevice(id, input: true) }
        model.setBrightness = { [weak self] v in self?.brightness?.set(v) }
        model.toggleWiFi = { [weak self] in self?.toggleWiFi() }
        model.toggleBluetooth = { [weak self] in self?.toggleBluetooth() }
    }

    private func cardVisibilityChanged(_ visible: Bool) {
        cardTimer?.invalidate()
        cardTimer = nil
        guard visible, host != nil else { return }
        refreshDeviceLists()
        readOutput()
        readBrightness()
        readBluetoothPower()
        readWiFi()
        // Luminosità e Bluetooth non mandano notifiche: li rileggiamo solo a scheda aperta.
        cardTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.readBrightness()
                self?.readBluetoothPower()
            }
        }
    }

    private func refreshFace() {
        host?.refreshRestingFace()
    }

    // MARK: - Muto del microfono

    func toggleMute(source: String) {
        setMuted(!model.muted, source: source, external: false)
    }

    private func setMuted(_ muted: Bool, source: String, external: Bool) {
        guard let host else { return }
        model.muted = muted
        model.muteUnsupported = false
        var applied = 0
        if muted {
            if let id = inputDevice {
                if applyMute(to: id) {
                    applied += 1
                } else {
                    // Né muto né volume impostabili: meglio dirlo che fingere.
                    model.muted = false
                    model.muteUnsupported = true
                }
            }
        } else {
            applied = unmuteAll()
        }
        host.log(model.muteUnsupported
                 ? "muto non applicabile: il microfono non ha muto né volume (\(source))"
                 : "microfono \(muted ? "muto" : "attivo") (\(source)): \(applied) dispositivi")
        refreshFace()
        if settings.peekOnMute && (!external || !host.isCardVisible) {
            host.attention(duration: 2)
        }
    }

    /// Muto vero se c'è, altrimenti volume d'ingresso a 0 (salvando quello di prima).
    @discardableResult
    private func applyMute(to id: AudioObjectID) -> Bool {
        if HAL.canMute(id, input: true) {
            let ok = HAL.setMuted(id, input: true, true)
            if ok { mutedDevices.insert(id) }
            return ok
        }
        let elements = HAL.settableVolumeElements(id, input: true)
        guard !elements.isEmpty, let uid = HAL.uid(id) else { return false }
        let current = elements.map { HAL.volumeScalar(id, input: true, element: $0) ?? 1 }
        if settings.savedInputVolumes[uid] == nil, current.contains(where: { $0 > 0 }) {
            settings.savedInputVolumes[uid] = current
            host?.saveSettings(settings)
        }
        var ok = true
        for el in elements { ok = HAL.setVolumeScalar(id, input: true, element: el, 0) && ok }
        return ok
    }

    /// Toglie il muto a tutti i microfoni che abbiamo toccato (e a quello predefinito).
    private func unmuteAll() -> Int {
        var count = 0
        var ids = mutedDevices
        if let id = inputDevice, HAL.isMuted(id, input: true) == true { ids.insert(id) }
        let existing = Set(HAL.allDevices())
        for id in ids where existing.contains(id) {
            if HAL.setMuted(id, input: true, false) { count += 1 }
        }
        mutedDevices = []
        if !settings.savedInputVolumes.isEmpty {
            for id in existing {
                guard let uid = HAL.uid(id), let saved = settings.savedInputVolumes[uid] else { continue }
                let elements = HAL.settableVolumeElements(id, input: true)
                for (i, el) in elements.enumerated() {
                    HAL.setVolumeScalar(id, input: true, element: el, i < saved.count ? saved[i] : (saved.first ?? 1))
                }
                count += 1
                settings.savedInputVolumes[uid] = nil
            }
            host?.saveSettings(settings)
        }
        return count
    }

    /// Il microfono predefinito è muto adesso (muto vero o volume salvato a 0)?
    private func readCurrentMute() -> Bool {
        guard let id = inputDevice else { return false }
        if let m = HAL.isMuted(id, input: true), HAL.canMute(id, input: true) { return m }
        if let uid = HAL.uid(id), settings.savedInputVolumes[uid] != nil {
            return (HAL.mainVolume(id, input: true) ?? 1) < 0.001
        }
        return false
    }

    private func bindInput() {
        inputListeners.forEach { $0.remove() }
        inputListeners = []
        inputDevice = HAL.defaultDevice(input: true)
        model.inputID = inputDevice ?? 0
        model.hasInput = inputDevice != nil
        guard let id = inputDevice else {
            updateMicRunning(false)
            return
        }
        inputListeners = [
            HALListener(object: id, address: HAL.muteAddress(input: true)) { [weak self] in
                MainActor.assumeIsolated { self?.inputMuteChanged() }
            },
            HALListener(object: id, address: HAL.address(kAudioDevicePropertyDeviceIsRunningSomewhere)) { [weak self] in
                MainActor.assumeIsolated { self?.readMicRunning() }
            },
        ]
        readMicRunning()
    }

    private func defaultInputChanged() {
        guard host != nil else { return }
        bindInput()
        guard let id = inputDevice else { return }
        if model.muted {
            // Un microfono nuovo o appena scelto prende lo stato muto.
            applyMute(to: id)
        } else if HAL.canMute(id, input: true), HAL.isMuted(id, input: true) == true {
            model.muted = true
            mutedDevices.insert(id)
            refreshFace()
        }
    }

    private func inputMuteChanged() {
        guard host != nil, let id = inputDevice, let m = HAL.isMuted(id, input: true), m != model.muted else { return }
        // Cambiato fuori da Isola (Impostazioni, un'altra app): seguiamo.
        setMuted(m, source: "esterno", external: true)
    }

    // MARK: - Chiamata

    private func readMicRunning() {
        updateMicRunning(inputDevice.map(HAL.isRunningSomewhere) ?? false)
    }

    private func updateMicRunning(_ running: Bool) {
        guard host != nil else { return }
        if running {
            guard !micRunning else { return }
            micRunning = true
            if runningSince == nil { runningSince = Date() }
            guard !model.inCall else { return }
            // Dettatura e Siri accendono il microfono per un attimo: aspettiamo 3 s.
            callConfirm?.cancel()
            let gen = generation
            let work = DispatchWorkItem { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, gen == self.generation, self.micRunning else { return }
                    self.startCall()
                }
            }
            callConfirm = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: work)
        } else {
            guard micRunning || model.inCall else { return }
            micRunning = false
            runningSince = nil
            callConfirm?.cancel()
            callConfirm = nil
            if model.inCall {
                stopCall()
                host?.log("microfono non più in uso: timer della chiamata fermo")
                refreshFace()
            }
        }
    }

    private func startCall() {
        callStart = runningSince ?? Date()
        model.inCall = true
        updateCallTime()
        callTimer?.invalidate()
        callTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateCallTime() }
        }
        host?.log("microfono in uso da un'app: timer della chiamata avviato")
        refreshFace()
    }

    private func stopCall() {
        callTimer?.invalidate()
        callTimer = nil
        callStart = nil
        model.inCall = false
        model.callTime = "00:00"
    }

    private func updateCallTime() {
        guard let start = callStart else { return }
        let t = max(0, Int(Date().timeIntervalSince(start)))
        let h = t / 3600, m = (t % 3600) / 60, s = t % 60
        model.callTime = h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%02d:%02d", m, s)
    }

    // MARK: - Uscita

    private func bindOutput() {
        guard host != nil else { return }
        outputListeners.forEach { $0.remove() }
        outputListeners = []
        outputDevice = HAL.defaultDevice(input: false)
        model.outputID = outputDevice ?? 0
        if let id = outputDevice {
            var addresses = [HAL.mainVolumeAddress(input: false), HAL.muteAddress(input: false)]
            for el: AudioObjectPropertyElement in 0...2 {
                addresses.append(HAL.address(kAudioDevicePropertyVolumeScalar, kAudioDevicePropertyScopeOutput, el))
            }
            outputListeners = addresses.map { a in
                HALListener(object: id, address: a) { [weak self] in
                    MainActor.assumeIsolated { self?.readOutput() }
                }
            }.filter(\.isActive)
        }
        readOutput()
    }

    private func readOutput() {
        guard let id = outputDevice, let v = HAL.mainVolume(id, input: false) else {
            model.hasOutput = false
            return
        }
        model.hasOutput = true
        if !model.editingVolume { model.volume = Double(v) }
        model.outputMuted = HAL.isMuted(id, input: false) ?? false
    }

    private func setVolume(_ value: Double) {
        guard let id = outputDevice else { return }
        HAL.setMainVolume(id, input: false, Float(value))
        if value > 0.005, HAL.isMuted(id, input: false) == true { HAL.setMuted(id, input: false, false) }
    }

    private func toggleOutputMute() {
        guard let id = outputDevice, HAL.canMute(id, input: false) else { return }
        HAL.setMuted(id, input: false, !(HAL.isMuted(id, input: false) ?? false))
        readOutput()
    }

    private func refreshDeviceLists() {
        guard host != nil else { return }
        let all = HAL.allDevices().filter { !HAL.isHidden($0) }
        model.outputs = all.filter { HAL.channelCount($0, input: false) > 0 }.map { AudioDeviceItem(id: $0, name: HAL.name($0)) }
        model.inputs = all.filter { HAL.channelCount($0, input: true) > 0 }.map { AudioDeviceItem(id: $0, name: HAL.name($0)) }
    }

    // MARK: - Luminosità, Wi-Fi, Bluetooth

    private func readBrightness() {
        guard let brightness, !model.editingBrightness else { return }
        if let level = brightness.read() {
            model.brightnessAvailable = true
            if abs(model.brightness - level) > 0.004 { model.brightness = level }
        } else {
            model.brightnessAvailable = false
        }
    }

    private func readBluetoothPower() {
        guard let bluetoothPower, bluetoothPower.isAvailable else { return }
        let on = bluetoothPower.read()
        if model.bluetoothOn != on { model.bluetoothOn = on }
    }

    private func toggleBluetooth() {
        guard let bluetoothPower, bluetoothPower.isAvailable else {
            BluetoothPower.openSystemSettings()
            return
        }
        let target = !(bluetoothPower.read() ?? false)
        bluetoothPower.set(target)
        model.bluetoothOn = target
        host?.log("Bluetooth \(target ? "acceso" : "spento") dalla scheda")
        let gen = generation
        for delay in [1.0, 3.0] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, gen == self.generation else { return }
                    self.readBluetoothPower()
                }
            }
        }
    }

    private func readWiFi() {
        guard host != nil else { return }
        guard let iface = wifi?.interface else {
            model.wifiAvailable = false
            return
        }
        model.wifiAvailable = true
        model.wifiOn = iface.powerOn()
        let name = model.wifiOn ? iface.ssid() : nil
        model.wifiName = (name?.isEmpty ?? true) ? nil : name
    }

    private func toggleWiFi() {
        guard let iface = wifi?.interface else { return }
        let target = !iface.powerOn()
        model.wifiOn = target
        let gen = generation
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            // CWInterface non è Sendable: qui ne prendiamo uno nuovo.
            var failed = false
            do { try CWWiFiClient.shared().interface()?.setPower(target) } catch { failed = true }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, gen == self.generation else { return }
                    self.host?.log(failed ? "Wi-Fi: cambio non riuscito" : "Wi-Fi \(target ? "acceso" : "spento") dalla scheda")
                    self.readWiFi()
                }
            }
        }
    }

    private func updateLocationState() {
        model.locationState = location.isAuthorized ? .allowed : (location.isDenied ? .denied : .notAsked)
    }

    func requestLocation() {
        location.request()
    }

    // MARK: - Scorciatoia

    private static func modifiers(_ variant: Int) -> UInt32 {
        UInt32(controlKey | optionKey | (variant == 1 ? shiftKey : 0))
    }

    static func hotkeyName(_ variant: Int) -> String { variant == 1 ? "⌃⇧⌥M" : "⌃⌥M" }

    private func registerHotkey() {
        unregisterHotkey()
        guard host != nil, settings.hotkeyEnabled else {
            hotkeyStatus = .off
            updateHotkeyTexts()
            return
        }
        let variants: [Int] = settings.hotkeyVariant == 0 ? [0] : settings.hotkeyVariant == 1 ? [1] : [0, 1]
        for v in variants {
            let hk = HotKey(keyCode: UInt32(kVK_ANSI_M), modifiers: Self.modifiers(v)) { [weak self] in
                self?.toggleMute(source: "scorciatoia")
            }
            if hk.isRegistered {
                hotKey = hk
                activeVariant = v
                hotkeyStatus = .active
                host?.log(v != variants[0]
                          ? "\(Self.hotkeyName(variants[0])) è già usata: uso \(Self.hotkeyName(v))"
                          : "scorciatoia \(Self.hotkeyName(v)) registrata")
                updateHotkeyTexts()
                return
            }
        }
        activeVariant = variants.last ?? 0
        hotkeyStatus = .taken
        host?.log("scorciatoia del muto non disponibile: combinazione già usata")
        updateHotkeyTexts()
    }

    private func unregisterHotkey() {
        hotKey?.unregister()
        hotKey = nil
        hotkeyStatus = .off
    }

    private func updateHotkeyTexts() {
        let name = Self.hotkeyName(activeVariant)
        switch hotkeyStatus {
        case .active:
            model.hotkeyHint = name
            model.hotkeyStatusText = "Attiva: premi \(name) in qualsiasi app."
            model.hotkeyProblem = false
        case .taken:
            model.hotkeyHint = "Tocca per il muto"
            model.hotkeyStatusText = settings.hotkeyVariant == -1
                ? "⌃⌥M e ⌃⇧⌥M sono già usate da altre app."
                : "\(name) è già usata da un'altra app. Scegli un'altra combinazione."
            model.hotkeyProblem = true
        case .off:
            model.hotkeyHint = "Tocca per il muto"
            model.hotkeyStatusText = "Spenta."
            model.hotkeyProblem = false
        }
    }

    // MARK: - Impostazioni

    func updateSettings(_ change: (inout ControlsSettings) -> Void) {
        var s = settings
        change(&s)
        guard s != settings else { return }
        let hotkeyChanged = s.hotkeyEnabled != settings.hotkeyEnabled || s.hotkeyVariant != settings.hotkeyVariant
        settings = s
        model.showBrightness = s.showBrightness
        model.showRadios = s.showRadios
        host?.saveSettings(s)
        if hotkeyChanged { registerHotkey() }
        refreshFace()
    }
}
