//
//  HomeScreensAfter.swift
//  CartoucheHarnessTests
//
//  Research only (the thread "Masquer le bouton maison en jeu"), removed
//  before the merge: the screenshots, in French, of the Home button over a
//  game behind the console as this branch makes it, which fades away and
//  comes back at a touch on its place (docs/decisions/110.md), for Ad to
//  validate. The workflow home-screens.yml copies this file into
//  launcher/Harness/Tests and runs it alone; the screenshots go to the
//  harness's Library/Logs/Screens. HomeScreensBefore.swift takes main's.
//

import UIKit
import XCTest
@testable import CartoucheHarness

@available(iOS 18.0, *)
final class HomeScreensAfter: HarnessCase {
    func testTheHomeButtonFadesAndComesBack() async throws {
        print("home-screens: languages \(Bundle.main.preferredLocalizations), \(Locale.preferredLanguages); "
              + "\"\(CartoucheText.homeFadesHint)\"")
        let (_, scene) = try await started(.plain())
        let screen = try XCTUnwrap(scene.parent as? CartoucheGameScreen)
        let home = try XCTUnwrap(Self.view("game.home", in: screen.view) as? UIButton)
        try await pause(1)
        try await save(screen, "apres-1-au-lancement")
        try await waitUntil("the Home button fades away", timeout: 8) { !screen.showsHome }
        try await pause(1)
        try await save(screen, "apres-2-trois-secondes-plus-tard-la-premiere-fois")
        try await waitUntil("the line goes", timeout: 8) { !Self.shows(CartoucheText.homeFadesHint, in: screen.view) }
        try await pause(0.5)
        try await save(screen, "apres-3-ensuite-pendant-la-partie")
        // A touch on its place.
        home.sendActions(for: .touchDown)
        home.sendActions(for: [.touchUpInside, .primaryActionTriggered])
        try await pause(0.6)
        XCTAssertEqual(actions.running?.isInFront, true, "no console")
        try await save(screen, "apres-4-un-toucher-sur-sa-place")
    }

    /// The game's window as the iPhone shows it, in Library/Logs/Screens.
    private func save(_ screen: CartoucheGameScreen, _ name: String) async throws {
        let window = try XCTUnwrap(screen.view.window, "the game's window")
        let format = UIGraphicsImageRendererFormat(for: window.traitCollection)
        let image = UIGraphicsImageRenderer(bounds: window.bounds, format: format).image { _ in
            _ = window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        let folder = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs/Screens", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let data = await Task.detached { image.pngData() }.value
        try XCTUnwrap(data, "\(name) as a PNG").write(to: folder.appendingPathComponent(name + ".png"))
        print("home-screens: \(name), \(Int(image.size.width))x\(Int(image.size.height)) points at \(Int(image.scale))x")
    }

    /// The view of IDENTIFIER in VIEW, VIEW itself included.
    private static func view(_ identifier: String, in view: UIView) -> UIView? {
        if view.accessibilityIdentifier == identifier {
            return view
        }
        for subview in view.subviews {
            if let found = Self.view(identifier, in: subview) {
                return found
            }
        }
        return nil
    }

    /// Whether VIEW, or a view in it, shows TEXT.
    private static func shows(_ text: String, in view: UIView) -> Bool {
        if let label = view as? UILabel, label.text == text {
            return true
        }
        return view.subviews.contains { shows(text, in: $0) }
    }
}
