//
//  UnpackTests.swift
//  CartoucheHarnessTests
//
//  The two ways Cartouche unpacks an IPA, on the same archives:
//  LiveContainer's unpacker (unarchive.m, on the iPhone's libarchive), for
//  an IPA on the iPhone, from the Files picker or another app; Cartouche's
//  own reader (CartoucheZip), for one in the player's games folder, read
//  where it sits. Both must give the folder the IPA holds, file for file,
//  byte for byte, with the files' permissions and links, whether the IPA
//  is in Zip64, as nxnative's large ones are, or not, its files deflated
//  or stored; and both must say so when they could not.
//

import XCTest
@testable import CartoucheHarness

final class UnpackTests: HarnessCase {
    /// What a folder holds at a path.
    private enum Item: Equatable, CustomStringConvertible {
        case folder(mode: Int)
        case file(Data, mode: Int)
        case link(String)

        var description: String {
            switch self {
            case .folder(let mode):
                return "a folder, mode " + String(mode, radix: 8)
            case .file(let data, let mode):
                return "\(data.count) bytes of CRC-32 " + String(HarnessCRC32.checksum(data), radix: 16)
                    + ", mode " + String(mode, radix: 8)
            case .link(let target):
                return "a link to " + target
            }
        }
    }

    /// An IPA to unpack: the entries it holds, and how it is written.
    private struct Variant {
        let label: String
        let entries: [HarnessZip.Entry]
        let zip64: Bool
    }

    /// GAME's IPA in Zip64 or not, its files deflated, as zip does, or all
    /// stored, as nxnative's pack_ipa.py stores a large romfs.img.
    private func variants(of game: HarnessGame) -> [Variant] {
        let stored = game.files.map { entry -> HarnessZip.Entry in
            var entry = entry
            entry.method = .store
            return entry
        }
        return [
            Variant(label: "Zip64, deflated", entries: game.files, zip64: true),
            Variant(label: "deflated", entries: game.files, zip64: false),
            Variant(label: "Zip64, stored", entries: stored, zip64: true),
            Variant(label: "stored", entries: stored, zip64: false),
        ]
    }

    /// A new empty folder of the test's.
    private func newFolder(_ name: String) throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("HarnessUnpack", isDirectory: true)
            .appendingPathComponent(name, isDirectory: true)
        try? FileManager.default.removeItem(at: folder)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    /// LiveContainer's unpacker on the IPA at IPA, off the main thread, as
    /// the install runs it: what it returned, and its progress. CANCELLED:
    /// the install was stopped before.
    private func unpackWithLiveContainer(_ ipa: URL, into folder: URL,
                                         cancelled: Bool = false) async -> (status: Int32, progress: Progress) {
        let progress = Progress.discreteProgress(totalUnitCount: 0)
        if cancelled { progress.cancel() }
        let box = HarnessBox(progress)
        let status = await Task.detached { HarnessUnarchive.unpack(ipa.path, into: folder.path, progress: box.value) }.value
        return (status, progress)
    }

    /// Cartouche's reader on the IPA at IPA, as an install from the games
    /// folder runs it: its progress.
    @discardableResult
    private func unpackWithCartouche(_ ipa: URL, into folder: URL) async throws -> Progress {
        let progress = Progress.discreteProgress(totalUnitCount: 0)
        let source = try CartoucheFileSource(ipa)
        let entries = try await CartoucheZip.entries(of: source)
        try await CartoucheZip.extract(source, entries: entries, into: folder, progress: progress)
        return progress
    }

    /// What the folder at FOLDER holds, by path, a folder's ending with "/".
    private func contents(of folder: URL) throws -> [String: Item] {
        let fileManager = FileManager.default
        var found: [String: Item] = [:]
        guard let walker = fileManager.enumerator(atPath: folder.path) else { return found }
        while let relative = walker.nextObject() as? String {
            let path = folder.appendingPathComponent(relative).path
            let attributes = try fileManager.attributesOfItem(atPath: path)
            let mode = (attributes[.posixPermissions] as? NSNumber)?.intValue ?? -1
            switch attributes[.type] as? FileAttributeType {
            case .typeDirectory?:
                found[relative + "/"] = .folder(mode: mode)
            case .typeSymbolicLink?:
                found[relative] = .link(try fileManager.destinationOfSymbolicLink(atPath: path))
            default:
                found[relative] = .file(try Data(contentsOf: URL(fileURLWithPath: path)), mode: mode)
            }
        }
        return found
    }

    /// What unpacking ENTRIES gives.
    private func expected(_ entries: [HarnessZip.Entry]) -> [String: Item] {
        var items: [String: Item] = [:]
        for entry in entries {
            switch entry.kind {
            case .folder: items[entry.name] = .folder(mode: Int(entry.mode))
            case .file: items[entry.name] = .file(entry.data, mode: Int(entry.mode))
            case .link: items[entry.name] = .link(String(decoding: entry.data, as: UTF8.self))
            }
        }
        return items
    }

    /// Fails unless FOLDER holds ENTRIES and nothing else.
    private func assertHolds(_ folder: URL, _ entries: [HarnessZip.Entry], _ label: String,
                             file: StaticString = #filePath, line: UInt = #line) throws {
        let found = try contents(of: folder)
        let wanted = expected(entries)
        XCTAssertEqual(found.keys.sorted(), wanted.keys.sorted(), "\(label): what the IPA holds, and nothing else",
                       file: file, line: line)
        for (path, item) in wanted.sorted(by: { $0.key < $1.key }) where found[path] != nil && found[path] != item {
            XCTFail("\(label): \(path) is \(found[path]!), not \(item)", file: file, line: line)
        }
    }

    // MARK: LiveContainer's unpacker

    func testLiveContainerUnpacksAGameAsItWasPacked() async throws {
        let game = HarnessGame.plain()
        for variant in variants(of: game) {
            let ipa = try HarnessIPA.write(variant.entries, named: "\(variant.label).ipa", zip64: variant.zip64)
            let folder = try newFolder(variant.label)
            let (status, progress) = await unpackWithLiveContainer(ipa, into: folder)
            XCTAssertEqual(status, 0, variant.label)
            try assertHolds(folder, variant.entries, variant.label)

            // The console's progress: every byte of the game, all written.
            let size = Int64(variant.entries.reduce(0) { $0 + $1.data.count })
            XCTAssertEqual(progress.totalUnitCount, size, "\(variant.label): the bytes to write")
            XCTAssertEqual(progress.completedUnitCount, size, "\(variant.label): the bytes written")
        }
    }

    func testLiveContainerRefusesBytesThatAreNoArchive() async throws {
        let folder = try newFolder("not a zip")
        let (status, _) = await unpackWithLiveContainer(try HarnessIPA.notAZip(), into: folder)
        XCTAssertEqual(status, 1)
        XCTAssertTrue(listing(of: folder).isEmpty)
    }

    func testLiveContainerRefusesAnIPACutShort() async throws {
        let ipa = try HarnessIPA.game(.plain())
        // In the executable, in romfs.img, in MoltenVK: a damaged archive,
        // not a file that is no archive (patch 0011).
        for fraction in [0.1, 0.5, 0.9] {
            let cut = try HarnessIPA.cut(ipa, keeping: fraction, named: "Cut at \(fraction).ipa")
            let (status, _) = await unpackWithLiveContainer(cut, into: try newFolder("cut at \(fraction)"))
            XCTAssertEqual(status, 2, "an IPA cut at \(Int(fraction * 100)) % of it")
        }
    }

    func testLiveContainerRefusesAnIPAWhoseFileChanged() async throws {
        let game = HarnessGame.plain()
        // libarchive reads a stored file whose CRC-32 does not match with a
        // warning only, and a deflated one may inflate to other bytes: both
        // are damaged (patch 0011).
        for method in [HarnessZip.Method.store, .deflate] {
            let label = method == .store ? "stored" : "deflated"
            let damaged = try HarnessIPA.damaged(game, in: "romfs.img", named: "Damaged \(label).ipa", method: method)
            let (status, _) = await unpackWithLiveContainer(damaged, into: try newFolder("damaged \(label)"))
            XCTAssertEqual(status, 2, "an IPA whose \(label) romfs.img changed")
        }
    }

    func testLiveContainerStopsOnceTheInstallIsCancelled() async throws {
        let folder = try newFolder("cancelled")
        let (status, progress) = await unpackWithLiveContainer(try HarnessIPA.game(.plain()), into: folder, cancelled: true)
        XCTAssertEqual(status, 1, "a stopped install is no install (patch 0009)")
        XCTAssertEqual(progress.completedUnitCount, 0)
        XCTAssertTrue(listing(of: folder).isEmpty, "nothing unpacked")
    }

    // MARK: Cartouche's reader, as LiveContainer's

    func testCartouchesReaderGivesTheFolderLiveContainersDoes() async throws {
        let game = HarnessGame.plain(1)
        for variant in variants(of: game) {
            let ipa = try HarnessIPA.write(variant.entries, named: "\(variant.label).ipa", zip64: variant.zip64)
            let source = try CartoucheFileSource(ipa)
            let entries = try await CartoucheZip.entries(of: source)
            XCTAssertEqual(entries.map(\.name), variant.entries.map(\.name), "\(variant.label): the central directory, in order")

            let byCartouche = try newFolder(variant.label + ", Cartouche")
            let progress = try await unpackWithCartouche(ipa, into: byCartouche)
            try assertHolds(byCartouche, variant.entries, variant.label)
            XCTAssertEqual(progress.totalUnitCount, Int64(variant.entries.reduce(0) { $0 + $1.data.count }))
            XCTAssertEqual(progress.completedUnitCount, progress.totalUnitCount)

            let byLiveContainer = try newFolder(variant.label + ", LiveContainer")
            let (status, _) = await unpackWithLiveContainer(ipa, into: byLiveContainer)
            XCTAssertEqual(status, 0)
            XCTAssertEqual(try contents(of: byCartouche), try contents(of: byLiveContainer),
                           "\(variant.label): both give the same folder")
        }
    }

    func testLinksInAnIPAStayLinksWithBothReaders() async throws {
        // A framework as Xcode lays one out for the Mac, which an app's
        // IPA may carry: links to the version it holds.
        let app = "Payload/Engine.app/"
        let framework = app + "Frameworks/Engine.framework/"
        let entries: [HarnessZip.Entry] = [
            .folder("Payload/"), .folder(app),
            .file(app + "Info.plist", HarnessIPA.plist(["CFBundleIdentifier": "com.example.harness.engine",
                                                        "CFBundleExecutable": "Engine"])),
            .file(app + "Engine", HarnessMachOFile.executable(sdk: 0x001A_0000), mode: 0o755),
            .folder(app + "Frameworks/"), .folder(framework),
            .folder(framework + "Versions/"), .folder(framework + "Versions/A/"),
            .file(framework + "Versions/A/Engine", HarnessMachOFile.library(), mode: 0o755),
            .link(framework + "Versions/Current", to: "A"),
            .link(framework + "Engine", to: "Versions/Current/Engine"),
        ]
        for zip64 in [true, false] {
            let label = zip64 ? "Zip64" : "zip"
            let ipa = try HarnessIPA.write(entries, named: "Engine \(label).ipa", zip64: zip64)
            let byLiveContainer = try newFolder("links, LiveContainer, " + label)
            let (status, _) = await unpackWithLiveContainer(ipa, into: byLiveContainer)
            XCTAssertEqual(status, 0)
            try assertHolds(byLiveContainer, entries, "LiveContainer, " + label)
            let byCartouche = try newFolder("links, Cartouche, " + label)
            try await unpackWithCartouche(ipa, into: byCartouche)
            try assertHolds(byCartouche, entries, "Cartouche, " + label)
            XCTAssertEqual(try Data(contentsOf: byCartouche.appendingPathComponent(framework + "Engine")),
                           HarnessMachOFile.library(), "the link leads to the library")
        }
    }

    func testCartouchesReaderRefusesAnIPACutShort() async throws {
        let cut = try HarnessIPA.cut(try HarnessIPA.game(.plain()), keeping: 0.5, named: "Cut.ipa")
        do {
            try await unpackWithCartouche(cut, into: try newFolder("cut"))
            XCTFail("an IPA cut short unpacks")
        } catch {
            XCTAssertTrue(error is CartoucheZipError, "\(error)")
        }
    }

    func testCartouchesReaderRefusesAFileWhoseBytesChanged() async throws {
        let game = HarnessGame.plain()
        let damaged = try HarnessIPA.damaged(game, in: "romfs.img", named: "Damaged.ipa")
        do {
            try await unpackWithCartouche(damaged, into: try newFolder("damaged"))
            XCTFail("an IPA whose romfs.img changed unpacks")
        } catch {
            let message = (error as? CartoucheZipError)?.message ?? "\(error)"
            XCTAssertTrue(message.contains("romfs.img is damaged"), message)
        }
    }
}
