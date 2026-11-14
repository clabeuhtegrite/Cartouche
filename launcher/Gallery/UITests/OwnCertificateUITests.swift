//
//  OwnCertificateUITests.swift
//  CartoucheGalleryUITests
//
//  Cartouche signed with the player's own certificate
//  (docs/imported-signing.md). Signed on the iPhone by a signing app: the
//  guide's first step is the certificate, whose import asks for the
//  certificate and its password, never a profile; the setup says what the
//  signature lacks; a new version is one to download, never to install from
//  Cartouche. Signed by the Cartouche Installer: a new version is one to
//  install from the Installer.
//

import XCTest

final class OwnCertificateUITests: ConsoleTestCase {
    /// The guide opens by itself with the certificate's step open, in the
    /// place of LocalDevVPN's and the Apple ID's; its import asks for the
    /// certificate and its password alone; the card on the home says that
    /// step, the first of four.
    @MainActor
    func testSignedOnTheIPhoneTheGuideAsksForTheCertificateAlone() {
        let app = launchGallery(Launch(setupDone: false, owned: [], signing: "iphone"))
        let guide = app.navigationBars[Words.guide]
        expect(guide.waitForExistence(timeout: Self.firstLaunch), "The guide did not open by itself on the first launch", in: app)
        expect(app.buttons[Words.importCertificate].waitForExistence(timeout: 10),
               "The guide's first step, the certificate, is not open", in: app)
        expect(element(beginningWith: Words.howOnIPhone, in: app).exists,
               "The certificate's step does not ask for the certificate the signing app used", in: app)
        for step in [Words.certificateStep, Words.buildStep, Words.folderStep, Words.playStep] {
            expect(element(labelled: step, in: app).exists, "The guide shows no step \(step)", in: app)
        }
        for step in [Words.vpnStep, Words.accountStep] {
            expect(!element(labelled: step, in: app).exists, "The guide shows \(step), which only an Apple ID needs", in: app)
        }

        tap(app.buttons[Words.importCertificate], "Import signing certificate, in the guide", in: app)
        expect(app.navigationBars[Words.importCertificate].waitForExistence(timeout: 15),
               "Import signing certificate did not open", in: app)
        expect(app.buttons[Words.chooseCertificate].exists, "No button to choose the certificate", in: app)
        expect(!app.buttons[Words.chooseProfile].exists, "Signed on the iPhone, Cartouche asks for a profile", in: app)
        expect(app.secureTextFields[Words.certificatePassword].exists, "No field for the certificate's password", in: app)
        expect(!app.buttons[Words.useCertificate].isEnabled, "Use this certificate works without a certificate", in: app)
        back(from: Words.importCertificate, in: app)
        expect(guide.waitForExistence(timeout: 10), "Back from the import did not come back to the guide", in: app)

        tap(guide.buttons[Words.done], "Done of the guide", in: app)
        expect(waitForGone(guide), "Done did not close the guide", in: app)
        expect(waitUntil(10) { isOnConsole(app) }, "The console did not come back once the guide closed", in: app)
        let card = element(in: app.buttons, containing: Words.guide)
        expect(card.waitForExistence(timeout: 10), "No guide's card on the home", in: app)
        let step = String(format: Words.guideCard, 1, 4, Words.certificateStep)
        expect(card.label.contains(step), "The guide's card does not say \(step): \(card.label)", in: app)
        expectMainThreadAnswered(app)
    }

    /// The setup, from the System page, has the certificate's step without
    /// the Apple ID's, and says what the signature lacks: Increased Memory
    /// Limit, which the signing app left out, and the games' keychain
    /// groups.
    @MainActor
    func testSignedOnTheIPhoneTheSetupSaysWhatTheSignatureLacks() {
        let app = openConsole(Launch(setupDone: false, work: "iml-left-out", signing: "iphone"))
        tap(app.buttons[Words.system], "System in the dock", in: app)
        expect(app.navigationBars[Words.system].waitForExistence(timeout: 15), "The System page did not open", in: app)
        let row = element(in: app.buttons, beginningWith: Words.setup)
        scrollTo(row, "Setup on the System page", in: app)
        tap(row, "Setup on the System page", in: app)
        expect(app.navigationBars[Words.setup].waitForExistence(timeout: 15), "Setup did not open", in: app)
        expect(app.buttons[Words.importCertificate].waitForExistence(timeout: 10), "The setup has no import of the certificate",
               in: app)
        expect(!app.buttons[Words.signIn].exists, "Signed with the player's own certificate, the setup asks for an Apple ID", in: app)
        for words in [Words.signature, Words.memoryLeftOut, Words.keychainsLeftOut] {
            let shown = element(beginningWith: words, in: app)
            _ = shown.waitForExistence(timeout: 5)
            scrollTo(shown, "\(words) in the setup", in: app)
        }
        back(from: Words.setup, in: app)
        tap(app.buttons[Words.done], "Done of the System page", in: app)
        expect(waitUntil(10) { isOnConsole(app) }, "Done did not bring the console back", in: app)
        expectMainThreadAnswered(app)
    }

    /// A newer Cartouche on offer, signed on the iPhone: its IPA to
    /// download, which the signing app signs, or Later, which puts it off.
    @MainActor
    func testSignedOnTheIPhoneANewVersionIsOneToDownload() {
        let app = launchGallery(Launch(work: "update", signing: "iphone"))
        // The gallery's version is 0.3.0 (project.yml), the one on offer
        // 0.4.0 (GalleryApp.swift).
        let offer = element(labelled: String(format: Words.updateOffer, "0.4.0"), in: app)
        expect(offer.waitForExistence(timeout: Self.firstLaunch), "No update on offer over the console", in: app)
        expect(element(beginningWith: String(format: Words.offerOnIPhone, "0.3.0"), in: app).exists,
               "The update on offer does not say to download it and sign it", in: app)
        expect(app.buttons[Words.download].exists, "The update on offer has no Download", in: app)
        tap(app.buttons[Words.later], "Later, on the update on offer", in: app)
        expect(waitForGone(offer), "Later did not put the update off", in: app)
        expect(waitUntil(10) { isOnConsole(app) }, "The console did not come back once the update was put off", in: app)
        expectMainThreadAnswered(app)
    }

    /// A newer Cartouche on offer, signed by the Cartouche Installer: the
    /// Installer on the computer installs it, and Done puts it off.
    @MainActor
    func testSignedByTheInstallerANewVersionIsOneForTheInstaller() {
        let app = launchGallery(Launch(work: "update", signing: "installer"))
        let offer = element(labelled: String(format: Words.updateOffer, "0.4.0"), in: app)
        expect(offer.waitForExistence(timeout: Self.firstLaunch), "No update on offer over the console", in: app)
        expect(element(beginningWith: String(format: Words.offerOnComputer, "0.3.0"), in: app).exists,
               "The update on offer does not send to the Cartouche Installer", in: app)
        expect(!app.buttons[Words.download].exists, "The Installer's install offers a download", in: app)
        tapButtonOnTop(Words.done, "Done, on the update on offer", in: app)
        expect(waitForGone(offer), "Done did not put the update off", in: app)
        expect(waitUntil(10) { isOnConsole(app) }, "The console did not come back once the update was put off", in: app)
        expectMainThreadAnswered(app)
    }
}
