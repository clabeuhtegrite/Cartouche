//
//  CartoucheGameBuild.swift
//  Cartouche
//
//  Which build of a game an IPA, or an installed game, is: the game's
//  version, the nxnative commit and shader chain it was built from, which
//  nxnative writes into the app's Info.plist (DMCommit, DMChain), and when
//  it was built, which the IPA says by the time of its Info.plist, written
//  by the build. Cartouche Builder and nxnative's own build script make
//  IPAs alike: a game built again after a change to nxnative, or with an
//  update of the game, is a newer build of it, which the console offers to
//  install over the one on the iPhone.
//
//  Platform-independent: tested on its own by launcher/Package.swift.
//

import Foundation

struct CartoucheGameBuild: Codable, Hashable {
    /// The game's version, CFBundleShortVersionString.
    var version: String?
    /// The nxnative commit, 12 hexadecimal digits or more, with "+dirty"
    /// after it when the build had changes of its own.
    var commit: String?
    /// The shader chain of that commit.
    var chain: String?
    /// When the IPA was built.
    var builtAt: Date?

    init(version: String? = nil, commit: String? = nil, chain: String? = nil, builtAt: Date? = nil) {
        self.version = Self.text(version)
        self.commit = Self.text(commit)?.lowercased()
        self.chain = Self.text(chain)?.lowercased()
        self.builtAt = builtAt
    }

    /// From the app's Info.plist, and the time it has in the IPA.
    init(info: [String: Any], builtAt: Date?) {
        self.init(version: info["CFBundleShortVersionString"] as? String, commit: info["DMCommit"] as? String,
                  chain: info["DMChain"] as? String, builtAt: builtAt)
    }

    /// The build of the app installed at BUNDLE, as the Info.plist in it
    /// says, without when it was built; nil when it has none to read.
    static func installed(atBundle bundle: URL) -> CartoucheGameBuild? {
        guard let data = try? Data(contentsOf: bundle.appendingPathComponent("Info.plist")),
              let info = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        else { return nil }
        return CartoucheGameBuild(info: info, builtAt: nil)
    }

    /// The record Cartouche wrote of a game's install, RECORDED, when it is
    /// of the build INSTALLED, with when that build was made; nil for a
    /// record of another build. Cartouche 0.9.0 to 0.11.2 recorded no
    /// version, commit nor chain, as it read them from LiveContainer's
    /// settings for the game: such a record, of the build installed then,
    /// takes them from the game's Info.plist and keeps when it was built.
    static func record(_ recorded: CartoucheGameBuild, of installed: CartoucheGameBuild) -> CartoucheGameBuild? {
        if recorded.version == nil, recorded.commit == nil, recorded.chain == nil {
            return CartoucheGameBuild(version: installed.version, commit: installed.commit, chain: installed.chain,
                                      builtAt: recorded.builtAt)
        }
        guard recorded.version == installed.version, recorded.commit == installed.commit else { return nil }
        return recorded
    }

    /// Whether nxnative says it was built from changed files, so that its
    /// commit does not tell what it holds.
    var isDirty: Bool { commit?.hasSuffix("+dirty") ?? false }

    /// The commit as nxnative shows it: its first 12 digits.
    var shortCommit: String? {
        guard let commit else { return nil }
        let digits = commit.prefix { $0.isHexDigit }
        return digits.isEmpty ? nil : String(digits.prefix(12))
    }

    /// Whether this build is newer than INSTALLED, the one on the iPhone: a
    /// later version of the game, or the same version built later from
    /// another commit of nxnative, or from changed files.
    ///
    /// A build that names no commit is newer only by its version: its date
    /// alone would not tell it from a copy of the installed game, such as
    /// the one Cartouche writes to the games folder, made after it.
    func isNewer(than installed: CartoucheGameBuild) -> Bool {
        if let version, let other = installed.version {
            switch version.compare(other, options: .numeric) {
            case .orderedDescending: return true
            case .orderedAscending: return false
            case .orderedSame: break
            }
        }
        guard let commit else { return false }
        // The same commit, without changes of either's own: the same build.
        if !isDirty, !installed.isDirty, let other = installed.commit, Self.sameCommit(commit, other) {
            return false
        }
        guard let builtAt, let installedAt = installed.builtAt else { return false }
        return builtAt > installedAt
    }

    /// Whether this one is newer than OTHER, both builds of the games
    /// folder: by version, then by when they were built.
    func isNewerCopy(than other: CartoucheGameBuild) -> Bool {
        if let version, let otherVersion = other.version {
            switch version.compare(otherVersion, options: .numeric) {
            case .orderedDescending: return true
            case .orderedAscending: return false
            case .orderedSame: break
            }
        }
        return (builtAt ?? .distantPast) > (other.builtAt ?? .distantPast)
    }

    /// The same commit, one written longer than the other: nxnative writes
    /// 12 digits, a full hash has 40.
    static func sameCommit(_ a: String, _ b: String) -> Bool {
        let a = a.lowercased(), b = b.lowercased()
        let length = min(a.count, b.count)
        return length >= 7 && a.prefix(length) == b.prefix(length)
    }

    private static func text(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        return value
    }
}
