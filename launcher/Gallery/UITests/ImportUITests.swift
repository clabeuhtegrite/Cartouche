//
//  ImportUITests.swift
//  CartoucheGalleryUITests
//
//  Importing a game: the Files picker from the dock's Import and from the
//  sheet of a game the player does not have yet. It must come, close, and
//  hand over the IPA picked, once, with the console answering throughout.
//  The gallery's install says which IPA it was given (GalleryTesting.swift);
//  the real one, which unpacks and signs the game with LiveContainer, is not
//  in the gallery.
//

import XCTest

final class ImportUITests: ConsoleTestCase {
    /// Import shows the Files picker; Cancel closes it, and the console
    /// answers again.
    @MainActor
    func testImportShowsTheFilesPickerAndCancelGivesTheConsoleBack() {
        let app = openConsole()
        tap(app.buttons[Words.importGame], "Import in the dock", in: app)
        let picker = FilesPicker(app: app, test: self)
        expect(picker.waitForIt(), "The Files picker did not show within a minute of Import", in: app)
        picker.close()
        expect(picker.waitForItToGo(), "The Files picker did not close", in: app)
        expect(waitUntil(10) { isOnConsole(app) }, "The console did not come back once the picker closed", in: app)

        // The console answers: the System page opens, and closes.
        tap(app.buttons[Words.system], "System in the dock", in: app)
        tap(app.buttons[Words.done], "Done of the System page", in: app)
        expect(waitUntil(10) { isOnConsole(app) }, "Done did not bring the console back", in: app)

        // And Import shows the picker again.
        tap(app.buttons[Words.importGame], "Import in the dock, again", in: app)
        expect(picker.waitForIt(), "The Files picker did not show again", in: app)
        picker.close()
        expect(picker.waitForItToGo(), "The Files picker did not close again", in: app)
        expect(waitUntil(10) { isOnConsole(app) }, "The console did not come back", in: app)
        expectMainThreadAnswered(app)
    }

    /// The IPA picked goes to the install, once the picker has gone.
    @MainActor
    func testImportInstallsTheIPAPicked() {
        let app = openConsole()
        tap(app.buttons[Words.importGame], "Import in the dock", in: app)
        let picker = FilesPicker(app: app, test: self)
        expect(picker.waitForIt(), "The Files picker did not show within a minute of Import", in: app)
        picker.pick(GalleryWords.ipa)
        expect(picker.waitForItToGo(), "The Files picker stayed once the IPA was picked", in: app)
        expectInstall(of: GalleryWords.ipa, in: app)
        expect(waitUntil(10) { isOnConsole(app) }, "The console did not come back after the install", in: app)
        expectMainThreadAnswered(app)
    }

    /// From the sheet of a game the player does not have, Import my copy
    /// shows the picker over the sheet; the IPA picked closes the sheet and
    /// goes to the install.
    @MainActor
    func testImportFromTheSheetOfAGameNotThePlayers() {
        let app = openConsole()
        tap(element(in: app.buttons, beginningWith: Words.allGames), "All games", in: app)
        let search = app.searchFields.firstMatch
        tap(search, "the search of every game (\(Words.search))", in: app)
        search.typeText("Sentinels")
        tap(element(in: app.buttons, containing: Games.other), "the cover of \(Games.other)", in: app)
        tap(app.buttons[Words.importCopy], "Import my copy on the sheet", in: app)
        let picker = FilesPicker(app: app, test: self)
        expect(picker.waitForIt(), "The Files picker did not show over the sheet", in: app)
        picker.pick(GalleryWords.ipa)
        expect(picker.waitForItToGo(), "The Files picker stayed once the IPA was picked", in: app)
        expectInstall(of: GalleryWords.ipa, in: app)
        // The sheet went, every game is still there.
        expect(!app.buttons[Words.importCopy].exists, "The sheet stayed over every game after the import", in: app)
        expect(app.searchFields.firstMatch.exists, "Every game went with the sheet", in: app)
        expectMainThreadAnswered(app)
    }

    /// The gallery's install of IPA, the first since it opened, says so over
    /// the console; Done closes it, and no second one follows.
    @MainActor
    private func expectInstall(of ipa: String, in app: XCUIApplication) {
        let alert = app.alerts[GalleryWords.install]
        expect(alert.waitForExistence(timeout: 20), "No install of the IPA picked", in: app)
        let message = "Install 1: \(ipa)"
        expect(alert.staticTexts[message].exists, "The install was not the first, of \(ipa): \(alert.debugDescription)",
               in: app)
        tap(alert.buttons[Words.done], "Done of the install", in: app)
        expect(waitForGone(alert), "The install's alert stayed", in: app)
        // The install happens once.
        Thread.sleep(forTimeInterval: 2)
        expect(!app.alerts[GalleryWords.install].exists, "A second install followed the first", in: app)
    }
}
