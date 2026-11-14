//
//  BuildStoppersTests.swift
//  BuilderKitTests
//
//  What stops a build before it starts, as the app says it (14 November
//  2026): an Xcode older than the one nxnative builds the shaders with
//  (MacSetup.swift), and the games no Mac built yet (Unbuilt.swift).
//

import Foundation
import XCTest
@testable import BuilderKit

final class BuildStoppersTests: XCTestCase {
    /// Xcode 27.1, whose Metal compiler nxnative refuses: Ocarina of Time's
    /// eight builds on one Mac.
    func testAnXcodeOlderThanNxnativesIsOlderNumberByNumber() {
        XCTAssertTrue(MacSetup.older("27.1", than: "27.2"))
        XCTAssertTrue(MacSetup.older("26.4.1", than: "27.2"))
        XCTAssertTrue(MacSetup.older("27", than: "27.0.1"))
        XCTAssertFalse(MacSetup.older("27.2", than: "27.2"))
        XCTAssertFalse(MacSetup.older("27.2.0", than: "27.2"))
        XCTAssertFalse(MacSetup.older("27.10", than: "27.2"))
        XCTAssertFalse(MacSetup.older("28.0 beta", than: "27.2"))
        XCTAssertFalse(MacSetup.older("", than: "27.2"))
        XCTAssertFalse(MacSetup.older("27.1", than: "unknown"))
    }

    /// The Xcode to build with: the chosen one when it is recent enough,
    /// else nxnative's own version, else the newest; an older one only when
    /// there is no other, for the page to say it is too old.
    func testTheXcodeToBuildWith() {
        let old = (path: "/Applications/Xcode.app", version: "27.1")
        let wanted = (path: "/Applications/Xcode-27.2.app", version: "27.2")
        let beta = (path: "/Applications/Xcode-beta.app", version: "27.3")
        func pick(_ found: [(path: String, version: String)], chosen: String) -> String? {
            MacSetup.pick(found, chosen: chosen, wanted: "27.2")?.path
        }
        XCTAssertEqual(pick([old, wanted, beta], chosen: "/Applications/Xcode-beta.app/Contents/Developer"), beta.path)
        XCTAssertEqual(pick([old, wanted, beta], chosen: "/Applications/Xcode.app/Contents/Developer"), wanted.path)
        XCTAssertEqual(pick([old, beta], chosen: "/Applications/Xcode.app/Contents/Developer"), beta.path)
        XCTAssertEqual(pick([old], chosen: "/Applications/Xcode.app/Contents/Developer"), old.path)
        XCTAssertEqual(pick([old], chosen: ""), old.path)
        XCTAssertNil(pick([], chosen: ""))
    }

    /// unbuilt.json, as the nxnative page workflow writes it
    /// (telemetry/nxnative.py, unbuilt): by title ID, without what is not a
    /// game of its own.
    func testTheGamesNoMacBuilt() throws {
        let json = #"""
            {"schema": 1, "from": "2026-10-15", "to": "2026-11-11", "games": [
              {"titleId": "0400a3a01ee4c000", "macs": 4, "failures": 8, "hours": 4.7, "stage": "iOS shaders"},
              {"titleId": "0100F2C0115B6000", "macs": 3, "failures": 3},
              {"titleId": "0100", "macs": 3, "failures": 3},
              {"titleId": "010093801237C000", "macs": 0, "failures": 0}]}
            """#
        let games = try XCTUnwrap(UnbuiltGames.parse(Data(json.utf8)))
        XCTAssertEqual(games.keys.sorted(), ["0100F2C0115B6000", "0400A3A01EE4C000"])
        XCTAssertEqual(games["0400A3A01EE4C000"], UnbuiltGame(titleID: "0400a3a01ee4c000", macs: 4, failures: 8, hours: 4.7, stage: "iOS shaders"))
        XCTAssertNil(games["0100F2C0115B6000"]?.hours)
        XCTAssertNil(UnbuiltGames.parse(Data("<html>".utf8)))
        XCTAssertEqual(UnbuiltGames.parse(Data(#"{"schema": 1, "games": []}"#.utf8)), [:])
    }

    /// What a game's sheet says of one, in the player's language.
    func testWhatTheSheetSaysOfAGameNoMacBuilt() {
        defer { L10n.use("") }
        let pokopia = UnbuiltGame(titleID: "0400A3A01EE4C000", macs: 4, failures: 8, hours: 4.7, stage: "iOS shaders")
        L10n.use("en")
        XCTAssertEqual(UnbuiltGames.words(pokopia),
                       "In the last 4 weeks, 4 Macs tried it with Cartouche Builder and all 8 of their builds failed, most often at the step “iOS shaders”, "
                       + "after about 4.7 hours. Building it may keep this Mac busy for hours for nothing: better wait until nxnative improves it. "
                       + "The nightly builds leave it aside.")
        L10n.use("fr")
        XCTAssertEqual(UnbuiltGames.words(UnbuiltGame(titleID: "0400A3A01EE4C000", macs: 3, failures: 5), named: { $0.uppercased() }),
                       "Ces 4 dernières semaines, 3 Mac l’ont essayé avec Cartouche Builder et leurs 5 constructions ont toutes échoué. "
                       + "Sa construction peut occuper ce Mac des heures pour rien : mieux vaut attendre que nxnative l’améliore. "
                       + "Les constructions de la nuit le laissent de côté.")
        XCTAssertTrue(UnbuiltGames.words(pokopia, named: { $0.uppercased() }).contains("à l’étape « IOS SHADERS », après 4,7 h environ."))
    }

    /// The copy the nightly run reads (cartouche_builder/batch.py, unbuilt)
    /// is in the engine's folder.
    func testTheListIsKeptWhereTheEngineReadsIt() {
        let home = BuilderHome(URL(fileURLWithPath: "/Users/player/Library/Application Support/Cartouche Builder"))
        XCTAssertEqual(home.unbuilt.path, "/Users/player/Library/Application Support/Cartouche Builder/unbuilt.json")
    }
}
