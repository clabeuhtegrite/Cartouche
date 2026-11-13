//
//  CartoucheGameLookupTests.swift
//  CartoucheCoreTests
//
//  What Cartouche asks its server about a game it does not know
//  (Sources/CartoucheGameLookup.swift): the name and the platform alone,
//  the answers read as telemetry/README.md has them, kept and asked again a
//  month later, and a server that does not answer asked again later.
//

import Foundation
import XCTest
@testable import CartoucheCore

final class CartoucheGameLookupTests: XCTestCase {
    private let endpoint = URL(string: "https://cartouche-telemetry.example.workers.dev")
    private let unravel = CartoucheFoundGame(igdb: 103281, name: "Unravel Two", cover: "co1yxz", artwork: "ar7k2",
                                             genre: "puzzle", platform: "switch", summary: "Two Yarnys, tied together.")

    private func json(_ object: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: object)
    }

    // MARK: What is asked

    func testTheTitleIdSaysThePlatform() {
        XCTAssertEqual(CartoucheGameWanted.platform(titleId: "0400C3F00006E000"), "switch2")
        XCTAssertEqual(CartoucheGameWanted.platform(titleId: "01006BB00C6F0000"), "switch")
        XCTAssertNil(CartoucheGameWanted.platform(titleId: "0500000000000000"))
        XCTAssertNil(CartoucheGameWanted.platform(titleId: "0100abc"))
        XCTAssertNil(CartoucheGameWanted.platform(titleId: nil))
    }

    func testANameIsSentAsTheServerTakesIt() throws {
        let game = try XCTUnwrap(CartoucheGameWanted(name: "  Unravel\tTwo \n", platform: "switch"))
        XCTAssertEqual(game.name, "Unravel Two")
        XCTAssertEqual(game.key, "switch:Unravel Two")
        XCTAssertNil(CartoucheGameWanted(name: " \n ", platform: nil))
        // A platform the server does not know is left out.
        XCTAssertNil(CartoucheGameWanted(name: "Celeste", platform: "wii")?.platform)
        XCTAssertEqual(CartoucheGameWanted(name: "Celeste", platform: nil)?.key, ":Celeste")
        // Cut to 128 UTF-16 code units, between two characters.
        let long = try XCTUnwrap(CartoucheGameWanted(name: String(repeating: "\u{E9}", count: 100) + String(repeating: "🎮", count: 40),
                                                     platform: nil))
        XCTAssertLessThanOrEqual(long.name.utf16.count, CartoucheGameWanted.longestName)
        XCTAssertEqual(long.name.utf16.count, 128)
        XCTAssertTrue(long.name.hasSuffix("🎮"))
    }

    func testTheRequestSendsTheNameAndThePlatformAlone() throws {
        let request = try XCTUnwrap(CartoucheGameWanted(name: "Unravel Two", platform: "switch")).request(to: XCTUnwrap(endpoint))
        XCTAssertEqual(request.url?.absoluteString, "https://cartouche-telemetry.example.workers.dev/v1/games")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: String])
        XCTAssertEqual(body, ["name": "Unravel Two", "platform": "switch"])

        // Without a platform, the name alone: the server refuses a null one.
        let alone = try XCTUnwrap(CartoucheGameWanted(name: "Unravel Two", platform: nil)).request(to: XCTUnwrap(endpoint))
        let named = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(alone.httpBody)) as? [String: Any])
        XCTAssertEqual(Array(named.keys), ["name"])
    }

    // MARK: The answers

    func testAnAnswerReadsAsTheServerGivesIt() throws {
        let found = try json(["found": true, "igdb": 103281, "name": "Unravel Two", "cover": "co1yxz", "artwork": "ar7k2",
                              "genre": "puzzle", "platform": "switch", "summary": "Two Yarnys, tied together."])
        XCTAssertEqual(CartoucheGameAnswer.read(found), .found(unravel))
        XCTAssertEqual(CartoucheGameAnswer.read(try json(["found": false])), .notFound)
        // The least the server gives: an ID, a name and a cover.
        let least = try json(["found": true, "igdb": 7, "name": "Celeste", "cover": "cob9dh"])
        XCTAssertEqual(CartoucheGameAnswer.read(least), .found(CartoucheFoundGame(igdb: 7, name: "Celeste", cover: "cob9dh")))
    }

    func testWhatIsNotAsTheServerGivesItIsLeftOut() throws {
        // An artwork, a genre, a platform or a summary that is not leaves
        // the game.
        let odd = try json(["found": true, "igdb": 103281, "name": "Unravel Two", "cover": "co1yxz", "artwork": "../ar",
                            "genre": "indie", "platform": "ps5", "summary": " \n "])
        XCTAssertEqual(CartoucheGameAnswer.read(odd), .found(CartoucheFoundGame(igdb: 103281, name: "Unravel Two", cover: "co1yxz")))
        // A cover that is not, no ID or no name: no answer.
        XCTAssertNil(CartoucheGameAnswer.read(try json(["found": true, "igdb": 1, "name": "A", "cover": "co/1"])))
        XCTAssertNil(CartoucheGameAnswer.read(try json(["found": true, "igdb": 0, "name": "A", "cover": "co1"])))
        XCTAssertNil(CartoucheGameAnswer.read(try json(["found": true, "igdb": 1, "name": " ", "cover": "co1"])))
        XCTAssertNil(CartoucheGameAnswer.read(try json(["found": true, "igdb": 1, "cover": "co1"])))
        XCTAssertNil(CartoucheGameAnswer.read(Data("not an answer".utf8)))
        XCTAssertNil(CartoucheGameAnswer.read(try json(["error": "IGDB unavailable"])))
    }

    // MARK: Asking, keeping, asking again

    /// Cartouche's server, as the tests stand it in: an answer for each
    /// name, or a status for every request.
    private final class Server: @unchecked Sendable {
        var answers: [String: [String: Any]] = [:]
        var status = 200
        var retryAfter: String?
        var asked: [[String: String]] = []
    }

    private func load(from server: Server) -> CartoucheGameLookup.Load {
        let load: CartoucheGameLookup.Load = { request in
            let sent: Any? = request.httpBody.flatMap { try? JSONSerialization.jsonObject(with: $0) }
            let body: [String: String] = (sent as? [String: String]) ?? [:]
            server.asked.append(body)
            let headers: [String: String]? = server.retryAfter.map { ["Retry-After": $0] }
            guard let url = request.url,
                  let response = HTTPURLResponse(url: url, statusCode: server.status, httpVersion: nil, headerFields: headers) else {
                throw URLError(.badURL)
            }
            let found: [String: Any] = server.answers[body["name"] ?? ""] ?? ["found": false]
            let answer: [String: Any] = server.status == 200 ? found : ["error": "no"]
            let data = try JSONSerialization.data(withJSONObject: answer)
            return (data, response as URLResponse)
        }
        return load
    }

    /// Where the answers are kept: a folder of its own, removed after the
    /// test.
    private func keptFile() -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        return folder.appendingPathComponent("Cartouche/GameLookups.json")
    }

    private func wanted(_ name: String, _ platform: String? = "switch") -> CartoucheGameWanted {
        CartoucheGameWanted(name: name, platform: platform)!
    }

    @MainActor
    func testAnswersAreKeptShownAndAskedForAgainAMonthLater() async throws {
        let server = Server()
        server.answers["Unravel Two"] = ["found": true, "igdb": 103281, "name": "Unravel Two", "cover": "co1yxz",
                                         "artwork": "ar7k2", "genre": "puzzle", "platform": "switch",
                                         "summary": "Two Yarnys, tied together."]
        let file = keptFile()
        let lookup = CartoucheGameLookup(endpoint: endpoint, file: file, load: load(from: server))
        let games = [wanted("Unravel Two"), wanted("My Homebrew", nil)]
        var shown: [String: CartoucheFoundGame]?
        let now = Date()
        await lookup.lookUpIfDue(games, now: now) { shown = $0 }?.value
        XCTAssertEqual(server.asked, [["name": "Unravel Two", "platform": "switch"], ["name": "My Homebrew"]])
        XCTAssertEqual(shown, ["switch:Unravel Two": unravel])
        XCTAssertEqual(CartoucheGameLookup.kept(at: file), ["switch:Unravel Two": unravel])

        // Answered less than a month ago, the found and the not found:
        // not asked again.
        XCTAssertNil(lookup.lookUpIfDue(games, now: now.addingTimeInterval(29 * 86_400)) { _ in XCTFail("asked again") })
        // Another name is.
        await lookup.lookUpIfDue(games + [wanted("Unravel 2")], now: now.addingTimeInterval(60)) { _ in }?.value
        XCTAssertEqual(server.asked.count, 3)
        XCTAssertEqual(server.asked.last, ["name": "Unravel 2", "platform": "switch"])

        // A month later, they are asked again.
        await lookup.lookUpIfDue(games, now: now.addingTimeInterval(CartoucheGameLookup.freshness + 60)) { _ in }?.value
        XCTAssertEqual(server.asked.count, 5)

        // Another Cartouche, started later, has the answers kept.
        let again = CartoucheGameLookup(endpoint: endpoint, file: file, load: load(from: server))
        XCTAssertEqual(again.answers, ["switch:Unravel Two": unravel])
    }

    @MainActor
    func testAnswersKeptBeforeTheSummariesShowAndAreAskedForAgain() async throws {
        let server = Server()
        server.answers["Unravel Two"] = ["found": true, "igdb": 103281, "name": "Unravel Two", "cover": "co1yxz",
                                         "summary": "Two Yarnys, tied together."]
        let file = keptFile()
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        // Asked yesterday, by a Cartouche that did not read the summaries.
        let yesterday = Date().addingTimeInterval(-86_400).timeIntervalSinceReferenceDate
        let old = """
        {"schema": 1, "games": {"switch:Unravel Two": {"asked": \(yesterday), "found": {"igdb": 103281, "name": "Unravel Two", "cover": "co1yxz"}}}}
        """
        try Data(old.utf8).write(to: file)
        let lookup = CartoucheGameLookup(endpoint: endpoint, file: file, load: load(from: server))
        // Shown meanwhile, and asked for again at once.
        XCTAssertEqual(lookup.answers["switch:Unravel Two"]?.cover, "co1yxz")
        var shown: [String: CartoucheFoundGame]?
        await lookup.lookUpIfDue([wanted("Unravel Two")]) { shown = $0 }?.value
        XCTAssertEqual(server.asked.count, 1)
        XCTAssertEqual(shown?["switch:Unravel Two"]?.summary, "Two Yarnys, tied together.")
        // Kept with the summary, and not asked for again before a month.
        let again = CartoucheGameLookup(endpoint: endpoint, file: file, load: load(from: server))
        XCTAssertEqual(again.answers["switch:Unravel Two"]?.summary, "Two Yarnys, tied together.")
        XCTAssertNil(again.lookUpIfDue([wanted("Unravel Two")]) { _ in XCTFail("asked again") })
    }

    @MainActor
    func testAServerThatDoesNotAnswerIsAskedAgainLater() async throws {
        let server = Server()
        server.status = 503
        let file = keptFile()
        let lookup = CartoucheGameLookup(endpoint: endpoint, file: file, load: load(from: server))
        let games = [wanted("Unravel Two"), wanted("Celeste")]
        let now = Date()
        await lookup.lookUpIfDue(games, now: now) { _ in XCTFail("an answer shown from a server that did not answer") }?.value
        // The first refused, the others wait.
        XCTAssertEqual(server.asked.count, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))

        // Within the hour, nothing is asked.
        server.status = 200
        XCTAssertNil(lookup.lookUpIfDue(games, now: now.addingTimeInterval(1800)) { _ in })
        // An hour later, all are.
        var shown: [String: CartoucheFoundGame]?
        await lookup.lookUpIfDue(games, now: now.addingTimeInterval(CartoucheGameLookup.retryDelay + 60)) { shown = $0 }?.value
        XCTAssertEqual(server.asked.count, 3)
        XCTAssertEqual(shown, [:])

        // A month later, too many games asked: when the server says.
        server.status = 429
        server.retryAfter = "7200"
        let later = now.addingTimeInterval(CartoucheGameLookup.retryDelay + CartoucheGameLookup.freshness + 120)
        await lookup.lookUpIfDue(games, now: later) { _ in }?.value
        XCTAssertEqual(server.asked.count, 4)
        XCTAssertNil(lookup.lookUpIfDue(games, now: later.addingTimeInterval(3700)) { _ in })
        server.status = 200
        await lookup.lookUpIfDue(games, now: later.addingTimeInterval(7300)) { _ in }?.value
        XCTAssertEqual(server.asked.count, 6)
    }

    @MainActor
    func testANameTheServerRefusesIsNotAskedAgainSoon() async throws {
        let server = Server()
        server.status = 400
        let lookup = CartoucheGameLookup(endpoint: endpoint, file: keptFile(), load: load(from: server))
        let games = [wanted("Unravel Two")]
        await lookup.lookUpIfDue(games) { _ in }?.value
        XCTAssertEqual(server.asked.count, 1)
        XCTAssertNil(lookup.lookUpIfDue(games, now: Date().addingTimeInterval(86_400)) { _ in })
    }

    @MainActor
    func testAtMostABatchIsAskedInOneGo() async throws {
        let server = Server()
        let lookup = CartoucheGameLookup(endpoint: endpoint, file: keptFile(), load: load(from: server))
        let games = (1 ... CartoucheGameLookup.batch + 5).map { wanted("Game \($0)") }
        await lookup.lookUpIfDue(games) { _ in }?.value
        XCTAssertEqual(server.asked.count, CartoucheGameLookup.batch)
        await lookup.lookUpIfDue(games) { _ in }?.value
        XCTAssertEqual(server.asked.count, CartoucheGameLookup.batch + 5)
    }

    @MainActor
    func testOnlyAnHTTPSServerIsAsked() {
        let refused: CartoucheGameLookup.Load = { _ in
            XCTFail("a server that is not https was asked")
            throw URLError(.badURL)
        }
        let file = keptFile()
        let plain = CartoucheGameLookup(endpoint: URL(string: "http://cartouche-telemetry.example.workers.dev"), file: file,
                                        load: refused)
        XCTAssertNil(plain.lookUpIfDue([wanted("Celeste")]) { _ in })
        let none = CartoucheGameLookup(endpoint: nil, file: file, load: refused)
        XCTAssertNil(none.lookUpIfDue([wanted("Celeste")]) { _ in })
    }

    func testAKeptFileThatIsNotAsCartoucheWritesItGivesNothingWrong() throws {
        let file = keptFile()
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("not a list".utf8).write(to: file)
        XCTAssertEqual(CartoucheGameLookup.kept(at: file), [:])
        let odd = """
        {"schema": 1, "games": {
          "switch:Unravel Two": {"asked": 0, "found": {"igdb": 103281, "name": "Unravel Two", "cover": "../co1yxz"}},
          ":Celeste": {"asked": 0, "found": {"igdb": 7, "name": "Celeste", "cover": "cob9dh", "genre": "indie"}},
          ":Nothing": {"asked": 0}
        }}
        """
        try Data(odd.utf8).write(to: file)
        XCTAssertEqual(CartoucheGameLookup.kept(at: file), [":Celeste": CartoucheFoundGame(igdb: 7, name: "Celeste", cover: "cob9dh")])
    }
}
