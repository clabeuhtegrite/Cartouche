//
//  CartoucheBridgeBuilds.swift
//  Cartouche
//
//  Cartouche Builder's builds, as the Mac shares them with a paired iPhone
//  over the bridge (CartoucheBridge.swift, its `builds` and `build`, and,
//  from a Mac whose info says hasBuildsControl, `buildDue`, `stop`,
//  `stopAll`, `follow` and `nightly`): whether a batch runs, each game the
//  Mac knows, building, waiting its turn, or as its library has it, whether
//  the Mac follows it, and the Mac's nightly build. And what Cartouche makes
//  of them: a game's line on its sheet, the button that asks the Mac to
//  build it, the one that stops its build, and the Mac's builds now,
//  waiting, done and failed (CartoucheMacBuildsPage.swift).
//
//  This file is shared: Cartouche compiles it with the launcher, Cartouche
//  Builder through the CartoucheCore package (launcher/Package.swift).
//  Platform-independent: tested on its own by launcher/Package.swift.
//

import Foundation

/// What the Mac answers of its builds. A field a Mac a little older or
/// newer leaves out takes its default.
public struct CartoucheBridgeBuilds: Codable, Equatable, Sendable {
    /// A game the Mac knows: from the player's dumps, or only by its IPA in
    /// the games folder.
    public struct Game: Codable, Equatable, Sendable {
        /// Its title ID, as its dump says: its region's own.
        public var id: String
        /// Its name on the Mac.
        public var name: String
        /// "building" or "queued", in the batch running or starting; else
        /// its state in the Mac's library: "due", "up_to_date", "failed",
        /// "not_followed", "no_profile", "no_source".
        public var state: String
        /// Why it is due, as the Mac's library names it: "new" for a game
        /// never built.
        public var reasons: [String]
        /// Building: how far its build is, from 0 to 1, what it does now in
        /// the Mac's words, and the seconds it has left, when known.
        public var progress: Double?
        public var step: String?
        public var left: Double?
        /// Waiting: its turn, 1 for the next.
        public var turn: Int?
        /// When its IPA was last built, in seconds since 1970.
        public var built: Double?
        /// When its last build failed, after the last one that worked, and
        /// why, in the Mac's words.
        public var failed: Double?
        public var error: String?
        /// Whether the Mac has its dump: with its IPA alone, the Mac cannot
        /// build it again.
        public var buildable: Bool
        /// Whether the Mac follows it: builds it when nxnative improves it.
        /// Nil from a Mac that does not say.
        public var followed: Bool?
        /// Building or waiting its turn: whether the Mac can stop its build,
        /// or take it out of the queue, alone now; and whether its build is
        /// stopping. Nil from a Mac that does not say.
        public var stoppable: Bool?
        public var stopping: Bool?

        public init(id: String, name: String, state: String, reasons: [String] = [], progress: Double? = nil, step: String? = nil,
                    left: Double? = nil, turn: Int? = nil, built: Date? = nil, failed: Date? = nil, error: String? = nil, buildable: Bool = true,
                    followed: Bool? = nil, stoppable: Bool? = nil, stopping: Bool? = nil) {
            self.id = id
            self.name = name
            self.state = state
            self.reasons = reasons
            self.progress = progress
            self.step = step
            self.left = left
            self.turn = turn
            self.built = built?.timeIntervalSince1970
            self.failed = failed?.timeIntervalSince1970
            self.error = error
            self.buildable = buildable
            self.followed = followed
            self.stoppable = stoppable
            self.stopping = stopping
        }

        private enum CodingKeys: String, CodingKey {
            case id, name, state, reasons, progress, step, left, turn, built, failed, error, buildable, followed, stoppable, stopping
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = try c.decode(String.self, forKey: .id)
            name = try c.decodeIfPresent(String.self, forKey: .name) ?? id
            state = try c.decodeIfPresent(String.self, forKey: .state) ?? ""
            reasons = (try? c.decodeIfPresent([String].self, forKey: .reasons)) ?? []
            progress = try? c.decodeIfPresent(Double.self, forKey: .progress)
            step = try? c.decodeIfPresent(String.self, forKey: .step)
            left = try? c.decodeIfPresent(Double.self, forKey: .left)
            turn = try? c.decodeIfPresent(Int.self, forKey: .turn)
            built = try? c.decodeIfPresent(Double.self, forKey: .built)
            failed = try? c.decodeIfPresent(Double.self, forKey: .failed)
            error = try? c.decodeIfPresent(String.self, forKey: .error)
            buildable = (try? c.decodeIfPresent(Bool.self, forKey: .buildable)) ?? true
            followed = try? c.decodeIfPresent(Bool.self, forKey: .followed)
            stoppable = try? c.decodeIfPresent(Bool.self, forKey: .stoppable)
            stopping = try? c.decodeIfPresent(Bool.self, forKey: .stopping)
        }

        public var builtDate: Date? { built.map { Date(timeIntervalSince1970: $0) } }
        public var failedDate: Date? { failed.map { Date(timeIntervalSince1970: $0) } }
    }

    /// The Mac's nightly build: whether it builds what is due every night,
    /// even with its app closed, and at what time, in the Mac's own hours.
    public struct Nightly: Codable, Equatable, Sendable {
        public var on: Bool
        public var hour: Int
        public var minute: Int

        public init(on: Bool, hour: Int = 3, minute: Int = 30) {
            self.on = on
            self.hour = min(max(hour, 0), 23)
            self.minute = min(max(minute, 0), 59)
        }

        private enum CodingKeys: String, CodingKey { case on, hour, minute }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            self.init(on: (try? c.decodeIfPresent(Bool.self, forKey: .on)) ?? false,
                      hour: (try? c.decodeIfPresent(Int.self, forKey: .hour)) ?? 3,
                      minute: (try? c.decodeIfPresent(Int.self, forKey: .minute)) ?? 30)
        }
    }

    /// Whether a batch runs on the Mac, or starts: a build asked for waits
    /// its turn in it.
    public var running: Bool
    /// Whether the Mac takes a build now; when it does not, why, in its
    /// words: its tools not ready, an IPA being imported.
    public var ready: Bool
    public var why: String?
    public var games: [Game]
    /// How many games are due that the batch running does not have: what
    /// Build what is due builds. Nil from a Mac that does not say.
    public var due: Int?
    /// The Mac's nightly build; nil from a Mac that does not say.
    public var nightly: Nightly?

    public init(running: Bool = false, ready: Bool = true, why: String? = nil, games: [Game] = [], due: Int? = nil, nightly: Nightly? = nil) {
        self.running = running
        self.ready = ready
        self.why = why
        self.games = games
        self.due = due
        self.nightly = nightly
    }

    private enum CodingKeys: String, CodingKey { case running, ready, why, games, due, nightly }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        running = (try? c.decodeIfPresent(Bool.self, forKey: .running)) ?? false
        ready = (try? c.decodeIfPresent(Bool.self, forKey: .ready)) ?? true
        why = try? c.decodeIfPresent(String.self, forKey: .why)
        games = (try? c.decodeIfPresent([Game].self, forKey: .games)) ?? []
        due = try? c.decodeIfPresent(Int.self, forKey: .due)
        nightly = try? c.decodeIfPresent(Nightly.self, forKey: .nightly)
    }

    /// The games building now.
    public var building: [Game] { games.filter { $0.state == "building" } }

    /// The games waiting their turn, the next first.
    public var waiting: [Game] {
        games.filter { $0.state == "queued" }.sorted { ($0.turn ?? .max) < ($1.turn ?? .max) }
    }

    /// Every game the Mac knows, by name.
    public var library: [Game] {
        games.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// How many games Build what is due builds: as the Mac counts them, or,
    /// from a Mac that does not say, those due that the batch does not have.
    public var dueCount: Int {
        due ?? games.filter { $0.state == "due" }.count
    }

    /// A game's last build: built, or failed, and when.
    public struct Done: Equatable, Identifiable, Sendable {
        public let game: Game
        public let failed: Bool
        public let date: Date

        public var id: String { game.id }
    }

    /// The builds done, the newest first: each game's last, built or
    /// failed, at most LIMIT; none of a game building or waiting now.
    public func done(limit: Int = 8) -> [Done] {
        let ended = games.compactMap { game -> Done? in
            guard game.state != "building", game.state != "queued" else { return nil }
            let built = game.built ?? -.infinity, failed = game.failed ?? -.infinity
            if let date = game.failedDate, failed > built { return Done(game: game, failed: true, date: date) }
            if let date = game.builtDate { return Done(game: game, failed: false, date: date) }
            return nil
        }
        return Array(ended.sorted { $0.date > $1.date }.prefix(limit))
    }

    /// The games whose last build failed, the newest first; none building
    /// or waiting now.
    public var failures: [Done] {
        done(limit: .max).filter(\.failed)
    }
}

// MARK: A game's sheet

/// A game's build on the player's Mac, as its sheet shows it: where the
/// build is, and the button that asks the Mac for one.
struct CartoucheMacBuild: Equatable {
    enum Status: Equatable {
        /// Building now: how far, what it does, the seconds it has left.
        case building(progress: Double?, step: String?, left: Double?)
        /// Waiting its turn in the batch: 1 for the next.
        case waiting(turn: Int?)
        /// Never built on the Mac.
        case new
        /// nxnative improved it since its last build: a build is due.
        case improved(built: Date?)
        /// Built, with nothing due since.
        case upToDate(built: Date?)
        /// Its last build failed, and why, in the Mac's words.
        case failed(at: Date?, error: String?)
        /// Not followed: the Mac builds it only when asked.
        case notFollowed(built: Date?)
        /// nxnative has no profile for it yet.
        case noProfile
        /// Only its IPA is on the Mac, without its dump.
        case ipaOnly(built: Date?)
    }

    /// What the button of a game building or waiting asks of the Mac.
    enum Halt: Equatable {
        /// Building: stop its build; the batch goes on with the next game.
        case stop
        /// Waiting its turn: take it out of the queue.
        case remove
    }

    /// What the button asks of the Mac.
    enum Action: Equatable {
        /// A first build.
        case build
        /// A build nxnative's changes call for.
        case rebuild
        /// A build of a game up to date, or whose last one failed.
        case buildAgain
        /// A build after the games of the batch running.
        case addToQueue
    }

    /// The game's title ID on the Mac, and its name there.
    let id: String
    let name: String
    let status: Status
    /// The button; none while the game builds or waits its turn, nor for a
    /// game the Mac has only the IPA of.
    let action: Action?
    /// The button that stops its build, or takes it out of the queue: only
    /// when the Mac says it can, alone, now.
    let halt: Halt?
    /// Whether its build is stopping.
    let stopping: Bool
    /// Whether the Mac follows the game; nil when it does not say.
    let followed: Bool?
    /// Whether the Mac takes a build now; why not otherwise, in its words.
    let ready: Bool
    let why: String?

    /// The game whose title IDs are TITLE_IDS in BUILDS, the first one the
    /// Mac knows: a game's IDs are those of its regions, and the Mac has
    /// the one of the player's dump.
    static func of(_ titleIds: [String], in builds: CartoucheBridgeBuilds) -> CartoucheMacBuild? {
        for titleId in titleIds {
            if let game = builds.games.first(where: { $0.id.caseInsensitiveCompare(titleId) == .orderedSame }) {
                return CartoucheMacBuild(game, running: builds.running, ready: builds.ready, why: builds.why)
            }
        }
        return nil
    }

    init(_ game: CartoucheBridgeBuilds.Game, running: Bool, ready: Bool, why: String?) {
        id = game.id
        name = game.name
        followed = game.followed
        self.ready = ready
        self.why = ready ? nil : why
        let failedLast = (game.failed ?? -.infinity) > (game.built ?? -.infinity)
        switch game.state {
        case "building":
            status = .building(progress: game.progress.map { min(max($0, 0), 1) }, step: game.step, left: game.left)
        case "queued":
            status = .waiting(turn: game.turn)
        case "no_source":
            status = .ipaOnly(built: game.builtDate)
        case "no_profile":
            status = .noProfile
        case "failed":
            status = .failed(at: game.failedDate, error: game.error)
        case "not_followed":
            status = failedLast ? .failed(at: game.failedDate, error: game.error) : .notFollowed(built: game.builtDate)
        case "due":
            // As the Mac says it: never built, else improved.
            if game.reasons == ["new"] {
                status = failedLast ? .failed(at: game.failedDate, error: game.error) : .new
            } else {
                status = .improved(built: game.builtDate)
            }
        default:
            status = failedLast ? .failed(at: game.failedDate, error: game.error) : .upToDate(built: game.builtDate)
        }
        stopping = game.stopping == true
        switch status {
        case .building:
            halt = game.stoppable == true && !stopping ? .stop : nil
        case .waiting:
            halt = game.stoppable == true ? .remove : nil
        default:
            halt = nil
        }
        switch status {
        case .building, .waiting, .ipaOnly:
            action = nil
        default:
            if !game.buildable {
                action = nil
            } else if running {
                // A batch runs: the game waits its turn after the games in it.
                action = .addToQueue
            } else if case .improved = status {
                action = .rebuild
            } else if game.built == nil {
                action = .build
            } else {
                action = .buildAgain
            }
        }
    }
}
