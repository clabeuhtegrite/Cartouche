//
//  CartouchePlayTimeTests.swift
//  CartoucheCoreTests
//
//  A game's play time as its counter writes it in its data folder
//  (launcher/Guest/CartouchePlayTimeCounter.m), what Cartouche keeps of it
//  (Sources/CartouchePlayTime.swift), and the space a game takes.
//

import Foundation
import XCTest
@testable import CartoucheCore

final class CartouchePlayTimeTests: XCTestCase {
    private var folder: URL!
    private let night = Date(timeIntervalSince1970: 1_794_281_224)

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("CartouchePlayTimeTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    /// A data folder whose game wrote PLIST, as the counter writes it.
    private func dataFolder(_ name: String, plist: [String: Any]?) throws -> URL {
        let home = folder.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        if let plist {
            let file = home.appendingPathComponent(CartouchePlayTime.file)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try PropertyListSerialization.data(fromPropertyList: plist, format: .binary, options: 0).write(to: file)
        }
        return home
    }

    private func file(_ name: String, bytes: Int, in parent: URL) throws {
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        try Data(repeating: 7, count: bytes).write(to: parent.appendingPathComponent(name))
    }

    func testReadsTheCountersFile() throws {
        let home = try dataFolder("game", plist: [
            "seconds": 3_723.5, "sessions": 3, "firstPlayed": night, "lastPlayed": night + 7_200,
            "lastSession": ["start": night + 3_600, "seconds": 1_200.0], "version": 1,
        ])
        let time = try XCTUnwrap(CartouchePlayTime.read(home: home))
        XCTAssertEqual(time.seconds, 3_723.5)
        XCTAssertEqual(time.sessions, 3)
        XCTAssertEqual(time.firstPlayed, night)
        XCTAssertEqual(time.lastPlayed, night + 7_200)
    }

    func testReadsNothingElse() throws {
        XCTAssertNil(CartouchePlayTime.read(home: try dataFolder("never-played", plist: nil)))
        XCTAssertNil(CartouchePlayTime.read(home: try dataFolder("no-seconds", plist: ["sessions": 2])))
        XCTAssertNil(CartouchePlayTime.read(home: try dataFolder("negative", plist: ["seconds": -1.0])))
        // A later format may mean something else.
        XCTAssertNil(CartouchePlayTime.read(home: try dataFolder("later", plist: ["seconds": 60.0, "version": 2])))
        let broken = try dataFolder("broken", plist: nil)
        let file = broken.appendingPathComponent(CartouchePlayTime.file)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("not a plist".utf8).write(to: file)
        XCTAssertNil(CartouchePlayTime.read(home: broken))
        // A file without sessions or dates still says how long.
        let bare = try XCTUnwrap(CartouchePlayTime.read(home: try dataFolder("bare", plist: ["seconds": 90])))
        XCTAssertEqual(bare.seconds, 90)
        XCTAssertEqual(bare.sessions, 0)
        XCTAssertNil(bare.lastPlayed)
    }

    func testTheSameFolderKeepsTheMostOfEach() {
        let before = CartouchePlayTime(seconds: 600, sessions: 2, firstPlayed: night, lastPlayed: night + 600)
        let after = CartouchePlayTime(seconds: 900, sessions: 3, firstPlayed: night + 60, lastPlayed: night + 3_600)
        XCTAssertEqual(before.merged(with: after),
                       CartouchePlayTime(seconds: 900, sessions: 3, firstPlayed: night, lastPlayed: night + 3_600))
        XCTAssertEqual(after.merged(with: before), before.merged(with: after))
        XCTAssertEqual(before.merged(with: CartouchePlayTime()), before)
    }

    func testTheRecordAddsUpTheDataFolders() {
        var record = CartouchePlayTimeRecord()
        let first = CartouchePlayTime(seconds: 3_600, sessions: 4, firstPlayed: night, lastPlayed: night + 86_400)
        XCTAssertTrue(record.note(first, bundleId: "org.nxnative.0400c3f00006e000", titleId: "0400C3F00006E000", folder: "A"))
        // Read again unchanged: nothing to save.
        XCTAssertFalse(record.note(first, bundleId: "org.nxnative.0400c3f00006e000", titleId: nil, folder: "A"))
        XCTAssertFalse(record.note(CartouchePlayTime(seconds: 60, sessions: 1), bundleId: "org.nxnative.0400c3f00006e000",
                                   titleId: nil, folder: "A"))
        // The game installed again after its saves were erased: a new data
        // folder, whose time adds to the first one's.
        let second = CartouchePlayTime(seconds: 1_800, sessions: 1, firstPlayed: night + 172_800, lastPlayed: night + 174_600)
        XCTAssertTrue(record.note(second, bundleId: "org.nxnative.0400c3f00006e000", titleId: "0400C3F00006E000", folder: "B"))
        let total = CartouchePlayTime(seconds: 5_400, sessions: 5, firstPlayed: night, lastPlayed: night + 174_600)
        XCTAssertEqual(record.total(bundleId: "org.nxnative.0400c3f00006e000"), total)
        // A game only in the games folder, by its IPA's bundle ID or title ID.
        XCTAssertEqual(record.total(bundleId: nil, titleId: "0400C3F00006E000"), total)
        XCTAssertEqual(record.total(bundleId: "org.example.other", titleId: "0400C3F00006E000"), total)
        XCTAssertNil(record.total(bundleId: "org.example.other"))
        XCTAssertNil(record.total(bundleId: nil, titleId: "01006BB00C6F0000"))

        let saved = try? JSONDecoder().decode(CartouchePlayTimeRecord.self, from: JSONEncoder().encode(record))
        XCTAssertEqual(saved, record)
    }

    func testMeasuresFilesButNotLinks() throws {
        let game = folder.appendingPathComponent("game", isDirectory: true)
        try file("a", bytes: 10_000, in: game)
        try file("b", bytes: 5_000, in: game.appendingPathComponent("Documents", isDirectory: true))
        let elsewhere = folder.appendingPathComponent("elsewhere", isDirectory: true)
        try file("big", bytes: 2_000_000, in: elsewhere)
        // As the tmp LiveContainer links in a game's data folder.
        try FileManager.default.createSymbolicLink(at: game.appendingPathComponent("tmp"), withDestinationURL: elsewhere)

        let size = CartoucheGameSize.measure(game)
        XCTAssertGreaterThanOrEqual(size, 15_000)
        XCTAssertLessThan(size, 1_000_000)
        XCTAssertEqual(CartoucheGameSize.measure(folder.appendingPathComponent("missing")), 0)
    }

    func testAGamesFolders() throws {
        let bundle = folder.appendingPathComponent("Game.app", isDirectory: true)
        try file("Info.plist", bytes: 1_000, in: bundle)
        try file("main", bytes: 50_000, in: bundle)
        let played = try dataFolder("A", plist: ["seconds": 120.0, "sessions": 1, "version": 1])
        try file("save.bin", bytes: 20_000, in: played.appendingPathComponent("Documents", isDirectory: true))
        let fresh = try dataFolder("B", plist: nil)
        let folders = CartoucheGameFolders(bundleId: "org.nxnative.0400c3f00006e000", titleId: "0400C3F00006E000",
                                           bundle: bundle, data: ["A": played, "B": fresh])

        XCTAssertEqual(folders.playTimes(), ["A": CartouchePlayTime(seconds: 120, sessions: 1)])
        let size = folders.measure()
        XCTAssertGreaterThanOrEqual(size.bundle, 51_000)
        XCTAssertGreaterThanOrEqual(size.data, 20_000)
        XCTAssertEqual(size.total, size.bundle + size.data)
        // The bundle measured already is not measured again.
        XCTAssertEqual(folders.measure(bundle: 42).bundle, 42)
        XCTAssertEqual(folders.measure(bundle: 42).data, size.data)

        // Another install of the game: another key.
        let key = folders.bundleKey
        XCTAssertEqual(folders.bundleKey, key)
        try file("Info.plist", bytes: 1_200, in: bundle)
        XCTAssertNotEqual(folders.bundleKey, key)
    }
}
