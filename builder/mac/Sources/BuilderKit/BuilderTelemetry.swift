//
//  BuilderTelemetry.swift
//  Cartouche Builder
//
//  What Cartouche Builder sends to Cartouche's telemetry server
//  (telemetry/README.md#cartouche-builder), as Cartouche does from the
//  iPhone: events of its own, named builder.*, each with this copy of the
//  app's random number (a new one every 13 months, and when the player
//  erases what it sent), its version, the Mac's model and macOS's version.
//  Never a file name, a path, a message, the Mac's name, an address or the
//  player's Apple account: an event's fields are words, numbers and yes or
//  no. On unless the player turns it off in the settings; what the server
//  has not taken yet waits in the builder's folder (telemetry.json), a
//  month at most.
//

import Foundation

/// A value of an event's field: text, a number or a yes or no.
public enum TelemetryValue: Codable, Equatable, Sendable {
    case text(String)
    case number(Double)
    case flag(Bool)

    public static func count(_ value: Int) -> TelemetryValue { .number(Double(value)) }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let flag = try? container.decode(Bool.self) {
            self = .flag(flag)
        } else if let number = try? container.decode(Double.self) {
            self = .number(number)
        } else {
            self = .text(try container.decode(String.self))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .text(let text): try container.encode(text)
        case .number(let number): try container.encode(number)
        case .flag(let flag): try container.encode(flag)
        }
    }
}

/// What every report carries: this copy of the app and this Mac, in the
/// fields the server has for Cartouche's.
public struct TelemetryContext: Codable, Equatable, Sendable {
    public var install: String
    /// Cartouche Builder's version.
    public var cartouche: String
    /// The Mac's model identifier, such as "Mac16,12".
    public var device: String
    /// macOS's version.
    public var ios: String
    /// The language the app shows.
    public var language: String?

    public init(install: String, cartouche: String, device: String, ios: String, language: String? = nil) {
        self.install = install
        self.cartouche = cartouche
        self.device = device
        self.ios = ios
        self.language = language
    }
}

/// Something the app did or met: a build, an update, an error.
public struct TelemetryEvent: Codable, Equatable, Sendable {
    public static let kind = "event"
    public static let maximumFields = 24
    public static let maximumText = 160

    public var schema = TelemetryFormat.schema
    public var kind = TelemetryEvent.kind
    public var id: String
    public var seq: Int
    public var context: TelemetryContext
    public var name: String
    /// A game's title ID, sixteen hexadecimal digits.
    public var game: String?
    public var fields: [String: TelemetryValue]?

    /// Nil when NAME is not an event's name. A game that is not a title ID
    /// is left out, and so are the fields beyond the first 24 and those
    /// whose key is not a word; text is cut to 160 characters.
    public init?(id: String, seq: Int, context: TelemetryContext, name: String, game: String? = nil,
                 fields: [String: TelemetryValue] = [:]) {
        guard name.count <= 48, TelemetryFormat.matches(TelemetryFormat.eventName, name) else { return nil }
        self.id = id
        self.seq = seq
        self.context = context
        self.name = name
        self.game = game.map { $0.uppercased() }.flatMap { TelemetryFormat.matches(TelemetryFormat.titleID, $0) ? $0 : nil }
        var kept: [String: TelemetryValue] = [:]
        for key in fields.keys.sorted() where kept.count < Self.maximumFields && TelemetryFormat.matches(TelemetryFormat.word, key) {
            switch fields[key] {
            case .text(let text)?: kept[key] = .text(String(text.prefix(Self.maximumText)))
            case .number(let number)? where number.isFinite: kept[key] = .number(number)
            case .flag(let flag)?: kept[key] = .flag(flag)
            default: break
            }
        }
        self.fields = kept.isEmpty ? nil : kept
    }

    // The context sits beside the report's own keys.
    private enum CodingKeys: String, CodingKey {
        case schema, kind, id, seq, name, game, fields
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schema = try container.decode(Int.self, forKey: .schema)
        kind = try container.decode(String.self, forKey: .kind)
        id = try container.decode(String.self, forKey: .id)
        seq = try container.decode(Int.self, forKey: .seq)
        name = try container.decode(String.self, forKey: .name)
        game = try container.decodeIfPresent(String.self, forKey: .game)
        fields = try container.decodeIfPresent([String: TelemetryValue].self, forKey: .fields)
        context = try TelemetryContext(from: decoder)
    }

    public func encode(to encoder: Encoder) throws {
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

public enum TelemetryFormat {
    /// The version of the reports' format, which the server checks.
    public static let schema = 1

    static let eventName = expression("^[a-z][a-zA-Z0-9]*(\\.[a-z][a-zA-Z0-9]*){0,3}$")
    static let word = expression("^[a-zA-Z][a-zA-Z0-9]{0,31}$")
    static let titleID = expression("^[0-9A-F]{16}$")
    static let version = expression("^\\d{1,4}(\\.\\d{1,4}){1,2}$")
    static let model = expression("^[A-Za-z]{2,16}\\d{1,4},\\d{1,4}$")

    /// The JSON of a report, its keys in order.
    public static func json<Report: Encodable>(_ report: Report) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return String(decoding: try encoder.encode(report), as: UTF8.self)
    }

    /// What one request sends: reports already in JSON.
    public static func batch(_ bodies: [String]) -> String {
        "{\"reports\":[" + bodies.joined(separator: ",") + "]}"
    }

    static func matches(_ expression: NSRegularExpression, _ text: String) -> Bool {
        expression.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    private static func expression(_ pattern: String) -> NSRegularExpression {
        // The patterns above are fixed: one that does not compile is a bug.
        try! NSRegularExpression(pattern: pattern)
    }
}

/// The reports not sent yet, kept until the server has them: the same
/// rules as Cartouche's (CartoucheTelemetryQueue).
public struct TelemetryQueue: Codable, Equatable, Sendable {
    public struct Entry: Codable, Equatable, Sendable {
        public var id: String
        public var created: Date
        /// The report's JSON.
        public var body: String

        public init(id: String, created: Date, body: String) {
            self.id = id
            self.created = created
            self.body = body
        }
    }

    /// The newest reports are kept beyond this many.
    public static let capacity = 300
    /// A report the server never took is dropped after a month.
    public static let maximumAge: TimeInterval = 30 * 86_400
    public static let batchCount = 25
    public static let batchBytes = 60_000

    public private(set) var entries: [Entry] = []
    public private(set) var failures = 0
    public private(set) var retryAfter: Date?

    public init() {}

    public mutating func add(_ entry: Entry) {
        guard !entries.contains(where: { $0.id == entry.id }) else { return }
        entries.append(entry)
        if entries.count > Self.capacity {
            entries.removeFirst(entries.count - Self.capacity)
        }
    }

    /// Drops the reports older than a month.
    public mutating func prune(now: Date) {
        entries.removeAll { now.timeIntervalSince($0.created) > Self.maximumAge }
    }

    /// The oldest reports one request can carry, unless the server asked to
    /// wait or there is none.
    public func batch(now: Date) -> [Entry]? {
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
    public mutating func remove(_ ids: Set<String>) {
        entries.removeAll { ids.contains($0.id) }
        failures = 0
        retryAfter = nil
    }

    /// The request failed: wait longer after each failure, from a minute to
    /// six hours, or as long as the server asked.
    public mutating func failed(now: Date, serverWait: TimeInterval? = nil) {
        failures += 1
        let wait = serverWait ?? min(60 * pow(2, Double(min(failures - 1, 12))), 6 * 3_600)
        retryAfter = now.addingTimeInterval(max(wait, 1))
    }

    public mutating func removeAll() {
        entries.removeAll()
        failures = 0
        retryAfter = nil
    }
}

/// An event the app sends: its name, the game it is of, its fields
/// (BuilderTelemetry.batchEvents).
public struct BatchEvent: Equatable, Sendable {
    public var name: String
    public var game: String?
    public var fields: [String: TelemetryValue]

    public init(_ name: String, game: String? = nil, fields: [String: TelemetryValue] = [:]) {
        self.name = name
        self.game = game
        self.fields = fields
    }
}

/// The app's telemetry: its switch, its queue and its sending.
@MainActor
public final class BuilderTelemetry: ObservableObject {
    /// Where the docs say what leaves the Mac.
    public static let privacy = URL(string: "https://github.com/clabeuhtegrite/Cartouche/blob/main/docs/privacy.md#cartouche-builder")!
    /// A copy of the app takes a new random number after 13 months.
    public static let installLifetime: TimeInterval = 395 * 86_400

    /// The server, from the app's Info.plist (CartoucheTelemetryURL, from
    /// app/config.env as for Cartouche), or nil for a build that has none.
    public nonisolated static var bundledEndpoint: URL? {
        guard let text = Bundle.main.object(forInfoDictionaryKey: "CartoucheTelemetryURL") as? String,
              let url = URL(string: text.trimmingCharacters(in: .whitespaces)), url.scheme == "https", url.host != nil else {
            return nil
        }
        return url
    }

    /// What the app keeps of its telemetry. A value an older version did not
    /// keep takes its default.
    struct State: Codable {
        var isOn = true
        var install: String
        var installSince: Date
        var seq = 0
        var queue = TelemetryQueue()
        var sent = 0
        var lastSent: Date?
        var lastVersion: String?

        init() {
            install = BuilderTelemetry.newNumber()
            installSince = Date()
        }

        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            isOn = try values.decodeIfPresent(Bool.self, forKey: .isOn) ?? true
            install = try values.decodeIfPresent(String.self, forKey: .install) ?? BuilderTelemetry.newNumber()
            installSince = try values.decodeIfPresent(Date.self, forKey: .installSince) ?? Date()
            seq = try values.decodeIfPresent(Int.self, forKey: .seq) ?? 0
            queue = (try? values.decodeIfPresent(TelemetryQueue.self, forKey: .queue)) ?? TelemetryQueue()
            sent = try values.decodeIfPresent(Int.self, forKey: .sent) ?? 0
            lastSent = try values.decodeIfPresent(Date.self, forKey: .lastSent)
            lastVersion = try values.decodeIfPresent(String.self, forKey: .lastVersion)
        }
    }

    @Published public private(set) var isOn: Bool
    @Published public private(set) var sent: Int
    @Published public private(set) var waiting: Int
    @Published public private(set) var lastSent: Date?
    @Published public private(set) var isErasing = false

    /// The language the app shows, sent with each report.
    public var language: String?

    private var state: State
    private let file: URL?
    private let endpoint: URL?
    private let version: String
    private let device: String
    private let system: String
    private var started = false
    private var sending = false

    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 20
        configuration.waitsForConnectivity = false
        return URLSession(configuration: configuration)
    }()

    /// FILE keeps the telemetry between launches (nil keeps nothing, for the
    /// gallery); ENDPOINT is the server, nil to send nothing.
    public init(file: URL?, endpoint: URL?, version: String) {
        self.file = file
        self.endpoint = endpoint
        self.version = TelemetryFormat.matches(TelemetryFormat.version, version) ? version : "0.0.0"
        device = BuilderTelemetry.modelIdentifier
        system = BuilderTelemetry.systemVersion
        var state = file.flatMap { try? Data(contentsOf: $0) }.flatMap { try? JSONDecoder().decode(State.self, from: $0) } ?? State()
        if Date().timeIntervalSince(state.installSince) > Self.installLifetime {
            state.install = Self.newNumber()
            state.installSince = Date()
        }
        self.state = state
        isOn = state.isOn
        sent = state.sent
        waiting = state.queue.entries.count
        lastSent = state.lastSent
    }

    // MARK: Start

    /// Sends what waits, once, and says when the app was updated since it
    /// last ran.
    public func start() {
        guard !started else { return }
        started = true
        let before = state.lastVersion
        state.lastVersion = version
        save()
        if let before, before != version {
            event("builder.updated", fields: ["from": .text(before), "to": .text(version)])
        }
        send()
    }

    /// The player's switch. Off, the reports not sent yet are dropped.
    public func setOn(_ on: Bool) {
        guard on != state.isOn else { return }
        state.isOn = on
        if !on { state.queue.removeAll() }
        save()
    }

    /// Has the server delete every report of this copy of the app, which then
    /// takes a new number. False if the server could not be reached.
    public func erase() async -> Bool {
        guard !isErasing else { return false }
        isErasing = true
        defer { isErasing = false }
        if let endpoint {
            var request = URLRequest(url: endpoint.appendingPathComponent("v1/forget"))
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try? JSONSerialization.data(withJSONObject: ["install": state.install])
            request.timeoutInterval = 20
            let response = try? await Self.session.data(for: request).1
            guard let status = (response as? HTTPURLResponse)?.statusCode, (200..<300).contains(status) else {
                return false
            }
        }
        state.install = Self.newNumber()
        state.installSince = Date()
        state.queue.removeAll()
        state.sent = 0
        state.lastSent = nil
        save()
        return true
    }

    // MARK: Events

    /// Queues an event, if the player has telemetry on and the app a server,
    /// and sends.
    public func event(_ name: String, game: String? = nil, fields: [String: TelemetryValue] = [:]) {
        guard state.isOn, endpoint != nil else { return }
        state.seq += 1
        guard let report = TelemetryEvent(id: Self.newNumber(), seq: state.seq, context: context, name: name, game: game, fields: fields),
              let body = try? TelemetryFormat.json(report) else { return }
        state.queue.add(TelemetryQueue.Entry(id: report.id, created: Date(), body: body))
        save()
        send()
    }

    /// An error the app met, by what it was doing (ORIGIN, a word) and its
    /// codes, never its words.
    public func error(_ error: Error, origin: String, background: Bool = false) {
        var fields: [String: TelemetryValue] = ["origin": .text(origin), "background": .flag(background)]
        if let failure = error as? EngineFailure {
            fields["kind"] = .text(FailureDetails.name(failure.kind) ?? "other")
            fields.merge(Self.fields(of: failure.details)) { _, new in new }
            if let exit = failure.exit, (-1_000...1_000).contains(exit) { fields["exit"] = .count(exit) }
        } else {
            fields["error"] = .text(Self.codes(of: error))
        }
        event("builder.error", fields: fields)
    }

    /// What the telemetry may say of why the engine failed: the exception's
    /// class, where and errno, each checked again, since the engine wrote
    /// them.
    public nonisolated static func fields(of details: FailureDetails) -> [String: TelemetryValue] {
        var fields: [String: TelemetryValue] = [:]
        if let exception = details.exception.flatMap(FailureDetails.name) { fields["exception"] = .text(exception) }
        if let place = details.place.flatMap(FailureDetails.place) { fields["where"] = .text(place) }
        if let number = details.errorNumber, (1..<10_000).contains(number) { fields["errno"] = .count(number) }
        return fields
    }

    /// What the telemetry may say of why a game was not built: the cause's
    /// name (cartouche_builder/causes.py), nxnative's exit code and, for an
    /// error of the engine's own, its exception, where and errno; each
    /// checked again, since the engine wrote them.
    public nonisolated static func fields(cause: String?, exit: Int?, failure: FailureDetails?) -> [String: TelemetryValue] {
        var fields = failure.map { Self.fields(of: $0) } ?? [:]
        if let cause = cause.flatMap(FailureDetails.name) { fields["cause"] = .text(cause) }
        if let exit, (-1_000...1_000).contains(exit) { fields["exit"] = .count(exit) }
        return fields
    }

    /// An nxnative commit's 12 digits, when TEXT is one.
    public nonisolated static func commit(_ text: String) -> String? {
        let digits = text.lowercased()
        guard (7...40).contains(digits.count), digits.unicodeScalars.allSatisfy({ ("0"..."9").contains($0) || ("a"..."f").contains($0) }) else { return nil }
        return String(digits.prefix(12))
    }

    /// What the app sends at a batch's end: an event for each game built,
    /// failed, or skipped once tried (a full disk, no room, no keys), with
    /// why as names and numbers and the nxnative commit it was built from,
    /// the same for each app built for this Mac (builder.mac*), then one for
    /// the batch; never a name, a message or a path. LIBRARY says each
    /// game's kind and the size of its IPA and of its Mac app, JOBS how many
    /// games the settings build at once.
    public nonisolated static func batchEvents(_ status: BatchStatus, library: Library?, jobs: Int) -> [BatchEvent] {
        let head = status.head.map { String($0.prefix(12)) }
        var events: [BatchEvent] = []
        // A game skipped says why only when it was tried, not one the batch
        // ended before. A game built for this Mac alone, its IPA up to date
        // or not built, has its Mac app's events alone.
        let ipas = status.games.filter { $0.macOnly != true }
        for game in ipas where ["built", "failed"].contains(game.state) || (game.state == "skipped" && !(game.cause ?? "").isEmpty) {
            var fields: [String: TelemetryValue] = [:]
            if let reasons = game.reasons, !reasons.isEmpty { fields["reasons"] = .text(reasons.joined(separator: ",")) }
            if let duration = game.duration { fields["seconds"] = .number(duration.rounded()) }
            if let kind = library?.game(game.titleID)?.kind { fields["source"] = .text(kind) }
            if let built = game.commit.flatMap(BuilderTelemetry.commit) ?? head { fields["nxnative"] = .text(built) }
            if game.fallback == true { fields["fallback"] = .flag(true) }
            if game.state == "built" {
                if let size = library?.game(game.titleID)?.ipa?.size, size > 0 {
                    fields["ipaMB"] = .number((Double(size) / 1_000_000).rounded())
                }
                events.append(BatchEvent("builder.built", game: game.titleID, fields: fields))
            } else {
                fields["stage"] = .text(game.stage ?? "")
                fields.merge(BuilderTelemetry.fields(cause: game.cause, exit: game.exit, failure: game.failure)) { _, new in new }
                events.append(BatchEvent(game.state == "failed" ? "builder.failed" : "builder.skipped", game: game.titleID, fields: fields))
            }
        }
        // Its app for this Mac, after its IPA or alone: the stage it was at
        // is the Mac app's, the IPA's being done.
        let macs = status.games.filter(\.buildsMac)
        for game in macs where ["built", "failed"].contains(game.mac ?? "") || (game.mac == "skipped" && !(game.macCause ?? "").isEmpty) {
            var fields: [String: TelemetryValue] = ["alone": .flag(game.macOnly == true)]
            if let reasons = game.reasons, !reasons.isEmpty { fields["reasons"] = .text(reasons.joined(separator: ",")) }
            if let duration = game.macDuration { fields["seconds"] = .number(duration.rounded()) }
            if let kind = library?.game(game.titleID)?.kind { fields["source"] = .text(kind) }
            if let built = game.commit.flatMap(BuilderTelemetry.commit) ?? head { fields["nxnative"] = .text(built) }
            if game.fallback == true { fields["fallback"] = .flag(true) }
            if game.mac == "built" {
                if let size = library?.game(game.titleID)?.mac?.app?.size, size > 0 {
                    fields["appMB"] = .number((Double(size) / 1_000_000).rounded())
                }
                events.append(BatchEvent("builder.macBuilt", game: game.titleID, fields: fields))
            } else {
                fields["stage"] = .text(game.stage ?? "")
                fields.merge(BuilderTelemetry.fields(cause: game.macCause, exit: game.macExit, failure: game.macFailure)) { _, new in new }
                events.append(BatchEvent(game.mac == "failed" ? "builder.macFailed" : "builder.macSkipped", game: game.titleID, fields: fields))
            }
        }
        // The games by how they ended, their IPA's builds; their Mac apps'
        // apart.
        var fields: [String: TelemetryValue] = [
            "state": .text(status.state),
            "games": .count(status.games.count),
            "built": .count(ipas.filter { $0.state == "built" }.count),
            "failed": .count(ipas.filter { $0.state == "failed" }.count),
            "skipped": .count(ipas.filter { $0.state == "skipped" }.count),
            "stopped": .count(ipas.filter { $0.state == "stopped" }.count),
            "scheduled": .flag(status.scheduled ?? false),
            "jobs": .count(jobs),
        ]
        if !macs.isEmpty {
            for (key, state) in [("macBuilt", "built"), ("macFailed", "failed"), ("macSkipped", "skipped"), ("macStopped", "stopped")] {
                fields[key] = .count(macs.filter { $0.mac == state }.count)
            }
        }
        if let started = status.startedDate, let ended = status.endedDate {
            fields["minutes"] = .number((ended.timeIntervalSince(started) / 60 * 10).rounded() / 10)
        }
        if let head { fields["nxnative"] = .text(head) }
        if status.fallback != nil { fields["fallback"] = .flag(true) }
        if let failure = status.failure { fields.merge(BuilderTelemetry.fields(of: failure)) { _, new in new } }
        events.append(BatchEvent("builder.batch", fields: fields))
        return events
    }

    /// "NSCocoaErrorDomain 640 < NSPOSIXErrorDomain 28": an error and the
    /// ones under it.
    public nonisolated static func codes(of error: Error) -> String {
        var parts: [String] = []
        var current: NSError? = error as NSError
        while let found = current, parts.count < 4 {
            parts.append("\(found.domain) \(found.code)")
            current = found.userInfo[NSUnderlyingErrorKey] as? NSError
        }
        return parts.joined(separator: " < ")
    }

    /// What each report says of this copy of the app and this Mac.
    public var context: TelemetryContext {
        TelemetryContext(install: state.install, cartouche: version, device: device, ios: system, language: language)
    }

    // MARK: Sending

    /// Sends the queue, a batch at a time, while the server takes them.
    public func send() {
        guard state.isOn, !sending, let endpoint else { return }
        state.queue.prune(now: Date())
        guard let batch = state.queue.batch(now: Date()) else { return }
        sending = true
        var request = URLRequest(url: endpoint.appendingPathComponent("v1/reports"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(TelemetryFormat.batch(batch.map(\.body)).utf8)
        Task {
            let ids = Set(batch.map(\.id))
            var again = false
            do {
                let (_, response) = try await Self.session.data(for: request)
                let http = response as? HTTPURLResponse
                switch http?.statusCode ?? 0 {
                case 200..<300:
                    state.queue.remove(ids)
                    state.sent += ids.count
                    state.lastSent = Date()
                    again = true
                case 400, 413, 422:
                    // Reports the server will never take go: kept, they
                    // would hold back the others.
                    state.queue.remove(ids)
                    again = true
                default:
                    let wait = (http?.value(forHTTPHeaderField: "Retry-After")).flatMap { TimeInterval($0) }
                    state.queue.failed(now: Date(), serverWait: wait)
                }
            } catch {
                state.queue.failed(now: Date())
            }
            sending = false
            save()
            if again, state.isOn { send() }
        }
    }

    // MARK: State

    private func save() {
        isOn = state.isOn
        sent = state.sent
        waiting = state.queue.entries.count
        lastSent = state.lastSent
        guard let file, let data = try? JSONEncoder().encode(state) else { return }
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: file, options: .atomic)
    }

    nonisolated static func newNumber() -> String {
        UUID().uuidString.lowercased()
    }

    /// The Mac's model identifier, such as "Mac16,12".
    public nonisolated static var modelIdentifier: String {
        var size = 0
        guard sysctlbyname("hw.model", nil, &size, nil, 0) == 0, size > 0 else { return "Mac0,0" }
        var bytes = [CChar](repeating: 0, count: size)
        guard sysctlbyname("hw.model", &bytes, &size, nil, 0) == 0 else { return "Mac0,0" }
        let text = bytes.withUnsafeBufferPointer { buffer in buffer.baseAddress.map { String(cString: $0) } ?? "" }
        return TelemetryFormat.matches(TelemetryFormat.model, text) ? text : "Mac0,0"
    }

    /// macOS's version, such as "26.1".
    public nonisolated static var systemVersion: String {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        return version.patchVersion > 0
            ? "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
            : "\(version.majorVersion).\(version.minorVersion)"
    }
}
