//
//  HomeButtonTests.swift
//  CartoucheHarnessTests
//
//  The Home button over a game behind the console (CartoucheGameScreen,
//  docs/decisions/110.md): it shows as the game starts, fades away a few
//  seconds after the game shows, and stays where it was, as good as
//  invisible, so that a touch on its place brings it back rather than go to
//  the game; a touch on it then shows the console. It shows again as the
//  game comes back from the console, and stays over the cover that hides
//  the game from a copy of the iPhone's screen, and for VoiceOver.
//

import UIKit
import XCTest
@testable import CartoucheHarness

@available(iOS 18.0, *)
final class HomeButtonTests: HarnessCase {
    /// Longer than the Home button stays, on a Mac of the CI that may be
    /// busy.
    private let fadeTimeout: TimeInterval = 8

    func testTheHomeButtonShowsAsTheGameStartsThenFadesAway() async throws {
        let (_, scene) = try await started(.plain())
        let screen = try gameScreen(of: scene)
        let home = try homeButton(of: screen)
        XCTAssertTrue(screen.showsHome, "it shows as the game starts")
        XCTAssertEqual(home.alpha, CartoucheGameScreen.homeOpacity, accuracy: 0.01)
        let shown = Date()
        try await waitUntil("it fades away", timeout: fadeTimeout) { !screen.showsHome }
        XCTAssertGreaterThan(Date().timeIntervalSince(shown), 2.5, "a few seconds after the game shows")
        try await waitUntil("as good as gone") { home.alpha < 0.05 }
        XCTAssertEqual(actions.running?.isInFront, true, "the game goes on")
    }

    func testATouchOnItsPlaceBringsItBackAndATouchOnItThenShowsTheConsole() async throws {
        let (_, scene) = try await started(.plain())
        let screen = try gameScreen(of: scene)
        let home = try homeButton(of: screen)
        try await waitUntil("it fades away", timeout: fadeTimeout) { !screen.showsHome }
        try await pause(0.6)
        // Faded away, it stays where it was, there to touch: a touch on its
        // place comes to Cartouche rather than to the game, whose process
        // iOS hands the touches on its scene.
        XCTAssertFalse(home.isHidden)
        XCTAssertGreaterThan(home.alpha, 0.01, "UIKit gives no touch to a view at 0.01 or less")
        XCTAssertTrue(home.isUserInteractionEnabled)
        let place = home.convert(CGPoint(x: home.bounds.midX, y: home.bounds.midY), to: screen.view)
        XCTAssertEqual(screen.view.hitTest(place, with: nil)?.isDescendant(of: home), true,
                       "a touch on its place goes to the Home button")

        // A tap on its place brings it back, and only that.
        tap(home)
        XCTAssertTrue(screen.showsHome)
        try await pause(0.7)
        XCTAssertEqual(actions.running?.isInFront, true, "the touch that brought it back shows no console")
        XCTAssertEqual(home.alpha, CartoucheGameScreen.homeOpacity, accuracy: 0.01)
        // A tap on it, now that it shows: the console, the game paused.
        tap(home)
        try await waitUntil("the console shows") { actions.running?.isInFront == false }
        XCTAssertEqual(scene.presenter?.scene?.settings.foreground, false)
    }

    func testATouchOnItKeepsItAFewSecondsMoreThenItFadesAgain() async throws {
        let (_, scene) = try await started(.plain())
        let screen = try gameScreen(of: scene)
        let home = try homeButton(of: screen)
        try await waitUntil("it fades away", timeout: fadeTimeout) { !screen.showsHome }
        tap(home)
        let touched = Date()
        XCTAssertTrue(screen.showsHome)
        try await waitUntil("it fades away again", timeout: fadeTimeout) { !screen.showsHome }
        XCTAssertGreaterThan(Date().timeIntervalSince(touched), 2.5, "a few seconds after the touch")
        XCTAssertEqual(actions.running?.isInFront, true)
    }

    func testItShowsAgainAsTheGameComesBackFromTheConsole() async throws {
        let (_, scene) = try await started(.plain())
        let screen = try gameScreen(of: scene)
        try await waitUntil("it fades away", timeout: fadeTimeout) { !screen.showsHome }
        scene.pressControllerHome()
        try await waitUntil("the console shows") { actions.running?.isInFront == false }
        try await pause(0.7)
        scene.pressControllerHome()
        try await waitUntil("the game shows again") { actions.running?.isInFront == true }
        XCTAssertTrue(screen.showsHome, "the way back shows as the game comes back")
        try await waitUntil("then it fades away", timeout: fadeTimeout) { !screen.showsHome }
    }

    func testTheFirstTimeItFadesALineSaysHowToBringItBackOnceOnly() async throws {
        let (_, scene) = try await started(.plain())
        let screen = try gameScreen(of: scene)
        let home = try homeButton(of: screen)
        XCTAssertFalse(shows(CartoucheText.homeFadesHint, in: screen.view), "not while it shows")
        try await waitUntil("it fades away", timeout: fadeTimeout) { !screen.showsHome }
        XCTAssertTrue(shows(CartoucheText.homeFadesHint, in: screen.view), "the line over its place")
        XCTAssertTrue(UserDefaults.standard.bool(forKey: CartoucheGameScreen.homeHintKey))
        try await waitUntil("the line goes", timeout: fadeTimeout) { !shows(CartoucheText.homeFadesHint, in: screen.view) }
        tap(home)
        try await waitUntil("it fades away again", timeout: fadeTimeout) { !screen.showsHome }
        try await pause(0.3)
        XCTAssertFalse(shows(CartoucheText.homeFadesHint, in: screen.view), "once only")
    }

    func testItStaysForVoiceOverAndFadesOnceVoiceOverStops() async throws {
        HarnessLC.assistiveTechnologyRuns = true
        let (_, scene) = try await started(.plain())
        let screen = try gameScreen(of: scene)
        try await pause(4.5)
        XCTAssertTrue(screen.showsHome, "VoiceOver and Switch Control reach only the buttons on screen")
        HarnessLC.assistiveTechnologyRuns = false
        NotificationCenter.default.post(name: UIAccessibility.voiceOverStatusDidChangeNotification, object: nil)
        XCTAssertTrue(screen.showsHome, "a while yet")
        try await waitUntil("it fades away", timeout: fadeTimeout) { !screen.showsHome }
    }

    func testItStaysOverTheCoverThatHidesTheGameFromACopyOfTheScreen() async throws {
        // A recording of the screen, or a Mac's iPhone Mirroring: the game
        // hides at once (TVTests).
        HarnessLC.soundGoesToADisplay = false
        let (_, scene) = try await started(.plain())
        let screen = try gameScreen(of: scene)
        defer { try? copyTheIPhonesScreen(false) }
        try copyTheIPhonesScreen()
        try await waitUntil("the game hides") { screen.hidesGameForTV }
        try await pause(4.5)
        XCTAssertTrue(screen.showsHome, "over the cover, where the game is not to see, the way back stays")
        try copyTheIPhonesScreen(false)
        try await waitUntil("the game shows again") { !screen.hidesGameForTV }
        XCTAssertTrue(screen.showsHome, "a while yet")
        try await waitUntil("then it fades away", timeout: fadeTimeout) { !screen.showsHome }
    }

    // MARK: Helpers

    /// The Home button over the game.
    private func homeButton(of screen: CartoucheGameScreen, file: StaticString = #filePath,
                            line: UInt = #line) throws -> UIButton {
        try XCTUnwrap(button("game.home", in: screen.view), "the Home button", file: file, line: line)
    }

    /// A tap on BUTTON, as UIKit sends it: the touch begins on it, then ends
    /// on it, which a button says once as .primaryActionTriggered. Sent
    /// with .touchUpInside, which a button turns into one more
    /// .primaryActionTriggered, the end of the touch came twice: the second
    /// showed the console from a touch that only brought the button back
    /// (run 43618025233).
    private func tap(_ button: UIButton) {
        button.sendActions(for: .touchDown)
        button.sendActions(for: .primaryActionTriggered)
    }

    /// The button of IDENTIFIER in VIEW, VIEW itself included.
    private func button(_ identifier: String, in view: UIView) -> UIButton? {
        if view.accessibilityIdentifier == identifier, let button = view as? UIButton {
            return button
        }
        for subview in view.subviews {
            if let found = button(identifier, in: subview) {
                return found
            }
        }
        return nil
    }

    /// Whether VIEW, or a view in it, shows TEXT.
    private func shows(_ text: String, in view: UIView) -> Bool {
        if let label = view as? UILabel, label.text == text {
            return true
        }
        return view.subviews.contains { shows(text, in: $0) }
    }

    /// iOS captures the iPhone's screen, or stops, and says so to the scene
    /// that Cartouche's windows are in, as it records it (TVTests).
    private func copyTheIPhonesScreen(_ copied: Bool = true, file: StaticString = #filePath, line: UInt = #line) throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.lazy.compactMap { $0 as? UIWindowScene }.first,
                                  file: file, line: line)
        if copied {
            scene.traitOverrides.sceneCaptureState = .active
        } else {
            scene.traitOverrides.remove(UITraitSceneCaptureState.self)
        }
    }
}
