//
//  CartoucheRomfsTests.swift
//  CartoucheCoreTests
//
//  The game files of an IPA nxnative built without them
//  (Sources/CartoucheRomfs.swift): romfs.id's line, the identity of an
//  image as nxnative and Cartouche Builder compute it, the IPAs that need
//  one, the copy into a game's app, and which image of the games folder
//  goes with which IPA.
//

import Foundation
import XCTest
@testable import CartoucheCore

final class CartoucheRomfsTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("CartoucheRomfsTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    // MARK: romfs.id

    func testReadsTheLineNxnativeWrites() throws {
        let identity = try XCTUnwrap(CartoucheRomfsIdentity(
            line: "DMROMFSID1 title=09D00E8A5D61A000 version=1.0 build=v0 size=105 index=c7a11b1c1eec2709\n"))
        XCTAssertEqual(identity.size, 105)
        XCTAssertEqual(identity.index, "c7a11b1c1eec2709")
        XCTAssertEqual(identity.title, "09D00E8A5D61A000")
        XCTAssertEqual(identity.version, "1.0")
    }

    func testTheSizeAndTheIndexAloneDecide() throws {
        // As Cartouche Builder takes it: the names are only labels
        // (builder/tests/test_bundle.py).
        for line in ["DMROMFSID1 size=105 index=c7a11b1c1eec2709",
                     "DMROMFSID1 title= size=105 index=c7a11b1c1eec2709\r\n",
                     "DMROMFSID1\ttitle=0100000000010000\tsize=105\tindex=C7A11B1C1EEC2709\nmore"] {
            let identity = try XCTUnwrap(CartoucheRomfsIdentity(line: line), line)
            XCTAssertEqual(identity, CartoucheRomfsIdentity(size: 105, index: 0xC7A1_1B1C_1EEC_2709,
                                                            title: identity.title, version: identity.version), line)
            XCTAssertTrue(identity.isMet(by: CartoucheRomfsIdentity(size: 105, index: 0xC7A1_1B1C_1EEC_2709)), line)
        }
        XCTAssertEqual(CartoucheRomfsIdentity(size: 1, index: 0xAB).index, "00000000000000ab")
    }

    func testRefusesAnotherLine() {
        for line in ["", "DMROMFSID2 size=105 index=c7a11b1c1eec2709", "DMROMFSID1x size=105 index=c7a11b1c1eec2709",
                     "DMROMFSID1 size=105", "DMROMFSID1 index=c7a11b1c1eec2709", "DMROMFSID1 size=-1 index=c7a11b1c1eec2709",
                     "DMROMFSID1 size=105 index=zz", " DMROMFSID1 size=105 index=c7a11b1c1eec2709"] {
            XCTAssertNil(CartoucheRomfsIdentity(line: line), line)
        }
    }

    // MARK: The image

    func testTheIdentityOfAnImageIsNxnatives() async throws {
        // Fixed by Cartouche Builder's reference implementation
        // (builder/cartouche_builder/romfs.py), from nxnative's
        // dm/host/romfs_identity.h.
        let whole = try await CartoucheRomfs.identity(ofImage: MemorySource(image()))
        XCTAssertEqual(whole, CartoucheRomfsIdentity(size: 105, index: 0xC7A1_1B1C_1EEC_2709))
        // An index whose last word the hash completes with zeros.
        let padded = try await CartoucheRomfs.identity(ofImage: MemorySource(image(extra: Data([1, 2, 3, 4, 5]))))
        XCTAssertEqual(padded, CartoucheRomfsIdentity(size: 110, index: 0x67B2_FCD8_0BF8_5089))
    }

    func testReadsTheHeaderAndTheIndexNeverTheGameData() async throws {
        let payload = Data((0 ..< 1_048_576).map { UInt8(truncatingIfNeeded: $0) })
        let source = MemorySource(image(payload: payload))
        let identity = try await CartoucheRomfs.identity(ofImage: source)
        XCTAssertEqual(identity, CartoucheRomfsIdentity(size: 1_048_664, index: 0xEE48_4E15_E588_B3D3))
        XCTAssertEqual(source.reads.reduce(0) { $0 + $1.count }, 32 + 56)
    }

    func testAFileThatIsNoWholeImageHasNoIdentity() async throws {
        let whole = image()
        var otherMagic = whole
        otherMagic[0] = UInt8(ascii: "X")
        var noEntries = whole
        noEntries.replaceSubrange(24 ..< 32, with: le(UInt64(0)))
        var indexTooEarly = whole
        indexTooEarly.replaceSubrange(8 ..< 16, with: le(UInt64(16)))
        var indexTooLong = whole
        indexTooLong.replaceSubrange(16 ..< 24, with: le(UInt64(57)))
        for (name, data) in [("cut off", whole.dropLast()), ("too short", whole.prefix(31)), ("empty", Data()),
                             ("another magic", otherMagic), ("no entries", noEntries),
                             ("index in the header", indexTooEarly), ("index past the end", indexTooLong)] {
            let identity = try await CartoucheRomfs.identity(ofImage: MemorySource(Data(data)))
            XCTAssertNil(identity, name)
        }
    }

    func testTheHashIsTheSameFedInAnyPieces() {
        let data = Data((0 ..< 1_000).map { UInt8(truncatingIfNeeded: $0 &* 37 &+ 11) })
        var whole = CartoucheWordHash()
        whole.mix(data)
        let expected = whole.finish()
        for piece in [1, 3, 7, 8, 13, 64, 999] {
            var hash = CartoucheWordHash()
            var at = 0
            while at < data.count {
                hash.mix(data[at ..< min(at + piece, data.count)])
                at += piece
            }
            hash.mix(Data())
            XCTAssertEqual(hash.finish(), expected, "pieces of \(piece)")
        }
    }

    func testNamesOfImages() {
        for name in ["romfs.img", "RomFS.img", "ROMFS.IMG", "Zelda.romfs.img", "Zelda RomFS.img"] {
            XCTAssertTrue(CartoucheRomfs.isImageName(name), name)
        }
        for name in ["._romfs.img", ".romfs.img", "romfs.img.part", "romfs.bin", "romfs", "romfs.id", "game.img"] {
            XCTAssertFalse(CartoucheRomfs.isImageName(name), name)
        }
    }

    func testTheImageOfAFolderInAnyCase() throws {
        XCTAssertNil(CartoucheRomfs.image(in: folder))
        try Data().write(to: folder.appendingPathComponent("._RomFS.img"))
        try Data().write(to: folder.appendingPathComponent("Zelda.romfs.img"))
        XCTAssertNil(CartoucheRomfs.image(in: folder), "nxnative reads romfs.img alone, in any case")
        try Data().write(to: folder.appendingPathComponent("RomFS.img"))
        XCTAssertEqual(CartoucheRomfs.image(in: folder)?.lastPathComponent, "RomFS.img")
        XCTAssertNil(CartoucheRomfs.image(in: folder.appendingPathComponent("missing")))
    }

    // MARK: The IPA

    func testAnIPABuiltWithoutItsGameFilesNeedsTheImageItNames() async throws {
        let source = try await ipa(["Game": Data("binary".utf8),
                                    "romfs.id": Data("DMROMFSID1 title=09D00E8A5D61A000 size=105 index=c7a11b1c1eec2709\n".utf8)])
        let entries = try await CartoucheZip.entries(of: source)
        XCTAssertEqual(CartoucheRomfs.appFolder(in: entries), "Payload/Game.app/")
        XCTAssertEqual(CartoucheRomfs.identityEntry(in: entries)?.name, "Payload/Game.app/romfs.id")
        let needed = try await CartoucheRomfs.neededIdentity(ofIPA: source, entries: entries)
        XCTAssertEqual(needed?.size, 105)
        XCTAssertEqual(needed?.index, "c7a11b1c1eec2709")
        XCTAssertEqual(needed?.title, "09D00E8A5D61A000")
    }

    func testAnIPAThatHoldsItsGameFilesNeedsNone() async throws {
        let line = Data("DMROMFSID1 size=105 index=c7a11b1c1eec2709\n".utf8)
        for files in [["romfs.id": line, "romfs.img": image()],
                      ["romfs.id": line, "romfs/": Data(), "romfs/data.bin": Data("data".utf8)],
                      ["Game": Data("binary".utf8)],
                      ["Plugins/romfs.id": line]] {
            let source = try await ipa(files)
            let entries = try await CartoucheZip.entries(of: source)
            let needed = try await CartoucheRomfs.neededIdentity(ofIPA: source, entries: entries)
            XCTAssertNil(needed, files.keys.sorted().joined(separator: ", "))
        }
    }

    func testARomfsIDThatCannotBeReadFails() async throws {
        let source = try await ipa(["romfs.id": Data("not an identity".utf8)])
        let entries = try await CartoucheZip.entries(of: source)
        do {
            _ = try await CartoucheRomfs.neededIdentity(ofIPA: source, entries: entries)
            XCTFail("an unreadable romfs.id was taken")
        } catch is CartoucheZipError {}
    }

    // MARK: The copy

    func testCopiesTheImageAndChecksTheCopy() async throws {
        let data = image()
        let into = folder.appendingPathComponent("romfs.img")
        let progress = Progress(totalUnitCount: 1)
        try await CartoucheRomfs.copy(MemorySource(data), to: into,
                                      needed: CartoucheRomfsIdentity(size: 105, index: 0xC7A1_1B1C_1EEC_2709), progress: progress)
        XCTAssertEqual(try Data(contentsOf: into), data)
        XCTAssertEqual(progress.totalUnitCount, 105)
        XCTAssertEqual(progress.completedUnitCount, 105)
    }

    func testACopyOfAnotherImageIsRemoved() async throws {
        let into = folder.appendingPathComponent("romfs.img")
        let other = image(extra: Data([1, 2, 3, 4, 5]))
        for (name, data) in [("another image", other), ("no image", Data(repeating: 7, count: 105))] {
            do {
                try await CartoucheRomfs.copy(MemorySource(data), to: into,
                                              needed: CartoucheRomfsIdentity(size: 105, index: 0xC7A1_1B1C_1EEC_2709))
                XCTFail("\(name) was kept")
            } catch is CartoucheZipError {}
            XCTAssertFalse(FileManager.default.fileExists(atPath: into.path), name)
        }
    }

    // MARK: The games folder

    func testEachIPATakesTheImageOfItsSizeBesideIt() {
        let needs = [CartoucheRomfsNeed(path: "Jeux/Mario.ipa", folder: "Jeux", size: 105),
                     CartoucheRomfsNeed(path: "Jeux/Zelda/Zelda.ipa", folder: "Jeux/Zelda", size: 110),
                     CartoucheRomfsNeed(path: "Jeux/Kirby.ipa", folder: "Jeux", size: 120)]
        let images = [CartoucheRomfsImage(path: "Jeux/romfs.img", folder: "Jeux", size: 105),
                      CartoucheRomfsImage(path: "Jeux/Zelda/RomFS.img", folder: "Jeux/Zelda", size: 110),
                      CartoucheRomfsImage(path: "Jeux/Other/romfs.img", folder: "Jeux/Other", size: 999)]
        let (taken, loose) = CartoucheRomfs.pair(needs, with: images)
        XCTAssertEqual(taken.mapValues(\.path), ["Jeux/Mario.ipa": "Jeux/romfs.img", "Jeux/Zelda/Zelda.ipa": "Jeux/Zelda/RomFS.img"])
        XCTAssertEqual(loose.map(\.path), ["Jeux/Other/romfs.img"])
    }

    func testAnImageBesideTheIPAComesBeforeOneElsewhere() {
        let need = CartoucheRomfsNeed(path: "Jeux/Zelda/Zelda.ipa", folder: "Jeux/Zelda", size: 105)
        let images = [CartoucheRomfsImage(path: "Jeux/romfs.img", folder: "Jeux", size: 105),
                      CartoucheRomfsImage(path: "Jeux/Zelda/Zelda.romfs.img", folder: "Jeux/Zelda", size: 105)]
        let (taken, loose) = CartoucheRomfs.pair([need], with: images)
        XCTAssertEqual(taken[need.path]?.path, "Jeux/Zelda/Zelda.romfs.img")
        XCTAssertEqual(loose.map(\.path), ["Jeux/romfs.img"])
        // Elsewhere in the games folder, when none is beside it.
        let elsewhere = CartoucheRomfs.pair([need], with: [images[0]])
        XCTAssertEqual(elsewhere.taken[need.path]?.path, "Jeux/romfs.img")
    }

    func testRomfsImgItselfComesBeforeAnotherName() {
        let need = CartoucheRomfsNeed(path: "Jeux/Mario.ipa", folder: "Jeux", size: 105)
        let images = [CartoucheRomfsImage(path: "Jeux/A.romfs.img", folder: "Jeux", size: 105),
                      CartoucheRomfsImage(path: "Jeux/romfs.img", folder: "Jeux", size: 105)]
        XCTAssertEqual(CartoucheRomfs.pair([need], with: images).taken[need.path]?.path, "Jeux/romfs.img")
    }

    func testOneImageServesTwoIPAsOfTheSameGame() {
        let needs = [CartoucheRomfsNeed(path: "Jeux/Mario 1.ipa", folder: "Jeux", size: 105),
                     CartoucheRomfsNeed(path: "Jeux/Mario 2.ipa", folder: "Jeux", size: 105)]
        let image = CartoucheRomfsImage(path: "Jeux/romfs.img", folder: "Jeux", size: 105)
        let (taken, loose) = CartoucheRomfs.pair(needs, with: [image])
        XCTAssertEqual(taken.count, 2)
        XCTAssertEqual(Set(taken.values), [image])
        XCTAssertTrue(loose.isEmpty)
    }

    // MARK: Helpers

    /// A root, one file and its bytes, as Cartouche Builder's tests write
    /// them (builder/tests/test_bundle.py), with EXTRA after the index.
    private func image(payload: Data = Data("example game data".utf8), extra: Data = Data()) -> Data {
        var index = le(UInt64(1)) + le(UInt64(1)) + le(UInt32(0)) + le(UInt16(0)) + Data([0, 0])
        index += le(UInt64(32)) + le(UInt64(payload.count)) + le(UInt32(0)) + le(UInt16(8)) + Data([1, 0])
        index += Data("data.bin".utf8) + extra
        let header = Data("DMROMFS1".utf8) + le(UInt64(32 + payload.count)) + le(UInt64(index.count)) + le(UInt64(2))
        return header + payload + index
    }

    /// An IPA of an app Game.app with FILES in it; a name that ends with "/"
    /// is a folder.
    private func ipa(_ files: [String: Data]) async throws -> MemorySource {
        let sink = MemorySink()
        let writer = CartoucheZipWriter(sink: sink)
        try await writer.addFolder("Payload/")
        try await writer.addFolder("Payload/Game.app/")
        try await writer.addData("Payload/Game.app/Info.plist", Data("<plist/>".utf8))
        for (name, data) in files.sorted(by: { $0.key < $1.key }) {
            if name.hasSuffix("/") {
                try await writer.addFolder("Payload/Game.app/" + name)
            } else {
                try await writer.addData("Payload/Game.app/" + name, data)
            }
        }
        try await writer.finish()
        return MemorySource(sink.data)
    }

    private func le<T: FixedWidthInteger>(_ value: T) -> Data {
        withUnsafeBytes(of: value.littleEndian) { Data($0) }
    }
}
