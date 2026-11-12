//
//  StorageUITests.swift
//  CartoucheGalleryUITests
//
//  The Storage page, from the System page: every kind of place it adds,
//  each form opening and closing; the player's NAS out of reach away from
//  home, which the page says without an error, with the saves waiting for
//  it and Try again; the player's Mac, paired, as the games folder; and
//  Add your Mac, with the Macs nearby, the digits to
//  check on both screens, and iOS refusing the local network. The gallery
//  stands in for the servers and the Macs (GalleryApp.swift): nothing here
//  reaches a real one, but the NAS's Try again, which knocks on its
//  address, as the app does, and finds no one.
//

import XCTest

final class StorageUITests: ConsoleTestCase {
    /// With no place yet, the page says to add one first and offers each
    /// kind, whose forms open and close: S3, FTP, and a folder in Files,
    /// with the Files picker.
    @MainActor
    func testTheStoragePageOffersEveryKindOfPlace() {
        let app = openConsole()
        openStorage(in: app)
        expect(element(beginningWith: Words.addFirst, in: app).waitForExistence(timeout: 10),
               "The Storage page does not say to add a place first", in: app)
        for form in [Words.addS3, Words.addFTP] {
            let row = app.buttons[form]
            scrollTo(row, "\(form) on the Storage page", in: app)
            tap(row, "\(form) on the Storage page", in: app)
            let bar = app.navigationBars[form]
            expect(bar.waitForExistence(timeout: 15), "\(form) did not open its form", in: app)
            tap(bar.buttons[Words.cancel], "Cancel of \(form)", in: app)
            expect(waitForGone(bar), "Cancel did not close \(form)", in: app)
        }
        expect(app.buttons[Words.addMac].exists, "The Storage page does not offer \(Words.addMac)", in: app)

        let folder = app.buttons[Words.addFolder]
        scrollTo(folder, "\(Words.addFolder) on the Storage page", in: app)
        tap(folder, "\(Words.addFolder) on the Storage page", in: app)
        let picker = FilesPicker(app: app, test: self)
        expect(picker.waitForIt(), "\(Words.addFolder) did not show the Files picker", in: app)
        picker.close()
        expect(picker.waitForItToGo(), "The Files picker of \(Words.addFolder) did not close", in: app)
        expect(app.navigationBars[Words.storage].waitForExistence(timeout: 10),
               "The Storage page did not come back once the Files picker closed", in: app)
        closeStorage(in: app)
        expectMainThreadAnswered(app)
    }

    /// The player's NAS, out of reach away from home: the System page says
    /// it is offline; the Storage page says it does not answer, without an
    /// error, with the games it listed and two games' saves waiting for it;
    /// Try again knocks on it, finds no one, and says so the same way.
    @MainActor
    func testANASOutOfReachSaysSoAndTriesAgainWithoutAnError() {
        let app = openConsole(Launch(work: "offline"))
        tap(app.buttons[Words.system], "System in the dock", in: app)
        let row = element(in: app.buttons, beginningWith: Words.storage)
        expect(row.waitForExistence(timeout: 15), "No Storage on the System page", in: app)
        let offlineShort = String(format: Words.offlineShort, "NAS")
        expect(row.label.contains(offlineShort) || (row.value as? String)?.contains(offlineShort) == true,
               "The System page does not say \(offlineShort): \(row.label)", in: app)
        tap(row, "Storage on the System page", in: app)
        expect(app.navigationBars[Words.storage].waitForExistence(timeout: 15), "The Storage page did not open", in: app)

        let offline = String(format: Words.offline, "NAS")
        expect(element(beginningWith: offline, in: app).waitForExistence(timeout: 10),
               "The Storage page does not say \(offline)", in: app)
        let waiting = String(format: Words.savesWaiting, 2)
        let saves = element(beginningWith: waiting, in: app)
        scrollTo(saves, "\(waiting) on the Storage page", in: app)
        let tryAgain = app.buttons[Words.tryAgain]
        scrollTo(tryAgain, "Try again for the saves", in: app)
        tap(tryAgain, "Try again for the saves", in: app)
        // The knock gives up within six seconds, and Try again comes back.
        Thread.sleep(forTimeInterval: 6)
        expect(waitUntil(15) { app.buttons[Words.tryAgain].exists && app.buttons[Words.tryAgain].isEnabled },
               "Try again did not come back once the NAS did not answer", in: app)
        expect(element(beginningWith: offline, in: app).exists, "The Storage page no longer says \(offline)", in: app)
        expect(app.alerts.count == 0, "Trying the NAS again showed an error: \(app.alerts.firstMatch.debugDescription)",
               in: app)
        closeStorage(in: app)
        expectMainThreadAnswered(app)
    }

    /// The player's Mac, paired: the System page says the games folder is
    /// on it, and the Storage page lists it among the places, with nothing
    /// left to add first.
    @MainActor
    func testTheMacPairedHoldsTheGames() {
        let app = openConsole(Launch(work: "mac"))
        tap(app.buttons[Words.system], "System in the dock", in: app)
        let row = element(in: app.buttons, beginningWith: Words.storage)
        expect(row.waitForExistence(timeout: 15), "No Storage on the System page", in: app)
        expect(row.label.contains("MacBook Air") || (row.value as? String)?.contains("MacBook Air") == true,
               "The System page does not say the games folder is on the Mac: \(row.label)", in: app)
        tap(row, "Storage on the System page", in: app)
        expect(app.navigationBars[Words.storage].waitForExistence(timeout: 15), "The Storage page did not open", in: app)
        let place = element(in: app.buttons, beginningWith: "MacBook Air")
        scrollTo(place, "the Mac among the places", in: app)
        expect(!element(beginningWith: Words.addFirst, in: app).exists, "The Storage page says to add a place first", in: app)
        closeStorage(in: app)
        expectMainThreadAnswered(app)
    }

    /// Add your Mac lists the Macs whose Cartouche Builder shares with
    /// Cartouche, on this network.
    @MainActor
    func testAddYourMacListsTheMacsNearby() {
        let app = openAddYourMac(Launch(work: "mac-nearby"))
        for mac in ["MacBook Air", "Mac mini"] {
            expect(element(in: app.buttons, beginningWith: mac).waitForExistence(timeout: 15),
                   "Add your Mac does not list \(mac)", in: app)
        }
        closeAddYourMac(in: app)
        expectMainThreadAnswered(app)
    }

    /// Pairing with a Mac, Add your Mac shows the six digits the Mac shows
    /// too, to check on both screens.
    @MainActor
    func testAddYourMacShowsTheDigitsToCheck() {
        let app = openAddYourMac(Launch(work: "mac-code"))
        // Read out one by one.
        expect(element(labelled: "4 8 2 9 1 5", in: app).waitForExistence(timeout: 15), "Add your Mac shows no digits",
               in: app)
        expect(element(beginningWith: Words.checkDigits, in: app).exists, "Add your Mac does not say to check the digits",
               in: app)
        closeAddYourMac(in: app)
        expectMainThreadAnswered(app)
    }

    /// iOS refusing Cartouche the local network, Add your Mac says where to
    /// allow it, and looks for no Mac.
    @MainActor
    func testAddYourMacWithoutTheLocalNetwork() {
        let app = openAddYourMac(Launch(work: "mac-refused"))
        expect(element(beginningWith: Words.noLocalNetwork, in: app).waitForExistence(timeout: 15),
               "Add your Mac does not say iOS refuses the local network", in: app)
        closeAddYourMac(in: app)
        expectMainThreadAnswered(app)
    }

    // MARK: Steps

    /// System, then Storage.
    @MainActor
    private func openStorage(in app: XCUIApplication) {
        tap(app.buttons[Words.system], "System in the dock", in: app)
        tap(element(in: app.buttons, beginningWith: Words.storage), "Storage on the System page", in: app)
        expect(app.navigationBars[Words.storage].waitForExistence(timeout: 15), "The Storage page did not open", in: app)
    }

    /// Back to the System page, then Done: the console.
    @MainActor
    private func closeStorage(in app: XCUIApplication) {
        back(from: Words.storage, in: app)
        tap(app.buttons[Words.done], "Done of the System page", in: app)
        expect(waitUntil(10) { isOnConsole(app) }, "Done did not bring the console back", in: app)
    }

    /// The gallery opened as LAUNCH says, then the Storage page's Add your
    /// Mac.
    @MainActor
    private func openAddYourMac(_ launch: Launch) -> XCUIApplication {
        let app = openConsole(launch)
        openStorage(in: app)
        let add = app.buttons[Words.addMac]
        scrollTo(add, "\(Words.addMac) on the Storage page", in: app)
        tap(add, "\(Words.addMac) on the Storage page", in: app)
        expect(app.navigationBars[Words.yourMac].waitForExistence(timeout: 15), "Add your Mac did not open", in: app)
        return app
    }

    /// Cancel of Add your Mac, then back to the console.
    @MainActor
    private func closeAddYourMac(in app: XCUIApplication) {
        let bar = app.navigationBars[Words.yourMac]
        tap(bar.buttons[Words.cancel], "Cancel of Add your Mac", in: app)
        expect(waitForGone(bar), "Cancel did not close Add your Mac", in: app)
        closeStorage(in: app)
    }
}
