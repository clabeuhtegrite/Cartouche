//
//  CartoucheSwitchSaveArchiveTests.swift
//  CartoucheCoreTests
//
//  A game's save between the player's Switch and this iPhone, in the folder
//  or the ZIP archive JKSV makes (Sources/CartoucheSwitchSaveArchive.swift):
//  an archive as JKSV writes it, read, unpacked and put in place of the
//  game's save; a folder zipped by macOS, without what macOS adds; a folder
//  picked in Files; a file that is no archive; and the archive Cartouche
//  writes for JKSV, its files at its root under the game's names, read back.
//

#if canImport(Darwin)
import Darwin
#endif
import Foundation
import XCTest
@testable import CartoucheCore

final class CartoucheSwitchSaveArchiveTests: XCTestCase {
    private var folder: URL!
    /// 13 Nov 2026, 15:20 UTC.
    private let afternoon = Date(timeIntervalSince1970: 1_794_583_200)
    /// Mario Kart 8 Deluxe's title ID.
    private let mk8d: UInt64 = 0x0100_1520_0002_2000

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("CartoucheSwitchSaveArchiveTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    /// Bytes that do not deflate, as most of a game's save.
    private func noise(_ count: Int, seed: UInt64) -> Data {
        var state = seed
        var data = Data(count: count)
        data.withUnsafeMutableBytes { (raw: UnsafeMutableRawBufferPointer) in
            for index in 0 ..< count {
                state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
                raw[index] = UInt8(truncatingIfNeeded: state >> 33)
            }
        }
        return data
    }

    /// Writes an archive named NAME in the test's folder, of ENTRIES: a
    /// folder for a name ending in "/", else a file of the data given.
    private func archive(_ name: String, _ entries: [(name: String, data: Data?)]) async throws -> URL {
        let sink = MemorySink()
        let writer = CartoucheZipWriter(sink: sink)
        for entry in entries {
            if let data = entry.data {
                try await writer.addData(entry.name, data)
            } else {
                try await writer.addFolder(entry.name)
            }
        }
        try await writer.finish()
        let url = folder.appendingPathComponent(name)
        try sink.data.write(to: url)
        return url
    }

    private func date(of url: URL) throws -> Date? {
        try FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date
    }

    // MARK: From the Switch

    /// JKSV's archive of a player's save: its files and its fiche at its
    /// root. The files take the place of the game's save, the fiche stays
    /// out, and the save they replace is kept.
    func testAJKSVArchiveComesInPlaceOfTheGamesSave() async throws {
        let progress = noise(70_000, seed: 1)
        let slot = Data(String(repeating: "slot 1 ", count: 40).utf8)
        let url = try await archive("Player - 2026-11-13_15-20-00.zip", [
            (CartoucheSwitchSaveMeta.fileName, CartoucheSwitchSaveTests.fiche(titleId: mk8d, type: 1)),
            ("progress.bin", progress),
            ("slots/", nil),
            ("slots/1.bin", slot),
        ])
        let pick = try await CartoucheSwitchSaveArchive.read(url)
        XCTAssertTrue(pick.isArchive)
        XCTAssertEqual(pick.export.meta?.titleId, "0100152000022000")
        XCTAssertEqual(pick.export.meta?.kind, .account)
        XCTAssertEqual(pick.export.files.map(\.path), ["progress.bin", "slots/1.bin"])
        XCTAssertEqual(pick.export.size, UInt64(progress.count + slot.count))
        XCTAssertEqual(pick.names.first, "Player - 2026-11-13_15-20-00")

        let documents = folder.appendingPathComponent("Documents", isDirectory: true)
        let save = documents.appendingPathComponent(CartoucheSwitchSave.saveFolder, isDirectory: true)
        try FileManager.default.createDirectory(at: save, withIntermediateDirectories: true)
        try Data("the iPhone's game".utf8).write(to: save.appendingPathComponent("progress.bin"))

        let destination = try CartoucheSwitchSave.folder(for: pick.export, game: ["0100152000022000"], names: pick.names,
                                                         documents: documents)
        XCTAssertEqual(destination, CartoucheSwitchSave.saveFolder)
        let work = folder.appendingPathComponent("work", isDirectory: true)
        let staged = work.appendingPathComponent("staged", isDirectory: true)
        try await CartoucheSwitchSaveArchive.stage(pick, as: destination, into: staged, work: work)
        let backup = try XCTUnwrap(CartoucheSwitchSave.place(staged, in: documents, now: afternoon))

        XCTAssertEqual(try Data(contentsOf: save.appendingPathComponent("progress.bin")), progress)
        XCTAssertEqual(try Data(contentsOf: save.appendingPathComponent("slots/1.bin")), slot)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: save.path).sorted(), ["progress.bin", "slots"])
        XCTAssertEqual(try date(of: save.appendingPathComponent("slots/1.bin")), afternoon)
        XCTAssertEqual(try String(contentsOf: backup.appendingPathComponent("save/progress.bin"), encoding: .utf8),
                       "the iPhone's game")
        // The fiche was never unpacked.
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: work.appendingPathComponent("unpacked/" + CartoucheSwitchSaveMeta.fileName).path))
    }

    /// A save's folder zipped by macOS: the save is inside, and what macOS
    /// adds is never unpacked.
    func testAFolderZippedByMacOSComesWithoutWhatMacOSAdds() async throws {
        let url = try await archive("Player.zip", [
            ("Player/", nil),
            ("Player/progress.bin", Data("game".utf8)),
            ("Player/.DS_Store", Data("Finder".utf8)),
            ("__MACOSX/", nil),
            ("__MACOSX/Player/", nil),
            ("__MACOSX/Player/._progress.bin", Data("resource fork".utf8)),
        ])
        let pick = try await CartoucheSwitchSaveArchive.read(url)
        XCTAssertNil(pick.export.meta)
        XCTAssertEqual(pick.export.root, "Player/")
        XCTAssertEqual(pick.export.files.map(\.path), ["progress.bin"])

        let work = folder.appendingPathComponent("work", isDirectory: true)
        let staged = work.appendingPathComponent("staged", isDirectory: true)
        try await CartoucheSwitchSaveArchive.stage(pick, as: CartoucheSwitchSave.saveFolder, into: staged, work: work)
        let save = staged.appendingPathComponent(CartoucheSwitchSave.saveFolder)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: save.path), ["progress.bin"])
        XCTAssertEqual(try String(contentsOf: save.appendingPathComponent("progress.bin"), encoding: .utf8), "game")
        XCTAssertFalse(FileManager.default.fileExists(atPath: work.appendingPathComponent("unpacked/__MACOSX").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: work.appendingPathComponent("unpacked/Player/.DS_Store").path))
    }

    /// JKSV's folder of a console's save, picked in Files: read with its
    /// fiche, and copied, the folder left as it was.
    func testAFolderPickedInFilesIsReadWithItsFicheAndCopied() async throws {
        let picked = folder.appendingPathComponent("Player - 2026-11-13_15-20-00", isDirectory: true)
        try FileManager.default.createDirectory(at: picked.appendingPathComponent("island"), withIntermediateDirectories: true)
        try CartoucheSwitchSaveTests.fiche(titleId: 0x0100_6F80_0232_6000, type: 3)
            .write(to: picked.appendingPathComponent(CartoucheSwitchSaveMeta.fileName))
        try Data("villagers".utf8).write(to: picked.appendingPathComponent("island/main.dat"))

        let pick = try await CartoucheSwitchSaveArchive.read(picked)
        XCTAssertFalse(pick.isArchive)
        XCTAssertEqual(pick.export.meta?.titleId, "01006F8002326000")
        XCTAssertEqual(pick.export.meta?.kind, .device)
        XCTAssertEqual(pick.export.files.map(\.path), ["island/main.dat"])

        let work = folder.appendingPathComponent("work", isDirectory: true)
        let staged = work.appendingPathComponent("staged", isDirectory: true)
        try await CartoucheSwitchSaveArchive.stage(pick, as: CartoucheSwitchSave.saveFolder, into: staged, work: work)
        XCTAssertEqual(try String(contentsOf: staged.appendingPathComponent("save/island/main.dat"), encoding: .utf8), "villagers")
        XCTAssertFalse(FileManager.default.fileExists(atPath: staged.appendingPathComponent("save/" + CartoucheSwitchSaveMeta.fileName).path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: picked.appendingPathComponent("island/main.dat").path))
    }

    /// A file that is no ZIP archive is one Cartouche cannot read
    /// (CartoucheSwitchSaveView: "It is not a save Cartouche can read").
    func testAFileThatIsNoArchiveIsUnreadable() async throws {
        let url = folder.appendingPathComponent("Save.zip")
        try Data(String(repeating: "not a zip archive\n", count: 4).utf8).write(to: url)
        do {
            _ = try await CartoucheSwitchSaveArchive.read(url)
            XCTFail("An archive was read")
        } catch is CartoucheZipError {
        }
    }

    /// An archive with an entry that would land outside the save is refused
    /// before anything is unpacked.
    func testAnArchiveThatWouldLandOutsideTheSaveIsRefused() async throws {
        let url = try await archive("Player.zip", [
            ("progress.bin", Data("game".utf8)),
            ("../../Documents/progress.bin", Data("elsewhere".utf8)),
        ])
        do {
            _ = try await CartoucheSwitchSaveArchive.read(url)
            XCTFail("The archive was read")
        } catch let problem as CartoucheSwitchSaveProblem {
            XCTAssertEqual(problem, .unsafe("../../Documents/progress.bin"))
        }
    }

    // MARK: To the Switch

    /// The archive for JKSV holds the save's files and folders at its root,
    /// without the save's folder around them and without a fiche, which
    /// JKSV restores without.
    func testTheZipForJKSVHoldsTheSaveAtItsRoot() async throws {
        let save = folder.appendingPathComponent("Documents/save", isDirectory: true)
        try FileManager.default.createDirectory(at: save.appendingPathComponent("slots"), withIntermediateDirectories: true)
        let progress = noise(70_000, seed: 2)
        try progress.write(to: save.appendingPathComponent("progress.bin"))
        try Data("slot".utf8).write(to: save.appendingPathComponent("slots/1.bin"))

        let sink = MemorySink()
        let files = try await CartoucheSwitchSaveArchive.writeZip(ofSave: save, to: sink)
        XCTAssertEqual(files, 2)
        let source = MemorySource(sink.data)
        let entries = try await CartoucheZip.entries(of: source)
        XCTAssertEqual(entries.map(\.name).sorted(), ["progress.bin", "slots/", "slots/1.bin"])
        XCTAssertTrue(entries.first { $0.name == "slots/" }?.isDirectory ?? false)
        let entry = try XCTUnwrap(entries.first { $0.name == "progress.bin" })
        let data = try await CartoucheZip.data(of: entry, in: source)
        XCTAssertEqual(data, progress)
    }

    /// The archive Cartouche makes for the Switch is a save Cartouche reads
    /// back as it was: the same files, the same bytes.
    func testTheZipForJKSVComesBackAsTheSameSave() async throws {
        let save = folder.appendingPathComponent("Documents/save", isDirectory: true)
        try FileManager.default.createDirectory(at: save.appendingPathComponent("slots/old"), withIntermediateDirectories: true)
        let progress = noise(300_000, seed: 3)
        try progress.write(to: save.appendingPathComponent("progress.bin"))
        try Data(String(repeating: "options ", count: 30).utf8).write(to: save.appendingPathComponent("slots/options.ini"))

        let url = folder.appendingPathComponent(CartoucheSwitchSave.archiveName(at: afternoon))
        let sink = try CartoucheFileSink(url)
        try await CartoucheSwitchSaveArchive.writeZip(ofSave: save, to: sink)
        try sink.close()

        let pick = try await CartoucheSwitchSaveArchive.read(url)
        XCTAssertNil(pick.export.meta)
        XCTAssertEqual(pick.export.root, "")
        XCTAssertEqual(pick.export.files.map(\.path), ["progress.bin", "slots/options.ini"])
        XCTAssertEqual(pick.export.folders, ["slots", "slots/old"])

        let work = folder.appendingPathComponent("work", isDirectory: true)
        let staged = work.appendingPathComponent("staged", isDirectory: true)
        try await CartoucheSwitchSaveArchive.stage(pick, as: CartoucheSwitchSave.saveFolder, into: staged, work: work)
        let back = staged.appendingPathComponent(CartoucheSwitchSave.saveFolder)
        XCTAssertEqual(try Data(contentsOf: back.appendingPathComponent("progress.bin")), progress)
        XCTAssertEqual(try Data(contentsOf: back.appendingPathComponent("slots/options.ini")),
                       try Data(contentsOf: save.appendingPathComponent("slots/options.ini")))
        // An empty folder of the save comes back too.
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: back.appendingPathComponent("slots/old").path), [])
    }

    #if canImport(Darwin)
    /// A file nxnative named .dm-case-N, as the iPhone's names ignore
    /// capitals, goes to the Switch under the name the game gave it, which
    /// nxnative keeps in an attribute of the file.
    func testAFileNxnativeRenamedGoesUnderTheGamesName() async throws {
        let save = folder.appendingPathComponent("Documents/save", isDirectory: true)
        try FileManager.default.createDirectory(at: save, withIntermediateDirectories: true)
        try Data("lower".utf8).write(to: save.appendingPathComponent("progress.bin"))
        let renamed = save.appendingPathComponent(".dm-case-0")
        try Data("capitals".utf8).write(to: renamed)
        let name = Array("Progress.BIN".utf8)
        XCTAssertEqual(setxattr(renamed.path, CartoucheSwitchSave.guestNameAttribute, name, name.count, 0, XATTR_NOFOLLOW), 0)
        XCTAssertEqual(CartoucheSwitchSave.guestName(of: renamed), "Progress.BIN")
        XCTAssertNil(CartoucheSwitchSave.guestName(of: save.appendingPathComponent("progress.bin")))

        let sink = MemorySink()
        let files = try await CartoucheSwitchSaveArchive.writeZip(ofSave: save, to: sink)
        XCTAssertEqual(files, 2)
        let source = MemorySource(sink.data)
        let entries = try await CartoucheZip.entries(of: source)
        XCTAssertEqual(entries.map(\.name).sorted(), ["Progress.BIN", "progress.bin"])
        let entry = try XCTUnwrap(entries.first { $0.name == "Progress.BIN" })
        let data = try await CartoucheZip.data(of: entry, in: source)
        XCTAssertEqual(String(decoding: data, as: UTF8.self), "capitals")
    }
    #endif
}
