//
//  SMBRefusalTests.swift
//  CartoucheStorageTests
//
//  What Cartouche says when an SMB server does not sign the player in, for
//  each way a server refuses the account (CartoucheSMBRefusal), without a
//  server: the storage tests' Samba lets guests in and never locks or holds
//  back the account. Each status is SMBClient's error for it, as Samba 4.19
//  answered a guest it does not let in, an account turned off, one whose
//  password must change and one locked after wrong passwords.
//

import Foundation
import SMBClient
import XCTest
@testable import CartoucheStorage

final class SMBRefusalTests: XCTestCase {
    private let host = "nas.local"

    /// What the form says when SERVER answers the sign-in with STATUS, as the
    /// player gave USER, or none.
    private func said(_ status: UInt32, user: String = "joueur") -> String {
        let server = CartoucheStorageServer(kind: .smb, name: "NAS", host: host, username: user, share: "Partage")
        return CartoucheSMB.signInFailed(server, answer(status)).localizedDescription
    }

    /// SMBClient's error for an answer whose header says STATUS: the SMB2
    /// header (MS-SMB2 2.2.1), then the error's own fields.
    private func answer(_ status: UInt32) -> ErrorResponse {
        var data = Data([0xFE, 0x53, 0x4D, 0x42, 64, 0, 1, 0])
        withUnsafeBytes(of: status.littleEndian) { data.append(contentsOf: $0) }
        data.append(Data(count: 60))
        return ErrorResponse(data: data)
    }

    private func signInFailed(_ reason: String) -> String {
        CartoucheText.storageSignInFailed(host, reason)
    }

    func testSaysTheServerRefusedTheUserNameOrThePassword() {
        // STATUS_LOGON_FAILURE, which Samba, Windows and macOS answer for a
        // wrong password and an unknown user alike; STATUS_NO_SUCH_USER,
        // STATUS_WRONG_PASSWORD.
        for status: UInt32 in [0xC000_006D, 0xC000_0064, 0xC000_006A] {
            XCTAssertEqual(said(status), signInFailed(CartoucheText.storageSMBRefused), String(format: "0x%08X", status))
        }
    }

    /// No user name, and the server lets no guest in: it wants an account.
    func testAsksAGuestTheServerRefusesForAnAccount() {
        XCTAssertEqual(said(0xC000_006D, user: ""), signInFailed(CartoucheText.storageSMBNoGuests))
    }

    /// STATUS_ACCOUNT_LOCKED_OUT, after too many wrong passwords: even the
    /// right one is refused for a while.
    func testSaysTheServerLockedTheAccount() {
        XCTAssertEqual(said(0xC000_0234), signInFailed(CartoucheText.storageSMBLocked))
    }

    /// STATUS_ACCOUNT_DISABLED, STATUS_ACCOUNT_EXPIRED,
    /// STATUS_PASSWORD_EXPIRED, STATUS_PASSWORD_MUST_CHANGE,
    /// STATUS_ACCOUNT_RESTRICTION, STATUS_INVALID_LOGON_HOURS,
    /// STATUS_INVALID_WORKSTATION, which SMBClient calls "Unknown error".
    func testSaysTheServerHoldsTheAccountBack() {
        for status: UInt32 in [0xC000_0072, 0xC000_0193, 0xC000_0071, 0xC000_0224, 0xC000_006E, 0xC000_006F, 0xC000_0070] {
            XCTAssertEqual(said(status), signInFailed(CartoucheText.storageSMBHeldBack), String(format: "0x%08X", status))
        }
    }

    /// Any other answer is not the account refused: SMBClient's words stay.
    func testLeavesAnyOtherAnswerInSMBClientsWords() {
        // STATUS_ACCESS_DENIED, STATUS_NOT_SUPPORTED.
        XCTAssertEqual(said(0xC000_0022), signInFailed("Access Denied"))
        XCTAssertEqual(said(0xC000_00BB), signInFailed("Not Supported"))
        let server = CartoucheStorageServer(kind: .smb, name: "NAS", host: host, username: "joueur", share: "Partage")
        let cut = URLError(.networkConnectionLost)
        XCTAssertEqual(CartoucheSMB.signInFailed(server, cut).localizedDescription, signInFailed(cut.localizedDescription))
    }

    /// The error keeps SMBClient's, for its report and its cause in the
    /// measurements (CartoucheFailure: storageCredentials).
    func testKeepsTheServersAnswerUnderneath() throws {
        let server = CartoucheStorageServer(kind: .smb, name: "NAS", host: host, username: "joueur", share: "Partage")
        let error = CartoucheSMB.signInFailed(server, answer(0xC000_006D))
        XCTAssertEqual(error.kind, .signInFailed)
        let underlying = try XCTUnwrap(error.underlyingError as? ErrorResponse)
        XCTAssertEqual(underlying.header.status, 0xC000_006D)
    }
}
