//
//  SwitchSaveTests.swift
//  CartoucheHarnessTests
//
//  A game's save brought from the player's Switch, as the game's sheet
//  brings it (CartoucheSwitchSaveView): an archive as JKSV exports one,
//  read and staged (CartoucheSwitchSave, CartoucheSwitchSaveArchive), then
//  put in place of the game's save in its data folder, in the saves' turn
//  (CartoucheSaveBackups): before the game's first start, the data folder
//  made for it as that start makes it; the save it replaced put back; sent
//  on to the saves folder as the newest copy; and none while the game runs.
//

import XCTest
@testable import CartoucheHarness

final class SwitchSaveTests: HarnessCase {
    /// An archive of a player's save of GAME as JKSV exports one, its
    /// files and its fiche at its root: PROGRESS, and a folder with a file.
    private func jksvExport(of game: HarnessGame, progress: Data) async throws -> URL {
        var fiche = [UInt8](repeating: 0, count: CartoucheSwitchSaveMeta.size)
        let titleId = UInt64(game.titleId, radix: 16) ?? 0
        for index in 0 ..< 4 {
            fiche[index] = UInt8(truncatingIfNeeded: CartoucheSwitchSaveMeta.magic >> (8 * UInt32(index)))
        }
        fiche[4] = 1   // JKSV's revision
        for index in 0 ..< 8 {
            fiche[5 + index] = UInt8(truncatingIfNeeded: titleId >> (8 * UInt64(index)))
        }
        fiche[37] = 1  // a player's save
        let folder = HarnessStorage.root.appendingPathComponent("Switch", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent("Player - 2026-11-13_15-20-00.zip")
        let sink = try CartoucheFileSink(url)
        let writer = CartoucheZipWriter(sink: sink)
        try await writer.addData(CartoucheSwitchSaveMeta.fileName, Data(fiche))
        try await writer.addData("progress.bin", progress)
        try await writer.addFolder("slots/")
        try await writer.addData("slots/1.bin", Data("slot 1".utf8))
        try await writer.finish()
        try sink.close()
        return url
    }

    /// The save of the archive at URL, read as the game's and staged for
    /// the game whose Documents are DOCUMENTS, as the page does.
    private func staged(_ url: URL, of game: HarnessGame, documents: URL?) async throws -> URL {
        let pick = try await CartoucheSwitchSaveArchive.read(url)
        XCTAssertEqual(pick.export.meta?.titleId, game.titleId.uppercased(), "read as the game's, by JKSV's fiche")
        let folder = try CartoucheSwitchSave.folder(for: pick.export, game: [game.titleId], names: pick.names, documents: documents)
        XCTAssertEqual(folder, CartoucheSwitchSave.saveFolder)
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("SwitchSaveTests-\(UUID().uuidString)",
                                                                                  isDirectory: true)
        let staged = work.appendingPathComponent("staged", isDirectory: true)
        try await CartoucheSwitchSaveArchive.stage(pick, as: folder, into: staged, work: work)
        return staged
    }

    /// The copies of GAME's saves in the saves folder FOLDER.
    private func copies(of game: HarnessGame, in folder: URL) -> [URL] {
        let gameFolder = folder.appendingPathComponent(CartoucheStoragePath.fileName(game.name) + " [\(game.titleId)]")
        let found = (try? FileManager.default.contentsOfDirectory(at: gameFolder, includingPropertiesForKeys: nil)) ?? []
        return found.filter { $0.pathExtension == "zip" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    func testASaveFromTheSwitchComesBeforeTheGamesFirstStartAndTheOneItReplacedComesBack() async throws {
        let game = HarnessGame.plain(2)
        let app = try await installed(game)
        XCTAssertNil(app.appInfo.dataUUID, "no data folder before the game starts")
        XCTAssertNil(actions.saves(of: app))

        // Its data folder, made for the save as the game's first start makes it.
        let target = try XCTUnwrap(actions.savesToImport(of: app), "the game's saves, for the save to come into")
        let documents = try dataFolder(of: app).appendingPathComponent("Documents", isDirectory: true)
        XCTAssertEqual(actions.saves(of: app)?.key, target.key)

        let first = Data((0..<4096).map { UInt8(truncatingIfNeeded: $0 &* 7) })
        let firstSave = try await staged(try await jksvExport(of: game, progress: first), of: game, documents: target.documents)
        let none = try await CartoucheSaveBackups.shared.bringIn(firstSave, of: target, running: { false })
        XCTAssertNil(none, "the game had no save to keep")
        XCTAssertEqual(try Data(contentsOf: documents.appendingPathComponent("save/progress.bin")), first)
        XCTAssertEqual(try String(contentsOf: documents.appendingPathComponent("save/slots/1.bin"), encoding: .utf8), "slot 1")
        XCTAssertFalse(exists(documents, "save/" + CartoucheSwitchSaveMeta.fileName), "JKSV's fiche stays out of the save")

        // Another save from the Switch replaces it, which is kept, and comes back.
        let second = Data("the second".utf8)
        let secondSave = try await staged(try await jksvExport(of: game, progress: second), of: game, documents: target.documents)
        let kept = try await CartoucheSaveBackups.shared.bringIn(secondSave, of: target, running: { false })
        XCTAssertNotNil(kept, "the save replaced is kept")
        XCTAssertEqual(try Data(contentsOf: documents.appendingPathComponent("save/progress.bin")), second)
        let before = try XCTUnwrap(CartoucheSwitchSave.backups(CartoucheSwitchSave.beforeImport, in: documents).first)
        try await CartoucheSaveBackups.shared.putBack(beforeImport: before, of: target, running: { false })
        XCTAssertEqual(try Data(contentsOf: documents.appendingPathComponent("save/progress.bin")), first)
        XCTAssertTrue(CartoucheSwitchSave.backups(CartoucheSwitchSave.beforeImport, in: documents).isEmpty)
        XCTAssertEqual(CartoucheSwitchSave.backups(CartoucheSwitchSave.beforePutBack, in: documents).count, 1,
                       "the save put back replaced is kept too")
        XCTAssertFalse(CartoucheSaveBackups.shared.isOn, "without a saves folder, nothing goes anywhere")
    }

    func testASaveFromTheSwitchGoesToTheSavesFolderAsTheNewestCopy() async throws {
        let (_, saves) = try HarnessStorage.folder("Sauvegardes", for: [.saves])
        let game = HarnessGame.plain(3)
        let app = try await installed(game)
        await CartoucheSaveBackups.shared.finish()
        let target = try XCTUnwrap(actions.saves(of: app), "a data folder, for the saves to come into")
        XCTAssertTrue(copies(of: game, in: saves).isEmpty, "no saves yet")

        let progress = Data((0..<8192).map { UInt8(truncatingIfNeeded: $0 &* 13) })
        let save = try await staged(try await jksvExport(of: game, progress: progress), of: game, documents: target.documents)
        _ = try await CartoucheSaveBackups.shared.bringIn(save, of: target, running: { false })
        try await waitUntil("the save went to the saves folder") { !self.copies(of: game, in: saves).isEmpty }
        await CartoucheSaveBackups.shared.finish()

        let sent = try XCTUnwrap(copies(of: game, in: saves).last)
        let source = try CartoucheFileSource(sent)
        let entries = try await CartoucheZip.entries(of: source)
        XCTAssertEqual(entries.map(\.name).filter { !$0.hasSuffix("/") }.sorted(), ["save/progress.bin", "save/slots/1.bin"],
                       "the save from the Switch, and nothing else")
        let entry = try XCTUnwrap(entries.first { $0.name == "save/progress.bin" })
        let data = try await CartoucheZip.data(of: entry, in: source)
        XCTAssertEqual(data, progress)
        XCTAssertNil(CartoucheSaveBackups.shared.problemReport)
    }

    func testNoSaveComesWhileTheGameRuns() async throws {
        let game = HarnessGame.plain(4)
        let app = try await installed(game)
        actions.play(app)
        try await waitUntil("the game runs") { actions.running != nil && actions.work == nil }
        let target = try XCTUnwrap(actions.saves(of: app))
        let documents = target.documents
        try write("the game's own", in: documents, at: "save/progress.bin")

        // Read and staged before the game started, put in place after.
        let save = try await staged(try await jksvExport(of: game, progress: Data("from the Switch".utf8)), of: game,
                                    documents: documents)
        do {
            _ = try await CartoucheSaveBackups.shared.bringIn(save, of: target, running: { self.actions.isRunning(app) })
            XCTFail("A save from the Switch came while the game ran")
        } catch let problem as CartoucheSwitchSaveProblem {
            XCTAssertEqual(problem, .running)
        }
        XCTAssertEqual(try String(contentsOf: documents.appendingPathComponent("save/progress.bin"), encoding: .utf8), "the game's own")
        XCTAssertTrue(CartoucheSwitchSave.backups(CartoucheSwitchSave.beforeImport, in: documents).isEmpty, "nothing kept, nothing moved")

        actions.quitRunningGame()
        try await waitUntil("the game has ended") { actions.running == nil }
    }
}
