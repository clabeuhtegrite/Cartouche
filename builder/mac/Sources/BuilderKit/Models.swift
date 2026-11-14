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
    /// What the measurements may send of it, never its words: the class of
    /// the exception, where the engine's code met it and its errno
    /// (cartouche_builder/failure.py), and the engine's exit status when it
    /// ended without an answer.
    public var details: FailureDetails
    public var exit: Int?

    private enum CodingKeys: String, CodingKey { case kind, message, exit }

    public init(kind: String, message: String, details: FailureDetails = FailureDetails(), exit: Int? = nil) {
        self.kind = kind
        self.message = message
        self.details = details
        self.exit = exit
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        kind = try c.decode(String.self, forKey: .kind)
        message = try c.decode(String.self, forKey: .message)
        details = (try? FailureDetails(from: decoder)) ?? FailureDetails()
        exit = try? c.decodeIfPresent(Int.self, forKey: .exit)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(kind, forKey: .kind)
        try c.encode(message, forKey: .message)
        try c.encodeIfPresent(exit, forKey: .exit)
        try details.encode(to: encoder)
    }

    public var errorDescription: String? { message }
}

/// Why the engine failed, as names and numbers (cartouche_builder/failure.py):
/// {"exception": "FileNotFoundError", "where": "library.scan", "errno": 2}.
public struct FailureDetails: Codable, Equatable, Sendable {
    public var exception: String?
    /// The module and the function of the engine's code: "library.scan".
    public var place: String?
    public var errorNumber: Int?

    private enum CodingKeys: String, CodingKey { case exception, place = "where", errorNumber = "errno" }

    public init(exception: String? = nil, place: String? = nil, errorNumber: Int? = nil) {
        self.exception = exception
        self.place = place
        self.errorNumber = errorNumber
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        exception = try? c.decodeIfPresent(String.self, forKey: .exception)
        place = try? c.decodeIfPresent(String.self, forKey: .place)
        errorNumber = try? c.decodeIfPresent(Int.self, forKey: .errorNumber)
    }

    public var isEmpty: Bool { exception == nil && place == nil && errorNumber == nil }

    /// The class of the exception Python ended on, from the last traceback
    /// in TEXT ("KeyError"), never its words.
    public static func exception(in text: String) -> String? {
        let lines = text.split(whereSeparator: \.isNewline).map(String.init)
        guard let start = lines.lastIndex(where: { $0.hasPrefix("Traceback (most recent call last):") }) else { return nil }
        // The traceback's frames are indented; its last line, which is not,
        // names the exception, with its module when it is not a built-in one.
        guard let line = lines[(start + 1)...].first(where: { !$0.hasPrefix(" ") && !$0.hasPrefix("\t") }) else { return nil }
        let head = line.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? ""
        return head.split(separator: ".").last.map(String.init).flatMap(name)
    }

    /// TEXT when it is a name a programmer gave ("CalledProcessError"),
    /// nothing else.
    public static func name(_ text: String) -> String? {
        guard (1...48).contains(text.count), let first = text.unicodeScalars.first,
              first == "_" || ("A"..."Z").contains(first) || ("a"..."z").contains(first),
              text.unicodeScalars.allSatisfy({ $0 == "_" || ("A"..."Z").contains($0) || ("a"..."z").contains($0) || ("0"..."9").contains($0) })
        else { return nil }
        return text
    }

    /// "library.scan" when it is a module and a function, nothing else.
    public static func place(_ text: String) -> String? {
        let parts = text.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        return parts.count == 2 && parts.allSatisfy({ name($0) != nil }) ? text : nil
    }
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
    /// The branch's newest commit, when the checkout stays on an older one,
    /// the last that built on this Mac, because the newest does not build
    /// (cartouche_builder/fallback.py); `held` then says so.
    public var latest: String?
    public var latestShort: String?
    public var held: Bool?

    enum CodingKeys: String, CodingKey {
        case head, short, time, subject, url, branch, latest, held
        case commitURL = "commit_url"
        case latestShort = "latest_short"
    }

    public init(head: String, short: String, time: Double? = nil, subject: String? = nil, url: String? = nil, branch: String? = nil, commitURL: String? = nil,
                latest: String? = nil, latestShort: String? = nil, held: Bool? = nil) {
        self.head = head
        self.short = short
        self.time = time
        self.subject = subject
        self.url = url
        self.branch = branch
        self.commitURL = commitURL
        self.latest = latest
        self.latestShort = latestShort
        self.held = held
    }

    /// The newest commit's 12 digits, while the builder stays behind it.
    public var heldBehind: String? {
        guard held == true, let latest, !latest.isEmpty else { return nil }
        return latestShort ?? String(latest.prefix(12))
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

/// What the game is built for (config.py's ios and mac, skip_ios and
/// skip_mac): its IPA for the iPhone, its app for this Mac, or both.
public struct GamePlatforms: Codable, Equatable, Sendable {
    public var ios: Bool
    public var mac: Bool

    private enum CodingKeys: String, CodingKey { case ios, mac }

    public init(ios: Bool = true, mac: Bool = true) {
        self.ios = ios
        self.mac = mac
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        ios = (try? c.decodeIfPresent(Bool.self, forKey: .ios)) ?? true
        mac = (try? c.decodeIfPresent(Bool.self, forKey: .mac)) ?? false
    }
}

/// The game's app for this Mac (cartouche_builder/macapps.py): the games
/// folder, which keeps it beside its IPA (`library`: as it is on this
/// Mac's disk, in one file when `packed`, on a NAS), the app this Mac plays
/// it from (`app`: the games folder's, or this Mac's copy of the file, in
/// `installs`, `behind` when made of an older build), its last build, its
/// last attempt that did not build, and whether the next batch builds it,
/// after its IPA or alone, with why in the player's words.
public struct GameMac: Codable, Equatable {
    public var folder: String
    public var packed: Bool
    public var installs: String
    public var library: GameIPA?
    public var app: GameIPA?
    public var behind: Bool
    public var build: GameBuild?
    public var attempt: GameAttempt?
    public var due: Bool
    /// Built alone: its IPA is up to date, or not built.
    public var alone: Bool
    /// "with_ipa", "after_ipa", "mac_new", "mac_missing", "mac_behind",
    /// "up_to_date", "failed_here", or the game's own reason when it is
    /// built for this Mac alone.
    public var reason: String
    public var detail: String

    private enum CodingKeys: String, CodingKey { case folder, packed, installs, library, app, behind, build, attempt, due, alone, reason, detail }

    public init(folder: String = "", packed: Bool = false, installs: String = "", library: GameIPA? = nil, app: GameIPA? = nil,
                behind: Bool = false, build: GameBuild? = nil, attempt: GameAttempt? = nil, due: Bool = false,
                alone: Bool = false, reason: String = "", detail: String = "") {
        self.folder = folder
        self.packed = packed
        self.installs = installs
        self.library = packed ? library : (library ?? app)
        self.app = app
        self.behind = behind
        self.build = build
        self.attempt = attempt
        self.due = due
        self.alone = alone
        self.reason = reason
        self.detail = detail
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        folder = (try? c.decodeIfPresent(String.self, forKey: .folder)) ?? ""
        packed = (try? c.decodeIfPresent(Bool.self, forKey: .packed)) ?? false
        installs = (try? c.decodeIfPresent(String.self, forKey: .installs)) ?? ""
        app = try? c.decodeIfPresent(GameIPA.self, forKey: .app)
        // An engine of before the games folder kept the apps: the app is
        // where it is kept.
        library = c.contains(.library) ? (try? c.decodeIfPresent(GameIPA.self, forKey: .library)) : app
        behind = (try? c.decodeIfPresent(Bool.self, forKey: .behind)) ?? false
        build = try? c.decodeIfPresent(GameBuild.self, forKey: .build)
        attempt = try? c.decodeIfPresent(GameAttempt.self, forKey: .attempt)
        due = (try? c.decodeIfPresent(Bool.self, forKey: .due)) ?? false
        alone = (try? c.decodeIfPresent(Bool.self, forKey: .alone)) ?? false
        reason = (try? c.decodeIfPresent(String.self, forKey: .reason)) ?? ""
        detail = (try? c.decodeIfPresent(String.self, forKey: .detail)) ?? ""
    }

    /// This Mac has the app to play it from.
    public var hasApp: Bool { app?.present ?? false }
    /// The games folder keeps its app (in one file, on a NAS).
    public var kept: Bool { library?.present ?? false }
    /// It can be played on this Mac: from its app here, or once the file
    /// the games folder keeps is installed.
    public var playable: Bool { hasApp || (packed && kept) }
    /// Played, it is installed first (from the NAS): not on this Mac yet,
    /// or made of an older build than the one the games folder keeps.
    public var needsInstall: Bool { packed && kept && (!hasApp || behind) }
    /// Its last build failed at nxnative's commit now: tried again when
    /// nxnative or the game's files change.
    public var failed: Bool { reason == "failed_here" }
}

/// What `api mac-install` answers: this Mac's copy of the game's app, made
/// of the file the games folder keeps; for the measurements, its bytes and
/// the time it took.
public struct MacInstallAnswer: Decodable, Equatable {
    public var app: GameIPA
    public var titleID: String
    public var bytes: Int64?
    public var seconds: Double?

    private enum CodingKeys: String, CodingKey {
        case app, bytes, seconds
        case titleID = "title_id"
    }
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
    /// What it is built for, and its app for this Mac: nil from an engine
    /// older than the Mac's builds, which builds its IPA alone.
    public var platforms: GamePlatforms?
    public var mac: GameMac?

    public var id: String { titleID }

    enum CodingKeys: String, CodingKey {
        case name, kind, source, followed, profile, state, due, reasons, detail, ipa, build, attempt, changes, aliases, icon, progress, platforms, mac
        case titleID = "title_id"
        case sourceSize = "source_size"
        case changeCounts = "change_counts"
    }

    public init(titleID: String, name: String, kind: String, source: String? = nil, sourceSize: UInt64? = nil, followed: Bool = true,
                profile: Bool? = true, state: GameState, reasons: [String] = [], detail: String = "", ipa: GameIPA? = nil,
                build: GameBuild? = nil, attempt: GameAttempt? = nil, changes: [Change] = [], changeCounts: ChangeCounts? = nil,
                aliases: [String] = [], icon: String? = nil, progress: GameProgress? = nil, platforms: GamePlatforms? = nil, mac: GameMac? = nil) {
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
        self.platforms = platforms
        self.mac = mac
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
        platforms = try? c.decodeIfPresent(GamePlatforms.self, forKey: .platforms)
        mac = try? c.decodeIfPresent(GameMac.self, forKey: .mac)
    }

    /// The commits that touch the game itself: its profile, or a fix naming it.
    public var ownChanges: [Change] { changes.filter { $0.kind != "shared" } }
    public var canBuild: Bool { kind != "ipa" }
    public var hasIPA: Bool { ipa?.present ?? false }
    /// Built for the iPhone, its IPA: every game of an engine older than
    /// the Mac's builds.
    public var onIOS: Bool { platforms?.ios ?? true }
    /// Built for this Mac, its app.
    public var onMac: Bool { platforms?.mac ?? false }
    public var hasMacApp: Bool { mac?.hasApp ?? false }
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
    /// The nxnative commit it was built (or tried) from, 12 digits, and
    /// whether that is an older one than the branch's newest, which does
    /// not build (cartouche_builder/fallback.py).
    public var commit: String?
    public var fallback: Bool?
    /// Why it was not built, as a name (cartouche_builder/causes.py:
    /// "app_build", "no_space", "damaged"...), nxnative's exit code, and for
    /// an error of the engine's own, its exception, where and errno.
    public var cause: String?
    public var exit: Int?
    public var failure: FailureDetails?
    /// Its app for this Mac, when the batch builds it (status.py): "mac"
    /// when its stage and progress are of the Mac app, not of its IPA;
    /// how its Mac app went (waiting, building, built, failed, stopped,
    /// skipped), after its IPA or alone (macOnly, its state then being
    /// the Mac app's), and why it was not built, as for its IPA.
    public var platform: String?
    public var mac: String?
    public var macOnly: Bool?
    public var macApp: String?
    public var macError: String?
    public var macCause: String?
    public var macExit: Int?
    public var macDuration: Double?
    public var macLog: String?
    public var macFailure: FailureDetails?

    enum CodingKeys: String, CodingKey {
        case name, reasons, detail, state, stage, step, k, n, frac, overall, eta, note, message, started, ended, error, log, ipa, duration
        case commit, fallback, cause, exit, failure, platform, mac
        case titleID = "title_id"
        case macOnly = "mac_only"
        case macApp = "mac_app"
        case macError = "mac_error"
        case macCause = "mac_cause"
        case macExit = "mac_exit"
        case macDuration = "mac_duration"
        case macLog = "mac_log"
        case macFailure = "mac_failure"
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

    /// Why it was not built, as the activity shows it: the error of a game
    /// that failed, or was skipped (a full disk, no room, no keys).
    public var shownError: String? {
        guard let error, !error.isEmpty, state == "failed" || state == "skipped" else { return nil }
        return error
    }

    /// The older nxnative commit it was built from, or builds from, while
    /// the branch's newest does not build (cartouche_builder/fallback.py).
    public var fallbackCommit: String? {
        guard fallback == true, let commit, !commit.isEmpty, state == "built" || state == "building" else { return nil }
        return commit
    }

    /// The batch builds its app for this Mac, after its IPA or alone.
    public var buildsMac: Bool { !(mac ?? "").isEmpty }
    /// Its stage and progress are of its Mac app now.
    public var onMacNow: Bool { platform == "mac" }

    /// What a game is built for: its IPA, for the iPhone, or its app, for this Mac.
    public enum Platform: Equatable, Sendable {
        case iPhone, mac
    }

    /// What its stage is of, as the activity page says it before the stage,
    /// when the batch builds the game for the iPhone and for this Mac: nil
    /// when it builds it for one of the two, or when the stage's own words
    /// say it (the app's stageText).
    public var shownPlatform: Platform? {
        guard buildsMac, macOnly != true else { return nil }
        let stage = stage ?? ""
        if onMacNow {
            return Self.macStages.contains(stage) ? nil : .mac
        }
        return Self.iPhoneStages.contains(stage) ? nil : .iPhone
    }

    /// The stages whose words name the iPhone (stageText): its shaders, its IPA.
    public static let iPhoneStages: Set<String> = ["shaders", "shader", "pack", "package", "ipa"]
    /// The stages of an app for this Mac, whose words name this Mac
    /// (stageText): nxnative's --platform mac-app, then macapps.py's.
    public static let macStages: Set<String> = ["Mac shaders", "Mac host", "Pipeline prebuild", "Pipeline archive",
                                                "Prewarm pipelines", "Mac app", "mac_deliver"]

    /// Why its Mac app was not built while its IPA was: the error of a
    /// game built for this Mac alone is its own (shownError).
    public var shownMacError: String? {
        guard macOnly != true, let macError, !macError.isEmpty, mac == "failed" || mac == "skipped" else { return nil }
        return macError
    }
}

/// A batch on an older nxnative commit (TO) than the branch's newest
/// (FROM), whose app build fails (cartouche_builder/fallback.py).
public struct BatchFallback: Codable, Equatable {
    public var from: String
    public var to: String

    public init(from: String, to: String) {
        self.from = from
        self.to = to
    }
}

public struct BatchStatus: Codable, Equatable {
    public var pid: Int?
    public var scheduled: Bool?
    public var state: String  // preparing, building, done, stopped, failed
    public var started: String?
    public var updated: String?
    public var ended: String?
    public var head: String?
    /// The branch's newest commit, and the commits the batch went from and
    /// to when it builds from an older one because the newest does not.
    public var latest: String?
    public var fallback: BatchFallback?
    public var message: String?
    public var error: String?
    /// Why a batch that failed did, as names and numbers.
    public var failure: FailureDetails?
    public var report: String?
    public var games: [GameProgress]
    public var lines: [String]
    public var running: Bool?

    enum CodingKeys: String, CodingKey { case pid, scheduled, state, started, updated, ended, head, latest, fallback, message, error, failure, report, games, lines, running }

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
        latest = try? c.decodeIfPresent(String.self, forKey: .latest)
        fallback = try? c.decodeIfPresent(BatchFallback.self, forKey: .fallback)
        message = try c.decodeIfPresent(String.self, forKey: .message)
        error = try c.decodeIfPresent(String.self, forKey: .error)
        failure = try? c.decodeIfPresent(FailureDetails.self, forKey: .failure)
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

// MARK: The queue

/// The games asked for while a batch runs (queue.json, the engine's
/// queue.py): those the batch has not taken yet, which it builds after its
/// own, and those to take out of it, a game waiting left out, one building
/// stopped.
public struct BuildQueue: Codable, Equatable {
    public struct Asked: Codable, Equatable {
        public var titleID: String
        public var force: Bool?
        /// The process of the batch it was asked of.
        public var batch: Int?
        public var added: String?

        enum CodingKeys: String, CodingKey {
            case force, batch, added
            case titleID = "title_id"
        }

        public init(titleID: String, force: Bool? = nil, batch: Int? = nil, added: String? = nil) {
            self.titleID = titleID
            self.force = force
            self.batch = batch
            self.added = added
        }
    }

    public var games: [Asked]
    public var stop: [String]

    enum CodingKeys: String, CodingKey { case games, stop }

    public init(games: [Asked] = [], stop: [String] = []) {
        self.games = games
        self.stop = stop
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        games = (try? c.decodeIfPresent([Asked].self, forKey: .games)) ?? []
        stop = (try? c.decodeIfPresent([String].self, forKey: .stop)) ?? []
    }

    /// The games asked of the batch whose process is PID, in their order:
    /// those asked of another batch wait for nothing, it ended.
    public func waiting(for pid: Int?) -> [String] {
        games.filter { $0.batch == nil || $0.batch == pid }.map(\.titleID)
    }
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

/// A game's app the builder put on this Mac (storage.py), still where it
/// put it: the app removes it, to the Trash.
public struct MacAppCopy: Codable, Equatable, Identifiable {
    public var path: String
    public var titleID: String
    public var name: String
    public var size: UInt64
    /// The game is still built for this Mac.
    public var on: Bool
    public var builtAt: String?
    /// Its game files are clones of its build folder's extracted files,
    /// kept: removing one of the two frees little.
    public var sharesBuild: Bool?
    /// This Mac's copy of the app a NAS keeps in one file: removed, the
    /// game stays built, installed again the next time it is played.
    public var packed: Bool?

    public var id: String { path }

    enum CodingKeys: String, CodingKey {
        case path, name, size, on, packed
        case titleID = "title_id"
        case builtAt = "built_at"
        case sharesBuild = "shares_build"
    }

    public init(path: String, titleID: String, name: String, size: UInt64, on: Bool = true, builtAt: String? = nil, sharesBuild: Bool? = nil,
                packed: Bool? = nil) {
        self.path = path
        self.titleID = titleID
        self.name = name
        self.size = size
        self.on = on
        self.builtAt = builtAt
        self.sharesBuild = sharesBuild
        self.packed = packed
    }

    public var isInstalledCopy: Bool { packed ?? false }

    public var date: Date? { builtAt.flatMap(ISODate.parse) }
}

public struct StorageReport: Codable, Equatable {
    public var workspace: String
    public var disks: [String: Disk?]
    public var folders: [BuildFolder]
    public var ipaCopies: [IPACopy]
    /// The games' Mac apps: nil from an engine older than the Mac's builds.
    public var macApps: [MacAppCopy]?
    public var totals: [String: UInt64]
    public var settings: StorageSettings?

    enum CodingKeys: String, CodingKey {
        case workspace, disks, folders, totals, settings
        case ipaCopies = "ipa_copies"
        case macApps = "mac_apps"
    }

    public func total(_ key: String) -> UInt64 { totals[key] ?? 0 }
    public var workspaceDisk: Disk? { disks["workspace"] ?? nil }
    public var gamesDisk: Disk? { disks["games"] ?? nil }
    /// The disk of the folder of the games' Mac apps.
    public var macAppsDisk: Disk? { disks["mac_apps"] ?? nil }
    public var apps: [MacAppCopy] { macApps ?? [] }
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
    /// Each game is built for the iPhone (its IPA) and for this Mac (its
    /// app), unless one of the two is turned off, for every game (ios,
    /// mac) or for one (skipIOS, skipMac); its Mac app goes in macApps,
    /// "" for the Applications folder of the player's session.
    public var ios: Bool
    public var mac: Bool
    public var skipIOS: [String]
    public var skipMac: [String]
    public var macApps: String

    enum CodingKeys: String, CodingKey {
        case sources, games, keys, workspace, skip, aliases, unprofiled, jobs, language, notifications, schedule, ios, mac
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
        case skipIOS = "skip_ios"
        case skipMac = "skip_mac"
        case macApps = "mac_apps"
    }

    /// nxnative's own repository and branch (config.py).
    public static let engineURL = "https://github.com/seedds/nxnative.git"
    public static let engineBranch = "main"

    public init(sources: String = "", games: String = "", keys: String = "", workspace: String = "", minFreeGB: Int = 20, workspaceLimitGB: Int = 0,
                engineURL: String = BuilderConfig.engineURL, engineBranch: String = BuilderConfig.engineBranch, enginePolicy: String = "weekly", refreshDays: Int = 7, skip: [String] = [], aliases: [String: [String]] = [:], unprofiled: Bool = false,
                gameLanguage: String = "", jobs: Int = 1, keepIPA: Bool = false, keepExtracted: Bool = false, language: String = "",
                notifications: Bool = true, schedule: Bool = false, scheduleHour: Int = 3, scheduleMinute: Int = 30, setupDone: Bool = false,
                ios: Bool = true, mac: Bool = true, skipIOS: [String] = [], skipMac: [String] = [], macApps: String = "") {
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
        self.ios = ios
        self.mac = mac
        self.skipIOS = skipIOS
        self.skipMac = skipMac
        self.macApps = macApps
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
        ios = try c.decodeIfPresent(Bool.self, forKey: .ios) ?? d.ios
        mac = try c.decodeIfPresent(Bool.self, forKey: .mac) ?? d.mac
        skipIOS = try c.decodeIfPresent([String].self, forKey: .skipIOS) ?? d.skipIOS
        skipMac = try c.decodeIfPresent([String].self, forKey: .skipMac) ?? d.skipMac
        macApps = try c.decodeIfPresent(String.self, forKey: .macApps) ?? d.macApps
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
        note(.ios, ios, other.ios, ios)
        note(.mac, mac, other.mac, mac)
        note(.skipIOS, skipIOS, other.skipIOS, skipIOS)
        note(.skipMac, skipMac, other.skipMac, skipMac)
        note(.macApps, macApps, other.macApps, macApps)
        return found
    }

    /// Whether the game TITLEID is built for the iPhone, its IPA.
    public func onIOS(_ titleID: String) -> Bool { ios && !skipIOS.contains(titleID.uppercased()) }
    /// Whether the game TITLEID is built for this Mac, its app.
    public func onMac(_ titleID: String) -> Bool { mac && !skipMac.contains(titleID.uppercased()) }
}

public struct BuilderInfo: Codable, Equatable {
    public var version: String
    public var home: String
    public var workspace: String
    public var defaultWorkspace: String?
    public var python: String?
    public var scheduled: Bool?
    public var problems: [String]?
    /// Where this Mac installs the Mac apps the games folder keeps in one
    /// file, and the folder it is when none is chosen: the Applications
    /// folder of the player's session.
    public var macApps: String?
    public var defaultMacApps: String?
    /// The games folder keeps the Mac apps in one file (a NAS's): they are
    /// installed in macApps to be played. False when it keeps them as
    /// they are, played from there.
    public var macPacked: Bool?

    enum CodingKeys: String, CodingKey {
        case version, home, workspace, python, scheduled, problems
        case defaultWorkspace = "default_workspace"
        case macApps = "mac_apps"
        case defaultMacApps = "default_mac_apps"
        case macPacked = "mac_packed"
    }
}

public struct ConfigAnswer: Codable, Equatable {
    public var config: BuilderConfig
    public var builder: BuilderInfo
}

/// What a game is built for, once one of the two turned on or off
/// (`api platform`); turning one on follows the game.
public struct PlatformAnswer: Codable, Equatable {
    public var titleID: String
    public var platforms: GamePlatforms
    public var followed: Bool

    enum CodingKeys: String, CodingKey {
        case platforms, followed
        case titleID = "title_id"
    }
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
