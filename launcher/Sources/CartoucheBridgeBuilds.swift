//
//  CartoucheBridgeBuilds.swift
//  Cartouche
//
//  Cartouche Builder's builds, as the Mac shares them with a paired iPhone
//  over the bridge (CartoucheBridge.swift, its `builds` and `build`):
//  whether a batch runs, and each game the Mac knows, building, waiting its
//  turn, or as its library has it. And what a game's sheet in Cartouche
//  makes of them: the game's line, the button that asks the Mac to build
//  it, and the Mac's builds now, waiting and done.
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

        public init(id: String, name: String, state: String, reasons: [String] = [], progress: Double? = nil, step: String? = nil,
                    left: Double? = nil, turn: Int? = nil, built: Date? = nil, failed: Date? = nil, error: String? = nil, buildable: Bool = true) {
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
        }

        private enum CodingKeys: String, CodingKey {
            case id, name, state, reasons, progress, step, left, turn, built, failed, error, buildable
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
        }

        public var builtDate: Date? { built.map { Date(timeIntervalSince1970: $0) } }
        public var failedDate: Date? { failed.map { Date(timeIntervalSince1970: $0) } }
    }

    /// Whether a batch runs on the Mac, or starts: a build asked for waits
    /// its turn in it.
    public var running: Bool
    /// Whether the Mac takes a build now; when it does not, why, in its
    /// words: its tools not ready, an IPA being imported.
    public var ready: Bool
    public var why: String?
    public var games: [Game]

    public init(running: Bool = false, ready: Bool = true, why: String? = nil, games: [Game] = []) {
        self.running = running
        self.ready = ready
        self.why = why
        self.games = games
    }

    private enum CodingKeys: String, CodingKey { case running, ready, why, games }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        running = (try? c.decodeIfPresent(Bool.self, forKey: .running)) ?? false
        ready = (try? c.decodeIfPresent(Bool.self, forKey: .ready)) ?? true
        why = try? c.decodeIfPresent(String.self, forKey: .why)
        games = (try? c.decodeIfPresent([Game].self, forKey: .games)) ?? []
    }

    /// The games building now.
    public var building: [Game] { games.filter { $0.state == "building" } }

    /// The games waiting their turn, the next first.
    public var waiting: [Game] {
        games.filter { $0.state == "queued" }.sorted { ($0.turn ?? .max) < ($1.turn ?? .max) }
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
