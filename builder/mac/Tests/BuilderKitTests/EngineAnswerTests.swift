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

        let building = try XCTUnwrap(try answer(StatusAnswer.self, "status-building").status)
        XCTAssertTrue(building.isRunning)
        XCTAssertEqual(building.running, true)
        XCTAssertEqual(building.current.map(\.titleID), ["0400C3F00006E000"])
        XCTAssertTrue(building.queued.isEmpty)
        XCTAssertFalse(building.lines.isEmpty)
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

    func testAGameStateTheAppDoesNotKnowIsUnknown() throws {
        let data = Data(#"{"title_id": "0100000000010000", "name": "A game", "state": "something_new"}"#.utf8)
        let game = try JSONDecoder().decode(Game.self, from: data)
        XCTAssertEqual(game.state, .unknown)
        XCTAssertTrue(game.followed)
        XCTAssertEqual(game.reasons, [])
    }
}
