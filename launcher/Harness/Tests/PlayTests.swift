//
//  PlayTests.swift
//  CartoucheHarnessTests
//
//  Play, in Cartouche's place, as LiveContainer's Run does
//  (CartoucheGameActions.play, LCAppModel.runApp): the game's data folder
//  on its first start, nxnative's switch for its settings screen, the
//  game's language, the signature, and what the player reads when the game
//  cannot start. LiveContainer then quits Cartouche for the game: the
//  harness records what it would open (HarnessLC.launches).
//

import XCTest
@testable import CartoucheHarness

final class PlayTests: HarnessCase {
    override func setUp() async throws {
        try await super.setUp()
        // Every game starts in Cartouche's place.
        CartoucheGameKeeping.shared.keepsConsoleOpen = false
    }

    private func play(_ app: LCAppModel, showingSettings: Bool = false,
                      file: StaticString = #filePath, line: UInt = #line) async throws {
        actions.play(app, showingSettings: showingSettings)
        XCTAssertEqual(actions.work?.kind, .starting, file: file, line: line)
        try await waitUntil("the start is over", file: file, line: line) { actions.work == nil }
    }

    private func env(of app: LCAppModel) throws -> String? {
        try? String(contentsOf: try dataFolder(of: app).appendingPathComponent("Documents/env.txt"), encoding: .utf8)
    }

    func testPlayStartsTheGameInCartouchesPlace() async throws {
        let game = HarnessGame.plain()
        let app = try await installed(game)
        try await play(app)

        XCTAssertNil(actions.notice)
        let folder = try dataFolder(of: app)
        XCTAssertEqual(HarnessLC.launches, [HarnessLC.Launch(bundle: app.appInfo.relativeBundlePath,
                                                             container: folder.lastPathComponent, classicMode: 0)])
        XCTAssertNil(actions.running)
        XCTAssertTrue(HarnessScenes.all.isEmpty)
        let launched: Date? = app.appInfo.lastLaunched
        XCTAssertNotNil(launched)

        // Its data folder, as LiveContainer makes it on a first start.
        let info = try XCTUnwrap(NSDictionary(contentsOf: folder.appendingPathComponent("LCContainerInfo.plist")))
        XCTAssertEqual(info["appIdentifier"] as? String, game.bundleIdentifier)
        XCTAssertEqual(app.uiContainers.map(\.folderName), [folder.lastPathComponent])
        XCTAssertEqual(app.uiSelectedContainer?.folderName, folder.lastPathComponent)

        // nxnative skips its settings screen.
        XCTAssertEqual(try env(of: app), CartoucheStartSwitch.note + "\nDM_LAUNCHER=0\n")
        // It starts in the iPhone's first language that it has, else its own.
        let language = CartoucheGameLanguage.best(for: Locale.preferredLanguages, among: game.languages) ?? game.languages[0]
        XCTAssertEqual(try preference(CartoucheGameLanguage.savedKey, of: app), language)
        XCTAssertEqual(try preference(CartoucheGameLanguage.sourceKey, of: app), "iPhone")
        // Signed at its install: not again.
        XCTAssertEqual(HarnessLC.signed.count, 1)
    }

    func testTheSecondStartUsesTheSameDataFolder() async throws {
        let app = try await installed(.plain())
        try await play(app)
        let folder = try dataFolder(of: app)
        try await play(app)
        XCTAssertEqual(HarnessLC.launches.map(\.container), [folder.lastPathComponent, folder.lastPathComponent])
        XCTAssertEqual(app.uiContainers.count, 1)
        XCTAssertEqual(try env(of: app), CartoucheStartSwitch.note + "\nDM_LAUNCHER=0\n")
    }

    func testStartingOnNxnativesScreenTakesTheLineOut() async throws {
        let app = try await installed(.plain())
        try await play(app)
        try await play(app, showingSettings: true)
        XCTAssertNil(try env(of: app), "nothing else was in env.txt: it goes")
        XCTAssertEqual(HarnessLC.launches.count, 2)
        try await play(app)
        XCTAssertEqual(try env(of: app), CartoucheStartSwitch.note + "\nDM_LAUNCHER=0\n")
    }

    func testTheLinesThePlayerWroteInEnvStay() async throws {
        let app = try await installed(.plain())
        _ = actions.settings(for: app, tileKey: "")
        try write("DM_RES_SCALE=1.50\n# mine\n", in: try dataFolder(of: app), at: "Documents/env.txt")
        try await play(app)
        XCTAssertEqual(try env(of: app), "DM_RES_SCALE=1.50\n# mine\n" + CartoucheStartSwitch.note + "\nDM_LAUNCHER=0\n")
        try await play(app, showingSettings: true)
        XCTAssertEqual(try env(of: app), "DM_RES_SCALE=1.50\n# mine\n")
    }

    func testALanguageThePlayerChoseStays() async throws {
        let game = HarnessGame.plain()
        let app = try await installed(game)
        _ = actions.settings(for: app, tileKey: "")
        let folder = try dataFolder(of: app)
        let home = URL(fileURLWithPath: NSHomeDirectory() + "/Documents/Data/Application/" + folder.lastPathComponent,
                       isDirectory: true)
        let choices = try XCTUnwrap(CartoucheGamePreferences(domain: game.bundleIdentifier, home: home))
        choices.keepLanguage(CartoucheGameLanguage.chosen("fr"))

        try await play(app)
        XCTAssertEqual(try preference(CartoucheGameLanguage.savedKey, of: app), "fr")
        XCTAssertEqual(try preference(CartoucheGameLanguage.sourceKey, of: app), "player")
    }

    func testAGameInClassicModeStartsAsLiveContainerRunsIt() async throws {
        let app = try await installed(.plain())
        app.appInfo.classicMode = true
        try await play(app)
        XCTAssertEqual(HarnessLC.launches.count, 1)
        XCTAssertEqual(HarnessLC.launches.first?.classicMode, app.appInfo.defaultClassicMode)
        XCTAssertNotEqual(HarnessLC.launches.first?.classicMode, 0)
    }

    // MARK: A game that cannot start

    func testACertificateIOSNoLongerAcceptsStopsTheStartAndSaysSo() async throws {
        let app = try await installed(.plain())
        HarnessLC.iOSRefusesCertificate = true
        try await play(app)
        XCTAssertTrue(HarnessLC.launches.isEmpty)
        XCTAssertEqual(actions.notice?.title, CartoucheText.startFailed)
        XCTAssertEqual(actions.notice?.message, CartoucheText.startCertificateRefused)
        XCTAssertNotNil(actions.notice?.report)
        XCTAssertEqual(CartoucheSetup.shared.certificateWorks, false, "the setup knows the certificate no longer works")
        XCTAssertEqual(HarnessLC.signed.count, 2, "LiveContainer signed it again first")
    }

    func testAGameSignedWithAnOldCertificateIsSignedAgainAtItsStart() async throws {
        let app = try await installed(.plain())
        HarnessLC.installCertificate(HarnessCertificate(team: "HARNESS001", password: "harness", serial: 77))
        try await play(app)
        XCTAssertNil(actions.notice)
        XCTAssertEqual(HarnessLC.signed.count, 2)
        XCTAssertEqual(HarnessLC.launches.count, 1)
    }

    func testZsignFailingAtTheStartSaysWhy() async throws {
        let app = try await installed(.plain())
        HarnessLC.installCertificate(HarnessCertificate(team: "HARNESS001", password: "harness", serial: 78))
        HarnessLC.signing = .fails("zsign: the certificate's private key does not open")
        try await play(app)
        XCTAssertTrue(HarnessLC.launches.isEmpty)
        XCTAssertEqual(actions.notice?.title, CartoucheText.startFailed)
        XCTAssertEqual(actions.notice?.message, "zsign: the certificate's private key does not open")
    }

    // MARK: A game LiveContainer did not sign whole

    /// A game zsign did not sign whole as it was installed, its executable
    /// signed all the same, as Breath of the Wild's were: LiveContainer
    /// would start it as it is, iOS running its executable. Play signs it
    /// again, whole, once, then starts it.
    func testAGameNotSignedWholeAtItsInstallIsSignedAgainWholeAtItsStart() async throws {
        HarnessLC.signing = .cannotSign(["Frameworks/MoltenVK.framework/MoltenVK"])
        let result = try await install(try HarnessIPA.game(.plain()))
        let app = try XCTUnwrap(result)
        XCTAssertEqual(app.appInfo.cartoucheSigningFailure, "filesNotSigned")
        XCTAssertEqual(HarnessLC.signed.count, 1)

        HarnessLC.signing = .signs
        actions.notice = nil
        try await play(app)
        XCTAssertNil(actions.notice)
        XCTAssertEqual(HarnessLC.signed.count, 2, "signed again, whole")
        XCTAssertNil(app.appInfo.cartoucheSigningFailure, "the mark goes")
        XCTAssertEqual(HarnessLC.launches.count, 1)

        // Signed whole: not again at the next start.
        try await waitUntil("LiveContainer let go of the game") { !app.isAppRunning }
        try await play(app)
        XCTAssertEqual(HarnessLC.signed.count, 2)
        XCTAssertEqual(HarnessLC.launches.count, 2)
    }

    /// A game LiveContainer must sign again at its start, and cannot: the
    /// player reads why, and may sign it again and play from the notice,
    /// which signs it whole, once, then starts it.
    func testAGameThatDoesNotSignAtItsStartSaysWhyAndOffersToSignItAgain() async throws {
        let game = HarnessGame.plain()
        let app = try await installed(game)
        HarnessLC.installCertificate(HarnessCertificate(team: "HARNESS001", password: "harness", serial: 79))
        HarnessLC.signing = .cannotSign([game.executable])
        try await play(app)
        XCTAssertTrue(HarnessLC.launches.isEmpty)
        XCTAssertEqual(actions.notice?.title, CartoucheText.notSignedTitle(app.displayName))
        XCTAssertEqual(actions.notice?.message, CartoucheText.notSignedFiles + " " + CartoucheText.notSignedAtStart)
        XCTAssertEqual(actions.notice?.signAgain, game.bundleIdentifier)
        XCTAssertEqual(app.appInfo.cartoucheSigningFailure, "filesNotSigned")
        let said = actions.notice?.report?.facts.first { $0.name == "LiveContainer said" }?.value ?? ""
        XCTAssertTrue(said.hasPrefix("Failed to Sign /") && said.hasSuffix("/" + game.executable), said)

        HarnessLC.signing = .signs
        let signed = HarnessLC.signed.count
        try await waitUntil("LiveContainer let go of the game") { !app.isAppRunning }
        actions.signAgain(game.bundleIdentifier)
        XCTAssertEqual(actions.work?.kind, .starting)
        try await waitUntil("the start is over") { actions.work == nil }
        XCTAssertNil(actions.notice)
        XCTAssertEqual(HarnessLC.signed.count, signed + 1, "signed again, whole, once")
        XCTAssertNil(app.appInfo.cartoucheSigningFailure)
        XCTAssertEqual(HarnessLC.launches.count, 1)
    }

    /// Signing it again whole at its start fails: the start goes on, as
    /// LiveContainer starts a game iOS runs the executable of, and the
    /// mark goes, so that it is not signed again at each start for nothing.
    func testAGameThatStillDoesNotSignWholeStartsAllTheSame() async throws {
        HarnessLC.signing = .cannotSign(["Frameworks/MoltenVK.framework/MoltenVK"])
        let result = try await install(try HarnessIPA.game(.plain()))
        let app = try XCTUnwrap(result)
        actions.notice = nil
        try await play(app)
        XCTAssertNil(actions.notice)
        XCTAssertEqual(HarnessLC.signed.count, 2, "signed again, whole, once")
        XCTAssertNil(app.appInfo.cartoucheSigningFailure)
        XCTAssertEqual(HarnessLC.launches.count, 1)
        XCTAssertTrue(CartoucheReports.journal(last: 40).contains {
            $0.contains("not signed again whole (filesNotSigned): notSigned; fileKind framework, files 1, kind filesNotSigned")
        }, "the journal says why, in names")
    }
}
