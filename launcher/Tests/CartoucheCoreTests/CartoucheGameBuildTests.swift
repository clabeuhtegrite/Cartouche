//
//  CartoucheGameBuildTests.swift
//  CartoucheCoreTests
//
//  Which build of a game is newer (Sources/CartoucheGameBuild.swift): the
//  one the console offers over the installed game. And which IPA of the
//  games folder is one of nxnative's games, whatever its names.
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

    // MARK: Whether an IPA is a game

    func testAnAppNxnativeBuiltIsAGameWhateverItsNames() {
        // As a player's, built with another bundle ID, under a name the
        // catalog does not know, without DMLanguage: what else nxnative
        // writes says it (Reddit, 12 Nov).
        let built: [[String: Any]] = [["DMLanguage": "fr"], ["DMTitleID": "0100F2C0115B6000"], ["DMCommit": "52124866a1b2"],
                                      ["CFBundleIdentifier": "com.player.silksong", "DMCommit": "52124866a1b2+dirty"]]
        for info in built {
            XCTAssertTrue(CartoucheNxnativeApp.isNxnative(info), "\(info)")
            XCTAssertTrue(CartoucheNxnativeApp.isGame(info: info, titleId: nil, needsGameFiles: false), "\(info)")
        }
        let other: [String: Any] = ["CFBundleIdentifier": "com.example.notes", "CFBundleName": "Notes"]
        XCTAssertFalse(CartoucheNxnativeApp.isNxnative(other))
        XCTAssertFalse(CartoucheNxnativeApp.isGame(info: other, titleId: nil, needsGameFiles: false))
    }

    func testAnIPABuiltWithoutItsGameFilesIsAGame() {
        // Its romfs.id says it, whatever its Info.plist.
        XCTAssertTrue(CartoucheNxnativeApp.isGame(info: [:], titleId: nil, needsGameFiles: true))
        // As one whose title ID Cartouche found, by its name or its bundle ID.
        XCTAssertTrue(CartoucheNxnativeApp.isGame(info: [:], titleId: "0100F2C0115B6000", needsGameFiles: false))
    }

    func testDMTitleIDNamesTheGame() {
        XCTAssertEqual(CartoucheNxnativeApp.titleId(in: ["DMTitleID": " 0100f2c0115b6000\n"]), "0100F2C0115B6000")
        let others: [Any] = ["0100F2C0115B600", "0100F2C0115B60000", "0100F2C0115B600G", "", 72_057_594_037_927_936]
        for value in others {
            XCTAssertNil(CartoucheNxnativeApp.titleId(in: ["DMTitleID": value]), "\(value)")
        }
        XCTAssertNil(CartoucheNxnativeApp.titleId(in: ["CFBundleIdentifier": "org.nxnative.0100f2c0115b6000"]))
    }
}
