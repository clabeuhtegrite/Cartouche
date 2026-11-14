//
//  InstallTests.swift
//  CartoucheHarnessTests
//
//  A game's install from an IPA on the iPhone, as the Files picker or
//  another app hands it to Cartouche (CartoucheGameActions.install), its
//  replacement by another build, and its uninstall: what LiveContainer
//  unpacks, signs and keeps, what the console shows, and what the player
//  reads when it goes wrong.
//

import Combine
import XCTest
@testable import CartoucheHarness

final class InstallTests: HarnessCase {
    // MARK: A game

    func testInstallsAGameFromItsIPA() async throws {
        let game = HarnessGame.plain()
        let app = try await installed(game)

        XCTAssertTrue(model.apps.contains(app))
        XCTAssertEqual(app.appInfo.bundleIdentifier(), game.bundleIdentifier)
        XCTAssertEqual(app.appInfo.displayName(), game.name)
        XCTAssertEqual(app.appInfo.relativeBundlePath, game.bundleIdentifier + ".app")
        let bundle = try bundle(of: app)
        XCTAssertEqual(bundle.deletingLastPathComponent().standardizedFileURL.path, LCPath.bundlePath.standardizedFileURL.path)

        // The whole game, as nxnative built it, and what LiveContainer
        // added: its record of the app, the signature and the profile.
        let files = listing(of: bundle)
        for expected in ["Info.plist", game.executable, "PkgInfo", "dm/", "dm/launcher.json", "dm/settings.tsv", "romfs.img",
                         "Frameworks/MoltenVK.framework/MoltenVK", "Frameworks/MoltenVK.framework/Info.plist",
                         "LCAppInfo.plist", "_CodeSignature/CodeResources", "embedded.mobileprovision"] {
            XCTAssertTrue(files.contains(expected), "\(expected) is in the installed game: \(files)")
        }
        XCTAssertEqual(try Data(contentsOf: bundle.appendingPathComponent("romfs.img")),
                       HarnessRomFS.image(bytes: game.romfsBytes, seed: game.titleId))
        XCTAssertEqual(try Data(contentsOf: bundle.appendingPathComponent("dm/launcher.json")), game.launcherJSON)
        let attributes = try FileManager.default.attributesOfItem(atPath: bundle.appendingPathComponent(game.executable).path)
        let mode = (attributes[.posixPermissions] as? NSNumber)?.intValue ?? 0
        XCTAssertEqual(mode & 0o111, 0o111, "the executable stays executable")

        // Signed once, with the certificate LiveContainer has, and patched.
        XCTAssertEqual(HarnessLC.signed, [bundle.path])
        XCTAssertTrue(HarnessLC.signatureIsValid(bundle.appendingPathComponent(game.executable).path))
        XCTAssertEqual((app.appInfo.info()?["LCPatchRevision"] as? NSNumber)?.intValue, 7)
        XCTAssertTrue(app.appInfo.spoofSDKVersion)
        let installedAt: Date? = app.appInfo.installationDate
        XCTAssertLessThan(abs(try XCTUnwrap(installedAt).timeIntervalSinceNow), 60)
        // No data folder until it starts.
        XCTAssertNil(app.appInfo.dataUUID)
        XCTAssertTrue(app.uiContainers.isEmpty)

        // Cartouche knows the game, and the console shows it.
        XCTAssertEqual(CartoucheCatalog.shared.gameTitle(of: app), game.titleId.uppercased())
        XCTAssertEqual(CartoucheCatalog.shared.entries(for: [app]).owned.first?.game?.titleId, game.titleId)
        XCTAssertTrue(actions.installed === app)
        XCTAssertFalse(FileManager.default.fileExists(atPath: unpackingFolder.path), "the unpacked IPA is gone")
        XCTAssertTrue(FileManager.default.fileExists(atPath: try HarnessIPA.game(game).path), "the player's IPA stays")
    }

    func testAnInstalledGameIsThereWhenCartoucheStartsAgain() async throws {
        let game = HarnessGame.plain()
        let app = try await installed(game)
        let spoofed = app.appInfo.info()?["spoofSDKVersion"] as? NSNumber

        // LiveContainer lists its apps again, from its folders.
        HarnessLC.loadApps()
        let again = try XCTUnwrap(self.app(game.bundleIdentifier))
        XCTAssertFalse(again === app)
        XCTAssertEqual(model.apps.count, 1)
        XCTAssertEqual(again.appInfo.relativeBundlePath, app.appInfo.relativeBundlePath)
        XCTAssertEqual(again.appInfo.displayName(), game.name)
        XCTAssertEqual((again.appInfo.info()?["LCPatchRevision"] as? NSNumber)?.intValue, 7)
        XCTAssertEqual(again.appInfo.info()?["spoofSDKVersion"] as? NSNumber, spoofed)
        XCTAssertEqual(CartoucheCatalog.shared.gameTitle(of: again), game.titleId.uppercased())
    }

    func testAnIPAAnotherAppOpenedCartoucheWithGoesOnceInstalled() async throws {
        let game = HarnessGame.plain(1)
        let inbox = LCPath.docPath.appendingPathComponent("Inbox", isDirectory: true)
        try FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
        let ipa = inbox.appendingPathComponent("\(game.name).ipa")
        try FileManager.default.moveItem(at: try HarnessIPA.game(game), to: ipa)

        XCTAssertTrue(CartouchePairing.openedFile(ipa))
        XCTAssertEqual(actions.work?.kind, .installing)
        try await waitUntil("the install is over") { actions.work == nil }
        XCTAssertNil(actions.notice)
        XCTAssertNotNil(app(game.bundleIdentifier))
        XCTAssertFalse(FileManager.default.fileExists(atPath: ipa.path), "the copy iOS made in Inbox goes")
    }

    func testTheConsoleFollowsTheInstallStepByStep() async throws {
        let stages = HarnessBox<[String]>([])
        let fractions = HarnessBox<[Double]>([])
        let watching = actions.$work.sink { work in
            guard let work else { return }
            if stages.value.last != work.stage { stages.value.append(work.stage) }
            if let fraction = work.fraction { fractions.value.append(fraction) }
        }
        defer { watching.cancel() }
        HarnessLC.signingTime = 0.5

        _ = try await installed(.plain())
        XCTAssertEqual(stages.value, ["checking", "unpacking", "signing"])
        XCTAssertGreaterThanOrEqual(fractions.value.max() ?? 0, 0.8, "the fraction reaches the signing: \(fractions.value)")
        XCTAssertTrue(fractions.value.allSatisfy { $0 >= 0 && $0 <= 1 })
    }

    func testAnInstallUnderWayTakesNoOther() async throws {
        let first = HarnessGame.plain(0)
        let second = HarnessGame.plain(1)
        HarnessLC.signingTime = 1
        actions.install(try HarnessIPA.game(first))
        XCTAssertNotNil(actions.work)
        actions.install(try HarnessIPA.game(second))
        try await waitUntil("the install is over") { actions.work == nil }
        XCTAssertNotNil(app(first.bundleIdentifier))
        XCTAssertNil(app(second.bundleIdentifier))
        XCTAssertEqual(model.apps.count, 1)
    }

    func testAFolderOfTheSameNameThatNoAppUsesIsLeftAlone() async throws {
        let game = HarnessGame.plain()
        let taken = LCPath.bundlePath.appendingPathComponent(game.bundleIdentifier + ".app", isDirectory: true)
        try write("left over", in: taken, at: "leftover.txt")

        let app = try await installed(game)
        let folder = try XCTUnwrap(app.appInfo.relativeBundlePath)
        XCTAssertTrue(folder.hasPrefix(game.bundleIdentifier + "_") && folder.hasSuffix(".app"), folder)
        XCTAssertTrue(exists(taken, "leftover.txt"))
    }

    func testOnlyThePrimaryCartoucheInstalls() async throws {
        HarnessLC.appURLScheme = "cartouche2"
        model.updateMultiLCStatus()
        actions.install(try HarnessIPA.game(.plain()))
        XCTAssertNil(actions.work)
        XCTAssertEqual(actions.notice?.title, CartoucheText.installFailed)
        XCTAssertEqual(actions.notice?.message, "lc.appList.manageInPrimaryTip".loc)
        XCTAssertTrue(model.apps.isEmpty)
    }

    // MARK: A GPU nxnative refuses

    func testOnAGPUNxnativeRefusesTheConsoleAsksFirstAndInstallsOnceThePlayerSaysSo() async throws {
        // As an iPhone 13 Pro or 15: no BC-compressed textures
        // (docs/decisions.md, 67).
        HarnessLC.readsBCTextures = false
        let game = HarnessGame.plain()
        let ipa = try HarnessIPA.game(game)
        actions.install(ipa)
        XCTAssertNil(actions.work, "nothing starts before the player answers")
        let question = try XCTUnwrap(actions.installQuestion)
        XCTAssertEqual(question.source, .file(ipa))
        XCTAssertEqual(question.name, "\(game.name) [\(game.titleId)]")

        actions.installAnyway(question)
        XCTAssertNil(actions.installQuestion)
        XCTAssertEqual(actions.work?.kind, .installing)
        try await waitUntil("the install is over") { actions.work == nil }
        XCTAssertNil(actions.notice)
        XCTAssertNotNil(app(game.bundleIdentifier))
        XCTAssertEqual(HarnessLC.signed.count, 1)
    }

    func testOnAGPUNxnativeRefusesCancelInstallsNothing() async throws {
        HarnessLC.readsBCTextures = false
        let ipa = try HarnessIPA.game(.plain())
        actions.install(ipa)
        let question = try XCTUnwrap(actions.installQuestion)
        actions.dropInstall(question)
        XCTAssertNil(actions.installQuestion)
        try await pause(0.3)
        XCTAssertNil(actions.work)
        XCTAssertNil(actions.notice)
        assertNothingInstalled()
        XCTAssertTrue(FileManager.default.fileExists(atPath: ipa.path), "the player's IPA stays")
    }

    func testAnInstallAskedForMeanwhileTakesThePlaceOfTheQuestion() async throws {
        HarnessLC.readsBCTextures = false
        // The first from another app, whose copy in Inbox goes unanswered.
        let first = HarnessGame.plain(0)
        let inbox = LCPath.docPath.appendingPathComponent("Inbox", isDirectory: true)
        try FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
        let opened = inbox.appendingPathComponent("\(first.name).ipa")
        try FileManager.default.moveItem(at: try HarnessIPA.game(first), to: opened)
        XCTAssertTrue(CartouchePairing.openedFile(opened))
        XCTAssertEqual(actions.installQuestion?.source, .file(opened))

        let second = HarnessGame.plain(1)
        let picked = try HarnessIPA.game(second)
        actions.install(picked)
        let question = try XCTUnwrap(actions.installQuestion)
        XCTAssertEqual(question.source, .file(picked), "one question at a time: the newest")
        XCTAssertFalse(FileManager.default.fileExists(atPath: opened.path), "the copy iOS made goes, as after Cancel")

        actions.installAnyway(question)
        try await waitUntil("the install is over") { actions.work == nil }
        XCTAssertNotNil(app(second.bundleIdentifier))
        XCTAssertNil(app(first.bundleIdentifier))
    }

    func testOnAGPUThatReadsBCTexturesNothingIsAsked() async throws {
        let ipa = try HarnessIPA.game(.plain())
        actions.install(ipa)
        XCTAssertNil(actions.installQuestion)
        XCTAssertEqual(actions.work?.kind, .installing)
        try await waitUntil("the install is over") { actions.work == nil }
    }

    // MARK: Another build of a game installed

    func testAnotherBuildReplacesTheGameWithItsSavesAndSettings() async throws {
        var game = HarnessGame.plain()
        let first = try await installed(game)
        // Its first start made its data folder, where it saved.
        _ = actions.settings(for: first, tileKey: "")
        let folder = try dataFolder(of: first)
        try write("level 12", in: folder, at: "Documents/save/slot1.bin")
        first.appInfo.orientationLock = .landscape
        first.appInfo.selectedLanguage = "fr"
        first.appInfo.doSymlinkInbox = true

        game.version = "1.1.0"
        game.commit = "0d9b6358aa11bb22cc33dd44ee55ff6677889900"
        game.romfsBytes = 256 << 10
        let second = try await installed(game)

        XCTAssertFalse(second === first)
        XCTAssertFalse(model.apps.contains(first))
        XCTAssertEqual(model.apps.filter { $0.appInfo.bundleIdentifier() == game.bundleIdentifier }.count, 1)
        XCTAssertEqual(second.appInfo.relativeBundlePath, first.appInfo.relativeBundlePath)
        XCTAssertEqual(second.appInfo.version(), "1.1.0")
        let bundle = try bundle(of: second)
        XCTAssertEqual(try Data(contentsOf: bundle.appendingPathComponent("romfs.img")).count, 256 << 10)
        XCTAssertEqual((second.appInfo.info()?["LCPatchRevision"] as? NSNumber)?.intValue, 7)

        // Its data folder and settings, as the Apps tab's Replace carries them.
        XCTAssertEqual(try dataFolder(of: second), folder)
        XCTAssertEqual(second.uiContainers.map(\.folderName), [folder.lastPathComponent])
        XCTAssertEqual(try String(contentsOf: folder.appendingPathComponent("Documents/save/slot1.bin"), encoding: .utf8), "level 12")
        XCTAssertEqual(second.appInfo.orientationLock, .landscape)
        XCTAssertEqual(second.appInfo.selectedLanguage, "fr")
        XCTAssertTrue(second.appInfo.doSymlinkInbox)
        XCTAssertEqual(HarnessLC.signed.count, 2, "each build is signed")
        XCTAssertEqual(CartoucheInstalledBuilds.installedBuild(of: second).version, "1.1.0")
        XCTAssertEqual(CartoucheInstalledBuilds.installedBuild(of: second).commit, game.commit)
    }

    // MARK: Uninstall

    func testAnUninstalledGameLeavesItsSavesForItsNextInstall() async throws {
        let game = HarnessGame.plain()
        let first = try await installed(game)
        _ = actions.settings(for: first, tileKey: "")
        let folder = try dataFolder(of: first)
        try write("level 3", in: folder, at: "Documents/save/slot1.bin")
        try write("shaders", in: folder, at: "Library/Caches/shaders.bin")
        try write("upload", in: folder, at: "tmp/upload.bin")
        try write("scratch", in: folder, at: "Documents/temp/scratch.bin")
        let bundlePath = try bundle(of: first).path

        actions.uninstall(first, erasingData: false)
        XCTAssertEqual(actions.work?.kind, .uninstalling)
        try await waitUntil("the game is uninstalled") { actions.work == nil }
        XCTAssertNil(actions.notice)
        XCTAssertNil(app(game.bundleIdentifier))
        XCTAssertFalse(FileManager.default.fileExists(atPath: bundlePath))
        XCTAssertTrue(exists(folder, "Documents/save/slot1.bin"), "the saves stay")
        XCTAssertFalse(exists(folder, "Library/Caches"), "what the game makes again goes")
        XCTAssertFalse(exists(folder, "tmp"))
        XCTAssertFalse(exists(folder, "Documents/temp"))
        XCTAssertTrue(HarnessLC.removedKeychains.isEmpty)

        // Installed again, it takes them back.
        let second = try await installed(game)
        XCTAssertEqual(second.appInfo.dataUUID, folder.lastPathComponent)
        XCTAssertEqual(second.uiContainers.map(\.folderName), [folder.lastPathComponent])
        XCTAssertEqual(second.uiSelectedContainer?.folderName, folder.lastPathComponent)
        XCTAssertTrue(exists(folder, "Documents/save/slot1.bin"))
    }

    func testUninstallingWithTheSavesErasesThemAndTheGamesKeychain() async throws {
        let game = HarnessGame.plain()
        let first = try await installed(game)
        _ = actions.settings(for: first, tileKey: "")
        let folder = try dataFolder(of: first)
        try write("level 3", in: folder, at: "Documents/save/slot1.bin")
        // LiveContainer listed it as it started.
        HarnessLC.loadApps()
        let listed = try XCTUnwrap(app(game.bundleIdentifier))
        XCTAssertTrue(model.appDataFolderNames.contains(folder.lastPathComponent))

        actions.uninstall(listed, erasingData: true)
        try await waitUntil("the game is uninstalled") { actions.work == nil }
        XCTAssertNil(actions.notice)
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path))
        XCTAssertEqual(HarnessLC.removedKeychains, [folder.lastPathComponent])
        XCTAssertFalse(model.appDataFolderNames.contains(folder.lastPathComponent))
        XCTAssertTrue(model.apps.isEmpty)

        let second = try await installed(game)
        XCTAssertNil(second.appInfo.dataUUID, "nothing left to take back")
        XCTAssertTrue(second.uiContainers.isEmpty)
    }

    // MARK: An app that is no game

    func testAnAppThatIsNoGameInstallsAndCartoucheSaysSo() async throws {
        let notesResult = try await install(try HarnessIPA.app())
        let notes = try XCTUnwrap(notesResult)
        XCTAssertEqual(actions.notice?.title, CartoucheText.installDone)
        XCTAssertEqual(actions.notice?.message, CartoucheText.installNotAGame("Harness Notes"))
        XCTAssertNil(actions.notice?.report, "nothing failed")
        XCTAssertNil(CartoucheCatalog.shared.gameTitle(of: notes))
        XCTAssertTrue(model.apps.contains(notes))
        XCTAssertTrue((UserDefaults.lcShared().stringArray(forKey: "LCGuestURLSchemes") ?? []).contains("harnessnotes"),
                      "LiveContainer answers the app's URL scheme")
    }

    // MARK: Signing

    /// What LiveContainer said as it could not sign the game, in the
    /// report: LiveContainer's words, as the player may send them.
    private func liveContainerSaid() -> String? {
        actions.notice?.report?.facts.first { $0.name == "LiveContainer said" }?.value
    }

    func testAGameZsignCannotSignInstallsWithTheReason() async throws {
        HarnessLC.signing = .fails("zsign: the provisioning profile does not match the certificate")
        let appResult = try await install(try HarnessIPA.game(.plain()))
        let app = try XCTUnwrap(appResult)
        XCTAssertEqual(actions.notice?.title, CartoucheText.installSignWarning)
        XCTAssertEqual(actions.notice?.message, CartoucheText.notSignedFiles + " " + CartoucheText.notSignedAtInstall)
        XCTAssertNotNil(actions.notice?.report)
        XCTAssertEqual(liveContainerSaid(), "zsign: the provisioning profile does not match the certificate")
        XCTAssertEqual(actions.notice?.signAgain, app.appInfo.bundleIdentifier(), "the player may sign it again and play")
        XCTAssertEqual(app.appInfo.cartoucheSigningFailure, "other", "marked, for Play to sign it again whole")
        XCTAssertTrue(model.apps.contains(app), "installed even so, as the Apps tab leaves it")
    }

    func testAGameSignedButForSomeFilesSaysWhich() async throws {
        HarnessLC.signing = .signsPartly("Frameworks/libharness.dylib: cannot sign")
        let result = try await install(try HarnessIPA.game(.plain()))
        XCTAssertNotNil(result)
        XCTAssertEqual(actions.notice?.title, CartoucheText.installSignWarning)
        XCTAssertEqual(actions.notice?.message, CartoucheText.notSignedFiles + " " + CartoucheText.notSignedAtInstall)
        XCTAssertEqual(liveContainerSaid(), "lc.appList.signSuccessWithError".loc + "\n\nFrameworks/libharness.dylib: cannot sign")
    }

    /// zsign's own words, a line a file it could not sign, with its path:
    /// the player reads that files were not signed, the report has zsign's
    /// words, and the measurements the reason, the kind of file and how
    /// many, never a path.
    func testAFileZsignCannotSignIsCountedByItsKind() async throws {
        HarnessLC.signing = .cannotSign(["Frameworks/MoltenVK.framework/MoltenVK"])
        let reported = try await notifications(CartoucheReports.reported) {
            _ = try await install(try HarnessIPA.game(.plain()))
        }
        let app = try XCTUnwrap(actions.installed)
        XCTAssertEqual(actions.notice?.title, CartoucheText.installSignWarning)
        XCTAssertEqual(actions.notice?.message, CartoucheText.notSignedFiles + " " + CartoucheText.notSignedAtInstall)
        let said = try XCTUnwrap(liveContainerSaid())
        XCTAssertTrue(said.hasPrefix("Failed to Sign /"), said)
        XCTAssertTrue(said.hasSuffix("/Frameworks/MoltenVK.framework/MoltenVK"), said)
        let failure = try XCTUnwrap(reported.compactMap { $0.userInfo?["failure"] as? CartoucheFailure }.last)
        XCTAssertEqual(failure.cause, .notSigned)
        XCTAssertEqual(failure.details["kind"], .text("filesNotSigned"))
        XCTAssertEqual(failure.details["fileKind"], .text("framework"))
        XCTAssertEqual(failure.details["files"], .number(1))
        XCTAssertNil(failure.details["signedAnyway"])
        XCTAssertEqual(app.appInfo.cartoucheSigningFailure, "filesNotSigned")
    }

    /// The Legend of Zelda: Breath of the Wild, from 0.12.0's measurements:
    /// zsign was handed the Metal pipeline archive nxnative bundles, a
    /// Mach-O of Apple's GPU it cannot sign, and every install ended
    /// "Installed, but not signed". It gets the files iOS loads code from
    /// only (CartoucheGameSigning).
    func testAGameWithAMetalPipelineArchiveInstallsSigned() async throws {
        var game = HarnessGame.plain()
        game.pipelineArchive = true
        let app = try await installed(game)
        XCTAssertNil(app.appInfo.cartoucheSigningFailure)
        let folder = "/" + (try bundle(of: app)).lastPathComponent + "/"
        let signed = HarnessLC.signedFiles.map { $0.components(separatedBy: folder).last ?? $0 }
        XCTAssertEqual(signed.sorted(), ["Frameworks/MoltenVK.framework/MoltenVK", game.executable].sorted())
        let archive = try bundle(of: app).appendingPathComponent("pso/applegpu_g18p.mtl4a")
        XCTAssertTrue(installedFile(archive, holds: HarnessMachOFile.pipelineArchive()), "the archive as nxnative made it")
        XCTAssertNotNil(HarnessMachO.zsignFailure(archive.path), "a file zsign cannot sign")
    }

    func testWithoutACertificateLiveContainerSignsNothing() async throws {
        HarnessLC.installCertificate(nil)
        _ = try await installed(.plain())
        XCTAssertTrue(HarnessLC.signed.isEmpty)
    }

    func testAnEncryptedAppIsInstalledWithTheAdviceToDecryptIt() async throws {
        var game = HarnessGame.plain()
        game.encrypted = true
        let appResult = try await install(try HarnessIPA.game(game))
        let app = try XCTUnwrap(appResult)
        XCTAssertEqual(actions.notice?.title, CartoucheText.installSignWarning)
        XCTAssertEqual(actions.notice?.message, CartoucheText.notSignedEncrypted)
        XCTAssertEqual(liveContainerSaid(), "The app you tried to install is encrypted. Please provide decrypted app.")
        XCTAssertNil(actions.notice?.signAgain, "signing it again would not help")
        XCTAssertTrue(HarnessLC.signed.isEmpty)
        XCTAssertTrue(model.apps.contains(app))
    }

    // MARK: Damaged IPAs

    func testBytesThatAreNoIPAAreRefused() async throws {
        let result = try await install(try HarnessIPA.notAZip())
        XCTAssertNil(result)
        XCTAssertEqual(actions.notice?.title, CartoucheText.installFailed)
        XCTAssertEqual(actions.notice?.message, "lc.appList.urlFileIsNotIpaError".loc)
        XCTAssertNotNil(actions.notice?.report)
        assertNothingInstalled()
    }

    func testAnIPACutShortIsRefused() async throws {
        let game = HarnessGame.plain()
        let cut = try HarnessIPA.cut(try HarnessIPA.game(game), inside: "romfs.img", named: "Cut Short.ipa")
        let result = try await install(cut)
        XCTAssertNil(result)
        XCTAssertEqual(actions.notice?.title, CartoucheText.installFailed)
        XCTAssertEqual(actions.notice?.message, CartoucheText.installDamagedIPA, "an IPA, damaged, not a file that is none")
        assertNothingInstalled()
    }

    func testAnIPAWhoseFileChangedIsRefused() async throws {
        let game = HarnessGame.plain()
        let damaged = try HarnessIPA.damaged(game, in: "romfs.img", named: "Damaged.ipa")
        let result = try await install(damaged)
        XCTAssertNil(result, "a game missing its files as they were is not installed")
        XCTAssertEqual(actions.notice?.title, CartoucheText.installFailed)
        XCTAssertEqual(actions.notice?.message, CartoucheText.installDamagedIPA)
        XCTAssertNotNil(actions.notice?.report)
        assertNothingInstalled()
    }

    func testAnIPAWithoutAnAppIsRefused() async throws {
        let ipa = try HarnessIPA.write([.folder("Payload/"), .file("Payload/readme.txt", Data("Put the app here.".utf8))],
                                       named: "No App.ipa")
        let result = try await install(ipa)
        XCTAssertNil(result)
        XCTAssertEqual(actions.notice?.title, CartoucheText.installFailed)
        XCTAssertEqual(actions.notice?.message, "lc.appList.bundleNotFondError".loc)
        assertNothingInstalled()
    }

    func testAZipWithoutPayloadIsRefused() async throws {
        let ipa = try HarnessIPA.write([
            .folder("Notes.app/"),
            .file("Notes.app/Info.plist", HarnessIPA.plist(["CFBundleIdentifier": "com.example.harness.loose"])),
        ], named: "No Payload.ipa")
        let result = try await install(ipa)
        XCTAssertNil(result)
        XCTAssertEqual(actions.notice?.title, CartoucheText.installFailed)
        XCTAssertEqual(actions.notice?.message, "lc.appList.bundleNotFondError".loc,
                       "no app in it, rather than a folder iOS cannot find")
        XCTAssertNotNil(actions.notice?.report)
        assertNothingInstalled()
    }

    func testAnAppWithoutItsInfoPlistIsRefused() async throws {
        let app = "Payload/Nameless.app/"
        let ipa = try HarnessIPA.write([
            .folder("Payload/"), .folder(app),
            .file(app + "Nameless", HarnessMachOFile.executable(sdk: 0x001A_0000), mode: 0o755),
        ], named: "No Info.plist.ipa")
        let result = try await install(ipa)
        XCTAssertNil(result, "not installed as an app named Unknown")
        XCTAssertEqual(actions.notice?.title, CartoucheText.installFailed)
        XCTAssertEqual(actions.notice?.message, "lc.appList.infoPlistCannotReadError".loc)
        XCTAssertNotNil(actions.notice?.report)
        assertNothingInstalled()
    }

    func testAnAppWhoseInfoPlistIsUnreadableIsRefused() async throws {
        let app = "Payload/Garbled.app/"
        for (label, plist) in [("zeros, as a copy that went wrong leaves them", Data(count: 64)),
                               ("a property list without the app's identifier",
                                HarnessIPA.plist(["CFBundleExecutable": "Garbled", "CFBundleName": "Garbled"]))] {
            let ipa = try HarnessIPA.write([
                .folder("Payload/"), .folder(app),
                .file(app + "Info.plist", plist),
                .file(app + "Garbled", HarnessMachOFile.executable(sdk: 0x001A_0000), mode: 0o755),
            ], named: "Garbled, \(label).ipa")
            let result = try await install(ipa)
            XCTAssertNil(result, label)
            XCTAssertEqual(actions.notice?.message, "lc.appList.infoPlistCannotReadError".loc, label)
            assertNothingInstalled()
        }
    }
}
