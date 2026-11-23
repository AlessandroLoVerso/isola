import Foundation
import IOKit
import IOKit.ps

/// Lo stato della batteria interna in un istante. Solo lettura.
struct BatteryState: Equatable {
    var present = false
    var percent = 0
    var pluggedIn = false
    var charging = false
    var charged = false
    /// La carica ottimizzata ha messo in pausa la ricarica (di solito all'80%).
    var optimizedPause = false
    /// `nil` = sconosciuto o "calcolo in corso".
    var minutesToEmpty: Int?
    var minutesToFull: Int?
    var adapterWatts: Int?
    var cycleCount: Int?
    var designCycles: Int?
    /// Capacità massima rispetto a quella di fabbrica, in percento (stima).
    var maxCapacity: Int?
    var lowPowerMode = false

    /// Collegato all'alimentatore ma fermo: limite di carica, batteria calda, ecc.
    var pluggedNotCharging: Bool { pluggedIn && !charging && !charged && !optimizedPause }
}

enum BatteryReader {
    /// Legge le fonti di alimentazione (IOPowerSources) e, se ci sono, i dati di AppleSmartBattery.
    static func read() -> BatteryState {
        var s = BatteryState()
        s.lowPowerMode = ProcessInfo.processInfo.isLowPowerModeEnabled

        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return s }

        for source in list {
            guard let d = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
                  d["Type"] as? String == "InternalBattery" else { continue }
            if let present = d["Is Present"], !bool(present) { continue }
            s.present = true
            let current = int(d["Current Capacity"]) ?? 0
            let max = int(d["Max Capacity"]) ?? 100
            s.percent = max > 0 ? Swift.min(100, Swift.max(0, Int((Double(current) / Double(max) * 100).rounded()))) : current
            s.pluggedIn = (d["Power Source State"] as? String) == "AC Power"
            s.charging = bool(d["Is Charging"])
            s.charged = bool(d["Is Charged"]) || (s.pluggedIn && !s.charging && s.percent >= 100)
            s.optimizedPause = s.pluggedIn && !s.charging && !s.charged
                && bool(d["Optimized Battery Charging Engaged"])
            if let t = int(d["Time to Empty"]), t > 0, !s.pluggedIn { s.minutesToEmpty = t }
            if let t = int(d["Time to Full Charge"]), t > 0, s.charging { s.minutesToFull = t }
            s.designCycles = int(d["DesignCycleCount"])
            if bool(d["LPM Active"]) { s.lowPowerMode = true }
            break
        }
        guard s.present else { return s }

        if s.pluggedIn, let adapter = IOPSCopyExternalPowerAdapterDetails()?.takeRetainedValue() as? [String: Any],
           let watts = int(adapter["Watts"]), watts > 0 {
            s.adapterWatts = watts
        }
        readSmartBattery(into: &s)
        return s
    }

    /// Cicli e capacità massima da IORegistry (`AppleSmartBattery`). Se mancano restano `nil`.
    private static func readSmartBattery(into s: inout BatteryState) {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard service != 0 else { return }
        defer { IOObjectRelease(service) }

        func value(_ key: String) -> Int? {
            int(IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue())
        }
        if let cycles = value("CycleCount"), cycles >= 0 { s.cycleCount = cycles }
        if s.designCycles == nil { s.designCycles = value("DesignCycleCount9C") }
        if let design = value("DesignCapacity"), design > 0,
           let full = value("NominalChargeCapacity") ?? value("AppleRawMaxCapacity"), full > 0 {
            s.maxCapacity = min(100, Int((Double(full) / Double(design) * 100).rounded()))
        }
    }

    private static func int(_ any: Any?) -> Int? {
        if let n = any as? NSNumber { return n.intValue }
        if let i = any as? Int { return i }
        return nil
    }

    private static func bool(_ any: Any?) -> Bool {
        if let b = any as? Bool { return b }
        if let n = any as? NSNumber { return n.boolValue }
        return false
    }
}
