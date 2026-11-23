import Darwin
import Foundation
import IOKit

/// Pressione della memoria come la intende macOS (`kern.memorystatus_vm_pressure_level`).
enum MemoryPressure: Equatable {
    case unknown, normal, warning, critical

    var label: String {
        switch self {
        case .unknown: return ""
        case .normal: return "Pressione bassa"
        case .warning: return "Pressione media"
        case .critical: return "Pressione alta"
        }
    }
}

/// Una lettura. `nil` = non disponibile (o prima lettura, senza un intervallo di confronto).
struct PerfSnapshot: Equatable {
    var cpu: Double?
    var cpuPerformance: Double?
    var cpuEfficiency: Double?
    var gpu: Double?
    var ramUsed: UInt64 = 0
    var ramTotal: UInt64 = 0
    var pressure: MemoryPressure = .unknown
    var down: Double?
    var up: Double?
    var thermal: ProcessInfo.ThermalState = .nominal

    var ramPercent: Double? {
        ramTotal > 0 ? Double(ramUsed) / Double(ramTotal) * 100 : nil
    }
}

/// Legge i contatori del sistema. Vive sul main thread e lavora solo quando viene chiamato
/// `sample()`: niente thread, niente timer suoi. Ogni lettura costa pochi microsecondi.
final class PerfSampler {
    /// Numero di core a efficienza: su Apple Silicon sono i primi (cpu0…cpuN-1). 0 = nessuna divisione.
    let efficiencyCores: Int
    let logicalCores: Int

    private var previousTicks: [UInt32]?
    private var previousNet: (down: UInt64, up: UInt64, at: TimeInterval)?
    private var gpuService: io_registry_entry_t = 0
    private var gpuSearched = false
    private let pageSize: UInt64
    private let totalMemory: UInt64

    init() {
        logicalCores = ProcessInfo.processInfo.activeProcessorCount
        totalMemory = ProcessInfo.processInfo.physicalMemory
        var size: vm_size_t = 0
        host_page_size(mach_host_self(), &size)
        pageSize = UInt64(size == 0 ? 16384 : size)

        var e = 0
        if Self.sysctlInt("hw.nperflevels") ?? 0 >= 2, Self.sysctlString("hw.perflevel1.name") == "Efficiency" {
            e = Self.sysctlInt("hw.perflevel1.logicalcpu") ?? 0
        }
        efficiencyCores = (e > 0 && e < logicalCores) ? e : 0
    }

    deinit { close() }

    /// Dimentica le letture precedenti (dopo una pausa il confronto non avrebbe senso).
    func reset() {
        previousTicks = nil
        previousNet = nil
    }

    /// Rilascia gli oggetti IOKit.
    func close() {
        if gpuService != 0 { IOObjectRelease(gpuService) }
        gpuService = 0
        gpuSearched = false
        reset()
    }

    func sample() -> PerfSnapshot {
        var s = PerfSnapshot()
        readCPU(into: &s)
        readMemory(into: &s)
        s.gpu = readGPU()
        readNetwork(into: &s)
        s.thermal = ProcessInfo.processInfo.thermalState
        return s
    }

    // MARK: CPU

    private func readCPU(into s: inout PerfSnapshot) {
        var count: natural_t = 0
        var info: processor_info_array_t?
        var infoCount: mach_msg_type_number_t = 0
        guard host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &count, &info, &infoCount) == KERN_SUCCESS,
              let info else { return }
        defer {
            vm_deallocate(mach_task_self_, vm_address_t(bitPattern: info),
                          vm_size_t(Int(infoCount) * MemoryLayout<integer_t>.stride))
        }
        let states = Int(CPU_STATE_MAX)
        let n = Int(count) * states
        var ticks = [UInt32](repeating: 0, count: n)
        for i in 0..<min(n, Int(infoCount)) { ticks[i] = UInt32(bitPattern: info[i]) }
        defer { previousTicks = ticks }
        guard let old = previousTicks, old.count == ticks.count else { return }

        var busyAll: UInt64 = 0, totalAll: UInt64 = 0
        var busyE: UInt64 = 0, totalE: UInt64 = 0
        var busyP: UInt64 = 0, totalP: UInt64 = 0
        for cpu in 0..<Int(count) {
            let b = cpu * states
            let user = UInt64(ticks[b + Int(CPU_STATE_USER)] &- old[b + Int(CPU_STATE_USER)])
            let system = UInt64(ticks[b + Int(CPU_STATE_SYSTEM)] &- old[b + Int(CPU_STATE_SYSTEM)])
            let nice = UInt64(ticks[b + Int(CPU_STATE_NICE)] &- old[b + Int(CPU_STATE_NICE)])
            let idle = UInt64(ticks[b + Int(CPU_STATE_IDLE)] &- old[b + Int(CPU_STATE_IDLE)])
            let busy = user + system + nice
            let total = busy + idle
            busyAll += busy; totalAll += total
            if efficiencyCores > 0 {
                if cpu < efficiencyCores { busyE += busy; totalE += total } else { busyP += busy; totalP += total }
            }
        }
        if totalAll > 0 { s.cpu = Double(busyAll) / Double(totalAll) * 100 }
        if efficiencyCores > 0 {
            if totalE > 0 { s.cpuEfficiency = Double(busyE) / Double(totalE) * 100 }
            if totalP > 0 { s.cpuPerformance = Double(busyP) / Double(totalP) * 100 }
        }
    }

    // MARK: memoria

    private func readMemory(into s: inout PerfSnapshot) {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let r = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard r == KERN_SUCCESS else { return }
        // Come "Memoria usata" in Monitoraggio Attività: memoria app + wired + compressa.
        let internalPages = UInt64(stats.internal_page_count)
        let purgeable = UInt64(stats.purgeable_count)
        let app = internalPages > purgeable ? internalPages - purgeable : 0
        let used = (app + UInt64(stats.wire_count) + UInt64(stats.compressor_page_count)) * pageSize
        s.ramTotal = totalMemory
        s.ramUsed = min(used, totalMemory)

        switch Self.sysctlInt("kern.memorystatus_vm_pressure_level") {
        case 1: s.pressure = .normal
        case 2: s.pressure = .warning
        case 4: s.pressure = .critical
        default: s.pressure = .unknown
        }
    }

    // MARK: GPU (Apple Silicon e Intel con IOAccelerator)

    private func readGPU() -> Double? {
        if gpuService == 0 {
            guard !gpuSearched else { return nil }
            gpuSearched = true
            gpuService = Self.findAccelerator()
            if gpuService == 0 { return nil }
        }
        guard let ref = IORegistryEntryCreateCFProperty(gpuService, "PerformanceStatistics" as CFString,
                                                        kCFAllocatorDefault, 0)?.takeRetainedValue(),
              let stats = ref as? [String: Any] else { return nil }
        let value = stats["Device Utilization %"] ?? stats["GPU Activity(%)"]
        if let n = value as? NSNumber { return min(100, max(0, n.doubleValue)) }
        return nil
    }

    /// Il primo IOAccelerator che pubblica l'utilizzo. L'oggetto resta trattenuto fino a `close()`.
    private static func findAccelerator() -> io_registry_entry_t {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOAccelerator"), &iterator) == KERN_SUCCESS
        else { return 0 }
        defer { IOObjectRelease(iterator) }
        var found: io_registry_entry_t = 0
        var service = IOIteratorNext(iterator)
        while service != 0 {
            if found == 0,
               let ref = IORegistryEntryCreateCFProperty(service, "PerformanceStatistics" as CFString,
                                                         kCFAllocatorDefault, 0)?.takeRetainedValue(),
               let stats = ref as? [String: Any],
               stats["Device Utilization %"] != nil || stats["GPU Activity(%)"] != nil {
                found = service
            } else {
                IOObjectRelease(service)
            }
            service = IOIteratorNext(iterator)
        }
        return found
    }

    // MARK: rete (interfacce fisiche "en*": Wi-Fi, Ethernet, iPhone)

    private func readNetwork(into s: inout PerfSnapshot) {
        guard let (down, up) = Self.networkBytes() else { return }
        let now = ProcessInfo.processInfo.systemUptime
        defer { previousNet = (down, up, now) }
        guard let old = previousNet else { return }
        let dt = now - old.at
        guard dt > 0.05 else { return }
        // Un contatore che torna indietro (interfaccia sparita) vale zero, non un picco.
        s.down = down >= old.down ? Double(down - old.down) / dt : 0
        s.up = up >= old.up ? Double(up - old.up) / dt : 0
    }

    /// Contatori a 64 bit da `NET_RT_IFLIST2` (quelli di `getifaddrs` sono a 32 bit e ripartono da zero ogni 4 GB).
    private static func networkBytes() -> (UInt64, UInt64)? {
        var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, 0, NET_RT_IFLIST2, 0]
        var length = 0
        guard sysctl(&mib, 6, nil, &length, nil, 0) == 0, length > 0 else { return nil }
        var buffer = [UInt8](repeating: 0, count: length)
        guard sysctl(&mib, 6, &buffer, &length, nil, 0) == 0 else { return nil }

        var down: UInt64 = 0, up: UInt64 = 0
        var name = [CChar](repeating: 0, count: Int(IF_NAMESIZE) + 1)
        buffer.withUnsafeBytes { raw in
            var offset = 0
            let headerSize = MemoryLayout<if_msghdr>.size
            while offset + headerSize <= length {
                let header = raw.loadUnaligned(fromByteOffset: offset, as: if_msghdr.self)
                let messageLength = Int(header.ifm_msglen)
                guard messageLength > 0 else { break }
                if Int32(header.ifm_type) == RTM_IFINFO2,
                   offset + MemoryLayout<if_msghdr2>.size <= length {
                    let h2 = raw.loadUnaligned(fromByteOffset: offset, as: if_msghdr2.self)
                    if if_indextoname(UInt32(h2.ifm_index), &name) != nil,
                       name[0] == CChar(UInt8(ascii: "e")), name[1] == CChar(UInt8(ascii: "n")) {
                        down &+= h2.ifm_data.ifi_ibytes
                        up &+= h2.ifm_data.ifi_obytes
                    }
                }
                offset += messageLength
            }
        }
        return (down, up)
    }

    // MARK: sysctl

    static func sysctlInt(_ name: String) -> Int? {
        var value: Int64 = 0
        var size = MemoryLayout<Int64>.size
        guard sysctlbyname(name, &value, &size, nil, 0) == 0 else { return nil }
        switch size {
        case 4: return Int(Int32(truncatingIfNeeded: value))
        default: return Int(value)
        }
    }

    static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        return String(cString: buffer)
    }
}
