//
//  CartoucheVPNTests.swift
//  CartoucheCoreTests
//
//  How Cartouche tells that LocalDevVPN is connected
//  (Sources/CartoucheVPN.swift): its tunnel, utun<n> with an address in
//  10.7.0.0/16, as SideStore's onboarding reads it.
//

import Foundation
import XCTest
@testable import CartoucheCore

final class CartoucheVPNTests: XCTestCase {
    func testLocalDevVPNsTunnelIsSeen() {
        let interfaces: [CartoucheVPN.Interface] = [
            .init(name: "lo0", address: "127.0.0.1"),
            .init(name: "en0", address: "192.168.1.20"),
            .init(name: "utun4", address: "10.7.0.10"),
        ]
        XCTAssertTrue(CartoucheVPN.hasTunnel(interfaces))
    }

    func testAnotherVPNOrNetworkIsNotLocalDevVPN() {
        let interfaces: [CartoucheVPN.Interface] = [
            .init(name: "utun0", address: "10.8.0.2"),
            .init(name: "en0", address: "10.7.0.5"),
            .init(name: "ipsec0", address: "10.7.0.9"),
        ]
        XCTAssertFalse(CartoucheVPN.hasTunnel(interfaces))
        XCTAssertFalse(CartoucheVPN.hasTunnel([]))
    }

    func testThisMachinesInterfacesAreRead() {
        // Every Mac has its loopback up, with its IPv4 address.
        XCTAssertTrue(CartoucheVPN.interfaces().contains { $0.name == "lo0" && $0.address == "127.0.0.1" })
    }
}
