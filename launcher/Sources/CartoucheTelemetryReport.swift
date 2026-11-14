//
//  CartoucheTelemetryReport.swift
//  Cartouche
//
//  What Cartouche sends to its telemetry server (telemetry/README.md), and
//  what it keeps on the iPhone until the server has it: a report of each
//  game session, read from the game's log (CartoucheGameLog.swift), and
//  Cartouche's own events. Every report names this copy of Cartouche by a
//  random number of its own and nothing else of the player: no Apple ID,
//  no name of the iPhone, no file name, no address of their storage.
//
//  Platform-independent: tested on its own by launcher/Package.swift.
//

import Foundation

enum CartoucheTelemetryFormat {
    /// The version of the reports' format, which the server checks.
    static let schema = 1

    /// The JSON of a report, its keys in order.
    static func json<Report: Encodable>(_ report: Report) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return String(decoding: try encoder.encode(report), as: UTF8.self)
    }

    /// What one request sends: reports already in JSON.
    static func batch(_ bodies: [String]) -> String {
        "{\"reports\":[" + bodies.joined(separator: ",") + "]}"
    }
}

/// What every report carries: this copy of Cartouche and this iPhone.
struct CartoucheTelemetryContext: Codable, Equatable {
    /// The random number of this copy of Cartouche: a new one every 13
    /// months, and when the player erases what it sent.
    var install: String
    /// Cartouche's version.
    var cartouche: String
    /// The model identifier, such as "iPhone19,4".
    var device: String
    var ios: String
    /// The language Cartouche shows.
    var language: String?
    /// The memory limit iOS sets for Cartouche, which a game started in its
    /// place shares: in the report of such a game's session, the limit the
    /// game had at its peak (CartoucheSessionReport.memoryLimit).
    var memoryLimitMiB: Int?
    var increasedMemoryLimit: Bool?
}

/// One session of a game.
struct CartoucheSessionReport: Codable, Equatable {
    static let kind = "session"

    var schema = CartoucheTelemetryFormat.schema
    var kind = CartoucheSessionReport.kind
    /// A random number of this report: sent again, the server keeps it once.
    var id: String
    /// The random number of the session: the same when its log, read before
    /// the game ended, is read again.
    var session: String
    /// The order of the reports of this copy of Cartouche.
    var seq: Int
    var context: CartoucheTelemetryContext
    /// The game's title ID, when Cartouche knows it.
    var game: String?
    var gameVersion: String?
    /// The nxnative commit the game was built from.
    var nxnative: String?
    /// Built from changed files of nxnative.
    var nxnativeChanged: Bool?
    /// nxnative's settings the game ran with, by their variable.
    var settings: [String: String]?
    /// How long the session lasted, from its log's dates.
    var minutes: Double
    /// The reading of nxnative's log that made the measures.
    var reader = CartoucheGameLogReader.version
    var measures: CartoucheGameMeasures
    /// What the game's own process wrote, when it ran behind the console.
    var process: CartoucheGameProcess?

    init(id: String, session: String, seq: Int, context: CartoucheTelemetryContext, game: String?, gameVersion: String?,
         nxnative: String?, nxnativeChanged: Bool?, settings: [String: String]?, minutes: Double, measures: CartoucheGameMeasures,
         process: CartoucheGameProcess? = nil) {
        self.id = id
        self.session = session
        self.seq = seq
        self.context = context
        self.game = game
        self.gameVersion = gameVersion
        self.nxnative = nxnative
        self.nxnativeChanged = nxnativeChanged
        self.settings = settings.flatMap { CartoucheTelemetrySettings.cleaned($0) }
        self.minutes = minutes
        self.measures = measures
        self.process = process
    }

    /// The memory limit a session's report gives (memoryLimitMiB): for a
    /// game in Cartouche's place, the one it had at its peak, as its log
    /// tells it (CartoucheGameLogReader.limitAtPeakMiB), and not CARTOUCHE,
    /// the one Cartouche read when it read the log, after the game: iOS
    /// raises the limit as Game Mode comes on, and one iPhone gave 6,144 or
    /// 8,192 MiB for the same game. Within a few MiB of it, the log's,
    /// rounded to the MiB, is the same limit as Cartouche's, read to the
    /// byte. Behind the console, the game's process had a limit of its own
    /// (PROCESS), and the report keeps Cartouche's.
    static func memoryLimit(cartouche: Int?, atPeak: Int?, process: CartoucheGameProcess?) -> Int? {
        guard process == nil, let atPeak else { return cartouche }
        if let cartouche, abs(cartouche - atPeak) <= 2 { return cartouche }
        return atPeak
    }

    // The context and the measures sit beside the report's own keys.
    private enum CodingKeys: String, CodingKey {
        case schema, kind, id, session, seq, game, gameVersion, nxnative, nxnativeChanged, settings, minutes, reader, process
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schema = try container.decode(Int.self, forKey: .schema)
        kind = try container.decode(String.self, forKey: .kind)
        id = try container.decode(String.self, forKey: .id)
        session = try container.decode(String.self, forKey: .session)
        seq = try container.decode(Int.self, forKey: .seq)
        game = try container.decodeIfPresent(String.self, forKey: .game)
        gameVersion = try container.decodeIfPresent(String.self, forKey: .gameVersion)
        nxnative = try container.decodeIfPresent(String.self, forKey: .nxnative)
        nxnativeChanged = try container.decodeIfPresent(Bool.self, forKey: .nxnativeChanged)
        settings = try container.decodeIfPresent([String: String].self, forKey: .settings)
        minutes = try container.decode(Double.self, forKey: .minutes)
        reader = try container.decode(Int.self, forKey: .reader)
        process = try container.decodeIfPresent(CartoucheGameProcess.self, forKey: .process)
        context = try CartoucheTelemetryContext(from: decoder)
        measures = try CartoucheGameMeasures(from: decoder)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schema, forKey: .schema)
        try container.encode(kind, forKey: .kind)
        try container.encode(id, forKey: .id)
        try container.encode(session, forKey: .session)
        try container.encode(seq, forKey: .seq)
        try container.encodeIfPresent(game, forKey: .game)
        try container.encodeIfPresent(gameVersion, forKey: .gameVersion)
        try container.encodeIfPresent(nxnative, forKey: .nxnative)
        try container.encodeIfPresent(nxnativeChanged, forKey: .nxnativeChanged)
        try container.encodeIfPresent(settings, forKey: .settings)
        try container.encode(minutes, forKey: .minutes)
        try container.encode(reader, forKey: .reader)
        try container.encodeIfPresent(process, forKey: .process)
        try context.encode(to: encoder)
        try measures.encode(to: encoder)
    }
}

/// What a game's own process wrote of its memory, every two seconds, when
/// it ran behind the console (launcher/LiveProcessSupport/CartoucheGuest.m),
/// and how it ended. iOS sets that process a limit of its own, which can
/// differ from Cartouche's.
struct CartoucheGameProcess: Codable, Equatable {
    /// A size the game's screen took, such as an iPhone Duo's unfolded.
    struct Screen: Codable, Equatable {
        /// Minutes after the game started.
        var minute: Double
        /// In points.
        var width: Int
        var height: Int
        /// The memory the game used as it took that size.
        var footprintMiB: Int?
    }

    /// The sizes a report carries: the last ones, up to how the game ended.
    static let screensKept = 10

    /// The limit iOS set for the game's process.
    var limitMiB: Int
    /// The most the game's process used, as iOS counts it.
    var peakMiB: Int
    /// What iOS still let it use at its last reading, two seconds or less
    /// before it ended.
    var lastAvailableMiB: Int?
    /// The player quit the game; false when iOS ended it.
    var quit: Bool?
    var screens: [Screen]?

    init(limitMiB: Int, peakMiB: Int, lastAvailableMiB: Int?, quit: Bool?, screens: [Screen]) {
        self.limitMiB = limitMiB
        self.peakMiB = peakMiB
        self.lastAvailableMiB = lastAvailableMiB
        self.quit = quit
        self.screens = screens.isEmpty ? nil : Array(screens.suffix(Self.screensKept))
    }
}

extension CartoucheGameMeasures {
    /// The measures of a session that ran behind the console, with what its
    /// own process wrote: the system's own peak, and how it ended when its
    /// log does not say, as a crash does. NEAR LIMIT: its last reading was
    /// close to the limit iOS set for it, as that of a game iOS stops for
    /// its memory is.
    func with(_ process: CartoucheGameProcess, nearLimit: Bool) -> CartoucheGameMeasures {
        var measures = self
        var memory = measures.memory ?? Memory()
        memory.peakMiB = max(process.peakMiB, memory.peakMiB ?? 0)
        memory.exactPeak = true
        measures.memory = memory
        let logged = measures.end?.kind
        guard logged != "crash", logged != "boot-failed" else { return measures }
        if process.quit == true {
            measures.end = End(kind: "quit")
        } else if nearLimit {
            measures.end = End(kind: "memory-likely")
        }
        return measures
    }
}

/// A value of an event: text, a number or a yes or no.
enum CartoucheTelemetryValue: Codable, Equatable {
    case text(String)
    case number(Double)
    case flag(Bool)

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let flag = try? container.decode(Bool.self) {
            self = .flag(flag)
        } else if let number = try? container.decode(Double.self) {
            self = .number(number)
        } else {
            self = .text(try container.decode(String.self))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .text(let text): try container.encode(text)
        case .number(let number): try container.encode(number)
        case .flag(let flag): try container.encode(flag)
        }
    }
}

/// Something Cartouche did or met: an install, an update, an error.
struct CartoucheEventReport: Codable, Equatable {
    static let kind = "event"
    /// What an event's name may be: "game.installed", "error".
    static let names = try! NSRegularExpression(pattern: "^[a-z][a-zA-Z0-9]*(\\.[a-z][a-zA-Z0-9]*){0,3}$")
    static let maximumFields = 24
    static let maximumText = 160

    var schema = CartoucheTelemetryFormat.schema
    var kind = CartoucheEventReport.kind
    var id: String
    var seq: Int
    var context: CartoucheTelemetryContext
    var name: String
    var game: String?
    var fields: [String: CartoucheTelemetryValue]?

    /// Nil when NAME is not an event's name. Fields beyond the first 24, with
    /// a key that is not a word, are left out; text is cut to 160 characters.
    init?(id: String, seq: Int, context: CartoucheTelemetryContext, name: String, game: String? = nil,
          fields: [String: CartoucheTelemetryValue] = [:]) {
        let range = NSRange(name.startIndex..., in: name)
        guard name.count <= 48, Self.names.firstMatch(in: name, range: range) != nil else { return nil }
        self.id = id
        self.seq = seq
        self.context = context
        self.name = name
        self.game = game
        var kept: [String: CartoucheTelemetryValue] = [:]
        for key in fields.keys.sorted() where kept.count < Self.maximumFields && CartoucheTelemetrySettings.isWord(key) {
            switch fields[key] {
            case .text(let text)?: kept[key] = .text(String(text.prefix(Self.maximumText)))
            case .number(let number)? where number.isFinite: kept[key] = .number(number)
            case .flag(let flag)?: kept[key] = .flag(flag)
            default: break
            }
        }
        self.fields = kept.isEmpty ? nil : kept
    }

    private enum CodingKeys: String, CodingKey {
        case schema, kind, id, seq, name, game, fields
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schema = try container.decode(Int.self, forKey: .schema)
        kind = try container.decode(String.self, forKey: .kind)
        id = try container.decode(String.self, forKey: .id)
        seq = try container.decode(Int.self, forKey: .seq)
        name = try container.decode(String.self, forKey: .name)
        game = try container.decodeIfPresent(String.self, forKey: .game)
        fields = try container.decodeIfPresent([String: CartoucheTelemetryValue].self, forKey: .fields)
        context = try CartoucheTelemetryContext(from: decoder)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schema, forKey: .schema)
        try container.encode(kind, forKey: .kind)
        try container.encode(id, forKey: .id)
        try container.encode(seq, forKey: .seq)
        try container.encode(name, forKey: .name)
        try container.encodeIfPresent(game, forKey: .game)
        try container.encodeIfPresent(fields, forKey: .fields)
        try context.encode(to: encoder)
    }
}

/// nxnative's settings as a report carries them: its variables, with short
/// values, and nothing that could be a path or a name.
enum CartoucheTelemetrySettings {
    static let maximum = 40
    private static let variable = try! NSRegularExpression(pattern: "^DM_[A-Z0-9_]{1,40}$")
    private static let value = try! NSRegularExpression(pattern: "^[A-Za-z0-9._:+-]{1,32}$")
    private static let word = try! NSRegularExpression(pattern: "^[a-zA-Z][a-zA-Z0-9]{0,31}$")

    static func cleaned(_ settings: [String: String]) -> [String: String]? {
        var kept: [String: String] = [:]
        for key in settings.keys.sorted() where kept.count < maximum {
            guard let text = settings[key], matches(variable, key), matches(value, text) else { continue }
            kept[key] = text
        }
        return kept.isEmpty ? nil : kept
    }

    static func isWord(_ text: String) -> Bool {
        matches(word, text)
    }

    private static func matches(_ expression: NSRegularExpression, _ text: String) -> Bool {
        expression.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }
}

/// The reports Cartouche has not sent yet, kept until the server has them.
struct CartoucheTelemetryQueue: Codable, Equatable {
    struct Entry: Codable, Equatable {
        var id: String
        var created: Date
        /// The report's JSON.
        var body: String
    }

    /// The newest reports are kept beyond this many.
    static let capacity = 300
    /// A report the server never took is dropped after a month.
    static let maximumAge: TimeInterval = 30 * 86_400
    static let batchCount = 25
    static let batchBytes = 60_000

    private(set) var entries: [Entry] = []
    private(set) var failures = 0
    private(set) var retryAfter: Date?

    var isEmpty: Bool { entries.isEmpty }

    mutating func add(_ entry: Entry) {
        guard !entries.contains(where: { $0.id == entry.id }) else { return }
        entries.append(entry)
        if entries.count > Self.capacity {
            entries.removeFirst(entries.count - Self.capacity)
        }
    }

    /// Drops the reports older than a month.
    mutating func prune(now: Date) {
        entries.removeAll { now.timeIntervalSince($0.created) > Self.maximumAge }
    }

    /// The oldest reports one request can carry, unless the server asked to
    /// wait or there is none.
    func batch(now: Date) -> [Entry]? {
        if let retryAfter, retryAfter > now { return nil }
        var batch: [Entry] = []
        var bytes = 0
        for entry in entries {
            let size = entry.body.utf8.count + 1
            if batch.count == Self.batchCount || (!batch.isEmpty && bytes + size > Self.batchBytes) { break }
            batch.append(entry)
            bytes += size
        }
        return batch.isEmpty ? nil : batch
    }

    /// The server took these, or refused them for good: they go.
    mutating func remove(_ ids: Set<String>) {
        entries.removeAll { ids.contains($0.id) }
        failures = 0
        retryAfter = nil
    }

    /// The request failed: wait longer after each failure, from a minute to
    /// six hours, or as long as the server asked.
    mutating func failed(now: Date, serverWait: TimeInterval? = nil) {
        failures += 1
        let wait = serverWait ?? min(60 * pow(2, Double(min(failures - 1, 12))), 6 * 3_600)
        retryAfter = now.addingTimeInterval(max(wait, 1))
    }

    mutating func removeAll() {
        entries.removeAll()
        failures = 0
        retryAfter = nil
    }
}

/// The logs whose sessions Cartouche has read. nxnative renames a game's
/// log.txt to log.prev.txt when the game starts again: the log keeps its
/// creation date, which tells it from the next one.
struct CartoucheTelemetryLogs: Codable, Equatable {
    struct Log: Codable, Equatable {
        var key: String
        var session: String
        var bytes: Int
    }

    static let capacity = 400
    private(set) var logs: [Log] = []

    /// A log, by the data folder it is in and when it was created.
    static func key(folder: String, created: Date) -> String {
        folder + "|" + String(Int64((created.timeIntervalSince1970 * 1000).rounded()))
    }

    /// Whether the log is new, or has grown since it was read: a game that
    /// was still running then.
    func needsReading(key: String, bytes: Int) -> Bool {
        guard let log = logs.first(where: { $0.key == key }) else { return true }
        return bytes > log.bytes
    }

    func session(of key: String) -> String? {
        logs.first { $0.key == key }?.session
    }

    mutating func record(key: String, session: String, bytes: Int) {
        logs.removeAll { $0.key == key }
        logs.append(Log(key: key, session: session, bytes: bytes))
        if logs.count > Self.capacity {
            logs.removeFirst(logs.count - Self.capacity)
        }
    }
}

/// The games Cartouche started, behind the console or in its own place,
/// and what the process of each that ran behind the console wrote of its
/// memory as it ended (CartoucheGuest.m). A session's log goes with the
/// game that started last before nxnative created it in its data folder,
/// and only if that game still ran then: the file the process writes
/// outlives the game, by a few seconds when it lingers, and the same game
/// started again in Cartouche's place right after, in the same data
/// folder, ran without that process.
struct CartoucheTelemetryRuns: Codable, Equatable {
    /// A game Cartouche started.
    struct Run: Codable, Equatable {
        /// Its data folder.
        var folder: String
        var started: Date
        /// Behind the console, rather than in Cartouche's place.
        var behind: Bool
        /// When it ended behind the console, as the console saw it: nil
        /// while it runs, once Cartouche stopped with it, and in Cartouche's
        /// place, which Cartouche leaves to the game.
        var ended: Date?
        /// What its process wrote last, as it ended behind the console.
        var process: CartoucheGameProcess?
        /// That reading was close to the limit iOS set for the process.
        var nearLimit: Bool?
    }

    /// The last reading a game's process wrote behind the console, as
    /// Cartouche finds it after it stopped with the game.
    struct Reading: Equatable {
        /// The game's data folder.
        var folder: String
        /// When the process started, and when it wrote last.
        var started: Date
        var updated: Date
        var process: CartoucheGameProcess
        var nearLimit: Bool
    }

    static let capacity = 20
    /// Cartouche notes a game's start before the game's process starts,
    /// and its end once the process has ended: a second more or less at
    /// the start changes nothing, as games do not start a second apart.
    private static let slack: TimeInterval = 1
    /// A game's process writes every two seconds.
    private static let readingEvery: TimeInterval = 2

    private(set) var runs: [Run] = []

    /// A game starts in FOLDER at STARTED, behind the console or in
    /// Cartouche's place.
    mutating func start(folder: String, at started: Date, behind: Bool) {
        guard !runs.contains(where: { $0.folder == folder && $0.started == started }) else { return }
        insert(Run(folder: folder, started: started, behind: behind))
    }

    /// The game that started behind the console in FOLDER at STARTED
    /// ended at ENDED, its process's last reading PROCESS, close to the
    /// limit with NEAR LIMIT.
    mutating func end(folder: String, started: Date, at ended: Date, process: CartoucheGameProcess?, nearLimit: Bool) {
        let run = Run(folder: folder, started: started, behind: true, ended: ended, process: process, nearLimit: nearLimit)
        if let index = runs.firstIndex(where: { $0.folder == folder && $0.started == started }) {
            runs[index] = run
        } else {
            insert(run)
        }
    }

    /// What the process of the game that ran behind the console wrote, for
    /// the session whose log nxnative created in FOLDER at CREATED, and
    /// whether it was close to its limit: what it wrote as the game ended;
    /// for a game Cartouche stopped with, LAST, the reading Cartouche finds
    /// when it opens again, if its process started with that game, before
    /// the log, and still ran as nxnative created it. Nil for a session in
    /// Cartouche's place, and for one that started after the game behind
    /// the console ended.
    func process(folder: String, created: Date, last: Reading?) -> (process: CartoucheGameProcess, nearLimit: Bool)? {
        guard let run = runs.last(where: { $0.folder == folder && $0.started <= created.addingTimeInterval(Self.slack) }),
              run.behind else { return nil }
        if let ended = run.ended {
            guard created <= ended, let process = run.process else { return nil }
            return (process, run.nearLimit ?? false)
        }
        guard let last, last.folder == folder, last.started >= run.started.addingTimeInterval(-Self.slack),
              last.started <= created.addingTimeInterval(Self.slack),
              last.updated >= created.addingTimeInterval(-Self.readingEvery) else { return nil }
        return (last.process, last.nearLimit)
    }

    private mutating func insert(_ run: Run) {
        runs.append(run)
        runs.sort { $0.started < $1.started }
        if runs.count > Self.capacity {
            runs.removeFirst(runs.count - Self.capacity)
        }
    }
}

/// A launch of Cartouche, from its start until the console has its games
/// and app.opened is sent, or until a game takes its process in its place.
/// An iPhone stops an app without a word, whether it crashed, iOS ended it
/// or the player closed it: Cartouche keeps each launch from its start
/// (CartoucheLaunchMark), and the next launch says when one stopped before
/// it got there, with app.unfinished, and how far it got.
struct CartoucheTelemetryLaunch: Codable, Equatable {
    enum Ending: String, Codable {
        /// Cartouche sent app.opened.
        case opened
        /// A game started in Cartouche's place, which takes its process.
        case game
    }

    /// How often a launch that has not got there yet says it still runs.
    static let noteEvery: TimeInterval = 5

    /// The version of Cartouche that launched: the next launch may be of
    /// another, once the player updated it.
    var version: String
    var started: Date
    /// When it was last seen: at each step, and every few seconds while
    /// it runs.
    var noted: Date
    /// LiveContainer listed the installed apps, or five seconds passed.
    var listed = false
    /// The check of LiveContainer's certificate ended, or half a minute
    /// passed.
    var checked = false
    /// Cartouche was in the background when it was last seen.
    var background = false
    var ended: Ending?

    init(version: String, started: Date) {
        self.version = version
        self.started = started
        noted = started
    }

    /// The fields of the app.unfinished event a launch at NOW sends for
    /// this one: how far it got, how long it was seen, to within a few
    /// seconds, and how long before.
    func fields(now: Date) -> [String: CartoucheTelemetryValue] {
        [
            "version": .text(version),
            "listed": .flag(listed),
            "checked": .flag(checked),
            "background": .flag(background),
            "seconds": .number(max(noted.timeIntervalSince(started), 0).rounded()),
            "minutesBefore": .number((max(now.timeIntervalSince(started), 0) / 60).rounded()),
        ]
    }
}

/// Where Cartouche keeps its launch until the next one: in its defaults,
/// which a crash leaves as they were.
struct CartoucheLaunchMark {
    static let standard = CartoucheLaunchMark(defaults: .standard)
    static let key = "CartoucheLaunch"
    let defaults: UserDefaults

    /// The launch, as it was last noted.
    var launch: CartoucheTelemetryLaunch? {
        defaults.data(forKey: Self.key).flatMap { try? JSONDecoder().decode(CartoucheTelemetryLaunch.self, from: $0) }
    }

    /// Whether a launch is noted that has not got there yet.
    var isGoingOn: Bool {
        launch.map { $0.ended == nil } ?? false
    }

    /// A launch of VERSION starts AT: the one before it, if it never got
    /// there.
    func begin(version: String, at date: Date) -> CartoucheTelemetryLaunch? {
        let last = launch
        write(CartoucheTelemetryLaunch(version: version, started: date))
        return last?.ended == nil ? last : nil
    }

    /// What the launch got to, AT: nothing once it got there.
    func note(at date: Date, _ change: (inout CartoucheTelemetryLaunch) -> Void = { _ in }) {
        guard var noted = launch, noted.ended == nil else { return }
        change(&noted)
        noted.noted = max(noted.noted, date)
        write(noted)
    }

    func clear() {
        defaults.removeObject(forKey: Self.key)
    }

    private func write(_ launch: CartoucheTelemetryLaunch) {
        guard let data = try? JSONEncoder().encode(launch) else { return }
        defaults.set(data, forKey: Self.key)
    }
}
