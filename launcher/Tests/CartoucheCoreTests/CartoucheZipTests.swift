//
//  CartoucheZipTests.swift
//  CartoucheCoreTests
//
//  The zip reader and writer (Sources/CartoucheZip.swift) against each
//  other, and against Python's zipfile, which reads and writes archives as
//  nxnative's pack_ipa.py does: deflated and stored entries, Unix modes,
//  links, Zip64.
//

import Foundation
import XCTest
@testable import CartoucheCore

/// An archive in memory, which counts how it is read.
final class MemorySource: CartoucheByteSource {
    let data: Data
    private(set) var reads: [(offset: UInt64, count: Int)] = []

    init(_ data: Data) {
        self.data = data
    }

    var size: UInt64 { UInt64(data.count) }

    func read(at offset: UInt64, count: Int) async throws -> Data {
        reads.append((offset, count))
        let start = Int(min(offset, size))
        let end = Int(min(offset + UInt64(count), size))
        return data.subdata(in: start ..< end)
    }
}

final class MemorySink: CartoucheByteSink {
    private(set) var data = Data()

    func write(_ chunk: Data) async throws {
        data.append(chunk)
    }
}

final class CartoucheZipTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("CartoucheZipTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    /// Bytes that do not deflate, as most of a game's data.
    private func noise(_ count: Int, seed: UInt64) -> Data {
        var state = seed
        var data = Data(count: count)
        data.withUnsafeMutableBytes { raw in
            for index in 0 ..< count {
                state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
                raw[index] = UInt8(truncatingIfNeeded: state >> 33)
            }
        }
        return data
    }

    /// An archive like an IPA's, written by CartoucheZipWriter.
    private func writeArchive(zip64: Bool) async throws -> (Data, Data) {
        let big = noise(CartoucheZipWriter.deflateLimit + 3_000_001, seed: 7)
        let bigFile = folder.appendingPathComponent("big.bin")
        try big.write(to: bigFile)
        let sink = MemorySink()
        let writer = CartoucheZipWriter(sink: sink)
        writer.alwaysZip64 = zip64
        try await writer.addFolder("Payload/")
        try await writer.addFolder("Payload/Game.app/")
        try await writer.addData("Payload/Game.app/Info.plist", Data(String(repeating: "<key>CFBundleIdentifier</key>\n", count: 50).utf8))
        try await writer.addData("Payload/Game.app/Game", noise(70_000, seed: 3), mode: 0o755)
        try await writer.addData("Payload/Game.app/Données é.txt", Data("Sauvegarde".utf8))
        try await writer.addData("Payload/Game.app/empty", Data())
        var added: UInt64 = 0
        try await writer.addFile("Payload/Game.app/romfs/big.bin", from: bigFile) { added += $0 }
        XCTAssertEqual(added, UInt64(big.count))
        try await writer.addSymlink("Payload/Game.app/link", target: "romfs/big.bin")
        try await writer.finish()
        XCTAssertEqual(writer.written, UInt64(sink.data.count))
        return (sink.data, big)
    }

    private func checkExtracted(_ root: URL, big: Data) throws {
        let app = root.appendingPathComponent("Payload/Game.app")
        XCTAssertEqual(try Data(contentsOf: app.appendingPathComponent("Info.plist")),
                       Data(String(repeating: "<key>CFBundleIdentifier</key>\n", count: 50).utf8))
        XCTAssertEqual(try Data(contentsOf: app.appendingPathComponent("Game")), noise(70_000, seed: 3))
        XCTAssertEqual(try String(contentsOf: app.appendingPathComponent("Données é.txt"), encoding: .utf8), "Sauvegarde")
        XCTAssertEqual(try Data(contentsOf: app.appendingPathComponent("empty")), Data())
        XCTAssertEqual(try Data(contentsOf: app.appendingPathComponent("romfs/big.bin")), big)
        let mode = try FileManager.default.attributesOfItem(atPath: app.appendingPathComponent("Game").path)[.posixPermissions] as? NSNumber
        XCTAssertEqual((mode?.uint16Value ?? 0) & 0o777, 0o755)
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: app.appendingPathComponent("link").path), "romfs/big.bin")
    }

    func testRoundTrip() async throws {
        let (archive, big) = try await writeArchive(zip64: false)
        let source = MemorySource(archive)
        let entries = try await CartoucheZip.entries(of: source)
        XCTAssertEqual(entries.count, 8)
        XCTAssertEqual(entries.first { $0.name.hasSuffix("Info.plist") }?.method, 8)
        XCTAssertEqual(entries.first { $0.name.hasSuffix("big.bin") }?.method, 0)
        XCTAssertTrue(entries.first { $0.name == "Payload/Game.app/" }?.isDirectory ?? false)
        XCTAssertTrue(entries.first { $0.name.hasSuffix("link") }?.isSymlink ?? false)

        let info = try XCTUnwrap(entries.first { $0.name.hasSuffix("Info.plist") })
        let plist = try await CartoucheZip.data(of: info, in: source)
        XCTAssertEqual(plist, Data(String(repeating: "<key>CFBundleIdentifier</key>\n", count: 50).utf8))

        let into = folder.appendingPathComponent("out")
        let progress = Progress()
        try await CartoucheZip.extract(source, entries: entries, into: into, progress: progress)
        try checkExtracted(into, big: big)
        XCTAssertEqual(progress.completedUnitCount, progress.totalUnitCount)
    }

    func testZip64RoundTrip() async throws {
        let (archive, big) = try await writeArchive(zip64: true)
        let source = MemorySource(archive)
        let entries = try await CartoucheZip.entries(of: source)
        XCTAssertEqual(entries.count, 8)
        let into = folder.appendingPathComponent("out")
        try await CartoucheZip.extract(source, entries: entries, into: into)
        try checkExtracted(into, big: big)
    }

    /// The archive is read from start to end once, in long reads, besides
    /// the central directory at its end.
    func testReadsInOrder() async throws {
        let (archive, _) = try await writeArchive(zip64: false)
        let source = MemorySource(archive)
        let entries = try await CartoucheZip.entries(of: source)
        let before = source.reads.count
        try await CartoucheZip.extract(source, entries: entries, into: folder.appendingPathComponent("out"))
        let reads = source.reads.dropFirst(before)
        XCTAssertLessThanOrEqual(reads.count, archive.count / CartoucheSequentialReader.chunk + 2)
        XCTAssertEqual(reads.map(\.offset), reads.map(\.offset).sorted())
    }

    func testDamagedEntryFails() async throws {
        let (archive, _) = try await writeArchive(zip64: false)
        var damaged = archive
        let source = MemorySource(archive)
        let entries = try await CartoucheZip.entries(of: source)
        let big = try XCTUnwrap(entries.first { $0.name.hasSuffix("big.bin") })
        let at = Int(big.localHeaderOffset) + 30 + big.name.utf8.count + 1_000
        damaged[at] ^= 0xFF
        do {
            try await CartoucheZip.extract(MemorySource(damaged), entries: entries, into: folder.appendingPathComponent("out"))
            XCTFail("a damaged archive was taken")
        } catch let error as CartoucheZipError {
            XCTAssertTrue(error.message.contains("big.bin"), error.message)
        }
    }

    func testPathsThatLeaveTheFolderFail() async throws {
        XCTAssertNil(CartoucheZip.safePath("../evil"))
        XCTAssertNil(CartoucheZip.safePath("Payload/../../evil"))
        XCTAssertNil(CartoucheZip.safePath("/etc/passwd"))
        XCTAssertNil(CartoucheZip.safePath("a/./b"))
        XCTAssertEqual(CartoucheZip.safePath("Payload//Game.app/"), "Payload/Game.app")

        let sink = MemorySink()
        let writer = CartoucheZipWriter(sink: sink)
        try await writer.addData("../evil", Data("x".utf8))
        try await writer.finish()
        let source = MemorySource(sink.data)
        let entries = try await CartoucheZip.entries(of: source)
        do {
            try await CartoucheZip.extract(source, entries: entries, into: folder.appendingPathComponent("out"))
            XCTFail("an entry outside the folder was taken")
        } catch is CartoucheZipError {}
    }

    func testLinksThatLeaveTheFolderFail() async throws {
        let sink = MemorySink()
        let writer = CartoucheZipWriter(sink: sink)
        try await writer.addSymlink("Payload/out", target: "../../outside")
        try await writer.finish()
        let source = MemorySource(sink.data)
        let entries = try await CartoucheZip.entries(of: source)
        do {
            try await CartoucheZip.extract(source, entries: entries, into: folder.appendingPathComponent("out"))
            XCTFail("a link outside the folder was made")
        } catch is CartoucheZipError {}
    }

    func testNotAnArchive() async throws {
        do {
            _ = try await CartoucheZip.entries(of: MemorySource(noise(5_000, seed: 1)))
            XCTFail("noise was read as an archive")
        } catch is CartoucheZipError {}
    }

    func testCRC32() {
        XCTAssertEqual(CartoucheCRC32.of(Data("123456789".utf8)), 0xCBF4_3926)
        XCTAssertEqual(CartoucheCRC32.of(Data()), 0)
    }

    // MARK: Python's zipfile

    private func python(_ script: String, _ arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["python3", "-I", "-c", script] + arguments
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        do {
            try process.run()
        } catch {
            throw XCTSkip("no python3: \(error)")
        }
        let said = String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        process.waitUntilExit()
        if process.terminationStatus != 0 {
            XCTFail("python3 failed: \(said)")
        }
        return said
    }

    func testPythonReadsWhatCartoucheWrites() async throws {
        for zip64 in [false, true] {
            let (archive, big) = try await writeArchive(zip64: zip64)
            let path = folder.appendingPathComponent("cartouche-\(zip64).zip")
            try archive.write(to: path)
            let said = try python("""
                import sys, zipfile
                with zipfile.ZipFile(sys.argv[1]) as z:
                    assert z.testzip() is None
                    big = z.read("Payload/Game.app/romfs/big.bin")
                    assert len(big) == int(sys.argv[2]), len(big)
                    assert z.read("Payload/Game.app/Données é.txt") == "Sauvegarde".encode()
                    game = z.getinfo("Payload/Game.app/Game")
                    assert (game.external_attr >> 16) & 0o777 == 0o755, oct(game.external_attr >> 16)
                    link = z.getinfo("Payload/Game.app/link")
                    assert (link.external_attr >> 16) & 0o170000 == 0o120000
                    print(len(z.namelist()))
                """, [path.path, String(big.count)])
            XCTAssertEqual(said.trimmingCharacters(in: .whitespacesAndNewlines), "8")
        }
    }

    func testCartoucheReadsWhatPythonWrites() async throws {
        let path = folder.appendingPathComponent("python.zip")
        _ = try python("""
            import sys, zipfile
            with zipfile.ZipFile(sys.argv[1], "w") as z:
                folder = zipfile.ZipInfo("Payload/Game.app/")
                folder.external_attr = (0o040755 << 16) | 0x10
                folder.create_system = 3
                z.writestr(folder, b"")
                game = zipfile.ZipInfo("Payload/Game.app/Game")
                game.external_attr = 0o100755 << 16
                game.create_system = 3
                game.compress_type = zipfile.ZIP_DEFLATED
                z.writestr(game, b"nxnative" * 10000)
                link = zipfile.ZipInfo("Payload/Game.app/link")
                link.external_attr = 0o120777 << 16
                link.create_system = 3
                z.writestr(link, b"Game")
                with z.open("Payload/Game.app/romfs.bin", "w", force_zip64=True) as f:
                    f.write(bytes(range(256)) * 4096)
            """, [path.path])
        let source = try CartoucheFileSource(path)
        let entries = try await CartoucheZip.entries(of: source)
        XCTAssertEqual(entries.count, 4)
        let into = folder.appendingPathComponent("out")
        try await CartoucheZip.extract(source, entries: entries, into: into)
        let app = into.appendingPathComponent("Payload/Game.app")
        XCTAssertEqual(try Data(contentsOf: app.appendingPathComponent("Game")), Data(String(repeating: "nxnative", count: 10000).utf8))
        XCTAssertEqual(try Data(contentsOf: app.appendingPathComponent("romfs.bin")).count, 256 * 4096)
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: app.appendingPathComponent("link").path), "Game")
        let mode = try FileManager.default.attributesOfItem(atPath: app.appendingPathComponent("Game").path)[.posixPermissions] as? NSNumber
        XCTAssertEqual((mode?.uint16Value ?? 0) & 0o777, 0o755)
    }

    /// A file of the iPhone written through CartoucheFileSink, read back
    /// through CartoucheFileSource.
    func testFileSinkAndSource() async throws {
        let path = folder.appendingPathComponent("file.zip")
        let sink = try CartoucheFileSink(path)
        let writer = CartoucheZipWriter(sink: sink)
        try await writer.addData("a.txt", Data("a".utf8))
        try await writer.finish()
        try sink.close()
        let source = try CartoucheFileSource(path)
        let entries = try await CartoucheZip.entries(of: source)
        let entry = try XCTUnwrap(entries.first)
        let data = try await CartoucheZip.data(of: entry, in: source)
        XCTAssertEqual(data, Data("a".utf8))
    }
}
