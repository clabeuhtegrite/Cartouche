//
//  GameFilesApartTests.swift
//  CartoucheHarnessTests
//
//  A game nxnative built with its game files apart (--romfs separate, or
//  DM_COPY_ROMFS=NO), as players build the big ones: its IPA holds the app
//  with romfs.id and no romfs.img, the image of the game's files, which the
//  player keeps beside the IPA. Cartouche installs the two together, from
//  the games folder or from Files, after checking the image against
//  romfs.id, and a new build of the game keeps the image the installed one
//  holds (CartoucheRomfs, decision 68).
//

import XCTest
@testable import CartoucheHarness

final class GameFilesApartTests: HarnessCase {
    private var stored: CartoucheStoredGames { CartoucheStoredGames.shared }

    /// A game of the catalogue, built with its files apart.
    private func apart(_ index: Int) -> HarnessGame {
        var game = HarnessGame.plain(index)
        game.romfsApart = true
        return game
    }

    /// A new empty folder of the iPhone's, as one Files shows.
    private func newFolder(_ name: String) throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("HarnessApart", isDirectory: true)
            .appendingPathComponent(name, isDirectory: true)
        try? FileManager.default.removeItem(at: folder)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    /// Fails unless APP's bundle holds GAME's files as its IPA has them,
    /// romfs.id with them, and the image of its files as romfs.img, where
    /// nxnative reads it.
    private func assertInstalled(_ app: LCAppModel, as game: HarnessGame,
                                 file: StaticString = #filePath, line: UInt = #line) throws {
        let bundle = try bundle(of: app)
        let top = "Payload/" + game.bundleName + "/"
        for entry in game.files where entry.kind == .file {
            let path = String(entry.name.dropFirst(top.count))
            XCTAssertTrue(installedFile(bundle.appendingPathComponent(path), holds: entry.data),
                          "\(path) is in the installed game as in its IPA", file: file, line: line)
        }
        let image = try? Data(contentsOf: bundle.appendingPathComponent("romfs.img"))
        XCTAssertTrue(image == game.romfsImage, "romfs.img, the image of its files, whole", file: file, line: line)
        XCTAssertTrue(HarnessLC.signatureIsValid(bundle.appendingPathComponent(game.executable).path), "signed",
                      file: file, line: line)
    }

    // MARK: From the games folder

    func testAGameWithItsFilesApartInstallsFromTheGamesFolderWithTheImageBesideIt() async throws {
        let (_, folder) = try HarnessStorage.folder("Jeux", for: [.games])
        let game = apart(0)
        // As nxnative's extraction names it, which a copy through the Finder
        // or Files keeps.
        try HarnessIPA.gameApart(game, in: folder, image: "RomFS.img")
        await stored.reload()
        XCTAssertNil(stored.problem)
        let found = try XCTUnwrap(stored.games.first)
        XCTAssertTrue(found.isGame)
        XCTAssertEqual(found.gameFiles?.size, UInt64(game.romfsImage.count), "romfs.id, read where the IPA sits")
        XCTAssertEqual(found.gameFilesPath, "RomFS.img", "the image beside it, in any letter case")
        XCTAssertFalse(found.lacksGameFiles)
        XCTAssertEqual(found.storedSize, found.size + UInt64(game.romfsImage.count))
        XCTAssertEqual(stored.looseGameFiles, [])

        let stages = HarnessBox<[String]>([])
        let installedApp = try await install(stored: found, stages: stages)
        XCTAssertNil(actions.notice, "\(String(describing: actions.notice))")
        let app = try XCTUnwrap(installedApp)
        XCTAssertEqual(stages.value, ["reading", "unpacking", "gameFiles", "signing"])
        try assertInstalled(app, as: game)
        XCTAssertEqual(HarnessLC.signed.count, 1)
        XCTAssertTrue(exists(folder, "RomFS.img"), "the image stays in the games folder")
        XCTAssertFalse(FileManager.default.fileExists(atPath: unpackingFolder.path), "the unpacked IPA is gone")
    }

    func testWithoutItsImageAGameWithItsFilesApartIsRefusedAndTheStoragePageSaysSo() async throws {
        let (_, folder) = try HarnessStorage.folder("Jeux", for: [.games])
        let game = apart(1)
        try HarnessIPA.gameApart(game, in: folder, image: nil)
        // Another game's image, of another size, which no IPA there takes.
        var other = apart(2)
        other.romfsBytes = 160 << 10
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("Switch 2"), withIntermediateDirectories: true)
        try other.romfsImage.write(to: folder.appendingPathComponent("Switch 2/romfs.img"))
        await stored.reload()
        let found = try XCTUnwrap(stored.games.first)
        XCTAssertNotNil(found.gameFiles)
        XCTAssertTrue(found.lacksGameFiles, "its romfs.img is missing")
        XCTAssertEqual(stored.looseGameFiles, ["Switch 2/romfs.img"], "and the image no IPA takes is told apart")

        let installedApp = try await install(stored: found)
        XCTAssertNil(installedApp)
        XCTAssertEqual(actions.notice?.title, CartoucheText.installFailed)
        XCTAssertEqual(actions.notice?.message, CartoucheText.installGameFilesMissing(found.name))
        assertNothingInstalled()
    }

    func testAnImageThatIsNotTheOneTheGameWasBuiltWithIsRefused() async throws {
        let (_, folder) = try HarnessStorage.folder("Jeux", for: [.games])
        let game = apart(3)
        // Of the size romfs.id names, but of other files: another index.
        var another = game
        another.romfsSeed = "another dump of the game"
        XCTAssertEqual(another.romfsImage.count, game.romfsImage.count)
        try HarnessIPA.gameApart(game, in: folder, imageData: another.romfsImage)
        await stored.reload()
        let found = try XCTUnwrap(stored.games.first)
        XCTAssertFalse(found.lacksGameFiles, "an image of the size it needs is beside it")

        let installedApp = try await install(stored: found)
        XCTAssertNil(installedApp)
        XCTAssertEqual(actions.notice?.title, CartoucheText.installFailed)
        XCTAssertEqual(actions.notice?.message, CartoucheText.installGameFilesMismatch(found.name))
        assertNothingInstalled()
    }

    // MARK: From Files

    func testAGameWithItsFilesApartInstallsFromFilesWithTheImageBesideIt() async throws {
        let game = apart(4)
        let ipa = try HarnessIPA.gameApart(game, in: try newFolder("beside"))
        let stages = HarnessBox<[String]>([])
        let installedApp = try await install(ipa, stages: stages)
        XCTAssertNil(actions.notice, "\(String(describing: actions.notice))")
        let app = try XCTUnwrap(installedApp)
        XCTAssertEqual(stages.value, ["checking", "unpacking", "gameFiles", "signing"])
        try assertInstalled(app, as: game)
        XCTAssertTrue(exists(ipa.deletingLastPathComponent(), "romfs.img"), "the image stays where it was")
        XCTAssertTrue(FileManager.default.fileExists(atPath: ipa.path), "and so does the IPA")
    }

    func testFromFilesWithoutItsImageCartoucheSaysToPutTheTwoTogether() async throws {
        let game = apart(5)
        let ipa = try HarnessIPA.gameApart(game, in: try newFolder("alone"), image: nil)
        let installedApp = try await install(ipa)
        XCTAssertNil(installedApp)
        XCTAssertEqual(actions.notice?.title, CartoucheText.installFailed)
        XCTAssertEqual(actions.notice?.message, CartoucheText.installGameFilesApart(ipa.deletingPathExtension().lastPathComponent))
        assertNothingInstalled()
    }

    // MARK: A new build of the game

    func testANewBuildOfTheGameKeepsTheImageTheInstalledOneHolds() async throws {
        let first = apart(6)
        let installedFirst = try await install(try HarnessIPA.gameApart(first, in: try newFolder("first build")))
        XCTAssertNil(actions.notice, "\(String(describing: actions.notice))")
        XCTAssertNotNil(installedFirst)

        // A later build from the same dump: romfs.id names the same image,
        // and none is beside it.
        var second = first
        second.version = "1.1.0"
        second.commit = "9f0e8d7c6b5a4f3e2d1c0b9a8f7e6d5c4b3a2f1e"
        let stages = HarnessBox<[String]>([])
        let installedSecond = try await install(try HarnessIPA.gameApart(second, in: try newFolder("second build"), image: nil),
                                                stages: stages)
        XCTAssertNil(actions.notice, "\(String(describing: actions.notice))")
        let app = try XCTUnwrap(installedSecond)
        XCTAssertEqual(app.appInfo.version(), "1.1.0")
        XCTAssertEqual(model.apps.count, 1, "the new build takes the place of the first")
        XCTAssertFalse(stages.value.contains("gameFiles"), "its image moved over, nothing copied: \(stages.value)")
        try assertInstalled(app, as: second)
        let apps = listing(of: LCPath.bundlePath).filter { $0.hasSuffix(".app/") && !$0.dropLast().contains("/") }
        XCTAssertEqual(apps.count, 1, "one copy of the game in Applications: \(apps)")
    }

    func testANewBuildThatNeedsOtherFilesIsRefusedAndTheInstalledGameStaysWhole() async throws {
        let first = apart(7)
        let installedFirst = try await install(try HarnessIPA.gameApart(first, in: try newFolder("first build")))
        let app = try XCTUnwrap(installedFirst)
        XCTAssertNil(actions.notice)

        // A build of an update of the game, whose files changed.
        var second = first
        second.version = "2.0.0"
        second.romfsBytes = 224 << 10
        let ipa = try HarnessIPA.gameApart(second, in: try newFolder("update"), image: nil)
        let refused = try await install(ipa)
        XCTAssertNil(refused)
        XCTAssertEqual(actions.notice?.message, CartoucheText.installGameFilesApart(ipa.deletingPathExtension().lastPathComponent))
        XCTAssertEqual(model.apps.count, 1)
        XCTAssertTrue(model.apps.first === app, "the installed copy stays")
        XCTAssertEqual(app.appInfo.version(), first.version)
        try assertInstalled(app, as: first)
    }
}
