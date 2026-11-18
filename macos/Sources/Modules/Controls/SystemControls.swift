import AppKit
import CoreGraphics
import CoreLocation
import CoreWLAN
import Foundation

// MARK: - Luminosità (DisplayServices, privato)

/// Luminosità dello schermo integrato con `DisplayServices.framework` (privato, caricato con
/// `dlopen`). Se manca qualcosa `isAvailable` è falso e la scheda nasconde il cursore.
@MainActor
final class BrightnessControl {
    private typealias GetFn = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32
    private typealias SetFn = @convention(c) (CGDirectDisplayID, Float) -> Int32
    private typealias CanFn = @convention(c) (CGDirectDisplayID) -> Bool

    private let getFn: GetFn?
    private let setFn: SetFn?
    private let canFn: CanFn?

    init() {
        let handle = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_LAZY)
        func load<T>(_ name: String, _: T.Type) -> T? {
            guard let handle, let sym = dlsym(handle, name) else { return nil }
            return unsafeBitCast(sym, to: T.self)
        }
        getFn = load("DisplayServicesGetBrightness", GetFn.self)
        setFn = load("DisplayServicesSetBrightness", SetFn.self)
        canFn = load("DisplayServicesCanChangeBrightness", CanFn.self)
    }

    /// Lo schermo integrato, se è acceso (a coperchio chiuso non c'è).
    private var builtInDisplay: CGDirectDisplayID? {
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(0, nil, &count) == .success, count > 0 else { return nil }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetOnlineDisplayList(count, &ids, &count) == .success else { return nil }
        return ids.prefix(Int(count)).first { CGDisplayIsBuiltin($0) != 0 }
    }

    /// 0...1, oppure `nil` se non si può leggere o cambiare.
    func read() -> Double? {
        guard let getFn, setFn != nil, let display = builtInDisplay else { return nil }
        if let canFn, !canFn(display) { return nil }
        var value: Float = 0
        guard getFn(display, &value) == 0, value.isFinite else { return nil }
        return Double(min(max(value, 0), 1))
    }

    func set(_ value: Double) {
        guard let setFn, let display = builtInDisplay else { return }
        _ = setFn(display, Float(min(max(value, 0), 1)))
    }
}

// MARK: - Bluetooth acceso/spento (IOBluetooth, privato)

/// `IOBluetoothPreferenceGet/SetControllerPowerState` (non documentate) con `dlsym`.
/// Se mancano, la scheda offre di aprire Impostazioni di Sistema › Bluetooth.
@MainActor
final class BluetoothPower {
    private typealias GetFn = @convention(c) () -> Int32
    private typealias SetFn = @convention(c) (Int32) -> Void

    private let getFn: GetFn?
    private let setFn: SetFn?

    init() {
        let handle = dlopen("/System/Library/Frameworks/IOBluetooth.framework/IOBluetooth", RTLD_LAZY)
        if let handle, let g = dlsym(handle, "IOBluetoothPreferenceGetControllerPowerState") {
            getFn = unsafeBitCast(g, to: GetFn.self)
        } else { getFn = nil }
        if let handle, let s = dlsym(handle, "IOBluetoothPreferenceSetControllerPowerState") {
            setFn = unsafeBitCast(s, to: SetFn.self)
        } else { setFn = nil }
    }

    var isAvailable: Bool { getFn != nil && setFn != nil }

    /// Da chiamare solo quando l'utente apre la scheda: può far chiedere il permesso Bluetooth.
    func read() -> Bool? {
        guard let getFn else { return nil }
        return getFn() != 0
    }

    func set(_ on: Bool) {
        setFn?(on ? 1 : 0)
    }

    static func openSystemSettings() {
        let urls = [
            "x-apple.systempreferences:com.apple.BluetoothSettings",
            "x-apple.systempreferences:com.apple.preferences.Bluetooth",
        ]
        for s in urls {
            if let url = URL(string: s), NSWorkspace.shared.open(url) { return }
        }
    }
}

// MARK: - Wi-Fi (CoreWLAN)

/// Stato del Wi-Fi e notifiche di macOS (accensione, rete). Usa un `CWWiFiClient` suo, così
/// `stopMonitoringAllEvents` non tocca gli altri moduli.
final class WiFiWatcher: NSObject, CWEventDelegate, @unchecked Sendable {
    private let client = CWWiFiClient()
    private let onChange: @MainActor () -> Void

    init(onChange: @escaping @MainActor () -> Void) {
        self.onChange = onChange
        super.init()
    }

    var interface: CWInterface? { client.interface() }

    func start() {
        client.delegate = self
        for event in [CWEventType.powerDidChange, .ssidDidChange, .linkDidChange] {
            try? client.startMonitoringEvent(with: event)
        }
    }

    func stop() {
        try? client.stopMonitoringAllEvents()
        client.delegate = nil
    }

    private func changed() {
        let handler = onChange
        DispatchQueue.main.async { MainActor.assumeIsolated { handler() } }
    }

    func powerStateDidChangeForWiFiInterface(withName interfaceName: String) { changed() }
    func ssidDidChangeForWiFiInterface(withName interfaceName: String) { changed() }
    func linkDidChangeForWiFiInterface(withName interfaceName: String) { changed() }
}

// MARK: - Posizione (solo per il nome della rete Wi-Fi)

/// Da macOS 14 il nome della rete Wi-Fi si legge solo con il permesso Posizione. Non lo
/// chiediamo mai da soli: solo quando l'utente tocca il pulsante nelle impostazioni.
@MainActor
final class LocationAccess: NSObject, CLLocationManagerDelegate {
    private var manager: CLLocationManager?
    var onChange: (() -> Void)?

    var status: CLAuthorizationStatus {
        (manager ?? CLLocationManager()).authorizationStatus
    }

    var isAuthorized: Bool {
        status == .authorizedAlways || status == .authorized
    }

    var isDenied: Bool { status == .denied || status == .restricted }

    func start() {
        guard manager == nil else { return }
        let m = CLLocationManager()
        m.delegate = self
        manager = m
    }

    func stop() {
        manager?.delegate = nil
        manager = nil
    }

    func request() {
        start()
        if isDenied {
            Self.openPrivacySettings()
        } else {
            manager?.requestWhenInUseAuthorization()
        }
    }

    static func openPrivacySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocationServices") {
            NSWorkspace.shared.open(url)
        }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        DispatchQueue.main.async { MainActor.assumeIsolated { self.onChange?() } }
    }
}
