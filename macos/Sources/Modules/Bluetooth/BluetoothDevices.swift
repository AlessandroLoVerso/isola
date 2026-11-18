import AppKit
import Foundation
import IOBluetooth
import IOKit

/// Batteria di un dispositivo, in percento (1...100). `nil` = non nota: mai numeri inventati.
struct BTBattery: Equatable {
    var left: Int?
    var right: Int?
    var caseLevel: Int?
    var single: Int?

    var isEmpty: Bool { left == nil && right == nil && caseLevel == nil && single == nil }

    /// Il valore più basso tra auricolari o dispositivo singolo (per la faccia).
    var lowest: Int? { [left, right, single].compactMap { $0 }.min() }

    /// Completa i valori mancanti con quelli di un'altra fonte.
    func filling(with other: BTBattery) -> BTBattery {
        BTBattery(left: left ?? other.left, right: right ?? other.right,
                  caseLevel: caseLevel ?? other.caseLevel, single: single ?? other.single)
    }
}

/// Un dispositivo collegato, come lo vede la scheda.
struct BTDevice: Identifiable, Equatable {
    /// Indirizzo normalizzato (minuscolo, senza separatori).
    let id: String
    var name: String
    var symbol: String
    var isAudio: Bool
    var battery: BTBattery
}

enum BTInfo {
    static func key(_ address: String?) -> String {
        (address ?? "").lowercased().filter { $0.isHexDigit }
    }

    // MARK: Proprietà private con controllo del tipo

    /// Legge un selettore senza argomenti solo se esiste e restituisce il tipo atteso
    /// (codifica Objective-C), così una firma diversa non può far crashare.
    private static func getter(_ object: NSObject, _ name: String, encoding: String) -> (IMP, Selector)? {
        let sel = NSSelectorFromString(name)
        guard object.responds(to: sel), let method = class_getInstanceMethod(type(of: object), sel) else { return nil }
        let ret = method_copyReturnType(method)
        defer { free(ret) }
        guard String(cString: ret) == encoding, method_getNumberOfArguments(method) == 2 else { return nil }
        return (method_getImplementation(method), sel)
    }

    private static func percent(_ device: IOBluetoothDevice, _ name: String) -> Int? {
        typealias Fn = @convention(c) (AnyObject, Selector) -> UInt8
        guard let (imp, sel) = getter(device, name, encoding: "C") else { return nil }
        let v = unsafeBitCast(imp, to: Fn.self)(device, sel)
        return (1...100).contains(v) ? Int(v) : nil
    }

    private static func int64(_ device: IOBluetoothDevice, _ name: String) -> Int64? {
        typealias Fn = @convention(c) (AnyObject, Selector) -> Int64
        guard let (imp, sel) = getter(device, name, encoding: "q") else { return nil }
        return unsafeBitCast(imp, to: Fn.self)(device, sel)
    }

    static func uint16(_ device: IOBluetoothDevice, _ name: String) -> UInt16? {
        typealias Fn = @convention(c) (AnyObject, Selector) -> UInt16
        guard let (imp, sel) = getter(device, name, encoding: "S") else { return nil }
        return unsafeBitCast(imp, to: Fn.self)(device, sel)
    }

    static func bool(_ device: IOBluetoothDevice, _ name: String) -> Bool? {
        typealias Fn = @convention(c) (AnyObject, Selector) -> Bool
        guard let (imp, sel) = getter(device, name, encoding: "B") else { return nil }
        return unsafeBitCast(imp, to: Fn.self)(device, sel)
    }

    /// 1) proprietà private di IOBluetoothDevice, 2) IORegistry (`BatteryPercent`).
    static func battery(_ device: IOBluetoothDevice) -> BTBattery {
        var b = BTBattery()
        b.left = percent(device, "batteryPercentLeft")
        b.right = percent(device, "batteryPercentRight")
        b.caseLevel = percent(device, "batteryPercentCase")
        b.single = percent(device, "batteryPercentSingle")
        if b.left == nil, b.right == nil, b.single == nil {
            b.single = percent(device, "batteryPercentCombined")
        }
        if b.single == nil, b.left == nil, b.right == nil,
           let h = int64(device, "headsetBattery"), (1...100).contains(h) {
            b.single = Int(h)
        }
        if b.isEmpty, let p = registryBattery(key(device.addressString)) {
            b.single = p
        }
        return b
    }

    /// Tastiere, mouse e trackpad Apple espongono `BatteryPercent` nell'IORegistry.
    static func registryBattery(_ address: String) -> Int? {
        guard !address.isEmpty else { return nil }
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("AppleDeviceManagementHIDEventService"),
                                           &iterator) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(iterator) }
        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }
            guard let addr = IORegistryEntryCreateCFProperty(service, "DeviceAddress" as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? String, key(addr) == address else { continue }
            if let p = IORegistryEntryCreateCFProperty(service, "BatteryPercent" as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? Int, (1...100).contains(p) {
                return p
            }
        }
        return nil
    }

    // MARK: Tipo e icona

    private static let appleVendor: UInt16 = 0x004C

    /// Product ID Apple/Beats noti → SF Symbol (con ripieghi se il simbolo manca).
    private static let appleSymbols: [UInt16: [String]] = [
        0x2002: ["airpods"], 0x200F: ["airpods"],
        0x2013: ["airpods.gen3", "airpods"],
        0x2019: ["airpods.gen4", "airpods.gen3", "airpods"], 0x201B: ["airpods.gen4", "airpods.gen3", "airpods"],
        0x200E: ["airpodspro"], 0x2014: ["airpodspro"], 0x2024: ["airpodspro"], 0x2027: ["airpodspro"],
        0x200A: ["airpodsmax"], 0x201F: ["airpodsmax"],
        0x2012: ["beats.fitpro", "beats.earphones", "earbuds"],
        0x200B: ["beats.powerbeatspro", "beats.earphones", "earbuds"],
        0x2011: ["beats.studiobuds", "beats.earphones", "earbuds"],
        0x2017: ["beats.studiobuds", "beats.earphones", "earbuds"],
        0x2006: ["beats.headphones", "headphones"], 0x2009: ["beats.headphones", "headphones"],
        0x200C: ["beats.headphones", "headphones"], 0x200D: ["beats.earphones", "earbuds"],
        0x2010: ["beats.earphones", "earbuds"],
    ]

    static func firstSymbol(_ names: [String], fallback: String) -> String {
        names.first { NSImage(systemSymbolName: $0, accessibilityDescription: nil) != nil } ?? fallback
    }

    static func describe(_ device: IOBluetoothDevice) -> (symbol: String, isAudio: Bool) {
        let major = device.deviceClassMajor
        let minor = device.deviceClassMinor
        let vendor = uint16(device, "vendorID")
        let product = uint16(device, "productID")
        let audioSink = bool(device, "isAudioSink") ?? false

        if vendor == appleVendor, let product, let names = appleSymbols[product] {
            return (firstSymbol(names, fallback: "headphones"), true)
        }
        // Il nome serve solo a scegliere l'icona: non esce mai dal Mac e non va nel log.
        let name = (device.name ?? "").lowercased()
        if name.contains("airpods max") { return ("airpodsmax", true) }
        if name.contains("airpods pro") { return ("airpodspro", true) }
        if name.contains("airpods") { return (firstSymbol(["airpods"], fallback: "headphones"), true) }

        switch major {
        case UInt32(kBluetoothDeviceClassMajorAudio):
            switch minor {
            case 0x05, 0x07, 0x0A: return ("hifispeaker", true)       // altoparlante, portatile, Hi-Fi
            case 0x08: return (firstSymbol(["car"], fallback: "hifispeaker"), true)
            default: return ("headphones", true)                        // cuffie, auricolare, vivavoce
            }
        case UInt32(kBluetoothDeviceClassMajorPeripheral):
            if minor & 0x10 != 0 { return ("keyboard", false) }
            if minor & 0x20 != 0 {
                return (firstSymbol(["magicmouse", "computermouse"], fallback: "computermouse"), false)
            }
            return (firstSymbol(["gamecontroller"], fallback: "dot.radiowaves.left.and.right"), false)
        case UInt32(kBluetoothDeviceClassMajorPhone):
            return ("iphone", false)
        case UInt32(kBluetoothDeviceClassMajorComputer):
            return ("laptopcomputer", false)
        default:
            return (audioSink ? "hifispeaker" : "dot.radiowaves.left.and.right", audioSink)
        }
    }

    static func snapshot(_ device: IOBluetoothDevice, readBattery: Bool) -> BTDevice {
        let kind = describe(device)
        return BTDevice(id: key(device.addressString),
                        name: device.name ?? "Dispositivo Bluetooth",
                        symbol: kind.symbol,
                        isAudio: kind.isAudio,
                        battery: readBattery ? battery(device) : BTBattery())
    }
}

// MARK: - Connessioni (IOBluetooth, a eventi)

/// Avvisa quando un dispositivo si collega o si scollega. Niente polling: notifiche di
/// IOBluetooth (connessioni) e una notifica di disconnessione per ogni dispositivo.
@MainActor
final class BluetoothWatcher: NSObject {
    private var connectNotification: IOBluetoothUserNotification?
    private var disconnectNotifications: [String: IOBluetoothUserNotification] = [:]
    private(set) var devices: [String: IOBluetoothDevice] = [:]

    /// (dispositivo, `true` se si è appena collegato e non era già noto)
    var onConnect: ((IOBluetoothDevice, Bool) -> Void)?
    var onDisconnect: ((String) -> Void)?

    func start() {
        // Quelli già collegati: entrano in elenco senza avviso.
        for case let device as IOBluetoothDevice in IOBluetoothDevice.pairedDevices() ?? [] where device.isConnected() {
            track(device, announce: false)
        }
        connectNotification = IOBluetoothDevice.register(forConnectNotifications: self,
                                                         selector: #selector(deviceConnected(_:device:)))
    }

    func stop() {
        connectNotification?.unregister()
        connectNotification = nil
        disconnectNotifications.values.forEach { $0.unregister() }
        disconnectNotifications = [:]
        devices = [:]
    }

    /// Riallinea l'elenco (per esempio quando si apre la scheda).
    func resync() {
        let connected = (IOBluetoothDevice.pairedDevices() ?? []).compactMap { $0 as? IOBluetoothDevice }
            .filter { $0.isConnected() }
        let keys = Set(connected.map { BTInfo.key($0.addressString) })
        for key in devices.keys where !keys.contains(key) { forget(key) }
        for device in connected where devices[BTInfo.key(device.addressString)] == nil {
            track(device, announce: false)
        }
    }

    func disconnect(_ key: String) {
        _ = devices[key]?.closeConnection()
    }

    private func track(_ device: IOBluetoothDevice, announce: Bool) {
        let key = BTInfo.key(device.addressString)
        guard !key.isEmpty else { return }
        let isNew = devices[key] == nil
        devices[key] = device
        if disconnectNotifications[key] == nil {
            disconnectNotifications[key] = device.register(forDisconnectNotification: self,
                                                           selector: #selector(deviceDisconnected(_:device:)))
        }
        onConnect?(device, announce && isNew)
    }

    private func forget(_ key: String) {
        disconnectNotifications.removeValue(forKey: key)?.unregister()
        guard devices.removeValue(forKey: key) != nil else { return }
        onDisconnect?(key)
    }

    @objc private func deviceConnected(_ notification: IOBluetoothUserNotification?, device: IOBluetoothDevice?) {
        guard connectNotification != nil, let device else { return }
        track(device, announce: true)
    }

    @objc private func deviceDisconnected(_ notification: IOBluetoothUserNotification?, device: IOBluetoothDevice?) {
        guard let device else {
            notification?.unregister()
            return
        }
        forget(BTInfo.key(device.addressString))
    }
}

// MARK: - Ripiego: system_profiler (una volta, in sottofondo)

/// Se IOBluetooth non dà la batteria, chiede a `system_profiler` (circa 0,3 s) una sola volta
/// dopo la connessione, fuori dal main thread.
final class ProfilerBattery: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?

    func fetch(completion: @escaping @Sendable ([String: BTBattery]) -> Void) {
        lock.lock()
        guard process == nil else { lock.unlock(); return }
        let p = Process()
        process = p
        lock.unlock()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/system_profiler")
        p.arguments = ["SPBluetoothDataType", "-json"]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        DispatchQueue.global(qos: .utility).async { [weak self] in
            var result: [String: BTBattery] = [:]
            do {
                try p.run()
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                p.waitUntilExit()
                if p.terminationStatus == 0 { result = Self.parse(data) }
            } catch {}
            self?.lock.lock()
            self?.process = nil
            self?.lock.unlock()
            completion(result)
        }
    }

    func cancel() {
        lock.lock()
        let p = process
        process = nil
        lock.unlock()
        if let p, p.isRunning { p.terminate() }
    }

    private static func parse(_ data: Data) -> [String: BTBattery] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let sections = root["SPBluetoothDataType"] as? [[String: Any]] else { return [:] }
        var out: [String: BTBattery] = [:]
        for section in sections {
            for entry in section["device_connected"] as? [[String: Any]] ?? [] {
                for case let props as [String: Any] in entry.values {
                    let key = BTInfo.key(props["device_address"] as? String)
                    guard !key.isEmpty else { continue }
                    let b = BTBattery(left: level(props["device_batteryLevelLeft"]),
                                      right: level(props["device_batteryLevelRight"]),
                                      caseLevel: level(props["device_batteryLevelCase"]),
                                      single: level(props["device_batteryLevelMain"]) ?? level(props["device_batteryLevel"]))
                    if !b.isEmpty { out[key] = b }
                }
            }
        }
        return out
    }

    private static func level(_ value: Any?) -> Int? {
        let n: Int?
        switch value {
        case let s as String: n = Int(s.filter(\.isNumber))
        case let i as Int: n = i
        default: n = nil
        }
        guard let n, (1...100).contains(n) else { return nil }
        return n
    }
}
