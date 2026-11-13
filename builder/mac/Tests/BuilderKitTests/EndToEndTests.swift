//
//  EndToEndTests.swift
//  BuilderKitTests
//
//  Cartouche Builder from end to end on a Mac, as the app runs it: the
//  engine itself, the builder's Python package, run by Engine as the app
//  runs it, on a world of the tests' own (builder/tests/world.py: a
//  player's folders, two games of a few bytes, nxnative's repository with
//  a simulated build script); then the bridge to Cartouche on the iPhone,
//  over TCP on this Mac: an iPhone of the tests' own pairs with the six
//  digits both screens show, opens a session encrypted with the paired
//  key, finds the IPAs the batch put in the games folder, reads them whole,
//  sends a save, and gets no session once the Mac forgot it. No game is
//  involved. The engine's own end-to-end tests are
//  builder/tests/test_end_to_end.py.
//
//  Skipped without a Python 3.12 or later for the engine
//  (CARTOUCHE_BUILDER_PYTHON names one, as for the app).
//

import CartoucheCore
import CryptoKit
import Foundation
import Network
import XCTest
@testable import BuilderKit

/// The world world.py made, as it says it.
private struct TestWorld: Decodable {
    var root: String
    var home: String
    var package: String
    var python: String
    var sources: String
    var games: String
    /// The Mac apps folder its settings name, in the world: never the
    /// Mac's own Applications folder.
    var applications: String
    var head: String
    /// What the engine's processes need beside what Engine gives them.
    var environment: [String: String]
    /// The games, by title ID.
    var titles: [String: String]
}

private struct Failure: Error, CustomStringConvertible {
    var description: String
    init(_ description: String) { self.description = description }
}

/// The player at the Mac: lets the tests' iPhone pair, and keeps the six
/// digits the Mac showed.
@MainActor
private final class Player: BridgeServerDelegate {
    var codes: [String] = []

    func bridgeServer(_ server: BridgeServer, allowPairing name: String, code: String) async -> Bool {
        codes.append(code)
        return name == "iPhone des tests"
    }

    func bridgeServerChanged(_ server: BridgeServer) {}
}

/// The digits the iPhone showed, from the handshake's own task.
private final class Shown: @unchecked Sendable {
    private let lock = NSLock()
    private var codes: [String] = []

    func add(_ code: String) {
        lock.lock()
        codes.append(code)
        lock.unlock()
    }

    var all: [String] {
        lock.lock()
        defer { lock.unlock() }
        return codes
    }
}

final class EndToEndTests: XCTestCase {
    /// builder/, from this file.
    private static let builder = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    private var folder: URL?
    private var world: TestWorld!
    private var home: BuilderHome!
    private var engine: Engine!
    private var saved: [String: String?] = [:]

    override func setUp() async throws {
        guard let python = await PythonFinder.find() else {
            throw XCTSkip("no Python 3.12 or later for the engine (CARTOUCHE_BUILDER_PYTHON names one)")
        }
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("cartouche-e2e-\(UUID().uuidString)", isDirectory: true).resolvingSymlinksInPath()
        self.folder = folder
        let script = Self.builder.appendingPathComponent("tests/world.py")
        let made = try await Run.program(python.path, [script.path, "make", folder.path],
                                         environment: Run.environment(["PYTHONDONTWRITEBYTECODE": "1"]), timeout: 300)
        guard made.succeeded else { throw Failure("world.py make: \(made.tail(40))") }
        world = try JSONDecoder().decode(TestWorld.self, from: made.output)
        for (key, value) in world.environment {
            saved.updateValue(ProcessInfo.processInfo.environment[key], forKey: key)
            setenv(key, value, 1)
        }
        home = BuilderHome(URL(fileURLWithPath: world.home))
        engine = Engine(package: URL(fileURLWithPath: world.package), python: URL(fileURLWithPath: world.python), home: home, language: "en")
    }

    override func tearDown() async throws {
        if let home, let status = Engine.readStatus(home), status.running == true {
            Engine.stopBatch(status)
        }
        for (key, value) in saved {
            if let value {
                setenv(key, value, 1)
            } else {
                unsetenv(key)
            }
        }
        saved = [:]
        if let folder {
            try? FileManager.default.removeItem(at: folder)
        }
    }

    // MARK: The app and its engine, then the bridge

    @MainActor
    func testTheAppBuildsTheGamesAndAnIPhoneTakesThemOverTheBridge() async throws {
        // What the app shows as it opens: the engine's answers, decoded as its models.
        let doctor = try await engine.doctor()
        XCTAssertTrue(doctor.ready, "\(doctor.checks.filter { !$0.ok }.map(\.key))")
        let config = try await engine.config()
        XCTAssertEqual(config.config.games, world.games)
        let library = try await engine.library(update: true)
        XCTAssertEqual(library.engine?.head, world.head)
        XCTAssertEqual(Set(library.due.map(\.titleID)), Set(world.titles.keys))
        for game in library.games {
            XCTAssertEqual(game.name, world.titles[game.titleID])
        }

        // The Build button: a batch of its own, detached from the app, followed in status.json.
        let batch = try engine.startBatch()
        let status = try await finish(batch)
        XCTAssertEqual(status.state, "done", log())
        XCTAssertEqual(Set(status.games.filter { $0.state == "built" }.map(\.titleID)), Set(world.titles.keys), log())
        XCTAssertEqual(status.head, world.head)
        let commit = String(world.head.prefix(12))
        for game in status.games {
            XCTAssertEqual(game.commit, commit, game.titleID)
            XCTAssertEqual(game.fallback, false, game.titleID)
            // Its app for this Mac too, as every game's by default, after its IPA.
            XCTAssertEqual(game.mac, "built", game.titleID)
            XCTAssertNil(game.shownMacError, game.titleID)
        }
        let after = try await engine.library(update: false)
        XCTAssertTrue(after.due.isEmpty)
        for game in after.games {
            XCTAssertEqual(game.state, .upToDate, game.titleID)
            XCTAssertEqual(game.ipa?.present, true, game.titleID)
            XCTAssertEqual(game.build?.commit, commit, game.titleID)
            XCTAssertEqual(game.onIOS, true, game.titleID)
            XCTAssertEqual(game.onMac, true, game.titleID)
            XCTAssertEqual(game.mac?.due, false, game.titleID)
            XCTAssertEqual(game.mac?.app?.present, true, game.titleID)
            XCTAssertEqual(game.mac?.build?.commit, commit, game.titleID)
            XCTAssertEqual(game.mac?.app.map { URL(fileURLWithPath: $0.path).deletingLastPathComponent().path }, world.applications, game.titleID)
        }
        // The Mac apps the builder put on this Mac, as the Storage page lists them.
        let storage = try await engine.storage()
        XCTAssertEqual(Set(storage.apps.map(\.titleID)), Set(world.titles.keys))
        XCTAssertEqual(Set(storage.apps.map(\.on)), [true])

        // The bridge, as the app opens it: the games folder and the saves.
        let server = BridgeServer(devices: BridgeDevices(url: home.bridge), name: "Mac des tests")
        server.roots = BridgeRoots(games: URL(fileURLWithPath: world.games), saves: home.saves)
        let player = Player()
        server.delegate = player
        server.start()
        defer { server.stop() }
        let port = try await listening(server)
        let endpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: try XCTUnwrap(NWEndpoint.Port(rawValue: port)))

        // The iPhone pairs once, the player checking the same six digits on both screens.
        let device = UUID().uuidString
        let shown = Shown()
        let connection = try await CartoucheBridgeConnection.open(endpoint)
        let paired = try await CartoucheBridgeHandshake.pair(connection, device: device, name: "iPhone des tests") { shown.add($0) }
        connection.close()
        XCTAssertEqual(paired.mac, server.devices.macID)
        XCTAssertEqual(paired.name, "Mac des tests")
        XCTAssertEqual(shown.all.count, 1)
        XCTAssertEqual(shown.all.first?.count, 6)
        XCTAssertEqual(player.codes, shown.all)
        try await eventually("the pairing written down on the Mac") { server.devices.key(of: device) == paired.key }

        // Then each connection is a session encrypted with the paired key.
        let client = try await CartoucheBridgeClient.connect(endpoint, device: device, key: paired.key, mac: paired.mac)
        let top = try await client.list("")
        XCTAssertEqual(top.map(\.name), [CartoucheBridge.gamesFolder, CartoucheBridge.savesFolder])
        let listed = try await client.list(CartoucheBridge.gamesFolder)
        XCTAssertEqual(Set(listed.map(\.name)), Set(world.titles.map { "\($0.value) [\($0.key)].ipa" }))
        for item in listed {
            let local = URL(fileURLWithPath: world.games).appendingPathComponent(item.name)
            let bytes = try Data(contentsOf: local)
            XCTAssertEqual(item.size, UInt64(bytes.count), item.name)
            let read = try await client.read("\(CartoucheBridge.gamesFolder)/\(item.name)", at: 0, count: bytes.count)
            XCTAssertEqual(Data(SHA256.hash(data: read)), Data(SHA256.hash(data: bytes)), item.name)
            // What Cartouche reads in it: the game, and the nxnative commit it was built from.
            let info = try infoPlist(of: local)
            XCTAssertEqual(info["DMCommit"] as? String, commit, item.name)
            XCTAssertTrue(item.name.contains("[\(info["DMTitleID"] as? String ?? "?")]"), item.name)
        }

        // A save goes to the Mac, there only once whole.
        let titleID = try XCTUnwrap(world.titles.keys.sorted().first)
        let save = Data("a save of the tests' own".utf8)
        let upload = try await client.create("\(CartoucheBridge.savesFolder)/\(titleID)/save.zip", size: UInt64(save.count))
        try await client.write(save, upload: upload)
        try await client.finish(upload)
        XCTAssertEqual(try Data(contentsOf: home.saves.appendingPathComponent("\(titleID)/save.zip")), save)
        client.close()

        // Forgotten on the Mac, the iPhone gets no session any more.
        server.devices.remove(device)
        do {
            let again = try await CartoucheBridgeClient.connect(endpoint, device: device, key: paired.key, mac: paired.mac)
            again.close()
            XCTFail("a device the Mac forgot got a session")
        } catch {
            XCTAssertEqual((error as? CartoucheBridgeError)?.kind, .notPaired, "\(error)")
        }
    }

    // MARK: Stop

    @MainActor
    func testStopEndsTheBatchTheAppStarted() async throws {
        // Lumen Drift's dump, the smaller game, builds first, and slowly.
        let scenario = try XCTUnwrap(world.environment["NXSIM_SCENARIO"])
        try Data(#"{"slow": {"0100E2E000A20000": 120}}"#.utf8).write(to: URL(fileURLWithPath: scenario))
        let batch = try engine.startBatch()
        try await eventually("Lumen Drift building", timeout: 120) {
            Engine.readStatus(self.home)?.current.contains { $0.titleID == "0100E2E000A20000" && $0.stage == "iOS shaders" } ?? false
        }
        let running = try XCTUnwrap(Engine.readStatus(home))
        XCTAssertEqual(running.running, true)
        let asked = Date()
        Engine.stopBatch(running)
        let status = try await finish(batch, timeout: 120)
        XCTAssertLessThan(Date().timeIntervalSince(asked), 60)
        XCTAssertEqual(status.state, "stopped", log())
        XCTAssertEqual(Set(status.games.map(\.state)), ["stopped"], log())
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: world.games), [])
    }

    // MARK: Helpers

    /// Until BATCH ends: its process, and status.json saying how.
    private func finish(_ batch: Process, timeout: TimeInterval = 300) async throws -> BatchStatus {
        let deadline = Date().addingTimeInterval(timeout)
        while batch.isRunning {
            guard Date() < deadline else { throw Failure("the batch still runs after \(Int(timeout)) s: \(log())") }
            try await Task.sleep(nanoseconds: 200_000_000)
        }
        guard let status = Engine.readStatus(home) else { throw Failure("no status.json: \(log())") }
        return status
    }

    private func eventually(_ what: String, timeout: TimeInterval = 20, _ check: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !check() {
            guard Date() < deadline else { throw Failure("waited \(Int(timeout)) s for \(what): \(log())") }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
    }

    private func listening(_ server: BridgeServer) async throws -> UInt16 {
        let deadline = Date().addingTimeInterval(20)
        while Date() < deadline {
            switch server.state {
            case let .running(port):
                return port
            case let .failed(reason):
                throw Failure("the bridge did not start: \(reason)")
            default:
                try await Task.sleep(nanoseconds: 50_000_000)
            }
        }
        throw Failure("the bridge did not start in 20 s")
    }

    /// The app's Info.plist in IPA.
    private func infoPlist(of ipa: URL) throws -> [String: Any] {
        let unzip = Process()
        unzip.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        unzip.arguments = ["-p", ipa.path, "Payload/*.app/Info.plist"]
        let output = Pipe()
        unzip.standardOutput = output
        unzip.standardError = FileHandle.nullDevice
        try unzip.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        unzip.waitUntilExit()
        let plist = try PropertyListSerialization.propertyList(from: data, format: nil)
        return try XCTUnwrap(plist as? [String: Any])
    }

    /// The end of what the batches the app started said (logs/app-batch.log).
    private func log() -> String {
        guard let home, let data = try? Data(contentsOf: home.logs.appendingPathComponent("app-batch.log")) else { return "" }
        return String(String(decoding: data, as: UTF8.self).suffix(3000))
    }
}
