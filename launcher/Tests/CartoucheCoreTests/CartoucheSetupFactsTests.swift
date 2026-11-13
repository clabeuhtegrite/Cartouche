//
//  CartoucheSetupFactsTests.swift
//  CartoucheCoreTests
//
//  What the measurements say of the installation when Cartouche starts, and
//  where the sign-in with the player's Apple ID stands
//  (Sources/CartoucheSetupFacts.swift).
//

import XCTest
@testable import CartoucheCore

final class CartoucheSetupFactsTests: XCTestCase {
    private func facts(certificate: Bool = true, works: Bool?, pairing: Bool = true,
                       signedIn: Bool = true) -> CartoucheSetupFacts {
        CartoucheSetupFacts(hasCertificate: certificate, certificateWorks: works, hasPairingFile: pairing, signedIn: signedIn)
    }

    /// app.opened waits for the check of the certificate, which ends a few
    /// seconds after the launch: before it, no installation is ready.
    func testTheCheckOfTheCertificateEndsWithItsAnswer() {
        XCTAssertFalse(facts(works: nil).isChecked)
        XCTAssertTrue(facts(works: true).isChecked)
        XCTAssertTrue(facts(works: false).isChecked)
        // Without a certificate, there is nothing to wait for.
        XCTAssertTrue(facts(certificate: false, works: nil).isChecked)
        XCTAssertFalse(CartoucheSetupFacts.isChecked(hasCertificate: true, certificateWorks: nil))
    }

    func testSaysWhereTheCertificateStands() {
        XCTAssertEqual(facts(certificate: false, works: nil).certificate, "none")
        XCTAssertEqual(facts(works: nil).certificate, "checking")
        XCTAssertEqual(facts(works: true).certificate, "works")
        XCTAssertEqual(facts(works: false).certificate, "refused")
    }

    /// Whether there is an Apple ID, never which.
    func testSendsWhatTheInstallationIsMadeOf() {
        XCTAssertEqual(facts(works: true, pairing: false, signedIn: true).fields,
                       ["certificate": .text("works"), "pairing": .flag(false), "signedIn": .flag(true)])
        XCTAssertEqual(facts(certificate: false, works: nil, pairing: true, signedIn: false).fields,
                       ["certificate": .text("none"), "pairing": .flag(true), "signedIn": .flag(false)])
    }

    // MARK: The sign-in

    /// A player on Reddit, November 12: "Signed in" under the Apple ID, and
    /// the certificate still to come, however many times they installed
    /// Cartouche again. The built-in SideStore keeps the Apple ID once Apple
    /// has accepted the account, before the team's and the certificate's
    /// steps: a sign-in that stopped there is not done.
    func testASignInThatStoppedBeforeTheCertificateIsNotDone() {
        XCTAssertEqual(facts(certificate: false, works: nil, signedIn: true).signInStep, .unfinished)
        XCTAssertEqual(facts(works: true).signInStep, .done)
        XCTAssertEqual(facts(works: nil).signInStep, .done)
        // A certificate iOS refuses is the certificate's step.
        XCTAssertEqual(facts(works: false).signInStep, .done)
        XCTAssertEqual(facts(certificate: false, works: nil, signedIn: false).signInStep, .notSignedIn)
        // A certificate LiveContainer had before, without an Apple ID.
        XCTAssertEqual(facts(works: true, signedIn: false).signInStep, .notSignedIn)
    }

    private let here = "7A1B4C2D-0E3F-4A5B-8C6D-9E0F1A2B3C4D"
    private let before = "0F1E2D3C-4B5A-4968-8776-A5B4C3D2E1F0"
    /// November 12, 2026, at noon, UTC.
    private let noon = Date(timeIntervalSince1970: 1_794_484_800)

    /// Installed again over this copy, as the setup told the player:
    /// Cartouche signs in again by itself, with the Apple ID and password
    /// SideStore keeps, once in this installation.
    func testCartoucheSignsInAgainByItselfOncePerInstallation() {
        func again(_ last: CartoucheLastSignIn?, step: CartoucheSignInStep = .unfinished,
                   pairing: Bool = true, vpn: Bool = true) -> Bool {
            CartoucheLastSignIn.signsInAgain(after: last, at: step, installation: here, hasPairingFile: pairing, vpnConnected: vpn)
        }
        let earlier = CartoucheLastSignIn(installation: before, started: noon.addingTimeInterval(-86_400))
        let now = CartoucheLastSignIn(installation: here, started: noon)
        XCTAssertTrue(again(earlier))
        // From a version that kept no sign-in: up to 0.11.2.
        XCTAssertTrue(again(nil))
        // Signed in in this installation already, by the player or by
        // itself: the player signs in again, told why it stopped.
        XCTAssertFalse(again(now))
        // The sign-in needs the pairing file and LocalDevVPN: Cartouche
        // tries again once they are there.
        XCTAssertFalse(again(earlier, vpn: false))
        XCTAssertFalse(again(earlier, pairing: false))
        XCTAssertFalse(again(earlier, step: .notSignedIn))
        XCTAssertFalse(again(earlier, step: .done))
    }

    /// iOS puts each install of an app in a folder of its own.
    func testAnInstallationIsTheFolderOfItsBundle() {
        let bundle = URL(fileURLWithPath: "/private/var/containers/Bundle/Application/\(here)/Cartouche.app", isDirectory: true)
        XCTAssertEqual(CartoucheLastSignIn.installation(of: bundle), here)
        let again = URL(fileURLWithPath: "/private/var/containers/Bundle/Application/\(before)/Cartouche.app/")
        XCTAssertEqual(CartoucheLastSignIn.installation(of: again), before)
    }

    private let environment = CartoucheReport.Environment(
        cartouche: "0.11.2 (ab12cd3)", basedOn: "LiveContainer 3.8.11, SideStore 0.7.0", system: "27.1 (25B72)",
        device: "iPhone18,2 (A19 Pro, 12 GB)", language: "en (en-US)", facts: [])

    private func report(_ origin: CartoucheReport.Origin, _ message: String, at minutes: TimeInterval) -> CartoucheReport {
        CartoucheReport(origin: origin, title: "Failed", message: message, date: noon.addingTimeInterval(minutes * 60),
                        environment: environment)
    }

    /// The setup says why the sign-in stopped, once its screen has gone, and
    /// after Cartouche was installed again over this copy, which keeps its
    /// reports.
    func testTheSetupFindsWhyTheSignInStopped() {
        let certificate = report(.signIn, "This Apple account already has a certificate.", at: 0)
        let reports = [report(.install, "The game was not installed.", at: 90), certificate,
                       report(.signIn, "Apple refused the verification code.", at: -150)]
        XCTAssertEqual(CartoucheLastSignIn.report(after: nil, among: reports), certificate)
        let started = CartoucheLastSignIn(installation: here, started: noon.addingTimeInterval(-40))
        XCTAssertEqual(CartoucheLastSignIn.report(after: started, among: reports), certificate)
        // A sign-in that started since ended without a report: it went
        // through, or it is still going.
        let since = CartoucheLastSignIn(installation: here, started: noon.addingTimeInterval(120))
        XCTAssertNil(CartoucheLastSignIn.report(after: since, among: reports))
        XCTAssertNil(CartoucheLastSignIn.report(after: nil, among: [reports[0]]))
    }

    /// Kept across launches, as JSON.
    func testTheLastSignInIsKept() throws {
        let last = CartoucheLastSignIn(installation: here, started: noon)
        XCTAssertEqual(try JSONDecoder().decode(CartoucheLastSignIn.self, from: JSONEncoder().encode(last)), last)
    }
}
