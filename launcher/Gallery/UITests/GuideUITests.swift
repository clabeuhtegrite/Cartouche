//
//  GuideUITests.swift
//  CartoucheGalleryUITests
//
//  The first game's guide, as a player new to Cartouche follows it: it
//  opens by itself on the first launch, before the Apple ID is signed in,
//  on its first step, LocalDevVPN; the account's step sends a player
//  without the pairing file to the setup; once signed in, No thanks skips
//  the Mac's step, and the games folder's step opens the Storage page, or
//  the Files picker, whose IPA closes the guide for the install. The card
//  at the top of the home says the step left and opens the guide again;
//  its × leaves the guide to the System page.
//

import XCTest

final class GuideUITests: ConsoleTestCase {
    /// A new install: no game, the setup not done.
    private let newPlayer = Launch(setupDone: false, owned: [])
    /// Signed in, with no game yet.
    private let signedIn = Launch(owned: [])

    /// The guide opens by itself over the console, its first step open;
    /// Done closes it, and the card at the top of the home says that step
    /// and opens the guide again.
    @MainActor
    func testTheGuideOpensByItselfOnTheFirstLaunch() {
        let app = launchGallery(newPlayer)
        expect(guideBar(in: app).waitForExistence(timeout: Self.firstLaunch),
               "The guide did not open by itself on the first launch", in: app)
        expect(app.buttons[Words.getVPN].waitForExistence(timeout: 10), "The guide's first step, LocalDevVPN, is not open",
               in: app)
        for step in [Words.accountStep, Words.buildStep, Words.folderStep, Words.playStep] {
            expect(element(labelled: step, in: app).exists, "The guide shows no step \(step)", in: app)
        }
        closeGuide(in: app)

        let card = guideCard(in: app)
        expect(card.waitForExistence(timeout: 10), "No guide's card on the home", in: app)
        let step = String(format: Words.guideCard, 1, 5, Words.vpnStep)
        expect(card.label.contains(step), "The guide's card does not say \(step): \(card.label)", in: app)
        tap(card, "the guide's card", in: app)
        expect(guideBar(in: app).waitForExistence(timeout: 15), "The guide's card did not open the guide", in: app)
        closeGuide(in: app)
        expectMainThreadAnswered(app)
    }

    /// Without the pairing file, which the Cartouche Installer alone puts
    /// in place, the account's step says so and opens the setup, which
    /// comes back to the guide.
    @MainActor
    func testTheAccountStepWithoutThePairingFileOpensTheSetup() {
        let app = launchGallery(newPlayer)
        expect(guideBar(in: app).waitForExistence(timeout: Self.firstLaunch),
               "The guide did not open by itself on the first launch", in: app)
        // A later step opens with a tap.
        tap(element(labelled: Words.accountStep, in: app), "the guide's account step", in: app)
        expect(element(beginningWith: Words.noPairingFile, in: app).waitForExistence(timeout: 10),
               "The account's step does not say the pairing file is missing", in: app)
        tap(app.buttons[Words.openSetup], "Open the setup, in the account's step", in: app)
        expect(app.navigationBars[Words.setup].waitForExistence(timeout: 15), "Open the setup did not open the setup",
               in: app)
        back(from: Words.setup, in: app)
        expect(guideBar(in: app).waitForExistence(timeout: 10), "Back from the setup did not come back to the guide", in: app)
        closeGuide(in: app)
        expectMainThreadAnswered(app)
    }

    /// Signed in, with no game: the card says the Mac's step, the guide has
    /// the steps before it done; No thanks skips it, the games folder's
    /// step opens the Storage page, and its Import an IPA instead the Files
    /// picker, whose IPA closes the guide and goes to the install.
    @MainActor
    func testNoThanksSkipsTheMacAndTheGuideImportsAnIPA() {
        let app = openConsole(signedIn)
        let card = guideCard(in: app)
        expect(card.waitForExistence(timeout: 15), "No guide's card on the home", in: app)
        let step = String(format: Words.guideCard, 3, 5, Words.buildStep)
        expect(card.label.contains(step), "The guide's card does not say \(step): \(card.label)", in: app)
        tap(card, "the guide's card", in: app)
        expect(guideBar(in: app).waitForExistence(timeout: 15), "The guide's card did not open the guide", in: app)
        for done in [Words.vpnStep, Words.accountStep] {
            let label = String(format: Words.stepDone, done)
            expect(element(labelled: label, in: app).exists, "The guide does not say \(label)", in: app)
        }
        tap(app.buttons[Words.noThanks], "No thanks, in the Mac's step", in: app)
        let skipped = String(format: Words.stepSkipped, Words.buildStep)
        expect(element(labelled: skipped, in: app).waitForExistence(timeout: 10), "No thanks did not skip the Mac's step",
               in: app)

        // The games folder's step: the Storage page, and back.
        tap(app.buttons[Words.chooseGamesFolder], "Choose the games folder, in the guide", in: app)
        expect(app.navigationBars[Words.storage].waitForExistence(timeout: 15),
               "Choose the games folder did not open the Storage page", in: app)
        back(from: Words.storage, in: app)

        // An IPA instead: the picker over the guide, which closes for the
        // install.
        tap(app.buttons[Words.importInstead], "Import an IPA instead, in the guide", in: app)
        let picker = FilesPicker(app: app, test: self)
        expect(picker.waitForIt(), "The Files picker did not show over the guide", in: app)
        picker.pick(GalleryWords.ipa)
        expect(picker.waitForItToGo(), "The Files picker stayed once the IPA was picked", in: app)
        expectInstall(of: GalleryWords.ipa, in: app)
        expect(!guideBar(in: app).exists, "The guide stayed over the install", in: app)
        expect(waitUntil(10) { isOnConsole(app) }, "The console did not come back after the install", in: app)
        expectMainThreadAnswered(app)
    }

    /// The card's × takes the guide off the home, for good; the System page
    /// opens it then, over the console.
    @MainActor
    func testTheGuideTakenOffTheHomeOpensFromTheSystemPage() {
        let app = openConsole(signedIn)
        tap(app.buttons[Words.guideHide], "the × of the guide's card", in: app)
        expect(waitForGone(guideCard(in: app)), "The guide's card stayed on the home", in: app)
        tap(app.buttons[Words.system], "System in the dock", in: app)
        tap(element(in: app.buttons, beginningWith: Words.guide), "the guide, on the System page", in: app)
        expect(guideBar(in: app).waitForExistence(timeout: 15), "The System page did not open the guide", in: app)
        closeGuide(in: app)
        expect(!guideCard(in: app).exists, "The guide's card came back on the home", in: app)
        expectMainThreadAnswered(app)
    }

    // MARK: The guide

    /// The guide's navigation bar, over the console.
    @MainActor
    private func guideBar(in app: XCUIApplication) -> XCUIElement {
        app.navigationBars[Words.guide]
    }

    /// The card at the top of the home, whose label may begin with its
    /// flag's.
    @MainActor
    private func guideCard(in app: XCUIApplication) -> XCUIElement {
        element(in: app.buttons, containing: Words.guide)
    }

    /// Done of the guide: the console, with nothing over it.
    @MainActor
    private func closeGuide(in app: XCUIApplication) {
        let bar = guideBar(in: app)
        tap(bar.buttons[Words.done], "Done of the guide", in: app)
        expect(waitForGone(bar), "Done did not close the guide", in: app)
        expect(waitUntil(10) { isOnConsole(app) }, "The console did not come back once the guide closed", in: app)
    }
}
