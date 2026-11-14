//
//  MacGames.swift
//  BuilderKit
//
//  The games played on this Mac: started from the builder (Play, or Game
//  settings, nxnative's own window first) or from anywhere else (the
//  Finder, the Dock, Launchpad), followed until they end, and their saves
//  kept in step with the iPhone's copies in the saves folder (MacSaves.swift):
//  the newest copy comes before a game the builder starts, the Mac's saves
//  go after every game, and while a game does not run, a round every
//  minute brings a copy that arrived, so that a start from the Dock finds
//  it too. A game whose saves nxnative's own cloud saves sync (a folder
//  the player chose in its settings window) is left to them: never two
//  syncs on one save.
//
//  A game is started through LaunchServices, as the Finder starts it: it
//  keeps its own permissions (Bluetooth, for its controllers) and its own
//  place in the Dock. Its launcher's process is followed until it ends;
//  how it ended is the last line its launcher wrote in its log
//  (MacPlay.swift).
//

import AppKit
import CartoucheCore
import Foundation

/// A game playing on this Mac.
public struct MacGameRun: Equatable, Sendable {
    public let app: MacGameApp
    /// The process followed: its launcher's, or another of the app's.
    public let pid: pid_t
    public let started: Date
    /// Started by the builder, else from the Finder, the Dock, Launchpad.
    public let fromBuilder: Bool
    /// Started with nxnative's settings window first.
    public let settings: Bool

    public init(app: MacGameApp, pid: pid_t, started: Date, fromBuilder: Bool, settings: Bool = false) {
        self.app = app
        self.pid = pid
        self.started = started
        self.fromBuilder = fromBuilder
        self.settings = settings
    }
}

/// What happened to the games of this Mac, for the app's words and its
/// measures.
public enum MacGamesNews {
    case started(MacGameRun)
    /// A game ended, after SECONDS, as its launcher said.
    case ended(MacGameRun, ending: MacGameEnding, exit: Int?, seconds: TimeInterval)
    /// A game's saves went or came, or could not: ON_SHARE, the saves
    /// folder is on a share.
    case saves(titleID: String, event: MacSaveEvent, onShare: Bool)
}

public enum MacPlayError: Error, Equatable {
    /// The game has no app on this Mac, or no longer.
    case noApp(String)
}

extension MacPlayError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .noApp:
            return tr("This game’s app is no longer on this Mac: build it for this Mac again.",
                      "L’app de ce jeu n’est plus sur ce Mac : construisez-le à nouveau pour ce Mac.")
        }
    }
}

@MainActor
public final class MacGames: ObservableObject {
    /// How often the saves of the games not playing are kept in step.
    public static let roundInterval: UInt64 = 60

    /// nxnative's folder of the games' logs, <title ID>.log.
    public nonisolated static var nxnativeLogs: URL {
        URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true).appendingPathComponent("Library/Logs/nxnative", isDirectory: true)
    }

    /// The games playing now, by title ID.
    @Published public private(set) var playing: [String: MacGameRun] = [:]
    /// The games whose saves come before the builder starts them.
    @Published public private(set) var preparing: Set<String> = []
    /// What each game's saves did last, by title ID.
    @Published public private(set) var last: [String: MacSaveEvent] = [:]
    /// The folder nxnative's own cloud saves go through, for each game
    /// whose player chose one, by title ID.
    @Published public private(set) var cloud: [String: String] = [:]
    /// The saves folder the Mac's saves are kept in step with, nil when
    /// they are not.
    @Published public private(set) var folder: MacSavesFolder?

    /// The games' apps on this Mac, by title ID.
    public private(set) var apps: [String: MacGameApp] = [:]
    public var news: ((MacGamesNews) -> Void)?
    /// The language of the prompts the games show: "fr", or English.
    public var language = "en"
    /// More environment for each start: the tests' own.
    public var environment: [String: String] = [:]
    public let store: MacSaveStore
    public let keeper: MacSaveKeeper
    /// nxnative's folder of the games' own (their saves) and of their logs.
    public let games: URL
    public let logs: URL
    private let scratch: URL
    private let preference: (String, String) -> String?
    private let sample: Bool
    private var watchers: [pid_t: any DispatchSourceProcess] = [:]
    private var observers: [any NSObjectProtocol] = []
    private var rounds: Task<Void, Never>?
    private var rounding = false

    /// STORE, the file of what the Mac knows of each game's saves; SCRATCH,
    /// a folder of the builder's for the copies that come.
    public init(store: URL, scratch: URL, games: URL = MacSavesFolder.nxnativeFolder, logs: URL = MacGames.nxnativeLogs,
                sample: Bool = false, preference: @escaping (String, String) -> String? = MacGames.preference) {
        self.store = MacSaveStore(url: store)
        keeper = MacSaveKeeper(store: self.store)
        self.scratch = scratch
        self.games = games
        self.logs = logs
        self.sample = sample
        self.preference = preference
    }

    /// A string of another app's preferences: KEY in DOMAIN, as the app
    /// last saved it.
    public nonisolated static func preference(_ key: String, _ domain: String) -> String? {
        CFPreferencesAppSynchronize(domain as CFString)
        return CFPreferencesCopyAppValue(key as CFString, domain as CFString) as? String
    }

    // MARK: What the builder tells

    /// The library's games that have an app on this Mac.
    public func use(apps list: [MacGameApp]) {
        var apps: [String: MacGameApp] = [:]
        for app in list { apps[app.titleID] = app }
        self.apps = apps
        var last: [String: MacSaveEvent] = [:]
        for titleID in apps.keys {
            if let event = store.record(titleID).last { last[titleID] = event }
        }
        if last != self.last { self.last = last }
        readCloud()
        noticeRunning()
    }

    /// The saves folder, ROOT, or none: the saves stay as they are.
    public func use(saves root: URL?) {
        guard let root else {
            if folder != nil { folder = nil }
            return
        }
        guard folder?.root != root.standardizedFileURL else { return }
        folder = MacSavesFolder(root: root, games: games, scratch: scratch)
    }

    /// Whether the builder keeps TITLE_ID's saves in step: a saves folder
    /// is chosen, and nxnative's own cloud saves do not sync them.
    public func keepsSaves(_ titleID: String) -> Bool {
        folder != nil && cloud[titleID.uppercased()] == nil
    }

    public func isPlaying(_ titleID: String) -> Bool {
        playing[titleID.uppercased()] != nil
    }

    // MARK: Following the games

    /// Follows the games started from anywhere, and keeps the saves of
    /// those that do not run in step, now and every minute.
    public func start() {
        guard !sample, observers.isEmpty else { return }
        let center = NSWorkspace.shared.notificationCenter
        observers.append(center.addObserver(forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.noticeRunning() }
        })
        noticeRunning()
        rounds = Task { [weak self] in
            while !Task.isCancelled, self != nil {
                await self?.round()
                try? await Task.sleep(nanoseconds: MacGames.roundInterval * 1_000_000_000)
            }
        }
    }

    public func stop() {
        observers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
        observers = []
        rounds?.cancel()
        rounds = nil
        watchers.values.forEach { $0.cancel() }
        watchers = [:]
    }

    /// A program running: its process, and its path as the kernel names it.
    typealias Program = (pid: pid_t, path: String)

    /// The processes of APP running now, by process number: those
    /// LaunchServices started from it, and those whose program is in it,
    /// its launcher and the game's host, which nxnative's launcher starts
    /// without LaunchServices. PROGRAMS: the programs running, listed once
    /// for every game of a round.
    private func pids(of app: MacGameApp, programs: [Program]? = nil) -> [pid_t] {
        let path = Self.realPath(app.url)
        let name = app.url.lastPathComponent
        var found = Set(NSWorkspace.shared.runningApplications.filter {
            !$0.isTerminated && $0.bundleURL?.lastPathComponent == name && $0.bundleURL.map(Self.realPath) == path
        }.map(\.processIdentifier))
        found.formUnion(Self.pids(inside: app, programs: programs ?? Self.runningPrograms()))
        // LaunchServices may not know yet that one ended.
        return found.filter { $0 > 0 && Self.alive($0) }.sorted()
    }

    /// Whether process PID runs; never for -1, which kill() takes for every
    /// process the builder may signal, nor 0, its own group.
    nonisolated static func alive(_ pid: pid_t) -> Bool {
        pid > 0 && (kill(pid, 0) == 0 || errno == EPERM)
    }

    /// The path of URL as the kernel names a program's: its links
    /// resolved, /private/var and not /var.
    nonisolated static func realPath(_ url: URL) -> String {
        guard let resolved = realpath(url.path, nil) else { return url.standardizedFileURL.path }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    /// The programs running now.
    nonisolated static func runningPrograms() -> [Program] {
        let count = proc_listallpids(nil, 0)
        guard count > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(count) + 64)
        let listed = pids.withUnsafeMutableBufferPointer { buffer in
            proc_listallpids(buffer.baseAddress, Int32(buffer.count * MemoryLayout<pid_t>.size))
        }
        guard listed > 0 else { return [] }
        var path = [UInt8](repeating: 0, count: Int(MAXPATHLEN) * 4)
        var programs: [Program] = []
        for pid in pids.prefix(Int(listed)) where pid > 0 {
            let length = proc_pidpath(pid, &path, UInt32(path.count))
            guard length > 0 else { continue }
            programs.append((pid, String(decoding: path.prefix(Int(length)), as: UTF8.self)))
        }
        return programs
    }

    /// The processes whose program is in APP, among PROGRAMS: its
    /// launcher's and its host's, however they were started.
    nonisolated static func pids(inside app: MacGameApp, programs: [Program]) -> [pid_t] {
        let folder = realPath(app.url) + "/Contents/MacOS/"
        return programs.filter { $0.path.hasPrefix(folder) }.map(\.pid)
    }

    /// Follows the games started from elsewhere: those running that the
    /// builder does not follow yet, but for one it is starting.
    private func noticeRunning() {
        guard !sample else { return }
        let waiting = apps.values.filter { playing[$0.titleID] == nil && !preparing.contains($0.titleID) }
        guard !waiting.isEmpty else { return }
        let programs = Self.runningPrograms()
        for app in waiting {
            followRunning(app, programs: programs)
        }
    }

    /// Follows APP's game when it runs already, started from elsewhere: the
    /// run followed, nil when it does not run.
    @discardableResult
    private func followRunning(_ app: MacGameApp, programs: [Program]? = nil) -> MacGameRun? {
        guard let pid = pids(of: app, programs: programs).first else { return nil }
        let started = NSRunningApplication(processIdentifier: pid)?.launchDate ?? Date()
        let run = MacGameRun(app: app, pid: pid, started: started, fromBuilder: false)
        follow(run)
        return run
    }

    private func follow(_ run: MacGameRun) {
        playing[run.app.titleID] = run
        news?(.started(run))
        watch(run)
    }

    /// Follows RUN's process until it ends. A game that ended as soon as it
    /// started has none to follow: LaunchServices says -1 of it.
    private func watch(_ run: MacGameRun) {
        let pid = run.pid
        guard pid > 0 else {
            ended(run)
            return
        }
        watchers.removeValue(forKey: pid)?.cancel()
        let source = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: .main)
        source.setEventHandler { [weak self] in
            Task { @MainActor in self?.exited(pid) }
        }
        watchers[pid] = source
        source.resume()
        // Gone before the watch began: nothing would say so.
        if !Self.alive(pid) {
            exited(pid)
        }
    }

    /// The process PID ended.
    private func exited(_ pid: pid_t) {
        watchers.removeValue(forKey: pid)?.cancel()
        guard let run = playing.values.first(where: { $0.pid == pid }) else { return }
        ended(run)
    }

    /// RUN's process ended: the game ended, unless another process of its
    /// app still runs.
    private func ended(_ run: MacGameRun) {
        let titleID = run.app.titleID
        if let other = pids(of: run.app).first(where: { $0 != run.pid }) {
            let next = MacGameRun(app: run.app, pid: other, started: run.started, fromBuilder: run.fromBuilder, settings: run.settings)
            playing[titleID] = next
            watch(next)
            return
        }
        playing.removeValue(forKey: titleID)
        let (ending, code) = MacGameEnding.read(log: logs.appendingPathComponent(titleID + ".log"), since: run.started)
        news?(.ended(run, ending: ending, exit: code, seconds: Date().timeIntervalSince(run.started)))
        // The saves it made go.
        if let folder, keepsSaves(titleID) {
            Task { await self.sync(run.app, in: folder, when: .after) }
        }
    }

    // MARK: Playing

    /// Starts TITLE_ID's game: its newest copy of saves first, when the
    /// builder keeps them; with nxnative's settings window first
    /// (SETTINGS), else straight into the game. A game playing already
    /// comes to the front.
    @discardableResult
    public func play(_ titleID: String, settings: Bool = false) async throws -> MacGameRun? {
        let titleID = titleID.uppercased()
        guard let app = apps[titleID] else { throw MacPlayError.noApp(titleID) }
        if let run = playing[titleID] {
            if let process = NSRunningApplication(processIdentifier: run.pid) {
                _ = process.activate(options: [])
            }
            return run
        }
        guard !sample, !preparing.contains(titleID) else { return nil }
        guard FileManager.default.fileExists(atPath: app.url.appendingPathComponent("Contents/Info.plist").path) else {
            throw MacPlayError.noApp(titleID)
        }
        // Started from the Dock a moment ago, not followed yet: that one plays.
        if let run = followRunning(app) { return run }
        preparing.insert(titleID)
        defer { preparing.remove(titleID) }
        readCloud()
        let keeps = keepsSaves(titleID)
        if let folder, keeps {
            await sync(app, in: folder, when: .before)
        }
        // Started meanwhile, from the Dock: that one plays.
        if let run = followRunning(app) { return run }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.arguments = MacPlayEnvironment.arguments(settings: settings)
        let own = games.standardizedFileURL.path == MacSavesFolder.nxnativeFolder.standardizedFileURL.path
        var environment = MacPlayEnvironment.make(app: app, keepsSaves: keeps, language: language,
                                                  documents: own ? nil : games.appendingPathComponent(titleID, isDirectory: true))
        environment.merge(self.environment) { _, extra in extra }
        configuration.environment = environment
        configuration.activates = true
        configuration.addsToRecentItems = false
        let started = Date()
        let pid: pid_t
        do {
            pid = try await NSWorkspace.shared.openApplication(at: app.url, configuration: configuration).processIdentifier
        } catch {
            // Started all the same, its launcher not saying to LaunchServices
            // that it finished launching: it plays.
            guard let running = pids(of: app).first else { throw error }
            pid = running
        }
        let run = MacGameRun(app: app, pid: pid, started: started, fromBuilder: true, settings: settings)
        follow(run)
        return run
    }

    // MARK: Saves

    /// Keeps the saves of the games not playing in step: a copy that
    /// arrived comes, saves made while the builder was closed go.
    public func round() async {
        guard !sample, !rounding else { return }
        // A game whose end nothing said, if any; one started from elsewhere.
        for run in Array(playing.values) where !Self.alive(run.pid) {
            exited(run.pid)
        }
        readCloud()
        noticeRunning()
        guard let folder else { return }
        rounding = true
        defer { rounding = false }
        let programs = Self.runningPrograms()
        for app in apps.values.sorted(by: { $0.titleID < $1.titleID }) where keepsSaves(app.titleID) {
            // Never under a game playing, or starting.
            guard playing[app.titleID] == nil, !preparing.contains(app.titleID), pids(of: app, programs: programs).isEmpty else { continue }
            await sync(app, in: folder, when: .round)
        }
    }

    private func sync(_ app: MacGameApp, in folder: MacSavesFolder, when: MacSaveMoment) async {
        // A copy takes the place of the saves only while no program of the
        // game runs, looked at again just before: one started from the Dock
        // meanwhile keeps the saves it found.
        let event = await keeper.sync(app.saveGame, in: folder, when: when, quiet: {
            MacGames.pids(inside: app, programs: MacGames.runningPrograms()).isEmpty
        })
        guard let event else { return }
        last[app.titleID] = event
        news?(.saves(titleID: app.titleID, event: event, onShare: folder.onShare))
    }

    /// The folders nxnative's own cloud saves go through, read again.
    private func readCloud() {
        var cloud: [String: String] = [:]
        for app in apps.values {
            if let found = MacCloudSaves.folder(of: app, documents: games.appendingPathComponent(app.titleID, isDirectory: true),
                                                preference: preference) {
                cloud[app.titleID] = found
            }
        }
        if cloud != self.cloud { self.cloud = cloud }
    }

    // MARK: The gallery

    /// Games playing, and what their saves did last, for the gallery's
    /// pictures.
    public func preview(folder root: URL?, playing: [MacGameRun] = [], last: [String: MacSaveEvent] = [:], cloud: [String: String] = [:]) {
        guard sample else { return }
        folder = root.map { MacSavesFolder(root: $0, games: games, scratch: scratch) }
        self.playing = Dictionary(uniqueKeysWithValues: playing.map { ($0.app.titleID, $0) })
        self.last = last
        self.cloud = cloud
    }

    /// The gallery's apps, without a look at the disk.
    public func preview(apps list: [MacGameApp]) {
        guard sample else { return }
        apps = Dictionary(uniqueKeysWithValues: list.map { ($0.titleID, $0) })
    }
}
