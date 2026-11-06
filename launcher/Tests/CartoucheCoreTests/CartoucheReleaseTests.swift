//
//  CartoucheReleaseTests.swift
//  CartoucheCoreTests
//
//  How Cartouche reads its own source (Sources/CartoucheRelease.swift) to
//  offer an update: the version SideStore would install, and versions
//  compared number by number.
//

import Foundation
import XCTest
@testable import CartoucheCore

final class CartoucheReleaseTests: XCTestCase {
    private let bundleIdentifier = "io.github.clabeuhtegrite.cartouche"

    private func source(_ versions: [[String: Any]], bundleIdentifier: String? = nil) throws -> Data {
        let app: [String: Any] = [
            "name": "Cartouche",
            "bundleIdentifier": bundleIdentifier ?? self.bundleIdentifier,
            "versions": versions,
        ]
        return try JSONSerialization.data(withJSONObject: ["name": "Cartouche", "apps": [app], "news": []])
    }

    private func version(_ version: String, minOS: String? = "15.0", maxOS: String? = nil) -> [String: Any] {
        var entry: [String: Any] = [
            "version": version,
            "date": "2026-11-06T17:12:50Z",
            "localizedDescription": "Cartouche \(version)",
            "downloadURL": "https://github.com/clabeuhtegrite/Cartouche/releases/download/v\(version)/Cartouche-\(version).ipa",
            "size": 36_802_806,
            "sha256": String(repeating: "0", count: 64),
        ]
        if let minOS { entry["minOSVersion"] = minOS }
        if let maxOS { entry["maxOSVersion"] = maxOS }
        return entry
    }

    func testTheNewestVersionWinsWhateverTheOrder() throws {
        let data = try source([version("0.3.0"), version("0.10.0"), version("0.9.2")])
        let newest = try CartoucheRelease.newest(in: data, bundleIdentifier: bundleIdentifier, systemVersion: "26.1")
        XCTAssertEqual(newest, CartoucheRelease(version: "0.10.0", notes: "Cartouche 0.10.0", size: 36_802_806))
    }

    func testAVersionForAnotherIOSIsLeftOut() throws {
        let data = try source([version("0.5.0", minOS: "27.0"), version("0.4.0", maxOS: "18.9"), version("0.3.0")])
        XCTAssertEqual(try CartoucheRelease.newest(in: data, bundleIdentifier: bundleIdentifier, systemVersion: "26.1")?.version, "0.3.0")
        XCTAssertEqual(try CartoucheRelease.newest(in: data, bundleIdentifier: bundleIdentifier, systemVersion: "27.0")?.version, "0.5.0")
        XCTAssertEqual(try CartoucheRelease.newest(in: data, bundleIdentifier: bundleIdentifier, systemVersion: "18.6.2")?.version, "0.4.0")
    }

    func testOnlyCartouchesOwnEntryCounts() throws {
        let data = try source([version("9.0.0")], bundleIdentifier: "com.example.other")
        XCTAssertNil(try CartoucheRelease.newest(in: data, bundleIdentifier: bundleIdentifier, systemVersion: "26.1"))
    }

    func testAVersionThatIsNotNumbersIsLeftOut() throws {
        let data = try source([version("1.0.0-beta"), version("0.3.0")])
        XCTAssertEqual(try CartoucheRelease.newest(in: data, bundleIdentifier: bundleIdentifier, systemVersion: "26.1")?.version, "0.3.0")
    }

    func testTheRepositorysSourceReads() throws {
        // The source the built-in SideStore reads, as main has it.
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("app/sidestore-source.json")
        let data = try Data(contentsOf: url)
        let newest = try XCTUnwrap(CartoucheRelease.newest(in: data, bundleIdentifier: bundleIdentifier, systemVersion: "26.1"))
        XCTAssertNotNil(CartoucheVersion.numbers(newest.version))
        XCTAssertFalse(newest.notes.isEmpty)
    }

    func testVersionsCompareNumberByNumber() {
        XCTAssertTrue(CartoucheVersion.isHigher("0.10.0", than: "0.9.9"))
        XCTAssertTrue(CartoucheVersion.isHigher("0.4.0", than: "0.3.0"))
        XCTAssertTrue(CartoucheVersion.isHigher("1.0", than: "0.99.99"))
        XCTAssertFalse(CartoucheVersion.isHigher("0.3.0", than: "0.3.0"))
        XCTAssertFalse(CartoucheVersion.isHigher("0.3", than: "0.3.0"))
        XCTAssertFalse(CartoucheVersion.isHigher("0.3.0", than: "0.4.0"))
        XCTAssertFalse(CartoucheVersion.isHigher("1.0.0-beta", than: "0.1.0"))
        XCTAssertFalse(CartoucheVersion.isHigher("0.1.0", than: "abc"))
        XCTAssertEqual(CartoucheVersion.numbers("26.1"), [26, 1])
        XCTAssertNil(CartoucheVersion.numbers("1..0"))
        XCTAssertNil(CartoucheVersion.numbers(""))
        XCTAssertNil(CartoucheVersion.numbers("+1.0"))
    }
}
