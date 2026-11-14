//
//  CartoucheTelemetryReportTests.swift
//  CartoucheCoreTests
//
//  What Cartouche sends to its telemetry server, and the queue it keeps
//  until the server has it (Sources/CartoucheTelemetryReport.swift).
//

import Foundation
import XCTest
@testable import CartoucheCore

final class CartoucheTelemetryReportTests: XCTestCase {
    private let context = CartoucheTelemetryContext(install: "8c1f6c2e-7a2f-4e19-8c3d-2f6a9b0e1d7c", cartouche: "0.10.0",
                                                    device: "iPhone19,4", ios: "27.3", language: "fr", memoryLimitMiB: 6143,
                                                    increasedMemoryLimit: true)
    private let now = Date(timeIntervalSince1970: 1_794_300_000)

    private func object(_ json: String) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
    }

    func testASessionReportIsFlat() throws {
        var measures = CartoucheGameMeasures()
        measures.frames = 9000
        measures.fps = CartoucheGameMeasures.Rate(median: 59.9, low5: 52)
        measures.end = CartoucheGameMeasures.End(kind: "crash", signal: 11, pc: "main+0x1a2b3c")
        let report = CartoucheSessionReport(
            id: "5f0c2a9e-4b1d-4c3e-9a77-1e2f3d4c5b6a", session: "b8e1d0c4-7a2f-4e19-8c3d-2f6a9b0e1d7c", seq: 7,
            context: context, game: "0400C3F00006E000", gameVersion: "1.0.0", nxnative: "6c3aeb3d70a1", nxnativeChanged: false,
            settings: ["DM_OPMODE": "0", "DM_RENDER_SCALE": "1.0", "DM_PATH": "/var/mobile/x", "lang": "fr"],
            minutes: 35.2, measures: measures)
        let json = try CartoucheTelemetryFormat.json(report)
        let fields = try object(json)
        XCTAssertEqual(fields["schema"] as? Int, 1)
        XCTAssertEqual(fields["kind"] as? String, "session")
        XCTAssertEqual(fields["install"] as? String, context.install)
        XCTAssertEqual(fields["device"] as? String, "iPhone19,4")
        XCTAssertEqual(fields["memoryLimitMiB"] as? Int, 6143)
        XCTAssertEqual(fields["game"] as? String, "0400C3F00006E000")
        XCTAssertEqual(fields["frames"] as? Int, 9000)
        XCTAssertEqual((fields["fps"] as? [String: Any])?["median"] as? Double, 59.9)
        XCTAssertEqual((fields["end"] as? [String: Any])?["pc"] as? String, "main+0x1a2b3c")
        XCTAssertEqual(fields["reader"] as? Int, CartoucheGameLogReader.version)
        // A path, and a key that is not one of nxnative's variables, stay home.
        XCTAssertEqual(fields["settings"] as? [String: String], ["DM_OPMODE": "0", "DM_RENDER_SCALE": "1.0"])
        XCTAssertNil(fields["context"])
        XCTAssertNil(fields["measures"])
        XCTAssertFalse(json.contains("null"))
        XCTAssertEqual(try JSONDecoder().decode(CartoucheSessionReport.self, from: Data(json.utf8)), report)
    }

    /// A session with every measure, and an event with each kind of value.
    private func fullReports() throws -> (session: CartoucheSessionReport, event: CartoucheEventReport) {
        var measures = CartoucheGameMeasures()
        measures.frames = 120_000
        measures.fps = .init(median: 59.9, low5: 52)
        measures.targetFps = 60
        measures.frameMs = .init(p50: 16.67, p95: 18.9, p99: 33.4)
        measures.gpuMs = .init(p50: 9.8, p95: 14.2, p99: 21.5)
        measures.overTargetPercent = 2.4
        measures.droppedPercent = 1.8
        measures.stutters = .init(count: 108, perMinute: 3.1, shaders: 76, textures: 21, other: 11)
        measures.shaderStallMsPerMinute = 210
        measures.prepare = .init(seconds: 21.43, lines: 13_394)
        measures.cpu = .init(watts: 4.1, percent: 230, performanceCoresPercent: 85)
        measures.gpuBusyMsPerSecond = 610
        measures.thermal = .init(nominal: 18, fair: 9, serious: 8.2, critical: 0, seriousAfterMinutes: 24)
        measures.lowPowerMinutes = 0.5
        measures.memory = .init(peakMiB: 4813, exactPeak: false, gpuPeakMiB: 2910, lowestHeadroomMiB: 1330)
        measures.guestFile = false
        measures.upscaler = .init(kind: "metalfx", gpuMs: 1.2)
        measures.audioUnderrunsPerMinute = 0.2
        measures.display = .init(tv: false, foldSplit: true)
        measures.dlc = true
        measures.end = .init(kind: "crash", signal: 11, pc: "main+0x1a2b3c", lr: "main+0x1a2b00")
        let process = CartoucheGameProcess(limitMiB: 6143, peakMiB: 4813, lastAvailableMiB: 1402, quit: false, screens: [
            .init(minute: 0, width: 874, height: 402, footprintMiB: 1830),
            .init(minute: 12.4, width: 1172, height: 905, footprintMiB: 4120),
        ])
        let session = CartoucheSessionReport(
            id: "5f0c2a9e-4b1d-4c3e-9a77-1e2f3d4c5b6a", session: "b8e1d0c4-7a2f-4e19-8c3d-2f6a9b0e1d7c", seq: 7,
            context: context, game: "0400C3F00006E000", gameVersion: "1.0.0", nxnative: "6c3aeb3d70a1", nxnativeChanged: false,
            settings: ["DM_OPMODE": "0", "DM_RENDER_SCALE": "1.0"], minutes: 35.2, measures: measures, process: process)
        let event = try XCTUnwrap(CartoucheEventReport(
            id: "3d9b2f5e-0000-4000-8000-000000000001", seq: 8, context: context, name: "game.installed", game: "0400C3F00006E000",
            fields: ["version": .text("1.0.0"), "nxnative": .text("6c3aeb3d70a1"), "fromStorage": .flag(true), "sizeMiB": .number(19_456)]))
        return (session, event)
    }

    /// Every key of a JSON object, and those of the objects in it as
    /// "fps.median", and of the objects of a list in it as
    /// "process.screens[].width".
    private func paths(of object: [String: Any], under prefix: String = "") -> Set<String> {
        var paths: Set<String> = []
        for (key, value) in object {
            paths.insert(prefix + key)
            if let inner = value as? [String: Any] {
                paths.formUnion(self.paths(of: inner, under: prefix + key + "."))
            } else if let list = value as? [[String: Any]] {
                for inner in list {
                    paths.formUnion(self.paths(of: inner, under: prefix + key + "[]."))
                }
            }
        }
        return paths
    }

    /// telemetry/test/app-reports.json holds these reports, field for field,
    /// so that the Worker's tests check that the server keeps every field
    /// Cartouche sends (telemetry/test/worker.test.js).
    func testTheServersTestsHaveEveryFieldCartoucheSends() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("../../../telemetry/test/app-reports.json").standardizedFileURL
        let file = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let kept = try XCTUnwrap(file["reports"] as? [[String: Any]])
        let (session, event) = try fullReports()
        let made = [try CartoucheTelemetryFormat.json(session), try CartoucheTelemetryFormat.json(event)]
        XCTAssertEqual(kept.count, made.count)
        for (json, report) in zip(made, kept) {
            XCTAssertEqual(paths(of: try object(json)), paths(of: report),
                           "app-reports.json should be: \(CartoucheTelemetryFormat.batch(made))")
        }
        guard kept.count == 2 else { return }
        XCTAssertEqual(try JSONDecoder().decode(CartoucheSessionReport.self, from: JSONSerialization.data(withJSONObject: kept[0])), session)
        XCTAssertEqual(try JSONDecoder().decode(CartoucheEventReport.self, from: JSONSerialization.data(withJSONObject: kept[1])), event)
    }

    /// A game that ran behind the console: the system's own peak, and the
    /// end its own process tells when its log does not.
    func testAGameBehindTheConsoleTellsItsPeakAndHowItEnded() {
        var logged = CartoucheGameMeasures()
        logged.memory = .init(peakMiB: 3900, exactPeak: nil, gpuPeakMiB: 2100, lowestHeadroomMiB: nil)
        logged.end = .init(kind: "unknown")
        let quit = CartoucheGameProcess(limitMiB: 5120, peakMiB: 4300, lastAvailableMiB: 820, quit: true, screens: [])
        let measures = logged.with(quit, nearLimit: true)
        XCTAssertEqual(measures.memory, .init(peakMiB: 4300, exactPeak: true, gpuPeakMiB: 2100, lowestHeadroomMiB: nil))
        XCTAssertEqual(measures.end, .init(kind: "quit"))
        var stopped = quit
        stopped.quit = false
        XCTAssertEqual(logged.with(stopped, nearLimit: true).end, .init(kind: "memory-likely"))
        XCTAssertEqual(logged.with(stopped, nearLimit: false).end, .init(kind: "unknown"))
        var unknown = quit
        unknown.quit = nil
        XCTAssertEqual(logged.with(unknown, nearLimit: false).end, .init(kind: "unknown"))
        // What the log saw stays: a crash, or a game that never started.
        var crashed = logged
        crashed.end = .init(kind: "crash", signal: 11, pc: "main+0x1a2b3c")
        XCTAssertEqual(crashed.with(quit, nearLimit: true).end, crashed.end)
        var notStarted = logged
        notStarted.end = .init(kind: "boot-failed")
        XCTAssertEqual(notStarted.with(stopped, nearLimit: true).end, notStarted.end)
        // A log without a reading of the memory takes the process's peak.
        XCTAssertEqual(CartoucheGameMeasures().with(quit, nearLimit: false).memory, .init(peakMiB: 4300, exactPeak: true))
        // The system's peak is the highest, but a log that read higher keeps its own.
        var higher = logged
        higher.memory?.peakMiB = 4500
        XCTAssertEqual(higher.with(quit, nearLimit: false).memory?.peakMiB, 4500)
    }

    func testAProcessKeepsTheLastSizesOfTheGamesScreen() {
        let sizes = (0..<12).map { CartoucheGameProcess.Screen(minute: Double($0), width: 874, height: 402, footprintMiB: nil) }
        let process = CartoucheGameProcess(limitMiB: 6143, peakMiB: 4813, lastAvailableMiB: nil, quit: nil, screens: sizes)
        XCTAssertEqual(process.screens?.map(\.minute), (2..<12).map(Double.init))
        XCTAssertNil(CartoucheGameProcess(limitMiB: 6143, peakMiB: 4813, lastAvailableMiB: nil, quit: nil, screens: []).screens)
    }

    /// The game behind the console ended a few seconds in, as it does when
    /// Cartouche starts it again in its own place for more memory: its
    /// session has its process, and the next one, in Cartouche's place,
    /// none, though the process wrote a few seconds longer.
    func testAGameStartedInCartouchesPlaceRightAfterTheConsoleHasNoProcess() {
        let behind = CartoucheGameProcess(limitMiB: 6144, peakMiB: 75, lastAvailableMiB: 6068, quit: true,
                                          screens: [.init(minute: 0, width: 440, height: 956, footprintMiB: 75)])
        var runs = CartoucheTelemetryRuns()
        runs.start(folder: "5A3C", at: now, behind: true)
        runs.end(folder: "5A3C", started: now, at: now.addingTimeInterval(4), process: behind, nearLimit: false)
        runs.start(folder: "5A3C", at: now.addingTimeInterval(6), behind: false)
        var lingering = behind
        lingering.quit = nil
        let last = CartoucheTelemetryRuns.Reading(folder: "5A3C", started: now.addingTimeInterval(0.3),
                                                  updated: now.addingTimeInterval(10), process: lingering, nearLimit: false)
        XCTAssertEqual(runs.process(folder: "5A3C", created: now.addingTimeInterval(1), last: last)?.process, behind)
        XCTAssertNil(runs.process(folder: "5A3C", created: now.addingTimeInterval(9), last: last))
        // Without the start in Cartouche's place: the game behind the console had ended.
        var ended = CartoucheTelemetryRuns()
        ended.end(folder: "5A3C", started: now, at: now.addingTimeInterval(4), process: behind, nearLimit: false)
        XCTAssertNil(ended.process(folder: "5A3C", created: now.addingTimeInterval(9), last: last))
        // A game that did not start behind the console, then started at once in Cartouche's place.
        var failed = CartoucheTelemetryRuns()
        failed.start(folder: "5A3C", at: now, behind: true)
        failed.start(folder: "5A3C", at: now.addingTimeInterval(0.5), behind: false)
        XCTAssertNil(failed.process(folder: "5A3C", created: now.addingTimeInterval(9), last: last))
        // An older session has none, and neither has another game's.
        XCTAssertNil(runs.process(folder: "5A3C", created: now.addingTimeInterval(-600), last: last))
        XCTAssertNil(runs.process(folder: "77B0", created: now.addingTimeInterval(1), last: last))
    }

    /// Two games behind the console in a row, in the same data folder:
    /// each session has its own process's reading, whatever the file
    /// holds when Cartouche reads the first.
    func testEachGameBehindTheConsoleHasItsOwnProcess() {
        let first = CartoucheGameProcess(limitMiB: 6144, peakMiB: 5890, lastAvailableMiB: 140, quit: false, screens: [])
        let second = CartoucheGameProcess(limitMiB: 6144, peakMiB: 3100, lastAvailableMiB: 2900, quit: true, screens: [])
        var runs = CartoucheTelemetryRuns()
        runs.start(folder: "5A3C", at: now, behind: true)
        runs.end(folder: "5A3C", started: now, at: now.addingTimeInterval(600), process: first, nearLimit: true)
        runs.start(folder: "5A3C", at: now.addingTimeInterval(700), behind: true)
        runs.end(folder: "5A3C", started: now.addingTimeInterval(700), at: now.addingTimeInterval(900), process: second,
                 nearLimit: false)
        let last = CartoucheTelemetryRuns.Reading(folder: "5A3C", started: now.addingTimeInterval(700.4),
                                                  updated: now.addingTimeInterval(899), process: second, nearLimit: false)
        let one = runs.process(folder: "5A3C", created: now.addingTimeInterval(2), last: last)
        XCTAssertEqual(one?.process, first)
        XCTAssertEqual(one?.nearLimit, true)
        XCTAssertEqual(runs.process(folder: "5A3C", created: now.addingTimeInterval(702), last: last)?.process, second)
        // A session between the two ran in neither process.
        XCTAssertNil(runs.process(folder: "5A3C", created: now.addingTimeInterval(650), last: last))
        // A game whose process wrote nothing Cartouche could read as it ended.
        runs.start(folder: "5A3C", at: now.addingTimeInterval(1000), behind: true)
        runs.end(folder: "5A3C", started: now.addingTimeInterval(1000), at: now.addingTimeInterval(1100), process: nil,
                 nearLimit: false)
        XCTAssertNil(runs.process(folder: "5A3C", created: now.addingTimeInterval(1002), last: last))
    }

    /// Cartouche stopped with the game behind the console, as when the
    /// player closed it: as Cartouche opens again, the session takes the
    /// last reading the file holds, if that game's process wrote it.
    func testAGameCartoucheStoppedWithTakesItsProcesssLastReading() {
        var runs = CartoucheTelemetryRuns()
        runs.start(folder: "5A3C", at: now, behind: true)
        let process = CartoucheGameProcess(limitMiB: 6144, peakMiB: 4247, lastAvailableMiB: 1210, quit: nil, screens: [])
        let last = CartoucheTelemetryRuns.Reading(folder: "5A3C", started: now.addingTimeInterval(0.4),
                                                  updated: now.addingTimeInterval(2500), process: process, nearLimit: true)
        let created = now.addingTimeInterval(3)
        let found = runs.process(folder: "5A3C", created: created, last: last)
        XCTAssertEqual(found?.process, process)
        XCTAssertEqual(found?.nearLimit, true)
        XCTAssertNil(runs.process(folder: "5A3C", created: created, last: nil))
        // An earlier game's process, a later one's, one that had stopped
        // as nxnative created the log, and another game's.
        var earlier = last
        earlier.started = now.addingTimeInterval(-300)
        XCTAssertNil(runs.process(folder: "5A3C", created: created, last: earlier))
        var later = last
        later.started = now.addingTimeInterval(60)
        XCTAssertNil(runs.process(folder: "5A3C", created: created, last: later))
        var stopped = last
        stopped.updated = now.addingTimeInterval(0.5)
        XCTAssertNil(runs.process(folder: "5A3C", created: created, last: stopped))
        var other = last
        other.folder = "77B0"
        XCTAssertNil(runs.process(folder: "5A3C", created: created, last: other))
        // The same game in Cartouche's place, after: none, the file unchanged.
        runs.start(folder: "5A3C", at: now.addingTimeInterval(3000), behind: false)
        XCTAssertNil(runs.process(folder: "5A3C", created: now.addingTimeInterval(3004), last: last))
        XCTAssertEqual(runs.process(folder: "5A3C", created: created, last: last)?.process, process)
    }

    /// The games Cartouche keeps: the last ones, in the order they started,
    /// as its file keeps them.
    func testTheRunsKeepTheLastGamesInTheOrderTheyStarted() throws {
        var runs = CartoucheTelemetryRuns()
        runs.start(folder: "A", at: now.addingTimeInterval(10), behind: false)
        // The end of a game whose start Cartouche did not keep.
        runs.end(folder: "B", started: now, at: now.addingTimeInterval(5), process: nil, nearLimit: false)
        runs.start(folder: "A", at: now.addingTimeInterval(10), behind: false)
        XCTAssertEqual(runs.runs.map(\.folder), ["B", "A"])
        XCTAssertEqual(runs.runs.map(\.behind), [true, false])
        for index in 0..<CartoucheTelemetryRuns.capacity {
            runs.start(folder: "C", at: now.addingTimeInterval(100 + Double(index)), behind: true)
        }
        XCTAssertEqual(runs.runs.count, CartoucheTelemetryRuns.capacity)
        XCTAssertEqual(Set(runs.runs.map(\.folder)), ["C"])
        let data = try JSONEncoder().encode(runs)
        XCTAssertEqual(try JSONDecoder().decode(CartoucheTelemetryRuns.self, from: data), runs)
    }

    func testAnEventKeepsOnlyWordsAndShortText() throws {
        XCTAssertNil(CartoucheEventReport(id: "a", seq: 1, context: context, name: "Bad Name"))
        XCTAssertNil(CartoucheEventReport(id: "a", seq: 1, context: context, name: "error/../x"))
        let event = try XCTUnwrap(CartoucheEventReport(
            id: "3d9b2f5e-0000-4000-8000-000000000001", seq: 2, context: context, name: "game.installed", game: "0400C3F00006E000",
            fields: ["sizeMiB": .number(19_456), "fromStorage": .flag(true), "source": .text(String(repeating: "s", count: 400)),
                     "not a word": .text("x"), "nan": .number(.nan)]))
        let json = try CartoucheTelemetryFormat.json(event)
        let fields = try object(json)
        XCTAssertEqual(fields["name"] as? String, "game.installed")
        XCTAssertEqual(fields["install"] as? String, context.install)
        let values = try XCTUnwrap(fields["fields"] as? [String: Any])
        XCTAssertEqual(Set(values.keys), ["sizeMiB", "fromStorage", "source"])
        XCTAssertEqual(values["sizeMiB"] as? Double, 19_456)
        XCTAssertEqual(values["fromStorage"] as? Bool, true)
        XCTAssertEqual((values["source"] as? String)?.count, CartoucheEventReport.maximumText)
        XCTAssertEqual(try JSONDecoder().decode(CartoucheEventReport.self, from: Data(json.utf8)), event)
    }

    func testABatchIsOneJSONObject() throws {
        let body = CartoucheTelemetryFormat.batch(["{\"id\":\"a\"}", "{\"id\":\"b\"}"])
        let reports = try XCTUnwrap(try object(body)["reports"] as? [[String: Any]])
        XCTAssertEqual(reports.map { $0["id"] as? String }, ["a", "b"])
    }

    func testTheQueueSendsTheOldestFirstAndKeepsTheNewest() {
        var queue = CartoucheTelemetryQueue()
        for index in 0..<(CartoucheTelemetryQueue.capacity + 5) {
            queue.add(.init(id: "r\(index)", created: now, body: "{}"))
        }
        queue.add(.init(id: "r10", created: now, body: "{}"))
        XCTAssertEqual(queue.entries.count, CartoucheTelemetryQueue.capacity)
        XCTAssertEqual(queue.entries.first?.id, "r5")
        let batch = queue.batch(now: now)
        XCTAssertEqual(batch?.count, CartoucheTelemetryQueue.batchCount)
        XCTAssertEqual(batch?.first?.id, "r5")
        queue.remove(Set(batch!.map(\.id)))
        XCTAssertEqual(queue.entries.first?.id, "r30")
    }

    func testABatchStaysUnderItsSize() {
        var queue = CartoucheTelemetryQueue()
        let large = String(repeating: "x", count: 25_000)
        for index in 0..<4 {
            queue.add(.init(id: "r\(index)", created: now, body: large))
        }
        XCTAssertEqual(queue.batch(now: now)?.count, 2)
        // A report larger than a batch still goes, alone.
        var single = CartoucheTelemetryQueue()
        single.add(.init(id: "big", created: now, body: String(repeating: "x", count: 70_000)))
        XCTAssertEqual(single.batch(now: now)?.count, 1)
    }

    func testAFailureWaitsLongerEachTime() {
        var queue = CartoucheTelemetryQueue()
        queue.add(.init(id: "r", created: now, body: "{}"))
        queue.failed(now: now)
        XCTAssertNil(queue.batch(now: now.addingTimeInterval(59)))
        XCTAssertNotNil(queue.batch(now: now.addingTimeInterval(61)))
        queue.failed(now: now)
        XCTAssertNil(queue.batch(now: now.addingTimeInterval(119)))
        for _ in 0..<20 { queue.failed(now: now) }
        XCTAssertNotNil(queue.batch(now: now.addingTimeInterval(6 * 3_600 + 1)))
        queue.failed(now: now, serverWait: 30)
        XCTAssertNotNil(queue.batch(now: now.addingTimeInterval(31)))
        queue.remove(["r"])
        XCTAssertEqual(queue.failures, 0)
        XCTAssertTrue(queue.isEmpty)
    }

    func testOldReportsAreDropped() {
        var queue = CartoucheTelemetryQueue()
        queue.add(.init(id: "old", created: now.addingTimeInterval(-31 * 86_400), body: "{}"))
        queue.add(.init(id: "new", created: now, body: "{}"))
        queue.prune(now: now)
        XCTAssertEqual(queue.entries.map(\.id), ["new"])
    }

    /// A game in Cartouche's place had the limit its log tells at its peak:
    /// Cartouche read another, after the game, on the same iPhone.
    func testASessionInCartouchesPlaceHasTheLimitTheGameHad() {
        XCTAssertEqual(CartoucheSessionReport.memoryLimit(cartouche: 6144, atPeak: 8192, process: nil), 8192)
        XCTAssertEqual(CartoucheSessionReport.memoryLimit(cartouche: nil, atPeak: 8192, process: nil), 8192)
        // The same limit, to the MiB the log rounds to: Cartouche's, to the byte.
        XCTAssertEqual(CartoucheSessionReport.memoryLimit(cartouche: 6143, atPeak: 6144, process: nil), 6143)
        XCTAssertEqual(CartoucheSessionReport.memoryLimit(cartouche: 6144, atPeak: 6145, process: nil), 6144)
        // A log without the headroom, such as the Mac's.
        XCTAssertEqual(CartoucheSessionReport.memoryLimit(cartouche: 6144, atPeak: nil, process: nil), 6144)
        // Behind the console, the game's process had its own: the report
        // keeps Cartouche's beside it.
        let process = CartoucheGameProcess(limitMiB: 3376, peakMiB: 3000, lastAvailableMiB: 376, quit: true, screens: [])
        XCTAssertEqual(CartoucheSessionReport.memoryLimit(cartouche: 6144, atPeak: 3377, process: process), 6144)
    }

    // MARK: Launches

    private func launchMark() throws -> (mark: CartoucheLaunchMark, defaults: UserDefaults, suite: String) {
        let suite = "CartoucheTelemetryReportTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        return (CartoucheLaunchMark(defaults: defaults), defaults, suite)
    }

    /// A launch that stopped before the console had its games: the next one
    /// says it, once, with how far it got.
    func testALaunchThatNeverGotThereIsToldByTheNext() throws {
        let (mark, defaults, suite) = try launchMark()
        defer { defaults.removePersistentDomain(forName: suite) }

        XCTAssertNil(mark.begin(version: "0.12.1", at: now), "the first launch")
        XCTAssertTrue(mark.isGoingOn)
        mark.note(at: now.addingTimeInterval(2)) { $0.listed = true }
        mark.note(at: now.addingTimeInterval(7))
        mark.note(at: now.addingTimeInterval(6)) { $0.background = true }

        let later = now.addingTimeInterval(3_600)
        let unfinished = try XCTUnwrap(mark.begin(version: "0.12.2", at: later))
        XCTAssertEqual(unfinished.version, "0.12.1")
        XCTAssertEqual(unfinished.started, now)
        let fields = unfinished.fields(now: later)
        XCTAssertEqual(fields["version"], .text("0.12.1"))
        XCTAssertEqual(fields["listed"], .flag(true))
        XCTAssertEqual(fields["checked"], .flag(false))
        XCTAssertEqual(fields["background"], .flag(true))
        XCTAssertEqual(fields["seconds"], .number(7), "the last time it was seen")
        XCTAssertEqual(fields["minutesBefore"], .number(60))
        for key in fields.keys {
            XCTAssertTrue(CartoucheTelemetrySettings.isWord(key), key)
        }
        let event = try XCTUnwrap(CartoucheEventReport(id: "3d9b2f5e-0000-4000-8000-000000000002", seq: 9, context: context,
                                                       name: "app.unfinished", fields: fields))
        XCTAssertEqual(event.fields, fields, "the server takes every field")

        // The launch that told it is the one that runs now.
        XCTAssertEqual(mark.launch?.version, "0.12.2")
        XCTAssertEqual(mark.launch?.started, later)
        XCTAssertNil(mark.launch?.ended)
    }

    /// A launch that got to the console, or to a game in Cartouche's place,
    /// leaves nothing to tell; nor does one telemetry was off for.
    func testALaunchThatGotThereIsNotTold() throws {
        let (mark, defaults, suite) = try launchMark()
        defer { defaults.removePersistentDomain(forName: suite) }

        _ = mark.begin(version: "0.12.1", at: now)
        mark.note(at: now.addingTimeInterval(4)) { $0.ended = .opened }
        XCTAssertFalse(mark.isGoingOn)
        // Nothing changes it once it got there.
        mark.note(at: now.addingTimeInterval(9)) { $0.background = true }
        XCTAssertEqual(mark.launch?.background, false)
        XCTAssertEqual(mark.launch?.noted, now.addingTimeInterval(4))
        XCTAssertNil(mark.begin(version: "0.12.1", at: now.addingTimeInterval(60)))

        mark.note(at: now.addingTimeInterval(61)) { $0.ended = .game }
        XCTAssertNil(mark.begin(version: "0.12.1", at: now.addingTimeInterval(120)), "a game took its place")

        mark.clear()
        XCTAssertFalse(mark.isGoingOn)
        mark.note(at: now.addingTimeInterval(121)) { $0.listed = true }
        XCTAssertNil(mark.launch, "no launch to note")
        XCTAssertNil(mark.begin(version: "0.12.1", at: now.addingTimeInterval(180)))

        // What an older or a damaged mark left is no launch.
        defaults.set(Data("{".utf8), forKey: CartoucheLaunchMark.key)
        XCTAssertNil(mark.launch)
        XCTAssertNil(mark.begin(version: "0.12.1", at: now.addingTimeInterval(240)))
    }

    /// A log keeps its creation date when nxnative renames it: read once,
    /// unless it grew since.
    func testALogIsReadOnceUnlessItGrew() {
        var logs = CartoucheTelemetryLogs()
        let key = CartoucheTelemetryLogs.key(folder: "5A3C", created: now)
        XCTAssertEqual(key, "5A3C|1794300000000")
        XCTAssertTrue(logs.needsReading(key: key, bytes: 100))
        logs.record(key: key, session: "s1", bytes: 100)
        XCTAssertFalse(logs.needsReading(key: key, bytes: 100))
        XCTAssertTrue(logs.needsReading(key: key, bytes: 180))
        XCTAssertEqual(logs.session(of: key), "s1")
        logs.record(key: key, session: "s1", bytes: 180)
        XCTAssertEqual(logs.logs.count, 1)
        for index in 0..<CartoucheTelemetryLogs.capacity {
            logs.record(key: "k\(index)", session: "s", bytes: 1)
        }
        XCTAssertEqual(logs.logs.count, CartoucheTelemetryLogs.capacity)
        XCTAssertNil(logs.session(of: key))
    }
}
