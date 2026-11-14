//
//  ShortcutTests.swift
//  CartoucheHarnessTests
//
//  Siri and Shortcuts, on LiveContainer's own list of apps
//  (CartoucheShortcuts.swift): the games they may name are the player's
//  installed games, by the names the console gives them, with the shorter
//  ones no other game could take; Play a Game asks the console for its game,
//  which then starts as Play starts it, or says why it cannot: the game
//  since uninstalled, or Cartouche busy with another.
//

import XCTest
@testable import CartoucheHarness

final class ShortcutTests: HarnessCase {
    private var shortcuts: CartoucheGameShortcuts { CartoucheGameShortcuts.shared }

    override func setUp() async throws {
        try await super.setUp()
        shortcuts.drop()
    }

    override func tearDown() async throws {
        shortcuts.drop()
        try await super.tearDown()
    }

    /// The console's name of the installed game APP.
    private func consoleName(of app: LCAppModel) throws -> String {
        try XCTUnwrap(CartoucheCatalog.shared.entries(for: model.apps).owned.first { $0.app === app }).name
    }

    func testTheGamesAreThePlayersInstalledOnesByTheConsolesNames() async throws {
        let first = try await installed(.plain(0))
        let second = try await installed(.plain(1))
        let query = CartoucheGameQuery()

        let games = try await query.suggestedEntities()
        let firstId = try XCTUnwrap(first.appInfo.bundleIdentifier())
        let secondId = try XCTUnwrap(second.appInfo.bundleIdentifier())
        XCTAssertEqual(Set(games.map(\.id)), [firstId, secondId])
        let names = [try consoleName(of: first), try consoleName(of: second)]
        for game in games {
            let name = game.id == firstId ? names[0] : names[1]
            XCTAssertEqual(game.name, name)
            XCTAssertEqual(game.synonyms, CartoucheGameNames.synonyms(of: name, among: names))
        }

        // A game a shortcut names, by its identifier; one gone, none.
        let found = try await query.entities(for: [secondId, "org.nxnative.0000000000000000"])
        XCTAssertEqual(found.map(\.id), [secondId])
        // What the player types: the beginning of a word of its name.
        let word = String(try XCTUnwrap(names[0].split(separator: " ").first).prefix(3))
        let matching = try await query.entities(matching: word)
        XCTAssertTrue(matching.contains { $0.id == firstId }, "\(word) finds \(names[0])")
        let none = try await query.entities(matching: "zzqxj")
        XCTAssertTrue(none.isEmpty)
    }

    func testPlayAGameAsksTheConsoleForItsGame() async throws {
        let app = try await installed(.plain())
        let games = try await CartoucheGameQuery().suggestedEntities()
        let game = try XCTUnwrap(games.first)

        _ = try await CartouchePlayGameIntent(game: game).perform()

        let request = try XCTUnwrap(shortcuts.request, "the console has the game to start")
        XCTAssertEqual(request.id, app.appInfo.bundleIdentifier())
        XCTAssertEqual(request.name, app.displayName)
        XCTAssertNil(actions.work, "the console starts it, as Play does")
        shortcuts.take(request)
        XCTAssertNil(shortcuts.request)
    }

    func testAGameUninstalledSinceIsNoLongerThere() async throws {
        let app = try await installed(.plain())
        let before = try await CartoucheGameQuery().suggestedEntities()
        let game = try XCTUnwrap(before.first)
        actions.uninstall(app, erasingData: true)
        try await waitUntil("the game is uninstalled") { actions.work == nil }

        do {
            _ = try await CartouchePlayGameIntent(game: game).perform()
            XCTFail("Siri starts a game no longer installed")
        } catch let error as CartoucheShortcutError {
            XCTAssertEqual(error.kind, .notInstalled)
            XCTAssertEqual(error.message, CartoucheText.shortcutNotInstalled(game.name))
        }
        XCTAssertNil(shortcuts.request)
        let games = try await CartoucheGameQuery().suggestedEntities()
        XCTAssertTrue(games.isEmpty)
    }

    func testCartoucheBusyWithAnInstallSaysSo() async throws {
        let playing = try await installed(.plain(0))
        let games = try await CartoucheGameQuery().suggestedEntities()
        let game = try XCTUnwrap(games.first { $0.id == playing.appInfo.bundleIdentifier() })
        HarnessLC.signingTime = 1
        actions.install(try HarnessIPA.game(.plain(1)))
        let work = try XCTUnwrap(actions.work)

        do {
            _ = try await CartouchePlayGameIntent(game: game).perform()
            XCTFail("Siri asks for a game while Cartouche installs another")
        } catch let error as CartoucheShortcutError {
            XCTAssertEqual(error.kind, .busy)
            XCTAssertEqual(error.message, CartoucheText.shortcutBusy(work.title))
        }
        XCTAssertNil(shortcuts.request, "no game starts once the install is over")
        try await waitUntil("the install is over") { actions.work == nil }
        XCTAssertNil(shortcuts.request)
    }
}
