//
//  RenewalTests.swift
//  CartoucheHarnessTests
//
//  Cartouche renewing itself as it comes to the front in the last days of
//  its signature, and Renew now (CartoucheRenewals in CartoucheRenewal.swift,
//  CartoucheRenewalRules.swift), through the built-in SideStore's renewal
//  as the harness stands it in (HarnessSideStore.swift); SideStore's other
//  actions, which wait for a renewal under way; and what the measurements
//  say of a renewal.
//

import UIKit
import XCTest
@testable import CartoucheHarness

final class RenewalTests: HarnessCase {
    private var renewals: CartoucheRenewals { CartoucheRenewals.shared }
    private var setup: CartoucheSetup { CartoucheSetup.shared }
    private var telemetry: CartoucheTelemetry { CartoucheTelemetry.shared }

    override func tearDown() async throws {
        // Nothing left under way for the test after.
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
