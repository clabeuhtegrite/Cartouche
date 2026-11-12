//
//  EngineAnswerTests.swift
//  BuilderKitTests
//
//  The engine's answers, as the app reads them (Engine.decode and
//  Models.swift): the fixtures are what the engine's commands answered on
//  fake games (builder/tests/test_app_contract.py, which checks that they
//  still have every key the engine writes).
//

import Foundation
import XCTest
@testable import BuilderKit

enum Fixture {
    static let folder = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures", isDirectory: true)

    /// The fixture NAME on one line, as the engine prints its answer.
    static func answer(_ name: String) throws -> Data {
        let data = try Data(contentsOf: folder.appendingPathComponent(name + ".json"))
        return try JSONSerialization.data(withJSONObject: JSONSerialization.jsonObject(with: data))
    }
}

final class EngineAnswerTests: XCTestCase {
    func testBundledIPAAnswerKeepsThePublishedPath() throws {
        let result = RunResult(status: 0, output: Data("{\"api\":1,\"ipa\":\"/Volumes/Games/Example (with ROMFS).ipa\"}\n".utf8))
        let answer = try Engine.decode(BundleIPAAnswer.self, from: result)
        XCTAssertEqual(answer.ipa, "/Volumes/Games/Example (with ROMFS).ipa")
    }

    func testBundledIPAAnswerTellsTheGameForTheMeasurements() throws {
        let line = "{\"api\":1,\"ipa\":\"/Volumes/Games/Example (with ROMFS) [0100152000022000].ipa\",\"title_id\":\"0100152000022000\",\"nxnative\":\"6c3aeb3d70a1\",\"bytes\":5120000000}\n"
        let answer = try Engine.decode(BundleIPAAnswer.self, from: RunResult(status: 0, output: Data(line.utf8)))
        XCTAssertEqual(answer.titleID, "0100152000022000")
        XCTAssertEqual(answer.nxnative, "6c3aeb3d70a1")
        XCTAssertEqual(answer.bytes, 5_120_000_000)
    }

    /// What the engine prints: a tool's line, then its answer.
    private func output(_ name: String) throws -> RunResult {
        var output = Data("Looking at nxnative and the games…\n".utf8)
        output.append(try Fixture.answer(name))
        output.append(10)
        return RunResult(status: 0, output: output)
    }

    private func answer<T: Decodable>(_ type: T.Type, _ name: String) throws -> T {
        try Engine.decode(type, from: output(name))
    }

    func testTheLibraryHasEachKindOfGame() throws {
        let library = try answer(Library.self, "library")
        XCTAssertEqual(library.games.count, 3)
        XCTAssertNotNil(library.checked.flatMap(ISODate.parse))
        XCTAssertEqual(library.engine?.short.count, 12)
        XCTAssertEqual(library.engine?.head.hasPrefix(library.engine?.short ?? "-"), true)
        XCTAssertEqual(library.folders?.games?.present, true)
        XCTAssertEqual(library.folders?.remote, false)

        let due = try XCTUnwrap(library.game("0400C3F00006E000"))
        XCTAssertEqual(due.state, .due)
        XCTAssertEqual(due.kind, "dump")
        XCTAssertTrue(due.canBuild)
        XCTAssertTrue(due.hasIPA)
        XCTAssertEqual(due.changes.count, 2)
        XCTAssertEqual(due.ownChanges.map(\.subject), ["Mario Kart World: the menus (PR #3)"])
        XCTAssertEqual(due.changeCounts?.own, 1)
        XCTAssertNotNil(due.build?.date)
        XCTAssertNil(due.progress)

        let failed = try XCTUnwrap(library.game("0100000000010000"))
        XCTAssertEqual(failed.state, .failed)
        XCTAssertEqual(failed.attempt?.result, "failed")
        XCTAssertEqual(failed.attempt?.error, "the fake build failed on purpose")
        XCTAssertNotNil(failed.attempt?.date)

        let ipaOnly = try XCTUnwrap(library.game("0100A0000E2F0000"))
        XCTAssertEqual(ipaOnly.state, .noSource)
        XCTAssertEqual(ipaOnly.kind, "ipa")
        XCTAssertFalse(ipaOnly.canBuild)
        XCTAssertTrue(ipaOnly.hasIPA)
        XCTAssertEqual(ipaOnly.build?.version, "1.5")

        XCTAssertEqual(library.due.map(\.titleID), ["0400C3F00006E000"])
        XCTAssertEqual(library.failed.map(\.titleID), ["0100000000010000"])
    }

    func testAGameBeingBuiltHasItsProgress() throws {
        let library = try answer(Library.self, "library-building")
        let building = try XCTUnwrap(library.game("0400C3F00006E000"))
        XCTAssertEqual(building.state, .building)
        let progress = try XCTUnwrap(building.progress)
        XCTAssertEqual(progress.state, "building")
        XCTAssertFalse((progress.stage ?? "").isEmpty)
        XCTAssertNotNil(progress.startedDate)
    }

    func testTheBatches() throws {
        let done = try XCTUnwrap(try answer(StatusAnswer.self, "status").status)
        XCTAssertEqual(done.state, "done")
        XCTAssertFalse(done.isRunning)
        XCTAssertEqual(done.running, false)
        XCTAssertEqual(done.finished.map(\.state), ["failed"])
        XCTAssertEqual(done.finished.first?.error, "the fake build failed on purpose")
        XCTAssertNotNil(done.endedDate)
        // Why it failed, as names and numbers, and the commit it was built from.
        let failed = try XCTUnwrap(done.finished.first)
        XCTAssertEqual(failed.cause, "nxnative")
        XCTAssertEqual(failed.exit, 1)
        XCTAssertEqual(failed.commit?.count, 12)
        XCTAssertEqual(failed.fallback, false)
        XCTAssertNotNil(failed.duration)
        XCTAssertNil(done.fallback)
        XCTAssertEqual(BuilderTelemetry.fields(cause: failed.cause, exit: failed.exit, failure: failed.failure),
                       ["cause": .text("nxnative"), "exit": .count(1)])

        let building = try XCTUnwrap(try answer(StatusAnswer.self, "status-building").status)
        XCTAssertTrue(building.isRunning)
        XCTAssertEqual(building.running, true)
        XCTAssertEqual(building.current.map(\.titleID), ["0400C3F00006E000"])
        XCTAssertTrue(building.queued.isEmpty)
        XCTAssertFalse(building.lines.isEmpty)
    }

    /// A batch on the last nxnative commit that built on this Mac, its
    /// newest not building (cartouche_builder/fallback.py), and a game
    /// skipped for a full disk.
    func testABatchOnTheLastCommitThatBuilt() throws {
        let json = #"""
            {"state": "done", "head": "6da69001c0ffee00", "latest": "7867152deadbeef0",
             "fallback": {"from": "7867152deadbeef0", "to": "6da69001c0ffee00"},
             "games": [{"title_id": "0100152000022000", "name": "A game", "state": "built", "commit": "6da69001c0ff", "fallback": true},
                       {"title_id": "01007EF00011E000", "name": "A third", "state": "failed", "commit": "6da69001c0ff", "fallback": true,
                        "cause": "app_build", "exit": 1, "error": "xcodebuild failed (exit 65)"},
                       {"title_id": "010093801237C000", "name": "Another", "state": "skipped", "cause": "no_space", "exit": 1, "failure": {},
                        "commit": "6da69001c0ff", "fallback": true, "error": "Your Mac's disk is full (0.4 GB left)."}]}
            """#
        let status = try JSONDecoder().decode(BatchStatus.self, from: Data(json.utf8))
        XCTAssertEqual(status.fallback, BatchFallback(from: "7867152deadbeef0", to: "6da69001c0ffee00"))
        XCTAssertEqual(status.latest, "7867152deadbeef0")
        XCTAssertEqual(status.games.count, 3)
        XCTAssertEqual(status.games.first?.fallback, true)
        XCTAssertEqual(status.games.first?.commit, "6da69001c0ff")
        XCTAssertEqual(status.games.last?.cause, "no_space")
        XCTAssertEqual(status.games.last?.failure, FailureDetails())
        // What the activity shows of each: the commit a game was built from
        // while the newest does not build, and why a game failed, or was
        // skipped.
        XCTAssertEqual(status.games.map(\.fallbackCommit), ["6da69001c0ff", nil, nil])
        XCTAssertEqual(status.games.map(\.shownError), [nil, "xcodebuild failed (exit 65)", "Your Mac's disk is full (0.4 GB left)."])
        // What an older engine wrote still reads.
        let older = try JSONDecoder().decode(BatchStatus.self, from: Data(#"{"state": "done", "fallback": "not one", "games": []}"#.utf8))
        XCTAssertNil(older.fallback)
        // What the telemetry may say of it: names and numbers it checks.
        XCTAssertEqual(BuilderTelemetry.fields(cause: "No space on /Volumes/Jeux", exit: 99_999, failure: nil), [:])
        XCTAssertEqual(BuilderTelemetry.commit("6DA69001C0FFEE00"), "6da69001c0ff")
        XCTAssertNil(BuilderTelemetry.commit("not a commit"))

        let held = try JSONDecoder().decode(EngineCommit.self, from: Data(#"""
            {"head": "6da69001c0ffee00", "short": "6da69001c0ff", "latest": "7867152deadbeef0", "latest_short": "7867152deadb", "held": true}
            """#.utf8))
        XCTAssertEqual(held.heldBehind, "7867152deadb")
        let current = try JSONDecoder().decode(EngineCommit.self, from: Data(#"{"head": "6da69001c0ffee00", "short": "6da69001c0ff"}"#.utf8))
        XCTAssertNil(current.heldBehind)
    }

    func testAFullDiskInThePlayersWords() {
        let posix = NSError(domain: NSPOSIXErrorDomain, code: Int(ENOSPC))
        XCTAssertTrue(DiskSpace.isFull(NSError(domain: NSCocoaErrorDomain, code: NSFileWriteOutOfSpaceError)))
        XCTAssertTrue(DiskSpace.isFull(NSError(domain: NSCocoaErrorDomain, code: NSFileWriteUnknownError, userInfo: [NSUnderlyingErrorKey: posix])))
        XCTAssertFalse(DiskSpace.isFull(NSError(domain: NSCocoaErrorDomain, code: NSFileWriteNoPermissionError)))
        XCTAssertFalse(DiskSpace.isFull(EngineFailure(kind: "no_space", message: "Your Mac's disk is full.")))
        defer { L10n.use("") }
        L10n.use("fr")
        XCTAssertEqual(DiskSpace.amount(412_000_000), "0,4 Go")
        XCTAssertEqual(DiskSpace.message(free: 412_000_000),
                       "Le disque du Mac est plein (il reste 0,4 Go). Libérez de la place, par exemple dans Stockage, puis réessayez.")
        L10n.use("en")
        XCTAssertEqual(DiskSpace.amount(12_400_000_000), "12 GB")
        XCTAssertEqual(DiskSpace.message(free: nil), "Your Mac's disk is full. Free some room, on the Storage page for example, then try again.")
        XCTAssertNotNil(DiskSpace.free(at: URL(fileURLWithPath: NSTemporaryDirectory())))
        // What the app shows of an error: a full disk in these words, not
        // Cocoa's; the engine's own words; another error's.
        let temporary = URL(fileURLWithPath: NSTemporaryDirectory())
        XCTAssertTrue(DiskSpace.words(for: posix, at: temporary).hasPrefix("Your Mac's disk is full ("), DiskSpace.words(for: posix, at: temporary))
        XCTAssertTrue(DiskSpace.words(for: NSError(domain: NSCocoaErrorDomain, code: NSFileWriteOutOfSpaceError), at: temporary).hasPrefix("Your Mac's disk is full ("))
        XCTAssertEqual(DiskSpace.words(for: EngineFailure(kind: "no_space", message: "The disk “NAS” is full. Free some room on it, then try again.")),
                       "The disk “NAS” is full. Free some room on it, then try again.")
        let denied = NSError(domain: NSCocoaErrorDomain, code: NSFileWriteNoPermissionError)
        XCTAssertEqual(DiskSpace.words(for: denied), denied.localizedDescription)
    }

    func testTheQueue() throws {
        let reply = try answer(QueueAnswer.self, "queue")
        XCTAssertEqual(reply.queued, true)
        XCTAssertEqual(reply.running, true)
        let queue = reply.queue
        XCTAssertEqual(queue.games.map(\.titleID), ["0100000000010000"])
        XCTAssertEqual(queue.games.first?.force, true)
        XCTAssertEqual(queue.stop, ["0100A0000E2F0000"])
        let batch = try XCTUnwrap(queue.games.first?.batch)
        XCTAssertEqual(queue.waiting(for: batch), ["0100000000010000"])
        XCTAssertEqual(queue.waiting(for: batch + 1), [], "asked of a batch that ended")
        // queue.json is the answer's queue, and no file is none.
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Fixture.answer("queue")) as? [String: Any])
        let file = try JSONSerialization.data(withJSONObject: XCTUnwrap(object["queue"]))
        XCTAssertEqual(try JSONDecoder().decode(BuildQueue.self, from: file), queue)
        let home = BuilderHome(FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        XCTAssertEqual(Engine.readQueue(home), BuildQueue())
    }

    func testStorageSettingsAndFolders() throws {
        let storage = try answer(StorageAnswer.self, "storage").storage
        XCTAssertEqual(storage.folders.count, 2)
        XCTAssertEqual(storage.ipaCopies.count, 2)
        XCTAssertNotNil(storage.workspaceDisk)
        XCTAssertNotNil(storage.gamesDisk)
        XCTAssertEqual(storage.buildFolders, storage.folders.reduce(0) { $0 + $1.size })
        XCTAssertEqual(storage.settings?.keepExtracted, false)
        XCTAssertTrue(storage.ipaCopies.allSatisfy(\.sameDisk))

        let answer = try answer(ConfigAnswer.self, "config")
        XCTAssertEqual(answer.config.jobs, 1)
        XCTAssertEqual(answer.config.enginePolicy, "weekly")
        XCTAssertTrue(answer.config.setupDone)
        XCTAssertFalse(answer.builder.version.isEmpty)
        var changed = answer.config
        changed.jobs = 2
        changed.keepExtracted = true
        changed.setupDone = false
        XCTAssertEqual(Set(changed.changes(from: answer.config).keys), ["jobs", "keep_extracted", "setup_done"])
        // Settings that do not say it: the setup assistant opens.
        let older = try JSONDecoder().decode(BuilderConfig.self, from: Data(#"{"sources": "/s", "games": "/g"}"#.utf8))
        XCTAssertFalse(older.setupDone)

        XCTAssertEqual(try self.answer(MountAnswer.self, "mount").folders.sources?.present, true)
        XCTAssertEqual(try self.answer(CleanAnswer.self, "clean").cleaned.freed, 0)
        XCTAssertEqual(try self.answer(FollowAnswer.self, "follow").followed, true)
    }

    func testWhatGoesWrongIsAFailureOfItsKind() throws {
        XCTAssertThrowsError(try answer(ConfigAnswer.self, "error")) { error in
            XCTAssertEqual((error as? EngineFailure)?.kind, "bad_request")
        }
        let crash = RunResult(status: 1, errors: Data("Traceback (most recent call last):\n  ...\nKeyError: 'x'\n".utf8))
        XCTAssertThrowsError(try Engine.decode(Library.self, from: crash)) { error in
            XCTAssertEqual((error as? EngineFailure)?.kind, "crashed")
            XCTAssertEqual((error as? EngineFailure)?.details, FailureDetails(exception: "KeyError"))
            XCTAssertEqual((error as? EngineFailure)?.exit, 1)
        }
        let slow = RunResult(status: 15, timedOut: true)
        XCTAssertThrowsError(try Engine.decode(Library.self, from: slow)) { error in
            XCTAssertEqual((error as? EngineFailure)?.kind, "timeout")
        }
        let odd = RunResult(status: 0, output: Data("{\"api\": 1, \"storage\": 3}\n".utf8))
        XCTAssertThrowsError(try Engine.decode(StorageAnswer.self, from: odd)) { error in
            XCTAssertEqual((error as? EngineFailure)?.kind, "unreadable")
        }
    }

    func testAFailureSaysItsExceptionWhereAndErrnoNeverItsWords() throws {
        let answer = #"{"error": {"kind": "failed", "message": "PermissionError: [Errno 13] Permission denied: '/Users/player/Jeux'", "#
            + #""exception": "PermissionError", "where": "storage.survey", "errno": 13}}"#
        XCTAssertThrowsError(try Engine.decode(Library.self, from: RunResult(status: 3, output: Data((answer + "\n").utf8)))) { error in
            let failure = error as? EngineFailure
            XCTAssertEqual(failure?.kind, "failed")
            XCTAssertEqual(failure?.details, FailureDetails(exception: "PermissionError", place: "storage.survey", errorNumber: 13))
            XCTAssertNil(failure?.exit)
            XCTAssertEqual(failure.map { BuilderTelemetry.fields(of: $0.details) },
                           ["exception": .text("PermissionError"), "where": .text("storage.survey"), "errno": .count(13)])
        }
        // An older engine says none of it; whatever else it says is left out.
        let older = try JSONDecoder().decode(EngineFailure.self, from: Data(#"{"kind": "engine", "message": "git failed"}"#.utf8))
        XCTAssertTrue(older.details.isEmpty)
        let odd = FailureDetails(exception: "No space left on /Volumes/Jeux", place: "/Users/player/x.py", errorNumber: -1)
        XCTAssertEqual(BuilderTelemetry.fields(of: odd), [:])
        // A batch that failed says it in status.json.
        let status = try JSONDecoder().decode(BatchStatus.self, from: Data(#"{"state": "failed", "failure": {"exception": "OSError", "errno": 28}}"#.utf8))
        XCTAssertEqual(status.failure, FailureDetails(exception: "OSError", errorNumber: 28))
    }

    func testTheExceptionATracebackEndsOn() {
        let chained = """
            Traceback (most recent call last):
              File "/Users/player/Builder/engine/cartouche_builder/batch.py", line 3, in run
                raise OSError(28, "No space left")
            OSError: [Errno 28] No space left on device: '/Volumes/Jeux'

            During handling of the above exception, another exception occurred:

            Traceback (most recent call last):
              File "/Users/player/Builder/engine/cartouche_builder/cli.py", line 9, in main
                    ^^^^^^^^^
            cartouche_builder.engine.EngineError: git fetch failed for /Users/player/nxnative
            """
        XCTAssertEqual(FailureDetails.exception(in: chained), "EngineError")
        XCTAssertEqual(FailureDetails.exception(in: "Traceback (most recent call last):\n  File \"x.py\"\nKeyboardInterrupt\n"), "KeyboardInterrupt")
        XCTAssertNil(FailureDetails.exception(in: "Note: something went wrong\nError: no such folder /Users/player"))
        XCTAssertNil(FailureDetails.exception(in: "Traceback (most recent call last):\n  File \"x.py\"\nNo space left on /Volumes/Jeux: what now\n"))
        XCTAssertEqual(FailureDetails.place("library.scan"), "library.scan")
        XCTAssertNil(FailureDetails.place("library"))
        XCTAssertNil(FailureDetails.place("a.b.c"))
    }

    func testAGameStateTheAppDoesNotKnowIsUnknown() throws {
        let data = Data(#"{"title_id": "0100000000010000", "name": "A game", "state": "something_new"}"#.utf8)
        let game = try JSONDecoder().decode(Game.self, from: data)
        XCTAssertEqual(game.state, .unknown)
        XCTAssertTrue(game.followed)
        XCTAssertEqual(game.reasons, [])
    }
}
