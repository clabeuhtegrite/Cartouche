//
//  SettingsFileTests.swift
//  Cartouche Builder
//
//  The settings the app reads and saves itself while the engine cannot run
//  yet (SettingsFile): the defaults with no file, every key it does not
//  know kept, the engine's version on a file it starts, and an older
//  builder's settings brought up to date as the engine does it: nothing
//  kept of settings taken over from another tool.
//

import XCTest
@testable import BuilderKit

final class SettingsFileTests: XCTestCase {
    private var home: BuilderHome!

    override func setUpWithError() throws {
        home = BuilderHome(FileManager.default.temporaryDirectory.appendingPathComponent("settings-\(UUID().uuidString)", isDirectory: true))
        try FileManager.default.createDirectory(at: home.root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: home.root)
    }

    private func saved() throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: home.config)) as? [String: Any])
    }

    func testNoFileIsTheDefaults() {
        let config = SettingsFile.read(home)
        XCTAssertEqual(config, BuilderConfig())
        XCTAssertTrue(config.sources.isEmpty && config.games.isEmpty && config.keys.isEmpty)
        XCTAssertFalse(config.setupDone)
    }

    func testAChangeKeepsTheKeysTheAppDoesNotKnow() throws {
        try Data(#"{"sources": "/s", "only": ["0100000000010000"], "version": 2}"#.utf8).write(to: home.config)
        try SettingsFile.write(["games": "/g", "setup_done": true], home)
        let saved = try saved()
        XCTAssertEqual(saved["sources"] as? String, "/s")
        XCTAssertEqual(saved["games"] as? String, "/g")
        XCTAssertEqual(saved["only"] as? [String], ["0100000000010000"])
        XCTAssertEqual(saved["version"] as? Int, 2)
        let config = SettingsFile.read(home)
        XCTAssertEqual(config.games, "/g")
        XCTAssertTrue(config.setupDone)
        let mode = try FileManager.default.attributesOfItem(atPath: home.config.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(mode?.intValue, 0o600)
    }

    func testSettingsTakenOverFromAnotherToolCountAsNone() throws {
        try Data(#"{"sources": "/Volumes/Share/Sources", "games": "/Volumes/Share/Games", "imported": true, "version": 1}"#.utf8).write(to: home.config)
        XCTAssertEqual(SettingsFile.read(home), BuilderConfig())
        try SettingsFile.write(["games": "/g"], home)
        let saved = try saved()
        XCTAssertEqual(Set(saved.keys), ["games", "version"])
        XCTAssertEqual(saved["version"] as? Int, SettingsFile.version)
    }

    /// The app's first settings are not an older builder's: the engine
    /// does not count them as set up because both folders are chosen.
    func testTheFirstSettingsSavedHaveTheVersion() throws {
        try FileManager.default.removeItem(at: home.config.deletingLastPathComponent())
        try SettingsFile.write(["sources": "/s", "games": "/g"], home)
        XCTAssertEqual(try saved()["version"] as? Int, SettingsFile.version)
        XCTAssertFalse(SettingsFile.read(home).setupDone)
    }

    func testAnOlderBuildersSettingsWithBothFoldersAreSetUp() throws {
        try Data(#"{"sources": "/s", "games": "/g", "version": 1}"#.utf8).write(to: home.config)
        XCTAssertTrue(SettingsFile.read(home).setupDone)
        try Data(#"{"sources": "/s", "version": 1}"#.utf8).write(to: home.config)
        XCTAssertFalse(SettingsFile.read(home).setupDone)
    }
}
