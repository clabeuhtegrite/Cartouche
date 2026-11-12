//
//  CartoucheGameBuildTests.swift
//  CartoucheCoreTests
//
//  Which build of a game is newer (Sources/CartoucheGameBuild.swift): the
//  one the console offers over the installed game.
//

import Foundation
import XCTest
@testable import CartoucheCore

final class CartoucheGameBuildTests: XCTestCase {
    private let night = Date(timeIntervalSince1970: 1_794_281_224)

    func testReadsNxnativesKeys() {
        let build = CartoucheGameBuild(info: ["CFBundleShortVersionString": " 1.0.0 ", "DMCommit": "52124866A1B2+dirty",
                                              "DMChain": "844BF1A5EA8F"], builtAt: night)
        XCTAssertEqual(build.version, "1.0.0")
        XCTAssertEqual(build.commit, "52124866a1b2+dirty")
        XCTAssertEqual(build.chain, "844bf1a5ea8f")
        XCTAssertEqual(build.builtAt, night)
        XCTAssertTrue(build.isDirty)
        XCTAssertEqual(build.shortCommit, "52124866a1b2")
        XCTAssertNil(CartoucheGameBuild(info: ["DMCommit": "", "CFBundleShortVersionString": 3], builtAt: nil).commit)
        XCTAssertNil(CartoucheGameBuild(info: [:], builtAt: nil).version)
    }

    /// The installed game's build is in the Info.plist of its bundle, binary
    /// once LiveContainer has written it again, not in LCAppInfo.plist.
    func testReadsTheBuildOfAnInstalledGameFromItsInfoPlist() throws {
        let bundle = FileManager.default.temporaryDirectory
            .appendingPathComponent("CartoucheGameBuildTests-\(UUID().uuidString)/Game.app", isDirectory: true)
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: bundle.deletingLastPathComponent()) }
        XCTAssertNil(CartoucheGameBuild.installed(atBundle: bundle))

        let settings = try PropertyListSerialization.data(fromPropertyList: ["LCDataUUID": "A1B2"], format: .xml, options: 0)
        try settings.write(to: bundle.appendingPathComponent("LCAppInfo.plist"))
        let info: [String: Any] = ["CFBundleShortVersionString": "1.2.0", "DMCommit": "52124866A1B2", "DMChain": "844bf1a5ea8f",
                                   "CFBundleIdentifier": "com.example.game"]
        let data = try PropertyListSerialization.data(fromPropertyList: info, format: .binary, options: 0)
        try data.write(to: bundle.appendingPathComponent("Info.plist"))
        let build = try XCTUnwrap(CartoucheGameBuild.installed(atBundle: bundle))
        XCTAssertEqual(build, CartoucheGameBuild(version: "1.2.0", commit: "52124866a1b2", chain: "844bf1a5ea8f"))
        XCTAssertNil(build.builtAt)

        try Data("not a property list".utf8).write(to: bundle.appendingPathComponent("Info.plist"))
        XCTAssertNil(CartoucheGameBuild.installed(atBundle: bundle))
    }

    func testALaterVersionIsNewer() {
        let installed = CartoucheGameBuild(version: "1.0.0", commit: "aaaaaaaaaaaa", builtAt: night)
        XCTAssertTrue(CartoucheGameBuild(version: "1.1.0", commit: "aaaaaaaaaaaa", builtAt: night).isNewer(than: installed))
        XCTAssertTrue(CartoucheGameBuild(version: "1.0.10").isNewer(than: CartoucheGameBuild(version: "1.0.9")))
        XCTAssertFalse(CartoucheGameBuild(version: "0.9.0", commit: "bbbbbbbbbbbb", builtAt: night + 86_400).isNewer(than: installed))
    }

    func testTheSameVersionBuiltLaterFromAnotherCommitIsNewer() {
        let installed = CartoucheGameBuild(version: "1.0.0", commit: "aaaaaaaaaaaa", builtAt: night)
        XCTAssertTrue(CartoucheGameBuild(version: "1.0.0", commit: "bbbbbbbbbbbb", builtAt: night + 3_600).isNewer(than: installed))
        XCTAssertFalse(CartoucheGameBuild(version: "1.0.0", commit: "bbbbbbbbbbbb", builtAt: night - 3_600).isNewer(than: installed))
        // The same commit is the same build, whenever the copy was made,
        // such as the one Cartouche writes to the games folder.
        XCTAssertFalse(CartoucheGameBuild(version: "1.0.0", commit: "aaaaaaaaaaaa", builtAt: night + 3_600).isNewer(than: installed))
        XCTAssertFalse(CartoucheGameBuild(version: "1.0.0", commit: String(repeating: "A", count: 40), builtAt: night + 3_600)
            .isNewer(than: installed))
        // A build that does not say when it was made tells nothing.
        XCTAssertFalse(CartoucheGameBuild(version: "1.0.0", commit: "bbbbbbbbbbbb").isNewer(than: installed))
    }

    func testBuildsFromChangedFilesGoByDate() {
        let installed = CartoucheGameBuild(version: "1.0.0", commit: "aaaaaaaaaaaa+dirty", builtAt: night)
        XCTAssertTrue(CartoucheGameBuild(version: "1.0.0", commit: "aaaaaaaaaaaa+dirty", builtAt: night + 60).isNewer(than: installed))
        XCTAssertTrue(CartoucheGameBuild(version: "1.0.0", commit: "aaaaaaaaaaaa", builtAt: night + 60).isNewer(than: installed))
        XCTAssertFalse(CartoucheGameBuild(version: "1.0.0", commit: "aaaaaaaaaaaa+dirty", builtAt: night).isNewer(than: installed))
    }

    func testABuildThatNamesNoCommitIsNewerOnlyByVersion() {
        let installed = CartoucheGameBuild(version: "1.0.0", builtAt: night)
        XCTAssertFalse(CartoucheGameBuild(version: "1.0.0", builtAt: night + 86_400).isNewer(than: installed))
        XCTAssertTrue(CartoucheGameBuild(version: "1.0.1", builtAt: night).isNewer(than: installed))
        // Over a game whose build named none: one that names a commit, made later.
        XCTAssertTrue(CartoucheGameBuild(version: "1.0.0", commit: "bbbbbbbbbbbb", builtAt: night + 60).isNewer(than: installed))
    }

    func testTheNewestCopy() {
        let old = CartoucheGameBuild(version: "1.0.0", commit: "aaaaaaaaaaaa", builtAt: night)
        let rebuilt = CartoucheGameBuild(version: "1.0.0", commit: "bbbbbbbbbbbb", builtAt: night + 3_600)
        let updated = CartoucheGameBuild(version: "1.1.0", commit: "aaaaaaaaaaaa", builtAt: night - 3_600)
        XCTAssertTrue(rebuilt.isNewerCopy(than: old))
        XCTAssertFalse(old.isNewerCopy(than: rebuilt))
        XCTAssertTrue(updated.isNewerCopy(than: rebuilt))
        XCTAssertFalse(old.isNewerCopy(than: old))
    }

    func testCommitsOfTwoLengths() {
        XCTAssertTrue(CartoucheGameBuild.sameCommit("52124866a1b2", "52124866A1B2C3D4E5F60718293A4B5C6D7E8F90"))
        XCTAssertFalse(CartoucheGameBuild.sameCommit("52124866a1b2", "52124866a1b3"))
        // Too short to tell.
        XCTAssertFalse(CartoucheGameBuild.sameCommit("5212", "52124866a1b2"))
    }
}
