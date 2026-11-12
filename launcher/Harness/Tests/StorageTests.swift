//
//  StorageTests.swift
//  CartoucheHarnessTests
//
//  The player's games folder and saves folder, here folders of the
//  iPhone's picked once (CartoucheStorageFolder.swift), as Cartouche uses
//  any of the player's servers: the games it lists there
//  (CartoucheStoredGames), a game installed from there, read where it sits
//  (CartoucheGameActions install(stored:), CartoucheZip), a game copied
//  there that installs again as it was, and a game's saves, which go there
//  after a game and come back with its next install (CartoucheSaveBackups).
//  The servers themselves are tested on their own, against real ones
//  (launcher/StorageTests).
//

import Combine
import XCTest
@testable import CartoucheHarness

final class StorageTests: HarnessCase {
    private var stored: CartoucheStoredGames { CartoucheStoredGames.shared }

    /// Puts GAME's IPA in FOLDER at PATH, as the player copies one there.
    @discardableResult
    private func put(_ game: HarnessGame, in folder: URL, at path: String) throws -> URL {
        let url = folder.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: try HarnessIPA.game(game), to: url)
        return url
    }

    /// The files of GAME's IPA, by their path in the game's bundle.
    private func bundleFiles(of game: HarnessGame) -> [(path: String, entry: HarnessZip.Entry)] {
        let top = "Payload/" + game.bundleName + "/"
        return game.files.filter { $0.kind == .file && $0.name.hasPrefix(top) }
            .map { (path: String($0.name.dropFirst(top.count)), entry: $0) }
    }

    /// Fails unless APP's bundle holds GAME's files as its IPA has them.
    private func assertInstalled(_ app: LCAppModel, as game: HarnessGame,
                                 file: StaticString = #filePath, line: UInt = #line) throws {
        let bundle = try bundle(of: app)
        XCTAssertEqual(app.appInfo.bundleIdentifier(), game.bundleIdentifier, file: file, line: line)
        for (path, entry) in bundleFiles(of: game) {
            let data = try? Data(contentsOf: bundle.appendingPathComponent(path))
            XCTAssertTrue(data == entry.data, "\(path) is in the installed game as in its IPA", file: file, line: line)
            let attributes = try? FileManager.default.attributesOfItem(atPath: bundle.appendingPathComponent(path).path)
            XCTAssertEqual((attributes?[.posixPermissions] as? NSNumber)?.intValue, Int(entry.mode), "\(path)'s mode",
                           file: file, line: line)
        }
        XCTAssertTrue(HarnessLC.signatureIsValid(bundle.appendingPathComponent(game.executable).path), "signed",
                      file: file, line: line)
    }

    // MARK: The games folder

    func testTheGamesFolderListsTheGamesInItAndOneLevelDown() async throws {
        let (_, folder) = try HarnessStorage.folder("Jeux", for: [.games])
        let named = HarnessGame.plain(0)
        let unnamed = HarnessGame.plain(1)
        // As Cartouche names the IPAs it writes, and as a dump may be named.
        let namedPath = "\(named.name) [\(named.titleId)].ipa"
        try put(named, in: folder, at: namedPath)
        try put(unnamed, in: folder, at: "Switch 2/dump.ipa")
        // An app that is no game, and a file that is no IPA, are not listed.
        try FileManager.default.copyItem(at: try HarnessIPA.app(), to: folder.appendingPathComponent("Notes.ipa"))
        try Data("Mes jeux".utf8).write(to: folder.appendingPathComponent("README.txt"))

        await stored.reload()
        XCTAssertNil(stored.problem)
        XCTAssertEqual(stored.serverName, "Jeux")
        XCTAssertEqual(Set(stored.games.map(\.path)), [namedPath, "Switch 2/dump.ipa"])

        // Known by its Info.plist, read where it sits.
        let dump = try XCTUnwrap(stored.games.first { $0.path == "Switch 2/dump.ipa" })
        XCTAssertTrue(dump.isGame)
        XCTAssertEqual(dump.titleId, unnamed.titleId.uppercased())
        XCTAssertEqual(dump.bundleId, unnamed.bundleIdentifier)
        XCTAssertEqual(dump.displayName, unnamed.name)
        XCTAssertEqual(dump.name, unnamed.name)
        XCTAssertEqual(dump.version, unnamed.version)
        XCTAssertEqual(dump.build?.commit, unnamed.commit)
        XCTAssertEqual(dump.build?.builtAt, unnamed.files.first { $0.name.hasSuffix(".app/Info.plist") }?.date,
                       "when the IPA was built: its Info.plist's time")
        XCTAssertEqual(dump.size, UInt64(try Data(contentsOf: folder.appendingPathComponent("Switch 2/dump.ipa")).count))
        let byName = try XCTUnwrap(stored.games.first { $0.path == namedPath })
        XCTAssertEqual(byName.titleId, named.titleId.uppercased())
        XCTAssertTrue(byName.isGame)
        XCTAssertEqual(stored.game(titleId: nil, bundleId: unnamed.bundleIdentifier)?.path, "Switch 2/dump.ipa")
    }

    func testAGameInstallsFromTheGamesFolderReadWhereItSits() async throws {
        let (_, folder) = try HarnessStorage.folder("Jeux", for: [.games])
        let game = HarnessGame.plain(2)
        let ipa = try put(game, in: folder, at: "\(game.name) [\(game.titleId)].ipa")
        await stored.reload()
        let found = try XCTUnwrap(stored.games.first)

        let stages = HarnessBox<[String]>([])
        let installedApp = try await install(stored: found, stages: stages)
        XCTAssertNil(actions.notice, "\(String(describing: actions.notice))")
        let app = try XCTUnwrap(installedApp)
        try assertInstalled(app, as: game)
        XCTAssertEqual(stages.value, ["reading", "unpacking", "signing"])
        XCTAssertEqual(HarnessLC.signed.count, 1)
        XCTAssertTrue(model.apps.contains(app))
        XCTAssertEqual(CartoucheCatalog.shared.gameTitle(of: app), game.titleId.uppercased())
        // The build Cartouche notes, for the console to offer a newer one.
        XCTAssertEqual(CartoucheInstalledBuilds.shared.build(of: app).commit, game.commit)
        XCTAssertEqual(CartoucheInstalledBuilds.shared.build(of: app).builtAt, found.build?.builtAt)
        XCTAssertTrue(FileManager.default.fileExists(atPath: ipa.path), "the IPA stays in the games folder")
        XCTAssertFalse(FileManager.default.fileExists(atPath: unpackingFolder.path), "the unpacked IPA is gone")
    }

    func testAGameFromTheGamesFolderInstallsAsFromTheFilesPicker() async throws {
        let (_, folder) = try HarnessStorage.folder("Jeux", for: [.games])
        let game = HarnessGame.plain(3)
        let fromFiles = try await installed(game)
        let viaLiveContainer = listing(of: try bundle(of: fromFiles))

        try put(game, in: folder, at: "\(game.name) [\(game.titleId)].ipa")
        await stored.reload()
        let viaStorage = try await install(stored: try XCTUnwrap(stored.games.first))
        XCTAssertNil(actions.notice)
        let app = try XCTUnwrap(viaStorage)
        XCTAssertEqual(listing(of: try bundle(of: app)), viaLiveContainer, "the same files either way")
        try assertInstalled(app, as: game)
        XCTAssertEqual(model.apps.count, 1, "the copy from the games folder takes the place of the other")
    }

    func testADamagedIPAInTheGamesFolderIsRefusedAndSaysWhichFile() async throws {
        let (_, folder) = try HarnessStorage.folder("Jeux", for: [.games])
        let game = HarnessGame.plain()
        let damaged = try HarnessIPA.damaged(game, in: "romfs.img", named: "Damaged.ipa")
        try FileManager.default.copyItem(at: damaged, to: folder.appendingPathComponent("\(game.name) [\(game.titleId)].ipa"))
        await stored.reload()

        let installedApp = try await install(stored: try XCTUnwrap(stored.games.first))
        XCTAssertNil(installedApp)
        XCTAssertEqual(actions.notice?.title, CartoucheText.installFailed)
        let message = actions.notice?.message ?? ""
        XCTAssertTrue(message.contains("romfs.img is damaged"), message)
        XCTAssertNotNil(actions.notice?.report)
        XCTAssertTrue(model.apps.isEmpty)
        XCTAssertTrue(HarnessLC.signed.isEmpty)
        XCTAssertTrue(listing(of: LCPath.bundlePath).isEmpty, "nothing left in Applications")
        XCTAssertFalse(FileManager.default.fileExists(atPath: unpackingFolder.path))
    }

    func testOnAGPUNxnativeRefusesAGameFromTheGamesFolderAsksFirstToo() async throws {
        HarnessLC.readsBCTextures = false
        let (_, folder) = try HarnessStorage.folder("Jeux", for: [.games])
        let game = HarnessGame.plain()
        try put(game, in: folder, at: "\(game.name) [\(game.titleId)].ipa")
        await stored.reload()
        let found = try XCTUnwrap(stored.games.first)

        actions.install(stored: found)
        XCTAssertNil(actions.work)
        let question = try XCTUnwrap(actions.installQuestion)
        XCTAssertEqual(question.source, .stored(found))
        XCTAssertEqual(question.name, game.name)
        actions.installAnyway(question)
        XCTAssertEqual(actions.work?.kind, .installing)
        try await waitUntil("the install is over") { actions.work == nil }
        XCTAssertNil(actions.notice)
        try assertInstalled(try XCTUnwrap(app(game.bundleIdentifier)), as: game)
    }

    func testWithoutAGamesFolderNothingIsListed() async throws {
        await stored.reload()
        XCTAssertTrue(stored.games.isEmpty)
        XCTAssertNil(stored.serverName)
        XCTAssertNil(stored.problem)
    }

    // MARK: A copy in the games folder

    func testAGameCopiedToTheGamesFolderIsItsIPAAndInstallsAgain() async throws {
        let (_, folder) = try HarnessStorage.folder("Jeux", for: [.games])
        let game = HarnessGame.plain(4)
        let app = try await installed(game)
        let top = "Payload/" + (app.appInfo.relativeBundlePath ?? "") + "/"

        let next = HarnessBox(false)
        actions.export(app, titleId: game.titleId) { next.value = true }
        XCTAssertEqual(actions.work?.kind, .exporting)
        try await waitUntil("the copy is over") { actions.work == nil }
        XCTAssertNil(actions.notice, "\(String(describing: actions.notice))")
        try await waitUntil("what comes next ran") { next.value }

        // "<game> [<title ID>].ipa", whole.
        let name = CartoucheStoredGame.fileName(game: game.name, titleId: game.titleId)
        let ipa = folder.appendingPathComponent(name)
        XCTAssertTrue(FileManager.default.fileExists(atPath: ipa.path), "\(listing(of: folder))")
        XCTAssertFalse(FileManager.default.fileExists(atPath: ipa.path + ".partial"))

        // The game as its IPA had it, file for file, under the bundle's
        // folder: nothing LiveContainer added for this iPhone, neither its
        // record, nor the signature, nor the profile that names the iPhone.
        let source = try CartoucheFileSource(ipa)
        let entries = try await CartoucheZip.entries(of: source)
        let wanted = [top] + ["dm/", "Frameworks/", "Frameworks/MoltenVK.framework/"].map { top + $0 }
            + bundleFiles(of: game).map { top + $0.path }
        XCTAssertEqual(entries.map(\.name).sorted(), wanted.sorted())
        for (path, file) in bundleFiles(of: game) {
            let entry = try XCTUnwrap(entries.first { $0.name == top + path })
            let data = try await CartoucheZip.data(of: entry, in: source)
            XCTAssertTrue(data == file.data, "\(path) as in the IPA it came from")
            XCTAssertEqual(entry.mode.map { $0 & 0o777 }, UInt32(file.mode), "\(path)'s mode")
        }
        // Its Info.plist keeps the time the first IPA gave it: when the game
        // was built.
        let infoPlist = try XCTUnwrap(CartoucheStoredGames.infoPlistEntry(in: entries))
        let builtAt = try XCTUnwrap(game.files.first { $0.name.hasSuffix(".app/Info.plist") }?.date)
        XCTAssertLessThanOrEqual(abs(try XCTUnwrap(infoPlist.modified).timeIntervalSince(builtAt)), 2)

        // The games folder lists it, as the game it is.
        let copy = try XCTUnwrap(stored.games.first { $0.path == name }, "\(stored.games.map(\.path))")
        XCTAssertEqual(copy.titleId, game.titleId.uppercased())
        XCTAssertEqual(copy.build?.commit, game.commit)

        // Uninstalled, it installs again from there, as it was.
        actions.uninstall(app, erasingData: false)
        try await waitUntil("the game is uninstalled") { actions.work == nil }
        XCTAssertTrue(model.apps.isEmpty)
        let again = try await install(stored: copy)
        XCTAssertNil(actions.notice)
        try assertInstalled(try XCTUnwrap(again), as: game)
    }

    // MARK: Saves

    /// The copies of GAME's saves in the saves folder FOLDER.
    private func copies(of game: HarnessGame, in folder: URL) -> [URL] {
        let gameFolder = folder.appendingPathComponent(CartoucheStoragePath.fileName(game.name) + " [\(game.titleId)]")
        let found = (try? FileManager.default.contentsOfDirectory(at: gameFolder, includingPropertiesForKeys: nil)) ?? []
        return found.filter { $0.pathExtension == "zip" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    func testAGamesSavesGoToTheSavesFolderAfterItAndComeBackWithItsNextInstall() async throws {
        let (_, saves) = try HarnessStorage.folder("Sauvegardes", for: [.saves])
        let game = HarnessGame.plain(5)
        let app = try await installed(game)
        XCTAssertNotNil(app.appInfo.dataUUID, "a data folder, for the saves to come into")
        XCTAssertTrue(copies(of: game, in: saves).isEmpty, "no saves yet")

        // The game saves as it runs behind the console, as nxnative does.
        actions.play(app)
        try await waitUntil("the game runs") { actions.running != nil && actions.work == nil }
        let documents = try dataFolder(of: app).appendingPathComponent("Documents", isDirectory: true)
        let save = Data((0..<4096).map { UInt8(truncatingIfNeeded: $0 &* 7) })
        try FileManager.default.createDirectory(at: documents.appendingPathComponent("save/0000000000000001"),
                                                withIntermediateDirectories: true)
        try save.write(to: documents.appendingPathComponent("save/0000000000000001/progress.bin"))
        try Data("device".utf8).write(to: documents.appendingPathComponent("env.device"))

        // They go once it ends.
        actions.quitRunningGame()
        try await waitUntil("the game has ended") { actions.running == nil }
        try await waitUntil("the saves went to the saves folder") { !self.copies(of: game, in: saves).isEmpty }
        await CartoucheSaveBackups.shared.finish()
        let sent = try XCTUnwrap(copies(of: game, in: saves).first)
        XCTAssertEqual(copies(of: game, in: saves).count, 1)
        XCTAssertNotNil(CartoucheSaveSync.date(inName: sent.lastPathComponent), "named by its date: \(sent.lastPathComponent)")
        let source = try CartoucheFileSource(sent)
        let entries = try await CartoucheZip.entries(of: source)
        XCTAssertEqual(entries.map(\.name).filter { !$0.hasSuffix("/") }, ["save/0000000000000001/progress.bin"],
                       "the saves, and nothing else of the game's")
        let saved = try XCTUnwrap(entries.first { $0.name == "save/0000000000000001/progress.bin" })
        let sentData = try await CartoucheZip.data(of: saved, in: source)
        XCTAssertTrue(sentData == save)
        XCTAssertNil(CartoucheSaveBackups.shared.problemReport)

        // Nothing changed since: nothing more goes.
        actions.copySaves(of: [app])
        await CartoucheSaveBackups.shared.finish()
        XCTAssertEqual(copies(of: game, in: saves).count, 1)

        // Uninstalled with its saves, as on a new iPhone: they come back
        // with the game.
        actions.uninstall(app, erasingData: true)
        try await waitUntil("the game is uninstalled") { actions.work == nil }
        XCTAssertFalse(FileManager.default.fileExists(atPath: documents.path))
        let again = try await installed(game)
        let back = try dataFolder(of: again).appendingPathComponent("Documents/save/0000000000000001/progress.bin")
        XCTAssertTrue((try? Data(contentsOf: back)) == save, "the saves came back")
        let target = try XCTUnwrap(actions.saves(of: again))
        XCTAssertNotNil(CartoucheSaveBackups.shared.news[target.key]?.fetched, "the game's sheet says they came")
        XCTAssertEqual(copies(of: game, in: saves).count, 1)
    }

    func testWithoutASavesFolderNoSaveGoesAnywhere() async throws {
        let game = HarnessGame.plain(6)
        let app = try await installed(game)
        XCTAssertNil(app.appInfo.dataUUID, "no data folder before the game starts")
        XCTAssertFalse(CartoucheSaveBackups.shared.isOn)
        actions.copySaves(of: [app])
        await CartoucheSaveBackups.shared.finish()
        XCTAssertFalse(CartoucheSaveBackups.shared.isSyncing)
    }
}
