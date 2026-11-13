//
//  BridgeBuilds.swift
//  Cartouche Builder
//
//  What the Mac shows a paired iPhone of its builds over the bridge
//  (CartoucheBridgeBuilds, launcher/Sources/CartoucheBridgeBuilds.swift):
//  each game of the library, building now or waiting its turn in the batch
//  running, or as the library has it, due, up to date, failed; when its IPA
//  was last built, and when its last build failed and why, in the words
//  the Mac's window shows, cut. Over the bridge alone, to the player's own
//  iPhones: no file of the Mac's, nothing to any server.
//

import CartoucheCore
import Foundation

public enum BridgeBuilds {
    /// The most of a failure's words an iPhone gets.
    static let errorLength = 500

    /// GAMES, the library's, with those BUILDING now and those WAITING
    /// their turn, in their order, in the batch running or starting
    /// (RUNNING). READY: whether the Mac takes a build now; WHY not, in the
    /// player's words. STAGE names a build's step in the player's words.
    public static func shared(games: [Game], building: [GameProgress], waiting: [GameProgress], running: Bool,
                              ready: Bool, why: String?, stage: (String?) -> String) -> CartoucheBridgeBuilds {
        var now: [String: GameProgress] = [:]
        for progress in building where now[progress.titleID] == nil {
            now[progress.titleID] = progress
        }
        var turns: [String: Int] = [:]
        var queue: [GameProgress] = []
        for progress in waiting where now[progress.titleID] == nil && turns[progress.titleID] == nil {
            queue.append(progress)
            turns[progress.titleID] = queue.count
        }
        var shared = games.map { game in
            Self.game(game, building: now[game.titleID], turn: turns[game.titleID], stage: stage)
        }
        // A game of the batch the library does not show yet: by the batch's
        // own words.
        var known = Set(games.map(\.titleID))
        for progress in building + queue where known.insert(progress.titleID).inserted {
            shared.append(Self.game(progress, turn: turns[progress.titleID], stage: stage))
        }
        return CartoucheBridgeBuilds(running: running, ready: ready, why: ready ? nil : why, games: shared)
    }

    /// GAME of the library, building now (BUILDING), waiting its turn
    /// (TURN), or as the library has it.
    static func game(_ game: Game, building: GameProgress?, turn: Int?, stage: (String?) -> String) -> CartoucheBridgeBuilds.Game {
        let built = game.build?.date
        var failed: Date?
        var error: String?
        if let attempt = game.attempt, attempt.result == "failed", let at = attempt.date, built.map({ at > $0 }) ?? true {
            failed = at
            error = attempt.error.map(cut)
        }
        var shared = CartoucheBridgeBuilds.Game(id: game.titleID, name: game.name, state: game.state.rawValue, reasons: game.reasons,
                                                built: built, failed: failed, error: error, buildable: game.canBuild)
        if dueForMacAppAlone(game) {
            // Its IPA up to date: so it is to the iPhone.
            shared.state = GameState.upToDate.rawValue
            shared.reasons = []
        }
        if let building {
            shared.state = "building"
            shared.progress = building.overall ?? building.frac
            shared.step = stage(building.stage)
            shared.left = building.eta.flatMap { $0 > 0 ? $0 : nil }
        } else if let turn {
            shared.state = "queued"
            shared.turn = turn
        } else if game.state == .building || game.state == .queued {
            // The library read while the batch had it, which no longer does:
            // as it was before.
            shared.state = built == nil ? GameState.due.rawValue : GameState.upToDate.rawValue
        }
        return shared
    }

    /// A game of the batch alone, building or waiting its turn (TURN).
    static func game(_ progress: GameProgress, turn: Int?, stage: (String?) -> String) -> CartoucheBridgeBuilds.Game {
        var shared = CartoucheBridgeBuilds.Game(id: progress.titleID, name: progress.name, state: progress.state, reasons: progress.reasons ?? [])
        if progress.state == "building" {
            shared.progress = progress.overall ?? progress.frac
            shared.step = stage(progress.stage)
            shared.left = progress.eta.flatMap { $0 > 0 ? $0 : nil }
        } else {
            shared.state = "queued"
            shared.turn = turn
        }
        return shared
    }

    /// Whether GAME is due for its app for this Mac alone, by reasons of
    /// that app (mac_…), its IPA up to date: a build the iPhone asks for
    /// builds its IPA again, as for a game up to date.
    public static func dueForMacAppAlone(_ game: Game) -> Bool {
        game.state == .due && !game.reasons.isEmpty && game.reasons.allSatisfy { $0.hasPrefix("mac_") }
    }

    private static func cut(_ text: String) -> String {
        text.count <= errorLength ? text : String(text.prefix(errorLength - 1)) + "…"
    }
}
