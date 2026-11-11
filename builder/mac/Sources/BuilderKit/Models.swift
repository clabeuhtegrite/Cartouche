//
//  Models.swift
//  Cartouche Builder
//
//  What the builder's engine answers (cartouche_builder/api.py) and what it
//  writes of a running batch (status.py), as the app reads them. Every
//  field the engine may leave out is optional, so that an engine a little
//  older or newer than the app still reads.
//

import Foundation

public struct EngineFailure: Codable, Error, LocalizedError, Equatable {
    public var kind: String
    public var message: String

    public init(kind: String, message: String) {
        self.kind = kind
        self.message = message
    }

    public var errorDescription: String? { message }
}

// MARK: The library

public struct Library: Codable, Equatable {
    public var checked: String?
    public var updated: Bool?
    public var language: String?
    public var folders: Folders?
    public var engine: EngineCommit?
    public var problems: [String]
    public var issues: [String]
    public var notes: [Note]
    public var games: [Game]

    public init(checked: String? = nil, updated: Bool? = nil, language: String? = nil, folders: Folders? = nil, engine: EngineCommit? = nil,
                problems: [String] = [], issues: [String] = [], notes: [Note] = [], games: [Game] = []) {
        self.checked = checked
        self.updated = updated
        self.language = language
        self.folders = folders
        self.engine = engine
        self.problems = problems
        self.issues = issues
        self.notes = notes
        self.games = games
    }

    enum CodingKeys: String, CodingKey { case checked, updated, language, folders, engine, problems, issues, notes, games }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        checked = try c.decodeIfPresent(String.self, forKey: .checked)
        updated = try c.decodeIfPresent(Bool.self, forKey: .updated)
        language = try c.decodeIfPresent(String.self, forKey: .language)
        folders = try c.decodeIfPresent(Folders.self, forKey: .folders)
        engine = try c.decodeIfPresent(EngineCommit.self, forKey: .engine)
        problems = try c.decodeIfPresent([String].self, forKey: .problems) ?? []
        issues = try c.decodeIfPresent([String].self, forKey: .issues) ?? []
        notes = try c.decodeIfPresent([Note].self, forKey: .notes) ?? []
        games = try c.decodeIfPresent([Game].self, forKey: .games) ?? []
    }

    public var due: [Game] { games.filter { $0.state == .due } }
    public var failed: [Game] { games.filter { $0.state == .failed } }

    public func game(_ titleID: String) -> Game? {
        games.first { $0.titleID == titleID }
    }
}

public struct Note: Codable, Equatable, Hashable {
    public var commit: String
    public var kind: String
    public var text: String
}

public struct EngineCommit: Codable, Equatable {
    public var head: String
    public var short: String
    public var time: Double?
    public var subject: String?
    public var url: String?
    public var branch: String?
    public var commitURL: String?

    enum CodingKeys: String, CodingKey {
        case head, short, time, subject, url, branch
        case commitURL = "commit_url"
    }

    public init(head: String, short: String, time: Double? = nil, subject: String? = nil, url: String? = nil, branch: String? = nil, commitURL: String? = nil) {
        self.head = head
        self.short = short
        self.time = time
        self.subject = subject
        self.url = url
        self.branch = branch
        self.commitURL = commitURL
    }

    public var date: Date? { time.flatMap { $0 > 0 ? Date(timeIntervalSince1970: $0) : nil } }

    /// The page of COMMIT on GitHub, when nxnative's remote is there.
    public func page(of commit: String) -> URL? {
        guard let commitURL, !commitURL.isEmpty else { return nil }
        return URL(string: commitURL.replacingOccurrences(of: "{sha}", with: commit))
    }
}

public struct Folder: Codable, Equatable {
    public var path: String
    public var present: Bool
    public var share: String?
    public var mounted: Bool?

    public init(path: String, present: Bool, share: String? = nil, mounted: Bool? = nil) {
        self.path = path
        self.present = present
        self.share = share
        self.mounted = mounted
    }

    public var isShare: Bool { !(share ?? "").isEmpty }
}

public struct Folders: Codable, Equatable {
    public var sources: Folder?
    public var games: Folder?
    public var keys: Folder?
    public var workspace: Folder?
    public var remote: Bool?

    public init(sources: Folder? = nil, games: Folder? = nil, keys: Folder? = nil, workspace: Folder? = nil, remote: Bool? = nil) {
        self.sources = sources
        self.games = games
        self.keys = keys
        self.workspace = workspace
        self.remote = remote
    }
}

public enum GameState: String, Codable, CaseIterable {
    case due, upToDate = "up_to_date", failed, notFollowed = "not_followed", noProfile = "no_profile", noSource = "no_source", building, queued
    case unknown

    public init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer().decode(String.self)
        self = GameState(rawValue: value) ?? .unknown
    }
}

public struct Change: Codable, Equatable, Hashable, Identifiable {
    public var sha: String
    public var short: String
    public var subject: String
    public var time: Double
    public var kind: String  // profile, named, shared

    public var id: String { sha }
    public var date: Date { Date(timeIntervalSince1970: time) }
}

public struct ChangeCounts: Codable, Equatable {
    public var profile: Int
    public var named: Int
    public var shared: Int

    public init(profile: Int = 0, named: Int = 0, shared: Int = 0) {
        self.profile = profile
        self.named = named
        self.shared = shared
    }

    public var own: Int { profile + named }
}

public struct GameIPA: Codable, Equatable {
    public var name: String
    public var path: String
    public var size: UInt64
    public var present: Bool
}

public struct GameBuild: Codable, Equatable {
    public var commit: String
    public var builtAt: String
    public var version: String?
    public var duration: Double?
    public var origin: String?
    public var toolchain: String?
    public var chain: String?
    public var size: UInt64?
    public var dirty: Bool?

    enum CodingKeys: String, CodingKey {
        case commit, version, duration, origin, toolchain, chain, size, dirty
        case builtAt = "built_at"
    }

    public var date: Date? { ISODate.parse(builtAt) }
}

public struct GameAttempt: Codable, Equatable {
    public var commit: String
    public var at: String
    public var result: String  // failed, stopped, skipped
    public var error: String?
    public var log: String?

    public var date: Date? { ISODate.parse(at) }
}

public struct Game: Codable, Equatable, Identifiable {
    public var titleID: String
    public var name: String
    public var kind: String  // packages, nup, dump, zip, ipa
    public var source: String?
    public var sourceSize: UInt64?
    public var followed: Bool
    public var profile: Bool?
    public var state: GameState
    public var due: Bool?
    public var reasons: [String]
    public var detail: String
    public var ipa: GameIPA?
    public var build: GameBuild?
    public var attempt: GameAttempt?
    public var changes: [Change]
    public var changeCounts: ChangeCounts?
    public var aliases: [String]
    public var icon: String?
    public var progress: GameProgress?

    public var id: String { titleID }

    enum CodingKeys: String, CodingKey {
        case name, kind, source, followed, profile, state, due, reasons, detail, ipa, build, attempt, changes, aliases, icon, progress
        case titleID = "title_id"
        case sourceSize = "source_size"
        case changeCounts = "change_counts"
    }

    public init(titleID: String, name: String, kind: String, source: String? = nil, sourceSize: UInt64? = nil, followed: Bool = true,
                profile: Bool? = true, state: GameState, reasons: [String] = [], detail: String = "", ipa: GameIPA? = nil,
                build: GameBuild? = nil, attempt: GameAttempt? = nil, changes: [Change] = [], changeCounts: ChangeCounts? = nil,
                aliases: [String] = [], icon: String? = nil, progress: GameProgress? = nil) {
        self.titleID = titleID
        self.name = name
        self.kind = kind
        self.source = source
        self.sourceSize = sourceSize
        self.followed = followed
        self.profile = profile
        self.state = state
        self.due = state == .due
        self.reasons = reasons
        self.detail = detail
        self.ipa = ipa
        self.build = build
        self.attempt = attempt
        self.changes = changes
        self.changeCounts = changeCounts
        self.aliases = aliases
        self.icon = icon
        self.progress = progress
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        titleID = try c.decode(String.self, forKey: .titleID)
        name = try c.decode(String.self, forKey: .name)
        kind = try c.decodeIfPresent(String.self, forKey: .kind) ?? ""
        source = try c.decodeIfPresent(String.self, forKey: .source)
        sourceSize = try c.decodeIfPresent(UInt64.self, forKey: .sourceSize)
        followed = try c.decodeIfPresent(Bool.self, forKey: .followed) ?? true
        profile = try c.decodeIfPresent(Bool.self, forKey: .profile)
        state = try c.decodeIfPresent(GameState.self, forKey: .state) ?? .unknown
        due = try c.decodeIfPresent(Bool.self, forKey: .due)
        reasons = try c.decodeIfPresent([String].self, forKey: .reasons) ?? []
        detail = try c.decodeIfPresent(String.self, forKey: .detail) ?? ""
        ipa = try c.decodeIfPresent(GameIPA.self, forKey: .ipa)
        build = try c.decodeIfPresent(GameBuild.self, forKey: .build)
        attempt = try c.decodeIfPresent(GameAttempt.self, forKey: .attempt)
        changes = try c.decodeIfPresent([Change].self, forKey: .changes) ?? []
        changeCounts = try c.decodeIfPresent(ChangeCounts.self, forKey: .changeCounts)
        aliases = try c.decodeIfPresent([String].self, forKey: .aliases) ?? []
        icon = try c.decodeIfPresent(String.self, forKey: .icon)
        progress = try? c.decodeIfPresent(GameProgress.self, forKey: .progress)
    }

    /// The commits that touch the game itself: its profile, or a fix naming it.
    public var ownChanges: [Change] { changes.filter { $0.kind != "shared" } }
    public var canBuild: Bool { kind != "ipa" }
    public var hasIPA: Bool { ipa?.present ?? false }
}

// MARK: A batch

public struct GameProgress: Codable, Equatable {
    public var titleID: String
    public var name: String
    public var reasons: [String]?
    public var detail: String?
    public var state: String  // queued, building, built, failed, stopped, skipped
    public var stage: String?
    public var step: String?
    public var k: Int?
    public var n: Int?
    public var frac: Double?
    public var overall: Double?
    public var eta: Double?
    public var note: String?
    public var message: String?
    public var started: String?
    public var ended: String?
    public var error: String?
    public var log: String?
    public var ipa: String?
    public var duration: Double?

    enum CodingKeys: String, CodingKey {
        case name, reasons, detail, state, stage, step, k, n, frac, overall, eta, note, message, started, ended, error, log, ipa, duration
        case titleID = "title_id"
    }

    public init(titleID: String, name: String, state: String, stage: String? = nil, k: Int? = nil, n: Int? = nil, frac: Double? = nil,
                overall: Double? = nil, eta: Double? = nil, message: String? = nil, error: String? = nil, duration: Double? = nil) {
        self.titleID = titleID
        self.name = name
        self.state = state
        self.stage = stage
        self.k = k
        self.n = n
        self.frac = frac
        self.overall = overall
        self.eta = eta
        self.message = message
        self.error = error
        self.duration = duration
    }

    public var startedDate: Date? { started.flatMap(ISODate.parse) }
}

public struct BatchStatus: Codable, Equatable {
    public var pid: Int?
    public var scheduled: Bool?
    public var state: String  // preparing, building, done, stopped, failed
    public var started: String?
    public var updated: String?
    public var ended: String?
    public var head: String?
    public var message: String?
    public var error: String?
    public var report: String?
    public var games: [GameProgress]
    public var lines: [String]
    public var running: Bool?

    enum CodingKeys: String, CodingKey { case pid, scheduled, state, started, updated, ended, head, message, error, report, games, lines, running }

    public init(state: String, pid: Int? = nil, games: [GameProgress] = [], lines: [String] = [], message: String? = nil) {
        self.state = state
        self.pid = pid
        self.games = games
        self.lines = lines
        self.message = message
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        pid = try c.decodeIfPresent(Int.self, forKey: .pid)
        scheduled = try c.decodeIfPresent(Bool.self, forKey: .scheduled)
        state = try c.decodeIfPresent(String.self, forKey: .state) ?? "done"
        started = try c.decodeIfPresent(String.self, forKey: .started)
        updated = try c.decodeIfPresent(String.self, forKey: .updated)
        ended = try c.decodeIfPresent(String.self, forKey: .ended)
        head = try c.decodeIfPresent(String.self, forKey: .head)
        message = try c.decodeIfPresent(String.self, forKey: .message)
        error = try c.decodeIfPresent(String.self, forKey: .error)
        report = try c.decodeIfPresent(String.self, forKey: .report)
        games = (try? c.decodeIfPresent([GameProgress].self, forKey: .games)) ?? []
        lines = (try? c.decodeIfPresent([String].self, forKey: .lines)) ?? []
        running = try c.decodeIfPresent(Bool.self, forKey: .running)
    }

    public var isRunning: Bool { state == "preparing" || state == "building" }
    public var current: [GameProgress] { games.filter { $0.state == "building" } }
    public var queued: [GameProgress] { games.filter { $0.state == "queued" } }
    public var finished: [GameProgress] { games.filter { !["building", "queued"].contains($0.state) } }
    public var startedDate: Date? { started.flatMap(ISODate.parse) }
    public var endedDate: Date? { ended.flatMap(ISODate.parse) }
}

// MARK: Storage

public struct Disk: Codable, Equatable {
    public var path: String
    public var free: UInt64
    public var total: UInt64
    public var present: Bool?
}

public struct BuildFolder: Codable, Equatable, Identifiable {
    public var path: String
    public var workspace: String
    public var titleID: String
    public var name: String
    public var kind: String  // build, dump
    public var size: UInt64
    public var parts: [String: UInt64]
    public var used: Double?

    public var id: String { path }

    enum CodingKeys: String, CodingKey {
        case path, workspace, name, kind, size, parts, used
        case titleID = "title_id"
    }

    public var extracted: UInt64 { parts["extracted"] ?? 0 }
    public var shaders: UInt64 { parts["shaders"] ?? 0 }
}

public struct IPACopy: Codable, Equatable, Identifiable {
    public var path: String
    public var workspace: String
    public var titleID: String
    public var name: String
    public var size: UInt64
    public var sameDisk: Bool
    public var used: Double?

    public var id: String { path }

    enum CodingKeys: String, CodingKey {
        case path, workspace, name, size, used
        case titleID = "title_id"
        case sameDisk = "same_disk"
    }
}

public struct StorageReport: Codable, Equatable {
    public var workspace: String
    public var disks: [String: Disk?]
    public var folders: [BuildFolder]
    public var ipaCopies: [IPACopy]
    public var totals: [String: UInt64]
    public var settings: StorageSettings?

    enum CodingKeys: String, CodingKey {
        case workspace, disks, folders, totals, settings
        case ipaCopies = "ipa_copies"
    }

    public func total(_ key: String) -> UInt64 { totals[key] ?? 0 }
    public var workspaceDisk: Disk? { disks["workspace"] ?? nil }
    public var gamesDisk: Disk? { disks["games"] ?? nil }
    public var buildFolders: UInt64 { ["extracted", "packages", "shaders", "app", "temporary", "other"].reduce(0) { $0 + total($1) } }
}

public struct StorageSettings: Codable, Equatable {
    public var keepExtracted: Bool
    public var keepIPA: Bool
    public var minFreeGB: Int
    public var workspaceLimitGB: Int

    enum CodingKeys: String, CodingKey {
        case keepExtracted = "keep_extracted"
        case keepIPA = "keep_ipa"
        case minFreeGB = "min_free_gb"
        case workspaceLimitGB = "workspace_limit_gb"
    }
}

public struct Cleaned: Codable, Equatable {
    public var freed: UInt64
    public var removed: [String]
}

// MARK: Tools and settings

public struct Check: Codable, Equatable, Identifiable {
    public var key: String
    public var label: String
    public var ok: Bool
    public var found: String
    public var fix: String
    public var command: String
    public var blocking: Bool

    public var id: String { key }
}

public struct Doctor: Codable, Equatable {
    public var checks: [Check]
    public var ready: Bool
    public var engine: Bool?
}

public struct BuilderConfig: Codable, Equatable {
    public var sources: String
    public var games: String
    public var keys: String
    public var workspace: String
    public var minFreeGB: Int
    public var workspaceLimitGB: Int
    public var engineURL: String
    public var engineBranch: String
    public var enginePolicy: String
    public var refreshDays: Int
    public var skip: [String]
    public var aliases: [String: [String]]
    public var unprofiled: Bool
    public var gameLanguage: String
    public var jobs: Int
    public var keepIPA: Bool
    public var keepExtracted: Bool
    public var language: String
    public var notifications: Bool
    public var schedule: Bool
    public var scheduleHour: Int
    public var scheduleMinute: Int
    /// The setup assistant was gone through to its end: it opens at the
    /// app's start until then.
    public var setupDone: Bool

    enum CodingKeys: String, CodingKey {
        case sources, games, keys, workspace, skip, aliases, unprofiled, jobs, language, notifications, schedule
        case minFreeGB = "min_free_gb"
        case workspaceLimitGB = "workspace_limit_gb"
        case engineURL = "engine_url"
        case engineBranch = "engine_branch"
        case enginePolicy = "engine_policy"
        case refreshDays = "refresh_days"
        case gameLanguage = "game_language"
        case keepIPA = "keep_ipa"
        case keepExtracted = "keep_extracted"
        case scheduleHour = "schedule_hour"
        case scheduleMinute = "schedule_minute"
        case setupDone = "setup_done"
    }

    /// nxnative's own repository and branch (config.py).
    public static let engineURL = "https://github.com/seedds/nxnative.git"
    public static let engineBranch = "main"

    public init(sources: String = "", games: String = "", keys: String = "", workspace: String = "", minFreeGB: Int = 20, workspaceLimitGB: Int = 0,
                engineURL: String = BuilderConfig.engineURL, engineBranch: String = BuilderConfig.engineBranch, enginePolicy: String = "weekly", refreshDays: Int = 7, skip: [String] = [], aliases: [String: [String]] = [:], unprofiled: Bool = false,
                gameLanguage: String = "", jobs: Int = 1, keepIPA: Bool = false, keepExtracted: Bool = false, language: String = "",
                notifications: Bool = true, schedule: Bool = false, scheduleHour: Int = 3, scheduleMinute: Int = 30, setupDone: Bool = false) {
        self.sources = sources
        self.games = games
        self.keys = keys
        self.workspace = workspace
        self.minFreeGB = minFreeGB
        self.workspaceLimitGB = workspaceLimitGB
        self.engineURL = engineURL
        self.engineBranch = engineBranch
        self.enginePolicy = enginePolicy
        self.refreshDays = refreshDays
        self.skip = skip
        self.aliases = aliases
        self.unprofiled = unprofiled
        self.gameLanguage = gameLanguage
        self.jobs = jobs
        self.keepIPA = keepIPA
        self.keepExtracted = keepExtracted
        self.language = language
        self.notifications = notifications
        self.schedule = schedule
        self.scheduleHour = scheduleHour
        self.scheduleMinute = scheduleMinute
        self.setupDone = setupDone
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = BuilderConfig()
        sources = try c.decodeIfPresent(String.self, forKey: .sources) ?? d.sources
        games = try c.decodeIfPresent(String.self, forKey: .games) ?? d.games
        keys = try c.decodeIfPresent(String.self, forKey: .keys) ?? d.keys
        workspace = try c.decodeIfPresent(String.self, forKey: .workspace) ?? d.workspace
        minFreeGB = try c.decodeIfPresent(Int.self, forKey: .minFreeGB) ?? d.minFreeGB
        workspaceLimitGB = try c.decodeIfPresent(Int.self, forKey: .workspaceLimitGB) ?? d.workspaceLimitGB
        engineURL = try c.decodeIfPresent(String.self, forKey: .engineURL) ?? d.engineURL
        engineBranch = try c.decodeIfPresent(String.self, forKey: .engineBranch) ?? d.engineBranch
        enginePolicy = try c.decodeIfPresent(String.self, forKey: .enginePolicy) ?? d.enginePolicy
        refreshDays = try c.decodeIfPresent(Int.self, forKey: .refreshDays) ?? d.refreshDays
        skip = try c.decodeIfPresent([String].self, forKey: .skip) ?? d.skip
        aliases = try c.decodeIfPresent([String: [String]].self, forKey: .aliases) ?? d.aliases
        unprofiled = try c.decodeIfPresent(Bool.self, forKey: .unprofiled) ?? d.unprofiled
        gameLanguage = try c.decodeIfPresent(String.self, forKey: .gameLanguage) ?? d.gameLanguage
        jobs = try c.decodeIfPresent(Int.self, forKey: .jobs) ?? d.jobs
        keepIPA = try c.decodeIfPresent(Bool.self, forKey: .keepIPA) ?? d.keepIPA
        keepExtracted = try c.decodeIfPresent(Bool.self, forKey: .keepExtracted) ?? d.keepExtracted
        language = try c.decodeIfPresent(String.self, forKey: .language) ?? d.language
        notifications = try c.decodeIfPresent(Bool.self, forKey: .notifications) ?? d.notifications
        schedule = try c.decodeIfPresent(Bool.self, forKey: .schedule) ?? d.schedule
        scheduleHour = try c.decodeIfPresent(Int.self, forKey: .scheduleHour) ?? d.scheduleHour
        scheduleMinute = try c.decodeIfPresent(Int.self, forKey: .scheduleMinute) ?? d.scheduleMinute
        setupDone = try c.decodeIfPresent(Bool.self, forKey: .setupDone) ?? d.setupDone
    }

    /// The keys of THIS that differ from OTHER, as the engine's settings take them.
    public func changes(from other: BuilderConfig) -> [String: Any] {
        var found: [String: Any] = [:]
        func note<T: Equatable>(_ key: CodingKeys, _ mine: T, _ theirs: T, _ value: Any) {
            if mine != theirs { found[key.rawValue] = value }
        }
        note(.sources, sources, other.sources, sources)
        note(.games, games, other.games, games)
        note(.keys, keys, other.keys, keys)
        note(.workspace, workspace, other.workspace, workspace)
        note(.minFreeGB, minFreeGB, other.minFreeGB, minFreeGB)
        note(.workspaceLimitGB, workspaceLimitGB, other.workspaceLimitGB, workspaceLimitGB)
        note(.engineURL, engineURL, other.engineURL, engineURL)
        note(.engineBranch, engineBranch, other.engineBranch, engineBranch)
        note(.enginePolicy, enginePolicy, other.enginePolicy, enginePolicy)
        note(.refreshDays, refreshDays, other.refreshDays, refreshDays)
        note(.skip, skip, other.skip, skip)
        note(.aliases, aliases, other.aliases, aliases)
        note(.unprofiled, unprofiled, other.unprofiled, unprofiled)
        note(.gameLanguage, gameLanguage, other.gameLanguage, gameLanguage)
        note(.jobs, jobs, other.jobs, jobs)
        note(.keepIPA, keepIPA, other.keepIPA, keepIPA)
        note(.keepExtracted, keepExtracted, other.keepExtracted, keepExtracted)
        note(.language, language, other.language, language)
        note(.notifications, notifications, other.notifications, notifications)
        note(.schedule, schedule, other.schedule, schedule)
        note(.scheduleHour, scheduleHour, other.scheduleHour, scheduleHour)
        note(.scheduleMinute, scheduleMinute, other.scheduleMinute, scheduleMinute)
        note(.setupDone, setupDone, other.setupDone, setupDone)
        return found
    }
}

public struct BuilderInfo: Codable, Equatable {
    public var version: String
    public var home: String
    public var workspace: String
    public var defaultWorkspace: String?
    public var python: String?
    public var scheduled: Bool?
    public var problems: [String]?

    enum CodingKeys: String, CodingKey {
        case version, home, workspace, python, scheduled, problems
        case defaultWorkspace = "default_workspace"
    }
}

public struct ConfigAnswer: Codable, Equatable {
    public var config: BuilderConfig
    public var builder: BuilderInfo
}

// MARK: Dates

public enum ISODate {
    private static let withFraction: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let plain: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    /// "2026-11-10T07:06:00+00:00", with or without fractions of a second.
    public static func parse(_ text: String) -> Date? {
        plain.date(from: text) ?? withFraction.date(from: text)
    }
}
