//
//  CartoucheGameLookup.swift
//  Cartouche
//
//  What IGDB has of a game of the player's that Cartouche does not know:
//  one nxnative.json has no profile for, such as a game built with a fork
//  of nxnative. Cartouche asks its server (telemetry/worker.js, POST
//  /v1/games) by the game's name, with Switch or Switch 2 when its title ID
//  says which, and nothing else (docs/privacy.md). The server, which alone
//  holds IGDB's keys, answers with the game's IDs there, its cover, an
//  artwork and its genre, or that IGDB has no game of that name. Cartouche
//  keeps each answer and asks again a month later; a server that does not
//  answer is asked again an hour later, or when it says. The server is the
//  telemetry's (CARTOUCHE_TELEMETRY_URL in app/config.env,
//  CartoucheTelemetryURL in the Info.plist): a build without one asks
//  nothing. Foundation only, so that swift test checks it on a Mac
//  (launcher/Package.swift).
//

import Foundation

/// What IGDB has of a game, as Cartouche's server answers: IDs only, never
/// an address.
struct CartoucheFoundGame: Codable, Hashable {
    /// IGDB's ID of the game.
    let igdb: Int
    /// IGDB's name of the game, for the player to check the match.
    let name: String
    /// The image ID of its cover, upright.
    let cover: String
    /// The image ID of an artwork, wide.
    var artwork: String? = nil
    /// One of Cartouche's genres (CartoucheCoverList.genres).
    var genre: String? = nil
    /// switch or switch2: the platform Cartouche said, else IGDB's.
    var platform: String? = nil

    /// The game, or nil unless it is as telemetry/README.md has it: an
    /// ID, a name and a cover; an artwork, a genre or a platform that is not
    /// is left out.
    static func checked(_ game: CartoucheFoundGame) -> CartoucheFoundGame? {
        let name = game.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard game.igdb > 0, !name.isEmpty, game.name.utf16.count <= 200, CartoucheCoverList.isImageId(game.cover) else {
            return nil
        }
        return CartoucheFoundGame(igdb: game.igdb, name: game.name, cover: game.cover,
                                  artwork: game.artwork.flatMap { CartoucheCoverList.isImageId($0) ? $0 : nil },
                                  genre: game.genre.flatMap { CartoucheCoverList.genres.contains($0) ? $0 : nil },
                                  platform: game.platform.flatMap { CartoucheGameWanted.platforms.contains($0) ? $0 : nil })
    }
}

/// A game Cartouche asks its server about: its name and its platform, as
/// they are sent.
struct CartoucheGameWanted: Hashable {
    let name: String
    /// switch or switch2, when Cartouche knows it.
    let platform: String?

    /// The platforms the server knows.
    static let platforms: Set<String> = ["switch", "switch2"]
    /// The longest name the server takes, in UTF-16 code units.
    static let longestName = 128

    /// The game of this NAME, cut to the longest the server takes, without
    /// the spaces around it; nil for a name of nothing but spaces. A
    /// PLATFORM the server does not know is left out.
    init?(name: String, platform: String?) {
        var kept = ""
        var length = 0
        for character in name.trimmingCharacters(in: .whitespacesAndNewlines) {
            // Control characters as spaces, as the server makes them.
            let shown: Character = character.unicodeScalars.contains { $0.properties.generalCategory == .control } ? " " : character
            length += shown.utf16.count
            if length > Self.longestName { break }
            kept.append(shown)
        }
        kept = kept.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !kept.isEmpty else { return nil }
        self.name = kept
        self.platform = platform.flatMap { Self.platforms.contains($0) ? $0 : nil }
    }

    /// The answer's key, among those Cartouche keeps.
    var key: String { (platform ?? "") + ":" + name }

    /// The platform a title ID says: a Switch 2 game's starts with 04, a
    /// Switch game's with 01.
    static func platform(titleId: String?) -> String? {
        guard let titleId, CartoucheCoverList.isTitleId(titleId) else { return nil }
        if titleId.hasPrefix("04") { return "switch2" }
        if titleId.hasPrefix("01") { return "switch" }
        return nil
    }

    /// The request that asks the server at ENDPOINT about the game.
    func request(to endpoint: URL) -> URLRequest {
        struct Body: Encodable {
            let name: String
            /// Left out when nil: the server takes a name alone.
            let platform: String?
        }
        var request = URLRequest(url: endpoint.appendingPathComponent("v1/games"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONEncoder().encode(Body(name: name, platform: platform))
        request.timeoutInterval = 20
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        return request
    }
}

/// The server's answer about a game.
enum CartoucheGameAnswer: Hashable {
    case found(CartoucheFoundGame)
    /// IGDB has no game of that name.
    case notFound

    /// The answer DATA holds, or nil unless it is one: {"found": false}, or
    /// {"found": true} with the game.
    static func read(_ data: Data) -> CartoucheGameAnswer? {
        struct Answer: Decodable {
            let found: Bool
            let igdb: Int?
            let name: String?
            let cover: String?
            let artwork: String?
            let genre: String?
            let platform: String?
        }
        guard data.count <= 16_384, let answer = try? JSONDecoder().decode(Answer.self, from: data) else { return nil }
        guard answer.found else { return .notFound }
        guard let igdb = answer.igdb, let name = answer.name, let cover = answer.cover,
              let game = CartoucheFoundGame.checked(CartoucheFoundGame(igdb: igdb, name: name, cover: cover, artwork: answer.artwork,
                                                                       genre: answer.genre, platform: answer.platform)) else {
            return nil
        }
        return .found(game)
    }
}

/// One answer Cartouche keeps: when it asked, and what IGDB has, if
/// anything.
private struct CartoucheGameRecord: Codable {
    var asked: Date
    var found: CartoucheFoundGame?
}

private struct CartoucheGameRecords: Codable {
    var schema = 1
    var games: [String: CartoucheGameRecord]
}

/// Without cookies or a cache of its own.
private let cartoucheLookupSession = URLSession(configuration: .ephemeral)

/// Asks Cartouche's server about the player's games Cartouche does not
/// know, and keeps the answers in Application Support.
@MainActor
final class CartoucheGameLookup {
    static let shared = CartoucheGameLookup(
        endpoint: (Bundle.main.object(forInfoDictionaryKey: "CartoucheTelemetryURL") as? String)
            .flatMap { URL(string: $0.trimmingCharacters(in: .whitespaces)) },
        file: CartoucheGameLookup.defaultFile)

    /// How long an answer holds: the server keeps its own for 30 days.
    static let freshness: TimeInterval = 30 * 86_400
    /// How long Cartouche waits after the server did not answer, unless it
    /// says.
    static let retryDelay: TimeInterval = 3600
    /// The most games asked in one go: the server takes 60 an hour from an
    /// address.
    static let batch = 20

    typealias Load = @Sendable (URLRequest) async throws -> (Data, URLResponse)

    private let endpoint: URL?
    private let file: URL
    private let load: Load
    private var records: [String: CartoucheGameRecord]
    /// The games to ask about, as the last call gave them.
    private var wanted: [CartoucheGameWanted] = []
    private var waitUntil: Date?
    private var asking: Task<Void, Never>?

    /// Asks the server at ENDPOINT, an https address, and keeps the answers
    /// in FILE. LOAD stands in for URLSession in the tests.
    init(endpoint: URL?, file: URL, load: Load? = nil) {
        self.endpoint = endpoint?.scheme == "https" && endpoint?.host != nil ? endpoint : nil
        self.file = file
        if let load {
            self.load = load
        } else {
            self.load = { request in try await cartoucheLookupSession.data(for: request) }
        }
        records = Self.records(at: file)
    }

    /// Where Cartouche keeps the answers.
    nonisolated static var defaultFile: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Cartouche/GameLookups.json")
    }

    /// The games kept in FILE, by the key of the game asked
    /// (CartoucheGameWanted.key); none when there is no such file.
    nonisolated static func kept(at file: URL) -> [String: CartoucheFoundGame] {
        records(at: file).compactMapValues(\.found)
    }

    private nonisolated static func records(at file: URL) -> [String: CartoucheGameRecord] {
        guard let data = try? Data(contentsOf: file),
              let kept = try? JSONDecoder().decode(CartoucheGameRecords.self, from: data), kept.schema == 1 else { return [:] }
        return kept.games.mapValues { record in
            CartoucheGameRecord(asked: record.asked, found: record.found.flatMap(CartoucheFoundGame.checked))
        }
    }

    /// The games found, by the key of the game asked.
    var answers: [String: CartoucheFoundGame] { records.compactMapValues(\.found) }

    /// Asks the server about the games of WANTED it has not answered for
    /// in a month, one after the other and at most `batch` of them, unless
    /// it did not answer a moment ago; keeps the answers and gives them all
    /// to SHOW. A call while it asks only changes the games it asks about
    /// next. Returns the asking, for the tests to wait for.
    @discardableResult
    func lookUpIfDue(_ wanted: [CartoucheGameWanted], now: Date = Date(),
                     show: @escaping @MainActor ([String: CartoucheFoundGame]) -> Void) -> Task<Void, Never>? {
        self.wanted = wanted
        guard let endpoint, asking == nil else { return nil }
        if let waitUntil, now < waitUntil { return nil }
        guard nextDue(now: now) != nil else { return nil }
        let task = Task {
            var asked = 0
            var changed = false
            questions: while asked < Self.batch, let game = self.nextDue(now: now) {
                asked += 1
                switch await self.ask(game, endpoint: endpoint) {
                case .answered(let found):
                    self.records[game.key] = CartoucheGameRecord(asked: now, found: found)
                    changed = true
                case .wait(let delay):
                    self.waitUntil = now.addingTimeInterval(delay)
                    break questions
                }
            }
            if changed {
                self.save(now: now)
                show(self.answers)
            }
            self.asking = nil
        }
        asking = task
        return task
    }

    /// The first game of those wanted whose answer is missing or old.
    private func nextDue(now: Date) -> CartoucheGameWanted? {
        wanted.first { game in
            guard let record = records[game.key] else { return true }
            return record.asked > now || now.timeIntervalSince(record.asked) >= Self.freshness
        }
    }

    private enum Outcome {
        /// What IGDB has, nil for nothing.
        case answered(CartoucheFoundGame?)
        /// The server did not answer: asked again after DELAY.
        case wait(TimeInterval)
    }

    private func ask(_ game: CartoucheGameWanted, endpoint: URL) async -> Outcome {
        do {
            let (data, response) = try await load(game.request(to: endpoint))
            let http = response as? HTTPURLResponse
            switch http?.statusCode ?? 0 {
            case 200:
                switch CartoucheGameAnswer.read(data) {
                case .found(let found)?: return .answered(found)
                case .notFound?: return .answered(nil)
                case nil: return .wait(Self.retryDelay)
                }
            case 400, 413:
                // A name the server will never take: not asked again before
                // a month.
                return .answered(nil)
            default:
                // Too many games asked, or IGDB away: when the server says.
                let said = http?.value(forHTTPHeaderField: "Retry-After").flatMap { TimeInterval($0) }
                return .wait(min(max(said ?? Self.retryDelay, 60), 86_400))
            }
        } catch {
            return .wait(Self.retryDelay)
        }
    }

    /// Writes the answers to FILE, without the old ones of games no longer
    /// wanted.
    private func save(now: Date) {
        let keys = Set(wanted.map(\.key))
        records = records.filter { key, record in
            keys.contains(key) || (record.asked <= now && now.timeIntervalSince(record.asked) < Self.freshness)
        }
        do {
            let data = try JSONEncoder().encode(CartoucheGameRecords(games: records))
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: file, options: .atomic)
        } catch {
            NSLog("[Cartouche] cannot keep the games looked up: %@", String(describing: error))
        }
    }
}
