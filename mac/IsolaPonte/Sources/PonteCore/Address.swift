import Darwin
import Foundation
import Network

/// An IPv4 (4 bytes) or IPv6 (16 bytes) address.
public struct IPAddr: Hashable, Sendable, CustomStringConvertible {
    public let bytes: [UInt8]

    public init?(bytes: [UInt8]) {
        guard bytes.count == 4 || bytes.count == 16 else { return nil }
        self.bytes = bytes
    }

    /// A literal "100.1.2.3" or "fd7a::1" (no names).
    public init?(_ text: String) {
        var s = text
        if let pct = s.firstIndex(of: "%") { s = String(s[..<pct]) } // drop an IPv6 zone
        var v4 = in_addr()
        if inet_pton(AF_INET, s, &v4) == 1 {
            self.bytes = withUnsafeBytes(of: &v4) { Array($0) }
            return
        }
        var v6 = in6_addr()
        if inet_pton(AF_INET6, s, &v6) == 1 {
            self.bytes = withUnsafeBytes(of: &v6) { Array($0) }
            return
        }
        return nil
    }

    public init?(host: NWEndpoint.Host) {
        switch host {
        case .ipv4(let a): self.init(bytes: Array(a.rawValue))
        case .ipv6(let a): self.init(bytes: Array(a.rawValue))
        default: return nil
        }
    }

    public var isV4: Bool { bytes.count == 4 }

    /// ::ffff:a.b.c.d → a.b.c.d; anything else unchanged.
    public var unmapped: IPAddr {
        if bytes.count == 16, bytes[0..<10].allSatisfy({ $0 == 0 }), bytes[10] == 0xFF, bytes[11] == 0xFF {
            return IPAddr(bytes: Array(bytes[12..<16]))!
        }
        return self
    }

    /// 100.64.0.0/10 (Tailscale IPv4) or fd7a:115c:a1e0::/48 (Tailscale IPv6).
    public var isTailscale: Bool {
        let b = unmapped.bytes
        if b.count == 4 { return b[0] == 100 && (b[1] & 0xC0) == 64 }
        return b[0] == 0xFD && b[1] == 0x7A && b[2] == 0x11 && b[3] == 0x5C && b[4] == 0xA1 && b[5] == 0xE0
    }

    public var isLoopback: Bool {
        let b = unmapped.bytes
        if b.count == 4 { return b[0] == 127 }
        return b[0..<15].allSatisfy({ $0 == 0 }) && b[15] == 1
    }

    public var description: String {
        var buf = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
        let family = isV4 ? AF_INET : AF_INET6
        _ = bytes.withUnsafeBytes { inet_ntop(family, $0.baseAddress, &buf, socklen_t(buf.count)) }
        return String(cString: buf)
    }

    /// For URLs: IPv6 in brackets.
    public var urlHost: String { isV4 ? description : "[\(description)]" }

    public var nwHost: NWEndpoint.Host {
        if isV4 { return .ipv4(IPv4Address(Data(bytes))!) }
        return .ipv6(IPv6Address(Data(bytes))!)
    }
}

public enum LocalAddresses {
    /// This Mac's Tailscale IPv4: an address in 100.64.0.0/10 on an "up" utun interface (where the
    /// Tailscale app puts it). Nil when Tailscale is not running or not connected.
    public static func tailscaleIPv4() -> IPAddr? {
        all().first { $0.name.hasPrefix("utun") && $0.addr.isV4 && $0.addr.isTailscale }?.addr
    }

    /// Every address on this Mac's interfaces (to notice a peer name that points back here).
    public static func set() -> Set<IPAddr> { Set(all().map(\.addr)) }

    private static func all() -> [(name: String, addr: IPAddr)] {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return [] }
        defer { freeifaddrs(head) }
        var out: [(String, IPAddr)] = []
        var p: UnsafeMutablePointer<ifaddrs>? = first
        while let ifa = p {
            defer { p = ifa.pointee.ifa_next }
            let flags = Int32(ifa.pointee.ifa_flags)
            guard flags & IFF_UP != 0, let sa = ifa.pointee.ifa_addr else { continue }
            let name = String(cString: ifa.pointee.ifa_name)
            switch Int32(sa.pointee.sa_family) {
            case AF_INET:
                let a = sa.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr }
                if let ip = IPAddr(bytes: withUnsafeBytes(of: a) { Array($0) }) { out.append((name, ip)) }
            case AF_INET6:
                let a = sa.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { $0.pointee.sin6_addr }
                if let ip = IPAddr(bytes: withUnsafeBytes(of: a) { Array($0) }) { out.append((name, ip)) }
            default:
                break
            }
        }
        return out
    }
}
