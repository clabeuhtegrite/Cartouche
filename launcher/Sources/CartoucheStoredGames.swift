//
//  CartoucheStoredGames.swift
//  Cartouche
//
//  The games in the player's games folder (CartoucheStorage), installed on
//  this iPhone or not: each IPA there, and the folders one level down. An
//  IPA Cartouche wrote is known by its name, "<game> [<title ID>].ipa";
//  any other by its Info.plist, read from the IPA where it sits: its
//  central directory and one entry, a few reads, even for an IPA of
//  several gigabytes. What Cartouche found is kept on the iPhone, so that
//  each IPA is read once.
//

import Combine
import Foundation

/// An IPA in the player's games folder.
struct CartoucheStoredGame: Codable, Hashable, Identifiable {
    /// Its path in the games folder's server.
    let path: String
    let size: UInt64
    let modified: Date?
    /// From its Info.plist, when Cartouche read it.
    var bundleId: String?
    var displayName: String?
    var version: String?
    /// The game's title ID, from its name or its bundle ID.
    var titleId: String?
    /// Whether it is an nxnative game, as far as Cartouche can tell.
    var isGame: Bool

    var id: String { path }
    var fileName: String { CartoucheStoragePath.name(path) }

    /// The name to show when the catalogue does not know the game.
    var name: String {
        if let displayName, !displayName.isEmpty { return displayName }
        var name = fileName
        if name.lowercased().hasSuffix(".ipa") { name.removeLast(4) }
        if let range = name.range(of: #"\s*\[[0-9A-Fa-f]{16}\]"#, options: .regularExpression) {
            name.removeSubrange(range)
        }
        return name
    }

    /// The name Cartouche gives the IPA of a game it copies to the games
    /// folder.
    static func fileName(game: String, titleId: String?) -> String {
        var name = CartoucheStoragePath.fileName(game)
        if let titleId { name += " [\(titleId.uppercased())]" }
        return name + ".ipa"
    }

    /// The title ID in a name such as "Mario Kart World [09D00E8A5D61A000].ipa".
    static func titleId(inName name: String) -> String? {
        guard let range = name.range(of: #"\[[0-9A-Fa-f]{16}\]"#, options: .regularExpression) else { return nil }
        return String(name[range].dropFirst().dropLast()).uppercased()
    }

    /// The title ID in an nxnative bundle ID, org.nxnative.<title ID>.
    static func titleId(inBundleId bundleId: String) -> String? {
        let prefix = "org.nxnative."
        let lowered = bundleId.lowercased()
        guard lowered.hasPrefix(prefix) else { return nil }
        let candidate = lowered.dropFirst(prefix.count).prefix(16)
        guard candidate.count == 16, candidate.allSatisfy(\.isHexDigit) else { return nil }
        return candidate.uppercased()
    }
}

@MainActor
final class CartoucheStoredGames: ObservableObject {
    static let shared = CartoucheStoredGames()

    @Published private(set) var games: [CartoucheStoredGame] = []
    @Published private(set) var isScanning = false
    /// Why the games folder could not be read, the last time.
    @Published private(set) var problem: String?
    /// The server the games are on, for the console to name.
    @Published private(set) var serverName: String?

    private let settings: CartoucheStorageSettings
    private var known: [String: CartoucheStoredGame] = [:]
    private let cacheFile: URL
    private var scan: Task<Void, Never>?

    init(settings: CartoucheStorageSettings = .shared) {
        self.settings = settings
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        cacheFile = caches.appendingPathComponent("Cartouche/StoredGames.json")
        if let data = try? Data(contentsOf: cacheFile),
           let saved = try? JSONDecoder().decode([String: CartoucheStoredGame].self, from: data) {
            known = saved
        }
        if let location = settings.location(.games) {
            serverName = location.server.name
            // The last list, until the folder has been read again.
            let prefix = location.server.id.uuidString + "|"
            games = known.filter { $0.key.hasPrefix(prefix) }.map(\.value).sorted(by: Self.byName)
        }
    }

    private static func byName(_ a: CartoucheStoredGame, _ b: CartoucheStoredGame) -> Bool {
        a.name.localizedStandardCompare(b.name) == .orderedAscending
    }

    /// The stored game of a title ID, or of an installed app's bundle ID.
    func game(titleId: String?, bundleId: String?) -> CartoucheStoredGame? {
        games.first { stored in
            (titleId != nil && stored.titleId == titleId) || (bundleId != nil && stored.bundleId == bundleId)
        }
    }

    /// Reads the games folder again, unless it is being read.
    func refresh() {
        guard scan == nil else { return }
        scan = Task {
            await read()
            scan = nil
        }
    }

    /// Reads the games folder again and waits for the list.
    func reload() async {
        if let scan { await scan.value }
        await read()
    }

    private func read() async {
        guard let location = settings.location(.games) else {
            games = []
            serverName = nil
            problem = nil
            return
        }
        serverName = location.server.name
        isScanning = true
        defer { isScanning = false }
        let remote: CartoucheRemote
        do {
            remote = try await CartoucheStorage.connect(location.server, settings: settings)
        } catch {
            problem = error.localizedDescription
            return
        }
        var found: [CartoucheStoredGame] = []
        do {
            var folders = [location.path]
            let top = try await remote.list(location.path)
            folders += top.filter(\.isFolder).prefix(64).map { CartoucheStoragePath.join(location.path, $0.name) }
            for folder in folders {
                let items: [CartoucheRemoteItem]
                if folder == location.path {
                    items = top
                } else {
                    items = (try? await remote.list(folder)) ?? []
                }
                for item in items where !item.isFolder && item.name.lowercased().hasSuffix(".ipa") {
                    let path = CartoucheStoragePath.join(folder, item.name)
                    let key = Self.key(location.server, path: path, size: item.size, modified: item.modified)
                    if let game = known[key] {
                        found.append(game)
                        continue
                    }
                    let game = await identify(path: path, item: item, in: remote, server: location.server)
                    known[key] = game
                    found.append(game)
                }
            }
            problem = nil
        } catch {
            problem = error.localizedDescription
        }
        await remote.disconnect()
        games = found.filter(\.isGame).sorted(by: Self.byName)
        save()
    }

    private static func key(_ server: CartoucheStorageServer, path: String, size: UInt64, modified: Date?) -> String {
        "\(server.id.uuidString)|\(path)|\(size)|\(Int(modified?.timeIntervalSince1970 ?? 0))"
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(known) else { return }
        try? FileManager.default.createDirectory(at: cacheFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: cacheFile, options: .atomic)
    }

    /// What the IPA at PATH is: by its name when Cartouche named it, else by
    /// its Info.plist. A file iCloud Drive has not downloaded is known by its
    /// name only: reading it would download all of it.
    private func identify(path: String, item: CartoucheRemoteItem, in remote: CartoucheRemote,
                          server: CartoucheStorageServer) async -> CartoucheStoredGame {
        var game = CartoucheStoredGame(path: path, size: item.size, modified: item.modified,
                                       titleId: CartoucheStoredGame.titleId(inName: item.name), isGame: false)
        if game.titleId != nil {
            game.isGame = true
            return game
        }
        if let folder = remote as? CartoucheFolder, !folder.isDownloaded(path) {
            game.titleId = CartoucheCatalog.shared.titleId(matchingName: game.name)
            game.isGame = game.titleId != nil
            return game
        }
        do {
            let source = try await remote.open(path)
            let info = try await Self.infoPlist(of: source)
            game.bundleId = info["CFBundleIdentifier"] as? String
            game.displayName = (info["CFBundleDisplayName"] as? String) ?? (info["CFBundleName"] as? String)
            game.version = info["CFBundleShortVersionString"] as? String
            game.titleId = game.bundleId.flatMap(CartoucheStoredGame.titleId(inBundleId:))
                ?? game.displayName.flatMap { CartoucheCatalog.shared.titleId(matchingName: $0) }
            game.isGame = game.titleId != nil || info["DMLanguage"] != nil
        } catch {
            NSLog("[Cartouche] cannot read %@: %@", path, error.localizedDescription)
            game.titleId = CartoucheCatalog.shared.titleId(matchingName: game.name)
            game.isGame = game.titleId != nil
        }
        return game
    }

    /// The Info.plist of the app in an IPA: Payload/<name>.app/Info.plist.
    nonisolated static func infoPlist(of source: CartoucheByteSource) async throws -> [String: Any] {
        let entries = try await CartoucheZip.entries(of: source)
        guard let entry = entries.first(where: { entry in
            let parts = entry.name.split(separator: "/")
            return parts.count == 3 && parts[0] == "Payload" && parts[1].hasSuffix(".app") && parts[2] == "Info.plist"
        }) else {
            throw CartoucheStorageError(CartoucheText.storageNotAnApp)
        }
        let data = try await CartoucheZip.data(of: entry, in: source, limit: 4 << 20)
        guard let plist = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
            throw CartoucheStorageError(CartoucheText.storageNotAnApp)
        }
        return plist
    }
}
