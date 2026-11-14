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
        XCTAssertNil(outcome(["action": "device"]))
        XCTAssertNotNil(outcome([:], action: .device))
        XCTAssertNil(outcome(["action": "signIn"], action: .device))
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
            (["family": "server", "kind": "httpStatus", "http": 429, "service": "grandSlam"], .tooManyAttempts),
            (["family": "server", "kind": "httpStatus", "http": 503, "service": "grandSlam"], .appleServer),
            (["family": "server", "kind": "underlyingError", "apple": -22411], .tooManyAttempts),
            (["family": "server", "kind": "underlyingError", "apple": -21668], .tooManyAttempts),
            (["family": "server", "kind": "underlyingError", "apple": -20102], .tooManyAttempts),
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

    func testApplesLimitSaysHowLongToWaitAndWhichService() throws {
        let left = try XCTUnwrap(outcome([
            "seconds": 41, "stage": "verification", "family": "server", "kind": "httpStatus", "http": 429,
            "service": "grandSlam", "retryAfter": 1_800, "codeAsked": true,
        ]))
        XCTAssertEqual(left.service, "grandSlam")
        XCTAssertEqual(left.retryAfter, 1_800)
        let failure = CartoucheFailure.sideStore(outcome: left, message: "Apple refuses more requests for now", fraction: 0.1,
                                                 seconds: 45, vpn: true, pairing: true)
        XCTAssertEqual(failure.cause, .tooManyAttempts)
        XCTAssertEqual(failure.fields, [
            "cause": .text("tooManyAttempts"), "stage": .text("verification"), "seconds": .number(41), "percent": .number(10),
            "kind": .text("httpStatus"), "http": .number(429), "service": .text("grandSlam"), "retryAfter": .number(1_800),
            "codeAsked": .flag(true), "vpn": .flag(true), "pairing": .flag(true),
        ])
        // Nor a week and more, nor a service that is no name.
        let odd = try XCTUnwrap(outcome(["family": "server", "kind": "httpStatus", "http": 429, "retryAfter": 999_999,
                                         "service": "gsa.apple.com"]))
        XCTAssertNil(odd.retryAfter)
        XCTAssertNil(odd.service)
    }

    func testApplesPageInTheWordsGivesItsStatusOnly() throws {
        // As SideStore passed it on before patch 0016.
        let message = "LNPerformActionErrorCodeLocalizedStringResource: Invalid server response: unparseable format\n<html>\n"
            + "<head><title>429 Too Many Requests</title></head>\n<body>\n<center><h1>429 Too Many Requests</h1></center>\n"
            + "<hr><center>Apple</center>\n</body>\n</html>"
        let left = try XCTUnwrap(outcome(["stage": "verification", "family": "server", "kind": "invalidResponseFormat",
                                          "codes": "SideSign.ServerError 1"]))
        let failure = CartoucheFailure.sideStore(outcome: left, message: message, fraction: nil, seconds: nil, vpn: true, pairing: true)
        XCTAssertEqual(failure.cause, .tooManyAttempts)
        XCTAssertEqual(failure.details["http"], .number(429))
        XCTAssertFalse(failure.summary.contains("Apple"))
        XCTAssertFalse(failure.summary.contains("html"))

        let unavailable = message.replacingOccurrences(of: "429 Too Many Requests", with: "503 Service Unavailable")
        let other = CartoucheFailure.sideStore(outcome: left, message: unavailable, fraction: nil, seconds: nil, vpn: nil, pairing: nil)
        XCTAssertEqual(other.cause, .appleServer)
        XCTAssertEqual(other.details["http"], .number(503))

        // Without an outcome, the page tells the cause.
        XCTAssertEqual(CartoucheFailure.sideStore(outcome: nil, message: message, fraction: nil, seconds: nil, vpn: nil, pairing: nil).cause,
                       .tooManyAttempts)
        XCTAssertEqual(CartoucheFailure.sideStore(outcome: nil, message: unavailable, fraction: nil, seconds: nil, vpn: nil,
                                                  pairing: nil).cause, .appleServer)
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

    // MARK: Requests sent again after Apple's 429 (patch 0020)

    func testSaysHowManyRequestsWentAgainAfterApplesLimit() throws {
        // Signed in once the third request sent again got past Apple's 429.
        let passed = try XCTUnwrap(outcome(["ok": true, "seconds": 9, "resent": 3]))
        XCTAssertEqual(CartoucheFailure.sideStoreSuccess(outcome: passed, seconds: 12),
                       ["seconds": .number(9), "resent": .number(3)])
        // Still refused after ten: Apple's limit, as before, with the ten.
        let refused = try XCTUnwrap(outcome([
            "seconds": 14, "stage": "account", "family": "server", "kind": "httpStatus", "http": 429,
            "service": "grandSlam", "resent": 10,
        ]))
        let failure = CartoucheFailure.sideStore(outcome: refused, message: "Apple refuses more requests for now", fraction: nil,
                                                 seconds: 15, vpn: true, pairing: true)
        XCTAssertEqual(failure.cause, .tooManyAttempts)
        XCTAssertEqual(failure.fields["resent"], .number(10))
        // A count, nothing else.
        XCTAssertNil(try XCTUnwrap(outcome(["resent": -1])).facts["resent"])
        XCTAssertNil(try XCTUnwrap(outcome(["resent": "three"])).facts["resent"])
    }

    // MARK: What SideStore's code did not expect (patch 0018)

    func testSaysWhichOfSideStoresSentencesAndWhatItNames() throws {
        let left = try XCTUnwrap(outcome([
            "stage": "FetchProvisioningProfiles", "family": "operation", "kind": "invalidParameters",
            "codes": "SideStore.OperationError 8", "reason": "notInContext", "missing": "targetAppBundle",
        ], action: .refresh))
        XCTAssertEqual(left.cause, .other)
        XCTAssertEqual(left.facts, ["reason": .text("notInContext"), "missing": .text("targetAppBundle")])
        let failure = CartoucheFailure.sideStore(outcome: left, message: "Failed to Refresh Some App", fraction: 1,
                                                 seconds: 4, vpn: true, pairing: true)
        XCTAssertEqual(failure.codes, "SideStore.OperationError 8")
        XCTAssertEqual(failure.details["kind"], .text("invalidParameters"))
        XCTAssertEqual(failure.details["reason"], .text("notInContext"))
        XCTAssertEqual(failure.details["missing"], .text("targetAppBundle"))
    }

    func testKeepsNoSentenceOfSideStoresForAReason() throws {
        let read = try XCTUnwrap(outcome([
            "reason": "Could not resolve installed app for 'Mario Kart World'", "missing": "context.targetAppBundle is nil",
        ], action: .refresh))
        XCTAssertEqual(read.facts, [:])
    }

    // MARK: Why minimuxer could not reach this iPhone (patch 0022)

    func testSaysWhyMinimuxerCouldNotReachThisIPhone() throws {
        // An iPad without cellular, with a Lockdown pairing file, from iPadOS 26.4.
        let left = try XCTUnwrap(outcome([
            "stage": "deviceCheck", "family": "operation", "kind": "invalidVPN", "codes": "SideStore.OperationError 10",
            "reason": "noIPsec", "pairingKind": "lockdown", "ipsec": false,
        ]))
        XCTAssertEqual(left.cause, .vpn)
        XCTAssertEqual(left.facts, ["reason": .text("noIPsec"), "pairingKind": .text("lockdown"), "ipsec": .flag(false)])
        let failure = CartoucheFailure.sideStore(outcome: left, message: "LocalDevVPN is not connected", fraction: 0,
                                                 seconds: 0, vpn: true, pairing: true)
        XCTAssertEqual(failure.cause, .vpn)
        XCTAssertEqual(failure.stage, "deviceCheck")
        XCTAssertEqual(failure.fields["reason"], .text("noIPsec"))
        XCTAssertEqual(failure.fields["pairingKind"], .text("lockdown"))
        XCTAssertEqual(failure.fields["ipsec"], .flag(false))
        XCTAssertEqual(failure.fields["vpn"], .flag(true))

        // A pairing file this iPhone refused at the handshake, with the
        // library's words behind minimuxer's.
        let refused = try XCTUnwrap(outcome([
            "stage": "deviceCheck", "family": "operation", "kind": "invalidPairingFile",
            "reason": "handshake", "detail": "reset", "pairingKind": "rppairing", "ipsec": true,
        ]))
        XCTAssertEqual(refused.cause, .pairing)
        XCTAssertEqual(refused.facts, ["reason": .text("handshake"), "detail": .text("reset"),
                                       "pairingKind": .text("rppairing"), "ipsec": .flag(true)])
    }

    func testKeepsNoSentenceOfMinimuxersNorAddress() throws {
        let read = try XCTUnwrap(outcome([
            "kind": "invalidVPN",
            "reason": "VPN tunnel iface is up and tunnel peer IP 10.7.0.1 is known, but TCP port poll failed",
            "detail": "Connection reset by peer (os error 54)", "pairingKind": "10.7.0.1", "ipsec": "no",
        ]))
        XCTAssertEqual(read.facts, [:])
    }

    // MARK: How a renewal ended

    func testARenewalEndsAsSideStoreLeftIt() throws {
        let quit = CartoucheFailure.sideStore(outcome: nil, message: "Built-in SideStore quit unexpectedly",
                                              fraction: 1, seconds: 4, vpn: true, pairing: true)
        // SideStore answered that it went through.
        XCTAssertEqual(CartoucheFailure.renewalEnd(failure: nil, outcome: nil, renewed: false), .renewed(despite: nil))
        // It quit before it said anything, and Cartouche's signature is the same.
        XCTAssertEqual(CartoucheFailure.renewalEnd(failure: quit, outcome: nil, renewed: false), .quit)
        // It quit once it had renewed Cartouche: its record says so.
        XCTAssertEqual(CartoucheFailure.renewalEnd(failure: quit, outcome: nil, renewed: true), .renewed(despite: quit))

        // It said it renewed Cartouche, and its answer was lost on the way.
        let renewed = try XCTUnwrap(outcome(["ok": true, "stage": "ScheduleExpirationWarningNotification"], action: .refresh))
        let lost = CartoucheFailure.sideStore(outcome: renewed, message: "Built-in SideStore quit unexpectedly",
                                              fraction: 1, seconds: 4, vpn: true, pairing: true)
        XCTAssertEqual(CartoucheFailure.renewalEnd(failure: lost, outcome: renewed, renewed: false), .renewed(despite: lost))

        // Any other failure stays one, unless Cartouche is renewed all the same.
        let failed = try XCTUnwrap(outcome(["stage": "FetchProvisioningProfiles", "family": "operation",
                                            "kind": "invalidParameters"], action: .refresh))
        let invalid = CartoucheFailure.sideStore(outcome: failed, message: "Invalid parameters", fraction: 1, seconds: 3,
                                                 vpn: true, pairing: true)
        XCTAssertEqual(CartoucheFailure.renewalEnd(failure: invalid, outcome: failed, renewed: false), .failed)
        XCTAssertEqual(CartoucheFailure.renewalEnd(failure: invalid, outcome: failed, renewed: true), .renewed(despite: invalid))
        let busy = CartoucheFailure.sideStore(outcome: nil, message: "Another refresh task is in progress.",
                                              fraction: 0, seconds: 0, vpn: true, pairing: true)
        XCTAssertEqual(CartoucheFailure.renewalEnd(failure: busy, outcome: nil, renewed: false), .failed)
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
            (.init(kind: .drive, status: 400, code: "invalid_grant"), .storageCredentials),
            (.init(kind: .drive, status: 401, code: "invalid_client"), .storageCredentials),
            (.init(kind: .drive, status: 401, code: "authError"), .storageCredentials),
            (.init(kind: .drive, status: 403, code: "accessNotConfigured"), .storageSetup),
            (.init(kind: .drive, status: 403, code: "SERVICE_DISABLED"), .storageSetup),
            (.init(kind: .drive, status: 403, code: "storageQuotaExceeded"), .storageFull),
            (.init(kind: .drive, status: 403, code: "insufficientFilePermissions"), .storageReadOnly),
            (.init(kind: .drive, status: 403, code: "userRateLimitExceeded"), .storageServer),
            (.init(kind: .drive, status: 429, code: "rateLimitExceeded"), .storageServer),
            (.init(kind: .drive, status: 404, code: "notFound"), .storageNotFound),
            (.init(kind: .drive, status: 403, code: "insufficientPermissions"), .storagePermission),
            (.init(kind: .drive, status: 503, code: "backendError"), .storageServer),
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
