//
//  MacConsoleTests.swift
//  CartoucheConsoleTests
//
//  The console's screens on the Mac know a game nxnative built for the Mac
//  as the iPhone's know an installed game (ConsoleGames.swift): by its app's
//  Info.plist, in its Contents. The console keeps each game it shows from
//  one list to the next, says which one runs, and finds the game's data
//  where nxnative's app keeps it, in apps and folders of the tests' own.
//

import Foundation
import XCTest
@testable import CartoucheConsole

final class MacConsoleTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("mac-console-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    /// An app as nxnative builds one for the Mac (dm/mac): its Info.plist in
    /// its Contents, with INFO.
    private func makeApp(_ name: String, _ info: [String: Any]) throws -> URL {
        let app = root.appendingPathComponent("Applications/\(name).app", isDirectory: true)
        let contents = app.appendingPathComponent("Contents", isDirectory: true)
        try FileManager.default.createDirectory(at: contents.appendingPathComponent("MacOS"), withIntermediateDirectories: true)
        let data = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
        try data.write(to: contents.appendingPathComponent("Info.plist"))
        return app
    }

    private func nxnativeApp(_ name: String, titleID: String) throws -> URL {
        try makeApp(name, ["CFBundleIdentifier": "org.nxnative." + titleID.lowercased(), "CFBundleName": name,
                           "CFBundleExecutable": name, "CFBundlePackageType": "APPL"])
    }

    func testAGamesAppIsWhatItsInfoPlistSays() throws {
        let url = try makeApp("Mario Kart 8 Deluxe", ["CFBundleIdentifier": "org.nxnative.0100152000022000",
                                                      "CFBundleName": "MK8", "CFBundleDisplayName": "Mario Kart 8 Deluxe"])
        let info = LCAppInfo(url: url)
        XCTAssertEqual(info.displayName(), "Mario Kart 8 Deluxe")
        XCTAssertEqual(info.bundleIdentifier(), "org.nxnative.0100152000022000")
        // Where the iPhone's bundle holds its Info.plist: the Mac's app has it in its Contents.
        XCTAssertEqual(info.bundlePath(), url.appendingPathComponent("Contents").path)
        XCTAssertEqual(info.relativeBundlePath, url.standardizedFileURL.path)
        XCTAssertNil(info.info(), "LiveContainer's own settings, which a Mac has none of")
        XCTAssertNotNil(info.installationDate)
        // No icon of its own: the console draws the game's, never the Mac's
        // icon of any app.
        XCTAssertNil(info.iconIsDarkIcon(true))
    }

    func testAnAppWithoutANameIsNamedAfterItsFile() throws {
        let url = try makeApp("Kirby and the Forgotten Land", ["CFBundleIdentifier": "org.nxnative.01004d300c5ae000"])
        XCTAssertEqual(LCAppInfo(url: url).displayName(), "Kirby and the Forgotten Land")
    }

    @MainActor
    func testTheCatalogueKnowsAGameByItsAppsBundleID() throws {
        let app = LCAppModel(appInfo: LCAppInfo(url: try nxnativeApp("Mario Kart 8 Deluxe", titleID: "0100152000022000")))
        let other = LCAppModel(appInfo: LCAppInfo(url: try makeApp("Notes", ["CFBundleIdentifier": "com.example.notes"])))
        XCTAssertEqual(CartoucheCatalog.shared.gameTitle(of: app), "0100152000022000")
        XCTAssertNil(CartoucheCatalog.shared.gameTitle(of: other), "an app that is not an nxnative game")
        let entries = CartoucheCatalog.shared.entries(for: [app, other])
        XCTAssertEqual(entries.owned.map(\.app), [app])
        XCTAssertEqual(entries.owned.first?.id, "app:" + app.appInfo.url.path)
    }

    @MainActor
    func testTheConsoleKeepsEachGameFromOneListToTheNext() throws {
        let console = CartoucheMacConsole.shared
        let kart = try nxnativeApp("Mario Kart 8 Deluxe", titleID: "0100152000022000")
        let kirby = try nxnativeApp("Kirby and the Forgotten Land", titleID: "01004D300C5AE000")
        console.show(games: [kart, kirby])
        let first = console.apps
        XCTAssertEqual(first.map(\.displayName), ["Mario Kart 8 Deluxe", "Kirby and the Forgotten Land"])
        // The same games again, in another order, one twice and one by
        // another spelling of its path: the same models, each once.
        let again = URL(fileURLWithPath: kart.path + "/../" + kart.lastPathComponent)
        console.show(games: [kirby, kart, again])
        XCTAssertEqual(console.apps.count, 2)
        XCTAssertTrue(console.apps[0] === first[1])
        XCTAssertTrue(console.apps[1] === first[0])
        console.show(games: [])
        XCTAssertTrue(console.apps.isEmpty)
    }

    @MainActor
    func testTheConsoleSaysWhichGameRuns() throws {
        let console = CartoucheMacConsole.shared
        let actions = CartoucheGameActions.shared
        let kart = try nxnativeApp("Mario Kart 8 Deluxe", titleID: "0100152000022000")
        let kirby = try nxnativeApp("Kirby and the Forgotten Land", titleID: "01004D300C5AE000")
        console.show(games: [kart, kirby])
        let kartModel = console.apps[0]

        console.showRunning(kart, inFront: true)
        XCTAssertTrue(actions.isRunning(kartModel))
        XCTAssertFalse(actions.isRunning(console.apps[1]))
        XCTAssertEqual(actions.running?.isInFront, true)
        let started = try XCTUnwrap(actions.running?.started)

        // Back to the console: the same game, behind it now.
        console.showRunning(kart, inFront: false)
        XCTAssertEqual(actions.running?.isInFront, false)
        XCTAssertEqual(actions.running?.started, started)

        // Quit asks the app to end the game that runs.
        var quit: [URL] = []
        console.onQuit = { quit.append($0) }
        actions.askToQuit()
        XCTAssertEqual(quit.map(\.path), [kart.standardizedFileURL.path])

        // Its app gone from the list, the game no longer runs here.
        console.show(games: [kirby])
        XCTAssertNil(actions.running)
        console.showRunning(kart, inFront: true)
        XCTAssertNil(actions.running, "a game the console does not show")
        console.show(games: [])
    }

    /// The words of LANGUAGE, as console/strings.py writes them in the app's
    /// Resources: a folder that holds that language alone, at its root and
    /// in its localization.
    private func writeWords(_ words: [String: String], language: String, in resources: URL) throws {
        let alone = resources.appendingPathComponent("Console/\(language)", isDirectory: true)
        let data = try PropertyListSerialization.data(fromPropertyList: words, format: .binary, options: 0)
        for folder in [alone, alone.appendingPathComponent("\(language).lproj", isDirectory: true)] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try data.write(to: folder.appendingPathComponent("Cartouche.strings"))
        }
    }

    @MainActor
    func testTheConsoleSpeaksTheLanguageTheAppChooses() throws {
        let console = CartoucheMacConsole.shared
        let resources = root.appendingPathComponent("Resources", isDirectory: true)
        try writeWords(["action.play": "Jouer", "sheet.onThisIPhone": "Sur ce Mac"], language: "fr", in: resources)
        try writeWords(["action.play": "Play", "sheet.onThisIPhone": "On this Mac"], language: "en", in: resources)
        defer { console.speak(nil) }

        console.speak("fr", from: resources)
        XCTAssertEqual(console.language, "fr")
        XCTAssertEqual(CartoucheText.play, "Jouer")
        XCTAssertEqual(CartoucheText.onThisIPhone, "Sur ce Mac")
        // A word the table lacks: the English the code carries.
        XCTAssertEqual(CartoucheText.quit, "Quit")
        // IGDB's descriptions are translated into it.
        XCTAssertEqual(CartoucheGameSummaryView.language?.minimalIdentifier, "fr")

        console.speak("en", from: resources)
        XCTAssertEqual(CartoucheText.onThisIPhone, "On this Mac")
        XCTAssertNil(CartoucheGameSummaryView.language)

        // A language the console does not have: the Mac's, from the app's
        // own bundle.
        console.speak("de", from: resources)
        XCTAssertNil(console.language)
        XCTAssertEqual(CartoucheText.bundle.bundleURL, Bundle(for: CartoucheCatalog.self).bundleURL)
    }

    @MainActor
    func testAGamesFoldersAreItsAppAndNxnativesDataForIt() throws {
        let actions = CartoucheGameActions.shared
        let kept = actions.dataRoot
        defer { actions.dataRoot = kept }
        actions.dataRoot = root.appendingPathComponent("nxnative", isDirectory: true)
        let url = try nxnativeApp("Mario Kart 8 Deluxe", titleID: "0100152000022000")
        let app = LCAppModel(appInfo: LCAppInfo(url: url))

        // Before its first start, no data yet.
        var folders = try XCTUnwrap(actions.folders(of: app))
        XCTAssertEqual(folders.titleId, "0100152000022000")
        XCTAssertEqual(folders.bundleId, "org.nxnative.0100152000022000")
        XCTAssertEqual(folders.bundle.path, url.appendingPathComponent("Contents").path)
        XCTAssertTrue(folders.data.isEmpty)

        let data = actions.dataRoot.appendingPathComponent("0100152000022000/save", isDirectory: true)
        try FileManager.default.createDirectory(at: data, withIntermediateDirectories: true)
        try Data(repeating: 1, count: 4096).write(to: data.appendingPathComponent("progress.bin"))
        folders = try XCTUnwrap(actions.folders(of: app))
        XCTAssertEqual(folders.data.mapValues(\.lastPathComponent), ["0100152000022000": "0100152000022000"])
        let size = folders.measure()
        XCTAssertGreaterThanOrEqual(size.data, 4096)
        XCTAssertGreaterThan(size.bundle, 0)

        let notes = LCAppModel(appInfo: LCAppInfo(url: try makeApp("Notes", ["CFBundleIdentifier": "com.example.notes"])))
        XCTAssertNil(actions.folders(of: notes))
    }
}
