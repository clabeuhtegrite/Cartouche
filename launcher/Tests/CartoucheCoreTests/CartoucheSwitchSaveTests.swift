//
//  CartoucheSwitchSaveTests.swift
//  CartoucheCoreTests
//
//  A game's save brought from the player's Switch (Sources/CartoucheSwitchSave.swift):
//  JKSV's fiche read as JKSV writes it, the save found in a folder or an
//  archive as JKSV, Checkpoint, macOS and Windows make them, what is
//  refused, the folder of the game's Documents it goes to, as nxnative
//  mounts its saves, and the saves it replaces, kept and put back.
//

import Foundation
import XCTest
@testable import CartoucheCore

final class CartoucheSwitchSaveTests: XCTestCase {
    private var folder: URL!
    /// 13 Nov 2026, 15:20 UTC.
    private let afternoon = Date(timeIntervalSince1970: 1_794_583_200)
    /// Mario Kart 8 Deluxe's title ID.
    private let mk8d: UInt64 = 0x0100_1520_0002_2000

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("CartoucheSwitchSaveTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    /// The fiche JKSV writes for a save of the game TITLEID, of TYPE, as
    /// fs::SaveMetaData lays it out, packed.
    static func fiche(titleId: UInt64, type: UInt8) -> Data {
        var bytes = [UInt8](repeating: 0, count: CartoucheSwitchSaveMeta.size)
        func put(_ value: UInt64, at offset: Int, count: Int) {
            for index in 0 ..< count {
                bytes[offset + index] = UInt8(truncatingIfNeeded: value >> (8 * UInt64(index)))
            }
        }
        put(UInt64(CartoucheSwitchSaveMeta.magic), at: 0, count: 4)
        put(1, at: 4, count: 1)                        // JKSV's revision
        put(titleId, at: 5, count: 8)                  // the application ID
        put(0x1122_3344_5566_7788, at: 13, count: 8)   // the account, its first half
        put(UInt64(type), at: 37, count: 1)            // the save's type
        put(titleId, at: 41, count: 8)                 // the owner
        put(0x40_0000, at: 61, count: 8)               // the save's size
        return Data(bytes)
    }

    private func file(_ path: String, _ size: UInt64 = 10) -> CartoucheSwitchSaveItem {
        CartoucheSwitchSaveItem(path: path, size: size)
    }

    private func folderItem(_ path: String) -> CartoucheSwitchSaveItem {
        CartoucheSwitchSaveItem(path: path, isFolder: true)
    }

    private func problem(_ work: () throws -> Any) -> CartoucheSwitchSaveProblem? {
        do {
            _ = try work()
            return nil
        } catch let problem as CartoucheSwitchSaveProblem {
            return problem
        } catch {
            XCTFail("Another error: \(error)")
            return nil
        }
    }

    // MARK: JKSV's fiche

    func testTheFicheGivesTheGameAndTheType() {
        let account = CartoucheSwitchSaveMeta(Self.fiche(titleId: mk8d, type: 1))
        XCTAssertEqual(account?.titleId, "0100152000022000")
        XCTAssertEqual(account?.kind, .account)
        XCTAssertEqual(CartoucheSwitchSaveMeta(Self.fiche(titleId: 0x0100_6F80_0232_6000, type: 3))?.kind, .device)
        XCTAssertEqual(CartoucheSwitchSaveMeta(Self.fiche(titleId: mk8d, type: 5))?.kind, .other(5))
        XCTAssertEqual(CartoucheSwitchSaveMeta(Self.fiche(titleId: mk8d, type: 0))?.kind, .other(0))
        // A later revision with more after it reads the same.
        XCTAssertEqual(CartoucheSwitchSaveMeta(Self.fiche(titleId: mk8d, type: 1) + Data(count: 14))?.titleId, "0100152000022000")
    }

    func testAShortOrForeignFicheIsNone() {
        XCTAssertNil(CartoucheSwitchSaveMeta(Self.fiche(titleId: mk8d, type: 1).prefix(85)))
        XCTAssertNil(CartoucheSwitchSaveMeta(Data()))
        var foreign = Self.fiche(titleId: mk8d, type: 1)
        foreign[0] = 0x4B
        XCTAssertNil(CartoucheSwitchSaveMeta(foreign))
    }

    // MARK: The save in what was picked

    func testAJKSVArchiveHoldsTheSaveAtItsRoot() throws {
        let export = try CartoucheSwitchSave.export(of: [
            file(".nx_save_meta.bin", 86), file("userdata.dat", 1000), folderItem("ghosts/"), file("ghosts/1.bin", 24),
        ], named: "Player - 2026-11-13_15-20-00")
        XCTAssertEqual(export.root, "")
        XCTAssertEqual(export.fichePath, ".nx_save_meta.bin")
        XCTAssertEqual(export.files.map(\.path), ["ghosts/1.bin", "userdata.dat"])
        XCTAssertEqual(export.folders, ["ghosts"])
        XCTAssertEqual(export.size, 1024)
        XCTAssertTrue(export.takes("userdata.dat"))
        XCTAssertTrue(export.takes("ghosts/"))
        XCTAssertFalse(export.takes(".nx_save_meta.bin"))
    }

    func testTheFicheSaysWhereTheSaveIs() throws {
        // JKSV's folder of a game, with one save.
        let export = try CartoucheSwitchSave.export(of: [
            folderItem("Player - 2026-11-13_15-20-00"), file("Player - 2026-11-13_15-20-00/.nx_save_meta.bin", 86),
            file("Player - 2026-11-13_15-20-00/game.sav"), folderItem("Player - 2026-11-13_15-20-00/empty"),
        ], named: "Mario Kart 8 Deluxe")
        XCTAssertEqual(export.root, "Player - 2026-11-13_15-20-00/")
        XCTAssertEqual(export.files.map(\.path), ["game.sav"])
        XCTAssertEqual(export.folders, ["empty"])
        XCTAssertTrue(export.takes("Player - 2026-11-13_15-20-00/game.sav"))
        XCTAssertFalse(export.takes("game.sav"))
    }

    func testAFolderZippedByMacOSIsReadInsideWithoutWhatMacOSAdds() throws {
        let export = try CartoucheSwitchSave.export(of: [
            folderItem("20261113-152000 Player/"), file("20261113-152000 Player/progress.bin"),
            file("20261113-152000 Player/.DS_Store"), file("20261113-152000 Player/._progress.bin"),
            folderItem("__MACOSX/"), file("__MACOSX/20261113-152000 Player/._progress.bin"),
        ], named: "20261113-152000 Player")
        XCTAssertEqual(export.root, "20261113-152000 Player/")
        XCTAssertNil(export.fichePath)
        XCTAssertEqual(export.files.map(\.path), ["progress.bin"])
        XCTAssertEqual(export.folders, [])
    }

    func testASaveWhoseOnlyFolderIsNotNamedAsTheArchiveStaysWhole() throws {
        // A game whose save is one folder, in an archive of another name.
        let export = try CartoucheSwitchSave.export(of: [file("Save/slot1.bin"), file("Save/slot2.bin")],
                                                    named: "Player - 2026-11-13_15-20-00")
        XCTAssertEqual(export.root, "")
        XCTAssertEqual(export.files.map(\.path), ["Save/slot1.bin", "Save/slot2.bin"])
        XCTAssertEqual(export.folders, ["Save"])
    }

    func testCheckpointsFolderOfAGameWithOneSave() throws {
        let export = try CartoucheSwitchSave.export(of: [folderItem("20261113-152000"), file("20261113-152000/save.dat")],
                                                    named: "0x0100152000022000 Mario Kart 8 Deluxe")
        XCTAssertEqual(export.root, "20261113-152000/")
        XCTAssertEqual(export.files.map(\.path), ["save.dat"])
    }

    func testSeveralSavesAreRefused() {
        // JKSV's folder of a game, with two saves.
        XCTAssertEqual(problem { try CartoucheSwitchSave.export(of: [
            file("A/.nx_save_meta.bin", 86), file("A/game.sav"), file("B/.nx_save_meta.bin", 86), file("B/game.sav"),
        ]) }, .several)
        // Checkpoint's, with two.
        XCTAssertEqual(problem { try CartoucheSwitchSave.export(of: [file("20261112-100000/save.dat"), file("20261113-152000/save.dat")],
                                                                 named: "0x0100152000022000 Mario Kart 8 Deluxe") }, .several)
        // A save beside the folder of another.
        XCTAssertEqual(problem { try CartoucheSwitchSave.export(of: [file("A/.nx_save_meta.bin", 86), file("A/game.sav"),
                                                                     file("B/game.sav")]) }, .several)
        // Far more than a save.
        let many = (0 ... CartoucheSwitchSave.itemLimit).map { file("file\($0)") }
        XCTAssertEqual(problem { try CartoucheSwitchSave.export(of: many) }, .several)
    }

    func testWhatWouldLandOutsideTheSaveIsRefused() {
        for path in ["../game.sav", "/var/game.sav", "a/../../game.sav", "a\\game.sav", "./game.sav"] {
            XCTAssertEqual(problem { try CartoucheSwitchSave.export(of: [file("ok.sav"), file(path)]) }, .unsafe(path), path)
        }
        let link = CartoucheSwitchSaveItem(path: "game.sav", isLink: true)
        XCTAssertEqual(problem { try CartoucheSwitchSave.export(of: [file("ok.sav"), link]) }, .unsafe("game.sav"))
        // The same name twice, and a name that is a file and a folder.
        XCTAssertEqual(problem { try CartoucheSwitchSave.export(of: [file("game.sav"), file("game.sav")]) }, .unsafe("game.sav"))
        XCTAssertEqual(problem { try CartoucheSwitchSave.export(of: [file("slot"), file("slot/1.bin")]) }, .unsafe("slot"))
    }

    func testNamesThatDifferOnlyByTheirCapitalsAreRefused() {
        XCTAssertEqual(problem { try CartoucheSwitchSave.export(of: [file("Save.dat"), file("save.dat")]) },
                       .caseClash("Save.dat", "save.dat"))
        XCTAssertEqual(problem { try CartoucheSwitchSave.export(of: [file("Slot/1.bin"), file("slot/2.bin")]) },
                       .caseClash("Slot", "slot"))
        // Accents written in either form are one name on the iPhone.
        XCTAssertEqual(problem { try CartoucheSwitchSave.export(of: [file("\u{E9}t\u{E9}.sav"), file("e\u{301}te\u{301}.sav")]) },
                       .caseClash("\u{E9}t\u{E9}.sav", "e\u{301}te\u{301}.sav"))
    }

    func testAnExportWithoutAFileIsEmpty() {
        XCTAssertEqual(problem { try CartoucheSwitchSave.export(of: []) }, .empty)
        XCTAssertEqual(problem { try CartoucheSwitchSave.export(of: [file(".nx_save_meta.bin", 86)]) }, .empty)
        XCTAssertEqual(problem { try CartoucheSwitchSave.export(of: [folderItem("a"), folderItem("a/b"), file(".DS_Store")]) },
                       .empty)
    }

    func testTheTitleIdANameGives() {
        XCTAssertEqual(CartoucheSwitchSave.titleId(inName: "0x0100152000022000 Mario Kart 8 Deluxe"), "0100152000022000")
        XCTAssertEqual(CartoucheSwitchSave.titleId(inName: "0100152000022000"), "0100152000022000")
        XCTAssertEqual(CartoucheSwitchSave.titleId(inName: "MK8D [0100152000022000].zip"), "0100152000022000")
        XCTAssertEqual(CartoucheSwitchSave.titleId(inName: "0x01006f8002326000 Animal Crossing"), "01006F8002326000")
        XCTAssertNil(CartoucheSwitchSave.titleId(inName: "Player - 2026-11-13_15-20-00"))
        XCTAssertNil(CartoucheSwitchSave.titleId(inName: "010015200002200"))
        XCTAssertNil(CartoucheSwitchSave.titleId(inName: "01001520000220001"))
        XCTAssertNil(CartoucheSwitchSave.titleId(inName: "20261113-152000"))
    }

    // MARK: Where it goes

    private func documents(_ folders: [String]) throws -> URL {
        let documents = folder.appendingPathComponent("Documents", isDirectory: true)
        try FileManager.default.createDirectory(at: documents, withIntermediateDirectories: true)
        for name in folders {
            try FileManager.default.createDirectory(at: documents.appendingPathComponent(name), withIntermediateDirectories: true)
        }
        return documents
    }

    private func export(type: UInt8?, of titleId: UInt64? = nil) throws -> CartoucheSwitchSaveExport {
        var export = try CartoucheSwitchSave.export(of: [file("game.sav")])
        if let type { export.meta = CartoucheSwitchSaveMeta(Self.fiche(titleId: titleId ?? mk8d, type: type)) }
        return export
    }

    func testAPlayersSaveGoesToSave() throws {
        let game = try documents(["save", "save_device"])
        XCTAssertEqual(try CartoucheSwitchSave.folder(for: export(type: 1), game: ["0100152000022000"], documents: game), "save")
        // A game that never started, whose data folder is made for it.
        XCTAssertEqual(try CartoucheSwitchSave.folder(for: export(type: 1), game: ["0100152000022000"], documents: nil), "save")
        // A save without a fiche, as Checkpoint's, is a player's.
        XCTAssertEqual(try CartoucheSwitchSave.folder(for: export(type: nil), game: ["0100152000022000"], documents: game), "save")
    }

    func testTheConsolesSaveGoesWhereNxnativeMountsIt() throws {
        // A game that mounts both, as Mario Kart 8 Deluxe.
        let both = try documents(["save", "save_device"])
        XCTAssertEqual(try CartoucheSwitchSave.folder(for: export(type: 3), game: ["0100152000022000"], documents: both), "save_device")
        try FileManager.default.removeItem(at: both)
        // A game that mounts the console's alone, as Animal Crossing: its save.
        let one = try documents(["save"])
        XCTAssertEqual(try CartoucheSwitchSave.folder(for: export(type: 3, of: 0x0100_6F80_0232_6000), game: ["01006F8002326000"],
                                                      documents: one), "save")
        // A game that never started: its first start tells.
        try FileManager.default.removeItem(at: one)
        let none = try documents([])
        XCTAssertEqual(problem { try CartoucheSwitchSave.folder(for: self.export(type: 3), game: ["0100152000022000"], documents: none) },
                       .startFirst)
        XCTAssertEqual(problem { try CartoucheSwitchSave.folder(for: self.export(type: 3), game: ["0100152000022000"], documents: nil) },
                       .startFirst)
    }

    func testTheSaveOfAnotherGameIsRefused() throws {
        let game = try documents(["save"])
        XCTAssertEqual(problem { try CartoucheSwitchSave.folder(for: self.export(type: 1), game: ["01006F8002326000"], documents: game) },
                       .otherGame("0100152000022000"))
        // The game's title ID in small letters is the same.
        XCTAssertEqual(try CartoucheSwitchSave.folder(for: export(type: 1), game: ["0100152000022000".lowercased()], documents: game), "save")
        // Without a fiche, by the name of Checkpoint's folder around it.
        XCTAssertEqual(problem { try CartoucheSwitchSave.folder(for: self.export(type: nil), game: ["01006F8002326000"],
                                                                names: ["20261113-152000", "0x0100152000022000 Mario Kart 8 Deluxe"],
                                                                documents: game) }, .otherGame("0100152000022000"))
        XCTAssertEqual(try CartoucheSwitchSave.folder(for: export(type: nil), game: ["0100152000022000"],
                                                      names: ["20261113-152000", "0x0100152000022000 Mario Kart 8 Deluxe"],
                                                      documents: game), "save")
        // The game's release in another region is the game.
        XCTAssertEqual(try CartoucheSwitchSave.folder(for: export(type: 1), game: ["0100152000024000", "0100152000022000"],
                                                      documents: game), "save")
        // A game whose title ID the catalogue does not know is not checked.
        XCTAssertEqual(try CartoucheSwitchSave.folder(for: export(type: 1), game: [], documents: game), "save")
        XCTAssertEqual(try CartoucheSwitchSave.folder(for: export(type: 1), game: [""], documents: game), "save")
    }

    func testDataThatIsNoGameIsRefused() throws {
        let game = try documents(["save"])
        for type: UInt8 in [0, 2, 4, 5, 6] {
            XCTAssertEqual(problem { try CartoucheSwitchSave.folder(for: self.export(type: type), game: ["0100152000022000"],
                                                                    documents: game) }, .notAGame, "type \(type)")
        }
    }

    func testNothingComesWhileNxnativeBringsInItsCloudSave() throws {
        let game = try documents(["save"])
        try Data().write(to: game.appendingPathComponent("save.pull"))
        XCTAssertEqual(problem { try CartoucheSwitchSave.folder(for: self.export(type: 1), game: ["0100152000022000"], documents: game) },
                       .cloudPull)
        let staged = folder.appendingPathComponent("staged/save", isDirectory: true)
        try FileManager.default.createDirectory(at: staged, withIntermediateDirectories: true)
        try Data("new".utf8).write(to: staged.appendingPathComponent("game.sav"))
        XCTAssertEqual(problem { try CartoucheSwitchSave.place(staged.deletingLastPathComponent(), in: game) as Any }, .cloudPull)
        XCTAssertTrue(FileManager.default.fileExists(atPath: staged.appendingPathComponent("game.sav").path))
    }

    // MARK: Putting it in place

    private func write(_ text: String, to url: URL, date: Date? = nil) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
        if let date { try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: url.path) }
    }

    private func text(_ url: URL) -> String? {
        (try? Data(contentsOf: url)).flatMap { String(data: $0, encoding: .utf8) }
    }

    private func modified(_ url: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    }

    /// The export of a JKSV folder in Files, on disk: its fiche, a file and
    /// an empty folder.
    private func pickedFolder() throws -> (URL, CartoucheSwitchSaveExport) {
        let picked = folder.appendingPathComponent("Player - 2026-11-13_15-20-00", isDirectory: true)
        try FileManager.default.createDirectory(at: picked, withIntermediateDirectories: true)
        try Self.fiche(titleId: mk8d, type: 1).write(to: picked.appendingPathComponent(".nx_save_meta.bin"))
        try write("progress from the Switch", to: picked.appendingPathComponent("userdata.dat"))
        try write("ghost", to: picked.appendingPathComponent("ghosts/1.bin"))
        try FileManager.default.createDirectory(at: picked.appendingPathComponent("empty"), withIntermediateDirectories: true)
        try write("", to: picked.appendingPathComponent(".DS_Store"))
        var export = try CartoucheSwitchSave.export(of: CartoucheSwitchSave.items(inFolder: picked), named: picked.lastPathComponent)
        export.meta = export.fichePath.flatMap { try? Data(contentsOf: picked.appendingPathComponent($0)) }.flatMap(CartoucheSwitchSaveMeta.init)
        return (picked, export)
    }

    func testAFolderInFilesIsListedAsItIs() throws {
        let (picked, export) = try pickedFolder()
        XCTAssertEqual(export.meta?.titleId, "0100152000022000")
        XCTAssertEqual(export.files, [CartoucheSwitchSaveItem(path: "ghosts/1.bin", size: 5),
                                      CartoucheSwitchSaveItem(path: "userdata.dat", size: 24)])
        XCTAssertEqual(export.folders, ["empty", "ghosts"])
        // A link is listed as one, never followed.
        try FileManager.default.createSymbolicLink(atPath: picked.appendingPathComponent("elsewhere").path,
                                                   withDestinationPath: "userdata.dat")
        let items = try CartoucheSwitchSave.items(inFolder: picked)
        XCTAssertEqual(items.first { $0.path == "elsewhere" }?.isLink, true)
        XCTAssertEqual(problem { try CartoucheSwitchSave.export(of: items) }, .unsafe("elsewhere"))
    }

    func testTheSaveComesInPlaceAndTheOneItReplacesIsKept() throws {
        let game = try documents([])
        let old = afternoon.addingTimeInterval(-86_400)
        try write("progress on the iPhone", to: game.appendingPathComponent("save/userdata.dat"), date: old)
        try write("console", to: game.appendingPathComponent("save_device/common.dat"), date: old)
        let (picked, export) = try pickedFolder()
        let staged = folder.appendingPathComponent("staged", isDirectory: true)
        try CartoucheSwitchSave.stage(export, from: picked, as: "save", into: staged)
        let now = afternoon
        let backup = try XCTUnwrap(CartoucheSwitchSave.place(staged, in: game, now: now))

        let save = game.appendingPathComponent("save", isDirectory: true)
        XCTAssertEqual(text(save.appendingPathComponent("userdata.dat")), "progress from the Switch")
        XCTAssertEqual(text(save.appendingPathComponent("ghosts/1.bin")), "ghost")
        XCTAssertTrue(FileManager.default.fileExists(atPath: save.appendingPathComponent("empty").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: save.appendingPathComponent(".nx_save_meta.bin").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: save.appendingPathComponent(".DS_Store").path))
        // Dated at the import: the newest save, which the syncs send on.
        XCTAssertEqual(modified(save.appendingPathComponent("userdata.dat")), now)
        XCTAssertEqual(modified(save.appendingPathComponent("ghosts/1.bin")), now)
        XCTAssertEqual(modified(save.appendingPathComponent("ghosts")), now)
        // The folder it replaced is kept, as it was; the other is left alone.
        XCTAssertEqual(text(backup.appendingPathComponent("save/userdata.dat")), "progress on the iPhone")
        XCTAssertEqual(modified(backup.appendingPathComponent("save/userdata.dat")), old)
        XCTAssertFalse(FileManager.default.fileExists(atPath: backup.appendingPathComponent("save_device").path))
        XCTAssertEqual(text(game.appendingPathComponent("save_device/common.dat")), "console")
        XCTAssertEqual(modified(game.appendingPathComponent("save_device/common.dat")), old)
        // Named as nxnative names its backups, which it leaves alone.
        XCTAssertEqual(backup.deletingLastPathComponent().lastPathComponent, "save-backups")
        XCTAssertEqual(CartoucheSwitchSave.date(ofBackup: backup.lastPathComponent, side: "before import"), now)
        XCTAssertEqual(CartoucheSwitchSave.backups("before import", in: game).map(\.folder.lastPathComponent),
                       [backup.lastPathComponent])
        // The folder picked is as it was.
        XCTAssertEqual(text(picked.appendingPathComponent("userdata.dat")), "progress from the Switch")
    }

    /// What nxnative left of its working copy of the save replaced goes: an
    /// older build of nxnative could start the game from it, without the
    /// save that came.
    func testNxnativesWorkingCopyOfTheSaveReplacedGoes() throws {
        let game = try documents([])
        try write("progress on the iPhone", to: game.appendingPathComponent("save/userdata.dat"))
        try write("progress on the iPhone", to: game.appendingPathComponent("save.work/userdata.dat"))
        try write("half a commit", to: game.appendingPathComponent("save.new/userdata.dat"))
        try write("console", to: game.appendingPathComponent("save_device.work/common.dat"))
        let (picked, export) = try pickedFolder()
        let staged = folder.appendingPathComponent("staged", isDirectory: true)
        try CartoucheSwitchSave.stage(export, from: picked, as: "save", into: staged)
        try CartoucheSwitchSave.place(staged, in: game, now: afternoon)

        XCTAssertEqual(text(game.appendingPathComponent("save/userdata.dat")), "progress from the Switch")
        XCTAssertFalse(FileManager.default.fileExists(atPath: game.appendingPathComponent("save.work").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: game.appendingPathComponent("save.new").path))
        // The console's save stayed, and its working copy with it.
        XCTAssertEqual(text(game.appendingPathComponent("save_device.work/common.dat")), "console")
    }

    func testTheConsolesSaveReplacesOnlyItsFolder() throws {
        let game = try documents([])
        try write("player", to: game.appendingPathComponent("save/userdata.dat"))
        try write("console", to: game.appendingPathComponent("save_device/common.dat"))
        let staged = folder.appendingPathComponent("staged", isDirectory: true)
        try write("console from the Switch", to: staged.appendingPathComponent("save_device/common.dat"))
        let backup = try XCTUnwrap(CartoucheSwitchSave.place(staged, in: game, now: afternoon))
        XCTAssertEqual(text(game.appendingPathComponent("save_device/common.dat")), "console from the Switch")
        XCTAssertEqual(text(game.appendingPathComponent("save/userdata.dat")), "player")
        XCTAssertEqual(text(backup.appendingPathComponent("save_device/common.dat")), "console")
        XCTAssertFalse(FileManager.default.fileExists(atPath: backup.appendingPathComponent("save").path))
    }

    func testAGameWithoutASaveKeepsNothing() throws {
        let game = folder.appendingPathComponent("Never started/Documents", isDirectory: true)
        let staged = folder.appendingPathComponent("staged", isDirectory: true)
        try write("from the Switch", to: staged.appendingPathComponent("save/game.sav"))
        XCTAssertNil(try CartoucheSwitchSave.place(staged, in: game, now: afternoon))
        XCTAssertEqual(text(game.appendingPathComponent("save/game.sav")), "from the Switch")
        XCTAssertFalse(FileManager.default.fileExists(atPath: game.appendingPathComponent("save-backups").path))
    }

    func testNothingChangesWhenTheSaveCannotBeKept() throws {
        let game = try documents([])
        try write("progress on the iPhone", to: game.appendingPathComponent("save/userdata.dat"))
        // save-backups is a file: no backup can be made there.
        try write("", to: game.appendingPathComponent("save-backups"))
        let staged = folder.appendingPathComponent("staged", isDirectory: true)
        try write("from the Switch", to: staged.appendingPathComponent("save/userdata.dat"))
        XCTAssertThrowsError(try CartoucheSwitchSave.place(staged, in: game, now: afternoon))
        XCTAssertEqual(text(game.appendingPathComponent("save/userdata.dat")), "progress on the iPhone")
        XCTAssertEqual(text(staged.appendingPathComponent("save/userdata.dat")), "from the Switch")
    }

    func testTheSaveFromBeforeTheImportComesBack() throws {
        let game = try documents([])
        try write("progress on the iPhone", to: game.appendingPathComponent("save/userdata.dat"))
        let staged = folder.appendingPathComponent("staged", isDirectory: true)
        try write("from the Switch", to: staged.appendingPathComponent("save/userdata.dat"))
        let backup = try XCTUnwrap(CartoucheSwitchSave.place(staged, in: game, now: afternoon))
        try write("played on from the Switch", to: game.appendingPathComponent("save/userdata.dat"))

        let later = afternoon.addingTimeInterval(3_600)
        try CartoucheSwitchSave.putBack(backup, in: game, now: later)
        XCTAssertEqual(text(game.appendingPathComponent("save/userdata.dat")), "progress on the iPhone")
        // Dated then, to win over the save it replaces in the syncs.
        XCTAssertEqual(modified(game.appendingPathComponent("save/userdata.dat")), later)
        XCTAssertFalse(FileManager.default.fileExists(atPath: backup.path))
        XCTAssertEqual(CartoucheSwitchSave.backups("before import", in: game), [])
        // What it replaced is kept too.
        let kept = try XCTUnwrap(CartoucheSwitchSave.backups("before putting back", in: game).first)
        XCTAssertEqual(kept.date, later)
        XCTAssertEqual(text(kept.folder.appendingPathComponent("save/userdata.dat")), "played on from the Switch")
    }

    func testTheNewestBackupsStayAndNxnativesAreLeftAlone() throws {
        let game = try documents(["save"])
        let backups = game.appendingPathComponent("save-backups", isDirectory: true)
        // Twelve imports, an hour apart, and nxnative's own backups.
        for hour in 0 ..< 12 {
            let backup = CartoucheSwitchSave.newBackup("before import", in: game, at: afternoon.addingTimeInterval(Double(hour) * 3_600))
            try write("save \(hour)", to: backup.appendingPathComponent("save/game.sav"))
        }
        for name in ["2026-11-01 10.00.00 local", "2026-11-01 10.00.00 cloud 2", "My own copy"] {
            try FileManager.default.createDirectory(at: backups.appendingPathComponent(name), withIntermediateDirectories: true)
        }
        let newest = CartoucheSwitchSave.backups("before import", in: game)[0].folder
        CartoucheSwitchSave.prune("before import", in: game, sparing: newest)
        let left = CartoucheSwitchSave.backups("before import", in: game)
        XCTAssertEqual(left.count, CartoucheSwitchSave.kept)
        XCTAssertEqual(left.first?.date, afternoon.addingTimeInterval(11 * 3_600))
        XCTAssertEqual(left.last?.date, afternoon.addingTimeInterval(2 * 3_600))
        for name in ["2026-11-01 10.00.00 local", "2026-11-01 10.00.00 cloud 2", "My own copy"] {
            XCTAssertTrue(FileManager.default.fileExists(atPath: backups.appendingPathComponent(name).path), name)
        }
    }

    // MARK: Sending it to the Switch

    func testTheSaveGoesToTheSwitchUnderTheGamesNames() throws {
        let save = folder.appendingPathComponent("Documents/save", isDirectory: true)
        try write("progress", to: save.appendingPathComponent("userdata.dat"), date: afternoon)
        try write("ghost", to: save.appendingPathComponent("ghosts/1.bin"))
        try FileManager.default.createDirectory(at: save.appendingPathComponent("empty"), withIntermediateDirectories: true)
        // Two names the game told apart by their capitals: nxnative named
        // the second .dm-case-1, with the game's in an attribute.
        try write("second", to: save.appendingPathComponent("ghosts/.dm-case-1"))
        try FileManager.default.createSymbolicLink(atPath: save.appendingPathComponent("link").path, withDestinationPath: "userdata.dat")
        let entries = try CartoucheSwitchSave.entries(ofSave: save) { url in
            url.lastPathComponent == ".dm-case-1" ? "1.BIN" : nil
        }
        XCTAssertEqual(entries.map(\.name), ["empty", "ghosts", "ghosts/1.BIN", "ghosts/1.bin", "userdata.dat"])
        XCTAssertEqual(entries.map(\.isFolder), [true, true, false, false, false])
        XCTAssertEqual(entries.first { $0.name == "ghosts/1.BIN" }?.url.lastPathComponent, ".dm-case-1")
        XCTAssertEqual(entries.last?.date, afternoon)
        // Without the attribute, the name stays.
        XCTAssertEqual(try CartoucheSwitchSave.entries(ofSave: save) { _ in nil }.map(\.name),
                       ["empty", "ghosts", "ghosts/.dm-case-1", "ghosts/1.bin", "userdata.dat"])
    }

    func testTheArchiveForTheSwitchIsNamedAsJKSVNamesItsOwn() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: afternoon)
        let stamp = String(format: "%04d-%02d-%02d_%02d-%02d-%02d", parts.year!, parts.month!, parts.day!,
                           parts.hour!, parts.minute!, parts.second!)
        XCTAssertEqual(CartoucheSwitchSave.archiveName(at: afternoon), "Cartouche - \(stamp).zip")
    }

    func testBackupsAreNamedAsNxnativeNamesItsOwn() throws {
        let game = try documents([])
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: afternoon)
        let stamp = String(format: "%04d-%02d-%02d %02d.%02d.%02d", parts.year!, parts.month!, parts.day!,
                           parts.hour!, parts.minute!, parts.second!)
        let first = CartoucheSwitchSave.newBackup("before import", in: game, at: afternoon)
        XCTAssertEqual(first.lastPathComponent, stamp + " before import")
        try FileManager.default.createDirectory(at: first, withIntermediateDirectories: true)
        let second = CartoucheSwitchSave.newBackup("before import", in: game, at: afternoon)
        XCTAssertEqual(second.lastPathComponent, stamp + " before import 2")
        XCTAssertEqual(CartoucheSwitchSave.date(ofBackup: second.lastPathComponent, side: "before import"), afternoon)
        XCTAssertNil(CartoucheSwitchSave.date(ofBackup: stamp + " local", side: "before import"))
        XCTAssertNil(CartoucheSwitchSave.date(ofBackup: stamp + " before imports", side: "before import"))
        XCTAssertNil(CartoucheSwitchSave.date(ofBackup: stamp + " before import x", side: "before import"))
        XCTAssertNil(CartoucheSwitchSave.date(ofBackup: "before import", side: "before import"))
    }
}
