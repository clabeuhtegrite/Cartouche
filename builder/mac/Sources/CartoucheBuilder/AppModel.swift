//
//  AppModel.swift
//  Cartouche Builder
//
//  What the window shows, and what its buttons do: the library and its
//  games, the batch running now (status.json, read every second while one
//  runs) and the games waiting their turn in it (queue.json: a game asked
//  for while a batch runs is built after its own), the storage, the
//  settings. The engine answers in the background;
//  the app checks nxnative every few hours and says when it improved a game.
//  It updates itself (Updater) and sends its measures (BuilderTelemetry):
//  what it built, how long it took and what failed, never a name or a path.
//  The games built for this Mac are played from it, their saves kept in
//  step with the iPhone's (MacGames).
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
    /// The saves of the games played on this Mac are kept in step with the
    /// iPhone's, in the saves folder.
    static let macSavesKey = "macSaves"

    static var menuBar: Bool { UserDefaults.standard.object(forKey: menuBarKey) as? Bool ?? true }
    static var macSaves: Bool { UserDefaults.standard.object(forKey: macSavesKey) as? Bool ?? true }
}

struct Banner: Identifiable, Equatable {
    enum Kind { case info, error }
    let id = UUID()
    var kind: Kind
    var text: String
}

@MainActor
final class AppModel: ObservableObject {
    static let shared: AppModel = LayoutCheck.requested ? LayoutCheck.model() : AppModel()
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
    /// The games played on this Mac, and their saves.
    let macGames: MacGames
    let sample: Bool

    @Published var section: AppSection = .library
    @Published var selection: String?
    @Published var banner: Banner?
    @Published var showSetup = false
    /// The step the setup assistant opens at.
    @Published var setupStep: SetupStep = .welcome
    @Published private(set) var engine: Engine?
    @Published private(set) var library: Library? {
        didSet { useMacApps() }
    }
    @Published private(set) var status: BatchStatus?
    /// The games asked for while a batch runs, not taken by it yet, and those
    /// taken out of it.
    @Published private(set) var queue = BuildQueue()
    /// Games being asked for, shown waiting until the engine answers.
    @Published private(set) var adding: Set<String> = []
    @Published private(set) var storage: StorageReport?
    @Published private(set) var config: BuilderConfig?
    @Published private(set) var info: BuilderInfo?
    @Published private(set) var checking = false
    /// The games no Mac built (Unbuilt.swift), by title ID: their sheet
    /// says so, and a build of one asks first (askUnbuilt).
    @Published var unbuilt: [String: UnbuiltGame] = [:]
    /// A build asked for that holds games no Mac built: it waits for the
    /// player's answer (ContentView).
    @Published var askUnbuilt: UnbuiltAsk?
    @Published private(set) var loadingStorage = false
    @Published private(set) var cleaning = false
    @Published private(set) var bundling = false
    @Published private(set) var bundleMessage = ""
    /// The game whose app the games folder keeps in one file (a NAS's) is
    /// being installed on this Mac, and how far it is, in the engine's words.
    @Published private(set) var installing: String?
    @Published private(set) var installMessage = ""
    /// A batch asked for, until status.json shows it: a few seconds, or as
    /// long as the engine's look at nxnative holds the batch lock, which the
    /// batch waits for (batch.LOCK_WAIT).
    @Published private(set) var starting: Date?
    /// The games that batch was asked for, waiting their turn in it meanwhile.
    @Published private(set) var startingGames: [String] = []
    private var startingProcess: Process?
    /// Where app-batch.log ended when the batch was asked for: what it says
    /// since is that batch's.
    private var startingLog: UInt64 = 0
    /// The games to ask the batch running for, one request after the other.
    private var toAsk: [(games: [String], force: Bool)] = []
    private var enqueueing = false

    private var started = false
    private var poller: Task<Void, Never>?
    private var checker: Task<Void, Never>?
    /// When the library is read again for the player's coming back.
    private var comebacks = ComebackReads()

    init(home: BuilderHome = .default, sample: Bool = false) {
        self.home = home
        self.sample = sample
        bridge = BridgeController(home: home, sample: sample)
        macGames = MacGames(store: home.macSaves, scratch: home.savesScratch, sample: sample)
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
        queue = Engine.readQueue(home)
        telemetry.language = L10n.code
        telemetry.start()
        setup.makeEngine = { [weak self] python in self?.makeEngine(python) }
        setup.onStep = { [weak self] item, outcome, seconds in
            self?.telemetry.event("builder.setup", fields: ["item": .text(item.rawValue), "result": .text(outcome), "seconds": .number(seconds.rounded())])
        }
        startUpdates()
        poll()
        await setup.refresh()
        // From now on: the tools found ready at this first look are no news,
        // and the library is checked below only if it was not for six hours.
        // A check holds the batch lock, which a build asked for meanwhile
        // waits for.
        setup.onReady = { [weak self] in
            Task { await self?.toolsReady() }
        }
        if engine == nil, let python = await PythonFinder.find() { _ = makeEngine(python) }
        await loadConfig()
        // At once, before the library: its first check fetches nxnative.
        showSetup = needsSetup
        bridge.attach(model: self)
        startMacGames()
        let checked = library?.checked.flatMap(ISODate.parse)
        let stale = checked.map { Date().timeIntervalSince($0) > AppModel.checkInterval } ?? true
        // This read is the one the app's coming to the front would ask for.
        comebacks.read()
        await refreshLibrary(update: stale && setup.ready)
        checkRegularly()
        telemetry.event("builder.opened", fields: openedFields())
        unbuilt = await UnbuiltGames.load(home)
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
        updater.isBuilding = { [weak self] in (self?.isBuilding ?? false) || (self?.bundling ?? false) }
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
        guard !isBuilding, !bundling, bridge.connected.isEmpty, bridge.request == nil, !NSApp.isActive,
              macGames.playing.isEmpty, macGames.preparing.isEmpty else { return false }
        return !NSApp.windows.contains { $0.isVisible && $0.styleMask.contains(.titled) }
    }

    /// The setup assistant opens by itself until it is gone through to its
    /// end (SetupAssistant.swift).
    var needsSetup: Bool { !(config?.setupDone ?? false) }

    /// The folder of the dumps or the games folder is not chosen yet.
    var foldersMissing: Bool { (config?.sources ?? "").isEmpty || (config?.games ?? "").isEmpty }

    /// Opens the setup assistant at STEP, over the window.
    func openSetup(at step: SetupStep = .welcome) {
        setupStep = step
        showSetup = true
    }

    /// The setup assistant's last step: it no longer opens by itself.
    func finishSetup() {
        update { $0.setupDone = true }
        showSetup = false
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
        guard !sample else { return }
        guard let engine else {
            // Python comes with the Mac's tools: until then, the settings as
            // they were saved, for the setup assistant to show and change.
            if config == nil { use(SettingsFile.read(home)) }
            return
        }
        do {
            let answer = try await engine.config()
            apply(answer)
        } catch {
            show(error, origin: "config")
        }
    }

    private func apply(_ answer: ConfigAnswer) {
        use(answer.config)
        info = answer.builder
    }

    private func use(_ fresh: BuilderConfig) {
        if fresh.language != L10n.chosen || config == nil {
            L10n.use(fresh.language)
            engine?.language = L10n.code
            telemetry.language = L10n.code
        }
        config = fresh
        bridge.update(games: fresh.games)
    }

    /// The library read again, with a look at nxnative (UPDATE). QUIETLY: a
    /// failure keeps the last library without a word, the next look saying
    /// why.
    func refreshLibrary(update: Bool, quietly: Bool = false) async {
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
            if !quietly { show(error, origin: update ? "check" : "library", background: update) }
        }
    }

    /// The player is back in the app, maybe from the Finder, where they put
    /// a game in their dumps or their games folder: the library reads the
    /// two folders again, without a look at nxnative, at most once in ten
    /// seconds (ComebackReads), and not while one is on its way.
    func playerCameBack() {
        guard started, !checking, comebacks.comeBack() else { return }
        Task { await refreshLibrary(update: false, quietly: true) }
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
    /// A game can be built, or added to the batch running or starting: not
    /// while an IPA is being imported.
    var canBuild: Bool { engine != nil && setup.ready && !bundling }

    /// A build asked for that holds games no Mac built (NEVER): the player
    /// builds them anyway, the OTHERS alone, or nothing.
    struct UnbuiltAsk: Identifiable {
        let id = UUID()
        /// As build() was asked: the games (what is due when empty), and FORCE.
        let games: [String]
        let force: Bool
        let never: [Game]
        let others: [String]

        var title: String {
            never.count == 1 ? tr("Build \(never[0].name) anyway?", "Construire \(never[0].name) quand même ?")
                : tr("Build these \(never.count) games anyway?", "Construire ces \(never.count) jeux quand même ?")
        }
    }

    /// Of GAMES (what is due when empty), those no Mac built that this one
    /// did not build either.
    func neverBuilt(_ games: [String]) -> [Game] {
        let asked = games.isEmpty ? dueOutsideBatch.map(\.titleID) : games
        return asked.compactMap { titleID in
            guard unbuilt[titleID] != nil, let game = library?.game(titleID), game.build == nil else { return nil }
            return game
        }
    }

    /// What the question says of each game no Mac built.
    func unbuiltMessage(_ ask: UnbuiltAsk) -> String {
        ask.never.map { game in
            let macs = unbuilt[game.titleID]?.macs ?? 0
            return tr("No Mac has built \(game.name) yet: its builds failed on \(macs) Macs in the last 4 weeks",
                      "Aucun Mac n’a encore construit \(game.name) : ses constructions ont échoué sur \(macs) Mac ces 4 dernières semaines")
                + (unbuilt[game.titleID]?.hours.map { tr(", after about \(UnbuiltGames.hoursText($0)) hours", ", après \(UnbuiltGames.hoursText($0)) h environ") } ?? "")
                + "."
        }.joined(separator: "\n")
    }

    /// Builds GAMES (what is due when empty), again with FORCE. While a batch
    /// runs, or starts, they wait their turn in it, built after its own games.
    /// Games no Mac built are asked about first, unless CONFIRMED.
    func build(_ games: [String] = [], force: Bool = false, confirmed: Bool = false) {
        guard !sample, !bundling else { return }
        guard engine != nil else {
            section = .setup
            return
        }
        if !confirmed {
            let never = neverBuilt(games)
            if !never.isEmpty {
                let asked = games.isEmpty ? dueOutsideBatch.map(\.titleID) : games
                let left = Set(never.map(\.titleID))
                askUnbuilt = UnbuiltAsk(games: games, force: force, never: never, others: asked.filter { !left.contains($0) })
                showMainWindow()
                return
            }
        }
        if status?.running == true || starting != nil || enqueueing {
            let wanted = games.isEmpty ? dueOutsideBatch.map(\.titleID) : games.filter { progress($0) == nil }
            if !wanted.isEmpty { enqueue(wanted, force: force && !games.isEmpty) }
            return
        }
        start(games, force: force)
    }

    private func start(_ games: [String], force: Bool) {
        guard let engine else { return }
        let log = home.logs.appendingPathComponent("app-batch.log")
        let logged = ((try? FileManager.default.attributesOfItem(atPath: log.path))?[.size] as? NSNumber)?.uint64Value ?? 0
        let asked = games.isEmpty ? dueOutsideBatch.map(\.titleID) : games
        do {
            startingProcess = try engine.startBatch(games: games, force: force)
            startingLog = logged
            startingGames = asked
            starting = Date()
        } catch {
            show(error, origin: "build")
        }
    }

    /// The batch asked for is no longer starting: it runs, it ended, or it
    /// never began.
    private func startingDone() {
        starting = nil
        startingProcess = nil
        startingGames = []
    }

    /// GAMES at the end of the batch running now, shown waiting at once.
    /// They are asked for one after the other: a batch that ends meanwhile
    /// leaves them a batch of their own, and one starting takes them once it
    /// runs.
    private func enqueue(_ games: [String], force: Bool) {
        adding.formUnion(games)
        toAsk.append((games, force))
        guard !enqueueing else { return }
        enqueueing = true
        Task {
            defer { enqueueing = false }
            while true {
                while starting != nil {
                    try? await Task.sleep(nanoseconds: 500_000_000)
                }
                // A batch stopped before it ran leaves nothing to ask for.
                guard !toAsk.isEmpty else { break }
                let (games, force) = toAsk.removeFirst()
                defer { adding.subtract(games) }
                guard let engine else { continue }
                do {
                    let answer = try await engine.enqueue(games, force: force)
                    queue = answer.queue
                    if answer.queued == false {
                        // No batch runs any more: one of their own, with the
                        // games asked for since.
                        let rest = toAsk
                        toAsk = []
                        rest.forEach { adding.subtract($0.games) }
                        start(games + rest.flatMap { $0.games }, force: force || rest.contains { $0.force })
                    } else {
                        telemetry.event("builder.queued", fields: ["games": .count(games.count), "forced": .flag(force)])
                    }
                } catch {
                    show(error, origin: "queue")
                }
            }
        }
    }

    /// Takes TITLE_ID out of the batch running now: waiting its turn, it is
    /// left out; building, its build stops and the batch goes on with the
    /// next game.
    func takeOut(_ titleID: String) {
        guard !sample, let engine, canTakeOut(titleID) else { return }
        let building = status?.current.contains(where: { $0.titleID == titleID }) ?? false
        Task {
            do {
                queue = try await engine.dequeue([titleID]).queue
                telemetry.event("builder.takenOut", fields: ["building": .flag(building)])
            } catch {
                show(error, origin: "queue")
            }
        }
    }

    /// Stops the build of TITLE_ID: the batch goes on with the next game, or
    /// stops when it has no other.
    func stopBuild(_ titleID: String) {
        let others = (status?.current.filter { $0.titleID != titleID }.count ?? 0) + waiting.count
        if others == 0 {
            stop()
        } else {
            takeOut(titleID)
        }
    }

    /// Stops the batch: the game building, and every game waiting its turn.
    /// A batch asked for that does not run yet, waiting for the lock, ends
    /// without starting. The process of a batch that ended is never sent
    /// anything: its number may be another's by now.
    func stop() {
        if status?.running == true {
            Engine.stopBatch(status)
        } else if starting != nil {
            if let startingProcess { Engine.stopStarting(startingProcess) }
            toAsk.forEach { adding.subtract($0.games) }
            toAsk = []
            startingDone()
        }
    }

    /// The progress of TITLE_ID in the batch running now: building, or
    /// waiting its turn, in the batch or asked for and not taken yet; or in
    /// the batch asked for, until it runs.
    func progress(_ titleID: String) -> GameProgress? {
        if let status, status.running == true {
            if let found = status.games.first(where: { $0.titleID == titleID && ($0.state == "building" || $0.state == "queued") }) {
                return found.state == "queued" && queue.stop.contains(titleID) ? nil : found
            }
            guard adding.contains(titleID) || queue.waiting(for: status.pid).contains(titleID) else { return nil }
        } else {
            guard starting != nil, startingGames.contains(titleID) || adding.contains(titleID) else { return nil }
        }
        return GameProgress(titleID: titleID, name: library?.game(titleID)?.name ?? titleID, state: "queued")
    }

    /// Whether Stop stops more than one game: those of the batch running, or
    /// of the batch asked for, until it runs.
    var stopsSeveral: Bool {
        let building = status?.running == true ? status?.current.count ?? 0 : 0
        return building + waiting.count > 1
    }

    /// Whether TITLE_ID can be taken out of the batch now: one runs, and the
    /// game was asked of it. Until the batch asked for runs, its games can
    /// only be stopped with it.
    func canTakeOut(_ titleID: String) -> Bool {
        status?.running == true && !adding.contains(titleID)
    }

    /// Whether TITLE_ID, building, was taken out of the batch: its build is
    /// stopping.
    func stopping(_ titleID: String) -> Bool {
        queue.stop.contains(titleID) && progress(titleID)?.state == "building"
    }

    /// The games waiting their turn in the batch running now, in the order
    /// they will be built: the batch's own, then those asked for. Until the
    /// batch asked for runs, the games it was asked for, then those since.
    var waiting: [GameProgress] {
        guard let status, status.running == true else {
            guard starting != nil else { return [] }
            var seen = Set<String>()
            return (startingGames + adding.sorted()).filter { seen.insert($0).inserted }.map {
                GameProgress(titleID: $0, name: library?.game($0)?.name ?? $0, state: "queued")
            }
        }
        var list = status.queued.filter { !queue.stop.contains($0.titleID) }
        var seen = Set(status.games.filter { $0.state == "building" || $0.state == "queued" }.map(\.titleID))
        for titleID in queue.waiting(for: status.pid) + adding.sorted() where !seen.contains(titleID) {
            seen.insert(titleID)
            list.append(GameProgress(titleID: titleID, name: library?.game(titleID)?.name ?? titleID, state: "queued"))
        }
        return list
    }

    /// The games due that the batch running now does not have.
    var dueOutsideBatch: [Game] {
        (library?.due ?? []).filter { progress($0.titleID) == nil }
    }

    /// The games asked for while the batch runs, for the gallery.
    func preview(queue: BuildQueue) {
        guard sample else { return }
        self.queue = queue
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
        let asked = Engine.readQueue(home)
        if asked != queue { queue = asked }
        if let starting {
            if let fresh, fresh.running == true, (fresh.startedDate ?? .distantPast) >= starting.addingTimeInterval(-5) {
                startingDone()
            } else if let fresh, fresh.running == false, let ended = fresh.endedDate, ended >= starting.addingTimeInterval(-5) {
                startingDone()
                batchEnded(fresh)
            } else if fresh?.running == true, let process = startingProcess, !process.isRunning, process.terminationStatus == 0 {
                // Another batch began first, the nightly one: the games asked
                // for went to its queue (cli._build).
                startingDone()
            } else if startingProcess?.isRunning != true || Date().timeIntervalSince(starting) > 600 {
                // The batch ended, or never began, without a word in status.json:
                // how long it was waited for, how the engine ended and the
                // exception its log ends on, never the log's words.
                var fields: [String: TelemetryValue] = ["origin": .text("build"), "kind": .text("not_started"),
                                                        "seconds": .number(Date().timeIntervalSince(starting).rounded())]
                if let process = startingProcess, !process.isRunning {
                    fields["exit"] = .count(Int(process.terminationStatus))
                    fields["signal"] = .flag(process.terminationReason == .uncaughtSignal)
                } else {
                    fields["running"] = .flag(startingProcess != nil)
                }
                if let exception = FailureDetails.exception(in: lastLogLines(80)) { fields["exception"] = .text(exception) }
                let said = lastLogLines()
                startingDone()
                banner = Banner(kind: .error, text: tr("The build did not start: ", "La construction n’a pas démarré : ") + said)
                telemetry.event("builder.error", fields: fields)
            }
        }
        if before?.running == true, fresh?.running == false, let fresh {
            batchEnded(fresh)
        } else if before?.running == true, let fresh, fresh.running == true {
            // A game of the batch ended: its sheet says so, as the batch goes on.
            let ended = Set(fresh.finished.map(\.titleID)).subtracting(before?.finished.map(\.titleID) ?? [])
            if !ended.isEmpty {
                Task { await refreshLibrary(update: false) }
            }
        }
    }

    /// The last lines the batch asked for wrote in app-batch.log: none of an
    /// earlier batch's.
    private func lastLogLines(_ count: Int = 3) -> String {
        let log = home.logs.appendingPathComponent("app-batch.log")
        guard let handle = try? FileHandle(forReadingFrom: log) else { return "" }
        defer { try? handle.close() }
        let end = (try? handle.seekToEnd()) ?? 0
        try? handle.seek(toOffset: startingLog <= end ? startingLog : 0)
        guard let data = try? handle.readToEnd() else { return "" }
        return String(decoding: data, as: UTF8.self).split(whereSeparator: \.isNewline).suffix(count).joined(separator: "\n")
    }

    private func batchEnded(_ status: BatchStatus) {
        let built = status.games.filter { $0.state == "built" }
        let failed = status.games.filter { $0.state == "failed" }
        // Built, but not for this Mac: its Mac app failed after its IPA.
        let macFailed = status.games.filter { $0.shownMacError != nil && $0.mac == "failed" }
        report(status)
        if config?.notifications ?? true, !built.isEmpty || !failed.isEmpty {
            var lines: [String] = []
            if !built.isEmpty {
                lines.append(tr("Built: ", "Construits : ") + built.map(\.name).joined(separator: ", "))
            }
            if !failed.isEmpty {
                lines.append(tr("Failed: ", "Échecs : ") + failed.map(\.name).joined(separator: ", "))
            }
            if !macFailed.isEmpty {
                lines.append(tr("Mac app failed: ", "App Mac en échec : ") + macFailed.map(\.name).joined(separator: ", "))
            }
            let title = failed.isEmpty && macFailed.isEmpty
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
    /// steps, reasons, causes and times, never a message, a name or a path
    /// (BuilderTelemetry.batchEvents).
    private func report(_ status: BatchStatus) {
        for event in BuilderTelemetry.batchEvents(status, library: library, jobs: config?.jobs ?? 1) {
            telemetry.event(event.name, game: event.game, fields: event.fields)
        }
    }

    // MARK: nxnative's improvements

    private func checkRegularly() {
        checker?.cancel()
        checker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(AppModel.checkInterval * 1_000_000_000))
                guard let self, !Task.isCancelled else { return }
                if !self.isBuilding, self.setup.ready { await self.refreshLibrary(update: true) }
                self.unbuilt = await UnbuiltGames.load(self.home)
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
        guard !sample, let before = config else { return }
        var changed = before
        edit(&changed)
        let changes = changed.changes(from: before)
        guard !changes.isEmpty else { return }
        config = changed
        if changes["language"] != nil {
            L10n.use(changed.language)
            engine?.language = L10n.code
            telemetry.language = L10n.code
            objectWillChange.send()
        }
        guard let engine else {
            // No engine yet: saved as the engine saves them, for it to read
            // when the Mac's tools bring its Python.
            do {
                try SettingsFile.write(changes, home)
                bridge.update(games: changed.games)
            } catch {
                config = before
                show(error, origin: "settings")
            }
            return
        }
        Task {
            do {
                let answer = try await engine.setConfig(changes)
                apply(answer)
                let refolded = ["sources", "games", "keys", "workspace", "unprofiled", "skip", "aliases", "engine_policy", "refresh_days",
                                "ios", "mac", "skip_ios", "skip_mac", "mac_apps"]
                if changes.keys.contains(where: refolded.contains) {
                    await refreshLibrary(update: false)
                }
                if changes.keys.contains(where: ["sources", "games"].contains), !showSetup, !foldersMissing {
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

    /// Builds GAME for PLATFORM ("ios", its IPA, or "mac", its app for this
    /// Mac) again, or no longer; what was built stays where it is.
    func setPlatform(_ game: Game, _ platform: String, _ on: Bool) {
        guard !sample, let engine else { return }
        Task {
            do {
                _ = try await engine.platform(game.titleID, platform, on)
                await loadConfig()
                await refreshLibrary(update: false)
                if storage != nil { await loadStorage() }
            } catch {
                show(error, origin: "platform")
            }
        }
    }

    /// Puts the game's Mac app in the Trash, never while the game runs from
    /// it, and builds the game no longer for this Mac (no longer at all,
    /// when it was built for this Mac alone): its saves stay on the Mac.
    /// This Mac's copy of an app the games folder keeps in one file (a
    /// NAS's) goes alone: the game stays built, its file where it is, and
    /// it is installed again the next time it is played.
    func removeMacApp(_ app: MacAppCopy) {
        guard !sample else { return }
        let url = URL(fileURLWithPath: app.path)
        if NSWorkspace.shared.runningApplications.contains(where: { $0.bundleURL?.standardizedFileURL == url.standardizedFileURL }) {
            banner = Banner(kind: .error, text: tr("Quit \(app.name) first: it is open on this Mac.", "Quittez d’abord \(app.name) : il est ouvert sur ce Mac."))
            return
        }
        Task {
            do {
                try FileManager.default.trashItem(at: url, resultingItemURL: nil)
            } catch {
                show(error, origin: "trash")
                return
            }
            telemetry.event("builder.cleaned", fields: ["what": .text(app.isInstalledCopy ? "mac_copy" : "mac_app"), "items": .count(1),
                                                        "freedMB": .number((Double(app.size) / 1_000_000).rounded())])
            if app.isInstalledCopy {
                banner = Banner(kind: .info, text: gamesOnShare
                    ? tr("\(app.name) is in the Trash. The NAS keeps its app: it is installed again when you play it.",
                         "\(app.name) est dans la Corbeille. Le NAS garde son app : elle se réinstalle quand vous y jouez.")
                    : tr("\(app.name) is in the Trash. The games folder keeps its app: it is installed again when you play it.",
                         "\(app.name) est dans la Corbeille. Le dossier des jeux garde son app : elle se réinstalle quand vous y jouez."))
                await loadStorage()
                await refreshLibrary(update: false)
                return
            }
            if let engine, config?.onMac(app.titleID) ?? app.on {
                do {
                    if config?.onIOS(app.titleID) ?? true {
                        _ = try await engine.platform(app.titleID, "mac", false)
                    } else {
                        try await engine.follow(app.titleID, false)
                    }
                } catch {
                    show(error, origin: "platform")
                }
            }
            banner = Banner(kind: .info, text: tr("\(app.name) is in the Trash.", "\(app.name) est dans la Corbeille."))
            await loadConfig()
            await loadStorage()
            await refreshLibrary(update: false)
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

    func bundleIPA(_ ipa: URL, image: URL) async throws -> String {
        guard let engine, !sample, !isBuilding, !bundling else {
            throw EngineFailure(kind: "busy", message: tr("Wait for the current operation to finish.", "Attendez la fin de l’opération en cours."))
        }
        bundling = true
        bundleMessage = tr("Checking the IPA and game data…", "Vérification de l’IPA et des fichiers du jeu…")
        defer { bundling = false }
        let started = Date()
        let answer: BundleIPAAnswer
        do {
            answer = try await engine.bundleROMFS(ipa: ipa, image: image) { [weak self] line in
                Task { @MainActor in self?.bundleMessage = line }
            }
        } catch {
            // The sheet shows its words; the measurements count it by its codes.
            telemetry.error(error, origin: "import")
            throw error
        }
        telemetry.event("builder.imported", game: answer.titleID, fields: importedFields(answer, seconds: Date().timeIntervalSince(started)))
        await refreshLibrary(update: false)
        return answer.ipa
    }

    /// An IPA imported with its game data, for the telemetry: never its
    /// name nor where it went.
    private func importedFields(_ answer: BundleIPAAnswer, seconds: TimeInterval) -> [String: TelemetryValue] {
        var fields: [String: TelemetryValue] = [
            "seconds": .number(seconds.rounded()),
            "remote": .flag(library?.folders?.remote ?? false),
        ]
        if let bytes = answer.bytes, bytes > 0 { fields["ipaMB"] = .number((Double(bytes) / 1_000_000).rounded()) }
        if let nxnative = answer.nxnative { fields["nxnative"] = .text(nxnative) }
        return fields
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

    // MARK: Playing on this Mac

    private func startMacGames() {
        macGames.news = { [weak self] news in self?.heard(news) }
        macGames.language = L10n.code
        useMacSaves()
        macGames.start()
    }

    /// The library's games that have an app on this Mac, as their
    /// Info.plist names them: their copies' folder is named after it.
    private func useMacApps() {
        let apps = (library?.games ?? []).compactMap { game -> MacGameApp? in
            guard let app = game.mac?.app, app.present else { return nil }
            let url = URL(fileURLWithPath: app.path)
            if sample { return MacGameApp(url: url, titleID: game.titleID, name: game.name) }
            return MacGameApp(url: url) ?? MacGameApp(url: url, titleID: game.titleID, name: game.name)
        }
        if sample {
            macGames.preview(apps: apps)
        } else {
            macGames.use(apps: apps)
        }
    }

    /// The saves folder of the bridge, the iPhone's, or none when the
    /// player turned the Mac's saves off.
    func useMacSaves() {
        guard !sample else { return }
        macGames.use(saves: AppSettings.macSaves ? bridge.saves : nil)
        Task { await macGames.round() }
    }

    func setMacSaves(_ on: Bool) {
        UserDefaults.standard.set(on, forKey: AppSettings.macSavesKey)
        useMacSaves()
        objectWillChange.send()
    }

    /// Starts GAME on this Mac: its newest copy of saves first; straight
    /// into the game, or with nxnative's own settings window (SETTINGS).
    /// An app the games folder keeps in one file (a NAS's) is installed on
    /// this Mac first, or its copy here made again of a newer build; when
    /// that cannot be done, the copy already here plays.
    func play(_ game: Game, settings: Bool = false) {
        guard !sample else { return }
        macGames.language = L10n.code
        Task {
            do {
                if let mac = game.mac, mac.needsInstall, !macGames.isPlaying(game.titleID) {
                    do {
                        try await installMac(game)
                    } catch {
                        guard mac.hasApp else { throw error }
                        show(error, origin: "install")
                        banner = Banner(kind: .error, text: tr("\(game.name) could not be updated on this Mac (\(DiskSpace.words(for: error))): the version already here starts.",
                                                               "\(game.name) n’a pas pu être mis à jour sur ce Mac (\(DiskSpace.words(for: error))) : la version déjà là démarre."))
                    }
                }
                try await macGames.play(game.titleID, settings: settings)
            } catch {
                show(error, origin: "play")
            }
        }
    }

    /// Whether GAME can be played on this Mac now: its app is here, or the
    /// games folder keeps it in one file, installed when played.
    func canPlay(_ game: Game) -> Bool {
        game.mac?.playable ?? false
    }

    /// Installs on this Mac GAME's app the games folder keeps in one file (a
    /// NAS's), or makes this Mac's copy of it again of the newest build; how
    /// far it is shows on the game (installMessage). One at a time.
    func installMac(_ game: Game) async throws {
        guard let engine, !sample else { return }
        guard installing == nil else {
            throw EngineFailure(kind: "busy", message: tr("Wait for the installation under way to finish.", "Attendez la fin de l’installation en cours."))
        }
        installing = game.titleID
        installMessage = tr("Installing \(game.name) on this Mac…", "Installation de \(game.name) sur ce Mac…")
        defer {
            installing = nil
            installMessage = ""
        }
        let titleID = game.titleID
        let again = game.mac?.hasApp ?? false
        let started = Date()
        let answer = try await engine.installMac(titleID) { [weak self] line in
            Task { @MainActor in
                if self?.installing == titleID { self?.installMessage = line }
            }
        }
        telemetry.event("builder.macInstalled", game: answer.titleID,
                        fields: BuilderTelemetry.installedFields(bytes: answer.bytes, seconds: Date().timeIntervalSince(started), again: again))
        await refreshLibrary(update: false)
        if storage != nil { await loadStorage() }
    }

    /// The game page's buttons: installs GAME's app, saying what went wrong.
    func installOnThisMac(_ game: Game) {
        guard !sample else { return }
        Task {
            do {
                try await installMac(game)
            } catch {
                show(error, origin: "install")
            }
        }
    }

    /// The games folder is on a network share: the player's words call it
    /// the NAS.
    var gamesOnShare: Bool { library?.folders?.games?.isShare ?? false }

    private func heard(_ news: MacGamesNews) {
        switch news {
        case .started:
            break
        case let .ended(run, ending: ending, exit: code, seconds: seconds):
            telemetry.event("builder.played", game: run.app.titleID,
                            fields: BuilderTelemetry.playedFields(ended: ending.rawValue, exit: code, seconds: seconds,
                                                                  fromBuilder: run.fromBuilder, settings: run.settings))
            if ending == .crashed {
                let log = "~/Library/Logs/nxnative/\(run.app.titleID).log"
                banner = Banner(kind: .error, text: tr("\(run.app.name) stopped unexpectedly. Its log: \(log)",
                                                       "\(run.app.name) s’est arrêté de façon inattendue. Son journal : \(log)"))
            }
        case let .saves(titleID: titleID, event: event, onShare: onShare):
            telemetry.event("builder.saves", game: titleID,
                            fields: BuilderTelemetry.savesFields(step: event.step, when: event.when.rawValue, onShare: onShare))
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
        // A full disk says which, and what is left on it, not Cocoa's words.
        banner = Banner(kind: .error, text: DiskSpace.words(for: error))
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
    static func sampled(library: Library, status: BatchStatus?, storage: StorageReport?, config: BuilderConfig, info: BuilderInfo?,
                        unbuilt: [String: UnbuiltGame] = [:]) -> AppModel {
        let home = BuilderHome(FileManager.default.temporaryDirectory.appendingPathComponent("cartouche-builder-gallery"))
        let model = AppModel(home: home, sample: true)
        model.library = library
        model.unbuilt = unbuilt
        model.status = status
        model.storage = storage
        model.config = config
        model.info = info
        model.engine = Engine(package: home.root, python: URL(fileURLWithPath: "/opt/homebrew/bin/python3.13"), home: home, language: L10n.code)
        model.started = true
        return model
    }

    /// nxnative being checked, or done, for the layout check.
    func preview(checking: Bool) {
        guard sample else { return }
        self.checking = checking
    }

    /// A batch asked for GAMES that does not run yet, waiting for the check
    /// of nxnative to end (CHECKING), or none, for the layout check.
    func preview(starting games: [String], checking: Bool) {
        guard sample else { return }
        startingGames = games
        starting = games.isEmpty ? nil : Date()
        self.checking = checking
    }
}

extension Notification.Name {
    static let openMainWindow = Notification.Name("io.github.clabeuhtegrite.cartouche-builder.open")
}
