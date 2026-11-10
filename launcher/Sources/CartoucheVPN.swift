//
//  CartoucheVPN.swift
//  Cartouche
//
//  Whether LocalDevVPN is connected. The built-in SideStore reaches the
//  iPhone's own services through it when it signs in, renews Cartouche and
//  installs its updates. LocalDevVPN gives the iPhone a tunnel interface,
//  utun<n>, with an IPv4 address in 10.7.0.0/16: that is how SideStore's
//  own onboarding tells that it is on (OnboardingView.swift,
//  LocalDevVPNStep), and Cartouche reads the same, without connecting to
//  anything.
//

import Foundation

enum CartoucheVPN {
    /// An interface of this device that is up, with its IPv4 address.
    struct Interface: Equatable {
        let name: String
        let address: String
    }

    /// Whether these interfaces hold LocalDevVPN's tunnel.
    static func hasTunnel(_ interfaces: [Interface]) -> Bool {
        interfaces.contains { $0.name.lowercased().hasPrefix("utun") && $0.address.hasPrefix("10.7.") }
    }

    /// Whether LocalDevVPN is connected now.
    static var isConnected: Bool { hasTunnel(interfaces()) }

    /// This device's interfaces that are up, with their IPv4 addresses.
    static func interfaces() -> [Interface] {
        var first: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&first) == 0, let first else { return [] }
        defer { freeifaddrs(first) }
        var found: [Interface] = []
        for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let entry = pointer.pointee
            guard entry.ifa_flags & UInt32(IFF_UP) != 0, let address = entry.ifa_addr,
                  address.pointee.sa_family == sa_family_t(AF_INET) else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(address, socklen_t(address.pointee.sa_len), &host, socklen_t(host.count),
                              nil, 0, NI_NUMERICHOST) == 0 else { continue }
            let name = String(cString: entry.ifa_name)
            let text = host.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
            found.append(Interface(name: name, address: text))
        }
        return found
    }
}
