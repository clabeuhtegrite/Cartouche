//
//  CartoucheSaveSyncTests.swift
//  CartoucheCoreTests
//
//  How a game's saves on the iPhone are kept in step with their copies in
//  the player's saves folder (Sources/CartoucheSaveSync.swift): which way
//  they go, in the cases nxnative's save_sync.c decides (ss_decide), the
//  copies' names, what a copy holds against what the saves hold, and the
//  saves a copy that came replaces.
//

import Foundation
import XCTest
@testable import CartoucheCore

final class CartoucheSaveSyncTests: XCTestCase {
    private var folder: URL!
    /// 10 Nov 2026, 06:40 UTC.
    private let morning = Date(timeIntervalSince1970: 1_794_292_800)

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("CartoucheSaveSyncTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    // MARK: Which way

    /// The saves here, written MINUTES after the morning.
    private func here(_ look: String, _ content: String?, minutes: Double) -> CartoucheLocalSaves {
        CartoucheLocalSaves(look: look, written: morning + minutes * 60, content: content)
    }

    /// The newest copy there, of saves written MINUTES after the morning.
    private func copy(_ content: String?, minutes: Double) -> CartoucheSaveCopy {
        let date = morning + minutes * 60
        return CartoucheSaveCopy(name: CartoucheSaveSync.fileName(date), date: date, content: content)
    }

    private func base(_ copy: CartoucheSaveCopy, look: String, content: String?) -> CartoucheSaveBase {
        CartoucheSaveBase(place: "server|Saves", copy: copy.name, content: content, look: look)
    }

    private func step(_ here: CartoucheLocalSaves?, _ newest: CartoucheSaveCopy?, base: CartoucheSaveBase? = nil,
                      baseIsThere: Bool = true, fetching: Bool = true) -> CartoucheSaveStep {
        CartoucheSaveSync.step(here: here, newest: newest, base: base, baseIsThere: baseIsThere, fetching: fetching)
    }

    func testNoSaveAnywhereMovesNothing() {
        XCTAssertEqual(step(nil, nil), .none)
        XCTAssertEqual(step(nil, nil, fetching: false), .none)
    }

    func testSavesOnlyHereGoThere() {
        XCTAssertEqual(step(here("1|10|1", "a", minutes: 5), nil), .send)
        XCTAssertEqual(step(here("1|10|1", "a", minutes: 5), nil, fetching: false), .send)
        // A copy that holds no save is as none.
        XCTAssertEqual(step(here("1|10|1", "a", minutes: 5), copy("", minutes: 9)), .send)
    }

    func testTheNewestCopyComesWhereThereIsNoSave() {
        // As after Cartouche was installed again: no save, no base.
        XCTAssertEqual(step(nil, copy(nil, minutes: 9)), .fetch)
        // Not after a game: at the game's next start.
        XCTAssertEqual(step(nil, copy(nil, minutes: 9), fetching: false), .none)
        // Not again once it came, if it held no save.
        let empty = copy("", minutes: 9)
        XCTAssertEqual(step(nil, empty, base: base(empty, look: "", content: "")), .none)
    }

    func testTheSameSaveOnBothSidesMovesNothing() {
        let there = copy("a", minutes: 9)
        XCTAssertEqual(step(here("1|10|1", "a", minutes: 5), there), .same)
        XCTAssertEqual(step(here("1|10|1", "a", minutes: 5), there, base: base(there, look: "1|10|1", content: "a")), .none)
        // Without reading either: the base knows both.
        XCTAssertEqual(step(here("1|10|1", nil, minutes: 5), copy(nil, minutes: 9),
                            base: base(there, look: "1|10|1", content: "a")), .none)
        // Written again as they were, later.
        XCTAssertEqual(step(here("1|10|7", "a", minutes: 7), there, base: base(there, look: "1|10|1", content: "a")), .none)
    }

    func testWhatIsNotKnownIsReadFirst() {
        XCTAssertEqual(step(here("1|10|1", nil, minutes: 5), copy(nil, minutes: 9)), .compare)
        XCTAssertEqual(step(here("1|10|1", "a", minutes: 5), copy(nil, minutes: 9)), .compare)
        let old = copy("a", minutes: 1)
        XCTAssertEqual(step(here("1|10|2", nil, minutes: 5), copy(nil, minutes: 9), base: base(old, look: "1|10|1", content: "a")),
                       .compare)
    }

    func testOnlyTheFoldersChangedComes() {
        let old = copy("a", minutes: 1)
        let known = base(old, look: "1|10|1", content: "a")
        let mine = here("1|10|1", "a", minutes: 1)
        XCTAssertEqual(step(mine, copy("b", minutes: 9), base: known), .fetch)
        // Whatever its date says: another iPhone's clock may be late.
        XCTAssertEqual(step(here("1|10|1", "a", minutes: 30), copy("b", minutes: 9), base: known), .fetch)
        // The base's copy left the folder: the saves here go there first.
        XCTAssertEqual(step(mine, copy("b", minutes: 9), base: known, baseIsThere: false), .keepAndFetch)
        // After a game, it waits for the next start.
        XCTAssertEqual(step(mine, copy("b", minutes: 9), base: known, fetching: false), .none)
    }

    func testOnlyTheSavesHereChangedGo() {
        let old = copy("a", minutes: 1)
        let known = base(old, look: "1|10|1", content: "a")
        XCTAssertEqual(step(here("1|12|5", "b", minutes: 5), old, base: known), .send)
        XCTAssertEqual(step(here("1|12|5", "b", minutes: 5), old, base: known, fetching: false), .send)
        // Even under a copy of a later date, made by an iPhone whose clock is
        // ahead.
        let ahead = copy("a", minutes: 60)
        XCTAssertEqual(step(here("1|12|5", "b", minutes: 5), ahead, base: base(ahead, look: "1|10|1", content: "a")), .send)
    }

    func testWhenBothChangedTheSavesWrittenLastWin() {
        let known = base(copy("a", minutes: 1), look: "1|10|1", content: "a")
        let mine = here("1|12|5", "b", minutes: 5)
        // The folder's are newer: they come, and the saves here are kept.
        XCTAssertEqual(step(mine, copy("c", minutes: 9), base: known), .keepAndFetch)
        XCTAssertEqual(step(mine, copy("c", minutes: 9), base: known, fetching: false), .keep)
        // The saves here are newer: they go, and the folder keeps its own.
        XCTAssertEqual(step(here("1|12|20", "b", minutes: 20), copy("c", minutes: 9), base: known), .send)
        // The same second: this iPhone's, as nxnative keeps its own.
        XCTAssertEqual(step(here("1|12|9", "b", minutes: 9), copy("c", minutes: 9), base: known), .send)
    }

    func testAFirstSyncWithSavesOnBothSidesKeepsBoth() {
        // The player chose this folder with saves of their own here.
        XCTAssertEqual(step(here("1|12|5", "b", minutes: 5), copy("c", minutes: 9)), .keepAndFetch)
        XCTAssertEqual(step(here("1|12|5", "b", minutes: 5), copy("c", minutes: 9), fetching: false), .keep)
        XCTAssertEqual(step(here("1|12|20", "b", minutes: 20), copy("c", minutes: 9)), .send)
    }

    func testABaseAnOlderCartoucheLeft() {
        // It knows the copy by its name and the saves by their look only.
        let old = copy(nil, minutes: 1)
        let known = base(old, look: "1|10|1", content: nil)
        XCTAssertEqual(step(here("1|10|1", nil, minutes: 1), old, base: known), .none)
        XCTAssertEqual(step(here("1|12|5", nil, minutes: 5), old, base: known), .compare)
        XCTAssertEqual(step(here("1|12|5", "b", minutes: 5), copy("a", minutes: 1), base: known), .send)
        XCTAssertEqual(step(here("1|10|1", "a", minutes: 1), copy("c", minutes: 9), base: known), .fetch)
    }

    // MARK: The copies' names

    func testTheNamesSortByDate() {
        let date = Date(timeIntervalSince1970: 1_793_973_933)
        XCTAssertEqual(CartoucheSaveSync.fileName(date), "2026-11-06T14-05-33Z.zip")
        XCTAssertEqual(CartoucheSaveSync.date(inName: "2026-11-06T14-05-33Z.zip"), date)
        XCTAssertNil(CartoucheSaveSync.date(inName: "2026-11-06T14-05-33Z.zip.partial"))
        XCTAssertNil(CartoucheSaveSync.date(inName: "notes.zip"))
        let dates = [morning + 3_600, morning, morning + 59]
        XCTAssertEqual(dates.map(CartoucheSaveSync.fileName).sorted(), dates.sorted().map(CartoucheSaveSync.fileName))
    }

    func testACopyThatGoesIsTheNewest() {
        let now = morning + 3_600
        // Named by when its saves were written, to the second.
        XCTAssertEqual(CartoucheSaveSync.sendName(written: morning + 0.7, after: nil, now: now), CartoucheSaveSync.fileName(morning))
        // After the newest copy there, whatever this iPhone's clock says.
        XCTAssertEqual(CartoucheSaveSync.sendName(written: morning, after: morning + 600, now: now),
                       CartoucheSaveSync.fileName(morning + 601))
        // Never later than now, nor at a date no save has.
        XCTAssertEqual(CartoucheSaveSync.sendName(written: now + 86_400, after: nil, now: now), CartoucheSaveSync.fileName(now))
        XCTAssertEqual(CartoucheSaveSync.sendName(written: Date(timeIntervalSince1970: 0), after: nil, now: now),
                       CartoucheSaveSync.fileName(now))
    }

    func testACopyKeptGoesUnderTheNewest() {
        let now = morning + 3_600
        XCTAssertEqual(CartoucheSaveSync.keepName(written: morning, under: morning + 600, now: now),
                       CartoucheSaveSync.fileName(morning))
        XCTAssertEqual(CartoucheSaveSync.keepName(written: morning + 900, under: morning + 600, now: now),
                       CartoucheSaveSync.fileName(morning + 599))
        XCTAssertEqual(CartoucheSaveSync.keepName(written: morning + 600, under: morning + 600, now: now),
                       CartoucheSaveSync.fileName(morning + 599))
    }

    // MARK: What the saves hold

    /// A game's Documents, with saves as nxnative keeps them, its working
    /// copy, and what is no save.
    private func documents() throws -> URL {
        let fileManager = FileManager.default
        let documents = folder.appendingPathComponent("Documents", isDirectory: true)
        let profiles = documents.appendingPathComponent("save/Profils", isDirectory: true)
        try fileManager.createDirectory(at: profiles, withIntermediateDirectories: true)
        try Data((0 ..< 70_000).map { UInt8(truncatingIfNeeded: $0 &* 31) })
            .write(to: documents.appendingPathComponent("save/save0.bin"))
        try Data("Joueur 1".utf8).write(to: profiles.appendingPathComponent("joueur é.txt"))
        try Data().write(to: profiles.appendingPathComponent("vide"))
        try fileManager.createSymbolicLink(atPath: documents.appendingPathComponent("save/dernier").path,
                                           withDestinationPath: "save0.bin")
        let device = documents.appendingPathComponent("save_device", isDirectory: true)
        try fileManager.createDirectory(at: device, withIntermediateDirectories: true)
        try Data("appareil".utf8).write(to: device.appendingPathComponent("device.dat"))
        let work = documents.appendingPathComponent("save.work", isDirectory: true)
        try fileManager.createDirectory(at: work, withIntermediateDirectories: true)
        try Data("en cours".utf8).write(to: work.appendingPathComponent("save0.bin"))
        try Data("journal".utf8).write(to: documents.appendingPathComponent("nxnative.log"))
        return documents
    }

    func testACopyHoldsWhatTheSavesHold() async throws {
        let documents = try documents()
        let content = try CartoucheSaveSync.content(ofSavesIn: documents)
        XCTAssertEqual(content.count, 32)
        let sink = MemorySink()
        try await CartoucheSaveSync.writeZip(ofSavesIn: documents, to: sink)
        let entries = try await CartoucheZip.entries(of: MemorySource(sink.data))
        // Read from the zip's central directory alone, as a copy in the
        // saves folder is, without downloading it.
        XCTAssertEqual(CartoucheSaveSync.content(of: entries), content)
        XCTAssertTrue(CartoucheSaveSync.holdsSavesOnly(entries))
        let names = Set(entries.map(\.name))
        XCTAssertTrue(names.isSuperset(of: ["save/", "save/save0.bin", "save/dernier", "save/Profils/joueur é.txt",
                                            "save/Profils/vide", "save_device/device.dat"]))
        XCTAssertFalse(names.contains { $0.hasPrefix("save.work") || $0 == "nxnative.log" })
    }

    func testWhatTheSavesHoldChangesWithThemNotWithTheirDates() throws {
        let documents = try documents()
        let content = try CartoucheSaveSync.content(ofSavesIn: documents)
        let look = try XCTUnwrap(CartoucheSaveSync.saves(in: documents)).look
        // Written again as they were.
        let save = documents.appendingPathComponent("save/save0.bin")
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(3_600)], ofItemAtPath: save.path)
        XCTAssertEqual(try CartoucheSaveSync.content(ofSavesIn: documents), content)
        XCTAssertNotEqual(try XCTUnwrap(CartoucheSaveSync.saves(in: documents)).look, look)
        // nxnative's working copy and the rest of Documents are no saves.
        try Data("autre".utf8).write(to: documents.appendingPathComponent("save.work/save0.bin"))
        try Data("autre".utf8).write(to: documents.appendingPathComponent("nxnative.log"))
        XCTAssertEqual(try CartoucheSaveSync.content(ofSavesIn: documents), content)
        // A byte of a save changed.
        var data = try Data(contentsOf: save)
        data[100] ^= 1
        try data.write(to: save)
        XCTAssertNotEqual(try CartoucheSaveSync.content(ofSavesIn: documents), content)
    }

    func testTheSavesLookAndWhenTheyWereWritten() throws {
        let empty = folder.appendingPathComponent("Empty", isDirectory: true)
        try FileManager.default.createDirectory(at: empty.appendingPathComponent("save"), withIntermediateDirectories: true)
        XCTAssertNil(CartoucheSaveSync.saves(in: empty))
        XCTAssertNil(CartoucheSaveSync.saves(in: folder.appendingPathComponent("Nowhere")))
        XCTAssertEqual(try CartoucheSaveSync.content(ofSavesIn: empty), "")

        let documents = try documents()
        try FileManager.default.removeItem(at: documents.appendingPathComponent("save/dernier"))
        let files = ["save/save0.bin", "save/Profils/joueur é.txt", "save/Profils/vide", "save_device/device.dat"]
        for (index, file) in files.enumerated() {
            try FileManager.default.setAttributes([.modificationDate: morning + Double(index) * 60],
                                                  ofItemAtPath: documents.appendingPathComponent(file).path)
        }
        let saves = try XCTUnwrap(CartoucheSaveSync.saves(in: documents))
        XCTAssertEqual(saves.written, morning + 180)
        XCTAssertEqual(saves.look, "4|70016|1794292980000")
        XCTAssertNil(saves.content)
    }

    func testACopyOfMoreThanSavesIsNone() async throws {
        let sink = MemorySink()
        let writer = CartoucheZipWriter(sink: sink)
        try await writer.addFolder("save/")
        try await writer.addData("save/save0.bin", Data("partie".utf8))
        try await writer.addData("Payload/Jeu.app/Info.plist", Data("<plist/>".utf8))
        try await writer.finish()
        let entries = try await CartoucheZip.entries(of: MemorySource(sink.data))
        XCTAssertFalse(CartoucheSaveSync.holdsSavesOnly(entries))
    }

    // MARK: The saves a copy replaces

    func testACopyThatComesReplacesTheSaves() async throws {
        let fileManager = FileManager.default
        let documents = try documents()
        // Another iPhone's saves, with no save_device.
        let other = folder.appendingPathComponent("Other", isDirectory: true)
        try fileManager.createDirectory(at: other.appendingPathComponent("save"), withIntermediateDirectories: true)
        try Data("autre partie".utf8).write(to: other.appendingPathComponent("save/save0.bin"))
        let sink = MemorySink()
        try await CartoucheSaveSync.writeZip(ofSavesIn: other, to: sink)
        let source = MemorySource(sink.data)
        let entries = try await CartoucheZip.entries(of: source)
        let unpacked = folder.appendingPathComponent("Unpacked", isDirectory: true)
        try await CartoucheZip.extract(source, entries: entries, into: unpacked)
        let aside = folder.appendingPathComponent("Aside", isDirectory: true)

        try CartoucheSaveSync.replaceSaves(in: documents, with: unpacked, aside: aside)
        XCTAssertEqual(try String(contentsOf: documents.appendingPathComponent("save/save0.bin"), encoding: .utf8),
                       "autre partie")
        // Both sides hold the same: the folder the copy has not goes, and
        // nxnative makes its working copy again from the saves.
        XCTAssertFalse(fileManager.fileExists(atPath: documents.appendingPathComponent("save_device").path))
        XCTAssertFalse(fileManager.fileExists(atPath: documents.appendingPathComponent("save.work").path))
        XCTAssertEqual(try CartoucheSaveSync.content(ofSavesIn: documents), CartoucheSaveSync.content(of: entries))
        // The rest of Documents stays, and what was replaced is aside.
        XCTAssertTrue(fileManager.fileExists(atPath: documents.appendingPathComponent("nxnative.log").path))
        XCTAssertTrue(fileManager.fileExists(atPath: aside.appendingPathComponent("save/Profils/joueur é.txt").path))
        XCTAssertTrue(fileManager.fileExists(atPath: aside.appendingPathComponent("save_device/device.dat").path))
    }
}
