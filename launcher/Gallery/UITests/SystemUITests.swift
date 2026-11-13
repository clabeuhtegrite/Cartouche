//
//  SystemUITests.swift
//  CartoucheGalleryUITests
//
//  The System page and every page it opens, each of which must come and go
//  with the console answering throughout; Reset Cartouche, at its end,
//  which asks twice before it erases; and Cartouche's own update, on offer
//  over the console, which Later puts off.
//

import XCTest

final class SystemUITests: ConsoleTestCase {
    /// Setup, Storage, Renew every night, Game measurements and Report a
    /// problem each open from the System page, with what they are for, and
    /// come back to it; Done closes it.
    @MainActor
    func testEveryPageOfTheSystemPageOpensAndComesBack() {
        let app = openConsole()
        tap(app.buttons[Words.system], "System in the dock", in: app)
        expect(app.navigationBars[Words.system].waitForExistence(timeout: 15), "The System page did not open", in: app)
        // Each row, and what its page shows, if it is to be told apart by
        // more than its title.
        let pages: [(row: String, shows: String?)] = [
            (Words.setup, nil),
            (Words.storage, Words.storageIntro),
            (Words.renewEveryNight, Words.openShortcuts),
            (Words.telemetry, Words.sendMeasurements),
            (Words.report, nil),
        ]
        for page in pages {
            let row = element(in: app.buttons, beginningWith: page.row)
            scrollTo(row, "\(page.row) on the System page", in: app)
            tap(row, "\(page.row) on the System page", in: app)
            expect(app.navigationBars[page.row].waitForExistence(timeout: 15), "\(page.row) did not open", in: app)
            // A list draws its rows only as they come on the screen: down
            // to it, once the page is there.
            if let shows = page.shows {
                let shown = element(beginningWith: shows, in: app)
                _ = shown.waitForExistence(timeout: 5)
                scrollTo(shown, "\(shows) on \(page.row)", in: app)
            }
            back(from: page.row, in: app)
            expect(app.navigationBars[Words.system].waitForExistence(timeout: 10),
                   "Back from \(page.row) did not come back to the System page", in: app)
        }
        tap(app.buttons[Words.done], "Done of the System page", in: app)
        expect(waitUntil(10) { isOnConsole(app) }, "Done did not bring the console back", in: app)
        expectMainThreadAnswered(app)
    }

    /// Reset Cartouche, at the end of the System page, asks twice before it
    /// erases anything: its button, then its confirmation, whose Cancel
    /// leaves everything as it was. Erase everything covers the page while
    /// Cartouche erases, then restarts: the gallery's reset only shows it,
    /// and comes back to the page (CartoucheReset.swift).
    @MainActor
    func testResetCartoucheAsksTwiceBeforeItErases() {
        let app = openConsole()
        tap(app.buttons[Words.system], "System in the dock", in: app)
        expect(app.navigationBars[Words.system].waitForExistence(timeout: 15), "The System page did not open", in: app)
        scrollAndTap(element(in: app.buttons, beginningWith: Words.resetCartouche), "Reset Cartouche on the System page", in: app)
        expect(app.navigationBars[Words.resetCartouche].waitForExistence(timeout: 15), "Reset Cartouche did not open", in: app)
        let erase = element(in: app.buttons, beginningWith: Words.eraseAndRestart)
        let erasing = element(labelled: Words.erasing, in: app)
        // Once, then Cancel: nothing happens.
        scrollAndTap(erase, "Erase everything and restart", in: app)
        tapButtonOnTop(Words.cancel, "Cancel of the confirmation", in: app)
        expect(!erasing.waitForExistence(timeout: 3), "Cancel erased all the same", in: app)
        // Then Erase everything.
        scrollAndTap(erase, "Erase everything and restart, again", in: app)
        tapButtonOnTop(Words.eraseEverything, "Erase everything, in the confirmation", in: app)
        expect(erasing.waitForExistence(timeout: 10), "Erase everything did not cover the page while Cartouche erases", in: app)
        expect(waitForGone(erasing, timeout: 15), "The gallery's reset did not end", in: app)
        back(from: Words.resetCartouche, in: app)
        tap(app.buttons[Words.done], "Done of the System page", in: app)
        expect(waitUntil(10) { isOnConsole(app) }, "Done did not bring the console back", in: app)
        expectMainThreadAnswered(app)
    }

    /// A newer Cartouche on offer shows over the console, with Update and
    /// Later; Later puts it off, and the console answers again.
    @MainActor
    func testANewVersionOnOfferIsPutOffByLater() {
        let app = launchGallery(Launch(work: "update"))
        // The gallery's version is 0.3.0 (project.yml), the one on offer
        // 0.4.0 (GalleryApp.swift).
        let offer = element(labelled: String(format: Words.updateOffer, "0.4.0"), in: app)
        expect(offer.waitForExistence(timeout: Self.firstLaunch), "No update on offer over the console", in: app)
        expect(app.buttons[Words.update].exists, "The update on offer has no Update", in: app)
        tap(app.buttons[Words.later], "Later, on the update on offer", in: app)
        expect(waitForGone(offer), "Later did not put the update off", in: app)
        expect(waitUntil(10) { isOnConsole(app) }, "The console did not come back once the update was put off", in: app)
        expectMainThreadAnswered(app)
    }
}
