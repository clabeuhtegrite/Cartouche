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
//  that runs, waits.
//
//  The server's address is a build setting (CARTOUCHE_TELEMETRY_URL in
//  app/config.env, CartoucheTelemetryURL in the Info.plist): a build
//  without one keeps its reports on the iPhone and sends nothing.
//

import Combine
import Foundation
import UIKit

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

    /// Posted by the game's end when Cartouche runs it beside itself.
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
    private var observers: Set<AnyCancellable> = []

    private init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        file = support.appendingPathComponent("Cartouche/Telemetry.json")
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
        center.publisher(for: Self.gameDidEnd)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.collect() }
            .store(in: &observers)
        center.publisher(for: Self.errorReported)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] note in self?.noteError(note) }
            .store(in: &observers)
        // LiveContainer lists the installed apps after the console shows:
        // its first list, or the list as it is a few seconds later, for a
        // player without games yet.
        DataManager.shared.model.$apps
            .filter { !$0.isEmpty }
            .map { _ in () }
            .merge(with: Just(()).delay(for: .seconds(5), scheduler: DispatchQueue.main))
            .first()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.noteOpen(DataManager.shared.model.apps)
                self?.collect()
            }
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
                    (job, CartoucheGameLogReader.read(contentsOf: job.url)?.measures(seconds: job.seconds, limitMiB: limit))
                }
            }.value
            for (job, measures) in measured {
                state.logs.record(key: job.key, session: job.session, bytes: job.bytes)
                guard let measures, state.isOn else { continue }
                let report = CartoucheSessionReport(
                    id: Self.newNumber(), session: job.session, seq: nextSeq(), context: context(limitMiB: limit),
                    game: job.game, gameVersion: job.gameVersion, nxnative: job.nxnative, nxnativeChanged: job.nxnativeChanged,
                    settings: job.settings, minutes: CartoucheGameLogReader.rounded(job.seconds / 60, 1), measures: measures)
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
        var jobs: [Job] = []
        for app in model.apps + model.hiddenApps {
            guard let found = catalog.gameTitle(of: app) else { continue }
            let titleId = found.isEmpty ? catalog.titleId(matchingName: app.displayName) : found
            var details: (build: CartoucheGameBuild, settings: [String: String])?
            for container in app.uiContainers {
                let documents = container.containerURL.appendingPathComponent("Documents", isDirectory: true)
                // A running game is still writing log.txt.
                let names = app.isAppRunning ? ["log.prev.txt"] : ["log.prev.txt", "log.txt"]
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
                    jobs.append(Job(url: url, key: key, session: state.logs.session(of: key) ?? Self.newNumber(), bytes: bytes,
                                    seconds: max(modified.timeIntervalSince(created), 0), game: titleId,
                                    gameVersion: build?.version, nxnative: build?.shortCommit,
                                    nxnativeChanged: build?.commit == nil ? nil : build?.isDirty,
                                    settings: details?.settings ?? [:]))
                }
            }
        }
        return jobs
    }

    // MARK: Events

    /// Each start of Cartouche, with what it has.
    private func noteOpen(_ apps: [LCAppModel]) {
        let catalog = CartoucheCatalog.shared
        let games = apps.filter { catalog.gameTitle(of: $0) != nil }.count
        var fields: [String: CartoucheTelemetryValue] = [
            "games": .number(Double(games)),
            "setUp": .flag(CartoucheSetup.shared.isComplete),
            "storage": .text(CartoucheStorageSettings.shared.location(.games)?.server.kind.rawValue ?? "none"),
            "saves": .text(CartoucheStorageSettings.shared.location(.saves)?.server.kind.rawValue ?? "none"),
        ]
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

    /// An error Cartouche showed: what it was doing, and the error's domain
    /// and code with those under it, never its words.
    private func noteError(_ note: Notification) {
        var fields: [String: CartoucheTelemetryValue] = [:]
        if let origin = note.userInfo?["origin"] as? String {
            fields["origin"] = .text(origin)
        }
        if let error = note.userInfo?["error"] as? Error {
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
        Task {
            let ids = Set(batch.map(\.id))
            var again = false
            do {
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
                state.queue.failed(now: Date())
            }
            sending = false
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
