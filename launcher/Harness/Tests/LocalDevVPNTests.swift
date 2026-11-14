//
//  LocalDevVPNTests.swift
//  CartoucheHarnessTests
//
//  Cartouche has LocalDevVPN connect by itself when what reaches the iPhone
//  through it starts with LocalDevVPN off (CartoucheLocalDevVPN, the rule in
//  CartoucheVPNConnect): Renew now, the renewal Cartouche starts by itself
//  in the last days of its signature, the sign-in, and the guide's button.
//  The harness's LocalDevVPN notes the URLs Cartouche opens, and connects a
//  moment after its own, as localdevvpn://enable does (HarnessLC.open); its
//  SideStore notes whether LocalDevVPN was connected each time Cartouche
//  asked it to renew (HarnessLC.vpnAtRenewals). Up to 0.12.1, the player
//  connected LocalDevVPN in its app before each of them, and came back.
//

import XCTest
@testable import CartoucheHarness

final class LocalDevVPNTests: HarnessCase {
    private var renewals: CartoucheRenewals { CartoucheRenewals.shared }
    private var localDevVPN: CartoucheLocalDevVPN { CartoucheLocalDevVPN.shared }
    /// LocalDevVPN's URL that connects it, then opens Cartouche again.
    private let enable = URL(string: "localdevvpn://enable?scheme=cartouche")!

    override func tearDown() async throws {
        localDevVPN.waitLimit = CartoucheVPNConnect.timeout
        CartoucheAccount.shared.stopWaiting()
        HarnessLC.endHeldRenewal()
        try await waitUntil("no renewal is under way") { !self.renewals.isRenewing }
        try await super.tearDown()
    }

    private func renewalEnds(timeout: TimeInterval = 20, file: StaticString = #filePath, line: UInt = #line) async throws {
        try await waitUntil("the renewal ended", timeout: timeout, file: file, line: line) { !self.renewals.isRenewing }
    }

    private func localDevVPNOpened(_ count: Int = 1, file: StaticString = #filePath, line: UInt = #line) async throws {
        try await waitUntil("Cartouche opened LocalDevVPN", file: file, line: line) { HarnessLC.openedURLs.count == count }
    }

    // MARK: Renew now

    /// Up to 0.12.1, Renew now with LocalDevVPN off went to SideStore, which
    /// could not reach the iPhone: the player connected LocalDevVPN in its
    /// app, came back, and renewed again.
    func testRenewNowHasLocalDevVPNConnectFirst() async throws {
        try await setUpCartouche()
        HarnessSideStore.record(expiringIn: 5.5)
        HarnessLC.vpnConnected = false

        renewals.renewNow()
        XCTAssertTrue(renewals.isRenewing, "the System page shows it under way")
        try await localDevVPNOpened()
        XCTAssertEqual(HarnessLC.openedURLs, [enable])
        try await renewalEnds()
        XCTAssertEqual(HarnessLC.vpnAtRenewals, [true], "SideStore was asked once LocalDevVPN was connected")
        XCTAssertNil(renewals.report)
        XCTAssertEqual(CartoucheSignature.current().daysLeft, 6)
        XCTAssertNil(UserDefaults.standard.object(forKey: CartoucheLocalDevVPN.lastAutomaticOpenKey),
                     "the player asked: Cartouche may open it by itself all the same")
    }

    func testLocalDevVPNConnectedOpensNothing() async throws {
        try await setUpCartouche()
        HarnessSideStore.record(expiringIn: 5.5)
        renewals.renewNow()
        try await renewalEnds()
        XCTAssertEqual(HarnessLC.openedURLs, [])
        XCTAssertEqual(HarnessLC.vpnAtRenewals, [true])
    }

    /// A LocalDevVPN set to addresses of its own carries SideStore's traffic
    /// all the same, though Cartouche does not see its tunnel: Cartouche
    /// goes on after its limit, as up to 0.12.1, and SideStore says why
    /// should it not reach the iPhone.
    func testGoesOnAfterItsLimitWithoutTheTunnel() async throws {
        localDevVPN.waitLimit = 1
        try await setUpCartouche()
        HarnessSideStore.record(expiringIn: 5.5)
        HarnessLC.vpnConnected = false
        HarnessLC.localDevVPNConnects = false

        let began = Date()
        renewals.renewNow()
        try await waitUntil("SideStore is asked to renew Cartouche", timeout: 5) { HarnessLC.renewals.count == 1 }
        XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(began), 1, "once the limit had passed")
        XCTAssertEqual(HarnessLC.openedURLs, [enable])
        XCTAssertEqual(HarnessLC.vpnAtRenewals, [false])
        try await renewalEnds()
        XCTAssertTrue(CartoucheReports.journal(last: 20).contains {
            $0.hasSuffix("Renewal: LocalDevVPN did not connect in time, going on")
        }, "the journal says why the renewal went on")
    }

    /// The time the player spends in LocalDevVPN does not count, as the
    /// first time, when iOS asks them to allow its VPN configuration.
    func testTheTimeInLocalDevVPNDoesNotCount() async throws {
        localDevVPN.waitLimit = 1
        try await setUpCartouche()
        HarnessSideStore.record(expiringIn: 5.5)
        HarnessLC.vpnConnected = false
        HarnessLC.localDevVPNConnects = false

        renewals.renewNow()
        try await localDevVPNOpened()
        // LocalDevVPN in front.
        HarnessLC.cartoucheInFront = false
        try await pause(2)
        XCTAssertTrue(HarnessLC.renewals.isEmpty, "Cartouche still waits for LocalDevVPN")

        // The player allowed it: LocalDevVPN connects, and opens Cartouche again.
        HarnessLC.vpnConnected = true
        HarnessLC.cartoucheInFront = true
        try await waitUntil("SideStore is asked to renew Cartouche") { HarnessLC.renewals.count == 1 }
        XCTAssertEqual(HarnessLC.vpnAtRenewals, [true])
        try await renewalEnds()
        XCTAssertNil(renewals.report)
    }

    // MARK: By itself

    /// In the last days of its signature, Cartouche renewed itself only
    /// once the player had connected LocalDevVPN, which the measurements of
    /// the week of November 10 showed off on most copies.
    func testCartoucheRenewsItselfAfterHavingLocalDevVPNConnect() async throws {
        try await setUpCartouche()
        HarnessSideStore.record(expiringIn: 1.5)
        HarnessLC.vpnConnected = false

        renewals.renewIfDue()
        XCTAssertTrue(renewals.isRenewing)
        XCTAssertTrue(renewals.isAutomatic)
        try await localDevVPNOpened()
        XCTAssertEqual(HarnessLC.openedURLs, [enable])
        try await renewalEnds()
        XCTAssertEqual(HarnessLC.vpnAtRenewals, [true])
        XCTAssertNil(renewals.report)
        XCTAssertEqual(CartoucheSignature.current().daysLeft, 6)
        let opened = try XCTUnwrap(UserDefaults.standard.object(forKey: CartoucheLocalDevVPN.lastAutomaticOpenKey) as? Date,
                                   "kept across launches")
        XCTAssertLessThan(abs(opened.timeIntervalSinceNow), 60)
    }

    /// Cartouche opens LocalDevVPN by itself only from the front: not while
    /// it is in the background, nor without LocalDevVPN on the iPhone. It
    /// then counts no try, and renews itself once LocalDevVPN is connected.
    func testNothingOpensFromTheBackground() async throws {
        try await setUpCartouche()
        HarnessSideStore.record(expiringIn: 1.5)
        HarnessLC.vpnConnected = false
        HarnessLC.cartoucheInFront = false

        renewals.renewIfDue()
        XCTAssertFalse(renewals.isRenewing)
        try await pause(0.5)
        XCTAssertEqual(HarnessLC.openedURLs, [])
        XCTAssertNil(UserDefaults.standard.object(forKey: CartoucheRenewals.lastTryKey), "no try counted")

        HarnessLC.cartoucheInFront = true
        HarnessLC.vpnConnected = true
        renewals.renewIfDue()
        XCTAssertTrue(renewals.isRenewing)
        try await renewalEnds()
        XCTAssertEqual(HarnessLC.openedURLs, [])
        XCTAssertEqual(HarnessLC.vpnAtRenewals, [true])
    }

    /// A LocalDevVPN that does not connect: Cartouche does not open it by
    /// itself each time it comes back, which would take the player out of
    /// Cartouche each time, but six hours later at the earliest.
    func testCartoucheOpensItByItselfOnceInSixHours() async throws {
        localDevVPN.waitLimit = 1
        try await setUpCartouche()
        HarnessSideStore.record(expiringIn: 1.5)
        HarnessLC.vpnConnected = false
        HarnessLC.localDevVPNConnects = false
        HarnessLC.renewal = .fails("Could not connect to the device.")

        renewals.renewIfDue()
        try await renewalEnds(timeout: 5)
        XCTAssertEqual(HarnessLC.openedURLs, [enable])
        let report = try XCTUnwrap(renewals.report)
        XCTAssertEqual(report.failure?.details["automatic"], .flag(true))
        XCTAssertEqual(report.failure?.details["vpnOpened"], .flag(true), "the measurements say Cartouche opened it")

        for _ in 0..<3 {
            renewals.renewIfDue()
        }
        try await pause(0.5)
        XCTAssertFalse(renewals.isRenewing)
        XCTAssertEqual(HarnessLC.openedURLs.count, 1, "not each time Cartouche comes back")

        // Six hours later, LocalDevVPN connects.
        let sixHoursAgo = Date().addingTimeInterval(-6 * 3_600 - 1)
        UserDefaults.standard.set(sixHoursAgo, forKey: CartoucheRenewals.lastTryKey)
        UserDefaults.standard.set(sixHoursAgo, forKey: CartoucheLocalDevVPN.lastAutomaticOpenKey)
        HarnessLC.localDevVPNConnects = true
        HarnessLC.renewal = .renews(days: 7)
        renewals.renewIfDue()
        try await localDevVPNOpened(2)
        try await renewalEnds()
        XCTAssertEqual(HarnessLC.vpnAtRenewals, [false, true])
        XCTAssertNil(renewals.report)
        XCTAssertEqual(CartoucheSignature.current().daysLeft, 6)
    }

    // MARK: The sign-in

    /// The sign-in waited for the player to connect LocalDevVPN, which
    /// SideStore needs to register this iPhone: Cartouche has it connect
    /// at once, and goes on as soon as it is.
    func testTheSignInHasLocalDevVPNConnect() async throws {
        let account = CartoucheAccount.shared
        HarnessLC.vpnConnected = false
        HarnessLC.localDevVPNConnects = false

        account.signIn(appleID: "player@example.com", password: "password")
        XCTAssertTrue(account.isWaitingForVPN, "it waits for LocalDevVPN, as up to 0.12.1")
        XCTAssertEqual(HarnessLC.openedURLs, [enable], "and has it connect at once")
        account.stopWaiting()
        XCTAssertFalse(account.isWaitingForVPN)
        XCTAssertNil(UserDefaults.standard.object(forKey: CartoucheLocalDevVPN.lastAutomaticOpenKey))
    }

    // MARK: The guide's button

    func testTheButtonOpensTheAppStoreWithoutLocalDevVPN() {
        HarnessLC.vpnConnected = false
        HarnessLC.localDevVPNInstalled = false
        CartoucheGuide.shared.connectVPN()
        XCTAssertEqual(HarnessLC.openedURLs, [CartoucheLocalDevVPN.appStore])

        HarnessLC.localDevVPNInstalled = true
        CartoucheGuide.shared.connectVPN()
        XCTAssertEqual(HarnessLC.openedURLs, [CartoucheLocalDevVPN.appStore, enable])
    }
}
