//
//  CartoucheOwnSignatureTests.swift
//  CartoucheCoreTests
//
//  How Cartouche tells how it was signed, and what its signature gives it
//  when the player signed it with their own certificate
//  (Sources/CartoucheOwnSignature.swift).
//

import XCTest
@testable import CartoucheCore

final class CartoucheOwnSignatureTests: XCTestCase {
    private let team = "ABCDE12345"
    private let memory = CartoucheOwnSignature.memoryEntitlement
    private let keychain = CartoucheOwnSignature.keychainEntitlement

    // MARK: How Cartouche was signed

    /// The IPA for the player's own certificate carries the mode without
    /// the key of the Cartouche Installer's handoff, which the Installer
    /// adds when it signs on a computer (app/scripts/own_certificate_ipa.py).
    func testTheInfoPlistSaysWhoSignedCartouche() {
        XCTAssertEqual(CartoucheSigningMode(info: [:]), .account)
        XCTAssertEqual(CartoucheSigningMode(info: ["CartoucheImportedSigning": false]), .account)
        // Only the key the Installer adds beside the mode tells its install
        // apart: one without it was signed on the iPhone.
        XCTAssertEqual(CartoucheSigningMode(info: ["CartoucheImportedSigning": true]), .iPhone)
        XCTAssertEqual(CartoucheSigningMode(info: ["CartoucheImportedSigning": true,
                                                   "CartoucheSigningHandoffKey": Data(repeating: 1, count: 32)]), .installer)
        // A handoff key without the mode is no install with the player's
        // certificate.
        XCTAssertEqual(CartoucheSigningMode(info: ["CartoucheSigningHandoffKey": Data(repeating: 1, count: 32)]), .account)
        // The measurements' names, which the Installer's install had first.
        XCTAssertEqual([CartoucheSigningMode.account, .installer, .iPhone].map(\.rawValue), ["account", "imported", "iphone"])
    }

    // MARK: Increased Memory Limit

    func testIncreasedMemoryLimitCarriedLeftOutOrNotAllowed() {
        let all = CartoucheOwnSignature(signed: [memory: true], profile: [memory: true], team: team)
        XCTAssertEqual(all.increasedMemoryLimit, .granted)
        // The profile allows it, and the signing app signed Cartouche
        // without it.
        let leftOut = CartoucheOwnSignature(signed: [:], profile: [memory: true], team: team)
        XCTAssertEqual(leftOut.increasedMemoryLimit, .leftOut)
        let off = CartoucheOwnSignature(signed: [memory: false], profile: [memory: true], team: team)
        XCTAssertEqual(off.increasedMemoryLimit, .leftOut)
        // The App ID does not have the capability.
        let notAllowed = CartoucheOwnSignature(signed: [:], profile: [:], team: team)
        XCTAssertEqual(notAllowed.increasedMemoryLimit, .notInProfile)
        XCTAssertEqual(CartoucheOwnSignature(signed: [:], profile: [memory: false], team: team).increasedMemoryLimit, .notInProfile)
        // Only true counts, as iOS reads it.
        XCTAssertEqual(CartoucheOwnSignature(signed: [memory: "true"], profile: [:], team: team).increasedMemoryLimit, .notInProfile)
    }

    // MARK: The games' keychain groups

    func testTheGamesKeychainGroupsAreLiveContainers() {
        let groups = CartoucheOwnSignature.gameKeychainGroups(team: team)
        XCTAssertEqual(groups.count, 128)
        XCTAssertEqual(groups.first, "ABCDE12345.com.kdt.livecontainer.shared")
        XCTAssertEqual(groups[1], "ABCDE12345.com.kdt.livecontainer.shared.1")
        XCTAssertEqual(groups.last, "ABCDE12345.com.kdt.livecontainer.shared.127")
        XCTAssertEqual(Set(groups).count, 128)
    }

    func testTheGroupsCountOnlyAsTheSignatureNamesThem() {
        let groups = CartoucheOwnSignature.gameKeychainGroups(team: team)
        // Signed in one by one, as the Cartouche Installer does.
        XCTAssertEqual(CartoucheOwnSignature(signed: [keychain: groups], profile: [keychain: ["\(team).*"]], team: team).gameKeychains,
                       .granted)
        XCTAssertEqual(CartoucheOwnSignature(signed: [keychain: ["*"]], profile: [:], team: team).gameKeychains, .granted)
        // The profile's pattern, signed as it is: iOS gives no group by it.
        XCTAssertEqual(CartoucheOwnSignature(signed: [keychain: ["\(team).*"]], profile: [keychain: ["\(team).*"]], team: team)
                        .gameKeychains, .leftOut)
        // One group missing is as good as none: LiveContainer gives each
        // game's data folder one of them.
        XCTAssertEqual(CartoucheOwnSignature(signed: [keychain: Array(groups.dropLast())], profile: [keychain: ["\(team).*"]], team: team)
                        .gameKeychains, .leftOut)
        XCTAssertEqual(CartoucheOwnSignature(signed: [:], profile: [keychain: ["\(team).com.kdt.*"]], team: team).gameKeychains, .leftOut)
    }

    func testAProfileWithoutTheGroupsCannotGiveThem() {
        // Only the app's own group.
        let own = CartoucheOwnSignature(signed: [keychain: ["\(team).io.github.clabeuhtegrite.cartouche"]],
                                        profile: [keychain: ["\(team).io.github.clabeuhtegrite.cartouche"]], team: team)
        XCTAssertEqual(own.gameKeychains, .notInProfile)
        // Another team's.
        XCTAssertEqual(CartoucheOwnSignature(signed: [:], profile: [keychain: ["OTHER12345.*"]], team: team).gameKeychains, .notInProfile)
        XCTAssertEqual(CartoucheOwnSignature(signed: [:], profile: [:], team: team).gameKeychains, .notInProfile)
    }

    /// The patterns as the Cartouche Installer matches them
    /// (installer/src-tauri/src/imported_signing.rs, expands_only_authorized_identifiers).
    func testPatternsMatchAsTheInstallersDo() {
        XCTAssertTrue(CartoucheOwnSignature.identifierMatches("TEAM.*", "TEAM.io.github.cartouche"))
        XCTAssertTrue(CartoucheOwnSignature.identifierMatches("TEAM.io.*", "TEAM.io.github.cartouche"))
        XCTAssertFalse(CartoucheOwnSignature.identifierMatches("TEAM.io.*", "TEAM.iota.app"))
        XCTAssertFalse(CartoucheOwnSignature.identifierMatches("TEAM.*", "OTHER.app"))
        XCTAssertFalse(CartoucheOwnSignature.identifierMatches("TEAM.a*b", "TEAM.axb"))
        XCTAssertTrue(CartoucheOwnSignature.identifierMatches("TEAM.app", "TEAM.app"))
        XCTAssertFalse(CartoucheOwnSignature.identifierMatches("TEAM.app", "TEAM.app.extension"))
        XCTAssertFalse(CartoucheOwnSignature.identifierMatches("TEAM.*", "TEAM."))
        XCTAssertFalse(CartoucheOwnSignature.identifierMatches("*", "TEAM.app"))
        XCTAssertFalse(CartoucheOwnSignature.identifierMatches("TEAM*", "TEAMX.app"))
    }

    // MARK: What it sends

    func testSendsWhereEachGrantStandsAndNeverTheTeam() {
        let groups = CartoucheOwnSignature.gameKeychainGroups(team: team)
        let complete = CartoucheOwnSignature(signed: [memory: true, keychain: groups], profile: [:], team: team)
        XCTAssertTrue(complete.isComplete)
        XCTAssertEqual(complete.fields, ["iml": "granted", "gameKeychains": "granted"])
        let missing = CartoucheOwnSignature(signed: [keychain: ["\(team).*"]], profile: [keychain: ["\(team).*"]], team: team)
        XCTAssertFalse(missing.isComplete)
        XCTAssertEqual(missing.fields, ["iml": "notInProfile", "gameKeychains": "leftOut"])
        XCTAssertFalse(missing.fields.values.contains { $0.contains(team) })
    }
}
