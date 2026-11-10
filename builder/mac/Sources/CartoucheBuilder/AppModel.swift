//
//  AppModel.swift
//  Cartouche Builder
//
//  What the window shows, and what its buttons do: the library and its
//  games, the batch running now (status.json, read every second while one
//  runs), the storage, the settings. The engine answers in the background;
//  the app checks nxnative every few hours and says when it improved a game.
//  It updates itself (Updater) and sends its measures (BuilderTelemetry):
//  what it built, how long it took and what failed, never a name or a path.
//

import AppKit
import BuilderKit
import ServiceManagement
import SwiftUI
import UserNotifications

enum AppSection: String, CaseIterable, Identifiable {
    case library, activity, storage, iphone, setup

    var id: String { rawValue }

    var title: String {
        switch self {
        case .library: return tr("Library", "Bibliothèque")
        case .activity: return tr("Builds", "Constructions")
        case .storage: return tr("Storage", "Stockage")
        case .iphone: return "iPhone"
        case .setup: return tr("This Mac’s tools", "Outils du Mac")
        }
    }

    var symbol: String {
        switch self {
        case .library: return "square.grid.2x2"
        case .activity: return "hammer"
        case .storage: return "internaldrive"
        case .iphone: return "iphone.radiowaves.left.and.right"
        case .setup: return "wrench.and.screwdriver"
        }
    }
}

/// The app's own settings, besides the engine's (config.json).
enum AppSettings {
    static let menuBarKey = "menuBar"
    static let bridgeKey = "bridge"
    static let savesKey = "savesFolder"
    static let notifiedKey = "notifiedDue"

    static var menuBar: Bool { UserDefaults.standard.object(forKey: menuBarKey) as? Bool ?? true }
}

struct Banner: Identifiable, Equatable {
    enum Kind { case info, error }
    let id = UUID()
    var kind: Kind
    var text: String
}

@MainActor
final class AppModel: ObservableObject {
    static let shared = AppModel()
    static let mainWindow = "main"
    static let guide = URL(string: "https://github.com/clabeuhtegrite/Cartouche/blob/main/builder/README.md")!
    /// How often nxnative is checked while the app runs.
    static let checkInterval: TimeInterval = 6 * 3600
    /// Opened by itself after an update, in the menu bar only.
    static let launchedQuietly = CommandLine.arguments.contains("--background")

    let home: BuilderHome
    let setup = MacSetup()
    let bridge: BridgeController
    let covers = CoverStore.shared
    let updater: Updater
    let telemetry: BuilderTelemetry
    let sample: Bool

    @Published var section: AppSection = .library
    @Published var selection: String?
    @Published var banner: Banner?
    @Published var showOnboarding = false
    @Published private(set) var engine: Engine?
    @Published private(set) var library: Library?
    @Published private(set) var status: BatchStatus?
    @Published private(set) var storage: StorageReport?
    @Published private(set) var config: BuilderConfig?
    @Published private(set) var info: BuilderInfo?
    @Published private(set) var checking = false
    @Published private(set) var loadingStorage = false
    @Published private(set) var cleaning = false
    /// A batch asked for, until status.json shows it.
    @Published private(set) var starting: Date?
    private var startingProcess: Process?

    private var started = false
    private var poller: Task<Void, Never>?
    private var checker: Task<Void, Never>?

    init(home: BuilderHome = .default, sample: Bool = false) {
        self.home = home
        self.sample = sample
        bridge = BridgeController(home: home, sample: sample)
        if sample {
            updater = Updater(app: URL(fileURLWithPath: "/Applications/Cartouche Builder.app"), version: "0.2.0", identifier: Updater.identifier,
                              folder: home.root.appendingPathComponent("Updates"), enabled: false)
            telemetry = BuilderTelemetry(file: nil, endpoint: nil, version: "0.2.0")
        } else {
            updater = Updater.forThisApp()
            telemetry = BuilderTelemetry(file: home.root.appendingPathComponent("telemetry.json"),
                                         endpoint: BuilderTelemetry.bundledEndpoint, version: updater.current)
        }
    }

    // MARK: Start

    func start() async {
        guard !started, !sample else { return }
        started = true
        library = Engine.cachedLibrary(home)
        status = Engine.readStatus(home)
        telemetry.language = L10n.code
        telemetry.start()
        setup.makeEngine = { [weak self] python in self?.makeEngine(python) }
        setup.onReady = { [weak self] in
            Task { await self?.toolsReady() }
        }
        setup.onStep = { [weak self] item, outcome, seconds in
            self?.telemetry.event("builder.setup", fields: ["item": .text(item.rawValue), "result": .text(outcome), "seconds": .number(seconds.rounded())])
        }
        startUpdates()
        poll()
        await setup.refresh()
        if engine == nil, let python = await PythonFinder.find() { _ = makeEngine(python) }
        await loadConfig()
        bridge.attach(model: self)
        let checked = library?.checked.flatMap(ISODate.parse)
        let stale = checked.map { Date().timeIntervalSince($0) > AppModel.checkInterval } ?? true
        await refreshLibrary(update: stale && setup.ready)
        showOnboarding = needsOnboarding
        checkRegularly()
        telemetry.event("builder.opened", fields: openedFields())
    }

    /// What the app says of this Mac and its setup as it opens: counts and
    /// yes or no, never a name or a path.
    /// At most 24 fields, as the server keeps (TelemetryEvent).
    private func openedFields() -> [String: TelemetryValue] {
        let games = library?.games ?? []
        var fields: [String: TelemetryValue] = [
            "memoryGB": .number((Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824).rounded()),
            "cores": .count(ProcessInfo.processInfo.activeProcessorCount),
            "ready": .flag(setup.ready),
            "missing": .count(setup.missingCount),
            "games": .count(games.count),
            "followed": .count(games.filter(\.followed).count),
            "due": .count(games.filter { $0.state == .due }.count),
            "failed": .count(games.filter { $0.state == .failed }.count),
            "ipaOnly": .count(games.filter { $0.state == .noSource }.count),
            "remote": .flag(library?.folders?.remote ?? false),
            "bridge": .flag(bridge.enabled),
            "paired": .count(bridge.devices.count),
            "menuBar": .flag(AppSettings.menuBar),
            "atLogin": .flag(opensAtLogin),
            "automaticUpdates": .flag(updater.automatic),
            "fromDiskImage": .flag(updater.runsFromDiskImage),
        ]
        if let xcode = setup.xcode, let info = NSDictionary(contentsOfFile: xcode + "/Contents/Info.plist"),
           let version = info["CFBundleShortVersionString"] as? String {
            fields["xcode"] = .text(version)
        }
        if let config {
            fields["schedule"] = .flag(config.schedule)
            fields["jobs"] = .count(config.jobs)
            fields["keepExtracted"] = .flag(config.keepExtracted)
            fields["policy"] = .text(config.enginePolicy)
            fields["forkOfNxnative"] = .flag(config.engineURL != BuilderConfig.engineURL || config.engineBranch != BuilderConfig.engineBranch)
            fields["gameLanguage"] = .text(config.gameLanguage.isEmpty ? "default" : config.gameLanguage)
        }
        if let engine = library?.engine {
            fields["nxnative"] = .text(String(engine.head.prefix(12)))
        }
        return fields
    }

    // MARK: Updates

    private func startUpdates() {
        updater.isBuilding = { [weak self] in self?.isBuilding ?? false }
        updater.isIdle = { [weak self] in self?.isIdle ?? false }
        updater.quit = { NSApp.terminate(nil) }
        updater.failed = { [weak self] error in self?.telemetry.error(error, origin: "update", background: true) }
        if updater.runsFromDiskImage {
            banner = Banner(kind: .info, text: Updater.moveFirst)
        }
        updater.start()
    }

    /// Nothing the player would see go: no build, no iPhone connected, no
    /// window open, the app in the background.
    var isIdle: Bool {
        guard !isBuilding, bridge.connected.isEmpty, bridge.request == nil, !NSApp.isActive else { return false }
        return !NSApp.windows.contains { $0.isVisible && $0.styleMask.contains(.titled) }
    }

    var needsOnboarding: Bool {
        guard let config else { return true }
        return config.sources.isEmpty || config.games.isEmpty
    }

    @discardableResult
    func makeEngine(_ python: URL) -> Engine? {
        if let engine, engine.python == python { return engine }
        guard let package = Engine.bundledPackage() else {
            banner = Banner(kind: .error, text: tr("The app is incomplete: its engine is missing. Download it again.",
                                                   "L’app est incomplète : son moteur manque. Téléchargez-la à nouveau."))
            return nil
        }
        let made = Engine(package: package, python: python, home: home, language: L10n.code)
        engine = made
        return made
    }

    /// Everything is installed: the library can be read and checked.
    private func toolsReady() async {
        if engine == nil {
            var python = setup.python
            if python == nil { python = await PythonFinder.find() }
            if let python { makeEngine(python) }
        }
        await loadConfig()
        await refreshLibrary(update: true)
    }

    // MARK: The engine's answers

    func loadConfig() async {
        guard !sample, let engine else { return }
        do {
            let answer = try await engine.config()
            apply(answer)
        } catch {
            show(error, origin: "config")
        }
    }

    private func apply(_ answer: ConfigAnswer) {
        let language = answer.config.language
        if language != L10n.chosen || config == nil {
            L10n.use(language)
            engine?.language = L10n.code
            telemetry.language = L10n.code
        }
        config = answer.config
        info = answer.builder
        bridge.update(games: answer.config.games)
    }

    func refreshLibrary(update: Bool) async {
        guard !sample, let engine else { return }
        if update {
            guard !checking else { return }
            checking = true
        }
        defer { if update { checking = false } }
        do {
            let fresh = try await engine.library(update: update)
            library = fresh
            if update { announceImproved(fresh) }
        } catch {
            show(error, origin: update ? "check" : "library", background: update)
        }
    }

    func loadStorage() async {
        guard !sample, let engine, !loadingStorage else { return }
        loadingStorage = true
        defer { loadingStorage = false }
        do {
            storage = try await engine.storage()
        } catch {
            show(error, origin: "storage")
        }
    }

    // MARK: Builds

    var isBuilding: Bool { status?.running == true || starting != nil }
    var canBuild: Bool { engine != nil && !isBuilding && setup.ready }

    /// Builds GAMES (what is due when empty), again with FORCE.
    func build(_ games: [String] = [], force: Bool = false) {
        guard !sample else { return }
        guard let engine else {
            section = .setup
            return
        }
        guard !isBuilding else {
            banner = Banner(kind: .info, text: tr("A build is already running.", "Une construction est déjà en cours."))
            return
        }
        do {
            startingProcess = try engine.startBatch(games: games, force: force)
            starting = Date()
        } catch {
            show(error, origin: "build")
        }
    }

    func stop() {
        Engine.stopBatch(status)
    }

    /// The progress of TITLE_ID in the batch running now.
    func progress(_ titleID: String) -> GameProgress? {
        guard status?.running == true else { return nil }
        return status?.games.first { $0.titleID == titleID && ($0.state == "building" || $0.state == "queued") }
    }

    private func poll() {
        poller?.cancel()
        poller = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                self.readStatus()
                let fast = self.isBuilding
                try? await Task.sleep(nanoseconds: fast ? 1_000_000_000 : 4_000_000_000)
            }
        }
    }

    private func readStatus() {
        let fresh = Engine.readStatus(home)
        let before = status
        if fresh != before { status = fresh }
        if let starting {
            if let fresh, fresh.running == true, (fresh.startedDate ?? .distantPast) >= starting.addingTimeInterval(-5) {
                self.starting = nil
            } else if let fresh, fresh.running == false, let ended = fresh.endedDate, ended >= starting.addingTimeInterval(-5) {
                self.starting = nil
                batchEnded(fresh)
            } else if startingProcess?.isRunning != true || Date().timeIntervalSince(starting) > 600 {
                // The batch ended, or never began, without a word in status.json.
                self.starting = nil
                startingProcess = nil
                banner = Banner(kind: .error, text: tr("The build did not start: ", "La construction n’a pas démarré : ") + lastLogLines())
                telemetry.event("builder.error", fields: ["origin": .text("build"), "kind": .text("not_started")])
            }
        }
        if before?.running == true, fresh?.running == false, let fresh {
            batchEnded(fresh)
        }
    }

    private func lastLogLines() -> String {
        let log = home.logs.appendingPathComponent("app-batch.log")
        guard let text = try? String(contentsOf: log, encoding: .utf8) else { return "" }
        return text.split(whereSeparator: \.isNewline).suffix(3).joined(separator: "\n")
    }

    private func batchEnded(_ status: BatchStatus) {
        let built = status.games.filter { $0.state == "built" }
        let failed = status.games.filter { $0.state == "failed" }
        report(status)
        if config?.notifications ?? true, !built.isEmpty || !failed.isEmpty {
            var lines: [String] = []
            if !built.isEmpty {
                lines.append(tr("Built: ", "Construits : ") + built.map(\.name).joined(separator: ", "))
            }
            if !failed.isEmpty {
                lines.append(tr("Failed: ", "Échecs : ") + failed.map(\.name).joined(separator: ", "))
            }
            let title = failed.isEmpty
                ? tr("Your games are ready", "Vos jeux sont prêts")
                : tr("Builds ended, with failures", "Constructions terminées, avec des échecs")
            notify(title: title, body: lines.joined(separator: "\n"), section: .activity)
        }
        Task {
            await refreshLibrary(update: false)
            if storage != nil { await loadStorage() }
        }
    }

    /// The batch and each game in it, for the telemetry: their states,
    /// steps, reasons and times, never a message, a name or a path.
    private func report(_ status: BatchStatus) {
        let head = status.head.map { String($0.prefix(12)) }
        for game in status.games where ["built", "failed"].contains(game.state) {
            var fields: [String: TelemetryValue] = [:]
            if let reasons = game.reasons, !reasons.isEmpty { fields["reasons"] = .text(reasons.joined(separator: ",")) }
            if let duration = game.duration { fields["seconds"] = .number(duration.rounded()) }
            if let kind = library?.game(game.titleID)?.kind { fields["source"] = .text(kind) }
            if let head { fields["nxnative"] = .text(head) }
            if game.state == "built" {
                if let size = library?.game(game.titleID)?.ipa?.size, size > 0 {
                    fields["ipaMB"] = .number((Double(size) / 1_000_000).rounded())
                }
                telemetry.event("builder.built", game: game.titleID, fields: fields)
            } else {
                fields["stage"] = .text(game.stage ?? "")
                telemetry.event("builder.failed", game: game.titleID, fields: fields)
            }
        }
        var fields: [String: TelemetryValue] = [
            "state": .text(status.state),
            "games": .count(status.games.count),
            "built": .count(status.games.filter { $0.state == "built" }.count),
            "failed": .count(status.games.filter { $0.state == "failed" }.count),
            "skipped": .count(status.games.filter { $0.state == "skipped" }.count),
            "stopped": .count(status.games.filter { $0.state == "stopped" }.count),
            "scheduled": .flag(status.scheduled ?? false),
            "jobs": .count(config?.jobs ?? 1),
        ]
        if let started = status.startedDate, let ended = status.endedDate {
            fields["minutes"] = .number((ended.timeIntervalSince(started) / 60 * 10).rounded() / 10)
        }
        if let head { fields["nxnative"] = .text(head) }
        telemetry.event("builder.batch", fields: fields)
    }

    // MARK: nxnative's improvements

    private func checkRegularly() {
        checker?.cancel()
        checker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(AppModel.checkInterval * 1_000_000_000))
                guard let self, !Task.isCancelled else { return }
                if !self.isBuilding, self.setup.ready { await self.refreshLibrary(update: true) }
            }
        }
    }

    /// Tells the player of the games nxnative improved since the last time.
    private func announceImproved(_ library: Library) {
        let due = library.due.filter { $0.reasons != ["new"] }
        let ids = Set(due.map(\.titleID))
        let told = Set(UserDefaults.standard.stringArray(forKey: AppSettings.notifiedKey) ?? [])
        UserDefaults.standard.set(Array(ids).sorted(), forKey: AppSettings.notifiedKey)
        let news = due.filter { !told.contains($0.titleID) }
        guard !news.isEmpty, config?.notifications ?? true else { return }
        let title = news.count == 1
            ? tr("nxnative improved \(news[0].name)", "nxnative a amélioré \(news[0].name)")
            : tr("nxnative improved \(news.count) of your games", "nxnative a amélioré \(news.count) de vos jeux")
        let body = news.count == 1
            ? tr("A rebuild is ready to start.", "Une reconstruction est prête à lancer.")
            : news.prefix(4).map(\.name).joined(separator: ", ") + (news.count > 4 ? "…" : "")
        notify(title: title, body: body, section: .library, game: news.count == 1 ? news[0].titleID : nil)
    }

    func notify(title: String, body: String, section: AppSection, game: String? = nil) {
        var info: [String: String] = ["section": section.rawValue]
        if let game { info["game"] = game }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { [info] granted, _ in
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            content.sound = .default
            content.userInfo = info
            UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
        }
    }

    // MARK: Settings

    /// Changes the engine's settings by EDIT, at once on the screen.
    func update(_ edit: (inout BuilderConfig) -> Void) {
        guard !sample, let before = config, let engine else { return }
        var changed = before
        edit(&changed)
        let changes = changed.changes(from: before)
        guard !changes.isEmpty else { return }
        config = changed
        if changes["language"] != nil {
            L10n.use(changed.language)
            engine.language = L10n.code
            telemetry.language = L10n.code
            objectWillChange.send()
        }
        Task {
            do {
                let answer = try await engine.setConfig(changes)
                apply(answer)
                let refolded = ["sources", "games", "keys", "workspace", "unprofiled", "skip", "aliases", "engine_policy", "refresh_days"]
                if changes.keys.contains(where: refolded.contains) {
                    await refreshLibrary(update: false)
                }
                if changes.keys.contains(where: ["sources", "games"].contains), showOnboarding == false, needsOnboarding == false {
                    banner = nil
                }
            } catch {
                config = before
                show(error, origin: "settings")
            }
        }
    }

    func follow(_ game: Game, _ followed: Bool) {
        guard !sample, let engine else { return }
        Task {
            do {
                try await engine.follow(game.titleID, followed)
                await loadConfig()
                await refreshLibrary(update: false)
            } catch {
                show(error, origin: "follow")
            }
        }
    }

    func clean(_ what: String, paths: [String] = []) {
        guard !sample, let engine, !cleaning else { return }
        cleaning = true
        Task {
            defer { cleaning = false }
            do {
                let cleaned = try await engine.clean(what, paths: paths)
                banner = Banner(kind: .info, text: tr("Freed \(Format.size(cleaned.freed)).", "\(Format.size(cleaned.freed)) libérés."))
                telemetry.event("builder.cleaned", fields: ["what": .text(what), "items": .count(max(paths.count, cleaned.removed.count)),
                                                            "freedMB": .number((Double(cleaned.freed) / 1_000_000).rounded())])
                await loadStorage()
                await refreshLibrary(update: false)
            } catch {
                show(error, origin: "clean")
            }
        }
    }

    func mountShares() {
        guard !sample, let engine else { return }
        Task {
            do {
                _ = try await engine.mount()
                await refreshLibrary(update: false)
            } catch {
                show(error, origin: "mount")
            }
        }
    }

    // MARK: Login item

    var opensAtLogin: Bool { SMAppService.mainApp.status == .enabled }

    func setOpensAtLogin(_ on: Bool) {
        do {
            if on {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            show(error, origin: "login")
        }
        objectWillChange.send()
    }

    // MARK: Helpers

    /// Shows ERROR above the page, and counts it by ORIGIN, what the app
    /// was doing, with its codes but never its words.
    func show(_ error: Error, origin: String, background: Bool = false) {
        let text = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        banner = Banner(kind: .error, text: text)
        telemetry.error(error, origin: origin, background: background)
    }

    func game(_ titleID: String?) -> Game? {
        guard let titleID else { return nil }
        return library?.game(titleID)
    }

    func showMainWindow() {
        NSApp.activate()
        if let window = NSApp.windows.first(where: { $0.identifier?.rawValue == AppModel.mainWindow || $0.title == "Cartouche Builder" }) {
            window.makeKeyAndOrderFront(nil)
        } else {
            NotificationCenter.default.post(name: .openMainWindow, object: nil)
        }
    }

    func reveal(_ path: String) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    func open(_ path: String) {
        NSWorkspace.shared.open(URL(fileURLWithPath: path))
    }

    // MARK: The gallery

    /// A model with sample games, for the gallery's pictures.
    static func sampled(library: Library, status: BatchStatus?, storage: StorageReport?, config: BuilderConfig, info: BuilderInfo?) -> AppModel {
        let home = BuilderHome(FileManager.default.temporaryDirectory.appendingPathComponent("cartouche-builder-gallery"))
        let model = AppModel(home: home, sample: true)
        model.library = library
        model.status = status
        model.storage = storage
        model.config = config
        model.info = info
        model.engine = Engine(package: home.root, python: URL(fileURLWithPath: "/opt/homebrew/bin/python3.13"), home: home, language: L10n.code)
        model.started = true
        return model
    }
}

extension Notification.Name {
    static let openMainWindow = Notification.Name("io.github.clabeuhtegrite.cartouche-builder.open")
}
