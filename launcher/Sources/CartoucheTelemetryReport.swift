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
    /// The memory limit iOS sets for Cartouche, which its games share.
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
