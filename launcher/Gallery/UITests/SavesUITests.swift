//
//  SavesUITests.swift
//  CartoucheGalleryUITests
//
//  A game's saves, kept in step with the player's saves folder: Sync now
//  sends them there, and Put back a copy lists the copy, which the player
//  puts back after a question. The sync is Cartouche's own, on real files:
//  only the game's data folder and the saves folder, a folder in Files as
//  the player picks one, are the gallery's, in its own container
//  (GallerySaves, GalleryApp.swift).
//

import XCTest

final class SavesUITests: ConsoleTestCase {
    /// From the sheet of the game, its saves go to the folder, which then
    /// holds one copy of them; put back after a question, it is back in
    /// place, without an error, the console answering throughout. The game
    /// is the first of the player's, whose saves the gallery has (work:
    /// saves), not the one in focus as the console opens.
    @MainActor
    func testTheSavesGoToTheFolderAndTheirCopyComesBack() {
        let app = openConsole(Launch(work: "saves"))
        openSheet(of: Games.names[0], in: app)

        // Never synced yet, then synced.
        let syncNow = String(format: Words.syncNow, GalleryWords.savesFolder)
        let sync = element(in: app.buttons, beginningWith: syncNow)
        scrollTo(sync, "\(syncNow), on the sheet", in: app)
        expect(saysNoneYet(app), "The sheet says the saves were synced before they were", in: app)
        scrollAndTap(sync, "\(syncNow), on the sheet", in: app)
        expect(waitUntil(30) { !saysNoneYet(app) }, "The sheet's last sync still says none once the saves were sent", in: app)
        expect(app.alerts.count == 0, "Syncing the saves showed an error: \(app.alerts.firstMatch.debugDescription)", in: app)

        // Their one copy in the folder, put back.
        scrollAndTap(element(in: app.buttons, beginningWith: Words.putBack), "\(Words.putBack), on the sheet", in: app)
        expect(app.navigationBars[Words.putBack].waitForExistence(timeout: 15), "\(Words.putBack) did not open", in: app)
        // A copy is named by its date, which has the year.
        let year = String(Calendar.current.component(.year, from: Date()))
        let copy = element(in: app.buttons, containing: year)
        expect(copy.waitForExistence(timeout: 30), "\(Words.putBack) lists no copy of the saves just sent", in: app)
        tap(copy, "the copy of the saves", in: app)
        tap(element(in: app.buttons, beginningWith: Words.putBackCopy), "Put back the copy, in the question", in: app)
        expect(element(beginningWith: Words.putBackDone, in: app).waitForExistence(timeout: 30),
               "The copy of the saves is not back in place", in: app)
        expect(app.alerts.count == 0, "Putting the copy back showed an error: \(app.alerts.firstMatch.debugDescription)",
               in: app)

        back(from: Words.putBack, in: app)
        closeSheet(in: app)
        expectMainThreadAnswered(app)
    }

    /// Whether the sheet's last sync says there is none yet: as the value
    /// of its row, or as a text of its own.
    @MainActor
    private func saysNoneYet(_ app: XCUIApplication) -> Bool {
        let row = element(beginningWith: Words.lastSync, in: app)
        if row.exists, row.label.contains(Words.noneYet) || (row.value as? String)?.contains(Words.noneYet) == true {
            return true
        }
        return app.staticTexts[Words.noneYet].exists
    }
}
