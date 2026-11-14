//
//  CartoucheSwitchSave.swift
//  Cartouche
//
//  A game's save the player brings from their own Switch, to play on from
//  it on this iPhone: what JKSV or Checkpoint exported there, a folder or a
//  ZIP archive of the save's files, put in the game's Documents, where
//  nxnative keeps its saves (dm/host/hle_fs.c). Nothing is converted:
//
//  - nxnative's save is the Switch's: the files the game wrote to its save
//    data, under the same names, and nothing else. A player's save, an
//    account save, is the game's Documents/save; the console's, a device
//    save, too, but for a game that mounts both, as Mario Kart 8 Deluxe,
//    whose device save is Documents/save_device, made at its first start.
//  - JKSV writes .nx_save_meta.bin beside the files (fs::SaveMetaData,
//    include/fs/SaveMetaData.hpp): the game's title ID and the save's type,
//    which Cartouche checks. Checkpoint writes the files alone, in a
//    folder of the game's, "0x<title ID> <name>": a save without the fiche
//    is taken for a player's, and the title ID a name around it gives, if
//    any, for the game's.
//  - The folder the save replaces is kept first, in
//    save-backups/<date> before import, beside the backups nxnative makes
//    of the saves its cloud sync replaces, which it never touches
//    (save_sync.c, is_backup); the game's sheet puts it back, and what that
//    replaces is kept the same way.
//  - The save's files are dated at the import: the newest save, which
//    Cartouche's sync (CartoucheSaveSync) and nxnative's cloud saves then
//    send on, rather than an older one of the other side.
//
//  Platform-independent: tested on its own by launcher/Package.swift.
//

import Foundation

/// The type of a save on a Switch, FsSaveDataType, as JKSV's fiche gives it.
enum CartoucheSwitchSaveKind: Equatable {
    /// A user's save: their game.
    case account
    /// The console's save, one for all its users, where a few games keep
    /// their game, as Animal Crossing: New Horizons its island.
    case device
    /// System, BCAT, temporary or cache data: no game to play on.
    case other(UInt8)

    init(type: UInt8) {
        switch type {
        case 1: self = .account
        case 3: self = .device
        default: self = .other(type)
        }
    }
}

/// The fiche JKSV writes beside a save's files.
struct CartoucheSwitchSaveMeta: Equatable {
    static let fileName = ".nx_save_meta.bin"
    /// "JKSV", read as a 32-bit number, little-endian, as the Switch reads it.
    static let magic: UInt32 = 0x5653_4B4A
    /// Its size: a packed structure.
    static let size = 86

    /// The game's title ID: 16 hexadecimal digits in capitals, as the
    /// catalogue writes it.
    let titleId: String
    let kind: CartoucheSwitchSaveKind

    /// The fiche in DATA, nil for none: too short, or not JKSV's. Its
    /// fields, in bytes: the magic (4), JKSV's revision (1), the
    /// application ID (8), the account (16), the system save ID (8), the
    /// type (1), the rank (1), the index (2), the owner (8), the time (8),
    /// the flags (4), the size (8), the journal's (8), the commit (8) and
    /// the space (1).
    init?(_ data: Data) {
        let bytes = [UInt8](data.prefix(Self.size))
        guard bytes.count == Self.size, Self.number(bytes, at: 0, count: 4) == UInt64(Self.magic) else { return nil }
        titleId = String(format: "%016llX", Self.number(bytes, at: 5, count: 8))
        kind = CartoucheSwitchSaveKind(type: bytes[37])
    }

    private static func number(_ bytes: [UInt8], at offset: Int, count: Int) -> UInt64 {
        (0 ..< count).reduce(UInt64(0)) { $0 | UInt64(bytes[offset + $1]) << UInt64(8 * $1) }
    }
}

/// A file or a folder of what the player picked, a folder or an archive:
/// its path there, with "/" between folders.
struct CartoucheSwitchSaveItem: Hashable {
    var path: String
    var size: UInt64 = 0
    var isFolder = false
    var isLink = false
}

/// Why a save from a Switch cannot come in place of the game's.
enum CartoucheSwitchSaveProblem: Error, Equatable {
    /// No file of a save in it.
    case empty
    /// More than one save: several fiches, or a game's folder of saves, as
    /// JKSV and Checkpoint keep them.
    case several
    /// A path that would land outside the save, or a link, which no save
    /// has.
    case unsafe(String)
    /// Two names that a Switch tells apart, but not the iPhone: they differ
    /// only by their capitals.
    case caseClash(String, String)
    /// The save of another game, by its title ID.
    case otherGame(String)
    /// System, BCAT, temporary or cache data.
    case notAGame
    /// The console's save of a game that never started: whether it goes to
    /// save or to save_device, its first start tells.
    case startFirst
    /// nxnative stopped while it brought in the save of its cloud saves:
    /// the game's next start finishes that, or undoes it, first.
    case cloudPull
    /// The game started meanwhile: its save is its own while it runs.
    case running
}

/// A save exported from a Switch, as Cartouche read it.
struct CartoucheSwitchSaveExport: Equatable {
    /// The folder its files are in, in what was picked: "" for its root,
    /// else "Name/", as in an archive made of the save's folder.
    var root = ""
    /// Its files, by their path in the save.
    var files: [CartoucheSwitchSaveItem] = []
    /// Its folders, empty ones too, by their path in the save.
    var folders: [String] = []
    /// Where JKSV's fiche is, in what was picked, if there is one.
    var fichePath: String?
    /// The fiche, once read: nil when there is none, or it is not JKSV's.
    var meta: CartoucheSwitchSaveMeta?

    var size: UInt64 { files.reduce(0) { $0 + $1.size } }

    /// Whether the item at PATH, in what was picked, goes in the save: one
    /// of its files or folders.
    func takes(_ path: String) -> Bool {
        let parts = path.split(separator: "/", omittingEmptySubsequences: true).joined(separator: "/")
        guard parts.hasPrefix(root) else { return false }
        let inner = String(parts.dropFirst(root.count))
        return files.contains { $0.path == inner } || folders.contains(inner)
    }
}

/// A file or a folder of a game's save as it goes to the Switch, in an
/// archive JKSV puts back there.
struct CartoucheSwitchSaveEntry: Equatable {
    /// Its name in the archive: its path in the save, under the names the
    /// game gave its files.
    let name: String
    let url: URL
    let isFolder: Bool
    let date: Date
}

/// A folder of saves Cartouche kept in a game's save-backups.
struct CartoucheSwitchSaveBackup: Equatable {
    let folder: URL
    let date: Date
}

enum CartoucheSwitchSave {
    /// The folders of a game's Documents where nxnative keeps a player's
    /// save, and the console's for a game that has both
    /// (CartoucheSaveSync.folders).
    static let saveFolder = "save"
    static let deviceFolder = "save_device"
    /// nxnative's journal of the cloud's save coming in, while it comes:
    /// left there, the game's next start finishes or undoes it, by the
    /// folders it moved (save_sync.c, recover).
    static let pullJournal = "save.pull"
    /// nxnative's working copy of a save folder while the game runs, and its
    /// next committed version while the game commits it (hle_fs.c): what is
    /// left of them, after the game stopped, nxnative discards at its next
    /// start.
    static let workSuffix = ".work"
    static let newSuffix = ".new"
    /// nxnative's backups of the saves it replaces, Documents/save-backups,
    /// where Cartouche keeps its own.
    static let backupsFolder = "save-backups"
    /// What Cartouche's backups hold: the saves an import replaced, and
    /// those that putting them back replaced.
    static let beforeImport = "before import"
    static let beforePutBack = "before putting back"
    /// The backups kept of each, as nxnative keeps ten of each side.
    static let kept = 10
    /// More items than this in what was picked is more than a save: a
    /// folder of saves, or of anything.
    static let itemLimit = 20_000

    // MARK: Reading an export

    /// What an export holds besides a save, which never goes with it: what
    /// macOS and Windows leave in a folder or an archive they made.
    static func isJunk<Name: StringProtocol>(_ name: Name) -> Bool {
        name == ".DS_Store" || name.hasPrefix("._") || name == "__MACOSX" || name == "Thumbs.db" || name == "desktop.ini"
    }

    /// The save in ITEMS, those of the folder or the archive the player
    /// picked, of that NAME (an archive's without its extension): where its
    /// files are, and its fiche, if it has one, whose bytes are read next.
    /// The save is where the fiche is; without one, at the root of what was
    /// picked, or in the one folder there of its name, as macOS and Windows
    /// zip a folder.
    static func export(of items: [CartoucheSwitchSaveItem], named name: String? = nil) throws -> CartoucheSwitchSaveExport {
        guard items.count <= itemLimit else { throw CartoucheSwitchSaveProblem.several }
        var listed: [(parts: [Substring], item: CartoucheSwitchSaveItem)] = []
        for item in items {
            let parts = item.path.split(separator: "/", omittingEmptySubsequences: true)
            if parts.contains(where: { isJunk($0) }) { continue }
            guard !item.path.hasPrefix("/"), !item.path.contains("\\"), !parts.isEmpty,
                  !parts.contains(where: { $0 == ".." || $0 == "." }), !item.isLink else {
                throw CartoucheSwitchSaveProblem.unsafe(item.path)
            }
            listed.append((parts, item))
        }
        let fiches = listed.filter { !$0.item.isFolder && $0.parts.last == Substring(CartoucheSwitchSaveMeta.fileName) }
        guard fiches.count <= 1 else { throw CartoucheSwitchSaveProblem.several }

        var root: [Substring] = []
        if let fiche = fiches.first {
            root = Array(fiche.parts.dropLast())
        } else if let name, !name.isEmpty {
            let tops = Set(listed.map { $0.parts[0] })
            let atTop = listed.contains { $0.parts.count == 1 && !$0.item.isFolder }
            // A game's folder, "0x<title ID> <name>", as Checkpoint keeps one
            // for each game: its saves are its folders.
            let isGames = titleId(inName: name) != nil
            if !atTop, tops.count == 1, let top = tops.first, top == Substring(name) || isGames {
                // The save's folder, zipped by macOS or Windows, or the one
                // save of a game's folder.
                root = [top]
            } else if !atTop, tops.count > 1, isGames {
                throw CartoucheSwitchSaveProblem.several
            }
        }

        var export = CartoucheSwitchSaveExport(root: root.isEmpty ? "" : root.joined(separator: "/") + "/")
        export.fichePath = fiches.first.map { $0.parts.joined(separator: "/") }
        // Swift's strings are the same when their accents are, written in
        // either form: names are told apart by their bytes here, as on a
        // Switch.
        var folders: [[UInt8]: String] = [:]
        var files: [[UInt8]: CartoucheSwitchSaveItem] = [:]
        for (parts, item) in listed {
            guard parts.count >= root.count, Array(parts.prefix(root.count)) == root else {
                // Beside the fiche's folder: what was picked holds more.
                throw CartoucheSwitchSaveProblem.several
            }
            let inner = parts.dropFirst(root.count)
            guard !inner.isEmpty, export.fichePath != parts.joined(separator: "/") else { continue }
            let path = inner.joined(separator: "/")
            for count in 1 ..< inner.count {
                let around = inner.prefix(count).joined(separator: "/")
                folders[Array(around.utf8)] = around
            }
            if item.isFolder {
                folders[Array(path.utf8)] = path
            } else {
                guard files[Array(path.utf8)] == nil else { throw CartoucheSwitchSaveProblem.unsafe(item.path) }
                files[Array(path.utf8)] = CartoucheSwitchSaveItem(path: path, size: item.size)
            }
        }
        guard !files.isEmpty else { throw CartoucheSwitchSaveProblem.empty }
        if let both = folders.first(where: { files[$0.key] != nil }) {
            throw CartoucheSwitchSaveProblem.unsafe(export.root + both.value)
        }
        // The iPhone's names ignore capitals and the form of accents: two
        // names a Switch tells apart cannot both be there.
        var seen: [String: String] = [:]
        for path in folders.values.sorted() + files.values.map(\.path).sorted() {
            let key = path.precomposedStringWithCanonicalMapping.lowercased()
            if let other = seen[key] { throw CartoucheSwitchSaveProblem.caseClash(other, path) }
            seen[key] = path
        }
        export.files = files.values.sorted { $0.path < $1.path }
        export.folders = folders.values.sorted()
        return export
    }

    /// The files and folders in FOLDER, a folder the player picked in Files,
    /// by their paths there: links are listed as links, never followed.
    static func items(inFolder folder: URL) throws -> [CartoucheSwitchSaveItem] {
        let fileManager = FileManager.default
        guard let walker = fileManager.enumerator(atPath: folder.path) else {
            throw CocoaError(.fileReadNoSuchFile, userInfo: [NSFilePathErrorKey: folder.path])
        }
        var items: [CartoucheSwitchSaveItem] = []
        while let relative = walker.nextObject() as? String {
            let attributes = try fileManager.attributesOfItem(atPath: folder.appendingPathComponent(relative).path)
            let type = attributes[.type] as? FileAttributeType
            let size = (attributes[.size] as? NSNumber)?.uint64Value ?? (attributes[.size] as? UInt64) ?? 0
            items.append(CartoucheSwitchSaveItem(path: relative, size: size, isFolder: type == .typeDirectory,
                                                 isLink: type == .typeSymbolicLink))
            guard items.count <= itemLimit else { throw CartoucheSwitchSaveProblem.several }
        }
        return items
    }

    /// The title ID a name holds, as Checkpoint names a game's folder,
    /// "0x0100152000022000 Mario Kart 8 Deluxe": 16 hexadecimal digits,
    /// after "0x" or not, apart from other letters and digits; in capitals.
    static func titleId(inName name: String) -> String? {
        for word in name.split(whereSeparator: { !$0.isLetter && !$0.isNumber }) {
            var digits = word
            if digits.count == 18, digits.lowercased().hasPrefix("0x") { digits = digits.dropFirst(2) }
            if digits.count == 16, digits.allSatisfy(\.isHexDigit) { return digits.uppercased() }
        }
        return nil
    }

    // MARK: Where it goes

    /// The folder of the game's Documents the save goes to, in place of the
    /// one there: save, for a player's save and a save without a fiche; for
    /// the console's, save_device when the game has one, else save. The
    /// fiche's title ID, else the first one NAMES give (the names of what
    /// was picked and of the folder around it), must be one of the game's,
    /// TITLEIDS, its regions' too, when the catalogue knows them. DOCUMENTS:
    /// the game's, nil for a game that never started, whose data folder is
    /// made for the import.
    static func folder(for export: CartoucheSwitchSaveExport, game titleIds: [String], names: [String] = [],
                       documents: URL?) throws -> String {
        let fileManager = FileManager.default
        if let documents, fileManager.fileExists(atPath: documents.appendingPathComponent(pullJournal).path) {
            throw CartoucheSwitchSaveProblem.cloudPull
        }
        let game = Set(titleIds.filter { !$0.isEmpty }.map { $0.uppercased() })
        if let meta = export.meta {
            if !game.isEmpty, !game.contains(meta.titleId) { throw CartoucheSwitchSaveProblem.otherGame(meta.titleId) }
            switch meta.kind {
            case .account:
                return saveFolder
            case .device:
                if let documents, isFolder(documents.appendingPathComponent(deviceFolder)) { return deviceFolder }
                if let documents, isFolder(documents.appendingPathComponent(saveFolder)) { return saveFolder }
                throw CartoucheSwitchSaveProblem.startFirst
            case .other:
                throw CartoucheSwitchSaveProblem.notAGame
            }
        }
        if !game.isEmpty, let named = names.lazy.compactMap(titleId(inName:)).first, !game.contains(named) {
            throw CartoucheSwitchSaveProblem.otherGame(named)
        }
        return saveFolder
    }

    private static func isFolder(_ url: URL) -> Bool {
        var folder: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &folder) && folder.boolValue
    }

    // MARK: Putting it in place

    /// Copies, or MOVING moves, the save's files and folders from SOURCE,
    /// the folder picked or the archive unpacked, to FOLDER in STAGED, as
    /// they go in the game's Documents.
    static func stage(_ export: CartoucheSwitchSaveExport, from source: URL, as folder: String, into staged: URL,
                      moving: Bool = false) throws {
        let fileManager = FileManager.default
        let base = export.root.isEmpty ? source : source.appendingPathComponent(String(export.root.dropLast()), isDirectory: true)
        let destination = staged.appendingPathComponent(folder, isDirectory: true)
        try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)
        for path in export.folders {
            try fileManager.createDirectory(at: destination.appendingPathComponent(path, isDirectory: true),
                                            withIntermediateDirectories: true)
        }
        for file in export.files {
            let from = base.appendingPathComponent(file.path)
            let to = destination.appendingPathComponent(file.path)
            if moving {
                try fileManager.moveItem(at: from, to: to)
            } else {
                try fileManager.copyItem(at: from, to: to)
            }
        }
    }

    /// Puts the save STAGED holds (stage) in place of the game's in
    /// DOCUMENTS, dated NOW: the folder it replaces is kept first in
    /// save-backups/<date> before import. The backup, nil when the game had
    /// no save there.
    @discardableResult
    static func place(_ staged: URL, in documents: URL, now: Date = Date()) throws -> URL? {
        guard !FileManager.default.fileExists(atPath: documents.appendingPathComponent(pullJournal).path) else {
            throw CartoucheSwitchSaveProblem.cloudPull
        }
        let backup = newBackup(beforeImport, in: documents, at: now)
        let kept = try swap(staged, into: documents, keeping: backup, now: now)
        prune(beforeImport, in: documents, sparing: backup)
        return kept ? backup : nil
    }

    /// Puts BACKUP, one of Cartouche's, back in place of the folders it
    /// holds, dated NOW: those it replaces are kept first in
    /// save-backups/<date> before putting back, and BACKUP goes.
    static func putBack(_ backup: URL, in documents: URL, now: Date = Date()) throws {
        guard !FileManager.default.fileExists(atPath: documents.appendingPathComponent(pullJournal).path) else {
            throw CartoucheSwitchSaveProblem.cloudPull
        }
        let kept = newBackup(beforePutBack, in: documents, at: now)
        try swap(backup, into: documents, keeping: kept, now: now)
        try? FileManager.default.removeItem(at: backup)
        prune(beforePutBack, in: documents, sparing: kept)
    }

    /// Puts the save folders in INCOMING, save and save_device, in place of
    /// the game's in DOCUMENTS, dated NOW: those there move to KEPT first, a
    /// folder of their own, and come back if a step fails, as the folders
    /// already moved go back to INCOMING. What nxnative left of its working
    /// copies of those it replaced, <folder>.work and <folder>.new, goes
    /// then, for the game to make them again from the save that came, as
    /// Cartouche's sync does (CartoucheSaveSync.replaceSaves): nxnative
    /// discards them at its next start, a build of before that too. Whether
    /// any was kept.
    @discardableResult
    static func swap(_ incoming: URL, into documents: URL, keeping kept: URL, now: Date) throws -> Bool {
        let fileManager = FileManager.default
        let folders = [saveFolder, deviceFolder].filter { isFolder(incoming.appendingPathComponent($0)) }
        guard !folders.isEmpty else { throw CartoucheSwitchSaveProblem.empty }
        for folder in folders {
            try date(incoming.appendingPathComponent(folder, isDirectory: true), at: now)
        }
        try fileManager.createDirectory(at: documents, withIntermediateDirectories: true)
        var moved: [String] = []
        var placed: [String] = []
        do {
            for folder in folders {
                let here = documents.appendingPathComponent(folder, isDirectory: true)
                if (try? fileManager.attributesOfItem(atPath: here.path)) != nil {
                    if moved.isEmpty { try fileManager.createDirectory(at: kept, withIntermediateDirectories: true) }
                    try fileManager.moveItem(at: here, to: kept.appendingPathComponent(folder, isDirectory: true))
                    moved.append(folder)
                }
                try fileManager.moveItem(at: incoming.appendingPathComponent(folder, isDirectory: true), to: here)
                placed.append(folder)
            }
        } catch {
            // The saves as they were.
            for folder in placed.reversed() {
                try? fileManager.moveItem(at: documents.appendingPathComponent(folder, isDirectory: true),
                                          to: incoming.appendingPathComponent(folder, isDirectory: true))
            }
            for folder in moved.reversed() {
                try? fileManager.moveItem(at: kept.appendingPathComponent(folder, isDirectory: true),
                                          to: documents.appendingPathComponent(folder, isDirectory: true))
            }
            if moved.isEmpty || (try? fileManager.contentsOfDirectory(atPath: kept.path))?.isEmpty == true {
                try? fileManager.removeItem(at: kept)
            }
            throw error
        }
        for folder in placed {
            for leftover in [folder + workSuffix, folder + newSuffix] {
                try? fileManager.removeItem(at: documents.appendingPathComponent(leftover, isDirectory: true))
            }
        }
        return !moved.isEmpty
    }

    /// Dates FOLDER, its files and folders, at NOW.
    static func date(_ folder: URL, at now: Date) throws {
        let fileManager = FileManager.default
        var paths: [String] = []
        if let walker = fileManager.enumerator(atPath: folder.path) {
            while let relative = walker.nextObject() as? String {
                paths.append(relative)
            }
        }
        // The deepest first: a folder's date is set once its files are.
        for relative in paths.sorted(by: >) {
            try fileManager.setAttributes([.modificationDate: now], ofItemAtPath: folder.appendingPathComponent(relative).path)
        }
        try fileManager.setAttributes([.modificationDate: now], ofItemAtPath: folder.path)
    }

    // MARK: Sending it to the Switch

    /// The attribute in which nxnative keeps the name the game gave a file
    /// it named .dm-case-N on the iPhone, whose names ignore capitals
    /// (hle_fs.c, guest_name).
    static let guestNameAttribute = "org.d2rmobile.guest-name"

    /// The files and folders of SAVE, a game's Documents/save, as they go in
    /// an archive for the Switch, parents first: by the names the game gave
    /// them, GUESTNAME's for those nxnative named .dm-case-N; links, which
    /// no save has, left out.
    static func entries(ofSave save: URL, guestName: (URL) -> String? = guestName(of:)) throws -> [CartoucheSwitchSaveEntry] {
        let fileManager = FileManager.default
        guard let walker = fileManager.enumerator(atPath: save.path) else {
            throw CocoaError(.fileReadNoSuchFile, userInfo: [NSFilePathErrorKey: save.path])
        }
        var relatives: [String] = []
        while let relative = walker.nextObject() as? String {
            relatives.append(relative)
        }
        var entries: [CartoucheSwitchSaveEntry] = []
        for relative in relatives.sorted() {
            let url = save.appendingPathComponent(relative)
            let attributes = try fileManager.attributesOfItem(atPath: url.path)
            let type = attributes[.type] as? FileAttributeType
            guard type == .typeDirectory || type == .typeRegular else { continue }
            var parts: [String] = []
            var path = save
            for part in relative.split(separator: "/") {
                path = path.appendingPathComponent(String(part))
                parts.append(part.hasPrefix(".dm-case-") ? guestName(path) ?? String(part) : String(part))
            }
            entries.append(CartoucheSwitchSaveEntry(name: parts.joined(separator: "/"), url: url, isFolder: type == .typeDirectory,
                                                    date: attributes[.modificationDate] as? Date ?? Date()))
        }
        return entries
    }

    /// The name the game gave the file at URL, which nxnative named
    /// .dm-case-N; nil when it kept none.
    static func guestName(of url: URL) -> String? {
        #if canImport(Darwin)
        let size = getxattr(url.path, guestNameAttribute, nil, 0, 0, XATTR_NOFOLLOW)
        guard size > 0 else { return nil }
        var bytes = [UInt8](repeating: 0, count: size)
        guard getxattr(url.path, guestNameAttribute, &bytes, size, 0, XATTR_NOFOLLOW) == size else { return nil }
        return String(decoding: bytes, as: UTF8.self)
        #else
        return nil
        #endif
    }

    /// The name of the archive a game's save goes to the Switch in, made
    /// at DATE, as JKSV names its own, "<user> - <date>.zip", in local time
    /// (stringutil.cpp, get_date_string).
    static func archiveName(at date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        return "Cartouche - " + formatter.string(from: date) + ".zip"
    }

    // MARK: Backups

    /// Made for each use: a formatter is not for several threads at once.
    private static func backupFormat() -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
        return formatter
    }

    /// A folder for saves about to be replaced, in DOCUMENTS:
    /// save-backups/<date> <side>, in local time, as nxnative names its own
    /// (save_sync.c, backup_dir), with " 2", " 3"... after it when that name
    /// is taken. Not made yet.
    static func newBackup(_ side: String, in documents: URL, at date: Date) -> URL {
        let backups = documents.appendingPathComponent(backupsFolder, isDirectory: true)
        let name = backupFormat().string(from: date) + " " + side
        var folder = backups.appendingPathComponent(name, isDirectory: true)
        var count = 2
        while FileManager.default.fileExists(atPath: folder.path) {
            folder = backups.appendingPathComponent(name + " \(count)", isDirectory: true)
            count += 1
        }
        return folder
    }

    /// The date of a backup of SIDE named NAME, nil for any other name.
    static func date(ofBackup name: String, side: String) -> Date? {
        let stamp = "0000-00-00 00.00.00"
        guard name.count > stamp.count + 1 else { return nil }
        let rest = name.dropFirst(stamp.count + 1)
        guard name.dropFirst(stamp.count).hasPrefix(" "), rest.hasPrefix(side) else { return nil }
        let after = rest.dropFirst(side.count)
        guard after.isEmpty || (after.hasPrefix(" ") && after.count > 1 && after.dropFirst().allSatisfy(\.isNumber)) else {
            return nil
        }
        return backupFormat().date(from: String(name.prefix(stamp.count)))
    }

    /// Cartouche's backups of SIDE in DOCUMENTS, the newest first.
    static func backups(_ side: String, in documents: URL) -> [CartoucheSwitchSaveBackup] {
        let backups = documents.appendingPathComponent(backupsFolder, isDirectory: true)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: backups.path)) ?? []
        return names.sorted(by: >).compactMap { name in
            date(ofBackup: name, side: side).map {
                CartoucheSwitchSaveBackup(folder: backups.appendingPathComponent(name, isDirectory: true), date: $0)
            }
        }
    }

    /// Removes Cartouche's backups of SIDE beyond the newest ones, but for
    /// SPARING, made just now whatever its date says.
    static func prune(_ side: String, in documents: URL, sparing: URL?) {
        let others = backups(side, in: documents).filter { $0.folder.lastPathComponent != sparing?.lastPathComponent }
        for backup in others.dropFirst(kept - 1) {
            try? FileManager.default.removeItem(at: backup.folder)
        }
    }
}
