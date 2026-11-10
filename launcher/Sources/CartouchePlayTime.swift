//
//  CartouchePlayTime.swift
//  Cartouche
//
//  How long the player played each game, and the space it takes on this
//  iPhone. A game counts its own play time, the time it is in front and
//  active, in its data folder (launcher/Guest/CartouchePlayTimeCounter.m,
//  Library/Cartouche/PlayTime.plist). Cartouche reads it there and keeps
//  what it read (CartouchePlayTimeRecord), so that the time stays once the
//  game is uninstalled with its saves, and shows for a game that is only
//  in the player's games folder. The space is measured as LiveContainer's
//  storage page measures it: what each file takes on the disk, links not
//  followed.
//
//  Foundation only, so that it is tested on a Mac (swift test
//  --package-path launcher); CartoucheGameStats.swift shows it.
//

import Foundation

/// A game's play time, as its counter writes it.
struct CartouchePlayTime: Codable, Hashable {
    /// The time the game was in front and active, in seconds.
    var seconds: Double
    /// How many times the game started and came to the front.
    var sessions: Int
    var firstPlayed: Date?
    var lastPlayed: Date?

    /// The counter's file in the game's data folder.
    static let file = "Library/Cartouche/PlayTime.plist"
    /// The counter's format. A later one may mean something else: it is
    /// not read.
    static let version = 1

    init(seconds: Double = 0, sessions: Int = 0, firstPlayed: Date? = nil, lastPlayed: Date? = nil) {
        self.seconds = seconds
        self.sessions = sessions
        self.firstPlayed = firstPlayed
        self.lastPlayed = lastPlayed
    }

    /// What the counter wrote, or nil for another file.
    init?(plist: [String: Any]) {
        guard let seconds = Self.number(plist["seconds"]), seconds.isFinite, seconds >= 0 else { return nil }
        if let version = Self.number(plist["version"]), version > Double(Self.version) { return nil }
        self.seconds = seconds
        let sessions = Self.number(plist["sessions"]) ?? 0
        self.sessions = sessions.isFinite ? Int(max(0, min(sessions, Double(Int32.max)))) : 0
        firstPlayed = plist["firstPlayed"] as? Date
        lastPlayed = plist["lastPlayed"] as? Date
    }

    /// The counter's file in the data folder HOME, if the game wrote one.
    static func read(home: URL) -> CartouchePlayTime? {
        guard let data = try? Data(contentsOf: home.appendingPathComponent(file)),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        else { return nil }
        return CartouchePlayTime(plist: plist)
    }

    /// The same data folder's time, read twice: the most of each, since the
    /// count only grows.
    func merged(with other: CartouchePlayTime) -> CartouchePlayTime {
        CartouchePlayTime(seconds: max(seconds, other.seconds), sessions: max(sessions, other.sessions),
                          firstPlayed: Self.earliest(firstPlayed, other.firstPlayed),
                          lastPlayed: Self.latest(lastPlayed, other.lastPlayed))
    }

    /// The times of two data folders together.
    static func + (a: CartouchePlayTime, b: CartouchePlayTime) -> CartouchePlayTime {
        CartouchePlayTime(seconds: a.seconds + b.seconds, sessions: a.sessions + b.sessions,
                          firstPlayed: earliest(a.firstPlayed, b.firstPlayed), lastPlayed: latest(a.lastPlayed, b.lastPlayed))
    }

    private static func number(_ value: Any?) -> Double? {
        switch value {
        case let number as NSNumber: return number.doubleValue
        case let value as Double: return value
        case let value as Int: return Double(value)
        default: return nil
        }
    }

    private static func earliest(_ a: Date?, _ b: Date?) -> Date? {
        guard let a, let b else { return a ?? b }
        return min(a, b)
    }

    private static func latest(_ a: Date?, _ b: Date?) -> Date? {
        guard let a, let b else { return a ?? b }
        return max(a, b)
    }
}

/// What Cartouche read of each game's play time, by the game's bundle ID,
/// then by data folder: the time of a data folder erased with the game
/// stays, and adds up with the next one's.
struct CartouchePlayTimeRecord: Codable, Equatable {
    struct Game: Codable, Equatable {
        /// The game's title ID, to find the time of a game that is only in
        /// the games folder.
        var titleId: String?
        /// By data folder name.
        var folders: [String: CartouchePlayTime] = [:]
    }

    var games: [String: Game] = [:]

    /// Notes TIME, read in the data folder FOLDER of the game BUNDLEID;
    /// returns whether the record changed.
    @discardableResult
    mutating func note(_ time: CartouchePlayTime, bundleId: String, titleId: String?, folder: String) -> Bool {
        var game = games[bundleId] ?? Game()
        let merged = game.folders[folder].map { $0.merged(with: time) } ?? time
        if game.folders[folder] == merged, titleId == nil || game.titleId == titleId { return false }
        game.folders[folder] = merged
        if let titleId { game.titleId = titleId }
        games[bundleId] = game
        return true
    }

    /// The game's time on this iPhone, every data folder's together: by its
    /// bundle ID, else by its title ID.
    func total(bundleId: String?, titleId: String? = nil) -> CartouchePlayTime? {
        var found: [Game] = []
        if let bundleId, let game = games[bundleId] {
            found = [game]
        } else if let titleId {
            found = games.values.filter { $0.titleId == titleId }
        }
        let times = found.flatMap(\.folders.values)
        guard !times.isEmpty else { return nil }
        return times.reduce(CartouchePlayTime(), +)
    }
}

/// The space a game takes on this iPhone.
struct CartoucheGameSize: Codable, Hashable {
    /// Its bundle: the game itself.
    var bundle: UInt64
    /// Its data folders: saves, settings and caches.
    var data: UInt64

    var total: UInt64 { bundle + data }

    /// The space the files under FOLDER take on the disk, as LiveContainer's
    /// storage page counts it (LCStorageManagementModel.calculateSize): each
    /// regular file's allocated size, links not followed.
    static func measure(_ folder: URL) -> UInt64 {
        let keys: [URLResourceKey] = [.isRegularFileKey, .totalFileAllocatedSizeKey, .fileAllocatedSizeKey, .fileSizeKey]
        guard let enumerator = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: keys) else { return 0 }
        let wanted = Set(keys)
        var total: UInt64 = 0
        for case let url as URL in enumerator {
            guard let values = try? url.resourceValues(forKeys: wanted), values.isRegularFile == true else { continue }
            let size = values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? values.fileSize ?? 0
            total += UInt64(max(size, 0))
        }
        return total
    }
}

/// A game's folders on this iPhone, as LiveContainer keeps them.
struct CartoucheGameFolders {
    /// The game's bundle ID, as its IPA gave it.
    let bundleId: String
    /// Its title ID, when Cartouche knows it.
    let titleId: String?
    let bundle: URL
    /// Its data folders in Cartouche, by name.
    let data: [String: URL]

    /// What tells one install of the bundle from the next: its path, and
    /// its Info.plist's date and size.
    var bundleKey: String {
        let values = try? bundle.appendingPathComponent("Info.plist")
            .resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
        let date = values?.contentModificationDate?.timeIntervalSince1970 ?? 0
        return "\(bundle.path)|\(date)|\(values?.fileSize ?? 0)"
    }

    /// The play time each data folder holds, by its name.
    func playTimes() -> [String: CartouchePlayTime] {
        data.compactMapValues { CartouchePlayTime.read(home: $0) }
    }

    /// The space the game takes; BUNDLE when the bundle was measured
    /// already, since it changes only with an install.
    func measure(bundle known: UInt64? = nil) -> CartoucheGameSize {
        CartoucheGameSize(bundle: known ?? CartoucheGameSize.measure(bundle),
                          data: data.values.reduce(UInt64(0)) { $0 + CartoucheGameSize.measure($1) })
    }
}
