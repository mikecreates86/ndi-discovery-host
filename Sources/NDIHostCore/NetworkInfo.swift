import Foundation
#if canImport(Darwin)
import Darwin
#endif

public struct DeviceAddress: Equatable {
    public let interface: String
    public let ip: String
}

public enum NetworkInfo {
    /// Active, non-loopback IPv4 addresses. Link-local (169.254.x.x) is skipped:
    /// those are unplugged or unconfigured ports, and devices can't use them.
    public static func ipv4Addresses() -> [DeviceAddress] {
        #if canImport(Darwin)
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return [] }
        defer { freeifaddrs(head) }

        var result: [DeviceAddress] = []
        for ptr in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let ifa = ptr.pointee
            let flags = Int32(ifa.ifa_flags)
            guard flags & IFF_UP != 0, flags & IFF_RUNNING != 0, flags & IFF_LOOPBACK == 0,
                  let sa = ifa.ifa_addr, sa.pointee.sa_family == sa_family_t(AF_INET) else { continue }
            var inAddr = sa.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr }
            var buf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            inet_ntop(AF_INET, &inAddr, &buf, socklen_t(INET_ADDRSTRLEN))
            let ip = String(cString: buf)
            if ip.hasPrefix("169.254.") { continue }
            result.append(DeviceAddress(interface: String(cString: ifa.ifa_name), ip: ip))
        }
        return result.sorted { $0.interface < $1.interface }
        #else
        return []
        #endif
    }
}
