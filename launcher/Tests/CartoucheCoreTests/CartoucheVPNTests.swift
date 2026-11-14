//
//  CartoucheVPNTests.swift
//  CartoucheCoreTests
//
//  How Cartouche tells that LocalDevVPN is connected
//  (Sources/CartoucheVPN.swift): its tunnel, utun<n> with an address in
//  10.7.0.0/16, as SideStore's onboarding reads it. When Cartouche has it
//  connect by itself, and how long it waits for it (CartoucheVPNConnect).
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

    // MARK: Having LocalDevVPN connect

    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func situation(connected: Bool = false, installed: Bool = true, inFront: Bool = true,
                           playerAsked: Bool = true, gameRunning: Bool = false,
                           lastAutomaticOpen: Date? = nil) -> CartoucheVPNConnect.Situation {
        CartoucheVPNConnect.Situation(connected: connected, installed: installed, inFront: inFront,
                                      playerAsked: playerAsked, gameRunning: gameRunning,
                                      lastAutomaticOpen: lastAutomaticOpen)
    }

    func testWhatNeedsLocalDevVPNHasItConnect() {
        // Up to 0.12.1, the sign-in, Renew now and an update waited for
        // the player to connect it in its own app.
        XCTAssertEqual(CartoucheVPNConnect.decide(situation(), at: now), .open)
        XCTAssertEqual(CartoucheVPNConnect.decide(situation(playerAsked: false), at: now), .open)
    }

    func testConnectedGoesOnAtOnce() {
        XCTAssertEqual(CartoucheVPNConnect.decide(situation(connected: true), at: now), .goOn)
        XCTAssertEqual(CartoucheVPNConnect.decide(situation(connected: true, installed: false, inFront: false), at: now), .goOn)
    }

    func testNothingOpensWithoutLocalDevVPNOrFromTheBackground() {
        XCTAssertEqual(CartoucheVPNConnect.decide(situation(installed: false), at: now), .leave)
        XCTAssertEqual(CartoucheVPNConnect.decide(situation(inFront: false), at: now), .leave)
        XCTAssertEqual(CartoucheVPNConnect.decide(situation(inFront: false, playerAsked: false), at: now), .leave)
    }

    func testCartoucheOpensItByItselfOnceInAWhile() {
        let lately = now.addingTimeInterval(-CartoucheVPNConnect.automaticSpacing + 60)
        let long = now.addingTimeInterval(-CartoucheVPNConnect.automaticSpacing - 60)
        XCTAssertEqual(CartoucheVPNConnect.decide(situation(playerAsked: false, lastAutomaticOpen: lately), at: now), .leave)
        XCTAssertEqual(CartoucheVPNConnect.decide(situation(playerAsked: false, lastAutomaticOpen: long), at: now), .open)
        // The player's tap opens it whenever Cartouche last did.
        XCTAssertEqual(CartoucheVPNConnect.decide(situation(playerAsked: true, lastAutomaticOpen: lately), at: now), .open)
        // A clock that went back holds nothing back.
        let ahead = now.addingTimeInterval(3_600)
        XCTAssertEqual(CartoucheVPNConnect.decide(situation(playerAsked: false, lastAutomaticOpen: ahead), at: now), .open)
    }

    func testNeverByItselfOverAGameBehindTheConsole() {
        XCTAssertEqual(CartoucheVPNConnect.decide(situation(playerAsked: false, gameRunning: true), at: now), .leave)
        XCTAssertEqual(CartoucheVPNConnect.decide(situation(playerAsked: true, gameRunning: true), at: now), .open)
    }

    func testTheURLBringsCartoucheBack() throws {
        // LocalDevVPN opens "<scheme>://" a second after it starts connecting.
        let url = try XCTUnwrap(CartoucheVPNConnect.enableURL(returningTo: "cartouche"))
        XCTAssertEqual(url.absoluteString, "localdevvpn://enable?scheme=cartouche")
        // A second copy of Cartouche, as LiveContainer numbers its scheme.
        XCTAssertEqual(CartoucheVPNConnect.enableURL(returningTo: "cartouche2")?.absoluteString,
                       "localdevvpn://enable?scheme=cartouche2")
        // LocalDevVPN builds "<scheme>://" with no check: never a scheme it
        // could not open, nor one that would carry more than a scheme.
        XCTAssertNil(CartoucheVPNConnect.enableURL(returningTo: ""))
        XCTAssertNil(CartoucheVPNConnect.enableURL(returningTo: "2cartouche"))
        XCTAssertNil(CartoucheVPNConnect.enableURL(returningTo: "cartouche://x"))
        XCTAssertNil(CartoucheVPNConnect.enableURL(returningTo: "car touche"))
        XCTAssertNil(CartoucheVPNConnect.enableURL(returningTo: "cartouche&scheme=other"))
    }

    func testTheWaitGoesOnOnceConnected() {
        var wait = CartoucheVPNConnect.Wait(started: now)
        XCTAssertEqual(wait.next(connected: false, inFront: true, at: now.addingTimeInterval(0.5)), .keepWaiting)
        XCTAssertEqual(wait.next(connected: true, inFront: true, at: now.addingTimeInterval(1)), .goOn)
    }

    func testTheWaitStopsAfterItsTimeInFront() {
        var wait = CartoucheVPNConnect.Wait(started: now)
        var time = now
        var next = CartoucheVPNConnect.Wait.Next.keepWaiting
        var looks = 0
        while next == .keepWaiting && looks < 1_000 {
            time = time.addingTimeInterval(0.5)
            next = wait.next(connected: false, inFront: true, at: time)
            looks += 1
        }
        XCTAssertEqual(next, .stop)
        XCTAssertEqual(time.timeIntervalSince(now), CartoucheVPNConnect.timeout, accuracy: 0.5)
        XCTAssertEqual(wait.seconds, CartoucheVPNConnect.timeout)
    }

    func testAShorterLimit() {
        var wait = CartoucheVPNConnect.Wait(started: now, limit: 1)
        XCTAssertEqual(wait.next(connected: false, inFront: true, at: now.addingTimeInterval(0.5)), .keepWaiting)
        XCTAssertEqual(wait.next(connected: false, inFront: true, at: now.addingTimeInterval(1)), .stop)
    }

    func testTheTimeInLocalDevVPNDoesNotCount() {
        // The player allows LocalDevVPN's configuration, the first time, for
        // as long as they take: Cartouche, suspended, looks again once back.
        var wait = CartoucheVPNConnect.Wait(started: now)
        XCTAssertEqual(wait.next(connected: false, inFront: false, at: now.addingTimeInterval(0.5)), .keepWaiting)
        XCTAssertEqual(wait.next(connected: false, inFront: false, at: now.addingTimeInterval(90)), .keepWaiting)
        XCTAssertEqual(wait.next(connected: false, inFront: true, at: now.addingTimeInterval(300)), .keepWaiting)
        XCTAssertLessThanOrEqual(wait.waited, CartoucheVPNConnect.tick)
        XCTAssertEqual(wait.next(connected: true, inFront: true, at: now.addingTimeInterval(301)), .goOn)
    }

    func testAClockThatGoesBackStillEndsTheWait() {
        var wait = CartoucheVPNConnect.Wait(started: now)
        XCTAssertEqual(wait.next(connected: false, inFront: true, at: now.addingTimeInterval(-3_600)), .keepWaiting)
        var time = now.addingTimeInterval(-3_600)
        var next = CartoucheVPNConnect.Wait.Next.keepWaiting
        var looks = 0
        while next == .keepWaiting && looks < 1_000 {
            time = time.addingTimeInterval(0.5)
            next = wait.next(connected: false, inFront: true, at: time)
            looks += 1
        }
        // It stops after its time in front all the same.
        XCTAssertEqual(next, .stop)
        XCTAssertLessThan(looks, 100)
    }
}
