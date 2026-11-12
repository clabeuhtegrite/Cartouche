//
//  SignInUITests.swift
//  CartoucheGalleryUITests
//
//  The Apple ID sign-in, from the System page's setup, with the built-in
//  SideStore stood in for (GallerySideStore in GalleryTesting.swift): it
//  reads the Apple ID and password Cartouche leaves in their keychain, and
//  answers by the Apple ID. "code" in it: Apple asks for a verification code,
//  123456; "limit": Apple refuses more sign-ins for now, with its page of
//  HTTP 429.
//

import XCTest

final class SignInUITests: ConsoleTestCase {
    /// A wrong code gets a new request that says so; the right one signs the
    /// player in, and the setup shows the Apple ID.
    @MainActor
    func testSignInWithAVerificationCode() {
        let app = openConsole(Launch(setupDone: false, pairingOnly: true, typing: true))
        openSignIn(in: app)
        signIn(in: app, appleID: "code@example.com")

        type("111111", inCodeOf: app)
        expect(app.staticTexts[GalleryWords.wrongCode].waitForExistence(timeout: 20),
               "No new request saying the code was wrong", in: app)
        type("123456", inCodeOf: app)

        let signedIn = element(in: app.staticTexts, beginningWith: Words.signedIn)
        expect(signedIn.waitForExistence(timeout: 30), "The setup does not say the Apple ID is signed in", in: app)
        expect(signedIn.label == Words.signedIn + GalleryWords.signedInAs, "The setup says \(signedIn.label)", in: app)
        expect(waitForGone(app.staticTexts[Words.signInTitle]), "The sign-in stayed open once signed in", in: app)
        closeSetup(in: app)
        expectMainThreadAnswered(app)
    }

    /// Apple refusing more sign-ins for now: Cartouche says so in its own
    /// words, counts the wait down in Sign In's place, and its report can be
    /// copied.
    @MainActor
    func testSignInRefusedForTooManyRequests() {
        let app = openConsole(Launch(setupDone: false, pairingOnly: true, typing: true))
        openSignIn(in: app)
        signIn(in: app, appleID: "limit@example.com")

        expect(app.staticTexts[Words.signInFailed].waitForExistence(timeout: 30), "No failure of the sign-in", in: app)
        let everything = app.descendants(matching: .any)
        expect(element(in: everything, beginningWith: Words.tooManyRequests).exists,
               "The failure does not say Apple refuses more sign-ins for now", in: app)
        expect(!element(in: everything, containing: "<html").exists, "Apple's page shows as it came", in: app)
        let wait = element(in: app.buttons, beginningWith: Words.tryAgainIn)
        expect(wait.exists, "No countdown in Sign In's place", in: app)
        expect(!wait.isEnabled, "The countdown can be tapped: \(wait.label)", in: app)

        tap(app.buttons[Words.copyReport], "Copy the report", in: app)
        expect(app.buttons[Words.reportCopied].waitForExistence(timeout: 5), "The report does not say it is copied", in: app)

        tap(app.buttons[Words.cancel], "Cancel of the sign-in", in: app)
        expect(waitForGone(app.staticTexts[Words.signInTitle]), "Cancel did not close the sign-in", in: app)
        closeSetup(in: app)
        expectMainThreadAnswered(app)
    }

    // MARK: Steps

    /// System, Setup, then Sign In: the sign-in's screen.
    @MainActor
    private func openSignIn(in app: XCUIApplication) {
        tap(app.buttons[Words.system], "System in the dock", in: app)
        tap(element(in: app.buttons, beginningWith: Words.setup), "Setup on the System page", in: app)
        tap(app.buttons[Words.signIn].firstMatch, "Sign In of the setup's Apple ID step", in: app)
        expect(app.staticTexts[Words.signInTitle].waitForExistence(timeout: 15), "The sign-in did not open", in: app)
    }

    /// Types the Apple ID and the password, then Go.
    @MainActor
    private func signIn(in app: XCUIApplication, appleID: String) {
        type(appleID, into: app.textFields[Words.appleID], "the Apple ID field", in: app)
        type("not-a-password\n", into: app.secureTextFields[Words.password], "the password field", in: app)
    }

    /// Types CODE in the field of Apple's request, which sends it at the
    /// sixth digit.
    @MainActor
    private func type(_ code: String, inCodeOf app: XCUIApplication) {
        type(code, into: app.textFields[Words.code], "the field of the verification code", in: app, timeout: 30)
    }

    /// From the setup, back to the System page, then Done: the console.
    @MainActor
    private func closeSetup(in app: XCUIApplication) {
        tap(app.navigationBars.buttons.firstMatch, "Back from the setup", in: app)
        tap(app.buttons[Words.done], "Done of the System page", in: app)
        expect(waitUntil(10) { isOnConsole(app) }, "Done did not bring the console back", in: app)
    }
}
