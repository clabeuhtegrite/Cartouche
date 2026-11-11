//
//  CartoucheFailureTests.swift
//  CartoucheCoreTests
//
//  Why something failed, as the measurements send it: the cause, the step,
//  the error's names and numbers, never its words.
//

import Foundation
import XCTest
@testable import CartoucheCore

final class CartoucheFailureTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_794_000_000)

    private func outcome(_ fields: [String: Any], action: CartoucheSideStoreOutcome.Action = .signIn,
                         maximumAge: TimeInterval = 3_600) -> CartoucheSideStoreOutcome? {
        var written: [String: Any] = ["version": 1, "action": action.rawValue, "ok": false, "date": 1_794_000_000 - 30]
        written.merge(fields) { _, new in new }
        let data = try! JSONSerialization.data(withJSONObject: written)
        return CartoucheSideStoreOutcome(data: data, expecting: action, now: now, maximumAge: maximumAge)
    }

    // MARK: What SideStore leaves

    func testReadsWhatSideStoreLeaves() throws {
        let read = try XCTUnwrap(outcome([
            "seconds": 12, "percent": 50, "stage": "device", "trail": "SignIn", "family": "minimuxer", "kind": "noVPN",
            "codes": "Minimuxer.MinimuxerError 3", "codeAsked": true, "codeMode": "trustedDevice",
            "certificates": 1, "bundledCertificate": true, "activeCertificate": false,
        ]))
        XCTAssertFalse(read.ok)
        XCTAssertEqual(read.seconds, 12)
        XCTAssertEqual(read.percent, 50)
        XCTAssertEqual(read.stage, "device")
        XCTAssertEqual(read.kind, "noVPN")
        XCTAssertEqual(read.codes, "Minimuxer.MinimuxerError 3")
        XCTAssertEqual(read.cause, .vpn)
        XCTAssertEqual(read.facts, [
            "codeAsked": .flag(true), "codeMode": .text("trustedDevice"), "certificates": .number(1),
            "bundledCertificate": .flag(true), "activeCertificate": .flag(false),
        ])
    }

    func testKeepsNoWordsNorAddresses() throws {
        let read = try XCTUnwrap(outcome([
            "stage": "Signing in as someone@example.com", "kind": "wrong password for Ad", "family": "portal",
            "codes": "SideSign.DeveloperPortalError 2 (Your Apple ID or password is incorrect)",
            "host": "192.168.1.2", "trail": "SignIn>/var/mobile/Containers", "codeMode": "+33 6 12 34 56 78",
            "teamType": "Ad's team", "unknownKey": "anything",
        ]))
        XCTAssertNil(read.stage)
        XCTAssertNil(read.kind)
        XCTAssertNil(read.codes)
        XCTAssertNil(read.host)
        XCTAssertNil(read.trail)
        XCTAssertEqual(read.facts, [:])
        XCTAssertEqual(read.family, "portal")
        XCTAssertEqual(read.cause, .appleRefused)
    }

    func testKeepsNumbersInTheirRanges() throws {
        let read = try XCTUnwrap(outcome(["percent": 250, "http": 42, "seconds": -3, "apple": -22406, "network": -1009,
                                          "certificates": true]))
        XCTAssertNil(read.percent)
        XCTAssertNil(read.http)
        XCTAssertNil(read.seconds)
        XCTAssertEqual(read.apple, -22406)
        XCTAssertEqual(read.network, -1009)
        XCTAssertNil(read.facts["certificates"])
    }

    func testTakesOnlyAFreshOutcomeOfTheActionAsked() {
        XCTAssertNotNil(outcome([:]))
        XCTAssertNil(outcome([:], maximumAge: 10))
        XCTAssertNil(outcome(["date": 1_794_000_000 + 3_600]))
        XCTAssertNil(outcome(["action": "refresh"]))
        XCTAssertNil(outcome(["version": "1"]))
        XCTAssertNil(outcome(["ok": 0]))
        XCTAssertNil(CartoucheSideStoreOutcome(data: Data("not json".utf8), expecting: .signIn, now: now))
    }

    func testCausesOfTheSignIn() {
        let cases: [([String: Any], CartoucheFailure.Cause)] = [
            (["family": "portal", "kind": "incorrectCredentials"], .appleCredentials),
            (["family": "portal", "kind": "appSpecificPasswordRequired"], .appSpecificPassword),
            (["family": "portal", "kind": "incorrectVerificationCode"], .verificationCode),
            (["family": "portal", "kind": "tooManyAttempts"], .tooManyAttempts),
            (["family": "portal", "kind": "noTeams"], .noTeam),
            (["family": "portal", "kind": "userCancelled"], .cancelled),
            (["family": "cartouche", "kind": "codeTimeout"], .verificationTimeout),
            (["family": "cartouche", "kind": "accountRepair"], .accountRepair),
            (["family": "cartouche", "kind": "noCredentials"], .credentialsMissing),
            (["family": "server", "kind": "underlyingError", "apple": -20209], .appleServer),
            (["family": "anisette", "kind": "allServersFailed"], .anisette),
            (["family": "operation", "kind": "forbidden", "stage": "certificate"], .certificateRefused),
            (["family": "operation", "kind": "forbidden", "stage": "device"], .other),
            (["family": "operation", "kind": "pairingNotComplete"], .pairing),
            (["family": "minimuxer", "kind": "noDevice", "stage": "device"], .device),
            (["family": "minimuxer", "kind": "somethingNew"], .device),
            (["family": "network", "kind": "url", "network": -1009, "host": "apple"], .offline),
            (["family": "network", "kind": "url", "network": -1001, "host": "apple"], .network),
            (["family": "network", "kind": "url", "network": -1001, "host": "sideStore"], .anisette),
            (["family": "network", "kind": "url", "network": -1001, "host": "anisette"], .anisette),
            (["family": "network", "kind": "url", "network": -1009, "host": "anisette"], .offline),
            (["family": "pairing", "kind": "unreadable"], .pairing),
            (["family": "emProxy", "kind": "unnamed"], .vpn),
            (["family": "signer", "kind": "missingAppBundle"], .appBundle),
            (["family": "signer", "kind": "missingProvisioningProfile"], .profile),
            (["family": "certificate", "kind": "pkcs12ImportFailed"], .certificate),
            (["family": "ocsp", "kind": "revoked"], .certificate),
            (["family": "database", "kind": "migrationFailed"], .database),
            (["family": "cancelled", "kind": "cancelled"], .cancelled),
            (["family": "cocoa", "kind": "cocoa", "stage": "database"], .database),
            (["family": "other", "kind": "Weird"], .other),
        ]
        for (fields, cause) in cases {
            XCTAssertEqual(outcome(fields)?.cause, cause, "\(fields)")
        }
    }

    // MARK: The failure of an action of SideStore

    func testTheFailureSaysWhatSideStoreLeft() throws {
        let left = try XCTUnwrap(outcome([
            "seconds": 40, "percent": 25, "stage": "team", "family": "server", "kind": "underlyingError",
            "codes": "SideSign.ServerError 3", "apple": 1100, "codeAsked": true,
        ]))
        let failure = CartoucheFailure.sideStore(outcome: left, message: "Your session has expired", fraction: 0.2,
                                                 seconds: 45, vpn: true, pairing: true)
        XCTAssertEqual(failure.cause, .appleServer)
        XCTAssertEqual(failure.stage, "team")
        XCTAssertEqual(failure.percent, 25)
        XCTAssertEqual(failure.seconds, 40)
        XCTAssertEqual(failure.codes, "SideSign.ServerError 3")
        XCTAssertEqual(failure.fields, [
            "cause": .text("appleServer"), "stage": .text("team"), "percent": .number(25), "seconds": .number(40),
            "kind": .text("underlyingError"), "apple": .number(1100),
            "codeAsked": .flag(true), "vpn": .flag(true), "pairing": .flag(true),
        ])
        XCTAssertFalse(failure.summary.contains("expired"))
        XCTAssertEqual(failure.summary, "appleServer, at team, 25 %, 40 s; apple 1100, codeAsked yes, "
                       + "kind underlyingError, pairing yes, vpn yes")
    }

    func testWithoutAnOutcomeTheBridgesSentencesTellTheCause() {
        let said: [(String, CartoucheFailure.Cause)] = [
            ("Built-in SideStore quit unexpectedly", .sideStoreQuit),
            ("LNPerformActionErrorCodeLocalizedStringResource: Built-in SideStore quit unexpectedly", .sideStoreQuit),
            ("Another refresh task is in progress.", .sideStoreBusy),
            ("Built-in SideStore failed to start in reasonable time", .sideStoreSlowStart),
            ("Unable to locate LiveProcess bundle. To use the Refresh All Apps shortcut, reinstall", .liveProcessMissing),
            ("Failed to start extension Error Domain=NSCocoaErrorDomain", .liveProcessFailed),
            ("SideStore refresh intent type was not found: 9SideStore21CartoucheSignInIntentV", .intentMissing),
            ("Une erreur inconnue", .noOutcome),
        ]
        for (message, cause) in said {
            let failure = CartoucheFailure.sideStore(outcome: nil, message: message, fraction: 0, seconds: 3, vpn: false, pairing: nil)
            XCTAssertEqual(failure.cause, cause, message)
            XCTAssertEqual(failure.details, ["vpn": .flag(false)])
            XCTAssertEqual(failure.seconds, 3)
        }
    }

    func testAnOutcomeThatWentWellYetFailedOnTheWayBack() throws {
        let left = try XCTUnwrap(outcome(["ok": true, "stage": "finish"]))
        let failure = CartoucheFailure.sideStore(outcome: left, message: "Something", fraction: 1, seconds: nil, vpn: nil, pairing: nil)
        XCTAssertEqual(failure.cause, .other)
        XCTAssertEqual(failure.stage, "finish")
        XCTAssertEqual(failure.details, ["outcomeOK": .flag(true)])
    }

    func testASuccessSaysHowLongAndWhatItNoted() throws {
        let left = try XCTUnwrap(outcome(["ok": true, "seconds": 31, "codeAsked": true, "codeMode": "sms"]))
        XCTAssertEqual(CartoucheFailure.sideStoreSuccess(outcome: left, seconds: 40),
                       ["seconds": .number(31), "codeAsked": .flag(true), "codeMode": .text("sms")])
        XCTAssertEqual(CartoucheFailure.sideStoreSuccess(outcome: nil, seconds: 40.4),
                       ["seconds": .number(40), "outcome": .flag(false)])
    }

    // MARK: Cartouche's own errors

    private struct Described: CartoucheDescribedError {
        var failureKind: String
        var failureCause: CartoucheFailure.Cause
        var underlyingError: Error?
    }

    private struct LibraryError: Error {
        var status: Int
    }

    func testTheDeepestErrorThatTellsACauseWins() {
        let logon = LibraryError(status: 0xC000_006D)
        let error = Described(failureKind: "signInFailed", failureCause: .storageServer, underlyingError: logon)
        let failure = CartoucheFailure.of(error, stage: "connecting", fraction: 0.1, seconds: 2.6) { error in
            (error as? LibraryError).map { CartoucheFailure.ProtocolStatus(kind: .smb, status: $0.status) }
        }
        XCTAssertEqual(failure.cause, .storageCredentials)
        XCTAssertEqual(failure.stage, "connecting")
        XCTAssertEqual(failure.percent, 10)
        XCTAssertEqual(failure.seconds, 3)
        XCTAssertEqual(failure.details, ["kind": .text("signInFailed"), "protocol": .text("smb"), "status": .number(3_221_225_581)])

        let alone = Described(failureKind: "readOnly", failureCause: .storageReadOnly, underlyingError: nil)
        XCTAssertEqual(CartoucheFailure.of(alone).cause, .storageReadOnly)
        let unknown = Described(failureKind: "signInFailed", failureCause: .storageServer, underlyingError: LibraryError(status: 1))
        XCTAssertEqual(CartoucheFailure.of(unknown).cause, .storageServer)
    }

    func testCausesOfIOSErrors() {
        let cases: [(Error, CartoucheFailure.Cause)] = [
            (NSError(domain: NSCocoaErrorDomain, code: NSFileWriteOutOfSpaceError), .noSpace),
            (NSError(domain: NSPOSIXErrorDomain, code: 28), .noSpace),
            (NSError(domain: NSURLErrorDomain, code: NSURLErrorNotConnectedToInternet), .offline),
            (NSError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut), .network),
            (NSError(domain: NSCocoaErrorDomain, code: NSFileReadNoSuchFileError), .fileMissing),
            (NSError(domain: NSCocoaErrorDomain, code: NSFileReadNoPermissionError), .fileUnreadable),
            (NSError(domain: NSPOSIXErrorDomain, code: 61), .network),
            (CancellationError(), .cancelled),
            (NSError(domain: "Elsewhere", code: 1), .other),
            (NSError(domain: "Wrapper", code: 1, userInfo: [NSUnderlyingErrorKey: NSError(domain: NSPOSIXErrorDomain, code: 28)]), .noSpace),
        ]
        for (error, cause) in cases {
            XCTAssertEqual(CartoucheFailure.of(error).cause, cause, "\(error)")
        }
    }

    func testStatusesOfTheStorageProtocols() {
        let cases: [(CartoucheFailure.ProtocolStatus, CartoucheFailure.Cause)] = [
            (.init(kind: .smb, status: 0xC000_006D), .storageCredentials),
            (.init(kind: .smb, status: 0xC000_0022), .storagePermission),
            (.init(kind: .smb, status: 0xC000_00CC), .storageNotFound),
            (.init(kind: .smb, status: 0xC000_007F), .storageFull),
            (.init(kind: .smb, status: 0xC000_0001), .storageServer),
            (.init(kind: .s3, status: 403, code: "SignatureDoesNotMatch"), .storageCredentials),
            (.init(kind: .s3, status: 403, code: "AccessDenied"), .storagePermission),
            (.init(kind: .s3, status: 404, code: "NoSuchBucket"), .storageNotFound),
            (.init(kind: .s3, status: 301, code: "PermanentRedirect"), .storageAddress),
            (.init(kind: .s3, status: 503, code: "SlowDown"), .storageServer),
            (.init(kind: .ftp, status: 530), .storageCredentials),
            (.init(kind: .ftp, status: 550), .storageNotFound),
            (.init(kind: .ftp, status: 552), .storageFull),
            (.init(kind: .sftp, status: 2), .storageNotFound),
            (.init(kind: .sftp, status: 3), .storagePermission),
        ]
        for (status, cause) in cases {
            XCTAssertEqual(status.cause, cause, "\(status)")
        }
    }

    func testAnExplainedErrorKeepsItsFailure() {
        struct Explained: CartoucheExplainedError {
            var failure: CartoucheFailure?
        }
        let error = Explained(failure: CartoucheFailure(.vpn, stage: "device", details: ["kind": .text("noVPN")]))
        let failure = CartoucheFailure.of(error, stage: "Renewing", fraction: 0.5, seconds: 9)
        XCTAssertEqual(failure.cause, .vpn)
        XCTAssertEqual(failure.stage, "device")
        XCTAssertEqual(failure.percent, 50)
        XCTAssertEqual(failure.seconds, 9)
        XCTAssertEqual(CartoucheFailure.of(Explained(failure: nil)).cause, .other)
    }

    func testAFailureKeepsOnlyNamesAndNumbers() {
        let failure = CartoucheFailure(.other, stage: "Installing Zelda from /private/var", codes: "Elsewhere 1 (the words)",
                                       details: ["kind": .text("the game's name"), "ok": .text("aName"),
                                                 "bad key": .flag(true), "under_score": .flag(true),
                                                 "huge": .number(.infinity), "count": .number(3)])
        XCTAssertNil(failure.stage)
        XCTAssertNil(failure.codes)
        XCTAssertEqual(failure.details, ["ok": .text("aName"), "count": .number(3)])
        XCTAssertEqual(CartoucheFailure(.other, codes: "NSURLErrorDomain -1001 < NSPOSIXErrorDomain 60").codes,
                       "NSURLErrorDomain -1001 < NSPOSIXErrorDomain 60")
    }

    func testEveryCauseIsAName() {
        for cause in CartoucheFailure.Cause.allCases {
            XCTAssertNotNil(CartoucheFailure.name(cause.rawValue), cause.rawValue)
            XCTAssertLessThanOrEqual(cause.rawValue.count, 24)
        }
    }
}
