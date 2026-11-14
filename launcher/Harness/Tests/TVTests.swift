//
//  TVTests.swift
//  CartoucheHarnessTests
//
//  A TV while a game runs behind the console (CartoucheTV.swift,
//  docs/decisions.md, 85): Cartouche asks iOS for the TV, and shows there
//  the game's own scene for a TV, which LiveContainer opens in the game's
//  process (app/patches/livecontainer/0012), over the game's card, and
//  never the iPhone's screen, where the game's controls are. While a copy
//  of the iPhone's screen goes elsewhere, to a TV or to a recording, the
//  game hides from it. The Simulator has no TV: the tests hand Cartouche
//  one as iOS does, a window with Cartouche's TV screen in the harness's
//  own scene, say that iOS captures the iPhone's screen with the capture
//  state of that scene, as iOS 27 does as it copies the screen to a TV it
//  has not handed Cartouche, and say where the sound goes
//  (HarnessLC.soundGoesToADisplay). What the TV does goes in the journal a
//  player's report takes along (CartoucheTV.note).
//

import AVFAudio
import UIKit
import XCTest
@testable import CartoucheHarness

@available(iOS 18.0, *)
final class TVTests: HarnessCase {
    private var tvWindow: UIWindow?

    private var host: CartoucheGameHost { CartoucheGameHost.shared }
    /// What the TV shows, while Cartouche has it.
    private var tv: CartoucheTVScreen? { CartoucheTV.shared.screen }
    private var card: CartoucheTVCardModel { CartoucheTV.shared.card }

    /// The line that opens each test's steps in the journal of the reports.
    private static let journalMark = "Harness: a TV test starts"

    override func setUp() async throws {
        try await super.setUp()
        try copyTheIPhonesScreen(false)
        CartoucheReports.note(Self.journalMark)
    }

    override func tearDown() async throws {
        disconnectTV()
        try? copyTheIPhonesScreen(false)
        try await super.tearDown()
    }

    // MARK: The game on the TV

    func testTheTVShowsTheGamesOwnSceneOverItsCard() async throws {
        let tvWindow = try connectTV()
        let game = HarnessGame.plain()
        let (_, scene) = try await started(game)
        try await waitUntil("the game's scene opens on the TV") { scene.tvScene != nil }
        let tv = try XCTUnwrap(self.tv)
        XCTAssertTrue(tv.game === scene.tvScene)
        XCTAssertTrue(host.gameOnTV === scene.tvScene)
        XCTAssertTrue(tv.showsGame)
        XCTAssertEqual(scene.tvScene?.view.isDescendant(of: tvWindow), true)
        XCTAssertEqual(scene.tvOpenings.count, 1)
        XCTAssertTrue(scene.tvOpenings.first === tvWindow.windowScene?.screen, "on the TV's screen")
        XCTAssertEqual(scene.tvForegroundUpdates.last, true)
        // Under it, the game's card, where the game leaves its scene empty.
        XCTAssertEqual(card.name, game.name)
        XCTAssertEqual(card.status, .playing)
        XCTAssertTrue(identifiers(in: tvWindow).contains("tv.card"))
        try assertTVShowsNothingOfTheIPhone(scene)
        // The iPhone keeps the game's scene, with its controls, and the
        // Home button.
        let screen = try gameScreen(of: scene)
        XCTAssertNotNil(scene.view.window)
        XCTAssertTrue(scene.view.isDescendant(of: screen.view))
        XCTAssertFalse(screen.hidesGameForTV)
        // A report says so (System › Report a problem).
        let steps = journal().filter { $0.hasPrefix("TV") }
        XCTAssertEqual(steps.count, 2, "\(steps)")
        XCTAssertTrue(steps.first?.hasPrefix("TV connected (") == true, "\(steps)")
        XCTAssertTrue(steps.last?.hasPrefix("TV: the game's own scene is on the TV (") == true, "\(steps)")
    }

    func testATVPluggedInDuringTheGameGetsTheGamesScene() async throws {
        let (_, scene) = try await started(.plain())
        XCTAssertNil(scene.tvScene, "no TV yet")
        XCTAssertTrue(scene.tvOpenings.isEmpty)
        let tvWindow = try connectTV()
        XCTAssertNotNil(scene.tvScene)
        XCTAssertTrue(tv?.game === scene.tvScene)
        XCTAssertEqual(tv?.showsGame, true)
        XCTAssertTrue(scene.tvOpenings.first === tvWindow.windowScene?.screen)
        try assertTVShowsNothingOfTheIPhone(scene)
    }

    func testCartoucheAsksIOSForTheTVWhileAGameRunsBehindTheConsole() async throws {
        guard #available(iOS 27.0, *) else { throw XCTSkip("iOS 27 hands an app a TV for a scene accessory") }
        XCTAssertTrue(host.tvAccessories.isEmpty)
        let (_, scene) = try await started(.plain())
        let screen = try gameScreen(of: scene)
        XCTAssertTrue(host.tvAccessories.contains { $0.controller === screen }, "from the game's screen")
        for (_, registration) in host.tvAccessories {
            XCTAssertEqual((registration as? UISceneAccessoryRegistration)?.isEnabled, true)
        }
        try await pause(0.7)
        scene.pressControllerHome()
        try await waitUntil("the console shows") { actions.running?.isInFront == false }
        XCTAssertFalse(host.tvAccessories.isEmpty, "the TV stays the game's while it is paused")
        actions.quitRunningGame()
        try await waitUntil("the game has ended") { actions.running == nil }
        XCTAssertTrue(host.tvAccessories.isEmpty, "iOS gets the TV back, and mirrors the console on it")
    }

    func testAGameWithoutASceneForTheTVLeavesItsCardThere() async throws {
        HarnessLC.gamesHaveATVScene = false
        let tvWindow = try connectTV()
        let (_, scene) = try await started(.plain())
        try await waitUntil("the game shows") { card.status == .playing }
        XCTAssertNil(scene.tvScene)
        XCTAssertNil(tv?.game)
        XCTAssertNil(host.gameOnTV)
        XCTAssertEqual(card.statusLine, CartoucheText.tvOnIPhone)
        XCTAssertTrue(identifiers(in: tvWindow).contains("tv.card"))
        try assertTVShowsNothingOfTheIPhone(scene)
        XCTAssertTrue(journal().contains("TV: the game has no scene of its own on the TV, which shows its card"))
        XCTAssertFalse(journal().contains { $0.hasPrefix("TV: the game's own scene is on the TV") })
    }

    /// With the game's picture on the TV, nxnative leaves the iPhone the
    /// game's controls alone, laid out to be held sideways: the game's
    /// screen turns sideways only, even for a game that lays itself out
    /// upright, and as the iPhone is held again once the TV has gone.
    func testTheGamesScreenTurnsSidewaysOnlyWhileItsPictureIsOnTheTV() async throws {
        let (_, scene) = try await started(.laidOutUpright())
        let screen = try gameScreen(of: scene)
        XCTAssertEqual(screen.turns, [.portrait, .landscape], "upright too, its picture on the iPhone")
        try connectTV()
        try await waitUntil("the game's scene opens on the TV") { scene.tvScene != nil }
        XCTAssertTrue(screen.pictureOnTV)
        XCTAssertEqual(screen.supportedInterfaceOrientations, .landscape)
        disconnectTV()
        try await waitUntil("the game's scene on the TV closes") { scene.tvScene == nil }
        XCTAssertFalse(screen.pictureOnTV)
        XCTAssertEqual(screen.supportedInterfaceOrientations, [.portrait, .landscapeLeft, .landscapeRight])
    }

    // MARK: The console over the game

    func testHomeLeavesTheGamesCardPausedOnTheTVAndBringsTheGameBack() async throws {
        try connectTV()
        let (_, scene) = try await started(.plain())
        try await waitUntil("the game's scene opens on the TV") { scene.tvScene != nil }
        try await pause(0.7)
        scene.pressControllerHome()
        try await waitUntil("the console shows") { actions.running?.isInFront == false }
        XCTAssertEqual(tv?.showsGame, false, "the card alone, while the console is on the iPhone")
        XCTAssertEqual(card.status, .paused)
        XCTAssertEqual(card.statusLine, CartoucheText.tvPaused)
        XCTAssertEqual(scene.tvForegroundUpdates.last, false, "in the background, with the game's own scene")
        XCTAssertTrue(tv?.game === scene.tvScene, "kept for the game's return")
        try assertTVShowsNothingOfTheIPhone(scene)

        try await pause(0.7)
        scene.pressControllerHome()
        try await waitUntil("the game shows again") { actions.running?.isInFront == true }
        XCTAssertEqual(tv?.showsGame, true)
        XCTAssertEqual(card.status, .playing)
        XCTAssertEqual(scene.tvForegroundUpdates.last, true)
        XCTAssertEqual(scene.tvOpenings.count, 1, "the same scene")
    }

    func testTheGamesSceneOnTheTVFollowsCartoucheIntoTheBackground() async throws {
        try connectTV()
        let (_, scene) = try await started(.plain())
        try await waitUntil("the game's scene opens on the TV") { scene.tvScene != nil }
        // The player leaves Cartouche for another app, and comes back.
        scene.hostSceneChanged(foreground: false)
        try await waitUntil("the game's scene on the TV goes to the background") { scene.tvForegroundUpdates.last == false }
        scene.hostSceneChanged()
        try await waitUntil("and comes back") { scene.tvForegroundUpdates.last == true }

        // Paused, it stays in the background as Cartouche comes back.
        try await pause(0.7)
        scene.pressControllerHome()
        try await waitUntil("the console shows") { actions.running?.isInFront == false }
        scene.hostSceneChanged()
        try await pause(0.2)
        XCTAssertEqual(scene.tvForegroundUpdates.last, false)
    }

    // MARK: The end of the game, and of the TV

    func testQuitClosesTheGamesSceneOnTheTVAndGivesTheTVBack() async throws {
        let tvWindow = try connectTV()
        let (_, scene) = try await started(.plain())
        try await waitUntil("the game's scene opens on the TV") { scene.tvScene != nil }
        actions.quitRunningGame()
        try await waitUntil("the game has ended") { actions.running == nil }
        XCTAssertNil(scene.tvScene)
        XCTAssertEqual(scene.tvClosings, 1)
        XCTAssertNil(tv?.game)
        XCTAssertNil(host.gameOnTV)
        XCTAssertTrue(host.tvAccessories.isEmpty, "iOS gets the TV back")
        XCTAssertNil(CartoucheTV.shared.host)
        XCTAssertEqual(card.name, "", "Cartouche's name alone, until iOS takes the TV back")
        XCTAssertFalse(identifiers(in: tvWindow).contains("harness.tv." + (scene.dataUUID ?? "")))
    }

    func testAGameIOSStopsLeavesTheTV() async throws {
        try connectTV()
        let (_, scene) = try await started(.plain())
        try await waitUntil("the game's scene opens on the TV") { scene.tvScene != nil }
        scene.kill()
        try await waitUntil("the game has ended") { actions.running == nil }
        XCTAssertNil(scene.tvScene)
        XCTAssertNil(tv?.game)
        XCTAssertTrue(host.tvAccessories.isEmpty)
        XCTAssertEqual(card.name, "")
    }

    func testAStartThatFailsBehindTheConsoleLeavesTheTVToIOS() async throws {
        HarnessLC.nextGameStart = .refused
        try connectTV()
        let app = try await installed(.plain())
        actions.play(app)
        try await waitUntil("the start is over") { actions.work == nil }
        XCTAssertEqual(HarnessLC.launches.count, 1, "in Cartouche's place, where the game asks iOS for the TV itself")
        XCTAssertTrue(host.tvAccessories.isEmpty)
        XCTAssertNil(CartoucheTV.shared.host)
        XCTAssertNil(tv?.game)
        XCTAssertEqual(card.name, "")
    }

    func testUnpluggingTheTVClosesTheGamesSceneThereAndTheGameGoesOn() async throws {
        try connectTV()
        let (_, scene) = try await started(.plain())
        try await waitUntil("the game's scene opens on the TV") { scene.tvScene != nil }
        disconnectTV()
        XCTAssertEqual(journal().last, "TV disconnected")
        XCTAssertNil(scene.tvScene, "nxnative puts its picture back on the iPhone")
        XCTAssertEqual(scene.tvClosings, 1)
        XCTAssertNil(host.gameOnTV)
        XCTAssertTrue(scene.isAppRunning)
        XCTAssertEqual(actions.running?.isInFront, true)

        try connectTV()
        XCTAssertNotNil(scene.tvScene, "plugged in again")
        XCTAssertEqual(scene.tvOpenings.count, 2)
        XCTAssertTrue(tv?.game === scene.tvScene)
    }

    // MARK: A copy of the iPhone's screen

    func testTheGameHidesFromATVThatMirrorsTheIPhone() async throws {
        HarnessLC.soundGoesToADisplay = true
        try copyTheIPhonesScreen()
        let (_, scene) = try await started(.plain())
        let screen = try gameScreen(of: scene)
        XCTAssertEqual(screen.hidesGameFrom, .tv, "black over the game, the TV a copy of the iPhone")
        let cover = try XCTUnwrap(view("game.tvCover", in: screen.view))
        XCTAssertGreaterThan(try XCTUnwrap(screen.view.subviews.firstIndex(of: cover)),
                             try XCTUnwrap(screen.view.subviews.firstIndex(of: scene.view)), "over the game's scene")
        XCTAssertEqual(coverText(in: screen), CartoucheText.tvMoving, "while iOS hands Cartouche the TV")
        XCTAssertEqual(view("game.tvCover.anyway", in: screen.view)?.isHidden, true)
        // A few seconds on, what the player can do about it.
        try await waitUntil("the way to show the game anyway", timeout: 8) {
            view("game.tvCover.anyway", in: screen.view)?.isHidden == false
        }
        XCTAssertEqual(coverText(in: screen), CartoucheText.tvMirrored)
        let anyway = try XCTUnwrap(view("game.tvCover.anyway", in: screen.view) as? UIButton)
        anyway.sendActions(for: .primaryActionTriggered)
        XCTAssertFalse(screen.hidesGameForTV, "the player chose to show it")
        XCTAssertNil(view("game.tvCover", in: screen.view))
        host.guardTheTV()
        XCTAssertFalse(screen.hidesGameForTV, "as long as the game runs")
        // A report says so, once each.
        XCTAssertEqual(journal().filter { $0.hasPrefix("TV") }, [
            "TV: a display mirrors the iPhone, the game hides from it",
            "TV: the player shows the game anyway, on the iPhone and on the display that mirrors it",
        ])
    }

    func testTheGameHidesAsSoonAsIOSCopiesTheIPhonesScreen() async throws {
        HarnessLC.soundGoesToADisplay = true
        let (_, scene) = try await started(.plain())
        let screen = try gameScreen(of: scene)
        XCTAssertFalse(screen.hidesGameForTV, "no copy")
        // A TV plugged in, or AirPlay: iOS 27 copies the iPhone's screen
        // there, until it hands Cartouche the TV, without a screen for it
        // among UIScreen.screens.
        try copyTheIPhonesScreen()
        try await waitUntil("the game hides") { screen.hidesGameFrom == .tv }
        // The TV unplugged.
        try copyTheIPhonesScreen(false)
        try await waitUntil("the game shows again") { !screen.hidesGameForTV }
        XCTAssertEqual(journal().filter { $0.hasPrefix("TV") }, [
            "TV: a display mirrors the iPhone, the game hides from it",
            "TV: the game shows again",
        ])
    }

    func testARecordingOfTheScreenHidesTheGameWithAWayToShowItAtOnce() async throws {
        // The sound stays on the iPhone: a recording of the screen, a Mac's
        // iPhone Mirroring, or a TV whose sound goes to headphones, which
        // Cartouche cannot tell apart.
        HarnessLC.soundGoesToADisplay = false
        let (_, scene) = try await started(.plain())
        let screen = try gameScreen(of: scene)
        try copyTheIPhonesScreen()
        try await waitUntil("the game hides") { screen.hidesGameFrom == .elsewhere }
        XCTAssertEqual(coverText(in: screen), CartoucheText.tvCaptured)
        let anyway = try XCTUnwrap(view("game.tvCover.anyway", in: screen.view) as? UIButton)
        XCTAssertFalse(anyway.isHidden, "at once")
        // The sound moves to a TV.
        HarnessLC.soundGoesToADisplay = true
        NotificationCenter.default.post(name: AVAudioSession.routeChangeNotification, object: nil)
        try await waitUntil("the cover speaks of the TV") { screen.hidesGameFrom == .tv }
        XCTAssertFalse(anyway.isHidden, "the way to show the game stays")
        anyway.sendActions(for: .primaryActionTriggered)
        XCTAssertFalse(screen.hidesGameForTV)
        XCTAssertEqual(journal().filter { $0.hasPrefix("TV") }, [
            "TV: the iPhone's screen is recorded or copied, the game hides from it",
            "TV: the player shows the game anyway, on the iPhone and on the display that mirrors it",
        ])
    }

    func testTheGameShowsAgainOnceIOSHandsCartoucheTheTV() async throws {
        HarnessLC.soundGoesToADisplay = true
        try copyTheIPhonesScreen()
        let (_, scene) = try await started(.plain())
        let screen = try gameScreen(of: scene)
        XCTAssertTrue(screen.hidesGameForTV)
        // iOS hands Cartouche the TV it copied the iPhone's screen to, even
        // while it says the screen is captured.
        try connectTV()
        XCTAssertFalse(screen.hidesGameForTV)
        XCTAssertNotNil(scene.tvScene)
        XCTAssertTrue(journal().contains("TV: the game shows again"))
        try await pause(0.3)
        XCTAssertFalse(screen.hidesGameForTV, "the TV is Cartouche's")
        // Unplugged, with another display that mirrors the iPhone.
        disconnectTV()
        try await waitUntil("the game hides again") { screen.hidesGameForTV }
    }

    func testThePausedGameHidesAsItComesBackToATVThatMirrorsTheIPhone() async throws {
        HarnessLC.soundGoesToADisplay = true
        let (_, scene) = try await started(.plain())
        let screen = try gameScreen(of: scene)
        XCTAssertFalse(screen.hidesGameForTV, "no TV")
        try await pause(0.7)
        scene.pressControllerHome()
        try await waitUntil("the console shows") { actions.running?.isInFront == false }
        // A TV now mirrors the iPhone, the console on it.
        try copyTheIPhonesScreen()
        try await pause(0.3)
        XCTAssertFalse(screen.hidesGameForTV, "the console may show there")
        try await pause(0.4)
        scene.pressControllerHome()
        try await waitUntil("the game shows again") { actions.running?.isInFront == true }
        XCTAssertTrue(screen.hidesGameForTV, "hidden from it")
    }

    // MARK: Helpers

    /// A TV that iOS hands Cartouche, as CartoucheTVSceneDelegate takes
    /// it: a window with Cartouche's TV screen, never key, under the
    /// console's.
    @discardableResult
    private func connectTV(file: StaticString = #filePath, line: UInt = #line) throws -> UIWindow {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.lazy.compactMap { $0 as? UIWindowScene }.first,
                                  file: file, line: line)
        let window = UIWindow(windowScene: scene)
        window.windowLevel = UIWindow.Level(rawValue: UIWindow.Level.normal.rawValue - 1)
        window.rootViewController = CartoucheTVScreen(card: CartoucheTV.shared.card)
        window.isHidden = false
        tvWindow = window
        CartoucheTV.shared.connect(window)
        return window
    }

    /// iOS captures the iPhone's screen, or stops, and says so to the scene
    /// that Cartouche's windows are in: as it copies the screen to a TV
    /// that it has not handed Cartouche, by cable or AirPlay, or records it.
    private func copyTheIPhonesScreen(_ copied: Bool = true, file: StaticString = #filePath, line: UInt = #line) throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.lazy.compactMap { $0 as? UIWindowScene }.first,
                                  file: file, line: line)
        if copied {
            scene.traitOverrides.sceneCaptureState = .active
        } else {
            scene.traitOverrides.remove(UITraitSceneCaptureState.self)
        }
    }

    /// What the cover over the game says.
    private func coverText(in screen: CartoucheGameScreen) -> String? {
        (view("game.tvCover.text", in: screen.view) as? UILabel)?.text
    }

    /// The TV unplugged, or taken back by iOS.
    private func disconnectTV() {
        guard let window = tvWindow else { return }
        tvWindow = nil
        CartoucheTV.shared.disconnect(window)
        window.isHidden = true
    }

    /// The steps Cartouche noted for its reports since this test started,
    /// without their time.
    private func journal() -> [String] {
        let lines = CartoucheReports.journal(last: CartoucheJournal.kept)
        guard let start = lines.lastIndex(where: { $0.hasSuffix(" " + Self.journalMark) }) else { return [] }
        // "11-13 10:41:07 TV connected (…)"
        return lines[lines.index(after: start)...].map { line in
            line.split(separator: " ", maxSplits: 2).dropFirst(2).first.map(String.init) ?? ""
        }
    }

    /// The game's screen on the iPhone, which holds its scene.
    private func gameScreen(of scene: AppSceneViewController, file: StaticString = #filePath,
                            line: UInt = #line) throws -> CartoucheGameScreen {
        try XCTUnwrap(scene.parent as? CartoucheGameScreen, file: file, line: line)
    }

    /// Fails if the TV shows anything of the iPhone's screen: the game's
    /// own scene, with its controls, or the game's screen with the Home
    /// button.
    private func assertTVShowsNothingOfTheIPhone(_ scene: AppSceneViewController, file: StaticString = #filePath,
                                                 line: UInt = #line) throws {
        let window = try XCTUnwrap(tvWindow, file: file, line: line)
        XCTAssertFalse(identifiers(in: window).contains("harness.game." + (scene.dataUUID ?? "")),
                       "the game's own scene, with its controls", file: file, line: line)
        XCTAssertFalse(scene.view.isDescendant(of: window), file: file, line: line)
        if let screen = scene.parent {
            XCTAssertFalse(screen.view.isDescendant(of: window), "the game's screen", file: file, line: line)
        }
    }

    /// The accessibility identifiers of VIEW and of every view in it.
    private func identifiers(in view: UIView) -> Set<String> {
        var found: Set<String> = []
        if let identifier = view.accessibilityIdentifier {
            found.insert(identifier)
        }
        for subview in view.subviews {
            found.formUnion(identifiers(in: subview))
        }
        return found
    }

    /// The view of IDENTIFIER in VIEW, VIEW itself included.
    private func view(_ identifier: String, in view: UIView) -> UIView? {
        if view.accessibilityIdentifier == identifier {
            return view
        }
        for subview in view.subviews {
            if let found = self.view(identifier, in: subview) {
                return found
            }
        }
        return nil
    }
}
