//
//  IPadUITests.swift
//  CartoucheGalleryUITests
//
//  The console on the whole screen of an iPad (uitests.sh --ipad), drawn
//  as the iPad of catalog/devices.json (-GalleryModel): the sheet of the
//  game in focus stands beside the home, with Play and Game settings, a tap
//  on another cover puts that game's sheet there instead, its settings open
//  beside the console, which stays in reach, and the words call the iPad
//  the iPad (CartoucheDeviceWords). On an iPhone, which opens a game's
//  sheet over the console (ConsoleUITests), they do not run.
//

import UIKit
import XCTest

final class IPadUITests: ConsoleTestCase {
    /// The 11-inch iPad Air (M3) of catalog/devices.json.
    private let iPad = Launch(model: "iPad15,3")

    /// The sheet of the game in focus beside the home, then that of the
    /// game whose cover is tapped, in its place.
    @MainActor
    func testTheSheetOfTheGameInFocusStandsBesideTheHome() throws {
        try onAnIPad()
        let app = openConsole(iPad)
        expect(app.staticTexts[Games.inFocus].waitForExistence(timeout: 15),
               "No sheet of \(Games.inFocus) beside the home", in: app)
        expect(app.buttons[Words.gameSettings].exists, "No Game settings beside the home", in: app)
        expect(!app.buttons[Words.details].exists, "Details on the home, which the sheet beside it makes useless", in: app)

        let other = Games.names.first { $0 != Games.inFocus }!
        tap(app.buttons[other], "the cover of \(other)", in: app)
        expect(waitUntil(10) { app.buttons[other].isSelected }, "The cover of \(other) did not take the focus", in: app)
        expect(waitUntil(10) { app.staticTexts[other].exists && !app.staticTexts[Games.inFocus].exists },
               "The sheet beside the home still shows \(Games.inFocus), not \(other)", in: app)
        expect(isOnConsole(app), "The tap left the console", in: app)
        expectMainThreadAnswered(app)
    }

    /// Game settings open beside the console too, which stays in reach.
    @MainActor
    func testAGamesSettingsOpenBesideTheConsole() throws {
        try onAnIPad()
        let app = openConsole(iPad)
        tap(app.buttons[Words.gameSettings], "Game settings beside the home", in: app)
        expect(element(in: app.buttons, containing: Words.controls).waitForExistence(timeout: 10),
               "The game's settings show no Controls", in: app)
        expect(isOnConsole(app), "The game's settings cover the console", in: app)
        expectMainThreadAnswered(app)
    }

    /// The game's sheet says this iPad, never this iPhone.
    @MainActor
    func testTheWordsCallTheIPadTheIPad() throws {
        try onAnIPad()
        let app = openConsole(iPad)
        expect(app.staticTexts[Games.inFocus].waitForExistence(timeout: 15),
               "No sheet of \(Games.inFocus) beside the home", in: app)
        expect(labelled(containing: "this iPad", in: app).waitForExistence(timeout: 10),
               "The sheet does not say this iPad", in: app)
        expect(!labelled(containing: "this iPhone", in: app).exists, "The console says this iPhone on an iPad", in: app)
        expectMainThreadAnswered(app)
    }

    /// Skips the test but on an iPad with iOS 27.1 or later, where the
    /// console and a game's sheet stand side by side (CartoucheSplit).
    private func onAnIPad() throws {
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .pad, "on an iPad: uitests.sh --ipad")
        guard #available(iOS 27.1, *) else { throw XCTSkip("the sheet stands beside the console from iOS 27.1") }
    }

    /// The first element of any kind whose label holds TEXT, whatever its
    /// case: a section's header may show in capitals.
    @MainActor
    private func labelled(containing text: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS[c] %@", text)).firstMatch
    }
}
