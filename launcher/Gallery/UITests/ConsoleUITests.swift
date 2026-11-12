//
//  ConsoleUITests.swift
//  CartoucheGalleryUITests
//
//  The console's own paths: the home with the player's games, the System
//  page, a game's sheet and its settings, and the watch on the main thread,
//  which must see the thread held on purpose.
//

import XCTest

final class ConsoleUITests: ConsoleTestCase {
    /// The home shows the player's games, the game in focus with Play and
    /// Details, and the dock.
    @MainActor
    func testTheHomeShowsThePlayersGames() {
        let app = openConsole()
        for name in Games.names {
            expect(app.buttons[name].waitForExistence(timeout: 10), "No cover of \(name) on the shelf", in: app)
        }
        expect(app.buttons[Words.details].exists, "No Details for the game in focus", in: app)
        expect(app.buttons[Words.importGame].exists, "No Import in the dock", in: app)
        expect(element(in: app.buttons, beginningWith: Words.allGames).exists, "No All games", in: app)
        expectMainThreadAnswered(app)
    }

    /// The System page opens over the console, with the setup and the
    /// storage, and Done closes it.
    @MainActor
    func testTheSystemPageOpensAndCloses() {
        let app = openConsole()
        tap(app.buttons[Words.system], "System in the dock", in: app)
        expect(element(in: app.buttons, beginningWith: Words.setup).waitForExistence(timeout: 15),
               "The System page shows no Setup", in: app)
        expect(element(in: app.buttons, beginningWith: Words.storage).exists, "The System page shows no Storage", in: app)
        tap(app.buttons[Words.done], "Done of the System page", in: app)
        expect(waitUntil(10) { isOnConsole(app) }, "Done did not bring the console back", in: app)
        expectMainThreadAnswered(app)
    }

    /// Details opens the sheet of the game in focus; its settings open from
    /// there, a setting changed stays changed, and Done goes back to the
    /// console.
    @MainActor
    func testAGamesSheetAndItsSettings() {
        let app = openConsole()
        let touchFeedback = openTouchFeedback(in: app)
        let before = touchFeedback.value as? String
        // The switch, at the end of its row.
        touchFeedback.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.5)).tap()
        let changed = waitUntil(5) { (touchFeedback.value as? String) != before }
        expect(changed, "Touch feedback did not change: \(before ?? "no value")", in: app)
        let after = touchFeedback.value as? String
        tap(app.buttons[Words.done].firstMatch, "Done of the settings", in: app)
        expect(waitUntil(10) { isOnConsole(app) }, "Done did not bring the console back", in: app)

        // Once more: the setting kept its new value.
        let again = openTouchFeedback(in: app)
        expect((again.value as? String) == after,
               "Touch feedback is \(again.value as? String ?? "no value") again, not \(after ?? "no value")", in: app)
        tap(app.buttons[Words.done].firstMatch, "Done of the settings", in: app)
        expect(waitUntil(10) { isOnConsole(app) }, "Done did not bring the console back", in: app)
        expectMainThreadAnswered(app)
    }

    /// The sheet of the game in focus, then its settings, on Controls: the
    /// switch of Touch feedback.
    @MainActor
    private func openTouchFeedback(in app: XCUIApplication) -> XCUIElement {
        tap(app.buttons[Words.details], "Details of the game in focus", in: app)
        tap(app.buttons[Words.gameSettings], "Game settings on the sheet", in: app)
        tap(element(in: app.buttons, containing: Words.controls), "the Controls category", in: app)
        let toggle = element(in: app.switches, beginningWith: Words.touchFeedback)
        expect(toggle.waitForExistence(timeout: 10), "Controls shows no Touch feedback", in: app)
        return toggle
    }

    /// The watch tells a main thread held for a second and a half, as by a
    /// freeze: a watch that saw nothing would let every test pass.
    @MainActor
    func testTheWatchSeesTheMainThreadHeld() {
        let app = openConsole(Launch(holdMainThread: 1.5))
        var reading: MainThreadReading?
        // Held two seconds after the gallery became active.
        let seen = waitUntil(20) {
            reading = mainThread(of: app)
            return (reading?.longest ?? 0) >= 1_200 && (reading?.stalls ?? 0) >= 1
        }
        print("== \(name): \(reading?.text ?? "no readout")")
        expect(seen, "The watch did not see the main thread held for 1.5 s: \(reading?.text ?? "no readout")", in: app)
    }
}
