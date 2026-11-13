//
//  IPadTests.swift
//  CartoucheHarnessTests
//
//  The screen of a game behind the console on an iPad, which turns
//  Cartouche's scenes as it is held, whatever a game allows (Apple's
//  TN3192): the screen keeps the way it is turned once the game allows it,
//  turns from one side to the other as the iPad does, lets go while the
//  console shows, and asks the player to turn an iPad held upright
//  sideways (CartoucheGameOrientations, CartoucheGameScreen.followTurns).
//  The launcher's words call the iPad the iPad (CartoucheDeviceWords).
//  They run on an iPad, the harness's second pass (harness.sh --ipad); on
//  an iPhone, which turns the screen itself, only the iPhone's test runs.
//  The Simulator turns only from its menus: the tests set the way the
//  screen is turned and the way the iPad is held (HarnessLC.screenTurned,
//  deviceHeld), and say in the log what iPadOS made of the lock.
//

import UIKit
import XCTest
@testable import CartoucheHarness

@available(iOS 18.0, *)
final class IPadTests: HarnessCase {
    private var onIPad: Bool { UIDevice.current.userInterfaceIdiom == .pad }

    // MARK: On an iPad

    /// An nxnative game, made to be played sideways, stays sideways as the
    /// iPad tilts upright, upside down or lies flat.
    func testAGameMadeToBePlayedSidewaysStaysSideways() async throws {
        try XCTSkipUnless(onIPad, "on an iPad: harness.sh --ipad")
        HarnessLC.screenTurned = .landscapeRight
        HarnessLC.deviceHeld = .landscapeRight
        let (_, scene) = try await started(.plain())
        let screen = try gameScreen(of: scene)
        try await waitUntil("the screen keeps the way it is turned") { screen.keepsTurn }
        if #available(iOS 26.0, *) {
            XCTAssertTrue(screen.prefersInterfaceOrientationLocked, "iPadOS is asked to keep it")
        }
        XCTAssertEqual(screen.supportedInterfaceOrientations, .landscape)
        sayWhatIPadOSDid(screen)

        for held in [CartoucheGameOrientations.portrait, .portraitUpsideDown, []] {
            try await turn(held: held)
            XCTAssertTrue(screen.keepsTurn, "held \(held.rawValue): the game stays sideways")
        }
        XCTAssertFalse(shows(CartoucheText.turnIPadSideways, in: screen.view), "sideways already")
    }

    /// Held the other side up, the screen lets go for iPadOS to turn it
    /// there, then keeps that way.
    func testItTurnsFromOneSideToTheOtherWithTheIPad() async throws {
        try XCTSkipUnless(onIPad, "on an iPad: harness.sh --ipad")
        HarnessLC.screenTurned = .landscapeRight
        HarnessLC.deviceHeld = .landscapeRight
        let (_, scene) = try await started(.plain())
        let screen = try gameScreen(of: scene)
        try await waitUntil("the screen keeps the way it is turned") { screen.keepsTurn }

        try await turn(held: .landscapeLeft)
        XCTAssertFalse(screen.keepsTurn, "it lets go, for iPadOS to turn it")
        if #available(iOS 26.0, *) {
            XCTAssertFalse(screen.prefersInterfaceOrientationLocked)
        }
        try await turn(turned: .landscapeLeft)
        XCTAssertTrue(screen.keepsTurn, "turned the other side, it keeps that way")
    }

    /// The console over the paused game turns as the iPad is held: the
    /// game's screen lets go, and keeps its way again once the game is back.
    func testTheConsoleTurnsAsTheIPadIsHeldWhileTheGameIsPaused() async throws {
        try XCTSkipUnless(onIPad, "on an iPad: harness.sh --ipad")
        HarnessLC.screenTurned = .landscapeLeft
        HarnessLC.deviceHeld = .landscapeLeft
        let (_, scene) = try await started(.plain())
        let screen = try gameScreen(of: scene)
        try await waitUntil("the screen keeps the way it is turned") { screen.keepsTurn }

        try await pause(0.7)
        scene.pressControllerHome()
        try await waitUntil("the console shows") { actions.running?.isInFront == false }
        XCTAssertFalse(screen.keepsTurn, "the console turns as the iPad is held")
        try await turn(held: .portrait)
        XCTAssertFalse(screen.keepsTurn)

        try await turn(held: .landscapeLeft)
        try await pause(0.7)
        scene.pressControllerHome()
        try await waitUntil("the game shows again") { actions.running?.isInFront == true }
        try await waitUntil("the screen keeps its way again") { screen.keepsTurn }
    }

    /// A game started on an iPad held upright shows upright: the player is
    /// asked to turn the iPad sideways, and the screen keeps that way once
    /// it is.
    func testAnIPadHeldUprightAsksThePlayerToTurnItSideways() async throws {
        try XCTSkipUnless(onIPad, "on an iPad: harness.sh --ipad")
        HarnessLC.screenTurned = .portrait
        HarnessLC.deviceHeld = .portrait
        let (_, scene) = try await started(.plain())
        let screen = try gameScreen(of: scene)
        try await waitUntil("the player is asked to turn the iPad") {
            self.shows(CartoucheText.turnIPadSideways, in: screen.view)
        }
        XCTAssertFalse(screen.keepsTurn, "upright, which the game does not allow: nothing to keep")
        XCTAssertTrue(CartoucheReports.journal(last: 30).contains { $0.contains("asked to turn it sideways") },
                      "a report says so")

        try await turn(held: .landscapeRight)
        XCTAssertFalse(screen.keepsTurn, "until iPadOS has turned it")
        try await turn(turned: .landscapeRight)
        XCTAssertTrue(screen.keepsTurn)
    }

    /// A game that turns every way Cartouche does turns as the iPad is held,
    /// and asks nothing.
    func testAGameThatTurnsEveryWayTurnsWithTheIPad() async throws {
        try XCTSkipUnless(onIPad, "on an iPad: harness.sh --ipad")
        var game = HarnessGame.plain()
        game.orientations = ["UIInterfaceOrientationPortrait", "UIInterfaceOrientationPortraitUpsideDown",
                             "UIInterfaceOrientationLandscapeLeft", "UIInterfaceOrientationLandscapeRight"]
        HarnessLC.screenTurned = .portrait
        HarnessLC.deviceHeld = .portrait
        let (_, scene) = try await started(game)
        let screen = try gameScreen(of: scene)
        XCTAssertEqual(screen.supportedInterfaceOrientations, .all)
        try await turn(held: .landscapeLeft)
        XCTAssertFalse(screen.keepsTurn)
        XCTAssertFalse(shows(CartoucheText.turnIPadSideways, in: screen.view))
    }

    /// The launcher's words call the iPad the iPad, as its model says.
    func testTheWordsCallTheIPadTheIPad() throws {
        try XCTSkipUnless(onIPad, "on an iPad: harness.sh --ipad")
        XCTAssertTrue(CartoucheDevice.isPad, CartoucheDevice.modelIdentifier)
        XCTAssertTrue(CartoucheText.thisIPhone.hasSuffix(" iPad"), CartoucheText.thisIPhone)
        XCTAssertFalse(CartoucheText.onThisIPhone.contains("iPhone"), CartoucheText.onThisIPhone)
    }

    // MARK: On an iPhone

    /// An iPhone turns the game's screen as the game allows: the screen
    /// asks for no lock, and never asks the player to turn the iPhone.
    func testAnIPhoneTurnsTheGamesScreenItself() async throws {
        try XCTSkipIf(onIPad, "on an iPhone")
        HarnessLC.screenTurned = .portrait
        HarnessLC.deviceHeld = .portrait
        let (_, scene) = try await started(.plain())
        let screen = try gameScreen(of: scene)
        XCTAssertEqual(screen.supportedInterfaceOrientations, .landscape)
        HarnessLC.screenTurned = .landscapeRight
        try await turn(held: .landscapeRight)
        XCTAssertFalse(screen.keepsTurn)
        if #available(iOS 26.0, *) {
            XCTAssertFalse(screen.prefersInterfaceOrientationLocked)
        }
        XCTAssertFalse(shows(CartoucheText.turnIPadSideways, in: screen.view))
    }

    /// An iPhone's words are those of Cartouche.xcstrings.
    func testTheWordsCallTheIPhoneTheIPhone() throws {
        try XCTSkipIf(onIPad, "on an iPhone")
        XCTAssertFalse(CartoucheDevice.isPad, CartoucheDevice.modelIdentifier)
        XCTAssertTrue(CartoucheText.thisIPhone.hasSuffix(" iPhone"), CartoucheText.thisIPhone)
    }

    // MARK: Helpers

    /// The device turns, held HELD, or its screen turned TURNED, and says
    /// so as iOS does; a moment for the game's screen to follow.
    private func turn(held: CartoucheGameOrientations? = nil, turned: CartoucheGameOrientations? = nil) async throws {
        if let held { HarnessLC.deviceHeld = held }
        if let turned { HarnessLC.screenTurned = turned }
        NotificationCenter.default.post(name: UIDevice.orientationDidChangeNotification, object: UIDevice.current)
        try await pause(0.1)
    }

    /// Whether VIEW, or a view in it, shows TEXT.
    private func shows(_ text: String, in view: UIView) -> Bool {
        if let label = view as? UILabel, label.text == text {
            return true
        }
        return view.subviews.contains { shows(text, in: $0) }
    }

    /// What iPadOS made of the screen's request, in the log: the Simulator
    /// may not keep the way it is turned, which it turns only from its
    /// menus.
    private func sayWhatIPadOSDid(_ screen: CartoucheGameScreen) {
        guard #available(iOS 26.0, *), let scene = screen.view.window?.windowScene else { return }
        let geometry = scene.effectiveGeometry
        print("harness: iPadOS turned the game's scene \(geometry.interfaceOrientation.rawValue), "
              + (geometry.isInterfaceOrientationLocked ? "its orientation locked" : "its orientation not locked"))
    }
}
