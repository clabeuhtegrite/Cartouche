//
//  CartoucheTunnelWait.swift
//  Cartouche
//
//  Refresh All Apps, the action of Shortcuts that renews Cartouche, waits
//  for LocalDevVPN's tunnel before the built-in SideStore starts
//  (app/patches/livecontainer/0015). The automation that renews Cartouche
//  every night runs LocalDevVPN's Enable action just before it, which
//  returns before the tunnel is up; SideStore reaches the iPhone through
//  it as it starts. Up to 0.12.1, the player had to leave LocalDevVPN
//  connected all day.
//
//  This file joins LiveContainer's SideStoreSupport framework, which
//  cannot import the launcher: it reads the tunnel as the launcher's
//  CartoucheVPN does, utun<n> with an IPv4 address in 10.7.0.0/16, and
//  app/tests/test_renewal.py checks that both read the same.
//

import Foundation

enum CartoucheTunnelWait {
    /// How long Refresh All Apps waits at most: LocalDevVPN's tunnel is up
    /// within a second or two of its action. Without it, SideStore then
    /// says why it cannot reach the iPhone, as up to 0.12.1.
    static let timeout: TimeInterval = 15

    /// Waits until LocalDevVPN's tunnel is up, `timeout` at most: not at
    /// all when it is.
    static func waitForLocalDevVPN() async {
        let started = Date()
        while !isConnected, Date().timeIntervalSince(started) < timeout {
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
    }

    /// Whether LocalDevVPN's tunnel is up: an interface utun<n>, up, with
    /// an IPv4 address in 10.7.0.0/16.
    static var isConnected: Bool {
        var first: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&first) == 0, let first else { return false }
        defer { freeifaddrs(first) }
        for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let entry = pointer.pointee
            guard entry.ifa_flags & UInt32(IFF_UP) != 0, let address = entry.ifa_addr,
                  address.pointee.sa_family == sa_family_t(AF_INET) else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(address, socklen_t(address.pointee.sa_len), &host, socklen_t(host.count),
                              nil, 0, NI_NUMERICHOST) == 0 else { continue }
            let name = String(cString: entry.ifa_name)
            let text = host.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
            if name.lowercased().hasPrefix("utun") && text.hasPrefix("10.7.") { return true }
        }
        return false
    }
}
