//
//  SetupFilesTests.swift
//  BuilderKitTests
//
//  What the setup assistant finds in the folder of the dumps
//  (SetupFiles.swift): its games, counted as the engine finds them
//  (library.py), and, in a folder that holds none, what nxnative built
//  already, which goes in the games folder. A player whose folder held an
//  IPA and its romfs.img read "No game in it for now." without a word on
//  them (Reddit, 12 Nov).
//

import Foundation
import XCTest
@testable import BuilderKit

final class SetupFilesTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("SetupFilesTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    func testCountsTheGamesAsTheEngineFindsThem() async throws {
        let none = await SetupFiles.countGames(at: folder.path)
        XCTAssertEqual(none, 0)
        // A game and its update, by the title ID in their names; a game in a
        // folder of its own; a NUP named without its ID.
        try write("Mario Kart World [09D00E8A5D61A000].nsp")
        try write("Mario Kart World [09D00E8A5D61A800].nsp")
        try write("Zelda/0100F2C0115B6000.xci")
        try write("Kirby.nup")
        let three = await SetupFiles.countGames(at: folder.path)
        XCTAssertEqual(three, 3)
        let unreadable = await SetupFiles.countGames(at: folder.appendingPathComponent("Missing").path)
        XCTAssertNil(unreadable)
    }

    func testWhatNxnativeBuiltIsNoGameButIsFound() async throws {
        // As the player's folder: an IPA built without its game files and
        // its romfs.img, beside a folder nxnative built a game in.
        try write("Silksong/Hollow Knight Silksong.ipa")
        try write("Silksong/RomFS.img")
        try write("Zelda_build/Payload/Zelda.app/romfs.id")
        let count = await SetupFiles.countGames(at: folder.path)
        XCTAssertEqual(count, 0)
        let built = await SetupFiles.holdsBuilt(at: folder.path)
        XCTAssertTrue(built)
    }

    func testAnIPAOrAnImageIsFoundAsDeepAsGamesAreLookedFor() async throws {
        for path in ["Zelda.ipa", "ROMFS.IMG", "Games/Zelda.romfs.img", "Zelda_build/Zelda.ipa", "a/b/c/d/romfs.img"] {
            let root = folder.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try write(path, in: root)
            let built = await SetupFiles.holdsBuilt(at: root.path)
            XCTAssertTrue(built, path)
        }
    }

    func testNothingBuiltInAFolderWithout() async throws {
        let empty = await SetupFiles.holdsBuilt(at: folder.path)
        XCTAssertFalse(empty)
        // Hidden files and folders, other files, and an IPA deeper than games
        // are looked for.
        for path in ["._romfs.img", ".Trash/Zelda.ipa", "romfs.img.part", "Zelda.nsp", "a/b/c/d/e/Zelda.ipa"] {
            try write(path)
        }
        let others = await SetupFiles.holdsBuilt(at: folder.path)
        XCTAssertFalse(others)
        let unreadable = await SetupFiles.holdsBuilt(at: folder.appendingPathComponent("Missing").path)
        XCTAssertFalse(unreadable)
    }

    func testTheBaseGameOfATitleID() {
        XCTAssertEqual(SetupFiles.baseTitleID(in: "Mario Kart World [09D00E8A5D61A000].nsp"), "09D00E8A5D61A000")
        // An update's, and a DLC's.
        XCTAssertEqual(SetupFiles.baseTitleID(in: "[09d00e8a5d61a800] v131072.nsp"), "09D00E8A5D61A000")
        XCTAssertEqual(SetupFiles.baseTitleID(in: "DLC [0100F2C0115B7001].nsp"), "0100F2C0115B6000")
        XCTAssertNil(SetupFiles.baseTitleID(in: "Kirby.nup"))
        XCTAssertNil(SetupFiles.baseTitleID(in: "0100F2C0115B60001.nsp"), "17 digits name no title")
    }

    /// An empty file at PATH, in ROOT or the tests' folder.
    private func write(_ path: String, in root: URL? = nil) throws {
        let url = (root ?? folder).appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data().write(to: url)
    }
}
