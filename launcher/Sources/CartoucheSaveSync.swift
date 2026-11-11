//
//  CartoucheSaveSync.swift
//  Cartouche
//
//  How a game's saves on this iPhone are kept in step with their copies in
//  the player's saves folder, the way nxnative keeps a game's save in step
//  with a cloud folder (dm/host/save_sync.c, ss_decide):
//
//  - The saves are the game's Documents/save and Documents/save_device, the
//    folders nxnative commits a game's saves to. A copy is a zip of them,
//    "<game> [<title ID>]/<date>.zip" in the saves folder, named by the time
//    its saves were last written, in UTC: the copies sort by when the game
//    saved, whichever iPhone made them, and the newest is the save played
//    last. A copy an older Cartouche made is named by the time it was made,
//    just after the game.
//  - Two saves are the same when their files are: the same paths, sizes and
//    CRC-32s, which a zip's central directory holds, so that a copy is
//    compared without being downloaded.
//  - For each game, Cartouche keeps the base: the copy last known to be the
//    same as the saves here, what it holds, and how the saves here looked
//    then, their files' count, size and newest date, which change whenever
//    the game saves.
//  - Which way, as ss_decide: nothing in the folder, the saves here go
//    there; nothing here, the newest copy comes; the same save on both
//    sides, nothing moves; only the folder's changed since the base, its
//    newest copy comes; only the saves here changed, they go; both changed,
//    or this iPhone never synced the game with this folder, the saves
//    written last win, and the others are kept as a copy of their own date.
//  - The newest copy comes when the game is installed and before it starts;
//    the saves here go after the game. A copy that goes as the newest is
//    named after the newest one there, so that it is the newest whatever
//    the iPhones' clocks say.
//
//  Platform-independent: tested on its own by launcher/Package.swift.
//

import CryptoKit
import Foundation

/// A game's saves on this iPhone.
struct CartoucheLocalSaves: Hashable {
    /// How they look: their files' count, size and newest date, which
    /// change whenever the game saves.
    let look: String
    /// When they were last written: the date of their newest file.
    let written: Date
    /// What they hold (CartoucheSaveSync.content), once read.
    var content: String?
}

/// The newest copy of a game's saves in the saves folder.
struct CartoucheSaveCopy: Hashable {
    let name: String
    /// The date its name gives.
    let date: Date
    /// What it holds, from its zip's central directory, once read.
    var content: String?
}

/// What this iPhone last knew to be the same here and in the saves folder,
/// for one game.
struct CartoucheSaveBase: Codable, Hashable {
    /// The saves folder: its server's ID and its path, "<ID>|<path>". A base
    /// holds for that folder only.
    var place: String
    /// The copy, by name, in the game's folder there.
    var copy: String
    /// What it holds (CartoucheSaveSync.content); nil for a base an older
    /// Cartouche left, which knew the copy by its name only.
    var content: String?
    /// How the saves here looked then (CartoucheLocalSaves.look).
    var look: String
}

/// What to do with a game's saves.
enum CartoucheSaveStep: String, Codable {
    /// Nothing moves: neither side changed since the base, or only the
    /// folder's, whose newest copy comes at the game's next start.
    case none
    /// Both sides hold the same save, which becomes the base.
    case same
    /// What both sides hold must be read first, to compare them.
    case compare
    /// The saves here go to the folder, as its newest copy.
    case send
    /// The saves here go to the folder as a copy of their own date, under
    /// the newest one there, which is newer and comes at the game's next
    /// start.
    case keep
    /// The newest copy comes here, in place of the saves here, which the
    /// folder has already.
    case fetch
    /// The saves here go to the folder as a copy of their own date, then the
    /// newest copy, which is newer, comes here in their place.
    case keepAndFetch
}

enum CartoucheSaveSync {
    /// The folders of a game's Documents that nxnative keeps its saves in.
    static let folders = ["save", "save_device"]
    /// nxnative's working copy of the saves, which the game makes again from
    /// them when it starts: it goes when other saves come in.
    static let workFolder = "save.work"
    /// The copies kept for each game.
    static let kept = 10

    // MARK: Which way

    /// Which way a game's saves go between HERE, the saves on this iPhone,
    /// nil when the game has none, and NEWEST, the newest copy in the game's
    /// folder, nil when there is none, from BASE, nil when this iPhone never
    /// synced the game with that folder. BASEISTHERE: whether the base's
    /// copy is still in the folder. FETCHING: whether the newest copy may
    /// come now, as it does when the game is installed and before it
    /// starts, rather than after a game. .compare asks for what both sides
    /// hold first: called again with it, the step is never .compare.
    static func step(here: CartoucheLocalSaves?, newest: CartoucheSaveCopy?, base: CartoucheSaveBase?,
                     baseIsThere: Bool, fetching: Bool) -> CartoucheSaveStep {
        guard let here else {
            // Nothing here: the newest copy comes, unless it came already and
            // held no save.
            guard let newest, fetching else { return .none }
            if let base, base.copy == newest.name, base.look.isEmpty { return .none }
            return .fetch
        }
        // Nothing in the folder, or a copy that holds no save.
        guard let newest, newest.content != "" else { return .send }
        let hereIsBase = base.map { $0.look == here.look || ($0.content != nil && $0.content == here.content) } ?? false
        let copyIsBase = base.map { $0.copy == newest.name || ($0.content != nil && $0.content == newest.content) } ?? false
        if hereIsBase && copyIsBase { return .none }
        guard let mine = here.content, let theirs = newest.content else { return .compare }
        if mine == theirs { return .same }
        if hereIsBase {
            // Only the folder's changed: its newest copy comes, at the start.
            // The saves here go first if the base's copy is no longer there.
            guard fetching else { return .none }
            return baseIsThere ? .fetch : .keepAndFetch
        }
        // Only the saves here changed.
        if copyIsBase { return .send }
        // Both changed since the base, or this iPhone never synced the game
        // with this folder: the saves written last win, the others are kept.
        // The same second: this iPhone's, as nxnative keeps its own.
        if newest.date > here.written { return fetching ? .keepAndFetch : .keep }
        return .send
    }

    // MARK: The copies' names

    /// Made for each use: a formatter is not for several threads at once.
    private static func nameFormat() -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd'T'HH-mm-ss'Z'"
        return formatter
    }

    /// A copy's name, its date in UTC: "2026-11-06T14-05-33Z.zip". The
    /// names sort by date.
    static func fileName(_ date: Date) -> String {
        nameFormat().string(from: date) + ".zip"
    }

    static func date(inName name: String) -> Date? {
        guard name.lowercased().hasSuffix(".zip") else { return nil }
        return nameFormat().date(from: String(name.dropLast(4)))
    }

    /// No save is older: a date before it is no date.
    private static let earliest = Date(timeIntervalSince1970: 946_684_800)

    /// The name of a copy that goes as the newest, of saves WRITTEN then:
    /// their date, but never later than NOW, and a second after AFTER, the
    /// newest copy there, when that is later.
    static func sendName(written: Date, after newest: Date?, now: Date = Date()) -> String {
        var seconds = (written < earliest ? now : min(written, now)).timeIntervalSince1970.rounded(.down)
        if let newest {
            seconds = max(seconds, newest.timeIntervalSince1970.rounded(.down) + 1)
        }
        return fileName(Date(timeIntervalSince1970: seconds))
    }

    /// The name of a copy that keeps saves WRITTEN then, under NEWEST, the
    /// newer copy there: their own date, but never later than NOW, and a
    /// second before NEWEST at the latest.
    static func keepName(written: Date, under newest: Date?, now: Date = Date()) -> String {
        var seconds = (written < earliest ? now : min(written, now)).timeIntervalSince1970.rounded(.down)
        if let newest {
            seconds = min(seconds, newest.timeIntervalSince1970.rounded(.down) - 1)
        }
        return fileName(Date(timeIntervalSince1970: seconds))
    }

    // MARK: The saves here

    /// The saves in DOCUMENTS, as they look now; nil when the game has none,
    /// no file in either folder.
    static func saves(in documents: URL) -> CartoucheLocalSaves? {
        var count = 0
        var size: UInt64 = 0
        var newest: Int64 = 0
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey]
        for folder in folders {
            let root = documents.appendingPathComponent(folder, isDirectory: true)
            guard FileManager.default.fileExists(atPath: root.path),
                  let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys) else { continue }
            while let url = walker.nextObject() as? URL {
                let values = try? url.resourceValues(forKeys: Set(keys))
                guard values?.isRegularFile == true else { continue }
                count += 1
                size += UInt64(values?.fileSize ?? 0)
                let date = Int64(((values?.contentModificationDate ?? .distantPast).timeIntervalSince1970 * 1000).rounded())
                newest = max(newest, date)
            }
        }
        guard count > 0 else { return nil }
        // The form older versions kept their saves' fingerprint in.
        return CartoucheLocalSaves(look: "\(count)|\(size)|\(newest)",
                                   written: Date(timeIntervalSince1970: TimeInterval(newest) / 1000))
    }

    /// What the saves in DOCUMENTS hold: each file's path, size and CRC-32,
    /// and each link's target, as a zip of them lists them (writeZip, and
    /// content(of:) for a copy). "" when there is no file.
    static func content(ofSavesIn documents: URL) throws -> String {
        var lines: [String] = []
        for folder in folders {
            let root = documents.appendingPathComponent(folder, isDirectory: true)
            var isFolder: ObjCBool = false
            guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isFolder), isFolder.boolValue,
                  let walker = FileManager.default.enumerator(atPath: root.path) else { continue }
            while let relative = walker.nextObject() as? String {
                let url = root.appendingPathComponent(relative)
                let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                let name = folder + "/" + relative
                if values.isSymbolicLink == true {
                    let target = Data(try FileManager.default.destinationOfSymbolicLink(atPath: url.path).utf8)
                    lines.append(line(name, size: UInt64(target.count), crc: CartoucheCRC32.of(target)))
                } else if values.isDirectory != true {
                    let (size, crc) = try checksum(of: url)
                    lines.append(line(name, size: size, crc: crc))
                }
            }
        }
        return digest(lines)
    }

    /// What a copy holds, from its zip's ENTRIES: what content(ofSavesIn:)
    /// gives for the saves it was made of.
    static func content(of entries: [CartoucheZipEntry]) -> String {
        digest(entries.filter { !$0.isDirectory }.map { line($0.name, size: $0.size, crc: $0.crc) })
    }

    private static func line(_ name: String, size: UInt64, crc: UInt32) -> String {
        name + "\t" + String(size) + "\t" + String(format: "%08x", crc)
    }

    /// The first 16 bytes of the SHA-256 of LINES, in their bytes' order, in
    /// hex, as nxnative writes a save's hash; "" for none.
    private static func digest(_ lines: [String]) -> String {
        guard !lines.isEmpty else { return "" }
        let sorted = lines.sorted { $0.utf8.lexicographicallyPrecedes($1.utf8) }
        let hash = SHA256.hash(data: Data(sorted.joined(separator: "\n").utf8))
        return hash.prefix(16).map { String(format: "%02x", $0) }.joined()
    }

    private static func checksum(of url: URL) throws -> (size: UInt64, crc: UInt32) {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var check = CartoucheCRC32()
        var size: UInt64 = 0
        while let chunk = try handle.cartoucheRead(upToCount: CartoucheSequentialReader.chunk) {
            check.update(chunk)
            size += UInt64(chunk.count)
        }
        return (size, check.value)
    }

    // MARK: Copies

    /// The saves' folders, files and links in DOCUMENTS, as a zip with paths
    /// from Documents: save/..., save_device/...
    static func writeZip(ofSavesIn documents: URL, to sink: CartoucheByteSink) async throws {
        let writer = CartoucheZipWriter(sink: sink)
        for folder in folders {
            let root = documents.appendingPathComponent(folder, isDirectory: true)
            var isFolder: ObjCBool = false
            guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isFolder), isFolder.boolValue,
                  let walker = FileManager.default.enumerator(atPath: root.path) else { continue }
            try await writer.addFolder(folder + "/")
            var relatives: [String] = []
            while let relative = walker.nextObject() as? String {
                relatives.append(relative)
            }
            for relative in relatives.sorted() {
                let url = root.appendingPathComponent(relative)
                let name = folder + "/" + relative
                let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey, .contentModificationDateKey])
                let date = values.contentModificationDate ?? Date()
                if values.isSymbolicLink == true {
                    let target = try FileManager.default.destinationOfSymbolicLink(atPath: url.path)
                    try await writer.addSymlink(name, target: target, date: date)
                } else if values.isDirectory == true {
                    try await writer.addFolder(name + "/", date: date)
                } else {
                    try await writer.addFile(name, from: url, date: date)
                }
            }
        }
        try await writer.finish()
    }

    /// Whether ENTRIES are those of a copy of saves: each in save/ or
    /// save_device/.
    static func holdsSavesOnly(_ entries: [CartoucheZipEntry]) -> Bool {
        entries.allSatisfy { entry in
            folders.contains { entry.name == $0 + "/" || entry.name.hasPrefix($0 + "/") }
        }
    }

    /// Puts the saves unpacked in UNPACKED in place of those in DOCUMENTS,
    /// and removes nxnative's working copy, for the game to make it again
    /// from them. A folder the copy does not have goes, so that both sides
    /// hold the same. The folders replaced go to ASIDE, a folder of their
    /// own, first, and come back if a step fails.
    static func replaceSaves(in documents: URL, with unpacked: URL, aside: URL) throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: documents, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: aside, withIntermediateDirectories: true)
        var moved: [String] = []
        var placed: [String] = []
        do {
            for folder in folders + [workFolder] {
                let here = documents.appendingPathComponent(folder, isDirectory: true)
                if fileManager.fileExists(atPath: here.path) {
                    try fileManager.moveItem(at: here, to: aside.appendingPathComponent(folder, isDirectory: true))
                    moved.append(folder)
                }
            }
            for folder in folders {
                let incoming = unpacked.appendingPathComponent(folder, isDirectory: true)
                if fileManager.fileExists(atPath: incoming.path) {
                    try fileManager.moveItem(at: incoming, to: documents.appendingPathComponent(folder, isDirectory: true))
                    placed.append(folder)
                }
            }
        } catch {
            // The saves as they were.
            for folder in placed {
                try? fileManager.removeItem(at: documents.appendingPathComponent(folder, isDirectory: true))
            }
            for folder in moved {
                try? fileManager.moveItem(at: aside.appendingPathComponent(folder, isDirectory: true),
                                          to: documents.appendingPathComponent(folder, isDirectory: true))
            }
            throw error
        }
    }
}
