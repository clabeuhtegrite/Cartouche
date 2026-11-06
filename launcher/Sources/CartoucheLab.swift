//
//  CartoucheLab.swift
//  Cartouche
//
//  The lab's rewrite of a game's modules on the iPhone (spike S2, step 2,
//  engine/spikes/s2/README.md). The player chooses a folder that holds their
//  game's modules, as the ExeFS folder of their dump has them, and the list
//  of the files that their Mac's build wrote from them (mac.sha256).
//  Cartouche copies the modules into a folder of its own, runs nxnative's
//  rewriter on them under the Python it carries (cartouche_s2.phone), with
//  its time and memory, and writes its report, its own list of files and the
//  rewriter's log into the chosen folder: at the end of the run, or when
//  Cartouche next opens if iOS closed it during the run.
//

import Foundation
import UIKit

/// status.json, which cartouche_s2.phone.run_job rewrites as it goes.
struct CartoucheLabStatus: Decodable {
    struct Game: Decodable {
        let id: String
        let name: String
    }

    struct Module: Decodable {
        let name: String
        let size: Int
        let state: String
        let began: Double?
        let seconds: Double?
        let restarts: Int?
    }

    struct File: Decodable {
        let name: String
        let sha256: String
        let size: Int
        /// "same", "different" or "absent" from the Mac's list; nil without one.
        let mac: String?
    }

    struct Summary: Decodable {
        let files: Int
        let same: Int?
        let different: Int?
        let absent: Int?
        let onlyOnMac: Int?
    }

    let state: String
    let started: Double
    let finished: Double?
    let python: String?
    let capstone: String?
    let nxnative: String?
    let game: Game?
    let modules: [Module]?
    let current: String?
    let files: [File]?
    let onlyOnMac: [String]?
    let summary: Summary?
    let error: String?

    var isActive: Bool { state == "starting" || state == "rewriting" }
}

/// Cartouche's memory while the lab runs, from what iOS reports for it.
struct CartoucheLabMemory: Equatable {
    var limitMiB: Int?
    var nowMiB: Int?
    var availableNowMiB: Int?
    var peakMiB: Int?
    var availableAtPeakMiB: Int?
    var peakByModule: [String: Int] = [:]
    /// Seconds from the start of the run to the last reading.
    var seconds: Double?
    /// Seconds without readings: iOS paused Cartouche in the background.
    var pausedSeconds: Double = 0

    /// How often the lab reads the memory, and the gap that means a pause.
    static let interval = 0.5
    static let pause = 3.0

    mutating func add(_ reading: CartoucheMemoryReading, module: String?, at seconds: Double) {
        if let last = self.seconds, seconds - last > Self.pause {
            pausedSeconds += seconds - last - Self.interval
        }
        self.seconds = seconds
        if limitMiB == nil { limitMiB = reading.limitMiB }
        nowMiB = reading.footprintMiB
        availableNowMiB = reading.availableMiB
        if reading.footprintMiB >= (peakMiB ?? 0) {
            peakMiB = reading.footprintMiB
            availableAtPeakMiB = reading.availableMiB
        }
        if let module {
            peakByModule[module] = max(peakByModule[module] ?? 0, reading.footprintMiB)
        }
    }
}

@MainActor
final class CartoucheLab: ObservableObject {
    static let shared = CartoucheLab()

    enum Phase: Equatable {
        case idle
        case copying(done: Int, total: Int)
        case starting
        case running
        case finished
        case failed(String)

        var isActive: Bool {
            switch self {
            case .copying, .starting, .running: return true
            default: return false
            }
        }
    }

    /// A folder the player chose, and the modules found in it.
    struct Folder: Equatable {
        struct Module: Equatable {
            let name: String   // main, subsdk0...
            let file: URL
        }

        let url: URL
        let modules: [Module]
        /// The Mac's list of the files its build wrote, mac.sha256.
        let reference: URL?
    }

    @Published private(set) var folder: Folder?
    @Published private(set) var folderName: String?
    @Published private(set) var folderError: String?
    @Published private(set) var phase: Phase = .idle
    @Published private(set) var status: CartoucheLabStatus?
    @Published private(set) var memory = CartoucheLabMemory()
    /// Whether the report reached the chosen folder; nil before a report.
    @Published private(set) var reportExported: Bool?
    /// The last run stopped without finishing: iOS closed Cartouche.
    @Published private(set) var interrupted = false

    /// The modules of a program, in load order, as nxnative rewrites them.
    nonisolated static let moduleNames = ["main"] + (0..<10).map { "subsdk\($0)" } + ["sdk"]
    nonisolated static let referenceName = "mac.sha256"
    nonisolated static let ownListName = "iphone.sha256"
    nonisolated static let reportName = "iphone-report.txt"
    /// The rewriter's log (rewrite.log of the run), by its name in the chosen folder.
    nonisolated static let logName = "iphone-rewrite.log"
    /// What Python wrote when the lab's code itself stopped it.
    nonisolated private static let pythonErrorName = "python-error.txt"
    private static let bookmarkKey = "CartoucheLabFolder"

    /// The last run's files: Documents/Cartouche/Lab/S2.
    static var runFolder: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Cartouche/Lab/S2", isDirectory: true)
    }

    private init() {
        restoreFolder()
        loadLastRun()
    }

    // MARK: The folder

    /// The folder the player picked (fileImporter, with access to it).
    func choose(_ url: URL) {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        if let bookmark = try? url.bookmarkData() {
            UserDefaults.standard.set(bookmark, forKey: Self.bookmarkKey)
        }
        scan(url)
    }

    func rescan() {
        guard let url = folder?.url ?? resolveBookmark() else { return }
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        scan(url)
    }

    private func restoreFolder() {
        guard let url = resolveBookmark() else { return }
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        scan(url)
    }

    private func resolveBookmark() -> URL? {
        guard let data = UserDefaults.standard.data(forKey: Self.bookmarkKey) else { return nil }
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: data, bookmarkDataIsStale: &stale) else { return nil }
        if stale, let fresh = try? url.bookmarkData() {
            UserDefaults.standard.set(fresh, forKey: Self.bookmarkKey)
        }
        return url
    }

    /// Finds the modules in the folder or in its ExeFS folder, and the Mac's
    /// list in either. A file iCloud has not downloaded yet may be listed as
    /// .<name>.icloud; reading it later downloads it.
    private func scan(_ url: URL) {
        folderName = url.lastPathComponent
        let exefs = url.appendingPathComponent("ExeFS", isDirectory: true)
        for candidate in [exefs, url] {
            let names = Self.names(in: candidate)
            let modules = Self.moduleNames.compactMap { name -> Folder.Module? in
                if names.contains(name) { return Folder.Module(name: name, file: candidate.appendingPathComponent(name)) }
                if names.contains(name + ".nso") { return Folder.Module(name: name, file: candidate.appendingPathComponent(name + ".nso")) }
                return nil
            }
            guard modules.contains(where: { $0.name == "main" }) else { continue }
            let reference = [url, candidate]
                .first { Self.names(in: $0).contains(Self.referenceName) }
                .map { $0.appendingPathComponent(Self.referenceName) }
            folder = Folder(url: url, modules: modules, reference: reference)
            folderError = nil
            return
        }
        folder = nil
        folderError = CartoucheText.labNoModules
    }

    /// The names of the files in a folder, those iCloud has not downloaded included.
    nonisolated private static func names(in folder: URL) -> Set<String> {
        Set(((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).map(plainName))
    }

    nonisolated static func plainName(_ name: String) -> String {
        if name.hasPrefix("."), name.hasSuffix(".icloud") {
            return String(name.dropFirst().dropLast(".icloud".count))
        }
        return name
    }

    // MARK: A run

    func run() {
        guard let folder, !phase.isActive else { return }
        Task { await perform(folder) }
    }

    private func perform(_ folder: Folder) async {
        UIApplication.shared.isIdleTimerDisabled = true
        let activity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .idleSystemSleepDisabled], reason: "Cartouche lab: rewriting a game's modules")
        defer {
            UIApplication.shared.isIdleTimerDisabled = false
            ProcessInfo.processInfo.endActivity(activity)
        }
        status = nil
        reportExported = nil
        interrupted = false
        memory = CartoucheLabMemory()
        let run = Self.runFolder
        let input = run.appendingPathComponent("input", isDirectory: true)
        let pythonError = run.appendingPathComponent(Self.pythonErrorName)
        do {
            phase = .copying(done: 0, total: folder.modules.count)
            try await Self.background {
                try? FileManager.default.removeItem(at: run)
                try FileManager.default.createDirectory(at: input, withIntermediateDirectories: true)
            }
            for (index, module) in folder.modules.enumerated() {
                try await Self.copy(module.file, to: input.appendingPathComponent(module.name), within: folder.url)
                phase = .copying(done: index + 1, total: folder.modules.count)
            }
            var job: [String: Any] = [
                "tools": CartouchePython.home.appendingPathComponent("app/dm/tools", isDirectory: true).path,
                "modules": input.path,
                "work": run.path,
                "out": run.appendingPathComponent("out", isDirectory: true).path,
                // Capstone's binding finds its library in the app's Frameworks.
                "env": ["LIBCAPSTONE_PATH": CartouchePython.frameworks.path],
            ]
            if let mac = folder.reference {
                let reference = input.appendingPathComponent(Self.referenceName)
                try await Self.copy(mac, to: reference, within: folder.url)
                job["reference"] = reference.path
            }
            let jobFile = run.appendingPathComponent("job.json")
            try JSONSerialization.data(withJSONObject: job, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
                .write(to: jobFile)
            let source = try Self.source(job: jobFile, failure: pythonError)
            // Python writes its own status as it starts the job. Until then, this one
            // shows at the next start that a run ended Cartouche while Python started.
            let starting: [String: Any] = ["state": "starting", "started": Date().timeIntervalSince1970]
            try JSONSerialization.data(withJSONObject: starting).write(to: run.appendingPathComponent("status.json"))

            phase = .starting
            let sampler = Task { await self.sample(run) }
            let result: Int32
            do {
                result = try await CartouchePython.shared.run(source)
            } catch {
                sampler.cancel()
                throw error
            }
            sampler.cancel()
            readStatus(run)
            if let stop = Self.lastLine(of: pythonError) {
                phase = .failed(CartoucheText.labPythonError(stop))
            } else if result != 0 || status == nil {
                phase = .failed(CartoucheText.labStopped)
            } else if status?.state == "done" {
                phase = .finished
            } else {
                phase = .failed(status?.error ?? CartoucheText.labStopped)
            }
        } catch {
            phase = .failed(error.localizedDescription)
        }

        reportExported = await writeReport(folder, interrupted: false)
        // The copies of the modules; the rewritten ones stay until the next run.
        try? FileManager.default.removeItem(at: input)
    }

    /// The Python source that runs a job. A failure of the lab's own code,
    /// before run_job can record it in status.json, is written to `failure`
    /// and goes no further: an uncaught SystemExit would end Cartouche.
    nonisolated private static func source(job: URL, failure: URL) throws -> String {
        // A JSON list of strings reads as the same list in Python.
        let list = try JSONSerialization.data(withJSONObject: [job.path, failure.path], options: [.withoutEscapingSlashes])
        let paths = String(decoding: list, as: UTF8.self)
        return """
            import traceback
            job, failure = \(paths)
            try:
                import cartouche_s2.phone
                cartouche_s2.phone.run_job(job)
            except BaseException:
                with open(failure, "w", encoding="utf-8") as stream:
                    traceback.print_exc(file=stream)

            """
    }

    /// Reads status.json and Cartouche's memory twice a second, and keeps the
    /// memory readings in memory.tsv, which outlasts Cartouche if iOS closes it.
    private func sample(_ run: URL) async {
        let samples = run.appendingPathComponent("memory.tsv")
        FileManager.default.createFile(atPath: samples.path, contents: Data("seconds\tfootprint_mib\tavailable_mib\tmodule\n".utf8))
        let handle = try? FileHandle(forWritingTo: samples)
        defer { try? handle?.close() }
        _ = try? handle?.seekToEnd()
        let start = Date()
        while !Task.isCancelled {
            readStatus(run)
            if phase == .starting, status?.state == "rewriting" {
                phase = .running
            }
            if let reading = CartoucheMemoryReading.now() {
                let seconds = Date().timeIntervalSince(start)
                memory.add(reading, module: status?.current, at: seconds)
                let line = String(format: "%.1f", seconds) + "\t\(reading.footprintMiB)\t\(reading.availableMiB)\t\(status?.current ?? "-")\n"
                try? handle?.write(contentsOf: Data(line.utf8))
            }
            try? await Task.sleep(nanoseconds: UInt64(CartoucheLabMemory.interval * 1_000_000_000))
        }
    }

    private func readStatus(_ run: URL) {
        guard let data = try? Data(contentsOf: run.appendingPathComponent("status.json")) else { return }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        if let decoded = try? decoder.decode(CartoucheLabStatus.self, from: data) {
            status = decoded
        }
    }

    /// The last run, as it was left. A run that iOS stopped still says it was
    /// rewriting, and its memory readings say how far it got: its report is
    /// written now, once.
    private func loadLastRun() {
        let run = Self.runFolder
        readStatus(run)
        guard let status else { return }
        if let data = try? Data(contentsOf: run.appendingPathComponent("memory.tsv")) {
            for line in String(decoding: data, as: UTF8.self).split(separator: "\n").dropFirst() {
                let columns = line.split(separator: "\t")
                guard columns.count >= 3, let seconds = Double(columns[0]),
                      let footprint = UInt64(columns[1]), let available = UInt64(columns[2]) else { continue }
                let module = columns.count > 3 && columns[3] != "-" ? String(columns[3]) : nil
                memory.add(CartoucheMemoryReading(footprintBytes: footprint << 20, availableBytes: available << 20),
                           module: module, at: seconds)
            }
        }
        // A run that reached its end wrote its report; one that iOS stopped did
        // not, and gets it now, once.
        let reported = FileManager.default.fileExists(atPath: run.appendingPathComponent(Self.reportName).path)
        let marker = run.appendingPathComponent("interrupted")
        if status.isActive, !reported || FileManager.default.fileExists(atPath: marker.path) {
            interrupted = true
            if !reported, let folder {
                FileManager.default.createFile(atPath: marker.path, contents: nil)
                Task { reportExported = await writeReport(folder, interrupted: true) }
            }
        } else if status.state == "done" {
            phase = .finished
        } else if let stop = Self.lastLine(of: run.appendingPathComponent(Self.pythonErrorName)) {
            phase = .failed(CartoucheText.labPythonError(stop))
        } else {
            phase = .failed(status.error ?? CartoucheText.labStopped)
        }
    }

    // MARK: The report

    /// Writes the report of the run into the run's folder, then copies it,
    /// the list of the files written and the rewriter's log into the chosen
    /// folder. Returns whether they all reached it.
    private func writeReport(_ folder: Folder, interrupted: Bool) async -> Bool {
        let run = Self.runFolder
        let outcome: String
        if interrupted {
            let when = status?.current.map { "while it rewrote \($0)" }
                ?? (status?.python == nil ? "while Python started" : "between two modules")
            outcome = "interrupted: Cartouche closed, by iOS or in a crash, \(when)"
        } else if case .failed(let reason) = phase {
            outcome = "failed: " + reason
        } else {
            outcome = status?.state ?? "?"
        }
        let log = run.appendingPathComponent("rewrite.log")
        let pythonError = (try? Data(contentsOf: run.appendingPathComponent(Self.pythonErrorName)))
            .map { String(decoding: $0, as: UTF8.self) }
        let report = Self.report(status: status, memory: memory, folder: folder, outcome: outcome, pythonError: pythonError,
                                 log: status?.state == "done" ? [] : Self.lastLines(of: log, count: 40))
        let reportFile = run.appendingPathComponent(Self.reportName)
        try? Data(report.utf8).write(to: reportFile)
        let exports = [(reportFile, Self.reportName), (run.appendingPathComponent(Self.ownListName), Self.ownListName), (log, Self.logName)]
            .filter { FileManager.default.fileExists(atPath: $0.0.path) }
        return await Self.export(exports, to: folder.url)
    }

    /// The report of a run, in English, as the project's documents are.
    nonisolated static func report(status: CartoucheLabStatus?, memory: CartoucheLabMemory, folder: Folder,
                                   outcome: String, pythonError: String?, log: [String]) -> String {
        var lines = ["Cartouche lab: nxnative's rewriter on the iPhone (spike S2, step 2)", ""]
        func row(_ label: String, _ value: String) {
            lines.append(label.padding(toLength: 15, withPad: " ", startingAt: 0) + value)
        }
        func mebibytes(_ value: Int?) -> String { value.map { "\($0) MiB" } ?? "?" }
        let info = Bundle.main.infoDictionary ?? [:]
        row("Date", ISO8601DateFormatter().string(from: Date()))
        row("iPhone", "\(CartoucheDevice.modelIdentifier), iOS \(CartoucheDevice.iOSVersion)")
        row("Memory limit", "\(mebibytes(memory.limitMiB)), Increased Memory Limit \(CartoucheDevice.hasIncreasedMemoryLimit ? "on" : "off")")
        row("Cartouche", "\(info["CFBundleShortVersionString"] as? String ?? "?") (\(info["LCVersionInfo"] as? String ?? "?"))")
        row("Runtime", "Python \(status?.python ?? "?"), Capstone \(status?.capstone ?? "?"), nxnative \(status?.nxnative.map { String($0.prefix(8)) } ?? "?")")
        row("Folder", "\(folder.url.lastPathComponent): \(folder.modules.map(\.name).joined(separator: " "))"
            + (folder.reference != nil ? ", \(referenceName)" : ", no \(referenceName)"))
        if let game = status?.game {
            row("Game", "\(game.name) (\(game.id))")
        } else if status?.modules != nil {
            row("Game", "no nxnative profile registers this main: every module rewritten")
        }
        var total = 0.0
        for module in status?.modules ?? [] {
            total += module.seconds ?? 0
            var text = String(format: "%.1f MB, ", Double(module.size) / 1_000_000)
            text += module.seconds.map { String(format: "%.1f s", $0) } ?? module.state
            text += ", peak \(mebibytes(memory.peakByModule[module.name]))"
            if let restarts = module.restarts, restarts > 0 { text += ", started again \(restarts) time(s)" }
            row("  " + module.name, text)
        }
        row("Total", String(format: "%.1f s", total))
        row("Peak memory", "\(mebibytes(memory.peakMiB)), \(mebibytes(memory.availableAtPeakMiB)) still available then")
        row("Last reading", "\(mebibytes(memory.nowMiB)) used, \(mebibytes(memory.availableNowMiB)) available, "
            + String(format: "%.0f s after the start", memory.seconds ?? 0))
        if memory.pausedSeconds > 0 {
            row("Paused", String(format: "%.0f s in the background, which the times include", memory.pausedSeconds))
        }
        row("Result", outcome)
        if let summary = status?.summary, let same = summary.same {
            row("Mac's list", "\(same) same, \(summary.different ?? 0) different, \(summary.absent ?? 0) not on it, "
                + "\(summary.onlyOnMac ?? 0) only on the Mac, of \(summary.files) files written")
        }
        if let files = status?.files, !files.isEmpty {
            lines += ["", "Files written (compared with \(referenceName)):"]
            for file in files {
                lines.append("  \((file.mac ?? "-").padding(toLength: 10, withPad: " ", startingAt: 0))\(file.sha256)  \(file.name)")
            }
            for name in status?.onlyOnMac ?? [] {
                lines.append("  only on the Mac: \(name)")
            }
        }
        if let pythonError {
            lines += ["", "Python stopped the lab's code:"]
            lines += pythonError.split(separator: "\n").map { "  " + String($0) }
        }
        if !log.isEmpty {
            lines += ["", "The last lines of the rewriter's log (\(logName)):"]
            lines += log.map { "  " + $0 }
        }
        return lines.joined(separator: "\n") + "\n"
    }

    nonisolated private static func lastLines(of file: URL, count: Int) -> [String] {
        guard let data = try? Data(contentsOf: file) else { return [] }
        return String(decoding: data, as: UTF8.self).split(separator: "\n").suffix(count).map { String($0) }
    }

    nonisolated private static func lastLine(of file: URL) -> String? {
        lastLines(of: file, count: 1).first
    }

    // MARK: Files

    nonisolated private static func background<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
        try await Task.detached(priority: .userInitiated) { try work() }.value
    }

    /// Copies a file of the chosen folder, which iCloud downloads first when
    /// it has not yet.
    nonisolated private static func copy(_ source: URL, to target: URL, within root: URL) async throws {
        try await background {
            let access = root.startAccessingSecurityScopedResource()
            defer { if access { root.stopAccessingSecurityScopedResource() } }
            var coordination: NSError?
            var failure: Error?
            NSFileCoordinator().coordinate(readingItemAt: source, options: .withoutChanges, error: &coordination) { url in
                do {
                    try? FileManager.default.removeItem(at: target)
                    try FileManager.default.copyItem(at: url, to: target)
                } catch {
                    failure = error
                }
            }
            if let error = (coordination as Error?) ?? failure {
                throw CopyFailure(name: source.lastPathComponent, reason: error.localizedDescription)
            }
        }
    }

    struct CopyFailure: LocalizedError {
        let name: String
        let reason: String
        var errorDescription: String? { CartoucheText.labCopyFailed(name, reason) }
    }

    /// Copies files of the run into the chosen folder, each under the name it
    /// is given there.
    nonisolated private static func export(_ files: [(URL, String)], to folder: URL) async -> Bool {
        (try? await background {
            let access = folder.startAccessingSecurityScopedResource()
            defer { if access { folder.stopAccessingSecurityScopedResource() } }
            var written = true
            for (file, name) in files {
                let data = try Data(contentsOf: file)
                var coordination: NSError?
                var failure: Error?
                NSFileCoordinator().coordinate(writingItemAt: folder.appendingPathComponent(name),
                                               options: .forReplacing, error: &coordination) { url in
                    do { try data.write(to: url, options: .atomic) } catch { failure = error }
                }
                if coordination != nil || failure != nil { written = false }
            }
            return written
        }) ?? false
    }
}
