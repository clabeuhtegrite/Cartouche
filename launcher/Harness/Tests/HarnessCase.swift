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
    /// What took the test's time, said in the log when it takes long.
    private var timings = HarnessTimings()

    var actions: CartoucheGameActions { CartoucheGameActions.shared }
    var model: SharedModel { DataManager.shared.model }

    override func setUp() async throws {
        timings = HarnessTimings()
        try await super.setUp()
        // Standard error is the app's own file, whatever pointed it
        // elsewhere since the test before (HarnessStandardError.swift).
        HarnessStandardError.keep()
        timings.settledBefore = try await settle()
        HarnessLC.reset()
        resetLauncher()
        // A new certificate for each test: Cartouche checks each one once.
        certificate = HarnessCertificate(team: "HARNESS001", password: "harness", serial: Int.random(in: 1...Int(Int32.max)))
        HarnessLC.installCertificate(certificate)
        HarnessStorage.warmUp()
        let watchdog = HarnessWatchdog()
        watchdog.start()
        self.watchdog = watchdog
        timings.setUp = Date().timeIntervalSince(timings.began)
        timings.bodyBegan = Date()
    }

    override func tearDown() async throws {
        let body = Date().timeIntervalSince(timings.bodyBegan)
        if let watchdog {
            let hold = watchdog.stop()
            if hold.seconds > mainThreadLimit {
                XCTFail(String(format: "The main thread was held up %.2f s, from %@ to %@; %@", hold.seconds, hold.from, hold.to,
                               hold.stack.isEmpty ? "no sample of it" : "a second in, it was in: " + hold.stack.prefix(30).joined(separator: " < ")))
            }
        }
        watchdog = nil
        let settled = try await settle()
        try await super.tearDown()
        let total = Date().timeIntervalSince(timings.began)
        // A test takes a few seconds: one that takes far longer waited on
        // something, which the log says, for the results cannot be read
        // from the pull request.
        if total > 20 {
            print(String(format: "harness: %@ took %.1f s: set up %.1f s (waiting for the test before %.1f s), "
                         + "its steps %.1f s (the longest wait %.1f s, for %@), cleaning up %.1f s (waiting %.1f s)",
                         name, total, timings.setUp, timings.settledBefore, body, timings.longestWait.seconds,
                         timings.longestWait.what.isEmpty ? "nothing" : "\"\(timings.longestWait.what)\"",
                         total - timings.setUp - body, settled))
        }
    }

    /// Waits for what the last test left under way, quits the game it left
    /// behind the console, and waits for the saves that go after it. How
    /// long it waited.
    @discardableResult
    private func settle() async throws -> TimeInterval {
        let began = Date()
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
        return Date().timeIntervalSince(began)
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
        // No TV left by the test before (TVTests).
        if #available(iOS 18.0, *), let tv = CartoucheTV.shared.window {
            CartoucheTV.shared.disconnect(tv)
            tv.isHidden = true
        }
    }

    // MARK: Waiting

    struct Timeout: Error, CustomStringConvertible {
        let description: String
    }

    /// Waits until CONDITION holds, looking every 20 ms, for at most
    /// TIMEOUT seconds, the main thread free meanwhile.
    func waitUntil(_ what: String, timeout: TimeInterval = 20, file: StaticString = #filePath, line: UInt = #line,
                   _ condition: () -> Bool) async throws {
        let began = Date()
        defer {
            let waited = Date().timeIntervalSince(began)
            if waited > timings.longestWait.seconds {
                timings.longestWait = (what, waited)
            }
        }
        let deadline = began.addingTimeInterval(timeout)
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

    /// Installs GAME and starts it behind the console, once its scene shows.
    func started(_ game: HarnessGame, file: StaticString = #filePath,
                 line: UInt = #line) async throws -> (LCAppModel, AppSceneViewController) {
        guard CartoucheGameKeeping.isAvailable else {
            XCTFail("LiveContainer's LiveProcess extension is not in the harness", file: file, line: line)
            throw Timeout(description: "no LiveProcess")
        }
        let app = try await installed(game, file: file, line: line)
        let shown = HarnessScenes.shownCount
        actions.play(app)
        try await waitUntil("the start is over", file: file, line: line) { actions.work == nil }
        XCTAssertNil(actions.notice, file: file, line: line)
        let running = try XCTUnwrap(actions.running, "\(game.name) runs behind the console", file: file, line: line)
        XCTAssertTrue(running.app === app, file: file, line: line)
        try await waitUntil("its scene shows", file: file, line: line) { HarnessScenes.shownCount > shown }
        return (app, try XCTUnwrap(HarnessScenes.running, file: file, line: line))
    }

    /// The screen of the game behind the console, which holds its scene.
    @available(iOS 18.0, *)
    func gameScreen(of scene: AppSceneViewController, file: StaticString = #filePath,
                    line: UInt = #line) throws -> CartoucheGameScreen {
        try XCTUnwrap(scene.parent as? CartoucheGameScreen, file: file, line: line)
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

    @MainActor private static var warmedUp = false

    /// Has iOS make and read a bookmark of a folder once, before the first
    /// test watches the main thread. The simulator's first bookmark waits
    /// on a file provider starting up (1.9 s on the CI's Mac), which an
    /// iPhone did long before the player picks a folder in Files: the test
    /// that picks one first would fail on the simulator, not on Cartouche.
    @MainActor
    static func warmUp() {
        guard !warmedUp else { return }
        warmedUp = true
        let url = root.appendingPathComponent("WarmUp", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        if let bookmark = try? CartoucheFolder.bookmark(of: url) {
            var stale = false
            _ = try? URL(resolvingBookmarkData: bookmark, options: [], relativeTo: nil, bookmarkDataIsStale: &stale)
        }
        try? FileManager.default.removeItem(at: root)
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

/// What took a test's time.
struct HarnessTimings {
    let began = Date()
    /// Setting up, and of it, waiting for what the test before left.
    var setUp: TimeInterval = 0
    var settledBefore: TimeInterval = 0
    var bodyBegan = Date()
    /// The test's longest wait, and what it waited for.
    var longestWait: (what: String, seconds: TimeInterval) = ("", 0)
}

/// Watches the main thread from another one: how long a block sent to it
/// waits, at worst, what the launcher was doing as the wait began and as
/// it ended, and where the main thread was a second into it.
final class HarnessWatchdog: @unchecked Sendable {
    struct Hold {
        var seconds: TimeInterval = 0
        var from = ""
        var to = ""
        var stack: [String] = []
    }

    private let lock = NSLock()
    private var watching = false
    private var worst = Hold()

    /// What the launcher is doing, on the main thread.
    @MainActor
    private static func step() -> String {
        CartoucheGameActions.shared.work.map { "\($0.kind) \($0.stage)" } ?? "no step under way"
    }

    /// From the main thread.
    func start() {
        precondition(Thread.isMainThread)
        let main = pthread_self()
        lock.lock()
        watching = true
        lock.unlock()
        let thread = Thread { [self] in
            var last = "no step under way"
            while true {
                lock.lock()
                let goOn = watching
                lock.unlock()
                guard goOn else { return }
                let sent = Date()
                let answered = DispatchSemaphore(value: 0)
                let stage = HarnessBox("")
                DispatchQueue.main.async {
                    stage.value = MainActor.assumeIsolated { Self.step() }
                    answered.signal()
                }
                var stack: [String] = []
                if answered.wait(timeout: .now() + 1) == .timedOut {
                    stack = HarnessMainThread.sample(main)
                    answered.wait()
                }
                let waited = Date().timeIntervalSince(sent)
                lock.lock()
                if waited > worst.seconds {
                    worst = Hold(seconds: waited, from: last, to: stage.value, stack: stack)
                }
                lock.unlock()
                last = stage.value
                Thread.sleep(forTimeInterval: 0.05)
            }
        }
        thread.name = "Harness watchdog"
        thread.start()
    }

    /// The longest wait.
    func stop() -> Hold {
        lock.lock()
        defer { lock.unlock() }
        watching = false
        return worst
    }
}

/// Where a thread is, from another: its frames, as the debugger would list
/// them, read while it stands still for an instant. Only the registers and
/// the thread's own stack are read meanwhile, into memory set aside before,
/// for the thread may hold a lock any other call would wait for; the names
/// come once it goes on.
enum HarnessMainThread {
    private static let capacity = 64
    private static let frames = UnsafeMutablePointer<UInt>.allocate(capacity: capacity)
    /// The registers, as thread_get_state gives ARM_THREAD_STATE64: x0 to
    /// x28, then fp, lr, sp and pc, 8 bytes each, cpsr and a pad, 4 each.
    private static let registers = UnsafeMutablePointer<natural_t>.allocate(capacity: 68)

    /// THREAD's frames, the innermost first; none where the harness cannot
    /// tell, as on an Intel Mac.
    static func sample(_ thread: pthread_t) -> [String] {
        #if arch(arm64)
        // All it needs, before the thread stands still: memory set aside
        // now, not as the thread may hold the lock of malloc.
        let frames = self.frames, registers = self.registers, capacity = self.capacity
        let port = pthread_mach_thread_np(thread)
        let top = UInt(bitPattern: pthread_get_stackaddr_np(thread))
        let bottom = top - UInt(pthread_get_stacksize_np(thread))
        var count = mach_msg_type_number_t(68)
        var found = 0
        guard thread_suspend(port) == KERN_SUCCESS else { return [] }
        if thread_get_state(port, thread_state_flavor_t(6), registers, &count) == KERN_SUCCESS, count >= 66 {
            let words = UnsafeRawPointer(registers)
            let fp = UInt(words.loadUnaligned(fromByteOffset: 232, as: UInt64.self))
            let lr = UInt(words.loadUnaligned(fromByteOffset: 240, as: UInt64.self))
            let pc = UInt(words.loadUnaligned(fromByteOffset: 256, as: UInt64.self))
            frames[0] = pc
            frames[1] = lr
            found = 2
            var frame = fp
            while found < capacity, frame >= bottom, frame <= top - 16, frame % 16 == 0,
                  let pointer = UnsafePointer<UInt>(bitPattern: frame) {
                let next = pointer[0]
                frames[found] = pointer[1]
                found += 1
                guard next > frame else { break }
                frame = next
            }
        }
        thread_resume(port)
        return (0..<found).map { name(of: frames[$0]) }
        #else
        return []
        #endif
    }

    /// The function at ADDRESS, by its image and its name.
    private static func name(of address: UInt) -> String {
        // Without the bits the system signs return addresses with, above
        // the 47 of an address.
        let code = address & 0x0000_7FFF_FFFF_FFFF
        var info = Dl_info()
        guard let pointer = UnsafeRawPointer(bitPattern: code), dladdr(pointer, &info) != 0 else {
            return String(format: "0x%lx", code)
        }
        let image = info.dli_fname.map { (String(cString: $0) as NSString).lastPathComponent } ?? "?"
        guard let symbol = info.dli_sname else { return image }
        return image + " " + demangled(symbol)
    }

    private static func demangled(_ symbol: UnsafePointer<CChar>) -> String {
        guard let readable = harnessSwiftDemangle(symbol, strlen(symbol), nil, nil, 0) else { return String(cString: symbol) }
        defer { free(readable) }
        return String(cString: readable)
    }
}

/// The Swift runtime's demangler, which the debugger uses too.
@_silgen_name("swift_demangle")
private func harnessSwiftDemangle(_ mangled: UnsafePointer<CChar>?, _ length: Int, _ output: UnsafeMutablePointer<CChar>?,
                                  _ outputSize: UnsafeMutablePointer<Int>?, _ flags: UInt32) -> UnsafeMutablePointer<CChar>?
