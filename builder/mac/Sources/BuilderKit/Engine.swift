//
//  Engine.swift
//  Cartouche Builder
//
//  The builder's engine, the Python package cartouche_builder that the app
//  carries in its Resources: its `api` commands answer one JSON object
//  each, and its batches run on their own, detached from the app, writing
//  what they do in status.json. The app finds a Python 3.12 or later for it
//  (Homebrew's, which Préparer ce Mac installs).
//

import Darwin
import Foundation

/// The builder's folder: ~/Library/Application Support/Cartouche Builder,
/// as the engine's paths.py has it.
public struct BuilderHome: Equatable, Sendable {
    public var root: URL

    public init(_ root: URL) {
        self.root = root
    }

    public static var `default`: BuilderHome {
        if let forced = ProcessInfo.processInfo.environment["CARTOUCHE_BUILDER_HOME"], !forced.isEmpty {
            return BuilderHome(URL(fileURLWithPath: (forced as NSString).expandingTildeInPath))
        }
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return BuilderHome(support.appendingPathComponent("Cartouche Builder", isDirectory: true))
    }

    public var config: URL { root.appendingPathComponent("config.json") }
    public var status: URL { root.appendingPathComponent("status.json") }
    public var queue: URL { root.appendingPathComponent("queue.json") }
    public var library: URL { root.appendingPathComponent("library.json") }
    public var bridge: URL { root.appendingPathComponent("bridge.json") }
    public var logs: URL { root.appendingPathComponent("logs", isDirectory: true) }
    public var engine: URL { root.appendingPathComponent("nxnative", isDirectory: true) }
    public var saves: URL { root.appendingPathComponent("Saves", isDirectory: true) }
}

/// The engine's settings (config.json), while the engine cannot run yet:
/// its Python comes with the Mac's tools, after the setup assistant's
/// first steps. The app reads them as they are saved, and saves a change
/// as the engine would, keeping every key it does not know; the engine
/// reads them when it starts (config.py). They are brought up to date as
/// the engine does it (config.migrate): settings an older builder took
/// over from another tool ("imported") count as none, and an older
/// builder's settings with both folders chosen as set up.
public enum SettingsFile {
    /// The settings' version, as config.py's VERSION: a file the app starts
    /// is not one of an older builder's (test_app_contract.py checks it).
    public static let version = 2

    public static func read(_ home: BuilderHome) -> BuilderConfig {
        guard let data = try? Data(contentsOf: home.config), let saved = object(data),
              var config = try? JSONDecoder().decode(BuilderConfig.self, from: data) else { return BuilderConfig() }
        if saved["imported"] as? Bool == true { return BuilderConfig() }
        if (saved["version"] as? Int ?? 0) < version, !config.sources.isEmpty, !config.games.isEmpty {
            config.setupDone = true
        }
        return config
    }

    /// Saves CHANGES, as BuilderConfig.changes(from:) gives them.
    public static func write(_ changes: [String: Any], _ home: BuilderHome) throws {
        var saved: [String: Any] = [:]
        if let data = try? Data(contentsOf: home.config), let found = object(data), found["imported"] as? Bool != true {
            saved = found
        }
        if saved.isEmpty { saved["version"] = version }
        for (key, value) in changes { saved[key] = value }
        try FileManager.default.createDirectory(at: home.root, withIntermediateDirectories: true)
        let data = try JSONSerialization.data(withJSONObject: saved, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: home.config, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: home.config.path)
    }

    private static func object(_ data: Data) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }
}

/// A native Python 3.12 or later, for the engine.
public enum PythonFinder {
    public static let candidates = [
        "/opt/homebrew/bin/python3.14",
        "/opt/homebrew/bin/python3.13",
        "/opt/homebrew/bin/python3.12",
        "/Library/Frameworks/Python.framework/Versions/3.14/bin/python3",
        "/Library/Frameworks/Python.framework/Versions/3.13/bin/python3",
        "/Library/Frameworks/Python.framework/Versions/3.12/bin/python3",
        "/usr/local/bin/python3.14",
        "/usr/local/bin/python3.13",
        "/usr/local/bin/python3.12",
        "/opt/homebrew/bin/python3",
        "/usr/local/bin/python3",
    ]

    /// The first candidate that is 3.12 or later and runs natively.
    public static func find() async -> URL? {
        var candidates = candidates
        if let forced = ProcessInfo.processInfo.environment["CARTOUCHE_BUILDER_PYTHON"], !forced.isEmpty {
            candidates.insert(forced, at: 0)
        }
        for path in candidates where FileManager.default.isExecutableFile(atPath: path) {
            if await suits(path) { return URL(fileURLWithPath: path) }
        }
        return nil
    }

    /// Whether PATH is a Python 3.12 or later for this Mac's processor.
    public static func suits(_ path: String) async -> Bool {
        let check = "import platform, sys; print(int(sys.version_info >= (3, 12)), platform.machine())"
        guard let result = try? await Run.program(path, ["-c", check], timeout: 30), result.succeeded else { return false }
        let words = result.text.split(whereSeparator: \.isWhitespace).map(String.init)
        guard words.count == 2, words[0] == "1" else { return false }
        #if arch(arm64)
        return words[1] == "arm64"
        #else
        return true
        #endif
    }

    /// "3.13.9" of PATH, for the Mac's tools page.
    public static func version(_ path: String) async -> String? {
        guard let result = try? await Run.program(path, ["-c", "import platform; print(platform.python_version())"], timeout: 30), result.succeeded else {
            return nil
        }
        let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }
}

/// The engine's answers that are not a whole type of Models.swift.
public struct StatusAnswer: Decodable { public var status: BatchStatus? }
public struct StorageAnswer: Decodable { public var storage: StorageReport }
public struct CleanAnswer: Decodable { public var cleaned: Cleaned }
public struct FollowAnswer: Decodable { public var followed: Bool }
public struct MountAnswer: Decodable { public var folders: Folders }
public struct QueueAnswer: Decodable {
    /// For an add: false when no batch runs, and nothing was kept.
    public var queued: Bool?
    public var queue: BuildQueue
    public var running: Bool?
}

private struct Envelope: Decodable {
    var error: EngineFailure?
}

public final class Engine: @unchecked Sendable {
    /// The folder that holds cartouche_builder/.
    public let package: URL
    public let python: URL
    public let home: BuilderHome
    /// The engine's language, "fr" or "en": the app's.
    public var language: String

    public init(package: URL, python: URL, home: BuilderHome = .default, language: String = "") {
        self.package = package
        self.python = python
        self.home = home
        self.language = language
    }

    /// The engine in the app's Resources, or the one CARTOUCHE_BUILDER_ENGINE
    /// names (builder/ of the repository, while developing).
    public static func bundledPackage() -> URL? {
        var candidates: [URL] = []
        if let forced = ProcessInfo.processInfo.environment["CARTOUCHE_BUILDER_ENGINE"], !forced.isEmpty {
            candidates.append(URL(fileURLWithPath: (forced as NSString).expandingTildeInPath))
        }
        if let resources = Bundle.main.resourceURL {
            candidates.append(resources.appendingPathComponent("engine", isDirectory: true))
        }
        return candidates.first { FileManager.default.fileExists(atPath: $0.appendingPathComponent("cartouche_builder/__init__.py").path) }
    }

    /// What the engine runs with. It writes no compiled files: inside the
    /// app, they would break its signature.
    public var environment: [String: String] {
        var extra = [
            "PYTHONPATH": package.path,
            "PYTHONUNBUFFERED": "1",
            "PYTHONDONTWRITEBYTECODE": "1",
            "CARTOUCHE_BUILDER_APP": "1",
        ]
        if home != .default || ProcessInfo.processInfo.environment["CARTOUCHE_BUILDER_HOME"] != nil {
            extra["CARTOUCHE_BUILDER_HOME"] = home.root.path
        }
        if !language.isEmpty { extra["CARTOUCHE_BUILDER_LANG"] = language }
        var environment = Run.environment(extra)
        environment.removeValue(forKey: "PYTHONHOME")
        environment.removeValue(forKey: "VIRTUAL_ENV")
        return environment
    }

    /// Runs `api ARGUMENTS` and decodes its answer; LINE gets what it says
    /// along the way.
    public func api<T: Decodable>(_ type: T.Type, _ arguments: [String], timeout: TimeInterval = 1800,
                                  line: (@Sendable (String) -> Void)? = nil) async throws -> T {
        let result = try await Run.program(python.path, ["-m", "cartouche_builder", "api"] + arguments, environment: environment,
                                           directory: package, timeout: timeout, line: line)
        return try Engine.decode(type, from: result)
    }

    /// The answer of RESULT: the last line of its output that is a JSON object.
    static func decode<T: Decodable>(_ type: T.Type, from result: RunResult) throws -> T {
        let lines = result.output.split(separator: 10)
        guard let last = lines.last(where: { $0.first == UInt8(ascii: "{") }) else {
            let tail = result.tail()
            let exception = FailureDetails.exception(in: result.errorText) ?? FailureDetails.exception(in: result.text)
            throw EngineFailure(kind: result.timedOut ? "timeout" : "crashed", message: tail.isEmpty ? "exit \(result.status)" : tail,
                                details: FailureDetails(exception: exception), exit: Int(result.status))
        }
        let data = Data(last)
        if let envelope = try? JSONDecoder().decode(Envelope.self, from: data), let error = envelope.error {
            throw error
        }
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw EngineFailure(kind: "unreadable", message: String(describing: error))
        }
    }

    // MARK: The commands

    public func library(update: Bool) async throws -> Library {
        try await api(Library.self, update ? ["library", "--update"] : ["library"], timeout: 900)
    }

    public func storage() async throws -> StorageReport {
        try await api(StorageAnswer.self, ["storage"], timeout: 600).storage
    }

    public func clean(_ what: String, paths: [String] = []) async throws -> Cleaned {
        try await api(CleanAnswer.self, ["clean", what] + paths, timeout: 1800).cleaned
    }

    public func doctor() async throws -> Doctor {
        try await api(Doctor.self, ["doctor"], timeout: 300)
    }

    public func setup(line: (@Sendable (String) -> Void)? = nil) async throws -> Doctor {
        try await api(Doctor.self, ["setup"], timeout: 7200, line: line)
    }

    public func config() async throws -> ConfigAnswer {
        try await api(ConfigAnswer.self, ["config"], timeout: 120)
    }

    /// Changes the settings by the keys of CHANGES (the engine's names).
    public func setConfig(_ changes: [String: Any]) async throws -> ConfigAnswer {
        let data = try JSONSerialization.data(withJSONObject: changes, options: [.sortedKeys])
        return try await api(ConfigAnswer.self, ["config", "--set", String(decoding: data, as: UTF8.self)], timeout: 120)
    }

    public func follow(_ titleID: String, _ followed: Bool) async throws {
        _ = try await api(FollowAnswer.self, ["follow", titleID, followed ? "on" : "off"], timeout: 60)
    }

    public func mount() async throws -> Folders {
        try await api(MountAnswer.self, ["mount"], timeout: 300).folders
    }

    /// Adds GAMES to the batch running now, after its own, again even if up
    /// to date with FORCE. Its `queued` is false when no batch runs: nothing
    /// was kept, and a batch of their own builds them.
    public func enqueue(_ games: [String], force: Bool) async throws -> QueueAnswer {
        try await api(QueueAnswer.self, ["queue", "add"] + (force ? ["--force"] : []) + games, timeout: 120)
    }

    /// Takes GAMES out of the batch running now: one waiting is left out, the
    /// build of one building stops, and the batch goes on with the next.
    public func dequeue(_ games: [String]) async throws -> QueueAnswer {
        try await api(QueueAnswer.self, ["queue", "remove"] + games, timeout: 120)
    }

    // MARK: Batches

    /// Starts a batch that builds GAMES (all that are due when empty), again
    /// even if up to date with FORCE, kept awake by caffeinate. It goes on
    /// when the app quits; status.json says how it goes. While the engine's
    /// look at nxnative holds the batch lock, it waits for it first.
    @discardableResult
    public func startBatch(games: [String] = [], force: Bool = false) throws -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/caffeinate")
        var arguments = ["-i", python.path, "-m", "cartouche_builder", "build"]
        if force && !games.isEmpty { arguments.append("--force") }
        arguments += games
        process.arguments = arguments
        process.environment = environment
        process.currentDirectoryURL = package
        let manager = FileManager.default
        try manager.createDirectory(at: home.logs, withIntermediateDirectories: true)
        let log = home.logs.appendingPathComponent("app-batch.log")
        if !manager.fileExists(atPath: log.path) { manager.createFile(atPath: log.path, contents: nil) }
        let handle = try FileHandle(forWritingTo: log)
        _ = try handle.seekToEnd()
        process.standardOutput = handle
        process.standardError = handle
        process.standardInput = FileHandle.nullDevice
        try process.run()
        try? handle.close()
        return process
    }

    /// The batch running now, from status.json, or the last one.
    public static func readStatus(_ home: BuilderHome = .default) -> BatchStatus? {
        guard let data = try? Data(contentsOf: home.status), var status = try? JSONDecoder().decode(BatchStatus.self, from: data) else {
            return nil
        }
        if status.isRunning, let pid = status.pid, !alive(pid) {
            // Ended without saying so: stopped by force, or the Mac restarted.
            status.state = "stopped"
            status.running = false
        } else {
            status.running = status.isRunning
        }
        return status
    }

    /// The games asked for while a batch runs, from queue.json.
    public static func readQueue(_ home: BuilderHome = .default) -> BuildQueue {
        guard let data = try? Data(contentsOf: home.queue), let queue = try? JSONDecoder().decode(BuildQueue.self, from: data) else {
            return BuildQueue()
        }
        return queue
    }

    /// The library the engine last answered, shown at once while a new one comes.
    public static func cachedLibrary(_ home: BuilderHome = .default) -> Library? {
        guard let data = try? Data(contentsOf: home.library) else { return nil }
        return try? JSONDecoder().decode(Library.self, from: data)
    }

    /// Asks the running batch to stop after what it is doing: the engine
    /// takes SIGTERM as its Stop.
    public static func stopBatch(_ status: BatchStatus?) {
        guard let pid = status?.pid, pid > 1 else { return }
        kill(pid_t(pid), SIGTERM)
    }

    /// Stops a batch startBatch began that does not run yet, as it waits for
    /// the lock. caffeinate becomes the engine in the process startBatch
    /// started, keeping the Mac awake from a child of its own that ends with
    /// it: the engine takes SIGTERM as its Stop and ends without building
    /// (cli._build).
    public static func stopStarting(_ process: Process) {
        guard process.isRunning else { return }
        process.terminate()
    }

    public static func alive(_ pid: Int) -> Bool {
        guard pid > 0 else { return false }
        return kill(pid_t(pid), 0) == 0 || errno == EPERM
    }
}
