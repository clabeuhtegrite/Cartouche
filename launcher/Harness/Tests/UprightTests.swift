//
//  UprightTests.swift
//  CartoucheHarnessTests
//
//  The ways the screen of a game behind the console turns on an iPhone
//  (CartoucheGameScreen, CartoucheGameOrientations.behindTheConsole):
//  upright too, as the player holds the iPhone, for a game that lays itself
//  out upright, as nxnative's games built since 4 November 2026 do, whose
//  Info.plist lists every way for an iPad; sideways only for a game built
//  before. The Simulator holds its iPhone upright: the log says which way
//  the game's screen is turned. While the game's picture is on a TV, the
//  screen turns sideways only (TVTests). On an iPad, the screen turns as
//  the game allows (IPadTests): these run on an iPhone.
//

import UIKit
import XCTest
@testable import CartoucheHarness

@available(iOS 18.0, *)
final class UprightTests: HarnessCase {
    private let uprightOrSideways: UIInterfaceOrientationMask = [.portrait, .landscapeLeft, .landscapeRight]
    private var onIPad: Bool { UIDevice.current.userInterfaceIdiom == .pad }

    /// Up to 0.12.1, the screen of nxnative's games turned sideways only on
    /// an iPhone, and on the outer display of the iPhone Duo, as their own
    /// app does, though they lay their picture above their controls
    /// upright, as the Duo's inner display shows them.
    func testAGameThatLaysItselfOutUprightTurnsUprightToo() async throws {
        try XCTSkipIf(onIPad, "on an iPhone")
        let (_, scene) = try await started(.laidOutUpright())
        let screen = try gameScreen(of: scene)
        XCTAssertEqual(screen.turns, [.portrait, .landscape])
        XCTAssertEqual(screen.supportedInterfaceOrientations, uprightOrSideways)
        noteTurn(of: screen)
    }

    /// A game nxnative built before 4 November allows sideways only, on an
    /// iPad too: upright, its picture would stay in the middle, its
    /// controls laid out to be held sideways.
    func testAGameBuiltBeforeNxnativeLaidGamesOutUprightStaysSideways() async throws {
        try XCTSkipIf(onIPad, "on an iPhone")
        let (_, scene) = try await started(.plain())
        let screen = try gameScreen(of: scene)
        XCTAssertEqual(screen.turns, .landscape)
        XCTAssertEqual(screen.supportedInterfaceOrientations, .landscape)
        noteTurn(of: screen)
    }

    /// Paused under the console and back: the game's screen turns as it
    /// did.
    func testTheGameTurnsUprightTooAfterThePause() async throws {
        try XCTSkipIf(onIPad, "on an iPhone")
        let (_, scene) = try await started(.laidOutUpright())
        let screen = try gameScreen(of: scene)
        try await pause(0.7)
        scene.pressControllerHome()
        try await waitUntil("the console shows") { actions.running?.isInFront == false }
        try await pause(0.7)
        scene.pressControllerHome()
        try await waitUntil("the game shows again") { actions.running?.isInFront == true }
        XCTAssertEqual(screen.supportedInterfaceOrientations, uprightOrSideways)
        noteTurn(of: screen)
    }

    // MARK: Helpers

    /// Says in the log which way iOS turned the game's screen, and its
    /// size: the Simulator holds its iPhone upright.
    private func noteTurn(of screen: CartoucheGameScreen) {
        guard let scene = screen.view.window?.windowScene else { return }
        let turned: String
        switch scene.effectiveGeometry.interfaceOrientation {
        case .portrait: turned = "upright"
        case .portraitUpsideDown: turned = "upside down"
        case .landscapeLeft, .landscapeRight: turned = "sideways"
        default: turned = "unknown"
        }
        let size = screen.view.bounds.size
        NSLog("[Harness] %@: the game's screen is turned %@, %.0fx%.0f points", name, turned, size.width, size.height)
    }
}
