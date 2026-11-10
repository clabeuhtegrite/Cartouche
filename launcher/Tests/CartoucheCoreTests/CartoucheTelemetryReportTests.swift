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
        let session = CartoucheSessionReport(
            id: "5f0c2a9e-4b1d-4c3e-9a77-1e2f3d4c5b6a", session: "b8e1d0c4-7a2f-4e19-8c3d-2f6a9b0e1d7c", seq: 7,
            context: context, game: "0400C3F00006E000", gameVersion: "1.0.0", nxnative: "6c3aeb3d70a1", nxnativeChanged: false,
            settings: ["DM_OPMODE": "0", "DM_RENDER_SCALE": "1.0"], minutes: 35.2, measures: measures)
        let event = try XCTUnwrap(CartoucheEventReport(
            id: "3d9b2f5e-0000-4000-8000-000000000001", seq: 8, context: context, name: "game.installed", game: "0400C3F00006E000",
            fields: ["version": .text("1.0.0"), "nxnative": .text("6c3aeb3d70a1"), "fromStorage": .flag(true), "sizeMiB": .number(19_456)]))
        return (session, event)
    }

    /// Every key of a JSON object, and those of the objects in it as "fps.median".
    private func paths(of object: [String: Any], under prefix: String = "") -> Set<String> {
        var paths: Set<String> = []
        for (key, value) in object {
            paths.insert(prefix + key)
            if let inner = value as? [String: Any] {
                paths.formUnion(self.paths(of: inner, under: prefix + key + "."))
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
