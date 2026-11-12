//
//  CartoucheCoverListTests.swift
//  CartoucheCoreTests
//
//  The covers Cartouche shows (Sources/CartoucheCoverList.swift): a
//  covers.json read as its schema has it, a newer list over the one the app
//  carries, and that newer list read every day and kept.
//

import Foundation
import XCTest
@testable import CartoucheCore

final class CartoucheCoverListTests: XCTestCase {
    private let ocarina: [String: Any] = ["titleId": "0400486024DEC000", "igdb": 405460,
                                          "name": "The Legend of Zelda: Ocarina of Time", "cover": "cocv5r", "artwork": "ar6knj"]
    private let kart: [String: Any] = ["titleId": "0400C3F00006E000", "igdb": 338104, "name": "Mario Kart World",
                                       "cover": "co9mxq"]
    private let address = URL(string: "https://raw.githubusercontent.com/clabeuhtegrite/Cartouche/refs/heads/live-covers/covers.json")

    private func list(_ covers: [[String: Any]], schema: Int = 1, source: String = "IGDB") throws -> Data {
        try JSONSerialization.data(withJSONObject: ["schema": schema, "source": source, "covers": covers])
    }

    private func cover(_ titleId: String, _ image: String) -> CartoucheCover {
        CartoucheCover(titleId: titleId, igdb: 1, cover: image, artwork: nil)
    }

    // MARK: covers.json

    func testAListReadsByTitleId() throws {
        let covers = try XCTUnwrap(CartoucheCoverList.covers(in: list([ocarina, kart])))
        XCTAssertEqual(covers.count, 2)
        XCTAssertEqual(covers["0400486024DEC000"],
                       CartoucheCover(titleId: "0400486024DEC000", igdb: 405460, cover: "cocv5r", artwork: "ar6knj"))
        XCTAssertEqual(covers["0400C3F00006E000"]?.cover, "co9mxq")
        XCTAssertNil(covers["0400C3F00006E000"]?.artwork)
    }

    func testOnlyACoversListIsRead() throws {
        XCTAssertNil(CartoucheCoverList.covers(in: try list([ocarina], schema: 2)))
        XCTAssertNil(CartoucheCoverList.covers(in: try list([ocarina], source: "Elsewhere")))
        XCTAssertNil(CartoucheCoverList.covers(in: Data("not a list".utf8)))
        XCTAssertNil(CartoucheCoverList.covers(in: Data("{}".utf8)))
        XCTAssertNil(CartoucheCoverList.covers(in: Data(repeating: 0x20, count: CartoucheCoverList.maximumSize + 1)))
        XCTAssertEqual(CartoucheCoverList.covers(in: try list([])), [:])
    }

    func testACoverNotAsTheSchemaHasItIsLeftOut() throws {
        var path = ocarina
        path["cover"] = "../../cover"
        var lowercase = kart
        lowercase["titleId"] = "0400c3f00006e000"
        var noGame = kart
        noGame["igdb"] = 0
        var noCover = kart
        noCover.removeValue(forKey: "cover")
        var badArtwork = kart
        badArtwork["titleId"] = "040074A01BF12000"
        badArtwork["artwork"] = "ar/1"
        let covers = try XCTUnwrap(CartoucheCoverList.covers(in: list([path, lowercase, noGame, noCover, badArtwork, ocarina])))
        // The covers after the wrong ones still count; a wrong artwork
        // leaves its cover.
        XCTAssertEqual(Set(covers.keys), ["040074A01BF12000", "0400486024DEC000"])
        XCTAssertEqual(covers["040074A01BF12000"]?.cover, "co9mxq")
        XCTAssertNil(covers["040074A01BF12000"]?.artwork)
        XCTAssertEqual(covers["0400486024DEC000"]?.cover, "cocv5r")
    }

    func testAGenreCartoucheKnowsIsRead() throws {
        var racing = kart
        racing["genre"] = "racing"
        var unknown = ocarina
        unknown["genre"] = "indie"
        let covers = try XCTUnwrap(CartoucheCoverList.covers(in: list([racing, unknown])))
        XCTAssertEqual(covers["0400C3F00006E000"]?.genre, "racing")
        // A genre Cartouche does not know leaves its cover, without it.
        XCTAssertEqual(covers["0400486024DEC000"]?.cover, "cocv5r")
        XCTAssertNil(covers["0400486024DEC000"]?.genre)
        // A list from before genres reads as it did.
        XCTAssertNil(try XCTUnwrap(CartoucheCoverList.covers(in: list([kart])))["0400C3F00006E000"]?.genre)
    }

    func testASummaryIsRead() throws {
        var racing = kart
        racing["summary"] = "  Race across a world.\u{0007}\n\nTwenty-four racers.  "
        var empty = ocarina
        empty["summary"] = " \n "
        let covers = try XCTUnwrap(CartoucheCoverList.covers(in: list([racing, empty])))
        // Without its control characters, nor the spaces around it.
        XCTAssertEqual(covers["0400C3F00006E000"]?.summary, "Race across a world. \n\nTwenty-four racers.")
        // An empty summary leaves its cover, without it.
        XCTAssertEqual(covers["0400486024DEC000"]?.cover, "cocv5r")
        XCTAssertNil(covers["0400486024DEC000"]?.summary)
        // At most 2,000 characters.
        XCTAssertEqual(CartoucheCoverList.summary(String(repeating: "🎮", count: 2_100))?.count, CartoucheCoverList.longestSummary)
        XCTAssertNil(CartoucheCoverList.summary("\u{0007}\n "))
        // A list from before summaries reads as it did.
        XCTAssertNil(try XCTUnwrap(CartoucheCoverList.covers(in: list([kart])))["0400C3F00006E000"]?.summary)
    }

    func testIdsAreAsTheSchemaHasThem() {
        XCTAssertTrue(CartoucheCoverList.isImageId("cocv5r"))
        XCTAssertTrue(CartoucheCoverList.isImageId("ak6iozckwj322sjmxqd4"))
        XCTAssertFalse(CartoucheCoverList.isImageId(""))
        XCTAssertFalse(CartoucheCoverList.isImageId(String(repeating: "a", count: 41)))
        XCTAssertFalse(CartoucheCoverList.isImageId("co%2Fx"))
        XCTAssertFalse(CartoucheCoverList.isImageId("cöver"))
        XCTAssertTrue(CartoucheCoverList.isTitleId("0400486024DEC000"))
        XCTAssertFalse(CartoucheCoverList.isTitleId("0400486024dec000"))
        XCTAssertFalse(CartoucheCoverList.isTitleId("0400486024DEC00"))
        XCTAssertFalse(CartoucheCoverList.isTitleId("0400486024DEC00G"))
    }

    func testANewerListGoesOverTheCarriedOne() {
        let carried = ["0400C3F00006E000": cover("0400C3F00006E000", "old"), "040074A01BF12000": cover("040074A01BF12000", "dk")]
        let newer = ["0400C3F00006E000": cover("0400C3F00006E000", "new"), "0400486024DEC000": cover("0400486024DEC000", "oot")]
        let merged = CartoucheCoverList.merged(carried, with: newer)
        XCTAssertEqual(merged.count, 3)
        XCTAssertEqual(merged["0400C3F00006E000"]?.cover, "new")
        // A game the newer list has no cover for keeps the carried one.
        XCTAssertEqual(merged["040074A01BF12000"]?.cover, "dk")
        XCTAssertEqual(merged["0400486024DEC000"]?.cover, "oot")
    }

    func testTheRepositorysCoversRead() throws {
        // The list the app carries, as this commit has it: every cover reads.
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let data = try Data(contentsOf: root.appendingPathComponent("catalog/covers.json"))
        let document = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let records = try XCTUnwrap(document["covers"] as? [[String: Any]])
        let covers = try XCTUnwrap(CartoucheCoverList.covers(in: data))
        XCTAssertEqual(covers.count, records.count)
        // Each summary as igdb_covers.py kept it.
        for record in records {
            let titleId = try XCTUnwrap(record["titleId"] as? String)
            XCTAssertEqual(covers[titleId]?.summary, record["summary"] as? String, titleId)
        }
    }

    // MARK: The newer covers, every day

    /// IGDB's list as the branch live-covers would serve it.
    private final class Server: @unchecked Sendable {
        var status = 200
        var body = Data()
        var requests = 0
    }

    private func load(from server: Server) -> CartoucheLiveCovers.Load {
        { request in
            server.requests += 1
            guard let url = request.url,
                  let response = HTTPURLResponse(url: url, statusCode: server.status, httpVersion: nil, headerFields: nil) else {
                throw URLError(.badURL)
            }
            return (server.body, response)
        }
    }

    /// Where these covers are kept: a folder of its own, removed after the test.
    private func keptFile() -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        return folder.appendingPathComponent("Cartouche/LiveCovers.json")
    }

    @MainActor
    func testNewerCoversAreReadKeptAndShown() async throws {
        let server = Server()
        server.body = try list([ocarina])
        let file = keptFile()
        let live = CartoucheLiveCovers(url: address, file: file, load: load(from: server))
        var shown: [String: CartoucheCover]?
        let read = live.refreshIfDue { shown = $0 }
        XCTAssertNotNil(read)
        await read?.value
        XCTAssertEqual(shown?["0400486024DEC000"]?.cover, "cocv5r")
        XCTAssertEqual(Array(CartoucheLiveCovers.kept(at: file).keys), ["0400486024DEC000"])

        // Kept less than six hours ago: not read again.
        let again = live.refreshIfDue { _ in XCTFail("the covers were read again") }
        XCTAssertNil(again)
        XCTAssertEqual(server.requests, 1)

        // Six hours later, they are.
        let later = live.refreshIfDue(now: Date().addingTimeInterval(CartoucheLiveCovers.freshness + 60)) { _ in }
        await later?.value
        XCTAssertEqual(server.requests, 2)
    }

    @MainActor
    func testAReadThatFailsChangesNothingAndWaitsAnHour() async throws {
        let server = Server()
        server.status = 404
        let file = keptFile()
        let live = CartoucheLiveCovers(url: address, file: file, load: load(from: server))
        let failed = live.refreshIfDue { _ in XCTFail("covers shown from a failed read") }
        await failed?.value
        XCTAssertEqual(server.requests, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))

        // Within the hour, nothing is read.
        server.status = 200
        server.body = Data("{}".utf8)
        let soon = live.refreshIfDue { _ in XCTFail("read again within the hour") }
        XCTAssertNil(soon)

        // An hour later it is, and a file that is not a list of covers
        // changes nothing either.
        let notCovers = live.refreshIfDue(now: Date().addingTimeInterval(CartoucheLiveCovers.retryDelay + 60)) { _ in
            XCTFail("covers shown from a file that is not a list of covers")
        }
        await notCovers?.value
        XCTAssertEqual(server.requests, 2)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    }

    @MainActor
    func testOnlyAnHTTPSAddressIsRead() {
        let file = keptFile()
        let refused: CartoucheLiveCovers.Load = { _ in
            XCTFail("an address that is not https was read")
            throw URLError(.badURL)
        }
        let plain = CartoucheLiveCovers(url: URL(string: "http://example.com/covers.json"), file: file, load: refused)
        let plainRead = plain.refreshIfDue { _ in }
        XCTAssertNil(plainRead)
        let none = CartoucheLiveCovers(url: nil, file: file, load: refused)
        let noRead = none.refreshIfDue { _ in }
        XCTAssertNil(noRead)
    }

    func testNoCoversAreKeptAtFirst() {
        XCTAssertEqual(CartoucheLiveCovers.kept(at: keptFile()), [:])
    }
}
