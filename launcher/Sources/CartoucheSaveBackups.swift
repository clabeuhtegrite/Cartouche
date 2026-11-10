//
//  CartoucheSaveBackups.swift
//  Cartouche
//
//  Copies of the games' saves in the player's saves folder. A game is
//  Cartouche itself while it plays, so Cartouche copies when it opens again
//  after a game, and whenever it comes back to the front: each game whose
//  saves changed since their last copy gets a new one, and Play waits for
//  the copies under way. A copy is a zip of the game's Documents/save and
//  Documents/save_device, the folders nxnative keeps a game's saves in,
//  named by its date, in a folder of the game's own:
//  "<game> [<title ID>]/<date>.zip". The ten newest stay.
//
//  A copy can be put back from the game's sheet. The saves it replaces are
//  copied first, and nxnative's working copy (save.work) goes, for the
//  game to make it again from the saves put back.
//

import Combine
import Foundation
import UIKit

/// A game's saves on this iPhone, and what to call their copies.
struct CartoucheSaveTarget: Hashable, Identifiable {
    /// What tells the game's saves apart: its bundle ID and data folder.
    let key: String
    let name: String
    let titleId: String?
    /// The game's Documents folder.
    let documents: URL

    var id: String { key }
}

/// A copy of a game's saves in the saves folder.
struct CartoucheSaveBackup: Hashable, Identifiable {
    let path: String
    let date: Date
    let size: UInt64

    var id: String { path }
}

@MainActor
final class CartoucheSaveBackups: ObservableObject {
    static let shared = CartoucheSaveBackups()
    /// The copies kept for each game.
    nonisolated static let kept = 10
    /// The folders of a game's Documents that nxnative keeps its saves in.
    nonisolated static let folders = ["save", "save_device"]

    /// Whether copies are being made.
    @Published private(set) var isCopying = false
    /// The date of each game's last copy, by target key.
    @Published private(set) var lastCopy: [String: Date]
    /// Why the last copies failed, if they did, and the report on it.
    @Published private(set) var problemReport: CartoucheReport?
    var problem: String? { problemReport?.message }

    private let settings: CartoucheStorageSettings
    private let defaults: UserDefaults
    private var run: Task<Void, Never>?
    private var background = UIBackgroundTaskIdentifier.invalid
    private static let fingerprintsKey = "Cartouche.saves.fingerprints"
    private static let lastKey = "Cartouche.saves.last"

    init(settings: CartoucheStorageSettings = .shared, defaults: UserDefaults = .standard) {
        self.settings = settings
        self.defaults = defaults
        lastCopy = (defaults.dictionary(forKey: Self.lastKey) as? [String: Date]) ?? [:]
    }

    /// Whether the player chose a saves folder.
    var isOn: Bool { settings.location(.saves) != nil }

    /// Copies the saves of the TARGETS that changed since their last copy,
    /// unless copies are being made.
    func copyChanged(_ targets: [CartoucheSaveTarget]) {
        guard run == nil, isOn, !targets.isEmpty else { return }
        run = Task {
            _ = await makeCopies(targets, always: false)
            run = nil
        }
    }

    /// Copies TARGET's saves now, changed or not.
    func copyNow(_ target: CartoucheSaveTarget) async -> Bool {
        await finish()
        return await makeCopies([target], always: true)
    }

    /// Waits for the copies under way: before a game starts, which closes
    /// Cartouche.
    func finish() async {
        while let run {
            await run.value
            if self.run == run { break }
        }
    }

    // MARK: Copying

    private func makeCopies(_ targets: [CartoucheSaveTarget], always: Bool) async -> Bool {
        guard let location = settings.location(.saves) else { return false }
        let place = location.server.id.uuidString + "|" + location.path
        var fingerprints = (defaults.dictionary(forKey: Self.fingerprintsKey) as? [String: String]) ?? [:]
        var due: [(target: CartoucheSaveTarget, stamp: String)] = []
        for target in targets {
            // A game that never saved has nothing to copy.
            guard let fingerprint = await Self.fingerprint(of: target.documents) else { continue }
            let stamp = place + "|" + fingerprint
            if always || fingerprints[target.key] != stamp {
                due.append((target, stamp))
            }
        }
        guard !due.isEmpty else { return true }

        isCopying = true
        beginBackground()
        defer {
            isCopying = false
            endBackground()
        }
        var remote: CartoucheRemote?
        var done = true
        do {
            let connected = try await CartoucheStorage.connect(location.server, settings: settings)
            remote = connected
            if await settings.checkAccess(connected, server: location.server.id, path: location.path) == false {
                throw CartoucheStorageError(CartoucheText.savesReadOnly)
            }
            for (target, stamp) in due {
                let folder = CartoucheStoragePath.join(location.path, Self.folderName(target))
                try await connected.makeFolders(folder)
                let date = Date()
                let upload = try await connected.create(CartoucheStoragePath.join(folder, Self.fileName(date)), size: nil)
                do {
                    try await Self.writeZip(of: target.documents, to: upload)
                    try await upload.finish()
                } catch {
                    await upload.cancel()
                    throw error
                }
                fingerprints[target.key] = stamp
                defaults.set(fingerprints, forKey: Self.fingerprintsKey)
                lastCopy[target.key] = date
                defaults.set(lastCopy, forKey: Self.lastKey)
                do {
                    try await Self.prune(folder, in: connected)
                } catch {
                    NSLog("[Cartouche] cannot remove old copies of %@: %@", target.name, error.localizedDescription)
                }
            }
            problemReport = nil
            CartoucheReports.note("Saves copied: \(due.count) " + (due.count == 1 ? "game" : "games"))
        } catch {
            // The copies Cartouche makes by itself, each time it comes
            // back, fail away from home too: their report is not kept.
            problemReport = CartoucheReports.make(.saves, CartoucheText.savesCopyFailed, message: error.localizedDescription,
                                                  error: error, step: "Copying the saves to " + CartoucheReports.place(.saves),
                                                  facts: [.init("Games", String(due.count))], inBackground: !always)
            NSLog("[Cartouche] saves not copied: %@", error.localizedDescription)
            done = false
        }
        await remote?.disconnect()
        return done
    }

    /// A few seconds more to finish, if the player leaves Cartouche.
    private func beginBackground() {
        guard background == .invalid else { return }
        background = UIApplication.shared.beginBackgroundTask(withName: "Cartouche saves") { [weak self] in
            // iOS calls this on the main thread, as the time runs out.
            Task { @MainActor in self?.endBackground() }
        }
    }

    private func endBackground() {
        guard background != .invalid else { return }
        UIApplication.shared.endBackgroundTask(background)
        background = .invalid
    }

    /// The folder of a game's copies: "<game> [<title ID>]".
    nonisolated static func folderName(_ target: CartoucheSaveTarget) -> String {
        var name = CartoucheStoragePath.fileName(target.name)
        if let titleId = target.titleId { name += " [\(titleId.uppercased())]" }
        return name
    }

    /// Made for each use: a formatter is not for several threads at once.
    nonisolated private static func nameFormat() -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd'T'HH-mm-ss'Z'"
        return formatter
    }

    /// A copy's name, its date in UTC: "2026-11-06T14-05-33Z.zip". The
    /// names sort by date.
    nonisolated static func fileName(_ date: Date) -> String {
        nameFormat().string(from: date) + ".zip"
    }

    nonisolated static func date(inName name: String) -> Date? {
        guard name.lowercased().hasSuffix(".zip") else { return nil }
        return nameFormat().date(from: String(name.dropLast(4)))
    }

    /// What the saves are now: their files' count, size and newest date.
    /// Nil when the game has no saves.
    nonisolated static func fingerprint(of documents: URL) async -> String? {
        var count = 0
        var size: UInt64 = 0
        var newest: Int64 = 0
        var found = false
        for folder in folders {
            let root = documents.appendingPathComponent(folder, isDirectory: true)
            guard let walker = FileManager.default.enumerator(at: root,
                                                              includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey,
                                                                                           .isRegularFileKey]) else { continue }
            found = found || FileManager.default.fileExists(atPath: root.path)
            while let url = walker.nextObject() as? URL {
                let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey])
                guard values?.isRegularFile == true else { continue }
                count += 1
                size += UInt64(values?.fileSize ?? 0)
                let date = Int64(((values?.contentModificationDate ?? .distantPast).timeIntervalSince1970 * 1000).rounded())
                newest = max(newest, date)
            }
        }
        return found ? "\(count)|\(size)|\(newest)" : nil
    }

    /// The saves' folders, files and links, as a zip with paths from
    /// Documents: save/..., save_device/...
    nonisolated static func writeZip(of documents: URL, to sink: CartoucheByteSink) async throws {
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

    /// Keeps the newest copies of a game, and removes what an interrupted
    /// copy left.
    nonisolated static func prune(_ folder: String, in remote: CartoucheRemote) async throws {
        let items = try await remote.list(folder).filter { !$0.isFolder }
        for item in items where item.name.hasSuffix(".partial") {
            try await remote.delete(CartoucheStoragePath.join(folder, item.name))
        }
        let copies = items.filter { date(inName: $0.name) != nil }.map(\.name).sorted(by: >)
        for name in copies.dropFirst(kept) {
            try await remote.delete(CartoucheStoragePath.join(folder, name))
        }
    }

    // MARK: Listing and putting back

    /// TARGET's copies in the saves folder, the newest first.
    func copies(of target: CartoucheSaveTarget) async throws -> [CartoucheSaveBackup] {
        guard let location = settings.location(.saves) else { return [] }
        let remote = try await CartoucheStorage.connect(location.server, settings: settings)
        let folder = CartoucheStoragePath.join(location.path, Self.folderName(target))
        var items: [CartoucheRemoteItem] = []
        do {
            // A game never copied has no folder yet.
            let parent = try await remote.list(CartoucheStoragePath.parent(folder))
            if parent.contains(where: { $0.isFolder && $0.name == CartoucheStoragePath.name(folder) }) {
                items = try await remote.list(folder)
            }
        } catch {
            await remote.disconnect()
            throw error
        }
        await remote.disconnect()
        return items.compactMap { item in
            guard !item.isFolder, let date = Self.date(inName: item.name) else { return nil }
            return CartoucheSaveBackup(path: CartoucheStoragePath.join(folder, item.name), date: date, size: item.size)
        }
        .sorted { $0.date > $1.date }
    }

    /// Puts BACKUP back as TARGET's saves. The saves it replaces are copied
    /// first; nothing changes on the iPhone unless the backup reads whole.
    func restore(_ backup: CartoucheSaveBackup, of target: CartoucheSaveTarget) async throws {
        guard let location = settings.location(.saves) else { return }
        await finish()
        let fileManager = FileManager.default
        let work = fileManager.temporaryDirectory.appendingPathComponent("CartoucheRestore", isDirectory: true)
        try? fileManager.removeItem(at: work)
        try fileManager.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: work) }

        // The backup, here first: copying the saves now may remove the
        // oldest backup.
        let remote = try await CartoucheStorage.connect(location.server, settings: settings)
        let local = work.appendingPathComponent("backup.zip")
        do {
            let source = try await remote.open(backup.path)
            let sink = try CartoucheFileSink(local)
            var offset: UInt64 = 0
            while offset < source.size {
                let part = try await source.read(at: offset, count: Int(min(source.size - offset, 8 << 20)))
                guard !part.isEmpty else { throw CartoucheStorageError(CartoucheText.savesCopyUnreadable) }
                try await sink.write(part)
                offset += UInt64(part.count)
            }
            try sink.close()
        } catch {
            await remote.disconnect()
            throw error
        }
        await remote.disconnect()

        // Every file of the backup, checked, before the saves change.
        let unpacked = work.appendingPathComponent("unpacked", isDirectory: true)
        try fileManager.createDirectory(at: unpacked, withIntermediateDirectories: true)
        let source = try CartoucheFileSource(local)
        let entries = try await CartoucheZip.entries(of: source)
        guard entries.allSatisfy({ entry in
            Self.folders.contains { entry.name == $0 + "/" || entry.name.hasPrefix($0 + "/") }
        }) else {
            throw CartoucheStorageError(CartoucheText.savesCopyUnreadable)
        }
        try await CartoucheZip.extract(source, entries: entries, into: unpacked, progress: nil)

        guard await makeCopies([target], always: true) || !Self.hasSaves(target.documents) else {
            throw CartoucheStorageError(problem ?? CartoucheText.savesCopyUnreadable)
        }
        try fileManager.createDirectory(at: target.documents, withIntermediateDirectories: true)
        for folder in Self.folders + ["save.work"] {
            let old = target.documents.appendingPathComponent(folder, isDirectory: true)
            if fileManager.fileExists(atPath: old.path) {
                try fileManager.removeItem(at: old)
            }
        }
        for folder in Self.folders {
            let new = unpacked.appendingPathComponent(folder, isDirectory: true)
            if fileManager.fileExists(atPath: new.path) {
                try fileManager.moveItem(at: new, to: target.documents.appendingPathComponent(folder, isDirectory: true))
            }
        }
        // The saves put back are copied already.
        if let fingerprint = await Self.fingerprint(of: target.documents) {
            var fingerprints = (defaults.dictionary(forKey: Self.fingerprintsKey) as? [String: String]) ?? [:]
            fingerprints[target.key] = location.server.id.uuidString + "|" + location.path + "|" + fingerprint
            defaults.set(fingerprints, forKey: Self.fingerprintsKey)
        }
    }

    nonisolated private static func hasSaves(_ documents: URL) -> Bool {
        folders.contains { FileManager.default.fileExists(atPath: documents.appendingPathComponent($0).path) }
    }
}
