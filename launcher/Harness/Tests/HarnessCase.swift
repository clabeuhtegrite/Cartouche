//
//  HarnessCase.swift
//  CartoucheHarnessTests
//
//  What every test of the harness starts from: Cartouche as on an iPhone
//  where it was just installed and set up (LiveContainer has its
//  certificate, nothing is installed), with nothing left of the test
//  before, and what the tests wait with. The main thread, where the
//  console draws, must never be held up long: a test fails when it was
//  held more than MAINTHREADLIMIT.
//

import Combine
import Foundation
import XCTest
@testable import CartoucheHarness

@MainActor
class HarnessCase: XCTestCase {
    /// The certificate LiveContainer signs with, as SideStore keeps one.
    var certificate = HarnessCertificate(team: "HARNESS001", password: "harness")
    /// The longest the main thread may be held up during a test.
    var mainThreadLimit: TimeInterval = 1.5
    private var watchdog: HarnessWatchdog?

    var actions: CartoucheGameActions { CartoucheGameActions.shared }
    var model: SharedModel { DataManager.shared.model }

    override func setUp() async throws {
        try await super.setUp()
        try await settle()
        HarnessLC.reset()
        resetLauncher()
        // A new certificate for each test: Cartouche checks each one once.
        certificate = HarnessCertificate(team: "HARNESS001", password: "harness", serial: Int.random(in: 1...Int(Int32.max)))
        HarnessLC.installCertificate(certificate)
        let watchdog = HarnessWatchdog()
        watchdog.start()
        self.watchdog = watchdog
    }

    override func tearDown() async throws {
        if let watchdog {
            let (worst, during) = watchdog.stop()
            if worst > mainThreadLimit {
                XCTFail(String(format: "The main thread was held up %.2f s, %@", worst, during))
            }
        }
        watchdog = nil
        try await settle()
        try await super.tearDown()
    }

    /// Waits for what the last test left under way, quits the game it left
    /// behind the console, and waits for the saves that go after it.
    private func settle() async throws {
        let actions = CartoucheGameActions.shared
        let deadline = Date().addingTimeInterval(20)
        while actions.work != nil || actions.running != nil {
            if actions.running != nil, actions.work == nil {
                actions.quitRunningGame()
            }
            guard Date() < deadline else {
                XCTFail("Cartouche was still busy from the test before: \(String(describing: actions.work?.stage))")
                break
            }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        await CartoucheSaveBackups.shared.finish()
    }

    /// The launcher's own state, as on a new install.
    private func resetLauncher() {
        let actions = CartoucheGameActions.shared
        actions.notice = nil
        actions.installed = nil
        actions.switching = nil
        actions.quitQuestion = nil
        actions.closeInstallQuestion()
        let keeping = CartoucheGameKeeping.shared
        keeping.keepsConsoleOpen = true
        for bundleId in keeping.inPlace {
            keeping.startBehind(bundleId: bundleId)
        }
        // The game's process had Increased Memory Limit, as far as Cartouche
        // knows.
        keeping.tryBehindAgain()
        let storage = CartoucheStorageSettings.shared
        for server in storage.servers {
            storage.remove(server)
        }
        for role in CartoucheStorageRole.allCases {
            storage.setPlace(nil, for: role)
        }
        for account in ["signingCertificate", "signingCertificatePassword", "appleIDEmailAddress", "appleIDPassword"] {
            CartoucheStoreKeychain.remove(account)
        }
        try? FileManager.default.removeItem(at: HarnessStorage.root)
    }

    // MARK: Waiting

    struct Timeout: Error, CustomStringConvertible {
        let description: String
    }

    /// Waits until CONDITION holds, looking every 20 ms, for at most
    /// TIMEOUT seconds, the main thread free meanwhile.
    func waitUntil(_ what: String, timeout: TimeInterval = 20, file: StaticString = #filePath, line: UInt = #line,
                   _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            guard Date() < deadline else {
                XCTFail("Waited \(Int(timeout)) s, yet not \(what)", file: file, line: line)
                throw Timeout(description: "not \(what)")
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    /// Waits SECONDS, the main thread free meanwhile.
    func pause(_ seconds: TimeInterval) async throws {
        try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }

    // MARK: Games

    /// Installs the IPA at URL as the player does from the Files picker,
    /// and returns the game once the install is over, or nil if it failed.
    /// STAGES: the steps the console showed.
    @discardableResult
    func install(_ url: URL, stages: HarnessBox<[String]>? = nil,
                 file: StaticString = #filePath, line: UInt = #line) async throws -> LCAppModel? {
        try await installing(stages: stages, file: file, line: line) { actions.install(url) }
    }

    /// Installs STORED from the games folder, and returns the game once
    /// the install is over, or nil if it failed. STAGES: the steps the
    /// console showed.
    @discardableResult
    func install(stored game: CartoucheStoredGame, stages: HarnessBox<[String]>? = nil,
                 file: StaticString = #filePath, line: UInt = #line) async throws -> LCAppModel? {
        try await installing(stages: stages, file: file, line: line) { actions.install(stored: game) }
    }

    /// Starts an install with START, and returns the game once it is over,
    /// or nil if it failed, with the steps the console showed in STAGES.
    private func installing(stages: HarnessBox<[String]>?, file: StaticString, line: UInt,
                            _ start: () -> Void) async throws -> LCAppModel? {
        actions.installed = nil
        actions.notice = nil
        let watching = actions.$work.sink { work in
            guard let work, let stages, stages.value.last != work.stage else { return }
            stages.value.append(work.stage)
        }
        defer { watching.cancel() }
        start()
        XCTAssertEqual(actions.work?.kind, .installing, "the install shows over the console at once", file: file, line: line)
        try await waitUntil("the install is over", file: file, line: line) { actions.work == nil }
        return actions.installed
    }

    /// Installs GAME's IPA, and fails if it does not install cleanly.
    func installed(_ game: HarnessGame, file: StaticString = #filePath, line: UInt = #line) async throws -> LCAppModel {
        let app = try await install(try HarnessIPA.game(game), file: file, line: line)
        XCTAssertNil(actions.notice, "installed without a word: \(String(describing: actions.notice))", file: file, line: line)
        return try XCTUnwrap(app, "\(game.name) installed", file: file, line: line)
    }

    /// Fails unless no install left anything: no app in the list, nothing
    /// in Applications, nothing signed, the unpacked files gone.
    func assertNothingInstalled(file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(model.apps.isEmpty, "no app in the list", file: file, line: line)
        XCTAssertEqual(listing(of: LCPath.bundlePath), [], "nothing in Applications", file: file, line: line)
        XCTAssertTrue(HarnessLC.signed.isEmpty, file: file, line: line)
        XCTAssertFalse(FileManager.default.fileExists(atPath: unpackingFolder.path), "the unpacked files go", file: file, line: line)
    }

    /// The installed app of BUNDLEID.
    func app(_ bundleId: String) -> LCAppModel? {
        model.apps.first { $0.appInfo.bundleIdentifier() == bundleId }
    }

    func bundle(of app: LCAppModel) throws -> URL {
        URL(fileURLWithPath: try XCTUnwrap(app.appInfo.bundlePath()), isDirectory: true)
    }

    /// The data folder the game starts with.
    func dataFolder(of app: LCAppModel) throws -> URL {
        let name = try XCTUnwrap(app.appInfo.dataUUID, "\(app.displayName) has a data folder")
        return LCPath.dataPath.appendingPathComponent(name, isDirectory: true)
    }

    /// What the game's preferences hold under KEY, as nxnative reads them.
    func preference(_ key: String, of app: LCAppModel) throws -> String? {
        let folder = try dataFolder(of: app)
        // The game's HOME, as LiveContainer sets it (LCBootstrap.m).
        let home = URL(fileURLWithPath: NSHomeDirectory() + "/Documents/Data/Application/" + folder.lastPathComponent,
                       isDirectory: true)
        let preferences = try XCTUnwrap(CartoucheGamePreferences(domain: try XCTUnwrap(app.appInfo.bundleIdentifier()), home: home))
        return preferences.string(forKey: key)
    }

    /// Writes TEXT to the file at PATH in FOLDER, with the folders it needs.
    func write(_ text: String, in folder: URL, at path: String) throws {
        let file = folder.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: file)
    }

    func exists(_ folder: URL, _ path: String) -> Bool {
        FileManager.default.fileExists(atPath: folder.appendingPathComponent(path).path)
    }

    /// The folder Cartouche unpacks IPAs into, which goes once the install
    /// is over.
    var unpackingFolder: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("CartoucheInstall", isDirectory: true)
    }

    /// The notifications named NAME posted while BODY ran.
    func notifications(_ name: Notification.Name, during body: () async throws -> Void) async rethrows -> [Notification] {
        let found = HarnessBox<[Notification]>([])
        // On the thread that posts it, at once.
        let observer = NotificationCenter.default.addObserver(forName: name, object: nil, queue: nil) { note in
            found.value.append(note)
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        try await body()
        return found.value
    }
}

/// The folders the tests use as the player's storage: a folder of the
/// iPhone, picked once (CartoucheStorageServer.Kind.folder).
enum HarnessStorage {
    static var root: URL {
        FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("HarnessStorage", isDirectory: true)
    }

    /// A folder of the player's, with its own name, kept by Cartouche as
    /// the place for ROLES.
    @MainActor
    static func folder(_ name: String, for roles: [CartoucheStorageRole]) throws -> (server: CartoucheStorageServer, url: URL) {
        let url = root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        var server = CartoucheStorageServer(kind: .folder, name: name)
        server.bookmark = try CartoucheFolder.bookmark(of: url)
        let settings = CartoucheStorageSettings.shared
        settings.save(server, secret: nil)
        for role in roles {
            settings.setPlace(CartoucheStoragePlace(server: server.id, path: ""), for: role)
        }
        return (server, url)
    }
}

/// A value that closures share.
final class HarnessBox<Value>: @unchecked Sendable {
    var value: Value

    init(_ value: Value) {
        self.value = value
    }
}

/// Watches the main thread from another one: how long a block sent to it
/// waits, at worst, and what the launcher was doing then.
final class HarnessWatchdog: @unchecked Sendable {
    private let lock = NSLock()
    private var watching = false
    private var worst: TimeInterval = 0
    private var worstAt = ""

    func start() {
        lock.lock()
        watching = true
        lock.unlock()
        let thread = Thread { [self] in
            while true {
                lock.lock()
                let goOn = watching
                lock.unlock()
                guard goOn else { return }
                let sent = Date()
                let answered = DispatchSemaphore(value: 0)
                let stage = HarnessBox("")
                DispatchQueue.main.async {
                    stage.value = MainActor.assumeIsolated {
                        CartoucheGameActions.shared.work.map { "\($0.kind) \($0.stage)" } ?? "no step under way"
                    }
                    answered.signal()
                }
                answered.wait()
                let waited = Date().timeIntervalSince(sent)
                lock.lock()
                if waited > worst {
                    worst = waited
                    worstAt = "then: " + stage.value
                }
                lock.unlock()
                Thread.sleep(forTimeInterval: 0.05)
            }
        }
        thread.name = "Harness watchdog"
        thread.start()
    }

    /// The longest wait, and what was under way as it ended.
    func stop() -> (TimeInterval, String) {
        lock.lock()
        defer { lock.unlock() }
        watching = false
        return (worst, worstAt)
    }
}
