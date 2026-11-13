//
//  SavesUITests.swift
//  CartoucheGalleryUITests
//
//  A game's saves, kept in step with the player's saves folder: Sync now
//  sends them there, and Put back a copy lists the copy, which the player
//  puts back after a question. The sync is Cartouche's own, on real files:
//  only the game's data folder and the saves folder, a folder in Files as
//  the player picks one, are the gallery's, in its own container
//  (GallerySaves, GalleryApp.swift). And the game's saves between the
//  player's Switch and this iPhone: the save JKSV exported there, a ZIP
//  archive the gallery writes in its folder of On My iPhone, picked in
//  Files and put in place after a question, the save it replaced put back,
//  and the game's save made into a ZIP archive for JKSV, all of it
//  Cartouche's own on real files too.
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

    /// From the sheet of the game, Switch saves: the save JKSV exported on
    /// the Switch, picked in Files, is read as the game's by JKSV's fiche
    /// and put in place of the game's after a question; the save it
    /// replaced comes back after another; the game's save goes into a ZIP
    /// archive for JKSV, to share; all without an error, the console
    /// answering throughout.
    @MainActor
    func testASaveFromTheSwitchComesInAndTheGamesGoesBackToIt() {
        let app = openConsole(Launch(work: "saves"))
        openSheet(of: Games.names[0], in: app)
        scrollAndTap(element(in: app.buttons, beginningWith: Words.switchSaves), "\(Words.switchSaves), on the sheet", in: app)
        expect(app.navigationBars[Words.switchSaves].waitForExistence(timeout: 15), "\(Words.switchSaves) did not open",
               in: app)

        // The save JKSV exported, picked in Files, read as the game's.
        scrollAndTap(element(in: app.buttons, beginningWith: Words.chooseExport), Words.chooseExport, in: app)
        let picker = FilesPicker(app: app, test: self)
        expect(picker.waitForIt(), "The Files picker did not show within a minute of \(Words.chooseExport)", in: app)
        picker.pick(GalleryWords.switchExport)
        expect(picker.waitForItToGo(), "The Files picker stayed once the save was picked", in: app)
        let continueHere = element(in: app.buttons, beginningWith: Words.continueHere)
        expect(continueHere.waitForExistence(timeout: 30), "The save picked was not read", in: app)
        expect(says(Words.game, Words.checkedByFiche, in: app), "The save picked was not read as the game's, by JKSV's fiche",
               in: app)

        // In place, after the question.
        scrollAndTap(continueHere, "\(Words.continueHere), under the save read", in: app)
        expect(element(labelled: Words.continueQuestion, in: app).waitForExistence(timeout: 15),
               "\(Words.continueHere) did not ask first", in: app)
        tapButtonOnTop(Words.continueHere, "\(Words.continueHere), in the question", in: app)
        expect(element(beginningWith: Words.imported, in: app).waitForExistence(timeout: 30),
               "The save from the Switch is not in place", in: app)

        // The save it replaced, back after the question.
        let putBack = element(in: app.buttons, beginningWith: Words.putBackImport)
        scrollAndTap(putBack, "\(Words.putBackImport), once the save is in place", in: app)
        expect(element(labelled: Words.putBackImportQuestion, in: app).waitForExistence(timeout: 15),
               "\(Words.putBackImport) did not ask first", in: app)
        tapButtonOnTop(Words.putBackImport, "\(Words.putBackImport), in the question", in: app)
        expect(element(beginningWith: Words.putBackImportDone, in: app).waitForExistence(timeout: 30),
               "The save from before the import is not back", in: app)

        // The game's save, in a ZIP archive for JKSV to share, once the
        // save in place has gone to the saves folder.
        let make = app.buttons[Words.makeZip]
        scrollTo(make, "\(Words.makeZip), on the page", in: app)
        expect(waitUntil(60) { make.isEnabled }, "\(Words.makeZip) stayed greyed out", in: app)
        scrollAndTap(make, "\(Words.makeZip), on the page", in: app)
        let share = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@ AND label ENDSWITH %@", Words.shareZip, ".zip"))
            .firstMatch
        expect(share.waitForExistence(timeout: 30), "No ZIP archive for JKSV to share", in: app)
        expect(app.alerts.count == 0,
               "The saves between the Switch and this iPhone showed an error: \(app.alerts.firstMatch.debugDescription)", in: app)

        back(from: Words.switchSaves, in: app)
        closeSheet(in: app)
        expectMainThreadAnswered(app)
    }

    /// Whether the page says TEXT for its row LABEL: as the row's value, in
    /// its label, or as a text of its own.
    @MainActor
    private func says(_ label: String, _ text: String, in app: XCUIApplication) -> Bool {
        let row = element(labelled: label, in: app)
        if row.exists, (row.value as? String)?.contains(text) == true { return true }
        return app.staticTexts[text].exists || element(containing: text, in: app).exists
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
