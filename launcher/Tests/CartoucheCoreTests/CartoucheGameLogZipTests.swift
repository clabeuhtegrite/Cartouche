//
//  CartoucheGameLogZipTests.swift
//  CartoucheCoreTests
//
//  The zip the share sheet shares of a game's logs
//  (Sources/CartoucheGameLogZip.swift): the summary, then the logs byte for
//  byte as the game wrote them, paths, nickname and crash memory included,
//  as the player chose; and nothing left behind when it cannot be made.
//

import Foundation
import XCTest
@testable import CartoucheCore

final class CartoucheGameLogZipTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    func testTheZipHoldsTheSummaryAndTheLogsAsTheGameWroteThem() async throws {
        let documents = folder.appendingPathComponent("Documents", isDirectory: true)
        try FileManager.default.createDirectory(at: documents, withIntermediateDirectories: true)
        let last = "boot: game files /private/var/mobile/Containers/Data/Application/0F1E2D3C-4B5A-6978-8796-A5B4C3D2E1F0/Documents/romfs.img\n"
            + "boot: env DM_NICK=Lou (env.txt)\n"
            + String(repeating: "[dm] [nvn] frame interval up to frame 300: >16.7ms 6 / 300 frames, p99 33.40 ms\n", count: 2_000)
            + "[dm] *x1: 0x16fdff200 main+0x40 0 0x6c6c6548206f6c6c 0x1 0x16fdff300\n"
        let before = "boot: cloud saves through /private/var/mobile/Library/Mobile Documents/com~apple~CloudDocs/Saves d'Élodie\n"
        try Data(last.utf8).write(to: documents.appendingPathComponent("log.txt"))
        try Data(before.utf8).write(to: documents.appendingPathComponent("log.prev.txt"))
        let logs = CartoucheGameLogFolder(game: "Mario Kart World", documents: documents).files
        let summary = "Cartouche game log, 2026-11-13 21:05:00 +0100\nGame: Mario Kart World\n\n" + CartoucheGameLogShare.rawNote
        let out = folder.appendingPathComponent("Out", isDirectory: true)

        let zip = try await CartoucheGameLogShare.writeZip(named: "Mario Kart World log 2026-11-13 2105.zip", summary: summary,
                                                           logs: logs, in: out)

        XCTAssertEqual(zip.lastPathComponent, "Mario Kart World log 2026-11-13 2105.zip")
        let source = try CartoucheFileSource(zip)
        let entries = try await CartoucheZip.entries(of: source)
        XCTAssertEqual(entries.map(\.name), ["about.txt", "log.txt", "log.prev.txt"])
        var contents: [String: String] = [:]
        for entry in entries {
            contents[entry.name] = String(decoding: try await CartoucheZip.data(of: entry, in: source), as: UTF8.self)
        }
        XCTAssertEqual(contents["about.txt"], summary)
        XCTAssertEqual(contents["log.txt"], last)
        XCTAssertEqual(contents["log.prev.txt"], before)
        // The copies it zipped from are gone: the zip alone stays.
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: out.path), [zip.lastPathComponent])
    }

    func testAZipThatCannotBeMadeLeavesNothing() async throws {
        let out = folder.appendingPathComponent("Out", isDirectory: true)
        do {
            _ = try await CartoucheGameLogShare.writeZip(named: "Game log.zip", summary: "Cartouche game log",
                                                         logs: [folder.appendingPathComponent("log.txt")], in: out)
            XCTFail("a log that is not there is zipped")
        } catch {}
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: out.path), [])
    }
}
