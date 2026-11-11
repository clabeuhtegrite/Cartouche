//
//  CartoucheStorageSaves.swift
//  Cartouche
//
//  A game's saves kept in step with its folder in the player's saves
//  folder, on a server Cartouche signed in to: the steps CartoucheSaveSync
//  decides, taken there. CartoucheSaveBackups takes them for each game,
//  after a game, when a game is installed and before it starts; the storage
//  tests take them against real servers (launcher/StorageTests).
//
//  The game's folder holds its copies, "<game> [<title ID>]/<date>.zip",
//  and the newest ones only: after each copy that goes there, the oldest
//  beyond ten go, but for the copy just made, whatever its date, as
//  nxnative keeps the backup it just made. What another copy left half
//  written goes once it is an hour old, since another iPhone may still be
//  writing it.
//

import Foundation

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

/// What a sync did with a game's saves.
struct CartoucheSaveOutcome {
    var step: CartoucheSaveStep
    /// What is the same here and in the folder now, as far as this iPhone
    /// knows.
    var base: CartoucheSaveBase?
    /// The copy the saves here went to, as the newest one.
    var sent: String?
    /// The copy the saves here went to under a newer one, kept.
    var kept: String?
    /// The copy that came here.
    var fetched: String?
}

/// The player's saves folder on a server signed in to, for a round of
/// syncs: one game after another.
final class CartoucheSavesFolder {
    let remote: CartoucheRemote
    /// The saves folder's path on the server.
    let path: String
    /// "<server ID>|<path>", the folder a base holds for.
    let place: String
    /// A folder of this iPhone's for the copies that come, unpacked there
    /// first.
    let scratch: URL
    /// The games' folders in the saves folder, listed once.
    private var gameFolders: Set<String>?

    init(remote: CartoucheRemote, path: String, place: String, scratch: URL) {
        self.remote = remote
        self.path = path
        self.place = place
        self.scratch = scratch
    }

    /// The folder of a game's copies: "<game> [<title ID>]".
    static func folderName(_ target: CartoucheSaveTarget) -> String {
        var name = CartoucheStoragePath.fileName(target.name)
        if let titleId = target.titleId { name += " [\(titleId.uppercased())]" }
        return name
    }

    private func gameFolder(of target: CartoucheSaveTarget) -> String {
        CartoucheStoragePath.join(path, Self.folderName(target))
    }

    // MARK: Syncing

    /// Keeps TARGET's saves in step with the folder, from BASE, the last time
    /// both were the same (CartoucheSaveSync.step). FETCHING lets the newest
    /// copy come here, when the game is installed or about to start.
    func sync(_ target: CartoucheSaveTarget, base given: CartoucheSaveBase?, fetching: Bool) async throws -> CartoucheSaveOutcome {
        let base = given?.place == place ? given : nil
        let folder = gameFolder(of: target)
        let names = try await copyNames(in: folder)
        var here = CartoucheSaveSync.saves(in: target.documents)
        var newest = names.last.flatMap { name in
            CartoucheSaveSync.date(inName: name).map { CartoucheSaveCopy(name: name, date: $0) }
        }
        // What the base says of either side, read already.
        if let base, let content = base.content {
            if here?.look == base.look { here?.content = content }
            if newest?.name == base.copy { newest?.content = content }
        }
        let baseIsThere = base.map { names.contains($0.copy) } ?? false
        var step = CartoucheSaveSync.step(here: here, newest: newest, base: base, baseIsThere: baseIsThere, fetching: fetching)
        if step == .compare {
            if here != nil, here?.content == nil {
                here?.content = try CartoucheSaveSync.content(ofSavesIn: target.documents)
            }
            if let copy = newest, copy.content == nil {
                let directory = try await entries(of: CartoucheStoragePath.join(folder, copy.name))
                newest?.content = CartoucheSaveSync.content(of: directory)
            }
            step = CartoucheSaveSync.step(here: here, newest: newest, base: base, baseIsThere: baseIsThere, fetching: fetching)
        }

        var outcome = CartoucheSaveOutcome(step: step, base: base)
        switch step {
        case .none, .compare:
            // Saves written again as they were: the base takes their look,
            // not to read them again next time.
            if let here, var same = base, here.look != same.look, here.content != nil, here.content == same.content {
                same.look = here.look
                outcome.base = same
            }
        case .same:
            if let here, let newest {
                outcome.base = CartoucheSaveBase(place: place, copy: newest.name, content: here.content ?? newest.content,
                                                 look: here.look)
            }
        case .send:
            if let here {
                let name = CartoucheSaveSync.sendName(written: here.written, after: newest?.date)
                outcome.base = try await send(target, here, as: name, to: folder)
                outcome.sent = name
            }
        case .keep:
            if let here {
                let (name, kept) = try await keep(target, here, under: newest, in: folder, names: names)
                outcome.base = kept
                outcome.kept = name
            }
        case .fetch, .keepAndFetch:
            guard let newest else { break }
            if step == .keepAndFetch, let here {
                outcome.kept = try await keep(target, here, under: newest, in: folder, names: names).name
            }
            outcome.base = try await fetch(newest, of: target, from: folder)
            outcome.fetched = newest.name
        }
        return outcome
    }

    /// Puts the copy NAME back as TARGET's saves, as the player chose it: the
    /// saves here go to the folder first, unless it has them already, and
    /// the copy put back then goes there as the newest one, which the
    /// player's other iPhones take at their next start, rather than the one
    /// that was the newest.
    func putBack(_ name: String, of target: CartoucheSaveTarget, base given: CartoucheSaveBase?) async throws -> CartoucheSaveOutcome {
        let base = given?.place == place ? given : nil
        let folder = gameFolder(of: target)
        var names = try await copyNames(in: folder)
        guard names.contains(name), let date = CartoucheSaveSync.date(inName: name) else {
            throw CartoucheStorageError(.copyUnreadable, CartoucheText.savesCopyUnreadable)
        }
        var outcome = CartoucheSaveOutcome(step: .fetch, base: base)
        if let here = CartoucheSaveSync.saves(in: target.documents),
           !(base.map { $0.look == here.look && names.contains($0.copy) } ?? false) {
            let sent = CartoucheSaveSync.sendName(written: here.written, after: names.last.flatMap(CartoucheSaveSync.date(inName:)))
            // The copy to put back stays, even the oldest one.
            _ = try await send(target, here, as: sent, to: folder, sparing: name)
            names = try await copyNames(in: folder)
            outcome.kept = sent
        }
        let fetched = try await fetch(CartoucheSaveCopy(name: name, date: date), of: target, from: folder)
        outcome.fetched = name
        outcome.base = fetched
        // The newest one already, or a copy of no save.
        guard name != names.last, let here = CartoucheSaveSync.saves(in: target.documents) else { return outcome }
        var put = here
        put.content = fetched.content
        let newest = CartoucheSaveSync.sendName(written: here.written, after: names.last.flatMap(CartoucheSaveSync.date(inName:)))
        outcome.base = try await send(target, put, as: newest, to: folder)
        outcome.sent = newest
        return outcome
    }

    /// TARGET's copies, the newest first.
    func copies(of target: CartoucheSaveTarget) async throws -> [CartoucheSaveBackup] {
        let folder = gameFolder(of: target)
        guard try await hasFolder(folder) else { return [] }
        return try await remote.list(folder).compactMap { item in
            guard !item.isFolder, let date = CartoucheSaveSync.date(inName: item.name) else { return nil }
            return CartoucheSaveBackup(path: CartoucheStoragePath.join(folder, item.name), date: date, size: item.size)
        }
        .sorted { $0.date > $1.date }
    }

    // MARK: Steps

    /// The names of the game's copies in FOLDER, the oldest first; none when
    /// the game has no folder yet.
    private func copyNames(in folder: String) async throws -> [String] {
        guard try await hasFolder(folder) else { return [] }
        return try await remote.list(folder).filter { !$0.isFolder && CartoucheSaveSync.date(inName: $0.name) != nil }
            .map(\.name).sorted()
    }

    /// Whether the game's FOLDER is there: a game never copied has none, and
    /// some servers refuse to list a folder that is not.
    private func hasFolder(_ folder: String) async throws -> Bool {
        if gameFolders == nil {
            let items = try await remote.list(path)
            gameFolders = Set(items.filter(\.isFolder).map(\.name))
        }
        return gameFolders?.contains(CartoucheStoragePath.name(folder)) == true
    }

    /// The zip's entries of the copy at PATH, read from its end, without the
    /// rest of it.
    private func entries(of path: String) async throws -> [CartoucheZipEntry] {
        let source = try await remote.open(path)
        return try await CartoucheZip.entries(of: source)
    }

    /// Writes the saves HERE to NAME in FOLDER, then removes the copies past
    /// the newest ones, but for this one and SPARING; the base it makes.
    private func send(_ target: CartoucheSaveTarget, _ here: CartoucheLocalSaves, as name: String,
                      to folder: String, sparing: String? = nil) async throws -> CartoucheSaveBase {
        let content = try here.content ?? CartoucheSaveSync.content(ofSavesIn: target.documents)
        let hasIt = try await hasFolder(folder)
        if !hasIt {
            try await remote.makeFolders(folder)
            gameFolders?.insert(CartoucheStoragePath.name(folder))
        }
        let upload = try await remote.create(CartoucheStoragePath.join(folder, name), size: nil)
        do {
            try await CartoucheSaveSync.writeZip(ofSavesIn: target.documents, to: upload)
            try await upload.finish()
        } catch {
            await upload.cancel()
            throw error
        }
        do {
            try await prune(folder, made: name, sparing: sparing)
        } catch {
            NSLog("[Cartouche] cannot remove old copies of %@: %@", target.name, error.localizedDescription)
        }
        return CartoucheSaveBase(place: place, copy: name, content: content, look: here.look)
    }

    /// Keeps the saves HERE in FOLDER as a copy of their own date, under
    /// NEWEST, the newer one there: the name it has, and the base it makes.
    /// A copy of that name there already is left as it is when it holds the
    /// same saves; else the copy takes the second before.
    private func keep(_ target: CartoucheSaveTarget, _ here: CartoucheLocalSaves, under newest: CartoucheSaveCopy?,
                      in folder: String, names: [String]) async throws -> (name: String, base: CartoucheSaveBase) {
        var saves = here
        let content = try here.content ?? CartoucheSaveSync.content(ofSavesIn: target.documents)
        saves.content = content
        var name = CartoucheSaveSync.keepName(written: here.written, under: newest?.date)
        var date = CartoucheSaveSync.date(inName: name) ?? here.written
        while names.contains(name) {
            let directory = try await entries(of: CartoucheStoragePath.join(folder, name))
            if CartoucheSaveSync.content(of: directory) == content {
                return (name, CartoucheSaveBase(place: place, copy: name, content: content, look: here.look))
            }
            date = date.addingTimeInterval(-1)
            name = CartoucheSaveSync.fileName(date)
        }
        let base = try await send(target, saves, as: name, to: folder)
        return (name, base)
    }

    /// Brings COPY here in place of TARGET's saves, once it has come whole
    /// and reads as a copy of saves; the base it makes.
    private func fetch(_ copy: CartoucheSaveCopy, of target: CartoucheSaveTarget,
                       from folder: String) async throws -> CartoucheSaveBase {
        let fileManager = FileManager.default
        let work = scratch.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: work) }
        let local = work.appendingPathComponent("copy.zip")
        let source = try await remote.open(CartoucheStoragePath.join(folder, copy.name))
        let sink = try CartoucheFileSink(local)
        var offset: UInt64 = 0
        while offset < source.size {
            let part = try await source.read(at: offset, count: Int(min(source.size - offset, 8 << 20)))
            guard !part.isEmpty else { throw CartoucheStorageError(.copyUnreadable, CartoucheText.savesCopyUnreadable) }
            try await sink.write(part)
            offset += UInt64(part.count)
        }
        try sink.close()

        // Every file of the copy, checked, before the saves here change.
        let file = try CartoucheFileSource(local)
        let entries = try await CartoucheZip.entries(of: file)
        guard CartoucheSaveSync.holdsSavesOnly(entries) else {
            throw CartoucheStorageError(.copyUnreadable, CartoucheText.savesCopyUnreadable)
        }
        let unpacked = work.appendingPathComponent("unpacked", isDirectory: true)
        try await CartoucheZip.extract(file, entries: entries, into: unpacked, progress: nil)
        try CartoucheSaveSync.replaceSaves(in: target.documents, with: unpacked,
                                           aside: work.appendingPathComponent("replaced", isDirectory: true))
        return CartoucheSaveBase(place: place, copy: copy.name, content: CartoucheSaveSync.content(of: entries),
                                 look: CartoucheSaveSync.saves(in: target.documents)?.look ?? "")
    }

    /// Keeps the newest copies in FOLDER, MADE among them whatever its date,
    /// and SPARING too, and removes what a copy given up left over an hour
    /// ago.
    private func prune(_ folder: String, made: String, sparing: String?) async throws {
        let items = try await remote.list(folder).filter { !$0.isFolder }
        let stale = Date().addingTimeInterval(-3600)
        for item in items where item.name.hasSuffix(".partial") && (item.modified ?? .distantPast) < stale {
            try await remote.delete(CartoucheStoragePath.join(folder, item.name))
        }
        let others = items.map(\.name).filter { $0 != made && CartoucheSaveSync.date(inName: $0) != nil }.sorted(by: >)
        for name in others.dropFirst(CartoucheSaveSync.kept - 1) where name != sparing {
            try await remote.delete(CartoucheStoragePath.join(folder, name))
        }
    }
}
