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

        // Each built for the iPhone and for this Mac: Mario Kart World's
        // Mac app, which failed before, after its IPA; Super Mario Odyssey's,
        // built before, once its IPA builds again; Hollow Knight, an IPA
        // alone, has none.
        XCTAssertEqual(library.games.map(\.platforms), Array(repeating: GamePlatforms(ios: true, mac: true), count: 3))
        XCTAssertTrue(due.onIOS && due.onMac)
        let dueMac = try XCTUnwrap(due.mac)
        XCTAssertEqual(dueMac.reason, "with_ipa")
        XCTAssertTrue(dueMac.due)
        XCTAssertFalse(dueMac.alone)
        XCTAssertFalse(dueMac.hasApp)
        XCTAssertEqual(dueMac.attempt?.result, "failed")
        XCTAssertNotNil(dueMac.attempt?.date)
        XCTAssertFalse(dueMac.detail.isEmpty)
        XCTAssertFalse(due.hasMacApp)
        let built = try XCTUnwrap(failed.mac)
        XCTAssertEqual(built.reason, "after_ipa")
        XCTAssertFalse(built.due)
        XCTAssertTrue(built.hasApp)
        XCTAssertEqual(built.app?.name, "Super Mario Odyssey.app")
        // In the games folder beside its IPA, on this Mac's own disk: played
        // from there.
        XCTAssertEqual(built.app?.path, built.folder + "/Super Mario Odyssey.app")
        XCTAssertEqual(built.folder, library.folders?.games?.path)
        XCTAssertFalse(built.packed)
        XCTAssertEqual(built.library, built.app)
        XCTAssertFalse(built.behind)
        XCTAssertTrue(built.kept && built.playable)
        XCTAssertFalse(built.needsInstall)
        XCTAssertEqual(built.build?.commit.count, 12)
        XCTAssertNotNil(built.build?.date)
        XCTAssertTrue(failed.hasMacApp)
        XCTAssertEqual(ipaOnly.mac?.reason, "")
        XCTAssertFalse(ipaOnly.hasMacApp)
        XCTAssertEqual(Set(library.games.compactMap { $0.mac?.folder }).count, 1)
    }

    /// A game of an engine older than the Mac's builds: its IPA alone.
    func testAGameOfAnOlderEngineIsBuiltForTheIPhoneAlone() throws {
        let game = try JSONDecoder().decode(Game.self, from: Data(#"{"title_id": "0100152000022000", "name": "A game", "state": "up_to_date"}"#.utf8))
        XCTAssertNil(game.platforms)
        XCTAssertNil(game.mac)
        XCTAssertTrue(game.onIOS)
        XCTAssertFalse(game.onMac)
        XCTAssertFalse(game.hasMacApp)
        // Built for this Mac alone.
        let mac = try JSONDecoder().decode(Game.self, from: Data(#"""
            {"title_id": "0100152000022000", "name": "A game", "state": "due", "reasons": ["new"], "platforms": {"ios": false, "mac": true},
             "mac": {"folder": "/Users/player/Applications", "due": true, "alone": true, "reason": "new", "detail": "Never built"}}
            """#.utf8))
        XCTAssertFalse(mac.onIOS)
        XCTAssertTrue(mac.onMac)
        XCTAssertEqual(mac.mac, GameMac(folder: "/Users/player/Applications", due: true, alone: true, reason: "new", detail: "Never built"))
        // What is not as the engine writes it reads as nothing.
        let odd = try JSONDecoder().decode(Game.self, from: Data(#"{"title_id": "0100152000022000", "name": "A game", "state": "due", "platforms": 3, "mac": {"due": "yes"}}"#.utf8))
        XCTAssertNil(odd.platforms)
        XCTAssertEqual(odd.mac, GameMac())
    }

    /// A games folder on a NAS: the game's app kept there in one file, this
    /// Mac's copy installed from it to be played.
    func testAMacAppKeptOnANAS() throws {
        let library = try answer(Library.self, "library-nas")
        let mac = try XCTUnwrap(library.game("0400C3F00006E000")?.mac)
        XCTAssertTrue(mac.packed)
        XCTAssertEqual(mac.library?.name, "Mario Kart World [0400C3F00006E000].app.zip")
        XCTAssertEqual(mac.library?.path, mac.folder + "/Mario Kart World [0400C3F00006E000].app.zip")
        XCTAssertEqual(mac.app?.path, mac.installs + "/Mario Kart World.app")
        XCTAssertTrue(mac.hasApp && mac.kept && mac.playable)
        XCTAssertFalse(mac.behind)
        XCTAssertFalse(mac.needsInstall)
        // Not installed, or of an older build: installed first.
        var away = mac
        away.app = nil
        XCTAssertTrue(away.playable && away.needsInstall)
        var older = mac
        older.behind = true
        XCTAssertTrue(older.needsInstall)
        // Its file no longer in the games folder: nothing to play until it
        // is built again.
        let odyssey = try XCTUnwrap(library.game("0100000000010000")?.mac)
        XCTAssertTrue(odyssey.packed)
        XCTAssertFalse(odyssey.kept || odyssey.playable)

        let installed = try answer(MacInstallAnswer.self, "mac-install")
        XCTAssertEqual(installed.titleID, "0400C3F00006E000")
        XCTAssertEqual(installed.app.path, mac.app?.path)
        XCTAssertEqual(installed.bytes, Int64(installed.app.size))
        XCTAssertNotNil(installed.seconds)

        let storage = try answer(StorageAnswer.self, "storage-nas").storage
        let copy = try XCTUnwrap(storage.apps.first { $0.titleID == "0400C3F00006E000" })
        XCTAssertTrue(copy.isInstalledCopy)
        XCTAssertEqual(copy.path, mac.app?.path)
        XCTAssertEqual(storage.macAppsDisk?.path, mac.installs)
        XCTAssertEqual(try answer(ConfigAnswer.self, "config-nas").builder.macPacked, true)
    }

    /// The room on the build folders' disk, said before a build would be
    /// skipped for it (disks.py, room): the card only when it falls short.
    func testTheLibrarySaysTheRoomBeforeABuild() throws {
        let short = try XCTUnwrap(try answer(Library.self, "library").room)
        XCTAssertEqual(short.freeGB, 13)
        XCTAssertEqual(short.keepGB, 20)
        XCTAssertEqual(short.folders, 2)
        XCTAssertEqual(short.shortfall?.title, "7 GB missing to build")
        XCTAssertTrue(short.shortfall?.text.hasPrefix("Cartouche Builder starts a build only with 20 GB free on your Mac's disk") ?? false)
        let enough = try XCTUnwrap(try answer(Library.self, "library-building").room)
        XCTAssertNil(enough.shortfall)
        // A disk that cannot be read (a share not connected), or an engine
        // older than the card: no card.
        let line = #"{"api": 1, "games": [], "room": null}"#
        XCTAssertNil(try Engine.decode(Library.self, from: RunResult(status: 0, output: Data(line.utf8))).room)
        let odd = #"{"api": 1, "games": [], "room": "13 GB"}"#
        XCTAssertNil(try Engine.decode(Library.self, from: RunResult(status: 0, output: Data(odd.utf8))).room)
    }

    /// The Xcode nxnative builds the shaders with, as its checkout says
    /// (toolchain.py, wanted_xcode): the page "This Mac's tools" asks for it.
    func testTheDoctorSaysTheXcodeNxnativeWants() throws {
        let line = #"{"api": 1, "ready": false, "engine": true, "xcode": "27.2", "checks": [{"key": "xcode", "label": "Xcode", "ok": false, "found": "27.1 (27B44)", "fix": "Xcode 27.1 is older than Xcode 27.2.", "command": "", "blocking": true}]}"#
        let doctor = try Engine.decode(Doctor.self, from: RunResult(status: 0, output: Data(line.utf8)))
        XCTAssertEqual(doctor.xcode, "27.2")
        XCTAssertEqual(doctor.checks.first?.blocking, true)
        let older = #"{"api": 1, "ready": true, "checks": []}"#
        XCTAssertNil(try Engine.decode(Doctor.self, from: RunResult(status: 0, output: Data(older.utf8))).xcode)
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
        // Its IPA first, its Mac app waiting.
        let game = try XCTUnwrap(building.current.first)
        XCTAssertEqual(game.mac, "waiting")
        XCTAssertEqual(game.macOnly, false)
        XCTAssertEqual(game.platform, "ios")
        XCTAssertTrue(game.buildsMac)
        XCTAssertFalse(game.onMacNow)
        XCTAssertNil(game.shownMacError)
        XCTAssertEqual(failed.mac, "")
        XCTAssertFalse(failed.buildsMac)
    }

    /// The Mac apps of a batch: one after its IPA, which failed, the IPA
    /// staying built; one built for this Mac alone, which failed, its
    /// error being the game's own; one building now.
    func testTheMacAppsOfABatch() throws {
        let json = #"""
            {"state": "building", "games": [
               {"title_id": "0100152000022000", "name": "A game", "state": "built", "ipa": "/Volumes/Jeux/A game.ipa", "platform": "mac",
                "mac": "failed", "mac_only": false, "mac_error": "The disk “Games SSD” is full.", "mac_cause": "no_space", "mac_exit": 1,
                "mac_duration": 312.4, "mac_log": "/x/mac.log", "mac_failure": {}},
               {"title_id": "01007EF00011E000", "name": "Another", "state": "failed", "error": "the Mac host did not build", "platform": "mac",
                "mac": "failed", "mac_only": true, "mac_error": "the Mac host did not build", "mac_cause": "nxnative", "mac_exit": 1},
               {"title_id": "010093801237C000", "name": "A third", "state": "building", "stage": "Mac shaders", "platform": "mac",
                "mac": "building", "mac_only": false, "mac_exit": null}]}
            """#
        let status = try JSONDecoder().decode(BatchStatus.self, from: Data(json.utf8))
        XCTAssertEqual(status.games.map(\.buildsMac), [true, true, true])
        XCTAssertEqual(status.games.map(\.onMacNow), [true, true, true])
        XCTAssertEqual(status.games.map(\.shownMacError), ["The disk “Games SSD” is full.", nil, nil])
        XCTAssertEqual(status.games.map(\.shownError), [nil, "the Mac host did not build", nil])
        XCTAssertEqual(status.games[0].macDuration, 312.4)
        XCTAssertEqual(status.games[0].macFailure, FailureDetails())
        XCTAssertEqual(status.current.map(\.titleID), ["010093801237C000"])
    }

    /// What the activity page says a stage is of, for a game built for the
    /// iPhone and for this Mac: only when the stage's words do not say it.
    func testTheStageOfABuildForBothSaysWhatItIsOf() throws {
        func progress(_ stage: String, on platform: String, mac: String? = "building", macOnly: Bool = false) throws -> GameProgress {
            var fields: [String: Any] = ["title_id": "0100152000022000", "name": "A game", "state": "building", "stage": stage, "platform": platform,
                                         "mac_only": macOnly]
            if let mac { fields["mac"] = mac }
            return try JSONDecoder().decode(GameProgress.self, from: JSONSerialization.data(withJSONObject: fields))
        }
        // Its IPA first: the stages that do not name the iPhone.
        XCTAssertEqual(try progress("extract", on: "ios").shownPlatform, .iPhone)
        XCTAssertEqual(try progress("deliver", on: "ios").shownPlatform, .iPhone)
        XCTAssertEqual(try progress("", on: "ios").shownPlatform, .iPhone)
        XCTAssertNil(try progress("shaders", on: "ios").shownPlatform)
        XCTAssertNil(try progress("ipa", on: "ios").shownPlatform)
        // Then its app for this Mac, whose stages name it but the builder's own.
        XCTAssertNil(try progress("Mac shaders", on: "mac").shownPlatform)
        XCTAssertNil(try progress("mac_deliver", on: "mac").shownPlatform)
        XCTAssertEqual(try progress("deliver", on: "mac").shownPlatform, .mac)
        // Built for one of the two: nothing to tell apart.
        XCTAssertNil(try progress("extract", on: "ios", mac: nil).shownPlatform)
        XCTAssertNil(try progress("extract", on: "mac", macOnly: true).shownPlatform)
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
        // Each game built for the iPhone and for this Mac, its app in the
        // Applications folder of the player's session; one of the two off,
        // for every game or for one.
        XCTAssertTrue(answer.config.ios)
        XCTAssertTrue(answer.config.mac)
        XCTAssertEqual(answer.config.skipIOS, [])
        XCTAssertEqual(answer.config.skipMac, [])
        XCTAssertEqual(answer.config.macApps, "")
        XCTAssertTrue(older.ios && older.mac)
        XCTAssertEqual(answer.builder.macApps, answer.builder.defaultMacApps)
        XCTAssertEqual(answer.builder.macApps?.hasSuffix("/Applications"), true)
        var macOff = answer.config
        macOff.mac = false
        macOff.skipIOS = ["0100000000010000"]
        macOff.macApps = "/Volumes/Games SSD/Apps"
        XCTAssertEqual(Set(macOff.changes(from: answer.config).keys), ["mac", "skip_ios", "mac_apps"])
        XCTAssertFalse(macOff.onMac("0400C3F00006E000"))
        XCTAssertFalse(macOff.onIOS("0100000000010000"))
        XCTAssertTrue(macOff.onIOS("0400c3f00006e000"))

        // The games' Mac apps: Super Mario Odyssey's, whose game files no
        // longer share their room with its build folder.
        XCTAssertEqual(storage.apps.map(\.titleID), ["0100000000010000"])
        let app = try XCTUnwrap(storage.apps.first)
        XCTAssertEqual(app.name, "Super Mario Odyssey")
        XCTAssertTrue(app.on)
        XCTAssertEqual(app.sharesBuild, false)
        XCTAssertTrue(app.path.hasSuffix("/Super Mario Odyssey.app"))
        XCTAssertNotNil(app.date)
        XCTAssertEqual(storage.total("mac_apps"), app.size)
        XCTAssertNotNil(storage.macAppsDisk)
        XCTAssertFalse(app.isInstalledCopy)
        XCTAssertEqual(answer.builder.macPacked, false)
        // Of an engine older than the Mac's builds: none.
        let plain = try JSONDecoder().decode(StorageReport.self, from: Data(#"{"workspace": "/w", "disks": {}, "folders": [], "ipa_copies": [], "totals": {}}"#.utf8))
        XCTAssertEqual(plain.apps, [])
        XCTAssertNil(plain.macAppsDisk)

        // A game built for one of the two only.
        let platform = try self.answer(PlatformAnswer.self, "platform")
        XCTAssertEqual(platform.titleID, "0100000000010000")
        XCTAssertEqual(platform.platforms, GamePlatforms(ios: true, mac: false))
        XCTAssertTrue(platform.followed)

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
