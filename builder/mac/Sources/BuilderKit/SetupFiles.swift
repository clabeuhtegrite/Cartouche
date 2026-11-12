//
//  SetupFiles.swift
//  Cartouche Builder
//
//  What the setup assistant finds in the folder the player picks for
//  their dumps, read as the engine reads it (library.py): how many games it
//  holds, and, in one that holds none, whether it holds what nxnative built
//  already, its IPAs or the image of a game's files (romfs.img), which go
//  in the games folder, as the assistant says.
//

import Foundation

/// The files the assistant looks at, away from the main thread.
public enum SetupFiles {
    static let packageExtensions: Set<String> = ["nsp", "xci", "nsz", "xcz"]
    /// How deep games are looked for, as the engine does (library.py).
    static let depth = 4

    /// How many games the dumps folder at PATH holds, as the engine finds
    /// them (library.py), loose or in folders of folders: each .nup, each
    /// dump folder and zipped dump, and the packages of each game, known by
    /// the title ID in their names or their folder's; nil when it cannot be
    /// read. The engine reads a file named without its ID in the file
    /// itself: here each counts as a game.
    public static func countGames(at path: String) async -> Int? {
        let url = URL(fileURLWithPath: path, isDirectory: true)
        return await Task.detached(priority: .utility) { () -> Int? in
            guard (try? FileManager.default.contentsOfDirectory(atPath: url.path)) != nil else { return nil }
            var named = Set<String>()
            var unnamed = 0
            SetupFiles.count(url, top: true, depth: 0, named: &named, unnamed: &unnamed)
            return named.count + unnamed
        }.value
    }

    private static func count(_ folder: URL, top: Bool, depth: Int, named: inout Set<String>, unnamed: inout Int) {
        guard let items = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isDirectoryKey],
                                                                       options: [.skipsHiddenFiles]) else { return }
        var files: [URL] = [], folders: [URL] = []
        for item in items.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            if (try? item.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
                let name = item.lastPathComponent
                if !(name.lowercased().hasSuffix("_build") || name.lowercased().hasSuffix("_dump") || name == "__MACOSX") { folders.append(item) }
            } else {
                files.append(item)
            }
        }
        let packages = files.filter { SetupFiles.packageExtensions.contains($0.pathExtension.lowercased()) }
        let nups = files.filter { $0.pathExtension.lowercased() == "nup" }
        if !packages.isEmpty {
            let folderID = top ? nil : SetupFiles.baseTitleID(in: folder.lastPathComponent)
            let ids = Set(packages.compactMap { SetupFiles.baseTitleID(in: $0.lastPathComponent) })
            if !top, let id = folderID ?? (ids.count == 1 ? ids.first : nil), ids.isSubset(of: [id]) {
                named.insert(id)
            } else {
                named.formUnion(ids)
                unnamed += packages.filter { SetupFiles.baseTitleID(in: $0.lastPathComponent) == nil }.count
            }
        }
        for nup in nups {
            if let id = SetupFiles.baseTitleID(in: nup.lastPathComponent) ?? (nups.count == 1 && packages.isEmpty && !top ? SetupFiles.baseTitleID(in: folder.lastPathComponent) : nil) {
                named.insert(id)
            } else {
                unnamed += 1
            }
        }
        if packages.isEmpty && nups.isEmpty {
            if SetupFiles.isDump(folder) {
                unnamed += 1
                return
            }
            unnamed += files.filter { $0.pathExtension.lowercased() == "zip" }.count
        }
        guard depth < SetupFiles.depth else { return }
        for sub in folders { SetupFiles.count(sub, top: false, depth: depth + 1, named: &named, unnamed: &unnamed) }
    }

    /// Whether the folder at PATH holds what nxnative built already, loose
    /// or in folders as deep as games are looked for, its own build folders
    /// too: an IPA, or the image of a game's files (romfs.img, in any letter
    /// case), which go in the games folder (library.py, _built).
    public static func holdsBuilt(at path: String) async -> Bool {
        let url = URL(fileURLWithPath: path, isDirectory: true)
        return await Task.detached(priority: .utility) { () -> Bool in
            SetupFiles.holdsBuilt(url, depth: 0)
        }.value
    }

    private static func holdsBuilt(_ folder: URL, depth: Int) -> Bool {
        guard let items = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isDirectoryKey],
                                                                       options: [.skipsHiddenFiles]) else { return false }
        var folders: [URL] = []
        for item in items {
            let name = item.lastPathComponent.lowercased()
            if (try? item.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
                folders.append(item)
            } else if name.hasSuffix(".ipa") || name.hasSuffix("romfs.img") {
                return true
            }
        }
        return depth < SetupFiles.depth && folders.contains { SetupFiles.holdsBuilt($0, depth: depth + 1) }
    }

    /// Whether FOLDER is laid out as nxnative takes a dump (library.is_dump).
    private static func isDump(_ folder: URL) -> Bool {
        let manager = FileManager.default
        let has = { (path: String) in manager.fileExists(atPath: folder.appendingPathComponent(path).path) }
        let versions = ((try? manager.contentsOfDirectory(atPath: folder.appendingPathComponent("updates").path)) ?? []).filter { Int($0) != nil }
        if has("base/exefs/main.npdm") {
            return has("base/romfs") || versions.contains { has("updates/\($0)/romfs") }
        }
        if has("exefs/main.npdm") && has("romfs") { return true }
        return versions.contains { has("updates/\($0)/exefs/main.npdm") && has("updates/\($0)/romfs") }
    }

    /// The base game of the first title ID a name carries, as the engine
    /// reads it (titles.py): an update's or a DLC's ID gives its game's.
    static func baseTitleID(in name: String) -> String? {
        guard let match = name.range(of: "(?<![0-9A-Fa-f])[0-9A-Fa-f]{16}(?![0-9A-Fa-f])", options: .regularExpression),
              let value = UInt64(name[match], radix: 16) else { return nil }
        let low = value & 0xFFF
        let base = low == 0 ? value : low == 0x800 ? value & ~0xFFF : (value & ~0xFFF) &- 0x1000
        return String(format: "%016llX", base)
    }
}
