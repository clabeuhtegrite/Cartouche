//
//  CartoucheRelease.swift
//  Cartouche
//
//  Cartouche's own versions, as its source lists them
//  (app/sidestore-source.json): the source the built-in SideStore installs
//  Cartouche's updates from, which Cartouche reads too, to offer them
//  (CartoucheUpdates). Foundation only, so that swift test checks it on a
//  Mac (launcher/Package.swift).
//

import Foundation

/// A version of Cartouche that its source lists.
struct CartoucheRelease: Equatable {
    let version: String
    /// What the version brings, as the source words it.
    let notes: String
    /// The IPA's size, in bytes.
    let size: Int64?
    /// The IPA for the player's own certificate, which a signing app on the
    /// iPhone signs (app/scripts/own_certificate_ipa.py): the release
    /// workflow lists it beside the IPA since the version of November 15.
    /// Only Cartouche reads it, and only from GitHub, over HTTPS.
    var ownCertificateURL: URL? = nil

    /// The newest version of the app BUNDLE_IDENTIFIER that the source in
    /// DATA lists for an iOS of SYSTEM_VERSION, as SideStore picks it:
    /// none older than its minOSVersion or newer than its maxOSVersion.
    /// Nil when the source lists none.
    static func newest(in data: Data, bundleIdentifier: String, systemVersion: String) throws -> CartoucheRelease? {
        let source = try JSONDecoder().decode(Source.self, from: data)
        let versions = source.apps.first { $0.bundleIdentifier == bundleIdentifier }?.versions ?? []
        let runnable = versions.filter { version in
            guard CartoucheVersion.numbers(version.version) != nil else { return false }
            if let minimum = version.minOSVersion, CartoucheVersion.isHigher(minimum, than: systemVersion) { return false }
            if let maximum = version.maxOSVersion, CartoucheVersion.isHigher(systemVersion, than: maximum) { return false }
            return true
        }
        guard let newest = runnable.max(by: { CartoucheVersion.isHigher($1.version, than: $0.version) }) else { return nil }
        return CartoucheRelease(version: newest.version, notes: newest.localizedDescription ?? "", size: newest.size,
                                ownCertificateURL: newest.ownCertificateDownloadURL.flatMap(Self.ownCertificateURL))
    }

    /// The address of an IPA for the player's own certificate, when it is
    /// one of Cartouche's releases on GitHub.
    static func ownCertificateURL(_ text: String) -> URL? {
        guard let url = URL(string: text), url.scheme == "https", url.host == "github.com",
              url.path.hasPrefix("/clabeuhtegrite/Cartouche/releases/download/"), url.path.hasSuffix(".ipa") else { return nil }
        return url
    }

    private struct Source: Decodable {
        let apps: [App]
    }

    private struct App: Decodable {
        let bundleIdentifier: String
        let versions: [Version]?
    }

    private struct Version: Decodable {
        let version: String
        let localizedDescription: String?
        let size: Int64?
        let minOSVersion: String?
        let maxOSVersion: String?
        let ownCertificateDownloadURL: String?
    }
}

/// Versions as numbers between dots, such as 0.3.0, compared number by
/// number, as SideStore compares Cartouche's.
enum CartoucheVersion {
    /// The numbers of VERSION, such as [0, 3, 0] for "0.3.0"; nil unless it
    /// is numbers between dots.
    static func numbers(_ version: String) -> [Int]? {
        let parts = version.split(separator: ".", omittingEmptySubsequences: false)
        guard !parts.isEmpty, parts.count <= 4 else { return nil }
        var numbers: [Int] = []
        for part in parts {
            guard !part.isEmpty, part.count <= 9, part.utf8.allSatisfy({ $0 >= 0x30 && $0 <= 0x39 }),
                  let number = Int(part) else { return nil }
            numbers.append(number)
        }
        return numbers
    }

    /// Whether A is a higher version than B, "1.2" being "1.2.0". A version
    /// that is not numbers between dots is never higher, nor lower.
    static func isHigher(_ a: String, than b: String) -> Bool {
        guard var first = numbers(a), var second = numbers(b) else { return false }
        let count = max(first.count, second.count)
        first += Array(repeating: 0, count: count - first.count)
        second += Array(repeating: 0, count: count - second.count)
        return second.lexicographicallyPrecedes(first)
    }
}
