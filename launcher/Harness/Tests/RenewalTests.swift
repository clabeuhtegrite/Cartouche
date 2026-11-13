//
//  RenewalTests.swift
//  CartoucheHarnessTests
//
//  Cartouche renewing itself as it comes to the front in the last days of
//  its signature, and Renew now (CartoucheRenewals in CartoucheRenewal.swift,
//  CartoucheRenewalRules.swift), through the built-in SideStore's renewal
//  as the harness stands it in (HarnessSideStore.swift); SideStore's other
//  actions, which wait for a renewal under way, three minutes at most; and
//  what the measurements say of a renewal.
//

import SwiftUI
import UIKit
import XCTest
@testable import CartoucheHarness

final class RenewalTests: HarnessCase {
    private var renewals: CartoucheRenewals { CartoucheRenewals.shared }
    private var setup: CartoucheSetup { CartoucheSetup.shared }
    private var telemetry: CartoucheTelemetry { CartoucheTelemetry.shared }

    /// A screen of Cartouche's, in a window of its own: see showScreen().
    private var screen: UIWindow?

    override func tearDown() async throws {
        screen?.isHidden = true
        screen?.rootViewController = nil
        screen = nil
        // Nothing left under way for the test after.
        HarnessLC.endHeldRenewal()
        try await waitUntil("no renewal is under way") { !self.renewals.isRenewing }
        try await super.tearDown()
    }

    /// Cartouche as a player who signed in leaves it: SideStore's Apple ID,
    /// the pairing file where SideStore reads it, and the certificate,
    /// checked.
    private func setUpCartouche(file: StaticString = #filePath, line: UInt = #line) async throws {
        XCTAssertTrue(CartoucheStoreKeychain.set(Data("player@example.com".utf8), for: "appleIDEmailAddress"),
                      "the keychain works in the harness", file: file, line: line)
        try FileManager.default.createDirectory(at: CartouchePairing.storeDocuments, withIntermediateDirectories: true)
        try Data("pairing".utf8).write(to: CartouchePairing.storeDocuments.appendingPathComponent(CartouchePairing.importName))
        setup.refresh()
        try await waitUntil("Cartouche is set up", file: file, line: line) { self.setup.isComplete }
    }

    private func renewalEnds(file: StaticString = #filePath, line: UInt = #line) async throws {
        try await waitUntil("the renewal ended", file: file, line: line) { !self.renewals.isRenewing }
    }

    /// Shows a screen of Cartouche's as the games page, the guide and the
    /// setup are: it reads the setup as it appears and each time Cartouche
    /// comes back to the front (CartoucheSetupRefresh), and Cartouche then
    /// renews itself when it is due. Under the console's window.
    private func showScreen(file: StaticString = #filePath, line: UInt = #line) throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.lazy.compactMap { $0 as? UIWindowScene }.first,
                                  "the harness's scene", file: file, line: line)
        let window = UIWindow(windowScene: scene)
        window.windowLevel = UIWindow.Level(rawValue: UIWindow.Level.normal.rawValue - 1)
        window.rootViewController = UIHostingController(rootView: Color.clear.modifier(CartoucheSetupRefresh()))
        window.isHidden = false
        screen = window
    }

    /// Cartouche comes back to the front, as iOS tells it.
    private func comeBack() {
        NotificationCenter.default.post(name: UIApplication.didBecomeActiveNotification, object: nil)
    }

    // MARK: By itself

    /// The System page said that Cartouche renewed itself with LocalDevVPN
    /// on, and up to 0.12.0 it never did: of 87 copies signed for seven
    /// days on November 13, 27 expired on November 17, and only Renew now,
    /// an automation the player made in Shortcuts, or an update, renewed
    /// any.
    func testCartoucheRenewsItselfInItsLastThreeDays() async throws {
        try await setUpCartouche()
        HarnessSideStore.record(expiringIn: 2.5)
        XCTAssertEqual(CartoucheSignature.current().daysLeft, 2)

        renewals.renewIfDue()
        XCTAssertTrue(renewals.isRenewing, "at once")
        XCTAssertTrue(renewals.isAutomatic)
        XCTAssertFalse(renewals.canRenewNow, "the System page shows it under way")
        try await waitUntil("SideStore is asked to renew Cartouche") { HarnessLC.renewals.count == 1 }
        try await renewalEnds()
        XCTAssertNil(renewals.report)
        XCTAssertFalse(renewals.isAutomatic)
        XCTAssertEqual(CartoucheSignature.current().daysLeft, 6)

        // Renewed: nothing more each time it comes back.
        renewals.renewIfDue()
        XCTAssertFalse(renewals.isRenewing)
        try await pause(0.3)
        XCTAssertEqual(HarnessLC.renewals.count, 1)
    }

    func testASignatureWithMoreDaysLeftIsLeftAlone() async throws {
        try await setUpCartouche()
        HarnessSideStore.record(expiringIn: 4.5)
        renewals.renewIfDue()
        XCTAssertFalse(renewals.isRenewing)
        try await pause(0.3)
        XCTAssertTrue(HarnessLC.renewals.isEmpty)
    }

    /// Up to 0.12.0, Renew now went to SideStore on copies not signed in,
    /// which failed.
    func testNothingBeforeTheSetupIsDone() async throws {
        HarnessSideStore.record(expiringIn: 1.5)
        setup.refresh()
        try await waitUntil("Cartouche knows whether the certificate works") { self.setup.certificateWorks != nil }
        XCTAssertFalse(setup.isComplete, "no Apple ID, no pairing file")

        renewals.renewIfDue()
        XCTAssertFalse(renewals.isRenewing)
        XCTAssertFalse(renewals.canRenewNow, "nor from the System page")
        renewals.renewNow()
        XCTAssertFalse(renewals.isRenewing)
        try await pause(0.3)
        XCTAssertTrue(HarnessLC.renewals.isEmpty)
    }

    /// SideStore reaches the iPhone through LocalDevVPN: without it,
    /// Cartouche counts no try, and renews itself as it comes back once the
    /// player has turned it on.
    func testWaitsForLocalDevVPN() async throws {
        try await setUpCartouche()
        HarnessSideStore.record(expiringIn: 1.5)
        HarnessLC.vpnConnected = false
        renewals.renewIfDue()
        XCTAssertFalse(renewals.isRenewing)

        HarnessLC.vpnConnected = true
        renewals.renewIfDue()
        XCTAssertTrue(renewals.isRenewing)
        try await renewalEnds()
        XCTAssertEqual(HarnessLC.renewals.count, 1)
    }

    /// A renewal that failed says why on the System page, with its report,
    /// and Cartouche tries again six hours later, not each time it comes
    /// back.
    func testAFailedRenewalSaysWhyAndWaitsSixHours() async throws {
        try await setUpCartouche()
        HarnessSideStore.record(expiringIn: 0.5)
        HarnessLC.renewal = .fails("Could not find the provisioning profile.")
        renewals.renewIfDue()
        try await renewalEnds()
        let report = try XCTUnwrap(renewals.report)
        XCTAssertEqual(report.origin, .renewal)
        XCTAssertEqual(report.failure?.details["automatic"], .flag(true))
        XCTAssertEqual(HarnessLC.renewals.count, 1)

        renewals.renewIfDue()
        XCTAssertFalse(renewals.isRenewing, "tried less than six hours ago")

        // Six hours later.
        UserDefaults.standard.set(Date().addingTimeInterval(-6 * 3_600 - 1), forKey: CartoucheRenewals.lastTryKey)
        HarnessLC.renewal = .renews(days: 7)
        renewals.renewIfDue()
        XCTAssertTrue(renewals.isRenewing)
        XCTAssertNil(renewals.report, "a new renewal clears it")
        try await renewalEnds()
        XCTAssertNil(renewals.report)
        XCTAssertEqual(HarnessLC.renewals.count, 2)
        XCTAssertEqual(CartoucheSignature.current().daysLeft, 6)
    }

    /// The same, as the player sees it: a renewal that failed as a screen
    /// of Cartouche's appeared is not tried again each time Cartouche comes
    /// back to the front, but six hours after the try, whose date Cartouche
    /// keeps across launches.
    func testARenewalThatFailedAtTheFrontIsNotTriedAgainForSixHours() async throws {
        try await setUpCartouche()
        HarnessSideStore.record(expiringIn: 1.5)
        HarnessLC.renewal = .fails("Could not find the provisioning profile.")
        try showScreen()
        try await waitUntil("Cartouche renewed itself as its screen appeared") { HarnessLC.renewals.count == 1 }
        try await renewalEnds()
        XCTAssertNotNil(renewals.report)
        let tried = try XCTUnwrap(UserDefaults.standard.object(forKey: CartoucheRenewals.lastTryKey) as? Date,
                                  "in Cartouche's defaults, kept across launches")
        XCTAssertLessThan(abs(tried.timeIntervalSinceNow), 60)

        for _ in 0..<5 {
            comeBack()
            try await pause(0.1)
        }
        try await pause(0.3)
        XCTAssertEqual(HarnessLC.renewals.count, 1, "not each time Cartouche comes back")
        XCTAssertFalse(renewals.isRenewing)
        XCTAssertNotNil(renewals.report, "the System page still says why")

        // A minute short of six hours after the try.
        UserDefaults.standard.set(Date().addingTimeInterval(-6 * 3_600 + 60), forKey: CartoucheRenewals.lastTryKey)
        comeBack()
        try await pause(0.3)
        XCTAssertEqual(HarnessLC.renewals.count, 1)

        // Six hours after it.
        UserDefaults.standard.set(Date().addingTimeInterval(-6 * 3_600 - 1), forKey: CartoucheRenewals.lastTryKey)
        HarnessLC.renewal = .renews(days: 7)
        comeBack()
        try await waitUntil("Cartouche tried again as it came back") { HarnessLC.renewals.count == 2 }
        try await renewalEnds()
        XCTAssertNil(renewals.report)
        XCTAssertEqual(CartoucheSignature.current().daysLeft, 6)
    }

    // MARK: Renew now

    func testRenewNowRenewsOnceAtATime() async throws {
        try await setUpCartouche()
        HarnessSideStore.record(expiringIn: 5.5)
        XCTAssertTrue(renewals.canRenewNow)

        renewals.renewNow()
        XCTAssertTrue(renewals.isRenewing)
        XCTAssertFalse(renewals.isAutomatic)
        XCTAssertFalse(renewals.canRenewNow)
        renewals.renewNow()
        try await renewalEnds()
        XCTAssertEqual(HarnessLC.renewals.count, 1)
        XCTAssertEqual(CartoucheSignature.current().daysLeft, 6)
        XCTAssertTrue(renewals.canRenewNow)
    }

    // MARK: SideStore's other actions

    /// SideStore takes one action at a time: an update, a sign-in or the
    /// registration of this iPhone that starts while Cartouche renews
    /// itself, as when an update is offered as Cartouche opens, waits for
    /// the renewal's end, instead of failing with "Another refresh task is
    /// in progress".
    func testSideStoresOtherActionsWaitForTheRenewalUnderWay() async throws {
        let ran = HarnessBox(false)
        renewals.afterRenewal("Harness") { ran.value = true }
        XCTAssertTrue(ran.value, "at once, without a renewal")

        try await setUpCartouche()
        HarnessSideStore.record(expiringIn: 1.5)
        HarnessLC.renewalTime = 1
        renewals.renewIfDue()
        XCTAssertTrue(renewals.isRenewing)
        ran.value = false
        let renewingAsItRan = HarnessBox(true)
        renewals.afterRenewal("Harness") {
            renewingAsItRan.value = self.renewals.isRenewing
            ran.value = true
        }
        XCTAssertFalse(ran.value)
        try await waitUntil("the action ran") { ran.value }
        XCTAssertFalse(renewingAsItRan.value, "once the renewal had ended")
        XCTAssertEqual(HarnessLC.renewals.count, 1)
    }

    /// A renewal that never ends, SideStore no longer answering, holds an
    /// update, a sign-in or the registration of this iPhone up for
    /// `waitLimit` at most: then the action goes on, and SideStore, still
    /// at the renewal, may refuse it and say so, rather than leave the
    /// player waiting for ever.
    func testSideStoresOtherActionsWaitOnlySoLongForARenewalThatNeverEnds() async throws {
        XCTAssertEqual(renewals.waitLimit, 180, "three minutes, when the longest renewal measured took 71 seconds")
        let limit = renewals.waitLimit
        defer { renewals.waitLimit = limit }
        renewals.waitLimit = 1

        try await setUpCartouche()
        HarnessSideStore.record(expiringIn: 1.5)
        HarnessLC.renewal = .hangs
        renewals.renewIfDue()
        try await waitUntil("SideStore is asked to renew Cartouche") { HarnessLC.renewals.count == 1 }

        let ran = HarnessBox(false)
        let began = Date()
        renewals.afterRenewal("Harness") { ran.value = true }
        try await pause(0.5)
        XCTAssertFalse(ran.value, "it waits for the renewal first")
        try await waitUntil("the action went on", timeout: 5) { ran.value }
        XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(began), 1, "once the limit had passed")
        XCTAssertTrue(renewals.isRenewing, "the renewal had not ended")
        XCTAssertTrue(CartoucheReports.journal(last: 20).contains {
            $0.hasSuffix("Harness: the renewal under way has not ended after 1 s, going on")
        }, "the journal says why the action went on")

        // SideStore answers at last.
        HarnessLC.endHeldRenewal()
        try await renewalEnds()
        XCTAssertNil(renewals.report)
        XCTAssertEqual(CartoucheSignature.current().daysLeft, 6)
        XCTAssertEqual(HarnessLC.renewals.count, 1)
    }

    // MARK: What the measurements say

    /// Every report the server got, in order, as JSON.
    private var reports: [[String: Any]] {
        HarnessNetwork.requests.filter { $0.url.path == "/v1/reports" }.flatMap { request -> [[String: Any]] in
            let body = (try? JSONSerialization.jsonObject(with: request.body)) as? [String: Any]
            return body?["reports"] as? [[String: Any]] ?? []
        }
    }

    private func fields(of name: String, where matches: ([String: Any]) -> Bool = { _ in true }) -> [String: Any]? {
        reports
            .filter { $0["name"] as? String == name }
            .compactMap { $0["fields"] as? [String: Any] }
            .last(where: matches)
    }

    /// renewal.done says Cartouche renewed itself, and signature.renewed
    /// what renewed the signature: up to 0.12.0, the measurements could not
    /// tell the automation of Shortcuts from Renew now, from an update or
    /// from an install of the Cartouche Installer.
    func testTheMeasurementsSayCartoucheRenewedItself() async throws {
        HarnessNetwork.answer { request in
            request.url.host == "telemetry.harness.invalid" ? HarnessNetwork.Answer(status: 200) : nil
        }
        telemetry.setOn(false)
        telemetry.setOn(true)
        telemetry.start()
        try await setUpCartouche()
        HarnessSideStore.record(expiringIn: 2.5)
        // Cartouche reads its signature again as it comes back to the front.
        NotificationCenter.default.post(name: UIApplication.didBecomeActiveNotification, object: nil)

        renewals.renewIfDue()
        try await renewalEnds()
        try await waitUntil("the server has what renewed it") {
            self.fields(of: "signature.renewed") { $0["via"] as? String == "cartouche" } != nil
        }
        let done = try XCTUnwrap(fields(of: "renewal.done"))
        XCTAssertEqual(done["automatic"] as? Bool, true)
        let renewed = try XCTUnwrap(fields(of: "signature.renewed") { $0["via"] as? String == "cartouche" })
        XCTAssertEqual(renewed["daysLeft"] as? Double, 6)
    }
}
