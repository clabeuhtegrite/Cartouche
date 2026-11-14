//
//  Unbuilt.swift
//  Cartouche Builder
//
//  The games no Mac built: those at least three Macs tried in the last 28
//  days, none of them built, as the nxnative page workflow sums them up
//  each Thursday (telemetry/nxnative.py, unbuilt.json on the branch
//  nxnative-measurements). A game's sheet says so, a build of one asks
//  first, and the nightly run leaves aside those this Mac never built
//  (cartouche_builder/batch.py, left_aside), from the copy the app keeps in
//  the engine's folder: on 14 November 2026, Pokopia had failed eight
//  times on four Macs, after up to eight hours, a night each time nxnative
//  moved, and the games after it in the batch found no room left.
//

import Foundation

/// A game no Mac built: how many Macs tried it and how many builds failed,
/// how long they took (the median of each Mac's longest attempt, in hours)
/// and the step the most Macs failed at, when three Macs gave them.
public struct UnbuiltGame: Codable, Equatable, Sendable {
    public var titleID: String
    public var macs: Int
    public var failures: Int
    public var hours: Double?
    public var stage: String?

    enum CodingKeys: String, CodingKey {
        case macs, failures, hours, stage
        case titleID = "titleId"
    }

    public init(titleID: String, macs: Int, failures: Int, hours: Double? = nil, stage: String? = nil) {
        self.titleID = titleID
        self.macs = macs
        self.failures = failures
        self.hours = hours
        self.stage = stage
    }
}

public enum UnbuiltGames {
    public static let list = URL(string: "https://raw.githubusercontent.com/clabeuhtegrite/Cartouche/refs/heads/nxnative-measurements/unbuilt.json")!

    /// Title ID → the game, from an unbuilt.json; nil for a file that is not one.
    public static func parse(_ data: Data) -> [String: UnbuiltGame]? {
        struct List: Decodable {
            var games: [UnbuiltGame]
        }
        guard let list = try? JSONDecoder().decode(List.self, from: data) else { return nil }
        var found: [String: UnbuiltGame] = [:]
        for game in list.games where game.macs > 0 && game.titleID.count == 16 {
            found[game.titleID.uppercased()] = game
        }
        return found
    }

    /// The list, from HOME's copy when it is less than a day old, else from
    /// the branch, kept in HOME for the nightly run; the copy's, or none,
    /// when the branch cannot be reached.
    public static func load(_ home: BuilderHome) async -> [String: UnbuiltGame] {
        let file = home.unbuilt
        if let attributes = try? FileManager.default.attributesOfItem(atPath: file.path),
           let modified = attributes[.modificationDate] as? Date, Date().timeIntervalSince(modified) < 86400,
           let data = try? Data(contentsOf: file), let games = parse(data) {
            return games
        }
        var request = URLRequest(url: list)
        request.timeoutInterval = 20
        if let (data, response) = try? await URLSession.shared.data(for: request),
           (response as? HTTPURLResponse)?.statusCode == 200, let games = parse(data) {
            try? FileManager.default.createDirectory(at: home.root, withIntermediateDirectories: true)
            try? data.write(to: file, options: .atomic)
            return games
        }
        return (try? Data(contentsOf: file)).flatMap(parse) ?? [:]
    }

    /// What a game's sheet says of GAME, in the player's language, the step
    /// it failed at as NAMED says it.
    public static func words(_ game: UnbuiltGame, named: (String) -> String = { $0 }) -> String {
        var failed = tr("In the last 4 weeks, \(game.macs) Macs tried it with Cartouche Builder and all \(game.failures) of their builds failed",
                        "Ces 4 dernières semaines, \(game.macs) Mac l’ont essayé avec Cartouche Builder et leurs \(game.failures) constructions ont toutes échoué")
        if let stage = game.stage, !stage.isEmpty {
            failed += tr(", most often at the step “\(named(stage))”", ", le plus souvent à l’étape « \(named(stage)) »")
        }
        if let hours = game.hours, hours > 0 {
            failed += tr(", after about \(hoursText(hours)) hours", ", après \(hoursText(hours)) h environ")
        }
        return failed + tr(". Building it may keep this Mac busy for hours for nothing: better wait until nxnative improves it. The nightly builds leave it aside.",
                           ". Sa construction peut occuper ce Mac des heures pour rien : mieux vaut attendre que nxnative l’améliore. Les constructions de la nuit le laissent de côté.")
    }

    /// "4.7", "4,7" in French.
    public static func hoursText(_ hours: Double) -> String {
        let text = String(format: "%.1f", hours)
        return L10n.code == "fr" ? text.replacingOccurrences(of: ".", with: ",") : text
    }
}
