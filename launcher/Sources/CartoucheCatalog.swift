//
//  CartoucheCatalog.swift
//  Cartouche
//
//  The games Cartouche supports: every game nxnative has a profile for
//  (nxnative.json, from nxnative's dm/games at the commit Cartouche pins),
//  the compatibility sheets testers wrote for some of them, their official
//  covers on IGDB (covers.json, image IDs only), and the player's own copies:
//  those installed among LiveContainer's apps, and those in the player's
//  games folder (CartoucheStoredGames). The app carries these files in
//  CartoucheCatalog/ (catalog/ in the Cartouche repository). None says
//  where to get a game. Newer covers come every day (CartoucheLiveCovers),
//  with those of the games nxnative added since: a game of the player's
//  that the list does not know yet shows its cover by its title ID. A game
//  of the player's that nxnative has no profile for, such as one built with
//  a fork of nxnative, has its platform from its title ID, and its cover,
//  an artwork and its genre from IGDB by its name (CartoucheGameLookup).
//  The player can change the name, the platform, the genre and the cover
//  of any game of theirs, on this iPhone (CartouchePlayerInfo).
//

import Combine
import Foundation

struct CartoucheGameSheet: Decodable, Hashable {
    struct Requirements: Decodable, Hashable {
        let minimumIOS: String
        let bcTextureCompression: Bool
        let increasedMemoryLimit: Bool
        let peakMemoryMiB: Int?
    }

    struct Recommended: Decodable, Hashable {
        let resolution: String?
        let mode: String?
    }

    struct Result: Decodable, Hashable {
        let device: String
        let iOS: String
        let date: String
        let engine: String
        let status: String
        let peakMemoryMiB: Int?
        let notes: [String]?
        /// What Cartouche's game measurements found, for a result they made:
        /// the figures its note and engine say in English, which Cartouche
        /// says in the player's language (CartoucheMeasuredNote.swift).
        let measured: CartoucheMeasured?
    }

    let titleId: String
    let name: String
    let platform: String
    let requirements: Requirements
    let recommended: Recommended?
    let results: [Result]

    /// The highest memory peak measured, the sheet's own or a result's.
    var peakMemoryMiB: Int? {
        ([requirements.peakMemoryMiB] + results.map(\.peakMemoryMiB)).compactMap { $0 }.max()
    }
}

/// A game nxnative has a profile for (catalog/schema/nxnative.schema.json).
struct CartoucheNxGame: Decodable, Hashable {
    struct Variant: Decodable, Hashable {
        let titleId: String
        let region: String
        let build: String
    }

    let titleId: String
    let name: String
    let platform: String
    let genre: String
    /// Where nxnative's profile says the game plays: iphone, mac, bringup
    /// or unknown.
    let status: String
    let engine: String
    let build: String
    let sdk: String
    let variants: [Variant]?

    /// The main release's title ID, then those of the other regions.
    var titleIds: [String] { [titleId] + (variants ?? []).map(\.titleId) }
}

struct CartoucheDeviceProfile: Decodable, Hashable {
    struct Measurement: Decodable, Hashable {
        let date: String
        let iOS: String
        let increasedMemoryLimit: Bool
        let appMemoryLimitMiB: Int
    }

    let identifier: String
    let chip: String
    let memoryGB: Int
    let measurements: [Measurement]
}

/// A game in the catalogue: a supported game, the player's copy of one, or
/// the player's copy of an nxnative game that Cartouche does not know. The
/// player's copy is installed (app), in their games folder (stored), or
/// both.
struct CartoucheEntry: Identifiable, Hashable {
    let id: String
    let game: CartoucheNxGame?
    let sheet: CartoucheGameSheet?
    let app: LCAppModel?
    /// The game's IPA in the player's games folder, the newest when there
    /// are several.
    var stored: CartoucheStoredGame? = nil
    /// That IPA, when it is a newer build than the installed game: the
    /// console offers to update the game with it.
    var update: CartoucheStoredGame? = nil
    /// The title ID the player's copy says it is, that of a game the list
    /// may not know yet.
    var ownTitleId: String? = nil
    /// The game's official cover and artwork on IGDB, if Cartouche has them
    /// (CartoucheCatalog.cover(titleId:)).
    var cover: CartoucheCover? = nil
    /// What IGDB has of a game of the player's that Cartouche does not
    /// know, by its name (CartoucheGameLookup).
    var found: CartoucheFoundGame? = nil
    /// What the player said of their game (CartouchePlayerInfo), and the
    /// file of their cover.
    var player: CartouchePlayerInfo? = nil
    var playerCover: URL? = nil

    /// The name the player gave the game, else its own.
    var name: String { player?.name ?? ownName }

    /// The game's name in the catalogue, else its copy's.
    var ownName: String {
        if let sheet { return sheet.name }
        if let game { return game.name }
        return app?.appInfo.displayName() ?? stored?.name ?? ""
    }

    var titleId: String? { game?.titleId ?? sheet?.titleId ?? ownTitleId }
    /// The platform the player chose, else the game's own.
    var platform: String? { player?.platform ?? ownPlatform }
    /// The catalogue's platform for the game, else the one its title ID
    /// says, else IGDB's.
    var ownPlatform: String? {
        sheet?.platform ?? game?.platform ?? CartoucheGameWanted.platform(titleId: titleId) ?? found?.platform
    }
    /// The genre the player chose, else the game's own.
    var genre: String? { player?.genre ?? ownGenre }
    /// nxnative's genre for the game, else IGDB's: by its title ID, or by
    /// its name for a game Cartouche does not know.
    var ownGenre: String? {
        if let genre = game?.genre, genre != "other" { return genre }
        return cover?.genre ?? found?.genre
    }
    /// What the player wrote of the game, else IGDB's summary of it.
    var summary: String? { player?.summary ?? ownSummary }
    /// IGDB's summary of the game, in English: by its title ID, or by its
    /// name for a game Cartouche does not know.
    var ownSummary: String? { cover?.summary ?? found?.summary }
    /// Whether Cartouche knows nothing of the game but what the player's
    /// copy says: nxnative has no profile for it, nor IGDB a cover by its
    /// title ID.
    var isUnknown: Bool { game == nil && sheet == nil && cover == nil }
    var isOwned: Bool { app != nil || stored != nil }
    var isInstalled: Bool { app != nil }
    /// In the games folder, not on this iPhone: Install brings it.
    var canInstallFromStorage: Bool { app == nil && stored != nil }

    /// Whether the game is known to play on an iPhone: a tester's result
    /// says so, or nxnative's profile does.
    var playsOnIPhone: Bool {
        if let sheet, sheet.results.contains(where: { $0.status == "playable" || $0.status == "playable-with-issues" }) {
            return true
        }
        return game?.status == "iphone"
    }

    /// What tells the designed tiles apart: the title ID, or the app's folder.
    var tileKey: String { titleId ?? id }

    static func == (lhs: CartoucheEntry, rhs: CartoucheEntry) -> Bool {
        lhs.id == rhs.id && lhs.app === rhs.app && lhs.stored == rhs.stored && lhs.update == rhs.update
            && lhs.ownTitleId == rhs.ownTitleId && lhs.cover == rhs.cover && lhs.found == rhs.found
            && lhs.player == rhs.player && lhs.playerCover == rhs.playerCover
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}

final class CartoucheCatalog: ObservableObject {
    static let shared = CartoucheCatalog()

    let games: [CartoucheNxGame]
    let sheets: [CartoucheGameSheet]
    let devices: [CartoucheDeviceProfile]
    /// Each title ID, every region's, to its game.
    private let gamesByTitle: [String: CartoucheNxGame]
    /// Each game's title ID in nxnative.json to the cover the app carries.
    private let carriedCovers: [String: CartoucheCover]
    /// Those, under the newer ones Cartouche read (CartoucheLiveCovers),
    /// which also have the games nxnative added since.
    private var covers: [String: CartoucheCover]
    /// What IGDB has of the player's games Cartouche does not know, by the
    /// key of the game asked (CartoucheGameWanted.key).
    private var foundGames: [String: CartoucheFoundGame]
    /// What the player said of their games.
    private let playerInfo: CartouchePlayerInfoStore
    private let coversLock = NSLock()
    /// Changes when newer covers arrive, when IGDB's answers about the
    /// player's games do, and when the player changes what they said of
    /// one, for the views to show them.
    @Published private(set) var coversRevision = 0

    /// The title ID each app's folder was found to hold, or "" for an
    /// nxnative game without one, so that every Info.plist is read once.
    private var appTitles: [String: String] = [:]
    private var otherApps: Set<String> = []

    private init() {
        let folder = Bundle.main.bundleURL.appendingPathComponent("CartoucheCatalog", isDirectory: true)
        let decoder = JSONDecoder()
        var sheets: [CartoucheGameSheet] = []
        let gameFiles = (try? FileManager.default.contentsOfDirectory(
            at: folder.appendingPathComponent("games", isDirectory: true),
            includingPropertiesForKeys: nil)) ?? []
        for file in gameFiles where file.pathExtension == "json" {
            do {
                sheets.append(try decoder.decode(CartoucheGameSheet.self, from: Data(contentsOf: file)))
            } catch {
                NSLog("[Cartouche] cannot read the sheet %@: %@", file.lastPathComponent, String(describing: error))
            }
        }
        self.sheets = sheets.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }

        struct GameList: Decodable { let games: [CartoucheNxGame] }
        do {
            let data = try Data(contentsOf: folder.appendingPathComponent("nxnative.json"))
            self.games = try decoder.decode(GameList.self, from: data).games
        } catch {
            NSLog("[Cartouche] cannot read nxnative's games: %@", String(describing: error))
            self.games = []
        }
        var byTitle: [String: CartoucheNxGame] = [:]
        for game in games {
            for titleId in game.titleIds { byTitle[titleId] = game }
        }
        self.gamesByTitle = byTitle

        var carried: [String: CartoucheCover] = [:]
        do {
            let data = try Data(contentsOf: folder.appendingPathComponent("covers.json"))
            if let covers = CartoucheCoverList.covers(in: data) {
                carried = covers
            } else {
                NSLog("[Cartouche] covers.json is not a list of covers")
            }
        } catch {
            NSLog("[Cartouche] cannot read the covers: %@", String(describing: error))
        }
        self.carriedCovers = carried
        // The newer covers read the last time, until the next read.
        self.covers = CartoucheCoverList.merged(carried, with: CartoucheLiveCovers.kept(at: CartoucheLiveCovers.defaultFile))
        self.foundGames = CartoucheGameLookup.kept(at: CartoucheGameLookup.defaultFile)
        #if CARTOUCHE_GALLERY
        // Each scenario of the gallery starts from nothing the player said.
        let infoFolder = FileManager.default.temporaryDirectory.appendingPathComponent("GameInfo", isDirectory: true)
        try? FileManager.default.removeItem(at: infoFolder)
        self.playerInfo = CartouchePlayerInfoStore(folder: infoFolder)
        #else
        self.playerInfo = CartouchePlayerInfoStore(folder: CartouchePlayerInfoStore.defaultFolder)
        #endif

        struct DeviceList: Decodable { let devices: [CartoucheDeviceProfile] }
        do {
            let data = try Data(contentsOf: folder.appendingPathComponent("devices.json"))
            self.devices = try decoder.decode(DeviceList.self, from: data).devices
        } catch {
            NSLog("[Cartouche] cannot read the device profiles: %@", String(describing: error))
            self.devices = []
        }
    }

    func device(_ identifier: String) -> CartoucheDeviceProfile? {
        devices.first { $0.identifier == identifier }
    }

    func sheet(titleId: String) -> CartoucheGameSheet? {
        sheets.first { $0.titleId == titleId }
    }

    /// nxnative's game for a title ID of any of its regions.
    func game(titleId: String) -> CartoucheNxGame? {
        gamesByTitle[titleId]
    }

    /// The official cover of the game of a title ID of any of its regions,
    /// or of a game the list does not know yet.
    func cover(titleId: String) -> CartoucheCover? {
        let key = gamesByTitle[titleId]?.titleId ?? titleId
        coversLock.lock()
        defer { coversLock.unlock() }
        return covers[key]
    }

    /// Reads the newer covers when they are due, and shows them
    /// (CartoucheLiveCovers): when Cartouche opens, and when it comes back.
    @MainActor
    func refreshCoversIfDue() {
        CartoucheLiveCovers.shared.refreshIfDue { [weak self] newer in
            self?.showCovers(newer)
        }
    }

    @MainActor
    private func showCovers(_ newer: [String: CartoucheCover]) {
        let merged = CartoucheCoverList.merged(carriedCovers, with: newer)
        coversLock.lock()
        let changed = merged != covers
        covers = merged
        coversLock.unlock()
        if changed { coversRevision += 1 }
    }

    /// ENTRY with its game's cover, as Cartouche has them now.
    private func withCover(_ entry: CartoucheEntry) -> CartoucheEntry {
        var entry = entry
        entry.cover = entry.titleId.flatMap { cover(titleId: $0) }
        return entry
    }

    // MARK: The player's games Cartouche does not know, and what the player says

    /// The key of what the player said of ENTRY's game: its bundle ID as
    /// its IPA gives it, when it has no title ID, the same from one install
    /// to the next (CartoucheGameStats.bundleId(of:)).
    private static func playerKey(of entry: CartoucheEntry) -> String {
        let installed = entry.app.flatMap {
            ($0.appInfo.info()?["LCOrignalBundleIdentifier"] as? String) ?? $0.appInfo.bundleIdentifier()
        }
        return CartouchePlayerInfoStore.key(titleId: entry.titleId, bundleId: installed ?? entry.stored?.bundleId, id: entry.id)
    }

    /// What Cartouche asks its server about ENTRY, one of the player's games
    /// it does not know: its name, the player's or its own, and its
    /// platform, the player's or the one its title ID says.
    static func wanted(for entry: CartoucheEntry) -> CartoucheGameWanted? {
        guard entry.isOwned, entry.isUnknown else { return nil }
        return CartoucheGameWanted(name: entry.name,
                                   platform: entry.player?.platform ?? CartoucheGameWanted.platform(titleId: entry.titleId))
    }

    /// The games of ENTRIES that Cartouche asks its server about.
    static func wanted(among entries: Entries) -> [CartoucheGameWanted] {
        var seen = Set<String>()
        return entries.owned.compactMap(wanted(for:)).filter { seen.insert($0.key).inserted }
    }

    /// ENTRY, one of the player's games, with what the player said of it
    /// and, for a game Cartouche does not know, what IGDB has of it.
    private func withOwnInfo(_ entry: CartoucheEntry) -> CartoucheEntry {
        var entry = entry
        coversLock.lock()
        entry.player = playerInfo.info(for: Self.playerKey(of: entry))
        entry.playerCover = playerInfo.coverFile(of: entry.player)
        if let wanted = Self.wanted(for: entry) { entry.found = foundGames[wanted.key] }
        coversLock.unlock()
        return entry
    }

    /// Asks Cartouche's server about the player's games it does not know,
    /// those of ENTRIES, when they are due (CartoucheGameLookup), and shows
    /// the answers.
    @MainActor
    func lookUpGamesIfDue(among entries: Entries) {
        CartoucheGameLookup.shared.lookUpIfDue(Self.wanted(among: entries)) { [weak self] found in
            self?.showFound(found)
        }
    }

    @MainActor
    private func showFound(_ found: [String: CartoucheFoundGame]) {
        coversLock.lock()
        let changed = found != foundGames
        foundGames = found
        coversLock.unlock()
        if changed { coversRevision += 1 }
    }

    /// Keeps what the player says of ENTRY's game (CartoucheGameInfoView):
    /// INFO, with COVER the JPEG of a new cover of theirs
    /// (CartouchePlayerInfoStore.jpeg(from:)); nil INFO and no COVER go back
    /// to what Cartouche finds by itself.
    @MainActor
    func setPlayerInfo(_ info: CartouchePlayerInfo?, cover: Data? = nil, for entry: CartoucheEntry) throws {
        coversLock.lock()
        defer {
            coversLock.unlock()
            coversRevision += 1
        }
        try playerInfo.set(info, cover: cover, for: Self.playerKey(of: entry))
    }

    #if CARTOUCHE_GALLERY
    /// IGDB's answers about the player's games, as the gallery stands in
    /// for Cartouche's server.
    @MainActor
    func showFoundForGallery(_ found: [String: CartoucheFoundGame]) {
        showFound(found)
    }
    #endif

    struct Entries {
        /// The player's games, known to Cartouche or not, by name.
        var owned: [CartoucheEntry] = []
        /// The other supported games, by name.
        var others: [CartoucheEntry] = []

        var all: [CartoucheEntry] { owned + others }

        func entry(id: String?) -> CartoucheEntry? {
            guard let id else { return nil }
            return owned.first { $0.id == id } ?? others.first { $0.id == id }
        }
    }

    /// Whether these apps and the IPAs of the player's games folder give the
    /// player a game of their own: whether entries(for:stored:) has owned
    /// ones, an nxnative game installed or any IPA of the games folder,
    /// without making every entry.
    func hasOwnedGames(among apps: [LCAppModel], stored: [CartoucheStoredGame]) -> Bool {
        !stored.isEmpty || apps.contains { gameTitle(of: $0) != nil }
    }

    /// The catalogue for these apps and the IPAs of the player's games
    /// folder: each of the player's nxnative games, installed or stored, then
    /// every other game nxnative has a profile for, with the sheet testers
    /// wrote when there is one. An installed game whose newest IPA in the
    /// games folder is a newer build of it has that IPA as its update.
    func entries(for apps: [LCAppModel], stored: [CartoucheStoredGame] = []) -> Entries {
        var result = Entries()
        var ownedTitles = Set<String>()
        var storedLeft = stored
        for app in apps {
            guard let found = gameTitle(of: app) else { continue }
            let titleId = found.isEmpty ? titleMatchingName(of: app) : found
            let game = titleId.flatMap { self.game(titleId: $0) }
            let sheet = (game?.titleId ?? titleId).flatMap { self.sheet(titleId: $0) }
            if let game { ownedTitles.formUnion(game.titleIds) } else if let titleId { ownedTitles.insert(titleId) }
            let folder = app.appInfo.relativeBundlePath ?? app.appInfo.bundleIdentifier() ?? ""
            // Its IPA in the games folder, if there is one.
            let titles = Set(game?.titleIds ?? titleId.map { [$0] } ?? [])
            let bundleId = app.appInfo.bundleIdentifier()
            let copies = storedLeft.indices.filter { index in
                let stored = storedLeft[index]
                return (stored.titleId.map { titles.contains($0) } ?? false) || (bundleId != nil && stored.bundleId == bundleId)
            }
            let newest = copies.max { storedLeft[$1].isNewerCopy(than: storedLeft[$0]) }
            let storedCopy = newest.map { storedLeft[$0] }
            for index in copies.reversed() { storedLeft.remove(at: index) }
            var update: CartoucheStoredGame?
            if let storedCopy, let build = storedCopy.build, build.isNewer(than: CartoucheInstalledBuilds.shared.build(of: app)) {
                update = storedCopy
            }
            result.owned.append(CartoucheEntry(id: "app:" + folder, game: game, sheet: sheet, app: app, stored: storedCopy,
                                               update: update, ownTitleId: titleId))
        }
        // The games of the games folder that are not installed, one entry
        // each: the newest IPA of a game that has several.
        for copy in storedLeft.sorted(by: { $0.isNewerCopy(than: $1) }) {
            let game = copy.titleId.flatMap { self.game(titleId: $0) }
            let titleId = game?.titleId ?? copy.titleId
            if let titleId, ownedTitles.contains(titleId) { continue }
            if let game { ownedTitles.formUnion(game.titleIds) } else if let titleId { ownedTitles.insert(titleId) }
            let sheet = titleId.flatMap { self.sheet(titleId: $0) }
            result.owned.append(CartoucheEntry(id: "stored:" + copy.path, game: game, sheet: sheet, app: nil, stored: copy,
                                               ownTitleId: titleId))
        }
        result.owned = result.owned.map { withOwnInfo(withCover($0)) }
        result.owned.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        var others = games
            .filter { !ownedTitles.contains($0.titleId) }
            .map { CartoucheEntry(id: "game:" + $0.titleId, game: $0, sheet: self.sheet(titleId: $0.titleId), app: nil) }
        // A sheet always names an nxnative game (catalog tests); keep one
        // that would not.
        others += sheets
            .filter { !ownedTitles.contains($0.titleId) && game(titleId: $0.titleId) == nil }
            .map { CartoucheEntry(id: "game:" + $0.titleId, game: nil, sheet: $0, app: nil) }
        result.others = others.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }.map { withCover($0) }
        return result
    }

    /// The title ID of an nxnative game, "" for an nxnative game whose title
    /// ID is unknown, or nil for any other app.
    ///
    /// nxnative names its iOS apps org.nxnative.<title ID in lowercase>
    /// (dm/ios/tools/build_ipa.sh) unless the build was given another
    /// identifier, and writes DMLanguage into their Info.plist.
    func gameTitle(of app: LCAppModel) -> String? {
        let folder = app.appInfo.relativeBundlePath ?? ""
        if let known = appTitles[folder] { return known }
        if otherApps.contains(folder) { return nil }

        let original = app.appInfo.info()?["LCOrignalBundleIdentifier"] as? String
        let bundleId = (original ?? app.appInfo.bundleIdentifier() ?? "").lowercased()
        let prefix = "org.nxnative."
        if bundleId.hasPrefix(prefix) {
            let candidate = bundleId.dropFirst(prefix.count).prefix(16)
            if candidate.count == 16, candidate.allSatisfy(\.isHexDigit) {
                appTitles[folder] = candidate.uppercased()
                return appTitles[folder]
            }
        }

        let infoPlist = (app.appInfo.bundlePath() as NSString?)?.appendingPathComponent("Info.plist")
        if let infoPlist, let info = NSDictionary(contentsOfFile: infoPlist), info["DMLanguage"] != nil {
            appTitles[folder] = ""
            return ""
        }
        otherApps.insert(folder)
        return nil
    }

    /// An nxnative build with another bundle identifier keeps the game's
    /// name as its display name.
    private func titleMatchingName(of app: LCAppModel) -> String? {
        titleId(matchingName: app.appInfo.displayName() ?? "")
    }

    /// The title ID of the game of this name, ignoring case, accents and
    /// punctuation.
    func titleId(matchingName rawName: String) -> String? {
        let name = Self.comparable(rawName)
        guard !name.isEmpty else { return nil }
        return games.first { Self.comparable($0.name) == name }?.titleId
            ?? sheets.first { Self.comparable($0.name) == name }?.titleId
    }

    /// The title ID of the game an IPA's file name names, as players name
    /// them: "Mario Kart World.ipa", "MarioKartWorld-nxnative-v2.ipa",
    /// "MKW 09D00E8A5D61A000.ipa". A title ID the catalogue knows, written
    /// anywhere in the name, else the game the name is, else the game the
    /// name starts with, the longest such name. A name shorter than six
    /// letters and digits is taken only whole.
    func titleId(inFileName rawName: String) -> String? {
        var name = rawName
        if name.lowercased().hasSuffix(".ipa") { name.removeLast(4) }
        for run in Self.hexadecimalRuns(in: name) where run.count == 16 {
            if let known = game(titleId: run) { return known.titleId }
            if sheet(titleId: run) != nil { return run }
        }
        if let exact = titleId(matchingName: name) { return exact }
        let fileName = Self.comparable(name)
        let names = games.map { ($0.titleId, Self.comparable($0.name)) }
            + sheets.map { ($0.titleId, Self.comparable($0.name)) }
        return names
            .filter { $0.1.count >= 6 && fileName.hasPrefix($0.1) }
            .max { $0.1.count < $1.1.count }?.0
    }

    /// The runs of hexadecimal digits in NAME, in capitals.
    private static func hexadecimalRuns(in name: String) -> [String] {
        var runs: [String] = []
        var run = ""
        for character in name.uppercased() {
            if character.isASCII, character.isHexDigit {
                run.append(character)
            } else if !run.isEmpty {
                runs.append(run)
                run = ""
            }
        }
        if !run.isEmpty { runs.append(run) }
        return runs
    }

    private static func comparable(_ name: String) -> String {
        name.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
            .filter { $0.isLetter || $0.isNumber }
    }
}
