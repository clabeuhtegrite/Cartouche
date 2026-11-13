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
//  sends a save, and gets no session once the Mac forgot it. Then a game
//  built for this Mac is played from the app, started by LaunchServices
//  as the Finder starts it: the iPhone's copy of its saves comes first, its
//  launcher (the simulated nxnative's, a script) plays from it, and the
//  Mac's saves go after it, read back as the iPhone reads them. No real
//  game is involved. The engine's own end-to-end tests are
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
    /// Where its settings install the Mac apps a games folder on a NAS
    /// keeps in one file, in the world: never the Mac's own Applications
    /// folder.
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
            // In the games folder beside its IPA: this Mac's own disk keeps
            // it as it is, played from there; nothing installed elsewhere.
            XCTAssertEqual(game.mac?.packed, false, game.titleID)
            XCTAssertEqual(game.mac?.app.map { URL(fileURLWithPath: $0.path).deletingLastPathComponent().path }, world.games, game.titleID)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: world.applications))
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

    // MARK: Playing on this Mac

    @MainActor
    func testAGameBuiltForThisMacIsPlayedWithTheIPhonesSaves() async throws {
        let batch = try engine.startBatch()
        let status = try await finish(batch)
        XCTAssertEqual(status.state, "done", log())
        let library = try await engine.library(update: false)
        let titleID = try XCTUnwrap(world.titles.keys.sorted().first)
        let built = try XCTUnwrap(library.game(titleID)?.mac?.app)
        XCTAssertTrue(built.present)
        // The app as the builder reads it: the name it shows names its copies' folder.
        let app = try XCTUnwrap(MacGameApp(url: URL(fileURLWithPath: built.path)))
        XCTAssertEqual(app.titleID, titleID)
        XCTAssertEqual(app.name, world.titles[titleID])

        // The game's folder and its logs in the world, never nxnative's own on this Mac.
        let root = try XCTUnwrap(folder)
        let games = root.appendingPathComponent("nxnative", isDirectory: true)
        let logs = root.appendingPathComponent("Logs", isDirectory: true)
        let macGames = MacGames(store: home.macSaves, scratch: home.savesScratch, games: games, logs: logs)
        macGames.environment = ["NXSIM_LOGS": logs.path, "NXSIM_EXIT": "0"]
        macGames.language = "fr"
        var heard: [String] = []
        macGames.news = { news in
            switch news {
            case let .started(run): heard.append("started \(run.app.titleID) \(run.fromBuilder ? "builder" : "elsewhere")")
            case let .ended(run, ending: ending, exit: code, seconds: _): heard.append("ended \(run.app.titleID) \(ending.rawValue) \(code.map { "\($0)" } ?? "-")")
            case let .saves(titleID: id, event: event, onShare: onShare): heard.append("saves \(id) \(event.when.rawValue) \(event.step) \(onShare)")
            }
        }
        macGames.use(apps: [app])
        macGames.use(saves: home.saves)
        XCTAssertTrue(macGames.keepsSaves(titleID))

        // The iPhone played first: its copy, made by Cartouche's own code, in the saves folder.
        let iPhone = root.appendingPathComponent("iPhone/Documents", isDirectory: true)
        let gameFolder = home.saves.appendingPathComponent(MacSavesFolder.folderName(app.saveGame), isDirectory: true)
        try await iPhonePlays("iPhone 1", in: iPhone, copyTo: gameFolder, at: Date().addingTimeInterval(-600))

        // Play: the copy comes, the game starts straight away, plays from it, quits.
        let run = try await macGames.play(titleID)
        XCTAssertEqual(run?.fromBuilder, true)
        try await eventually("the game ended and its saves went", timeout: 60) {
            !macGames.isPlaying(titleID) && macGames.last[titleID]?.step == "send"
        }
        XCTAssertEqual(heard, ["saves \(titleID) before fetch false", "started \(titleID) builder", "ended \(titleID) quit 0",
                               "saves \(titleID) after send false"])
        // What the game found: no settings window, nxnative's cloud saves off, its prompt in French, the iPhone's progress.
        let played = try String(contentsOf: games.appendingPathComponent("\(titleID)/played.txt"), encoding: .utf8)
        XCTAssertEqual(played, "window=0\nsave_sync=0\nquit_title=Quitter \(app.name) ?\nfound=iPhone 1\n")
        // The newest copy is the Mac's, as the iPhone reads it.
        let copies = try FileManager.default.contentsOfDirectory(atPath: gameFolder.path).filter { $0.hasSuffix(".zip") }.sorted()
        XCTAssertEqual(copies.count, 2)
        let sent = try await unpack(gameFolder.appendingPathComponent(try XCTUnwrap(copies.last)), into: root)
        XCTAssertEqual(sent, ["save/progress.txt": "iPhone 1 +mac\n"])

        // The iPhone plays again; a round while the game does not run brings its saves.
        try await Task.sleep(nanoseconds: 1_100_000_000)
        try await iPhonePlays("iPhone 2", in: iPhone, copyTo: gameFolder, at: Date())
        await macGames.round()
        XCTAssertEqual(macGames.last[titleID]?.step, "fetch")
        XCTAssertEqual(try String(contentsOf: games.appendingPathComponent("\(titleID)/save/progress.txt"), encoding: .utf8), "iPhone 2\n")
        // Nothing of this Mac's own nxnative folders was touched.
        XCTAssertFalse(FileManager.default.fileExists(atPath: MacSavesFolder.nxnativeFolder.appendingPathComponent(titleID).path))
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

    /// The iPhone played: its save holds PROGRESS, and Cartouche's own code
    /// made its copy in FOLDER, named after DATE.
    private func iPhonePlays(_ progress: String, in documents: URL, copyTo folder: URL, at date: Date) async throws {
        let save = documents.appendingPathComponent("save", isDirectory: true)
        try FileManager.default.createDirectory(at: save, withIntermediateDirectories: true)
        try Data((progress + "\n").utf8).write(to: save.appendingPathComponent("progress.txt"))
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let sink = try CartoucheFileSink(folder.appendingPathComponent(CartoucheSaveSync.fileName(date)))
        try await CartoucheSaveSync.writeZip(ofSavesIn: documents, to: sink)
        try sink.close()
    }

    /// What the copy at URL holds, unpacked as Cartouche unpacks one.
    private func unpack(_ url: URL, into root: URL) async throws -> [String: String] {
        let into = root.appendingPathComponent("unpacked-\(UUID().uuidString)", isDirectory: true)
        let source = try CartoucheFileSource(url)
        let entries = try await CartoucheZip.entries(of: source)
        guard CartoucheSaveSync.holdsSavesOnly(entries) else { throw Failure("\(url.lastPathComponent) holds more than saves") }
        try await CartoucheZip.extract(source, entries: entries, into: into)
        var files: [String: String] = [:]
        let walker = FileManager.default.enumerator(atPath: into.path)
        while let relative = walker?.nextObject() as? String {
            let file = into.appendingPathComponent(relative)
            var isFolder: ObjCBool = false
            if FileManager.default.fileExists(atPath: file.path, isDirectory: &isFolder), !isFolder.boolValue {
                files[relative] = try String(contentsOf: file, encoding: .utf8)
            }
        }
        return files
    }

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

    /// Until CHECK, on the main actor, where what it reads lives.
    @MainActor
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
