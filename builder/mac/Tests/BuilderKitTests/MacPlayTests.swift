//
//  MacPlayTests.swift
//  BuilderKitTests
//
//  What the builder needs to start a game's Mac app and to know how it
//  ended (MacPlay.swift), as nxnative's docs/frontends.md and its launcher
//  (dm/mac/launcher.c) say it: the app's Info.plist, the launcher's last
//  line in its log, the environment of a start, and nxnative's own cloud
//  saves, which the builder leaves a game's saves to.
//

import Foundation
import XCTest
@testable import BuilderKit

final class MacPlayTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("mac-play-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    /// An app named NAME.app whose Info.plist holds INFO.
    private func app(_ name: String, _ info: [String: Any]) throws -> URL {
        let url = root.appendingPathComponent(name + ".app", isDirectory: true)
        try FileManager.default.createDirectory(at: url.appendingPathComponent("Contents"), withIntermediateDirectories: true)
        let data = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
        try data.write(to: url.appendingPathComponent("Contents/Info.plist"))
        return url
    }

    // MARK: The app

    func testAGamesAppIsWhatItsInfoPlistSays() throws {
        let url = try app("MK8", ["DMTitleID": "0100152000022000", "CFBundleDisplayName": "Mario Kart 8 Deluxe", "CFBundleName": "MK8",
                                  "CFBundleIdentifier": "org.nxnative.0100152000022000"])
        let found = try XCTUnwrap(MacGameApp(url: url))
        XCTAssertEqual(found.titleID, "0100152000022000")
        // Its copies' folder is named after the name it shows, as Cartouche
        // names it after its IPA's.
        XCTAssertEqual(found.name, "Mario Kart 8 Deluxe")
        XCTAssertEqual(found.bundleID, "org.nxnative.0100152000022000")
        XCTAssertEqual(found.saveGame, MacSaveGame(titleID: "0100152000022000", name: "Mario Kart 8 Deluxe"))
        // Packed with another bundle ID, a lower-case ID, no display name.
        let other = try XCTUnwrap(MacGameApp(url: try app("Kirby", ["DMTitleID": "01004d300c5ae000", "CFBundleName": "Kirby",
                                                                     "CFBundleIdentifier": "com.example.kirby"])))
        XCTAssertEqual(other.titleID, "01004D300C5AE000")
        XCTAssertEqual(other.name, "Kirby")
        XCTAssertEqual(other.bundleID, "com.example.kirby")
        // No bundle ID: nxnative's own.
        XCTAssertEqual(MacGameApp(url: try app("Dread", ["DMTitleID": "010093801237C000"]))?.bundleID, "org.nxnative.010093801237C000")
        XCTAssertEqual(MacGameApp(url: try app("Dread", ["DMTitleID": "010093801237C000"]))?.name, "Dread")
        // Any other app, or none.
        XCTAssertNil(MacGameApp(url: try app("Safari", ["CFBundleName": "Safari"])))
        XCTAssertNil(MacGameApp(url: try app("Odd", ["DMTitleID": "../0100152000022000"])))
        XCTAssertNil(MacGameApp(url: root.appendingPathComponent("Missing.app")))
    }

    // MARK: How it ended

    func testTheEndingIsTheLaunchersLastLine() {
        let start = "launcher: Mario Kart 8 Deluxe (0100152000022000), host /Applications/MK8.app/Contents/MacOS/dmhost\n"
            + "launcher: no settings window (DM_LAUNCHER=0 or --no-launcher)\n[host] a game's own line\n"
        let cases: [(String, MacGameEnding, Int?)] = [
            ("launcher: the host exited with 0", .quit, 0),
            ("launcher: the host exited with 70", .gpu, 70),
            ("launcher: the host exited with 134", .crashed, 134),
            ("launcher: the host exited with 1", .crashed, 1),
            ("launcher: the host stopped on signal 15", .stopped, 143),
            ("launcher: the host stopped on signal 9", .stopped, 137),
            ("launcher: the host stopped on signal 11", .crashed, 139),
            // The window closed without playing: no host line.
            ("", .unknown, nil),
            // Words the builder does not know: unknown, never wrong.
            ("launcher: the game ended (code 0)", .unknown, nil),
        ]
        for (last, ending, exit) in cases {
            let result = MacGameEnding.parse(start + last + "\n")
            XCTAssertEqual(result.ending, ending, last)
            XCTAssertEqual(result.exit, exit, last)
        }
        // After the host's line, the launcher may still say the cloud's save did not go.
        let after = MacGameEnding.parse(start + "launcher: the host exited with 0\nlauncher: the save did not reach the cloud; it goes at the next start\n")
        XCTAssertEqual(after.ending, .quit)
    }

    func testTheEndingIsReadFromTheEndOfThisStartsLog() throws {
        let log = root.appendingPathComponent("0100152000022000.log")
        // A long log: what ends it is at its end.
        var text = "launcher: Mario Kart 8 Deluxe (0100152000022000)\n"
        text += String(repeating: "[host] frame 1234 took 16.6 ms, nothing to say\n", count: 4000)
        text += "launcher: the host stopped on signal 6\n"
        try Data(text.utf8).write(to: log)
        let read = MacGameEnding.read(log: log, since: Date().addingTimeInterval(-60))
        XCTAssertEqual(read.ending, .crashed)
        XCTAssertEqual(read.exit, 134)
        // The log of an earlier start: this one wrote none (it never ran).
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-3600)], ofItemAtPath: log.path)
        XCTAssertEqual(MacGameEnding.read(log: log, since: Date()).ending, .unknown)
        XCTAssertEqual(MacGameEnding.read(log: root.appendingPathComponent("none.log")).ending, .unknown)
    }

    // MARK: A start

    func testAStartSkipsTheWindowAndSpeaksThePlayersLanguage() throws {
        let app = MacGameApp(url: URL(fileURLWithPath: "/Applications/MK8.app"), titleID: "0100152000022000", name: "Mario Kart 8 Deluxe")
        XCTAssertEqual(MacPlayEnvironment.arguments(settings: false), ["--no-launcher"])
        XCTAssertEqual(MacPlayEnvironment.arguments(settings: true), [])
        let french = MacPlayEnvironment.make(app: app, keepsSaves: true, language: "fr")
        // Never two syncs on one save: nxnative's own cloud saves stay off.
        XCTAssertEqual(french["DM_SAVE_SYNC"], "0")
        XCTAssertNil(french["DM_SAVE"])
        // Five lines each, in nxnative's order; its placeholders kept.
        let quit = try XCTUnwrap(french["DM_HOME_QUIT_TEXT"]).components(separatedBy: "\n")
        XCTAssertEqual(quit.count, 5)
        XCTAssertEqual(quit[1], "Quitter Mario Kart 8 Deluxe ?")
        XCTAssertFalse(quit.contains(""))
        let players = try XCTUnwrap(french["DM_CTRL_PROMPT_TEXT"]).components(separatedBy: "\n")
        XCTAssertEqual(players.count, 5)
        XCTAssertTrue(players[0].contains("{min}"))
        XCTAssertTrue(players[2].contains("{joined}") && players[2].contains("{min}"))
        XCTAssertFalse(players.contains(""))
        // In English, nxnative's own texts; its saves left to its cloud saves.
        let english = MacPlayEnvironment.make(app: app, keepsSaves: false, language: "en")
        XCTAssertEqual(english, [:])
        // The tests' own folder for the game's saves.
        let documents = root.appendingPathComponent("nxnative/0100152000022000", isDirectory: true)
        XCTAssertEqual(MacPlayEnvironment.make(app: app, keepsSaves: true, language: "en", documents: documents)["DM_SAVE"],
                       documents.appendingPathComponent("save").path)
    }

    // MARK: nxnative's own cloud saves

    func testAGameWhoseSavesNxnativesCloudSyncsIsLeftToIt() throws {
        let app = MacGameApp(url: URL(fileURLWithPath: "/Applications/MK8.app"), titleID: "0100152000022000", name: "Mario Kart 8 Deluxe",
                             bundleID: "com.example.mk8")
        let documents = root.appendingPathComponent("0100152000022000", isDirectory: true)
        try FileManager.default.createDirectory(at: documents, withIntermediateDirectories: true)
        var asked: [String] = []
        var chosen: String?
        let preference: (String, String) -> String? = { key, domain in
            asked.append(domain + " " + key)
            return chosen
        }
        XCTAssertNil(MacCloudSaves.folder(of: app, documents: documents, preference: preference))
        // The app's own domain, its cloudSaves.folder key.
        XCTAssertEqual(asked, ["com.example.mk8 cloudSaves.folder"])
        chosen = "/Users/player/Library/Mobile Documents/com~apple~CloudDocs/Saves"
        XCTAssertEqual(MacCloudSaves.folder(of: app, documents: documents, preference: preference), chosen)
        chosen = ""
        XCTAssertNil(MacCloudSaves.folder(of: app, documents: documents, preference: preference))
        // The player's env.txt wins over the window's choice, as nxnative reads it: the first line that sets it.
        chosen = "/Users/player/Saves"
        let env = documents.appendingPathComponent("env.txt")
        try Data("# DM_SAVE_SYNC=icloud\nDM_FPS_TARGET=30\nDM_SAVE_SYNC=0\nDM_SAVE_SYNC=icloud\n".utf8).write(to: env)
        XCTAssertNil(MacCloudSaves.folder(of: app, documents: documents, preference: preference))
        try Data("DM_SAVE_SYNC=icloud\n".utf8).write(to: env)
        XCTAssertEqual(MacCloudSaves.folder(of: app, documents: documents, preference: preference), "icloud")
        // Set empty, it is off all the same: nxnative then reads no folder.
        try Data("DM_SAVE_SYNC=\n".utf8).write(to: env)
        XCTAssertNil(MacCloudSaves.folder(of: app, documents: documents, preference: preference))
    }
}
