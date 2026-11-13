//
//  ShortcutUITests.swift
//  CartoucheGalleryUITests
//
//  Siri and the Home Screen (CartoucheShortcuts.swift): Play a Game, as iOS
//  hands it to Cartouche, starts its game as Play does, once, as Cartouche
//  opens or with something over the console, which goes first; without the
//  certificate it opens the setup, as Play does; a game no longer installed
//  is said so, and nothing starts. A game's sheet says what to say to Siri,
//  with the game's shorter name, and how to give it an icon of its own.
//

import XCTest

final class ShortcutUITests: ConsoleTestCase {
    /// Siri asks for a game as Cartouche opens, before its console shows:
    /// the console comes, and starts that game, once.
    @MainActor
    func testSiriStartsAGameAsCartoucheOpens() {
        let app = launchGallery(Launch(siri: Games.owned[1]))
        expectPlay(of: Games.names[1], timeout: Self.firstLaunch, in: app)
        expect(waitUntil(10) { isOnConsole(app) }, "The console did not come back after the start", in: app)
        expectMainThreadAnswered(app)
    }

    /// A game's sheet open over the console, then the System page: each
    /// goes, and the game Siri asked for starts.
    @MainActor
    func testWhatIsOverTheConsoleGoesForTheGameSiriAskedFor() {
        let app = openConsole(Launch(siriOnPost: Games.owned[0]))
        openSheet(of: Games.names[1], in: app)
        askSiri()
        expectPlay(of: Games.names[0], in: app)
        expect(!sheetShows(Games.names[1], in: app, timeout: 2), "The sheet stayed over the console", in: app)
        expect(waitUntil(10) { isOnConsole(app) }, "The console did not come back after the sheet", in: app)

        tap(app.buttons[Words.system], "System in the dock", in: app)
        expect(app.navigationBars[Words.system].waitForExistence(timeout: 15), "The System page did not open", in: app)
        askSiri()
        expectPlay(of: Games.names[0], count: 2, in: app)
        expect(!app.navigationBars[Words.system].exists, "The System page stayed over the console", in: app)
        expect(waitUntil(10) { isOnConsole(app) }, "The console did not come back after the System page", in: app)
        expectMainThreadAnswered(app)
    }

    /// Without the certificate, the game Siri asked for opens the setup, as
    /// Play does, and does not start.
    @MainActor
    func testWithoutTheCertificateSiriOpensTheSetupAsPlayDoes() {
        let app = launchGallery(Launch(setupDone: false, siri: Games.owned[0]))
        expect(app.navigationBars[Words.setup].waitForExistence(timeout: Self.firstLaunch),
               "The setup did not open for the game Siri asked for", in: app)
        expect(!app.alerts[GalleryWords.play].exists, "The game started without the certificate", in: app)
        tapButtonOnTop(Words.done, "Done of the setup", in: app)
        expect(waitUntil(10) { isOnConsole(app) }, "Done did not bring the console back", in: app)
        expect(!app.alerts[GalleryWords.play].exists, "The game started once the setup closed", in: app)
        expectMainThreadAnswered(app)
    }

    /// A shortcut of a game uninstalled since: Siri says so, and nothing
    /// starts.
    @MainActor
    func testAGameNoLongerInstalledIsSaidSo() {
        let app = launchGallery(Launch(owned: Array(Games.owned.prefix(2)), siri: Games.owned[2]))
        let alert = app.alerts[GalleryWords.shortcutFailed]
        expect(alert.waitForExistence(timeout: Self.firstLaunch), "Siri said nothing of the game no longer installed", in: app)
        let message = String(format: Words.noLongerInstalled, Games.names[2])
        expect(alert.staticTexts[message].exists, "Siri did not say \(message): \(alert.debugDescription)", in: app)
        tap(alert.buttons[Words.done], "Done of what Siri said", in: app)
        expect(waitUntil(10) { isOnConsole(app) }, "Done did not bring the console back", in: app)
        expect(!app.alerts[GalleryWords.play].exists, "A game started", in: app)
        expectMainThreadAnswered(app)
    }

    /// Siri and Home Screen, from a game's sheet: the sentence for Siri,
    /// with the game's shorter name, the steps to its icon and Open
    /// Shortcuts; back to the sheet.
    @MainActor
    func testAGamesSheetSaysWhatToSayToSiri() {
        let app = openConsole()
        let name = Games.names[0]
        openSheet(of: name, in: app)
        scrollAndTap(element(in: app.buttons, beginningWith: Words.siriAndHomeScreen), "Siri and Home Screen on the sheet", in: app)
        expect(app.navigationBars[Words.siriAndHomeScreen].waitForExistence(timeout: 15), "Siri and Home Screen did not open", in: app)
        let phrase = String(format: Words.siriPhrase, name)
        expect(element(labelled: phrase, in: app).waitForExistence(timeout: 10), "The page does not say \(phrase)", in: app)
        // Mario Kart World is Mario Kart too: no other of the player's games
        // could take it.
        let shorter = String(format: Words.siriShorter, "Mario Kart")
        expect(element(labelled: shorter, in: app).exists, "The page does not say \(shorter)", in: app)
        scrollTo(element(beginningWith: Words.homeScreenIcon, in: app), "An icon on the Home Screen", in: app)
        scrollTo(element(in: app.buttons, beginningWith: Words.openShortcuts), "Open Shortcuts", in: app)
        back(from: Words.siriAndHomeScreen, in: app)
        expect(sheetShows(name, in: app), "Back did not come back to the sheet of \(name)", in: app)
        closeSheet(in: app)
        expectMainThreadAnswered(app)
    }
}
