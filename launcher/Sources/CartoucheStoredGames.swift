//
//  CartoucheStoredGames.swift
//  Cartouche
//
//  The games in the player's games folder (CartoucheStorage), installed on
//  this iPhone or not: each IPA there, and the folders one level down. An
//  IPA Cartouche wrote is known by its name, "<game> [<title ID>].ipa";
//  any other by its Info.plist, read from the IPA where it sits: its
//  central directory and one entry, a few reads, even for an IPA of
//  several gigabytes. The Info.plist also says which build of the game
//  the IPA is (CartoucheGameBuild), for the console to offer a newer one
//  over the installed game. What Cartouche found is kept on the iPhone,
//  so that each IPA is read once.
//
//  An IPA nxnative built without its game files (romfs.id, CartoucheRomfs)
//  takes the image of them, romfs.img, that sits beside it, in any letter
//  case, or elsewhere in the games folder: Cartouche installs the two
//  together. An image no IPA takes, and an IPA without its image, are
//  told on the Storage page, since neither installs a game by itself.
//
//  Away from the games folder's server, as from a NAS at home, the last
//  list stays: Cartouche finds the server offline within a few seconds
//  (CartoucheStorageReach), and reads the folder again once it answers.
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
    /// Which build of the game it is, from its Info.plist.
    var build: CartoucheGameBuild?
    /// The game's title ID, from its name or its bundle ID.
    var titleId: String?
    /// Whether it is an nxnative game, as far as Cartouche can tell.
    var isGame: Bool
    /// The image of its game files it needs, for an IPA nxnative built
    /// without them (CartoucheRomfs); nil for one that holds them.
    var gameFiles: CartoucheRomfsIdentity? = nil
    /// The image of the games folder that goes with it, by its path: of the
    /// size it needs, beside it or elsewhere in the folder.
    var gameFilesPath: String? = nil
    /// Whether Cartouche looked for romfs.id in it, as an older Cartouche
    /// did not.
    var checkedGameFiles: Bool? = nil

    var id: String { path }
    /// Whether it needs an image of its game files the games folder lacks.
    var lacksGameFiles: Bool { gameFiles != nil && gameFilesPath == nil }
    /// What it takes in the games folder, with the image of its game files.
    var storedSize: UInt64 { size + (gameFilesPath == nil ? 0 : gameFiles?.size ?? 0) }
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

    /// Whether this IPA is a newer copy of the game than OTHER, of the same
    /// games folder: by the builds they are, else by when they were written
    /// there.
    func isNewerCopy(than other: CartoucheStoredGame) -> Bool {
        if let build, let otherBuild = other.build {
            if build.isNewerCopy(than: otherBuild) { return true }
            if otherBuild.isNewerCopy(than: build) { return false }
        }
        return (modified ?? .distantPast) > (other.modified ?? .distantPast)
    }
}

/// The build of each game Cartouche installed, as the IPA it came from
/// said: an installed game no longer says when it was built, since the
/// time of its Info.plist goes with the install.
final class CartoucheInstalledBuilds {
    static let shared = CartoucheInstalledBuilds()

    /// By the game's bundle ID.
    private var builds: [String: CartoucheGameBuild] = [:]
    private let file: URL

    init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        file = support.appendingPathComponent("Cartouche/InstalledBuilds.json")
        if let data = try? Data(contentsOf: file),
           let saved = try? JSONDecoder().decode([String: CartoucheGameBuild].self, from: data) {
            builds = saved
        }
    }

    /// Notes the build of the IPA Cartouche just installed as BUNDLEID.
    func record(_ build: CartoucheGameBuild, bundleId: String) {
        builds[bundleId] = build
        guard let data = try? JSONEncoder().encode(builds) else { return }
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: file, options: .atomic)
    }

    /// The builds read from the games' Info.plist, by the game's bundle, with
    /// when the Info.plist last changed: the console asks for them often.
    private static var readBuilds: [String: (changed: Date?, build: CartoucheGameBuild)] = [:]
    private static let readLock = NSLock()

    /// The build of the installed game, as the Info.plist in its bundle says.
    /// LiveContainer's info() is not it: those are LiveContainer's own
    /// settings for the game (LCAppInfo.plist), which name no version.
    static func installedBuild(of app: LCAppModel) -> CartoucheGameBuild {
        guard let path = app.appInfo.bundlePath() else { return CartoucheGameBuild() }
        let bundle = URL(fileURLWithPath: path, isDirectory: true)
        let changed = (try? bundle.appendingPathComponent("Info.plist")
            .resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        readLock.lock()
        defer { readLock.unlock() }
        if let known = readBuilds[path], known.changed == changed { return known.build }
        let build = CartoucheGameBuild.installed(atBundle: bundle) ?? CartoucheGameBuild()
        readBuilds[path] = (changed, build)
        return build
    }

    /// The record of the game's install, when it is of the build installed
    /// (CartoucheGameBuild.record(_:of:)).
    func record(of app: LCAppModel) -> CartoucheGameBuild? {
        guard let bundleId = app.appInfo.bundleIdentifier(), let recorded = builds[bundleId] else { return nil }
        return CartoucheGameBuild.record(recorded, of: Self.installedBuild(of: app))
    }

    /// The installed game's build, to compare with a copy in the games
    /// folder: when it was built, from the record of its install, or, for
    /// a game Cartouche installed before it kept one, when it was
    /// installed, which it was built before.
    func build(of app: LCAppModel) -> CartoucheGameBuild {
        let installedAt: Date? = app.appInfo.installationDate
        var build = record(of: app) ?? Self.installedBuild(of: app)
        if build.builtAt == nil { build.builtAt = installedAt }
        return build
    }
}

@MainActor
final class CartoucheStoredGames: ObservableObject {
    static let shared = CartoucheStoredGames()

    @Published private(set) var games: [CartoucheStoredGame] = []
    @Published private(set) var isScanning = false
    /// Why the games folder could not be read, the last time, and the
    /// report on it.
    @Published private(set) var problemReport: CartoucheReport?
    var problem: String? { problemReport?.message }
    /// The server the games are on, for the console to name.
    @Published private(set) var serverName: String?
    /// The images of game files in the games folder that no IPA there
    /// takes, by their paths (CartoucheRomfs): a romfs.img without the IPA
    /// nxnative built with it.
    @Published private(set) var looseGameFiles: [String] = []

    private let settings: CartoucheStorageSettings
    private var known: [String: CartoucheStoredGame] = [:]
    private let cacheFile: URL
    private var scan: Task<Void, Never>?
    #if CARTOUCHE_GALLERY
    private var shownForGallery = false
    #endif

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

    /// Reads the games folder again, unless it is being read. As Cartouche
    /// does by itself, it leaves a server it found offline a moment ago
    /// alone; EVEN IF OFFLINE, as the player asks, it tries it again.
    func refresh(evenIfOffline: Bool = false) {
        guard scan == nil else { return }
        scan = Task {
            await read(evenIfOffline: evenIfOffline)
            scan = nil
        }
    }

    /// Reads the games folder again and waits for the list.
    func reload() async {
        if let scan { await scan.value }
        await read(evenIfOffline: true)
    }

    #if CARTOUCHE_GALLERY
    /// A games folder with these IPAs, for the launcher's gallery
    /// (launcher/Gallery).
    func showForGallery(_ stored: [CartoucheStoredGame], server: String) {
        games = stored
        serverName = server
        shownForGallery = true
    }
    #endif

    private func read(evenIfOffline: Bool) async {
        #if CARTOUCHE_GALLERY
        if shownForGallery { return }
        #endif
        guard let location = settings.location(.games) else {
            games = []
            looseGameFiles = []
            serverName = nil
            problemReport = nil
            return
        }
        serverName = location.server.name
        if !evenIfOffline && CartoucheStorageReach.shared.isSettledOffline(location.server.id) {
            problemReport = nil
            return
        }
        isScanning = true
        defer { isScanning = false }
        let remote: CartoucheRemote
        do {
            remote = try await CartoucheStorage.connect(location.server, settings: settings)
        } catch is CartoucheStorageOffline {
            // No problem: the last list stays until the server answers again.
            problemReport = nil
            return
        } catch {
            problemReport = Self.readFailed(error, step: "Connecting to " + CartoucheReports.place(.games))
            return
        }
        var found: [CartoucheStoredGame] = []
        var images: [CartoucheRomfsImage] = []
        do {
            var folders = [location.path]
            let top = try await remote.list(location.path)
            // Whether Cartouche can copy a game there, for its Copy to.
            await settings.checkAccess(remote, server: location.server.id, path: location.path)
            folders += top.filter(\.isFolder).prefix(64).map { CartoucheStoragePath.join(location.path, $0.name) }
            for folder in folders {
                let items: [CartoucheRemoteItem]
                if folder == location.path {
                    items = top
                } else {
                    items = (try? await remote.list(folder)) ?? []
                }
                for item in items where !item.isFolder && CartoucheRomfs.isImageName(item.name) {
                    let path = CartoucheStoragePath.join(folder, item.name)
                    images.append(CartoucheRomfsImage(path: path, folder: CartoucheStoragePath.parent(path), size: item.size))
                }
                for item in items where !item.isFolder && item.name.lowercased().hasSuffix(".ipa") {
                    let path = CartoucheStoragePath.join(folder, item.name)
                    let key = Self.key(location.server, path: path, size: item.size, modified: item.modified)
                    // What a scan before 0.9.0 found says nothing of the
                    // build, and one by an older Cartouche nothing of the
                    // game files: read again.
                    if let game = known[key], game.build != nil, game.checkedGameFiles == true {
                        found.append(game)
                        continue
                    }
                    let (game, settled) = await identify(path: path, item: item, in: remote, server: location.server)
                    if settled { known[key] = game }
                    found.append(game)
                }
            }
            problemReport = nil
        } catch {
            problemReport = Self.readFailed(error, step: "Listing " + CartoucheReports.place(.games),
                                            facts: [.init("Games found", String(found.count))])
        }
        await remote.disconnect()
        let paired = Self.pairGameFiles(found, images: images)
        for game in paired.games {
            let key = Self.key(location.server, path: game.path, size: game.size, modified: game.modified)
            known[key]?.gameFilesPath = game.gameFilesPath
        }
        games = paired.games.filter(\.isGame).sorted(by: Self.byName)
        looseGameFiles = paired.loose
        save()
    }

    /// GAMES, each IPA built without its game files with the image of the
    /// games folder it takes (CartoucheRomfs.pair), and the images no IPA
    /// takes. An IPA Cartouche could not read may be the one an image goes
    /// with: none is said to be alone then.
    nonisolated static func pairGameFiles(_ games: [CartoucheStoredGame], images: [CartoucheRomfsImage])
        -> (games: [CartoucheStoredGame], loose: [String]) {
        let needs = games.compactMap { game in
            game.gameFiles.map { CartoucheRomfsNeed(path: game.path, folder: CartoucheStoragePath.parent(game.path), size: $0.size) }
        }
        let (taken, loose) = CartoucheRomfs.pair(needs, with: images, allRead: games.allSatisfy { $0.checkedGameFiles == true })
        let paired = games.map { game -> CartoucheStoredGame in
            var game = game
            game.gameFilesPath = taken[game.path]?.path
            return game
        }
        return (paired, loose.map(\.path))
    }

    /// The report on the games folder, which ERROR kept Cartouche from
    /// reading at STEP. Cartouche reads it each time it comes back, away
    /// from home too: the report is not kept.
    private static func readFailed(_ error: Error, step: String, facts: [CartoucheReport.Fact] = []) -> CartoucheReport {
        CartoucheReports.make(.storage, CartoucheText.storageGamesFailed, message: error.localizedDescription, error: error,
                              step: step, stage: "gamesFolder", facts: facts, inBackground: true)
    }

    private static func key(_ server: CartoucheStorageServer, path: String, size: UInt64, modified: Date?) -> String {
        "\(server.id.uuidString)|\(path)|\(size)|\(Int(modified?.timeIntervalSince1970 ?? 0))"
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(known) else { return }
        try? FileManager.default.createDirectory(at: cacheFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: cacheFile, options: .atomic)
    }

    /// What the IPA at PATH is: by the title ID in its name, as Cartouche
    /// names the IPAs it writes, else by its Info.plist, else by its name
    /// (CartoucheCatalog.titleId(inFileName:)); and which build of the game,
    /// by its Info.plist. A file iCloud Drive has not downloaded is known by
    /// its name only, since reading it would download all of it. Also
    /// returns whether to remember what it found: an IPA whose Info.plist
    /// could not be read is read again at the next scan, once it is
    /// downloaded or once the place answers.
    private func identify(path: String, item: CartoucheRemoteItem, in remote: CartoucheRemote,
                          server: CartoucheStorageServer) async -> (CartoucheStoredGame, settled: Bool) {
        var game = CartoucheStoredGame(path: path, size: item.size, modified: item.modified,
                                       titleId: CartoucheStoredGame.titleId(inName: item.name), isGame: false)
        let named = game.titleId != nil
        if let folder = remote as? CartoucheFolder, !folder.isDownloaded(path) {
            if !named { game.titleId = CartoucheCatalog.shared.titleId(inFileName: item.name) }
            game.isGame = game.titleId != nil
            return (game, false)
        }
        do {
            let source = try await remote.open(path)
            let entries = try await CartoucheZip.entries(of: source)
            let (info, builtAt) = try await Self.infoPlist(of: source, entries: entries)
            game.bundleId = info["CFBundleIdentifier"] as? String
            game.displayName = (info["CFBundleDisplayName"] as? String) ?? (info["CFBundleName"] as? String)
            game.version = info["CFBundleShortVersionString"] as? String
            game.build = CartoucheGameBuild(info: info, builtAt: builtAt)
            if !named {
                game.titleId = game.bundleId.flatMap(CartoucheStoredGame.titleId(inBundleId:))
                    ?? CartoucheNxnativeApp.titleId(in: info)
                    ?? game.displayName.flatMap { CartoucheCatalog.shared.titleId(matchingName: $0) }
                    ?? CartoucheCatalog.shared.titleId(inFileName: item.name)
            }
            // Its romfs.id, for an IPA built without its game files: one
            // more entry read.
            game.gameFiles = try await CartoucheRomfs.neededIdentity(ofIPA: source, entries: entries)
            game.checkedGameFiles = true
            game.isGame = CartoucheNxnativeApp.isGame(info: info, titleId: game.titleId, needsGameFiles: game.gameFiles != nil)
            return (game, true)
        } catch {
            NSLog("[Cartouche] cannot read %@: %@", path, error.localizedDescription)
            if !named { game.titleId = CartoucheCatalog.shared.titleId(inFileName: item.name) }
            game.isGame = game.titleId != nil
            return (game, false)
        }
    }

    /// The entry of the app's Info.plist in an IPA: Payload/<name>.app/Info.plist.
    nonisolated static func infoPlistEntry(in entries: [CartoucheZipEntry]) -> CartoucheZipEntry? {
        entries.first { entry in
            let parts = entry.name.split(separator: "/")
            return parts.count == 3 && parts[0] == "Payload" && parts[1].hasSuffix(".app") && parts[2] == "Info.plist"
        }
    }

    /// The Info.plist of the app in an IPA of these ENTRIES, and its time
    /// there, which says when the IPA was built.
    nonisolated static func infoPlist(of source: CartoucheByteSource,
                                      entries: [CartoucheZipEntry]) async throws -> (info: [String: Any], builtAt: Date?) {
        guard let entry = infoPlistEntry(in: entries) else {
            throw CartoucheStorageError(.notAnApp, CartoucheText.storageNotAnApp)
        }
        let data = try await CartoucheZip.data(of: entry, in: source, limit: 4 << 20)
        guard let plist = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
            throw CartoucheStorageError(.notAnApp, CartoucheText.storageNotAnApp)
        }
        return (plist, entry.modified)
    }
}
