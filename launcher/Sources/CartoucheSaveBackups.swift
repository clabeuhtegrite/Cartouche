//
//  CartoucheSaveBackups.swift
//  Cartouche
//
//  The games' saves kept in step with the player's saves folder, where each
//  game has a folder of its copies, the way nxnative keeps a game's save in
//  step with a cloud folder (CartoucheSaveSync, CartoucheStorageSaves):
//
//  - When a game is installed, and before it starts, the newest copy comes,
//    when the game has no saves on this iPhone, as after Cartouche was
//    installed again, or when the copy is newer than theirs, as when
//    another iPhone played the game since. A server offline from here is
//    left alone: the game plays with the saves it has.
//  - After a game, the saves that changed go: when a game behind the
//    console ends and, since a game in Cartouche's place is Cartouche
//    itself while it plays, when Cartouche opens again after a game and
//    whenever it comes back to the front, but for the game that runs. Play
//    waits for the syncs under way.
//  - When both changed, the saves written last win, and the others are kept
//    as a copy of their own date: the game's sheet says what came and what
//    was kept. The ten newest copies stay.
//  - A copy can be put back from the game's sheet: the saves it replaces go
//    to the saves folder first, and the copy put back becomes the newest
//    one there, which the player's other iPhones take at their next start.
//
//  Away from the saves folder's server, as from a NAS at home, the saves
//  wait: Cartouche finds the server offline within a few seconds
//  (CartoucheStorageReach), leaves it alone while it stays so, and sends the
//  saves waiting as soon as it answers again. Being offline is not a
//  problem: no report is made of it.
//

import Combine
import Foundation
import UIKit

/// What a sync did to a game's saves that the player should know.
struct CartoucheSaveNews: Codable, Hashable {
    /// The date of the copy that came here.
    var fetched: Date?
    /// The date of the copy the saves here were kept as, under a newer one.
    var kept: Date?
}

@MainActor
final class CartoucheSaveBackups: ObservableObject {
    static let shared = CartoucheSaveBackups()
    /// The copies kept for each game.
    nonisolated static let kept = CartoucheSaveSync.kept

    /// Whether the saves are being synced.
    @Published private(set) var isSyncing = false
    /// When each game's saves were last synced, by target key.
    @Published private(set) var lastSync: [String: Date]
    /// What the last syncs did that the player should know, by target key.
    @Published private(set) var news: [String: CartoucheSaveNews]
    /// Why the last sync failed, if it did, and the report on it.
    @Published private(set) var problemReport: CartoucheReport?
    /// The games whose saves wait for the saves folder's server, offline
    /// from here, by target key: they go once it answers again.
    @Published private(set) var waiting: Set<String> = []

    private let settings: CartoucheStorageSettings
    private let defaults: UserDefaults
    /// What was last the same here and in the saves folder, for each game
    /// (CartoucheSaveSync), by target key.
    private var bases: [String: CartoucheSaveBase]
    private var run: Task<Void, Never>?
    private var background = UIBackgroundTaskIdentifier.invalid
    private static let basesKey = "Cartouche.saves.bases"
    private static let syncedKey = "Cartouche.saves.synced"
    private static let newsKey = "Cartouche.saves.news"
    /// What Cartouche kept before it synced the saves: how each game's saves
    /// looked at their last copy, "<server ID>|<path>|<look>", and the date
    /// that named the copy.
    private static let fingerprintsKey = "Cartouche.saves.fingerprints"
    private static let lastKey = "Cartouche.saves.last"

    init(settings: CartoucheStorageSettings = .shared, defaults: UserDefaults = .standard) {
        self.settings = settings
        self.defaults = defaults
        let decoder = JSONDecoder()
        bases = defaults.data(forKey: Self.basesKey).flatMap { try? decoder.decode([String: CartoucheSaveBase].self, from: $0) } ?? [:]
        news = defaults.data(forKey: Self.newsKey).flatMap { try? decoder.decode([String: CartoucheSaveNews].self, from: $0) } ?? [:]
        let synced = (defaults.dictionary(forKey: Self.syncedKey) as? [String: Date]) ?? [:]
        let copied = (defaults.dictionary(forKey: Self.lastKey) as? [String: Date]) ?? [:]
        lastSync = synced.merging(copied) { synced, _ in synced }
    }

    /// Whether the player chose a saves folder.
    var isOn: Bool { settings.location(.saves) != nil }

    /// After a game: sends the saves of the TARGETS that changed since they
    /// were last in step with the saves folder, unless syncs are under way.
    /// What the folder has new for the others comes at their next start.
    func copyChanged(_ targets: [CartoucheSaveTarget]) {
        guard run == nil, isOn, !targets.isEmpty else { return }
        run = Task {
            _ = await syncRound(targets, fetching: false, onlyChanged: true, byPlayer: false)
            run = nil
        }
    }

    /// Syncs TARGET's saves with the saves folder, the newest copy coming
    /// here when it is the one to keep: when the game is installed and
    /// before it starts. A server known to be offline from here is left
    /// alone. What the sync did, unless it did not go through.
    @discardableResult
    func sync(_ target: CartoucheSaveTarget) async -> CartoucheSaveOutcome? {
        await turn { await self.syncRound([target], fetching: true, onlyChanged: false, byPlayer: false).outcomes[target.key] }
    }

    /// Syncs TARGET's saves now, as the player asked: whether it went
    /// through.
    func syncNow(_ target: CartoucheSaveTarget) async -> Bool {
        await turn { await self.syncRound([target], fetching: true, onlyChanged: false, byPlayer: true).failure == nil }
    }

    #if CARTOUCHE_GALLERY
    /// COUNT games whose saves wait for the server, for the launcher's
    /// gallery (launcher/Gallery).
    func showWaitingForGallery(_ count: Int) {
        waiting = Set((0 ..< count).map { "gallery-\($0)" })
    }
    #endif

    /// Waits for the syncs under way: before a game starts, which closes
    /// Cartouche.
    func finish() async {
        while let run {
            await run.value
            if self.run == run { break }
        }
    }

    /// Runs WORK once the syncs under way have ended, as the one under way:
    /// one round at a time, as each signs in to the server and may write a
    /// game's folder.
    private func turn<T: Sendable>(_ work: @escaping @MainActor () async -> T) async -> T {
        // The one under way, then any that began while it ended.
        while let current = run {
            await current.value
            if run == current { run = nil }
        }
        let task = Task { @MainActor in await work() }
        let marker = Task { @MainActor in _ = await task.value }
        run = marker
        let value = await task.value
        if run == marker { run = nil }
        return value
    }

    // MARK: Syncing

    /// What a round of syncs did, game by game, and why it stopped, if it
    /// did.
    private struct Round {
        var outcomes: [String: CartoucheSaveOutcome] = [:]
        var failure: Error?
    }

    /// Syncs the TARGETS with the saves folder, one game after another: all
    /// of them, or, ONLYCHANGED, after a game, those whose saves changed
    /// since they were last in step. FETCHING lets the newest copy come
    /// here. BYPLAYER: the player asked, and a server found offline is tried
    /// again.
    private func syncRound(_ targets: [CartoucheSaveTarget], fetching: Bool, onlyChanged: Bool, byPlayer: Bool) async -> Round {
        var result = Round()
        guard let location = settings.location(.saves) else {
            result.failure = CartoucheStorageError(.noSavesFolder, CartoucheText.savesNoFolder)
            return result
        }
        let place = Self.place(location)
        var due: [(target: CartoucheSaveTarget, base: CartoucheSaveBase?)] = []
        for target in targets {
            let base = savedBase(of: target, place: place)
            if onlyChanged {
                // A game that never saved, or whose saves did not change
                // since they were last in step, has nothing to send.
                guard let look = await Self.look(of: target.documents), look != base?.look else {
                    waiting.remove(target.key)
                    continue
                }
            }
            due.append((target, base))
        }
        guard !due.isEmpty else { return result }
        // The server was found offline from here: the saves to send wait for
        // it, rather than for the patience each time Cartouche comes back,
        // and a game starts with the saves it has.
        let reach = CartoucheStorageReach.shared
        if !byPlayer && (onlyChanged ? reach.isSettledOffline(location.server.id) : reach.isOffline(location.server.id)) {
            if onlyChanged { wait(for: due.map { $0.target }) }
            result.failure = CartoucheStorageOffline(location.server)
            return result
        }

        isSyncing = true
        beginBackground()
        defer {
            isSyncing = false
            endBackground()
        }
        var remote: CartoucheRemote?
        do {
            let connected = try await CartoucheStorage.connect(location.server, settings: settings)
            remote = connected
            if await settings.checkAccess(connected, server: location.server.id, path: location.path) == false {
                throw CartoucheStorageError(.readOnly, CartoucheText.savesReadOnly)
            }
            let folder = CartoucheSavesFolder(remote: connected, path: location.path, place: place, scratch: Self.scratch)
            // One game that fails leaves the others to go.
            var failed: Error?
            for (target, base) in due {
                do {
                    let outcome = try await folder.sync(target, base: base, fetching: fetching)
                    record(outcome, of: target)
                    result.outcomes[target.key] = outcome
                } catch let offline as CartoucheStorageOffline {
                    throw offline
                } catch {
                    NSLog("[Cartouche] saves of %@ not synced: %@", target.name, error.localizedDescription)
                    failed = failed ?? error
                }
            }
            if let failed { throw failed }
            problemReport = nil
        } catch let offline as CartoucheStorageOffline {
            // No problem: the saves wait for the server to answer again.
            if onlyChanged { wait(for: due.map { $0.target }.filter { result.outcomes[$0.key] == nil }) }
            result.failure = offline
        } catch {
            // The syncs Cartouche makes by itself, each time it comes back,
            // can fail on the way too: their report is not kept.
            problemReport = CartoucheReports.make(.saves, CartoucheText.savesCopyFailed, message: error.localizedDescription,
                                                  error: error, step: "Syncing the saves with " + CartoucheReports.place(.saves),
                                                  stage: "savesSync",
                                                  facts: [.init("Games", String(due.count))], inBackground: !byPlayer)
            NSLog("[Cartouche] saves not synced: %@", error.localizedDescription)
            result.failure = error
        }
        note(result.outcomes, of: due.map { $0.target })
        await remote?.disconnect()
        return result
    }

    /// The base of TARGET's saves for the saves folder at PLACE: the one
    /// Cartouche keeps, or, for saves an older Cartouche copied, the copy it
    /// made last, by its date, and how the saves looked then. None for
    /// another folder than the one the base was for: the saves go to the
    /// new one.
    private func savedBase(of target: CartoucheSaveTarget, place: String) -> CartoucheSaveBase? {
        if let base = bases[target.key] { return base.place == place ? base : nil }
        let fingerprints = (defaults.dictionary(forKey: Self.fingerprintsKey) as? [String: String]) ?? [:]
        let copied = (defaults.dictionary(forKey: Self.lastKey) as? [String: Date]) ?? [:]
        guard let stamp = fingerprints[target.key], stamp.hasPrefix(place + "|"), let date = copied[target.key] else { return nil }
        return CartoucheSaveBase(place: place, copy: CartoucheSaveSync.fileName(date), content: nil,
                                 look: String(stamp.dropFirst(place.count + 1)))
    }

    /// Keeps what a sync of TARGET's saves did.
    private func record(_ outcome: CartoucheSaveOutcome, of target: CartoucheSaveTarget) {
        waiting.remove(target.key)
        if let base = outcome.base, base != bases[target.key] {
            bases[target.key] = base
            defaults.set(try? JSONEncoder().encode(bases), forKey: Self.basesKey)
        }
        lastSync[target.key] = Date()
        defaults.set(lastSync, forKey: Self.syncedKey)
        let fetched = outcome.fetched.flatMap(CartoucheSaveSync.date(inName:))
        let kept = outcome.kept.flatMap(CartoucheSaveSync.date(inName:))
        if fetched != nil || kept != nil {
            news[target.key] = CartoucheSaveNews(fetched: fetched, kept: kept)
        } else if outcome.sent != nil {
            // Played since: what came before is old news.
            news[target.key] = nil
        } else {
            return
        }
        defaults.set(try? JSONEncoder().encode(news), forKey: Self.newsKey)
    }

    /// The journal's lines on a round: the saves sent, those that came, and
    /// those kept under newer ones.
    private func note(_ outcomes: [String: CartoucheSaveOutcome], of targets: [CartoucheSaveTarget]) {
        let sent = targets.filter { outcomes[$0.key]?.sent != nil }.count
        if sent > 0 {
            CartoucheReports.note("Saves sent to the saves folder: \(sent) " + (sent == 1 ? "game" : "games"))
        }
        for target in targets {
            guard let outcome = outcomes[target.key] else { continue }
            var line: String
            if let fetched = outcome.fetched {
                line = "Saves of \(target.name) came from the saves folder, the copy \(fetched)"
                if let kept = outcome.kept {
                    line += "; this iPhone's kept there as \(kept)"
                }
            } else if let kept = outcome.kept {
                line = "Saves of \(target.name): newer ones in the saves folder, for the next start; "
                line += "this iPhone's kept there as \(kept)"
            } else {
                continue
            }
            CartoucheReports.note(line)
        }
    }

    /// The saves of TARGETS wait for the saves folder's server, offline
    /// from here.
    private func wait(for targets: [CartoucheSaveTarget]) {
        problemReport = nil
        let added = Set(targets.map { $0.key }).subtracting(waiting)
        guard !added.isEmpty else { return }
        waiting.formUnion(added)
        CartoucheReports.note("Saves waiting for the saves folder: \(waiting.count) " + (waiting.count == 1 ? "game" : "games"))
    }

    /// The saves folder, as a base names it: "<server ID>|<path>".
    private static func place(_ location: (server: CartoucheStorageServer, path: String)) -> String {
        location.server.id.uuidString + "|" + location.path
    }

    /// Where the copies that come are unpacked, before they replace a
    /// game's saves.
    private static var scratch: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("CartoucheSaves", isDirectory: true)
    }

    /// How the saves in DOCUMENTS look, read off the main thread.
    nonisolated private static func look(of documents: URL) async -> String? {
        CartoucheSaveSync.saves(in: documents)?.look
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

    // MARK: Listing and putting back

    /// TARGET's copies in the saves folder, the newest first.
    func copies(of target: CartoucheSaveTarget) async throws -> [CartoucheSaveBackup] {
        guard let location = settings.location(.saves) else { return [] }
        let remote = try await CartoucheStorage.connect(location.server, settings: settings)
        let folder = CartoucheSavesFolder(remote: remote, path: location.path, place: Self.place(location), scratch: Self.scratch)
        do {
            let copies = try await folder.copies(of: target)
            await remote.disconnect()
            return copies
        } catch {
            await remote.disconnect()
            throw error
        }
    }

    /// Puts BACKUP back as TARGET's saves, as the player chose it. The saves
    /// it replaces go to the saves folder first; nothing changes on the
    /// iPhone unless the backup reads whole. The copy put back then becomes
    /// the newest one, which the player's other iPhones take at their next
    /// start.
    func restore(_ backup: CartoucheSaveBackup, of target: CartoucheSaveTarget) async throws {
        let failure: Error? = await turn {
            do {
                try await self.putBack(backup, of: target)
                return nil
            } catch {
                return error
            }
        }
        if let failure { throw failure }
    }

    // MARK: A save from the Switch

    /// Puts the save from the player's Switch that STAGED holds
    /// (CartoucheSwitchSave.stage) in place of TARGET's, once the syncs under
    /// way have ended, none starting meanwhile: the saves it replaces are
    /// kept on this iPhone first. It then goes to the saves folder as the
    /// newest copy, if the player chose one: now, or once its server answers
    /// again. RUNNING: whether the game runs now, which its turn asks
    /// first, as the player may have started it since the question; nothing
    /// changes then. The backup of the saves it replaced, nil when there
    /// were none.
    func bringIn(_ staged: URL, of target: CartoucheSaveTarget, running: @escaping @MainActor () -> Bool) async throws -> URL? {
        let documents = target.documents
        let result: Result<URL?, Error> = await turn {
            if running() { return .failure(CartoucheSwitchSaveProblem.running) }
            return await Task.detached(priority: .userInitiated) {
                Result { try CartoucheSwitchSave.place(staged, in: documents) }
            }.value
        }
        let backup = try result.get()
        news[target.key] = nil
        defaults.set(try? JSONEncoder().encode(news), forKey: Self.newsKey)
        sendChanged(target)
        return backup
    }

    /// Puts BACKUP, the saves an import replaced, back in place of TARGET's,
    /// as the player asked, the same way: what it replaces is kept on this
    /// iPhone, and it goes to the saves folder; nothing changes while the
    /// game runs (RUNNING).
    func putBack(beforeImport backup: CartoucheSwitchSaveBackup, of target: CartoucheSaveTarget,
                 running: @escaping @MainActor () -> Bool) async throws {
        let documents = target.documents
        let folder = backup.folder
        let result: Result<Void, Error> = await turn {
            if running() { return .failure(CartoucheSwitchSaveProblem.running) }
            return await Task.detached(priority: .userInitiated) {
                Result { try CartoucheSwitchSave.putBack(folder, in: documents) }
            }.value
        }
        try result.get()
        sendChanged(target)
    }

    /// Sends TARGET's saves, which the player changed on this iPhone, to the
    /// saves folder, after the syncs under way: now, or once its server
    /// answers again.
    private func sendChanged(_ target: CartoucheSaveTarget) {
        guard isOn else { return }
        Task {
            _ = await turn { await self.syncRound([target], fetching: false, onlyChanged: true, byPlayer: false).failure == nil }
        }
    }

    private func putBack(_ backup: CartoucheSaveBackup, of target: CartoucheSaveTarget) async throws {
        guard let location = settings.location(.saves) else { return }
        let place = Self.place(location)
        isSyncing = true
        beginBackground()
        defer {
            isSyncing = false
            endBackground()
        }
        let remote = try await CartoucheStorage.connect(location.server, settings: settings)
        do {
            if await settings.checkAccess(remote, server: location.server.id, path: location.path) == false {
                throw CartoucheStorageError(.readOnly, CartoucheText.savesReadOnly)
            }
            let folder = CartoucheSavesFolder(remote: remote, path: location.path, place: place, scratch: Self.scratch)
            let outcome = try await folder.putBack(CartoucheStoragePath.name(backup.path), of: target,
                                                   base: savedBase(of: target, place: place))
            record(outcome, of: target)
            // The player put it back: no news to tell of it.
            news[target.key] = nil
            defaults.set(try? JSONEncoder().encode(news), forKey: Self.newsKey)
            problemReport = nil
        } catch {
            await remote.disconnect()
            throw error
        }
        await remote.disconnect()
    }
}
