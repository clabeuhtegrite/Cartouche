//
//  WhatsNewUITests.swift
//  CartoucheGalleryUITests
//
//  What's new over the console as Cartouche opens after an update, which it
//  decides as Cartouche does (CartoucheWhatsNewView.swift): the notes of the
//  version installed, until Continue, with no word of the update after
//  them; nothing on a new install; and the System page's What's new.
//

import XCTest

final class WhatsNewUITests: ConsoleTestCase {
    /// After an update started from Cartouche, from 0.2.0 to the gallery's
    /// version, 0.3.0 (project.yml): What's new in Cartouche 0.3.0 over the
    /// console, with 0.3.0's notes (app/releases/0.3.0.md). Continue closes
    /// it, the console answers, and no word that the update is installed
    /// follows, What's new having said so.
    @MainActor
    func testAnUpdateShowsWhatsNewUntilContinue() {
        let app = launchGallery(Launch(work: "updated"))
        let title = element(labelled: String(format: Words.whatsNewTitle, "0.3.0"), in: app)
        expect(title.waitForExistence(timeout: Self.firstLaunch), "No What's new over the console after the update", in: app)
        expect(element(beginningWith: "Your own storage", in: app).exists, "What's new does not show 0.3.0's notes", in: app)
        tap(app.buttons[Words.whatsNewContinue], "Continue, on What's new", in: app)
        expect(waitForGone(title), "Continue did not close What's new", in: app)
        expect(waitUntil(10) { isOnConsole(app) }, "The console did not come back once What's new closed", in: app)
        let installed = element(labelled: String(format: Words.updateInstalled, "0.3.0"), in: app)
        expect(!installed.waitForExistence(timeout: 3), "The word that the update is installed followed What's new", in: app)
        expectMainThreadAnswered(app)
    }

    /// A new install shows no What's new, its version counting as seen. The
    /// System page's What's new lists the notes of the versions the gallery
    /// carries, and comes back to it.
    @MainActor
    func testANewInstallShowsNoneAndTheSystemPageListsThem() {
        let app = openConsole()
        let shown = element(beginningWith: String(format: Words.whatsNewTitle, ""), in: app)
        expect(!shown.waitForExistence(timeout: 3), "What's new showed on a new install", in: app)
        tap(app.buttons[Words.system], "System in the dock", in: app)
        expect(app.navigationBars[Words.system].waitForExistence(timeout: 15), "The System page did not open", in: app)
        let row = app.buttons[Words.releaseNotes]
        scrollTo(row, "What's new on the System page", in: app)
        tap(row, "What's new on the System page", in: app)
        expect(app.navigationBars[Words.releaseNotes].waitForExistence(timeout: 15), "What's new did not open", in: app)
        // A version's header, however the list writes it.
        let version = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH[c] %@", "Cartouche 0.")).firstMatch
        expect(version.waitForExistence(timeout: 10), "What's new lists no version", in: app)
        back(from: Words.releaseNotes, in: app)
        expect(app.navigationBars[Words.system].waitForExistence(timeout: 10),
               "Back from What's new did not come back to the System page", in: app)
        tap(app.buttons[Words.done], "Done of the System page", in: app)
        expect(waitUntil(10) { isOnConsole(app) }, "Done did not bring the console back", in: app)
        expectMainThreadAnswered(app)
    }
}
