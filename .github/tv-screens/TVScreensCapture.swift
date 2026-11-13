//
//  TVScreensCapture.swift
//  CartoucheHarnessTests
//
//  Research only (the TV mode's thread), removed before the merge: the
//  screenshots of the cover over the game (#165) that Ad validates, in
//  French, from the game's screen on the iPhone, which a TV that mirrors
//  the iPhone shows as it is. The workflow tv-screens.yml copies this file
//  into launcher/Harness/Tests and runs it alone; the screenshots go to the
//  harness's Library/Logs/Screens.
//

import UIKit
import XCTest
@testable import CartoucheHarness

@available(iOS 18.0, *)
final class TVScreensCapture: HarnessCase {
    override func tearDown() async throws {
        copyTheIPhonesScreen(false)
        try await super.tearDown()
    }

    func testTheCoverOverTheGame() async throws {
        print("tv-screens: languages \(Bundle.main.preferredLocalizations), \(Locale.preferredLanguages); "
              + "\"\(CartoucheText.tvShowAnyway)\"")
        HarnessLC.soundGoesToADisplay = true
        let (_, scene) = try await started(.plain())
        let screen = try XCTUnwrap(scene.parent as? CartoucheGameScreen)
        // The game as it shows, as 0.12.1 leaves it while iOS 27 copies the
        // iPhone's screen to a TV or records it: it sees neither.
        try await pause(2)
        try await save(screen, "1-avant-le-jeu-reste-affiche")
        // A TV, by cable or AirPlay, mirrors the iPhone.
        copyTheIPhonesScreen(true)
        try await waitUntil("the game hides") { screen.hidesGameFrom == .tv }
        try await pause(0.6)
        try await save(screen, "2-apres-tele-en-recopie-au-branchement")
        try await waitUntil("the way to show the game anyway", timeout: 8) {
            Self.view("game.tvCover.anyway", in: screen.view)?.isHidden == false
        }
        try await pause(0.6)
        try await save(screen, "3-apres-tele-en-recopie-4-secondes-plus-tard")
        copyTheIPhonesScreen(false)
        try await waitUntil("the game shows again") { !screen.hidesGameForTV }
        // A recording of the screen, or a Mac's iPhone Mirroring: the sound
        // stays on the iPhone.
        HarnessLC.soundGoesToADisplay = false
        copyTheIPhonesScreen(true)
        try await waitUntil("the game hides from the recording") { screen.hidesGameFrom == .elsewhere }
        try await pause(0.6)
        try await save(screen, "4-apres-enregistrement-ou-recopie-sur-un-mac")
    }

    /// iOS captures the iPhone's screen, or stops (TVTests).
    private func copyTheIPhonesScreen(_ copied: Bool) {
        guard let scene = UIApplication.shared.connectedScenes.lazy.compactMap({ $0 as? UIWindowScene }).first else {
            return
        }
        if copied {
            scene.traitOverrides.sceneCaptureState = .active
        } else {
            scene.traitOverrides.remove(UITraitSceneCaptureState.self)
        }
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
        print("tv-screens: \(name), \(Int(image.size.width))x\(Int(image.size.height)) points at \(Int(image.scale))x")
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
}
