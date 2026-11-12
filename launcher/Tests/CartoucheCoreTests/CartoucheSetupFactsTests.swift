//
//  CartoucheSetupFactsTests.swift
//  CartoucheCoreTests
//
//  What the measurements say of the installation when Cartouche starts
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
}
