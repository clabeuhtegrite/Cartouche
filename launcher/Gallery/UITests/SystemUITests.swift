//
//  SystemUITests.swift
//  CartoucheGalleryUITests
//
//  The System page and every page it opens, each of which must come and go
//  with the console answering throughout; the builds of the player's Mac,
//  driven from there; and Cartouche's own update, on offer over the
//  console, which Later puts off.
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

    /// The builds of the player's Mac, from the System page, while Cartouche
    /// Builder builds a game and another waits its turn: what is due joins
    /// the queue, Stop all stops every game, a game the Mac does not follow
    /// is followed then left again from its menu, and the nightly build is
    /// turned off; back on the System page, Done closes it.
    @MainActor
    func testTheMacsBuildsAreDrivenFromTheSystemPage() {
        let app = openConsole(Launch(work: "mac-builds"))
        tap(app.buttons[Words.system], "System in the dock", in: app)
        expect(app.navigationBars[Words.system].waitForExistence(timeout: 15), "The System page did not open", in: app)
        // The Mac paired in Storage, by its name (GalleryMac.paired).
        let row = element(in: app.buttons, beginningWith: String(format: Words.macBuildsOn, "MacBook Air"))
        scrollTo(row, "the Mac's builds on the System page", in: app)
        tap(row, "the Mac's builds on the System page", in: app)
        expect(app.navigationBars[Words.macBuildsPage].waitForExistence(timeout: 15), "The Mac's builds did not open", in: app)

        // Pikmin 4, which nxnative improved, after the game waiting.
        let list = app.collectionViews.descendants(matching: .any)
        tap(app.buttons[Words.addWhatIsDue], "Add what is due", in: app)
        scrollTo(element(in: list, beginningWith: "2. Pikmin 4"), "the game due, second in the queue", in: app)

        // Every game of the batch stops: nothing waits, and what is due can
        // be built again.
        scrollAndTap(app.buttons[Words.stopAll], "Stop all", in: app)
        expect(waitForGone(element(in: list, beginningWith: "1. ")), "A game still waits its turn once all stopped", in: app)
        expect(app.buttons[Words.buildWhatIsDue].waitForExistence(timeout: 10), "No Build what is due once all stopped", in: app)

        // Super Mario Odyssey, which the Mac does not follow: followed, then
        // not again.
        let menu = app.buttons[String(format: Words.macGameActions, "Super Mario Odyssey")]
        scrollAndTap(menu, "the menu of the game the Mac does not follow", in: app)
        tap(app.buttons[Words.follow], "Follow, in the game's menu", in: app)
        expect(waitForGone(element(in: list, beginningWith: Words.macNotFollowed)), "The game followed still says it is not", in: app)
        scrollAndTap(menu, "the menu of the game followed", in: app)
        tap(app.buttons[Words.stopFollowing], "Stop following, in the game's menu", in: app)
        expect(element(in: list, beginningWith: Words.macNotFollowed).waitForExistence(timeout: 10),
               "The game left does not say it is not followed", in: app)

        // The nightly build, on at 3:30: off, its time no longer said.
        let nightly = app.switches[Words.nightly].firstMatch
        scrollTo(nightly, "the nightly build", in: app)
        expect((nightly.value as? String) == "1", "The nightly build is not on", in: app)
        expect(element(beginningWith: Words.nightlyAt, in: app).exists, "The nightly build does not say when", in: app)
        // The switch itself, at the row's end: a tap on its words does not
        // turn it.
        nightly.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        expect(waitUntil(10) { (nightly.value as? String) == "0" }, "The nightly build did not turn off", in: app)
        expect(waitForGone(element(beginningWith: Words.nightlyAt, in: app)), "The nightly build off still says when", in: app)

        back(from: Words.macBuildsPage, in: app)
        expect(app.navigationBars[Words.system].waitForExistence(timeout: 10),
               "Back from the Mac's builds did not come back to the System page", in: app)
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
