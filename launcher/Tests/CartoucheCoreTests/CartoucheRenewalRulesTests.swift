//
//  CartoucheRenewalRulesTests.swift
//  CartoucheCoreTests
//
//  When Cartouche renews itself as it comes to the front, and what renewed
//  a signature that lasts longer (Sources/CartoucheRenewalRules.swift).
//

import XCTest
@testable import CartoucheCore

final class CartoucheRenewalRulesTests: XCTestCase {
    private let now = Date(timeIntervalSinceReferenceDate: 800_000_000)

    /// A copy signed in with a free Apple account, set up, LocalDevVPN on,
    /// SideStore idle and no game running, with DAYS LEFT.
    private func situation(daysLeft: Int? = 2, canRenew: Bool = true, isSetUp: Bool = true, vpn: Bool = true,
                           busy: Bool = false, paused: Bool = false, playing: Bool = false,
                           lastTry: Date? = nil) -> CartoucheAutomaticRenewal.Situation {
        CartoucheAutomaticRenewal.Situation(daysLeft: daysLeft, canRenew: canRenew, isSetUp: isSetUp, vpnConnected: vpn,
                                            sideStoreBusy: busy, signInsPaused: paused, gameRunning: playing,
                                            lastTry: lastTry)
    }

    private func wait(_ situation: CartoucheAutomaticRenewal.Situation) -> CartoucheAutomaticRenewal.Wait? {
        CartoucheAutomaticRenewal.wait(situation, at: now)
    }

    // MARK: When Cartouche renews itself

    /// The measurements of November 13: 87 copies signed for seven days,
    /// 27 of them expiring on November 17, and nothing but Renew now and an
    /// automation of the player's renewing them, while the System page said
    /// that Cartouche renewed itself with LocalDevVPN on.
    func testRenewsItselfInTheLastThreeDaysWithLocalDevVPNOn() {
        for days in [3, 2, 1, 0] {
            XCTAssertNil(wait(situation(daysLeft: days)), "\(days) days left")
            XCTAssertTrue(CartoucheAutomaticRenewal.isDue(situation(daysLeft: days), at: now))
        }
        // As the home's top bar shows the days left.
        XCTAssertEqual(CartoucheAutomaticRenewal.days, 3)
    }

    func testLeavesASignatureThatHasMoreDaysAlone() {
        for days in [4, 6, 7, 363] {
            XCTAssertEqual(wait(situation(daysLeft: days)), .notDue, "\(days) days left")
        }
        // A signature Cartouche could not read: nothing tells it is due.
        XCTAssertEqual(wait(situation(daysLeft: nil)), .notDue)
    }

    /// Cartouche opens once its signature has expired only when it read an
    /// older date than the one iOS holds: renewing then does no harm.
    func testAnExpiredSignatureIsDueToo() {
        XCTAssertNil(wait(situation(daysLeft: -1)))
    }

    /// The player's own certificate signs Cartouche with no Apple ID: they
    /// install it again from their computer.
    func testNeverWithThePlayersOwnCertificate() {
        XCTAssertEqual(wait(situation(canRenew: false)), .cannotRenew)
    }

    /// Not signed in, no pairing file, a certificate iOS refuses or still
    /// being checked, this iPhone left to register: SideStore would only
    /// fail, as Renew now did 4 times on 3 copies not signed in, in 0.11.1
    /// and 0.11.2.
    func testWaitsForTheSetup() {
        XCTAssertEqual(wait(situation(isSetUp: false)), .setup)
    }

    /// SideStore reaches the iPhone through LocalDevVPN: 9 renewals of
    /// 0.11.2 did not reach it. Cartouche tries again when it comes back,
    /// as when the player turned it on, and counts no try meanwhile.
    func testWaitsForLocalDevVPN() {
        XCTAssertEqual(wait(situation(vpn: false)), .vpn)
        XCTAssertNil(wait(situation(vpn: true)))
    }

    /// SideStore takes one action at a time: another, started meanwhile,
    /// fails with "Another refresh task is in progress".
    func testNeverWhileSideStoreIsAtSomethingElse() {
        XCTAssertEqual(wait(situation(busy: true)), .sideStoreBusy)
    }

    /// SideStore would start in a process of its own beside the game's.
    func testNeverWhileAGameRunsBehindTheConsole() {
        XCTAssertEqual(wait(situation(playing: true)), .gameRunning)
    }

    func testNeverWhileApplesLimitOnSignInsHolds() {
        XCTAssertEqual(wait(situation(paused: true)), .signInsPaused)
    }

    /// Each renewal asks Apple for the profiles: one that failed waits six
    /// hours before the next, whatever the player does meanwhile.
    func testTriesAgainSixHoursAfterTheLastTry() {
        XCTAssertEqual(wait(situation(lastTry: now.addingTimeInterval(-60))), .triedLately)
        XCTAssertEqual(wait(situation(lastTry: now.addingTimeInterval(-6 * 3_600 + 1))), .triedLately)
        XCTAssertNil(wait(situation(lastTry: now.addingTimeInterval(-6 * 3_600))))
        XCTAssertNil(wait(situation(lastTry: now.addingTimeInterval(-3 * 86_400))))
        // A try that LocalDevVPN would have failed was never made.
        XCTAssertEqual(wait(situation(vpn: false, lastTry: now.addingTimeInterval(-7 * 3_600))), .vpn)
    }

    /// The iPhone's clock went back: a try dated later holds nothing back.
    func testATryDatedLaterThanNowHoldsNothingBack() {
        XCTAssertNil(wait(situation(lastTry: now.addingTimeInterval(3_600))))
    }

    // MARK: What renewed the signature

    /// signature.renewed, up to 0.12.0: 24 of 51 were updates, and the
    /// others could be Renew now, the automation of Shortcuts or the
    /// Cartouche Installer alike.
    func testAnUpdateComesFirst() {
        XCTAssertEqual(CartoucheRenewalVia.of(updated: true, reinstalled: true, renewedHere: true), .update)
        XCTAssertEqual(CartoucheRenewalVia.of(updated: true, reinstalled: nil, renewedHere: false), .update)
    }

    func testTheSameVersionInstalledAgainIsAReinstall() {
        XCTAssertEqual(CartoucheRenewalVia.of(updated: false, reinstalled: true, renewedHere: false), .reinstall)
        XCTAssertEqual(CartoucheRenewalVia.of(updated: false, reinstalled: true, renewedHere: true), .reinstall)
    }

    func testARenewalOfCartouchesOwn() {
        XCTAssertEqual(CartoucheRenewalVia.of(updated: false, reinstalled: false, renewedHere: true), .cartouche)
        XCTAssertEqual(CartoucheRenewalVia.of(updated: false, reinstalled: nil, renewedHere: true), .cartouche)
    }

    /// Neither an install nor Cartouche itself: the Refresh All Apps action,
    /// as the automation of Shortcuts runs it.
    func testWhatRenewedItWhileCartoucheWasClosedIsOutside() {
        XCTAssertEqual(CartoucheRenewalVia.of(updated: false, reinstalled: false, renewedHere: false), .outside)
    }

    /// The first start of a version that notes its installation cannot tell
    /// a reinstall from the rest.
    func testWithoutTheInstallationBeforeItCannotTell() {
        XCTAssertNil(CartoucheRenewalVia.of(updated: false, reinstalled: nil, renewedHere: false))
    }

    func testSendsShortNames() {
        XCTAssertEqual(CartoucheRenewalVia.update.rawValue, "update")
        XCTAssertEqual(CartoucheRenewalVia.reinstall.rawValue, "reinstall")
        XCTAssertEqual(CartoucheRenewalVia.cartouche.rawValue, "cartouche")
        XCTAssertEqual(CartoucheRenewalVia.outside.rawValue, "outside")
    }
}
