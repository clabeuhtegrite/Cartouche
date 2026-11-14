//
//  BehindConsoleTests.swift
//  CartoucheHarnessTests
//
//  A game behind the console (CartoucheGameHost, docs/decisions.md, 38):
//  LiveContainer starts it in a process of its own, Cartouche shows its
//  scene over the console, the Home button pauses it and brings it back,
//  Quit ends it, iOS may end it, and a game short of memory there starts
//  in Cartouche's place. The harness's AppSceneViewController goes through
//  LiveContainer's steps, on its threads; the tests press the controller's
//  Home button as the game's process posts it, write the game's memory as
//  it does, and kill it as iOS does.
//

import UIKit
import XCTest
@testable import CartoucheHarness

final class BehindConsoleTests: HarnessCase {
    func testPlayRunsTheGameBehindTheConsole() async throws {
        let (app, scene) = try await started(.plain())
        let running = try XCTUnwrap(actions.running)
        XCTAssertTrue(running.isInFront)
        XCTAssertEqual(running.dataFolder, app.appInfo.dataUUID)
        XCTAssertTrue(actions.isRunning(app))
        XCTAssertEqual(scene.bundleId, app.appInfo.relativeBundlePath)
        XCTAssertEqual(scene.dataUUID, running.dataFolder)
        XCTAssertTrue(scene.isAppRunning)
        XCTAssertTrue(HarnessLC.launches.isEmpty, "Cartouche stays open")
        XCTAssertNotNil(scene.view.window, "the game's scene is on screen")
        XCTAssertTrue(scene.contentView?.superview === scene.view)
        XCTAssertTrue(UIApplication.shared.isIdleTimerDisabled, "the iPhone does not lock while the game is on")
        let env = try String(contentsOf: try dataFolder(of: app).appendingPathComponent("Documents/env.txt"), encoding: .utf8)
        XCTAssertTrue(env.contains("DM_LAUNCHER=0"))
        let launched: Date? = app.appInfo.lastLaunched
        XCTAssertNotNil(launched)
    }

    func testHomePausesTheGameUnderTheConsoleAndBringsItBack() async throws {
        let (app, scene) = try await started(.plain())
        let paused = try await notifications(.cartoucheGameDidPause) {
            try await pause(0.7)
            scene.pressControllerHome()
            try await waitUntil("the console shows") { actions.running?.isInFront == false }
        }
        XCTAssertEqual(paused.count, 1)
        XCTAssertTrue(paused.first?.object as AnyObject? === app)
        XCTAssertEqual(scene.presenter?.scene?.settings.foreground, false, "the game's scene goes to the background")
        XCTAssertTrue(scene.isAppRunning)

        try await pause(0.7)
        scene.pressControllerHome()
        try await waitUntil("the game shows again") { actions.running?.isInFront == true }
        XCTAssertEqual(scene.presenter?.scene?.settings.foreground, true)
        XCTAssertEqual(HarnessScenes.all.count, 1, "the same game, not another start")
    }

    func testResumeOnTheConsoleBringsThePausedGameBack() async throws {
        let (_, scene) = try await started(.plain())
        try await pause(0.7)
        scene.pressControllerHome()
        try await waitUntil("the console shows") { actions.running?.isInFront == false }
        actions.resumeRunningGame()
        try await waitUntil("the game shows again") { actions.running?.isInFront == true }
        XCTAssertEqual(scene.presenter?.scene?.settings.foreground, true)
    }

    func testPlayingThePausedGameAgainResumesIt() async throws {
        let (app, scene) = try await started(.plain())
        try await pause(0.7)
        scene.pressControllerHome()
        try await waitUntil("the console shows") { actions.running?.isInFront == false }
        actions.play(app)
        XCTAssertNil(actions.work, "nothing to start")
        try await waitUntil("the game shows again") { actions.running?.isInFront == true }
        XCTAssertEqual(HarnessScenes.all.count, 1)
    }

    func testAPausedGameStaysInTheBackgroundWhenCartoucheComesBack() async throws {
        let (_, scene) = try await started(.plain())
        try await pause(0.7)
        scene.pressControllerHome()
        try await waitUntil("the console shows") { actions.running?.isInFront == false }
        // iOS hands Cartouche's scene change on, as the player comes back.
        scene.hostSceneChanged()
        try await pause(0.2)
        XCTAssertEqual(scene.presenter?.scene?.foregroundUpdates.last, false)
        XCTAssertEqual(actions.running?.isInFront, false)
    }

    // MARK: Its end

    func testQuitEndsTheGameWithoutAWord() async throws {
        let (_, scene) = try await started(.plain())
        let folder = try XCTUnwrap(actions.running?.dataFolder)
        let ended = try await notifications(.cartoucheGameDidEnd) {
            actions.askToQuit()
            XCTAssertEqual(actions.quitQuestion, actions.running)
            actions.quitRunningGame()
            try await waitUntil("the game has ended") { actions.running == nil }
        }
        XCTAssertNil(actions.notice, "the player quit it")
        XCTAssertNil(actions.quitQuestion)
        XCTAssertNotNil(scene.terminatedAt)
        XCTAssertFalse(scene.isAppRunning)
        XCTAssertEqual(HarnessScenes.endedCount, 1)
        XCTAssertEqual(ended.count, 1)
        XCTAssertEqual(ended.first?.userInfo?["quit"] as? Bool, true)
        XCTAssertEqual(ended.first?.userInfo?["dataFolder"] as? String, folder)
        XCTAssertNil(scene.view.window, "the game's screen is gone")
        XCTAssertFalse(UIApplication.shared.isIdleTimerDisabled)
    }

    func testAGameThatTakesThreeSecondsToEndEndsAllTheSame() async throws {
        HarnessLC.gameEndsOnTerminate = false
        let (_, scene) = try await started(.plain())
        actions.quitRunningGame()
        try await waitUntil("the game has ended", timeout: 8) { actions.running == nil }
        XCTAssertNil(actions.notice)
        XCTAssertGreaterThan(Date().timeIntervalSince(try XCTUnwrap(scene.terminatedAt)), 2.5)
    }

    func testCartoucheCleansUpAGameLiveContainerNeverSaysHasEnded() async throws {
        HarnessLC.extensionReportsExit = false
        let (_, scene) = try await started(.plain())
        actions.quitRunningGame()
        try await waitUntil("Cartouche cleans up, six seconds later", timeout: 10) { actions.running == nil }
        XCTAssertFalse(scene.isAppRunning)
        XCTAssertNil(actions.notice)
    }

    func testAGameIOSStopsComesBackToTheConsoleWhichSaysSo() async throws {
        let (app, scene) = try await started(.plain())
        let ended = try await notifications(.cartoucheGameDidEnd) {
            scene.kill()
            try await waitUntil("the game has ended") { actions.running == nil }
        }
        XCTAssertEqual(actions.notice?.title, CartoucheText.gameStoppedTitle(app.displayName))
        XCTAssertEqual(actions.notice?.message, CartoucheText.gameStopped)
        XCTAssertNil(scene.terminatedAt, "Cartouche did not stop it")
        XCTAssertEqual(ended.first?.userInfo?["quit"] as? Bool, false)
    }

    func testAPausedGameIOSStopsIsSaidToHaveStoppedWhilePaused() async throws {
        let (app, scene) = try await started(.plain())
        try await pause(0.7)
        scene.pressControllerHome()
        try await waitUntil("the console shows") { actions.running?.isInFront == false }
        scene.kill()
        try await waitUntil("the game has ended") { actions.running == nil }
        XCTAssertEqual(actions.notice?.title, CartoucheText.gameStoppedTitle(app.displayName))
        XCTAssertEqual(actions.notice?.message, CartoucheText.gameStoppedPaused)
    }

    func testAnInstallKeepsTheIPhoneAwakeAsThePausedGameEnds() async throws {
        let (_, scene) = try await started(.plain(0))
        try await pause(0.7)
        scene.pressControllerHome()
        try await waitUntil("the console shows") { actions.running?.isInFront == false }
        XCTAssertFalse(UIApplication.shared.isIdleTimerDisabled, "the console over the paused game lets the iPhone lock")

        // Another game installs from the console meanwhile, and iOS ends the
        // paused one on the way.
        HarnessLC.signingTime = 2
        let installing = Task { try await self.install(try HarnessIPA.game(.plain(1))) }
        try await waitUntil("the install is on its way") { actions.isTransferring }
        XCTAssertTrue(UIApplication.shared.isIdleTimerDisabled, "the install keeps the iPhone awake")
        scene.kill()
        try await waitUntil("the game has ended") { actions.running == nil }
        XCTAssertTrue(actions.isTransferring, "the install goes on")
        XCTAssertTrue(UIApplication.shared.isIdleTimerDisabled, "still awake, for the install")
        let installed = try await installing.value
        XCTAssertNotNil(installed)
        XCTAssertFalse(UIApplication.shared.isIdleTimerDisabled, "the install over, the iPhone may lock")
    }

    func testAGameThatCrashesAsItStartsSaysItStopped() async throws {
        HarnessLC.nextGameStart = .crashes
        let app = try await installed(.plain())
        actions.play(app)
        try await waitUntil("the start is over") { actions.work == nil }
        try await waitUntil("the game has ended") { actions.running == nil }
        XCTAssertEqual(actions.notice?.message, CartoucheText.gameStopped)
        XCTAssertTrue(HarnessLC.launches.isEmpty)
    }

    // MARK: A game LiveProcess ends on an error

    /// Plays APP until LiveProcess ends it on an error: what Cartouche
    /// reported meanwhile.
    private func playUntilItEndsOnAnError(_ app: LCAppModel) async throws -> [CartoucheFailure] {
        let reported = try await notifications(CartoucheReports.reported) {
            actions.play(app)
            try await waitUntil("the start is over") { actions.work == nil }
            try await waitUntil("the game has ended") { actions.running == nil }
        }
        return reported.compactMap { $0.userInfo?["failure"] as? CartoucheFailure }
    }

    /// What LiveProcess said, in the report.
    private var liveProcessSaid: String? {
        actions.notice?.report?.facts.first { $0.name == "LiveProcess said" }?.value
    }

    /// dyld's words for a game whose signature iOS refuses, as LiveProcess
    /// passes them on: before, the console said only that the game had
    /// closed, start after start.
    func testAGameWhoseSignatureIOSRefusesAsItStartsSaysSoAndOffersToSignItAgain() async throws {
        let dyld = "dlopen(/private/var/mobile/Containers/Data/Application/5D2C/Documents/Applications/Game.app/Game, 0x0009): "
            + "tried: '/private/var/mobile/Containers/Data/Application/5D2C/Documents/Applications/Game.app/Game' "
            + "(code signature invalid in <8E1F2A3B-0C4D-3E5F-9A6B-7C8D9E0F1A2B> "
            + "'/private/var/mobile/Containers/Data/Application/5D2C/Documents/Applications/Game.app/Game' (errno=1) "
            + "sliceOffset=0x00000000, codeBlobOffset=0x00F0A000, codeBlobSize=0x0001E2A0)"
        HarnessLC.nextGameStart = .endsOnError(dyld)
        let game = HarnessGame.plain()
        let app = try await installed(game)
        let failures = try await playUntilItEndsOnAnError(app)
        XCTAssertEqual(actions.notice?.title, CartoucheText.gameStoppedTitle(app.displayName))
        XCTAssertEqual(actions.notice?.message, CartoucheText.gameSignatureRefused)
        XCTAssertEqual(actions.notice?.signAgain, game.bundleIdentifier)
        XCTAssertEqual(liveProcessSaid, dyld)
        XCTAssertEqual(app.appInfo.cartoucheSigningFailure, "codeSignature", "marked, for Play to sign it again whole")
        XCTAssertTrue(HarnessLC.launches.isEmpty, "not started again in Cartouche's place, where it would end the same way")
        let failure = try XCTUnwrap(failures.last)
        XCTAssertEqual(failure.cause, .notSigned)
        XCTAssertEqual(failure.stage, "gameProcess")
        XCTAssertEqual(failure.details["kind"], .text("codeSignature"))

        // Signed again from the notice, whole, it starts.
        HarnessLC.nextGameStart = .starts
        let signed = HarnessLC.signed.count
        actions.signAgain(game.bundleIdentifier)
        try await waitUntil("the start is over") { actions.work == nil }
        XCTAssertNil(actions.notice)
        XCTAssertEqual(HarnessLC.signed.count, signed + 1, "signed again, whole, once")
        XCTAssertNil(app.appInfo.cartoucheSigningFailure)
        XCTAssertTrue(actions.running?.app === app)
    }

    func testAGameThatEndsOnAnErrorSaysSoWithLiveProcesssWords() async throws {
        HarnessLC.nextGameStart = .endsOnError("App returned from its main function with code 3.")
        let app = try await installed(.plain())
        let failures = try await playUntilItEndsOnAnError(app)
        XCTAssertEqual(actions.notice?.title, CartoucheText.gameStoppedTitle(app.displayName))
        XCTAssertEqual(actions.notice?.message, CartoucheText.gameStoppedOnError)
        XCTAssertNil(actions.notice?.signAgain, "signing it again would not help")
        XCTAssertEqual(liveProcessSaid, "App returned from its main function with code 3.")
        XCTAssertNil(app.appInfo.cartoucheSigningFailure)
        XCTAssertTrue(HarnessLC.launches.isEmpty)
        let failure = try XCTUnwrap(failures.last)
        XCTAssertEqual(failure.cause, .gameEndedOnError)
        XCTAssertEqual(failure.details["kind"], .text("returnedFromMain"))
        XCTAssertEqual(failure.details["code"], .number(3))
    }

    // MARK: Memory

    /// What a game's process behind the console writes of its memory, with
    /// LIMITMIB, and whether it has Increased Memory Limit.
    private func reading(limitMiB: UInt64, increasedMemoryLimit: Bool? = true) throws -> CartoucheGameMemoryReading {
        var plist: [String: Any] = ["container": "harness", "pid": NSNumber(value: 1),
                                    "footprint": NSNumber(value: UInt64(512) << 20),
                                    "available": NSNumber(value: (limitMiB - 512) << 20)]
        if let increasedMemoryLimit {
            plist["increasedMemoryLimit"] = NSNumber(value: increasedMemoryLimit)
        }
        return try XCTUnwrap(CartoucheGameMemoryReading(plist: plist))
    }

    func testTheFirstReadingOfTheGamesMemoryIsKept() async throws {
        let (_, scene) = try await started(.plain())
        scene.writeMemory(footprintMiB: 900, availableMiB: 5_000)
        try await waitUntil("Cartouche reads the limit iOS set for the game", timeout: 8) {
            CartoucheGameKeeping.shared.limitMiB == 5_900
        }
        XCTAssertNotNil(actions.running, "a game that fits stays")
    }

    func testAGameStoppedNearItsMemoryLimitStartsInCartouchesPlaceNextTime() async throws {
        let game = HarnessGame.plain()
        let (app, scene) = try await started(game)
        scene.writeMemory(footprintMiB: 5_900, availableMiB: 150)
        scene.kill()
        try await waitUntil("the game has ended") { actions.running == nil }
        XCTAssertEqual(actions.notice?.title, CartoucheText.gameStoppedTitle(app.displayName))
        XCTAssertEqual(actions.notice?.message, CartoucheText.gameStoppedMemory(CartoucheText.memoryAmount(mebibytes: 6_050)))
        XCTAssertTrue(CartoucheGameKeeping.shared.inPlace.contains(game.bundleIdentifier))

        actions.notice = nil
        actions.play(app)
        try await waitUntil("the start is over") { actions.work == nil }
        XCTAssertNil(actions.running)
        XCTAssertEqual(HarnessLC.launches.count, 1, "in Cartouche's place, with all of its memory")
        XCTAssertEqual(HarnessScenes.all.count, 1)
    }

    func testAGameThatNeedsMoreMemoryStartsInCartouchesPlace() async throws {
        let (needing, behindMiB) = try XCTUnwrap(HarnessCatalog.gameNeedingMoreMemory(),
                                                 "a sheet in catalog/games says a game needs Increased Memory Limit, or gives its peak")
        // A game ran behind the console before, with less than Cartouche.
        CartoucheGameKeeping.shared.measured(try reading(limitMiB: UInt64(behindMiB)))
        let app = try await installed(HarnessGame(titleId: needing.titleId, name: needing.name))
        actions.play(app)
        try await waitUntil("the start is over") { actions.work == nil }
        XCTAssertNil(actions.running)
        XCTAssertTrue(HarnessScenes.all.isEmpty)
        XCTAssertEqual(HarnessLC.launches.count, 1)
    }

    // MARK: A game's process without Increased Memory Limit

    func testAGameIOSStopsAtOnceWithoutIncreasedMemoryLimitStartsAgainInCartouchesPlace() async throws {
        // As Donkey Kong Bananza: 3,376 MiB behind the console, its process
        // signed without the capability, stopped within two seconds, before
        // Cartouche measured it (docs/decisions.md, 67).
        let game = HarnessGame.plain()
        let (app, scene) = try await started(game)
        scene.writeMemory(footprintMiB: 3_200, availableMiB: 176, increasedMemoryLimit: false)
        scene.kill()
        try await waitUntil("it starts again in Cartouche's place") { HarnessLC.launches.count == 1 }
        try await waitUntil("the start is over") { actions.work == nil }
        XCTAssertNil(actions.running)
        XCTAssertNil(actions.notice, "nothing to say: the game starts again")
        XCTAssertEqual(HarnessLC.launches.first?.container, app.appInfo.dataUUID)
        XCTAssertEqual(HarnessScenes.all.count, 1)
        let keeping = CartoucheGameKeeping.shared
        XCTAssertTrue(keeping.behindLacksIML)
        XCTAssertEqual(keeping.limitMiB, 3_376)
        XCTAssertFalse(keeping.inPlace.contains(game.bundleIdentifier),
                       "not for good: for the capability missing there, not for its own needs")
    }

    func testWithoutIncreasedMemoryLimitThereEveryGameStartsInCartouchesPlaceUntilThePlayerTriesAgain() async throws {
        // The first game's first measurement, three seconds in, says its
        // process lacks the capability and has less than Cartouche: it starts
        // again in Cartouche's place at once.
        let first = HarnessGame.plain(0)
        let (_, scene) = try await started(first)
        scene.writeMemory(footprintMiB: 900, availableMiB: 2_476, increasedMemoryLimit: false)
        try await waitUntil("it starts again in Cartouche's place", timeout: 10) { HarnessLC.launches.count == 1 }
        try await waitUntil("the start is over") { actions.work == nil && actions.running == nil }
        XCTAssertNil(actions.notice)
        XCTAssertNotNil(scene.terminatedAt, "Cartouche quit it behind the console")
        XCTAssertTrue(CartoucheGameKeeping.shared.behindLacksIML)
        XCTAssertFalse(CartoucheGameKeeping.shared.inPlace.contains(first.bundleIdentifier))

        // Another game goes to Cartouche's place too, from the start.
        let second = try await installed(.plain(1))
        actions.play(second)
        try await waitUntil("the start is over") { actions.work == nil }
        XCTAssertNil(actions.running)
        XCTAssertEqual(HarnessLC.launches.count, 2)
        XCTAssertEqual(HarnessScenes.all.count, 1)

        // The player tries behind the console again (System › Games): the
        // next game goes there, and says whether its process has it now.
        CartoucheGameKeeping.shared.tryBehindAgain()
        actions.play(second)
        try await waitUntil("the start is over") { actions.work == nil }
        XCTAssertTrue(actions.running?.app === second)
        XCTAssertEqual(HarnessScenes.all.count, 2)
    }

    func testAProcessWithIncreasedMemoryLimitAgainSendsTheGamesBehindTheConsoleAgain() async throws {
        CartoucheGameKeeping.shared.measured(try reading(limitMiB: 3_376, increasedMemoryLimit: false))
        XCTAssertTrue(CartoucheGameKeeping.shared.behindLacksIML)
        // A reading that cannot tell leaves what Cartouche knew.
        CartoucheGameKeeping.shared.measured(try reading(limitMiB: 3_376, increasedMemoryLimit: nil))
        XCTAssertTrue(CartoucheGameKeeping.shared.behindLacksIML)
        CartoucheGameKeeping.shared.measured(try reading(limitMiB: 6_144, increasedMemoryLimit: true))
        XCTAssertFalse(CartoucheGameKeeping.shared.behindLacksIML)
        let (app, _) = try await started(.plain())
        XCTAssertTrue(actions.running?.app === app)
    }

    // MARK: Where LiveProcess fails

    func testAGameStartsInCartouchesPlaceWhenLiveProcessIsMissing() async throws {
        HarnessLC.nextGameStart = .noExtension
        let app = try await installed(.plain())
        actions.play(app)
        try await waitUntil("the start is over") { actions.work == nil }
        XCTAssertNil(actions.running)
        XCTAssertNil(actions.notice)
        XCTAssertEqual(HarnessLC.launches.count, 1)
        XCTAssertFalse(UIApplication.shared.isIdleTimerDisabled, "nothing left of the start behind the console")
    }

    func testAGameStartsInCartouchesPlaceWhenLiveProcessRefusesIt() async throws {
        HarnessLC.nextGameStart = .refused
        let app = try await installed(.plain())
        actions.play(app)
        try await waitUntil("the start is over") { actions.work == nil }
        XCTAssertNil(actions.running)
        XCTAssertNil(actions.notice)
        XCTAssertEqual(HarnessLC.launches.count, 1)
        XCTAssertFalse(UIApplication.shared.isIdleTimerDisabled, "nothing left of the start behind the console")
    }

    func testTheConsoleKeptClosedStartsEveryGameInCartouchesPlace() async throws {
        CartoucheGameKeeping.shared.keepsConsoleOpen = false
        let app = try await installed(.plain())
        actions.play(app)
        try await waitUntil("the start is over") { actions.work == nil }
        XCTAssertNil(actions.running)
        XCTAssertEqual(HarnessLC.launches.count, 1)
    }

    func testACertificateIOSRefusesStopsTheStartBehindTheConsoleToo() async throws {
        let app = try await installed(.plain())
        HarnessLC.iOSRefusesCertificate = true
        actions.play(app)
        try await waitUntil("the start is over") { actions.work == nil }
        XCTAssertNil(actions.running)
        XCTAssertTrue(HarnessScenes.all.isEmpty)
        XCTAssertTrue(HarnessLC.launches.isEmpty)
        XCTAssertEqual(actions.notice?.message, CartoucheText.startCertificateRefused)
    }

    // MARK: Another game, while one runs

    func testAnotherGameTakesThePlaceOfTheRunningOneOnceThePlayerSaysSo() async throws {
        let second = HarnessGame.plain(1)
        let secondApp = try await installed(second)
        let (firstApp, firstScene) = try await started(.plain(0))

        actions.play(secondApp)
        let change = try XCTUnwrap(actions.switching, "the console asks first")
        XCTAssertTrue(change.running.app === firstApp)
        XCTAssertTrue(change.next === secondApp)
        XCTAssertTrue(firstScene.isAppRunning, "nothing quits before the player says so")

        actions.confirmSwitch(change)
        try await waitUntil("the other game runs") { actions.running?.app === secondApp && actions.work == nil }
        try await waitUntil("its scene shows") { HarnessScenes.shownCount >= 2 }
        XCTAssertNotNil(firstScene.terminatedAt)
        XCTAssertFalse(firstScene.isAppRunning)
        XCTAssertEqual(HarnessScenes.all.count, 2)
        XCTAssertNil(actions.notice)
        XCTAssertNil(actions.switching)
    }

    func testTheRunningGameCannotBeReplacedNorUninstalled() async throws {
        let game = HarnessGame.plain()
        let (app, _) = try await started(game)

        let replaced = try await install(try HarnessIPA.game(game))
        XCTAssertNil(replaced)
        XCTAssertEqual(actions.notice?.title, CartoucheText.installFailed)
        XCTAssertEqual(actions.notice?.message, CartoucheText.quitFirst(app.displayName))
        XCTAssertTrue(actions.running?.app === app)
        XCTAssertTrue(model.apps.contains(app))

        actions.notice = nil
        actions.uninstall(app, erasingData: false)
        XCTAssertNil(actions.work)
        XCTAssertEqual(actions.notice?.title, CartoucheText.uninstallFailed)
        XCTAssertEqual(actions.notice?.message, CartoucheText.quitFirst(app.displayName))
        XCTAssertTrue(model.apps.contains(app))
    }
}
