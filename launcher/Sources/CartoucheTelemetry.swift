//
//  CartoucheTelemetry.swift
//  Cartouche
//
//  Cartouche's telemetry, on unless the player turns it off on the System
//  page (docs/privacy.md). After each game session, Cartouche reads what
//  nxnative measured in the game's log (CartoucheGameLog.swift) and
//  reports it with the game, its build and settings, and this iPhone; it
//  reports its own events too: each start, installs, its updates, the
//  renewals of its signature and its errors. The reports wait in a queue
//  on the iPhone until the server has them (telemetry/README.md).
//
//  A session's log is read when Cartouche comes back after the game, when
//  it opens, and when a game it runs beside itself ends: nxnative renames
//  log.txt to log.prev.txt at the game's next start, so both are read,
//  each once, by when it was created. A log still being written, by a game
//  that runs, waits. A game that ran behind the console also wrote its
//  memory in the app group (CartoucheGameMemoryReading). Cartouche notes
//  each game it starts, behind the console or in its own place, and the
//  last reading of each game that ends behind the console; the session
//  whose log nxnative created while that game ran reports it: its
//  process's limit and exact peak, the sizes its screen took, and whether
//  the player quit it or iOS ended it (CartoucheTelemetryRuns).
//
//  The server's address is a build setting (CARTOUCHE_TELEMETRY_URL in
//  app/config.env, CartoucheTelemetryURL in the Info.plist): a build
//  without one keeps its reports on the iPhone and sends nothing.
//

import Combine
import Foundation
import UIKit

@available(iOS 17.0, *)
@MainActor
final class CartoucheTelemetry: ObservableObject {
    static let shared = CartoucheTelemetry()

    /// The server, or nil for a build that has none.
    static let endpoint: URL? = {
        guard let text = Bundle.main.object(forInfoDictionaryKey: "CartoucheTelemetryURL") as? String,
              let url = URL(string: text.trimmingCharacters(in: .whitespaces)), url.scheme == "https", url.host != nil else {
            return nil
        }
        return url
    }()

    /// Where the docs say what leaves the iPhone.
    static let privacyURL = URL(string: "https://github.com/clabeuhtegrite/Cartouche/blob/main/docs/privacy.md")!

    /// A copy of Cartouche takes a new random number after 13 months.
    static let installLifetime: TimeInterval = 395 * 86_400

    /// Posted as Cartouche starts a game, behind the console or in its own
    /// place (CartoucheRunningGame.swift).
    static let gameStarts = Notification.Name("CartoucheGameStarts")
    /// Posted by the game's end when Cartouche runs it beside itself
    /// (CartoucheRunningGame.swift).
    static let gameDidEnd = Notification.Name("CartoucheGameDidEnd")
    /// Posted with each error report Cartouche makes (CartoucheReporting.swift):
    /// userInfo["origin"] says what Cartouche was doing, userInfo["error"]
    /// is the error, userInfo["background"] whether Cartouche did it by itself.
    static let errorReported = Notification.Name("CartoucheErrorReported")

    /// What Cartouche keeps of its telemetry. A value an older Cartouche
    /// did not keep takes its default.
    private struct State: Codable {
        var isOn = true
        var install: String
        var installSince: Date
        var seq = 0
        var queue = CartoucheTelemetryQueue()
        var logs = CartoucheTelemetryLogs()
        var runs = CartoucheTelemetryRuns()
        var sent = 0
        var lastSent: Date?
        var lastReport: String?
        var lastVersion: String?
        var lastExpiration: Date?

        init() {
            install = CartoucheTelemetry.newNumber()
            installSince = Date()
        }

        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            isOn = try values.decodeIfPresent(Bool.self, forKey: .isOn) ?? true
            install = try values.decodeIfPresent(String.self, forKey: .install) ?? CartoucheTelemetry.newNumber()
            installSince = try values.decodeIfPresent(Date.self, forKey: .installSince) ?? Date()
            seq = try values.decodeIfPresent(Int.self, forKey: .seq) ?? 0
            queue = (try? values.decodeIfPresent(CartoucheTelemetryQueue.self, forKey: .queue)) ?? CartoucheTelemetryQueue()
            logs = (try? values.decodeIfPresent(CartoucheTelemetryLogs.self, forKey: .logs)) ?? CartoucheTelemetryLogs()
            runs = (try? values.decodeIfPresent(CartoucheTelemetryRuns.self, forKey: .runs)) ?? CartoucheTelemetryRuns()
            sent = try values.decodeIfPresent(Int.self, forKey: .sent) ?? 0
            lastSent = try values.decodeIfPresent(Date.self, forKey: .lastSent)
            lastReport = try values.decodeIfPresent(String.self, forKey: .lastReport)
            lastVersion = try values.decodeIfPresent(String.self, forKey: .lastVersion)
            lastExpiration = try values.decodeIfPresent(Date.self, forKey: .lastExpiration)
        }
    }

    @Published private(set) var isOn: Bool
    /// The last report made, as it is sent.
    @Published private(set) var lastReport: String?
    @Published private(set) var lastSent: Date?
    @Published private(set) var sent: Int
    @Published private(set) var waiting: Int
    @Published private(set) var isErasing = false

    private var state: State
    private let file: URL
    private var started = false
    private var collecting = false
    private var collectAgain = false
    private var sending = false
    /// The batch on its way, which the player's switch stops.
    private var sendingBatch: Task<Void, Never>?
    private var observers: Set<AnyCancellable> = []

    private init() {
        file = Self.file
        var state = (try? Data(contentsOf: file)).flatMap { try? JSONDecoder().decode(State.self, from: $0) } ?? State()
        if Date().timeIntervalSince(state.installSince) > Self.installLifetime {
            state.install = Self.newNumber()
            state.installSince = Date()
        }
        self.state = state
        isOn = state.isOn
        lastReport = state.lastReport
        lastSent = state.lastSent
        sent = state.sent
        waiting = state.queue.entries.count
    }

    // MARK: Start

    /// Starts reading the games' sessions and sending, once, as the console shows.
    func start() {
        guard !started else { return }
        started = true
        let center = NotificationCenter.default
        center.publisher(for: UIApplication.didBecomeActiveNotification)
            .sink { [weak self] _ in
                self?.noteChanges()
                self?.collect()
            }
            .store(in: &observers)
        // At once: a game that starts in Cartouche's place takes its process.
        center.publisher(for: Self.gameStarts)
            .sink { [weak self] note in self?.noteGameStart(note) }
            .store(in: &observers)
        center.publisher(for: Self.gameDidEnd)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] note in
                self?.noteGameEnd(note)
                self?.collect()
            }
            .store(in: &observers)
        center.publisher(for: Self.errorReported)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] note in self?.noteError(note) }
            .store(in: &observers)
        // LiveContainer lists the installed apps after the console shows:
        // its first list, or the list as it is a few seconds later, for a
        // player without games yet.
        let listed = DataManager.shared.model.$apps
            .filter { !$0.isEmpty }
            .map { _ in () }
            .merge(with: Just(()).delay(for: .seconds(5), scheduler: DispatchQueue.main))
            .first()
        listed
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.collect() }
            .store(in: &observers)
        // Whether the installation is ready waits, too, for the check of
        // LiveContainer's certificate, which ends a few seconds after the
        // launch: before it, no installation is ready yet. Half a minute at
        // most, after which the certificate says it is still being checked.
        let setup = CartoucheSetup.shared
        let checked = setup.$certificateWorks
            .combineLatest(setup.$hasCertificate)
            .filter { value in
                let (works, hasCertificate) = value
                return CartoucheSetupFacts.isChecked(hasCertificate: hasCertificate, certificateWorks: works)
            }
            .map { _ in () }
            .merge(with: Just(()).delay(for: .seconds(30), scheduler: DispatchQueue.main))
            .first()
        listed.zip(checked)
            // @Published sends a value before it sets it: read them after.
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.noteOpen(DataManager.shared.model.apps) }
            .store(in: &observers)
        CartoucheGameActions.shared.$installed
            .compactMap { $0 }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] app in self?.noteInstall(app) }
            .store(in: &observers)
        noteChanges()
        collect()
    }

    /// The player's switch. Off, the reports not sent yet are dropped; on
    /// again, only the sessions after it are reported.
    func setOn(_ on: Bool) {
        guard on != state.isOn else { return }
        state.isOn = on
        isOn = on
        if on {
            collect(reporting: false)
        } else {
            state.queue.removeAll()
            // Not even the batch on its way, made before the switch.
            sendingBatch?.cancel()
        }
        save()
    }

    /// Has the server delete every report of this copy of Cartouche, which
    /// then takes a new number. False if the server could not be reached.
    func erase() async -> Bool {
        guard !isErasing else { return false }
        isErasing = true
        defer { isErasing = false }
        if let endpoint = Self.endpoint {
            var request = URLRequest(url: endpoint.appendingPathComponent("v1/forget"))
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try? JSONSerialization.data(withJSONObject: ["install": state.install])
            request.timeoutInterval = 20
            let response = try? await Self.session.data(for: request).1
            guard let status = (response as? HTTPURLResponse)?.statusCode, (200..<300).contains(status) else {
                return false
            }
        }
        state.install = Self.newNumber()
        state.installSince = Date()
        state.queue.removeAll()
        state.sent = 0
        state.lastSent = nil
        state.lastReport = nil
        save()
        return true
    }

    /// Cartouche is being reset (CartoucheReset.swift): what the telemetry
    /// knew of the games goes with them. Its number, its switch and the
    /// reports not sent yet stay, and its file with them (decision 97).
    func forgetGames() {
        state.logs = CartoucheTelemetryLogs()
        state.runs = CartoucheTelemetryRuns()
        save()
    }

    // MARK: Sessions

    /// A log to read: where it is and what is known of its game.
    private struct Job: Sendable {
        let url: URL
        let key: String
        let session: String
        let bytes: Int
        let seconds: Double
        let game: String?
        let gameVersion: String?
        let nxnative: String?
        let nxnativeChanged: Bool?
        let settings: [String: String]
        /// What its process wrote, when the game ran behind the console, and
        /// whether its last reading was close to its limit.
        let process: CartoucheGameProcess?
        let nearLimit: Bool
    }

    /// Reads the sessions of the games' logs not read yet, then sends.
    /// Without REPORTING, only notes them as read.
    func collect(reporting: Bool = true) {
        guard collecting == false else {
            collectAgain = true
            return
        }
        guard state.isOn || !reporting else { return }
        let jobs = findLogs()
        guard !jobs.isEmpty else {
            send()
            return
        }
        guard reporting else {
            for job in jobs { state.logs.record(key: job.key, session: job.session, bytes: job.bytes) }
            save()
            return
        }
        collecting = true
        let limit = CartoucheMemoryReading.now()?.limitMiB
        Task {
            let measured = await Task.detached(priority: .utility) {
                jobs.map { job in
                    // A game behind the console had its process's own limit.
                    let measures = CartoucheGameLogReader.read(contentsOf: job.url)?
                        .measures(seconds: job.seconds, limitMiB: job.process?.limitMiB ?? limit)
                    return (job, job.process.flatMap { process in measures?.with(process, nearLimit: job.nearLimit) } ?? measures)
                }
            }.value
            for (job, measures) in measured {
                state.logs.record(key: job.key, session: job.session, bytes: job.bytes)
                guard let measures, state.isOn else { continue }
                let report = CartoucheSessionReport(
                    id: Self.newNumber(), session: job.session, seq: nextSeq(), context: context(limitMiB: limit),
                    game: job.game, gameVersion: job.gameVersion, nxnative: job.nxnative, nxnativeChanged: job.nxnativeChanged,
                    settings: job.settings, minutes: CartoucheGameLogReader.rounded(job.seconds / 60, 1), measures: measures,
                    process: job.process)
                enqueue(report, id: report.id)
            }
            save()
            collecting = false
            if collectAgain {
                collectAgain = false
                collect()
            } else {
                send()
            }
        }
    }

    /// The logs of the installed nxnative games that have a session to read.
    private func findLogs() -> [Job] {
        let model = DataManager.shared.model
        let catalog = CartoucheCatalog.shared
        let running = CartoucheGameActions.shared.running
        // What the last game behind the console wrote, for one Cartouche stopped with.
        let last = CartoucheGameMemoryReading.last().flatMap { reading -> CartoucheTelemetryRuns.Reading? in
            guard let started = reading.started, let updated = reading.updated,
                  let process = Self.process(of: reading, quit: nil) else { return nil }
            return .init(folder: reading.container, started: started, updated: updated, process: process,
                         nearLimit: reading.wasNearLimit)
        }
        var jobs: [Job] = []
        for app in model.apps + model.hiddenApps {
            guard let found = catalog.gameTitle(of: app) else { continue }
            let titleId = found.isEmpty ? catalog.titleId(matchingName: app.displayName) : found
            var details: (build: CartoucheGameBuild, settings: [String: String])?
            for container in app.uiContainers {
                let documents = container.containerURL.appendingPathComponent("Documents", isDirectory: true)
                // A running game is still writing log.txt, behind the console too.
                let isRunning = app.isAppRunning || (running?.app === app && running?.dataFolder == container.folderName)
                let names = isRunning ? ["log.prev.txt"] : ["log.prev.txt", "log.txt"]
                for name in names {
                    let url = documents.appendingPathComponent(name)
                    guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
                          let created = attributes[.creationDate] as? Date,
                          let modified = attributes[.modificationDate] as? Date,
                          let bytes = (attributes[.size] as? NSNumber)?.intValue, bytes > 0 else { continue }
                    let key = CartoucheTelemetryLogs.key(folder: container.folderName, created: created)
                    guard state.logs.needsReading(key: key, bytes: bytes) else { continue }
                    if details == nil {
                        details = (build: CartoucheInstalledBuilds.installedBuild(of: app),
                                   settings: CartoucheGameActions.shared.settings(for: app, tileKey: "").values)
                    }
                    let build = details?.build
                    let process = state.runs.process(folder: container.folderName, created: created, last: last)
                    jobs.append(Job(url: url, key: key, session: state.logs.session(of: key) ?? Self.newNumber(), bytes: bytes,
                                    seconds: max(modified.timeIntervalSince(created), 0), game: titleId,
                                    gameVersion: build?.version, nxnative: build?.shortCommit,
                                    nxnativeChanged: build?.commit == nil ? nil : build?.isDirty,
                                    settings: details?.settings ?? [:], process: process?.process,
                                    nearLimit: process?.nearLimit ?? false))
                }
            }
        }
        return jobs
    }

    /// What READING says of the game's process behind the console, QUIT
    /// whether the player quit the game; nil without its start.
    private static func process(of reading: CartoucheGameMemoryReading, quit: Bool?) -> CartoucheGameProcess? {
        guard let started = reading.started else { return nil }
        let screens = reading.sizes.map { size in
            CartoucheGameProcess.Screen(minute: CartoucheGameLogReader.rounded(max(size.time.timeIntervalSince(started), 0) / 60, 1),
                                        width: Int(size.width.rounded()), height: Int(size.height.rounded()),
                                        footprintMiB: size.footprintBytes > 0 ? Int(size.footprintBytes / 1_048_576) : nil)
        }
        return CartoucheGameProcess(limitMiB: reading.limitMiB, peakMiB: reading.peakMiB,
                                    lastAvailableMiB: Int(reading.availableBytes / 1_048_576), quit: quit, screens: screens)
    }

    /// A game starts, behind the console or in Cartouche's place: kept at
    /// once, as a game in Cartouche's place takes its process.
    private func noteGameStart(_ note: Notification) {
        guard let info = note.userInfo, let folder = info["dataFolder"] as? String, let started = info["started"] as? Date,
              let behind = info["behind"] as? Bool else { return }
        state.runs.start(folder: folder, at: started, behind: behind)
        save()
    }

    /// The game that ran behind the console ended: whether the player quit
    /// it, and the last reading its own process wrote, as the console took
    /// it when the game ended.
    private func noteGameEnd(_ note: Notification) {
        guard let info = note.userInfo, let folder = info["dataFolder"] as? String, let quit = info["quit"] as? Bool,
              let started = info["started"] as? Date else { return }
        let reading = (info["reading"] as? CartoucheGameMemoryReading).flatMap { $0.container == folder ? $0 : nil }
        state.runs.end(folder: folder, started: started, at: Date(),
                       process: reading.flatMap { Self.process(of: $0, quit: quit) }, nearLimit: reading?.wasNearLimit ?? false)
        save()
    }

    // MARK: Events

    /// Each start of Cartouche, with what it has.
    private func noteOpen(_ apps: [LCAppModel]) {
        let catalog = CartoucheCatalog.shared
        let games = apps.filter { catalog.gameTitle(of: $0) != nil }.count
        let setup = CartoucheSetup.shared
        var fields: [String: CartoucheTelemetryValue] = [
            "games": .number(Double(games)),
            "setUp": .flag(setup.isComplete),
            "storage": .text(CartoucheStorageSettings.shared.location(.games)?.server.kind.rawValue ?? "none"),
            "saves": .text(CartoucheStorageSettings.shared.location(.saves)?.server.kind.rawValue ?? "none"),
            // The player's own certificate, or the Apple ID's (docs/imported-signing.md).
            "signing": .text(CartoucheImportedSigning.isImportedInstall ? "imported" : "account"),
        ]
        // What it is made of: never the Apple ID, only whether there is one.
        fields.merge(setup.facts.fields) { _, made in made }
        if let days = CartoucheSignature.current().daysLeft {
            fields["signatureDays"] = .number(Double(days))
        }
        event("app.opened", fields: fields)
    }

    /// A new version of Cartouche, or a renewed signature, since last time.
    private func noteChanges() {
        let version = CartoucheUpdates.runningVersion
        if let last = state.lastVersion, last != version {
            event("app.updated", fields: ["from": .text(last), "to": .text(version)])
        }
        state.lastVersion = version
        let signature = CartoucheSignature.current()
        if let expiration = signature.expirationDate {
            if let last = state.lastExpiration, expiration > last.addingTimeInterval(3_600) {
                var fields: [String: CartoucheTelemetryValue] = [:]
                if let days = signature.daysLeft { fields["daysLeft"] = .number(Double(days)) }
                event("signature.renewed", fields: fields)
            }
            state.lastExpiration = expiration
        }
        save()
    }

    private func noteInstall(_ app: LCAppModel) {
        let catalog = CartoucheCatalog.shared
        guard let found = catalog.gameTitle(of: app) else { return }
        let build = CartoucheInstalledBuilds.installedBuild(of: app)
        var fields: [String: CartoucheTelemetryValue] = [:]
        if let version = build.version { fields["version"] = .text(version) }
        if let commit = build.shortCommit { fields["nxnative"] = .text(commit) }
        event("game.installed", game: found.isEmpty ? catalog.titleId(matchingName: app.displayName) : found, fields: fields)
    }

    /// An error Cartouche showed: what it was doing, the error's domain and
    /// code with those under it, and why it failed (CartoucheFailure): its
    /// cause, the step, how far it got and how long it took, the error's
    /// names and numbers. Never its words.
    private func noteError(_ note: Notification) {
        var fields: [String: CartoucheTelemetryValue] = [:]
        let failure = note.userInfo?["failure"] as? CartoucheFailure
        if let failure {
            fields = failure.fields
        }
        if let origin = note.userInfo?["origin"] as? String {
            fields["origin"] = .text(origin)
        }
        // The built-in SideStore's error comes back as its text alone: its
        // codes come with the failure.
        if let codes = failure?.codes {
            fields["error"] = .text(codes)
        } else if let error = note.userInfo?["error"] as? Error {
            fields["error"] = .text(Self.codes(of: error))
        }
        // What Cartouche checks by itself, such as the games folder at each
        // return, fails whenever the player is away from home.
        if let background = note.userInfo?["background"] as? Bool {
            fields["background"] = .flag(background)
        }
        event("error", fields: fields)
    }

    /// "NSCocoaErrorDomain 640 < NSPOSIXErrorDomain 28": an error and the
    /// ones under it.
    static func codes(of error: Error) -> String {
        var parts: [String] = []
        var current: NSError? = error as NSError
        while let found = current, parts.count < 4 {
            parts.append("\(found.domain) \(found.code)")
            current = found.userInfo[NSUnderlyingErrorKey] as? NSError
        }
        return parts.joined(separator: " < ")
    }

    /// Queues an event, if the player has telemetry on.
    func event(_ name: String, game: String? = nil, fields: [String: CartoucheTelemetryValue] = [:]) {
        guard state.isOn, let report = CartoucheEventReport(id: Self.newNumber(), seq: nextSeq(), context: context(),
                                                             name: name, game: game, fields: fields) else { return }
        enqueue(report, id: report.id)
        save()
        send()
    }

    // MARK: Sending

    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 20
        configuration.waitsForConnectivity = false
        return URLSession(configuration: configuration)
    }()

    /// Sends the queue, a batch at a time, while the server takes them.
    func send() {
        guard state.isOn, !sending, let endpoint = Self.endpoint else { return }
        state.queue.prune(now: Date())
        guard let batch = state.queue.batch(now: Date()) else { return }
        sending = true
        var request = URLRequest(url: endpoint.appendingPathComponent("v1/reports"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(CartoucheTelemetryFormat.batch(batch.map(\.body)).utf8)
        sendingBatch = Task {
            let ids = Set(batch.map(\.id))
            var again = false
            do {
                // The player may have turned it off since the batch was
                // made: it is dropped with the rest.
                try Task.checkCancellation()
                let (_, response) = try await Self.session.data(for: request)
                let http = response as? HTTPURLResponse
                switch http?.statusCode ?? 0 {
                case 200..<300:
                    state.queue.remove(ids)
                    state.sent += ids.count
                    state.lastSent = Date()
                    again = true
                case 400, 413, 422:
                    // Reports the server will never take: kept, they would
                    // hold back the others.
                    state.queue.remove(ids)
                    again = true
                default:
                    let wait = (http?.value(forHTTPHeaderField: "Retry-After")).flatMap { TimeInterval($0) }
                    state.queue.failed(now: Date(), serverWait: wait)
                }
            } catch {
                if Task.isCancelled {
                    // Stopped by the switch, it did not fail: what was made
                    // once it was on again goes now.
                    again = true
                } else {
                    state.queue.failed(now: Date())
                }
            }
            sending = false
            sendingBatch = nil
            save()
            if again, state.isOn { send() }
        }
    }

    // MARK: State

    private func context(limitMiB: Int? = nil) -> CartoucheTelemetryContext {
        CartoucheTelemetryContext(install: state.install, cartouche: CartoucheUpdates.runningVersion,
                                  device: CartoucheDevice.modelIdentifier, ios: CartoucheDevice.iOSVersion,
                                  language: CartoucheText.bundle.preferredLocalizations.first,
                                  memoryLimitMiB: limitMiB ?? CartoucheMemoryReading.now()?.limitMiB,
                                  increasedMemoryLimit: CartoucheDevice.hasIncreasedMemoryLimit)
    }

    private func nextSeq() -> Int {
        state.seq += 1
        return state.seq
    }

    private func enqueue<Report: Encodable>(_ report: Report, id: String) {
        guard let body = try? CartoucheTelemetryFormat.json(report) else { return }
        state.queue.add(CartoucheTelemetryQueue.Entry(id: id, created: Date(), body: body))
        state.lastReport = body
    }

    /// The file the telemetry keeps its state in, which a reset of
    /// Cartouche keeps (CartoucheResetPlan.telemetryFile).
    static var file: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Cartouche/Telemetry.json")
    }

    private func save() {
        isOn = state.isOn
        lastReport = state.lastReport
        lastSent = state.lastSent
        sent = state.sent
        waiting = state.queue.entries.count
        guard let data = try? JSONEncoder().encode(state) else { return }
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: file, options: .atomic)
    }

    nonisolated private static func newNumber() -> String {
        UUID().uuidString.lowercased()
    }
}
