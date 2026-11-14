//
//  HomeScreensBefore.swift
//  CartoucheHarnessTests
//
//  Research only (the thread "Masquer le bouton maison en jeu"), removed
//  before the merge: the screenshots, in French, of the Home button over a
//  game behind the console as main makes it, which stays, for Ad to compare
//  with this branch's (HomeScreensAfter.swift). The workflow
//  home-screens.yml puts main's launcher and harness in place, copies this
//  file into launcher/Harness/Tests and runs it alone.
//

import UIKit
import XCTest
@testable import CartoucheHarness

@available(iOS 18.0, *)
final class HomeScreensBefore: HarnessCase {
    func testTheHomeButtonStays() async throws {
        let (_, scene) = try await started(.plain())
        let screen = try XCTUnwrap(scene.parent as? CartoucheGameScreen)
        try await pause(1)
        try await save(screen, "avant-1-au-lancement")
        try await pause(8)
        try await save(screen, "avant-3-ensuite-pendant-la-partie")
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
}
