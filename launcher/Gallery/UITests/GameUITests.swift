//
//  GameUITests.swift
//  CartoucheGalleryUITests
//
//  A game of the player's beyond its settings: its info, which the player
//  changes from its sheet and puts back to Cartouche's; the game paused
//  behind the console, which the home offers to resume or to quit, Quit
//  asking first; and an install, under way over the console, or failed,
//  with the report to copy. The gallery stands in for the games, their
//  install and their process (GalleryStubs.swift).
//

import XCTest

final class GameUITests: ConsoleTestCase {
    /// The first of the player's games, the one work: paused pauses; the
    /// console opens with another in focus, the first by name.
    private var game: String { Games.names[0] }

    /// The game's info, from its sheet: a new name shows on the sheet and
    /// on the home; Back to Cartouche's info puts the old one back.
    @MainActor
    func testTheInfoOfAGameChangesAndGoesBack() {
        let app = openConsole(Launch(typing: true))
        let name = "My Kart"
        editInfo(of: game, in: app)
        replaceText(in: app.textFields.firstMatch, with: name, "the game's name", in: app)
        saveInfo(in: app)
        expect(sheetShows(name, in: app), "The sheet does not show the new name, \(name)", in: app)
        closeSheet(in: app)
        expect(app.buttons[name].waitForExistence(timeout: 10), "The home does not show the new name, \(name)", in: app)
        expect(!app.buttons[game].exists, "The home still shows \(game) under its new name", in: app)

        // Back to Cartouche's info.
        editInfo(of: name, in: app)
        scrollAndTap(app.buttons[Words.backToCartouchesInfo], "Back to Cartouche's info", in: app)
        saveInfo(in: app)
        expect(sheetShows(game, in: app), "The sheet does not show \(game) again", in: app)
        closeSheet(in: app)
        expect(app.buttons[game].waitForExistence(timeout: 10), "The home does not show \(game) again", in: app)
        expect(!app.buttons[name].exists, "The home still shows \(name)", in: app)
        expectMainThreadAnswered(app)
    }

    /// The game paused behind the console: the home offers Resume and
    /// Quit, and so does its sheet, which says it is paused; Quit asks
    /// first, and the game stays paused until the player says so.
    @MainActor
    func testAGamePausedBehindTheConsoleAsksBeforeQuitting() {
        let app = openConsole(Launch(work: "paused"))
        expect(app.buttons[Words.resume].waitForExistence(timeout: 15), "The home does not offer to resume the game paused",
               in: app)
        let question = String(format: Words.quitQuestion, game)
        askToQuit(question, in: app)
        expect(app.buttons[Words.resume].waitForExistence(timeout: 10), "The game paused went once the question was answered",
               in: app)

        openSheet(of: game, in: app)
        expect(element(beginningWith: Words.paused, in: app).waitForExistence(timeout: 15),
               "The sheet does not say the game is paused behind Cartouche", in: app)
        expect(buttonOnTop(Words.resume, in: app, timeout: 5) != nil, "The sheet does not offer to resume the game paused",
               in: app)
        askToQuit(question, in: app)
        closeSheet(in: app)
        expectMainThreadAnswered(app)
    }

    /// A game being installed: over the console, its name, the step under
    /// way, and that the player can leave Cartouche meanwhile, as iOS goes
    /// on with it; the console answers throughout. The install reads as one
    /// element, whose label joins its lines.
    @MainActor
    func testAnInstallUnderWayShowsOverTheConsole() {
        let app = launchGallery(Launch(work: "installing", sheet: Games.owned[0]))
        let title = String(format: Words.installing, game)
        let install = element(containing: title, in: app)
        expect(install.waitForExistence(timeout: Self.firstLaunch), "No \(title) over the console", in: app)
        expect(install.label.contains(Words.unpacking), "The install does not say what it does now: \(install.label)", in: app)
        expect(install.label.contains(Words.canLeave), "The install does not say the player can leave Cartouche: \(install.label)",
               in: app)
        // A few seconds of it, as a player would watch it.
        Thread.sleep(forTimeInterval: 3)
        expectMainThreadAnswered(app)
    }

    /// An install the network dropped halfway: the alert says the game was
    /// not installed and offers its report, which Copy the report copies,
    /// as a banner says for a moment, and the console comes back.
    @MainActor
    func testAFailedInstallGivesItsReport() {
        let app = launchGallery(Launch(work: "install-failed", sheet: Games.owned[0]))
        let alert = app.alerts[Words.installFailed]
        expect(alert.waitForExistence(timeout: Self.firstLaunch), "No alert of the install that failed", in: app)
        tap(alert.buttons[Words.copyReport], "Copy the report, on the alert", in: app)
        // The banner reads as one element, and goes after two seconds and a
        // half.
        expect(element(containing: Words.reportCopied, in: app).waitForExistence(timeout: 5),
               "No word that the report was copied", in: app)
        expect(waitForGone(alert), "Copy the report did not close the alert", in: app)
        expect(waitUntil(10) { isOnConsole(app) }, "The console did not come back after the report", in: app)
        expectMainThreadAnswered(app)
    }

    // MARK: Steps

    /// From the home, the sheet of the game named NAME, then its info.
    @MainActor
    private func editInfo(of name: String, in app: XCUIApplication) {
        openSheet(of: name, in: app)
        scrollAndTap(app.buttons[Words.editInfo], "Edit the game's info on the sheet", in: app)
        expect(app.navigationBars[Words.gameInfo].waitForExistence(timeout: 15), "The game's info did not open", in: app)
    }

    /// Save of the game's info, which closes it, back on the sheet.
    @MainActor
    private func saveInfo(in app: XCUIApplication) {
        let bar = app.navigationBars[Words.gameInfo]
        tap(bar.buttons[Words.save], "Save of the game's info", in: app)
        expect(waitForGone(bar), "Save did not close the game's info", in: app)
    }

    /// Quit, on top, the home's or the sheet's, then the question,
    /// QUESTION: the game stays paused until Quit the game, which the
    /// gallery's stand-in answers by closing the question.
    @MainActor
    private func askToQuit(_ question: String, in app: XCUIApplication) {
        tapButtonOnTop(Words.quit, "Quit, for the game paused", in: app)
        let asked = element(labelled: question, in: app)
        expect(asked.waitForExistence(timeout: 10), "Quit did not ask \(question)", in: app)
        tap(app.buttons[Words.quitGame], "Quit the game, in the question", in: app)
        expect(waitForGone(asked), "The question stayed once answered", in: app)
    }
}
