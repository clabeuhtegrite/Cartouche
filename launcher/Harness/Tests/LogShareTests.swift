//
//  LogShareTests.swift
//  CartoucheHarnessTests
//
//  A game's log, shared from its sheet (CartoucheGameLogView, decision
//  101): where Cartouche finds the logs nxnative writes, in the data folder
//  the game plays with, once it has played; the zip the share sheet
//  shares, with the logs in it as the game wrote them; and what Send to
//  Cartouche would send of them, cleaned of the device's paths and the
//  player's nickname.
//

import XCTest
@testable import CartoucheHarness

final class LogShareTests: HarnessCase {
    override func setUp() async throws {
        try await super.setUp()
        // The game starts in Cartouche's place, and is done with at once.
        CartoucheGameKeeping.shared.keepsConsoleOpen = false
    }

    func testAGamesLogsAreFoundWhereItPlaysAndSharedAsTheGameWroteThem() async throws {
        let game = HarnessGame.plain()
        let app = try await installed(game)
        XCTAssertTrue(actions.logs(of: app)?.files.isEmpty ?? true, "a game that never played has no log")

        actions.play(app)
        try await waitUntil("the start is over") { actions.work == nil }
        let folder = try dataFolder(of: app)
        // As nxnative writes them: the last session, which crashed, and
        // the one before.
        let last = "boot: game files \(folder.path)/Documents/romfs.img\n"
            + "boot: env DM_NICK=Lou (env.txt)\n"
            + "[dm] CRASH sig=11 addr=0x10 pc=main+0x1a2b3c lr=main+0x1a2b00 sp=0x16fdff000\n"
            + "[dm] *x1: 0x16fdff200 main+0x40 0 0x6c6c6548206f6c6c 0x1 0x16fdff300\n"
        let before = "boot: game files \(folder.path)/Documents/romfs.img\n"
        try write(before, in: folder, at: "Documents/log.prev.txt")
        try write(last, in: folder, at: "Documents/log.txt")

        let logs = try XCTUnwrap(actions.logs(of: app), "an nxnative game's logs")
        XCTAssertEqual(logs.files.map(\.lastPathComponent), ["log.txt", "log.prev.txt"])
        XCTAssertEqual(logs.documents.resolvingSymlinksInPath(),
                       folder.appendingPathComponent("Documents", isDirectory: true).resolvingSymlinksInPath())
        XCTAssertEqual(logs.game, app.displayName)
        XCTAssertEqual(logs.titleId, game.titleId)
        XCTAssertEqual(logs.build?.version, game.version)

        let digests = logs.files.compactMap { CartoucheGameLogDigest.read($0, name: $0.lastPathComponent) }
        XCTAssertEqual(digests.map(\.lines), [4, 1])
        let share = CartoucheGameLogView.share(of: logs, logs: digests)
        XCTAssertTrue(share.summary.contains("Game: \(app.displayName) (\(game.titleId))"), share.summary)
        XCTAssertTrue(share.summary.contains("    Crash: [dm] CRASH sig=11"), share.summary)

        // The share sheet's zip: the logs as the game wrote them.
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("HarnessGameLogs", isDirectory: true)
        try? FileManager.default.removeItem(at: out)
        defer { try? FileManager.default.removeItem(at: out) }
        let name = CartoucheGameLogShare.fileName(game: logs.game, date: share.date)
        let zip = try await CartoucheGameLogShare.writeZip(named: name, summary: share.summary, logs: logs.files, in: out)
        let source = try CartoucheFileSource(zip)
        let entries = try await CartoucheZip.entries(of: source)
        XCTAssertEqual(entries.map(\.name), ["about.txt", "log.txt", "log.prev.txt"])
        var zipped: [String: String] = [:]
        for entry in entries {
            zipped[entry.name] = String(decoding: try await CartoucheZip.data(of: entry, in: source), as: UTF8.self)
        }
        XCTAssertEqual(zipped["log.txt"], last)
        XCTAssertEqual(zipped["log.prev.txt"], before)
        XCTAssertEqual(zipped["about.txt"], share.summary)

        // Send to Cartouche: the same logs, cleaned.
        let submission = try XCTUnwrap(share.submission(id: CartoucheProblemSubmission.newID()))
        XCTAssertFalse(submission.logs.contains(folder.path), submission.logs)
        XCTAssertFalse(submission.logs.contains("DM_NICK=Lou"), submission.logs)
        XCTAssertFalse(submission.logs.contains("6c6c6548206f6c6c"), submission.logs)
        XCTAssertTrue(submission.logs.contains("boot: env DM_NICK=<name> (env.txt)"), submission.logs)
        XCTAssertTrue(submission.logs.contains("[dm] CRASH sig=11 addr=0x10 pc=main+0x1a2b3c"), submission.logs)
        XCTAssertTrue(submission.title.hasPrefix(app.displayName + " log, Cartouche "), submission.title)
    }
}
