//
//  CartoucheSwitchSaveArchive.swift
//  Cartouche
//
//  A game's save between the player's Switch and this iPhone, in the folder
//  or the ZIP archive JKSV or Checkpoint makes there (CartoucheSwitchSave):
//  what the player picked in Files, read and unpacked, and a game's save
//  written as an archive JKSV puts back on the Switch, its files at the
//  root, without the fiche, which JKSV does without.
//

import Foundation

/// What the player picked in Files, read: the save in it.
struct CartoucheSwitchSavePick: Equatable {
    /// The folder or the archive picked.
    let url: URL
    let isArchive: Bool
    var export: CartoucheSwitchSaveExport

    /// Its name, and its folder's, which may give the game's title ID, as
    /// Checkpoint names a game's folder.
    var names: [String] {
        [url.deletingPathExtension().lastPathComponent, url.deletingLastPathComponent().lastPathComponent]
    }
}

enum CartoucheSwitchSaveArchive {
    /// The largest fiche read: JKSV's is 86 bytes.
    private static let ficheLimit = 4096

    /// Reads URL, a folder or a ZIP archive the player picked, with access to
    /// it granted: the save in it, and its fiche.
    static func read(_ url: URL) async throws -> CartoucheSwitchSavePick {
        var isFolder: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isFolder) else {
            throw CocoaError(.fileReadNoSuchFile, userInfo: [NSFilePathErrorKey: url.path])
        }
        if isFolder.boolValue {
            var export = try CartoucheSwitchSave.export(of: CartoucheSwitchSave.items(inFolder: url), named: url.lastPathComponent)
            if let path = export.fichePath {
                export.meta = (try? Data(contentsOf: url.appendingPathComponent(path))).flatMap(CartoucheSwitchSaveMeta.init)
            }
            return CartoucheSwitchSavePick(url: url, isArchive: false, export: export)
        }
        let source = try CartoucheFileSource(url)
        let entries = try await CartoucheZip.entries(of: source)
        var export = try CartoucheSwitchSave.export(of: entries.map(item), named: url.deletingPathExtension().lastPathComponent)
        if let path = export.fichePath, let entry = entries.first(where: { name(of: $0) == path }) {
            export.meta = (try? await CartoucheZip.data(of: entry, in: source, limit: ficheLimit)).flatMap(CartoucheSwitchSaveMeta.init)
        }
        return CartoucheSwitchSavePick(url: url, isArchive: true, export: export)
    }

    /// An archive's entry, as an item of what was picked.
    static func item(_ entry: CartoucheZipEntry) -> CartoucheSwitchSaveItem {
        CartoucheSwitchSaveItem(path: entry.name, size: entry.size, isFolder: entry.isDirectory, isLink: entry.isSymlink)
    }

    private static func name(of entry: CartoucheZipEntry) -> String {
        entry.name.split(separator: "/", omittingEmptySubsequences: true).joined(separator: "/")
    }

    /// Copies, or unpacks, the save PICK holds to FOLDER in STAGED, as it
    /// goes in the game's Documents (CartoucheSwitchSave.place), with access
    /// to it granted. WORK: a folder of this iPhone's, where an archive's
    /// files are unpacked first, every one checked.
    static func stage(_ pick: CartoucheSwitchSavePick, as folder: String, into staged: URL, work: URL) async throws {
        guard pick.isArchive else {
            try CartoucheSwitchSave.stage(pick.export, from: pick.url, as: folder, into: staged)
            return
        }
        let source = try CartoucheFileSource(pick.url)
        let entries = try await CartoucheZip.entries(of: source).filter { pick.export.takes($0.name) }
        let unpacked = work.appendingPathComponent("unpacked", isDirectory: true)
        try await CartoucheZip.extract(source, entries: entries, into: unpacked)
        try CartoucheSwitchSave.stage(pick.export, from: unpacked, as: folder, into: staged, moving: true)
    }

    /// Writes the save in SAVE, a game's Documents/save, to SINK, as an
    /// archive JKSV puts back on the Switch: its files and folders at the
    /// root, under the names the game gave them (CartoucheSwitchSave.entries).
    /// How many files it holds.
    @discardableResult
    static func writeZip(ofSave save: URL, to sink: CartoucheByteSink) async throws -> Int {
        let writer = CartoucheZipWriter(sink: sink)
        var files = 0
        for entry in try CartoucheSwitchSave.entries(ofSave: save) {
            if entry.isFolder {
                try await writer.addFolder(entry.name + "/", date: entry.date)
            } else {
                try await writer.addFile(entry.name, from: entry.url, date: entry.date)
                files += 1
            }
        }
        try await writer.finish()
        return files
    }
}
