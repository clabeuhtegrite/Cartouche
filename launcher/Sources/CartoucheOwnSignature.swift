//
//  CartoucheOwnSignature.swift
//  CartoucheCore
//
//  How Cartouche was signed, and, signed with the player's own certificate,
//  what its signature gives it (docs/imported-signing.md). A signing app on
//  the iPhone signs Cartouche with the entitlements of the player's
//  profile, which the player's App ID decides, and can leave some out:
//  Cartouche reads the entitlements it runs with and those its profile
//  allows, and says what is missing and how it comes back. Increased Memory
//  Limit first: without it, iOS gives Cartouche, and the games started in
//  its place, about 3 GB. Then the games' keychain groups, LiveContainer's,
//  one for each game's data folder (LiveContainer/Tweaks/SecItem.m):
//  without them, the games share Cartouche's keychain, which most games do
//  not use. Foundation only, so that swift test checks it
//  (launcher/Package.swift); CartoucheDevice.swift reads the signature.
//

import Foundation

/// How this copy of Cartouche was signed, from its Info.plist: by the
/// built-in SideStore, with the player's Apple ID; or with the player's own
/// certificate (CartoucheImportedSigning), by the Cartouche Installer on a
/// computer, which adds the key of the certificate it hands over
/// (CartoucheSigningHandoffKey), or by a signing app on the iPhone, from the
/// IPA for the player's own certificate (app/scripts/own_certificate_ipa.py),
/// which has no such key. The raw values are those the measurements send
/// (signing, in app.opened).
enum CartoucheSigningMode: String, Equatable, Sendable {
    case account
    case installer = "imported"
    case iPhone = "iphone"

    init(info: [String: Any]) {
        guard info["CartoucheImportedSigning"] as? Bool == true else {
            self = .account
            return
        }
        self = info["CartoucheSigningHandoffKey"] == nil ? .iPhone : .installer
    }
}

/// What Cartouche's signature carries, against what its profile allows.
struct CartoucheOwnSignature: Equatable, Sendable {
    /// Where an entitlement stands.
    enum Grant: String, Equatable, Sendable {
        /// The signature carries it: iOS gives it.
        case granted
        /// The profile allows it, and the signature does not carry it: the
        /// signing app left it out, and signing Cartouche again with all
        /// that the profile allows brings it.
        case leftOut
        /// The profile does not allow it: the player's App ID does not have
        /// the capability, and only another profile brings it.
        case notInProfile
    }

    let increasedMemoryLimit: Grant
    let gameKeychains: Grant

    static let memoryEntitlement = "com.apple.developer.kernel.increased-memory-limit"
    static let keychainEntitlement = "keychain-access-groups"
    static let teamEntitlement = "com.apple.developer.team-identifier"

    /// LiveContainer's keychain groups for the games, under TEAM: a shared
    /// one, then one for each of 127 more data folders
    /// (SharedModel.keychainAccessGroupCount), as the Cartouche Installer
    /// signs them in (installer/src-tauri/src/imported_signing.rs).
    static func gameKeychainGroups(team: String) -> [String] {
        let shared = team + ".com.kdt.livecontainer.shared"
        return [shared] + (1..<128).map { shared + ".\($0)" }
    }

    /// SIGNED: the entitlements Cartouche runs with. PROFILE: the
    /// Entitlements of the profile it was signed with. TEAM: the
    /// signature's team.
    init(signed: [String: Any], profile: [String: Any], team: String) {
        if signed[Self.memoryEntitlement] as? Bool == true {
            increasedMemoryLimit = .granted
        } else if profile[Self.memoryEntitlement] as? Bool == true {
            increasedMemoryLimit = .leftOut
        } else {
            increasedMemoryLimit = .notInProfile
        }
        let groups = Self.gameKeychainGroups(team: team)
        // iOS gives a keychain group that the signature names as it is, or
        // every group to a signature that names "*": a pattern such as
        // TEAM.* is a profile's, which gives nothing once in a signature.
        let carried = Set(signed[Self.keychainEntitlement] as? [String] ?? [])
        let allowed = profile[Self.keychainEntitlement] as? [String] ?? []
        if carried.contains("*") || groups.allSatisfy(carried.contains) {
            gameKeychains = .granted
        } else if groups.allSatisfy({ group in allowed.contains { Self.identifierMatches($0, group) } }) {
            gameKeychains = .leftOut
        } else {
            gameKeychains = .notInProfile
        }
    }

    /// Whether the pattern ALLOWED of a profile covers the identifier
    /// ACTUAL, as the Cartouche Installer matches them: the same, or after
    /// the part of ALLOWED before its final star, which ends with a dot.
    static func identifierMatches(_ allowed: String, _ actual: String) -> Bool {
        guard allowed.hasSuffix("*") else { return allowed == actual }
        let prefix = allowed.dropLast()
        return !prefix.contains("*") && prefix.hasSuffix(".") && actual.hasPrefix(prefix) && actual.count > prefix.count
    }

    /// Whether the signature gives Cartouche all it uses.
    var isComplete: Bool { increasedMemoryLimit == .granted && gameKeychains == .granted }

    /// What app.opened sends of it: where each grant stands, never the
    /// team nor the profile.
    var fields: [String: String] {
        ["iml": increasedMemoryLimit.rawValue, "gameKeychains": gameKeychains.rawValue]
    }
}
