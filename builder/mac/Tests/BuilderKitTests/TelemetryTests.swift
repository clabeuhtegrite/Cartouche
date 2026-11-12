//
//  TelemetryTests.swift
//  BuilderKitTests
//
//  What the app sends to Cartouche's telemetry server (BuilderTelemetry.swift):
//  its events in the server's format, telemetry/test/builder-reports.json
//  field for field, what an event keeps of what it is given, and the queue
//  of the reports not sent yet.
//

import Foundation
import XCTest
@testable import BuilderKit

final class TelemetryTests: XCTestCase {
    private let context = TelemetryContext(install: "8c1f6c2e-7a2f-4e19-8c3d-2f6a9b0e1d7c", cartouche: "0.2.1", device: "Mac16,12", ios: "26.6", language: "fr")
    private let head = "6c3aeb3d70a1"

    /// One event of each kind the app makes, as telemetry/test/builder-reports.json holds them.
    private func madeEvents() throws -> [TelemetryEvent] {
        let opened: [String: TelemetryValue] = [
            "atLogin": .flag(true), "automaticUpdates": .flag(true), "bridge": .flag(true), "cores": .count(10),
            "due": .count(2), "failed": .count(1), "followed": .count(9), "forkOfNxnative": .flag(false),
            "fromDiskImage": .flag(false), "gameLanguage": .text("default"), "games": .count(10), "ipaOnly": .count(1),
            "jobs": .count(1), "keepExtracted": .flag(false), "memoryGB": .number(16), "menuBar": .flag(true),
            "missing": .count(0), "nxnative": .text(head), "paired": .count(2), "policy": .text("weekly"),
            "ready": .flag(true), "remote": .flag(true), "schedule": .flag(true), "xcode": .text("27.2"),
        ]
        let setup: [String: TelemetryValue] = ["item": .text("metal"), "result": .text("ready"), "seconds": .number(312)]
        let built: [String: TelemetryValue] = ["fallback": .flag(true), "ipaMB": .number(1830), "nxnative": .text(head),
                                               "reasons": .text("named,shared"), "seconds": .number(5412), "source": .text("packages")]
        let failed: [String: TelemetryValue] = ["cause": .text("app_build"), "exit": .count(1), "nxnative": .text(head), "reasons": .text("profile"),
                                                "seconds": .number(1260), "source": .text("dump"), "stage": .text("app build")]
        let batch: [String: TelemetryValue] = ["built": .count(1), "failed": .count(1), "fallback": .flag(true), "games": .count(3), "jobs": .count(1),
                                               "minutes": .number(112.5), "nxnative": .text(head), "scheduled": .flag(true),
                                               "skipped": .count(1), "state": .text("done"), "stopped": .count(0)]
        let engineError: [String: TelemetryValue] = ["background": .flag(true), "kind": .text("engine"), "origin": .text("check")]
        let error: [String: TelemetryValue] = ["background": .flag(false), "error": .text("NSCocoaErrorDomain 640 < NSPOSIXErrorDomain 28"),
                                               "origin": .text("clean")]
        let updated: [String: TelemetryValue] = ["from": .text("0.2.0"), "to": .text("0.2.1")]
        let paired: [String: TelemetryValue] = ["allowed": .flag(true)]
        let cleaned: [String: TelemetryValue] = ["freedMB": .number(4210), "items": .count(3), "what": .text("extracted")]
        let queued: [String: TelemetryValue] = ["forced": .flag(true), "games": .count(2)]
        let takenOut: [String: TelemetryValue] = ["building": .flag(false)]
        let crashed: [String: TelemetryValue] = ["background": .flag(false), "exception": .text("ModuleNotFoundError"), "exit": .count(1),
                                                 "kind": .text("crashed"), "origin": .text("library")]
        let notStarted: [String: TelemetryValue] = ["exception": .text("PermissionError"), "exit": .count(1), "kind": .text("not_started"),
                                                    "origin": .text("build"), "seconds": .number(3), "signal": .flag(false)]
        let failedBatch: [String: TelemetryValue] = ["built": .count(0), "errno": .count(28), "exception": .text("OSError"),
                                                     "failed": .count(0), "games": .count(2), "jobs": .count(1), "minutes": .number(0.4),
                                                     "nxnative": .text(head), "scheduled": .flag(false), "skipped": .count(0),
                                                     "state": .text("failed"), "stopped": .count(2), "where": .text("workspace.prepare")]
        let imported: [String: TelemetryValue] = ["ipaMB": .number(5120), "nxnative": .text(head), "remote": .flag(true), "seconds": .number(48)]
        let skipped: [String: TelemetryValue] = ["cause": .text("no_space"), "exit": .count(1), "nxnative": .text(head), "reasons": .text("new"),
                                                 "seconds": .number(312), "source": .text("nup"), "stage": .text("unpack v0")]
        let failedHere: [String: TelemetryValue] = ["cause": .text("builder"), "errno": .count(13), "exception": .text("PermissionError"),
                                                    "nxnative": .text(head), "reasons": .text("source"), "seconds": .number(2410),
                                                    "source": .text("packages"), "stage": .text("deliver"), "where": .text("ipa.deliver")]
        let events: [(name: String, game: String?, fields: [String: TelemetryValue])] = [
            ("builder.opened", nil, opened),
            ("builder.setup", nil, setup),
            ("builder.built", "0100152000022000", built),
            ("builder.failed", "010093801237C000", failed),
            ("builder.batch", nil, batch),
            ("builder.error", nil, engineError),
            ("builder.error", nil, error),
            ("builder.updated", nil, updated),
            ("builder.paired", nil, paired),
            ("builder.cleaned", nil, cleaned),
            ("builder.queued", nil, queued),
            ("builder.takenOut", nil, takenOut),
            ("builder.error", nil, crashed),
            ("builder.error", nil, notStarted),
            ("builder.batch", nil, failedBatch),
            ("builder.imported", "0100152000022000", imported),
            ("builder.skipped", "0100152000022000", skipped),
            ("builder.failed", "010093801237C000", failedHere),
        ]
        var made: [TelemetryEvent] = []
        for (index, event) in events.enumerated() {
            let seq = index + 1
            let id = "6a1d9e3c-0000-4000-8000-" + String(format: "%012ld", seq)
            made.append(try XCTUnwrap(TelemetryEvent(id: id, seq: seq, context: context, name: event.name, game: event.game, fields: event.fields)))
        }
        return made
    }

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

    /// telemetry/test/builder-reports.json holds these reports, field for
    /// field, so that the Worker's tests check that the server keeps every
    /// field the app sends (telemetry/test/worker.test.js).
    func testTheServersTestsHaveEveryFieldTheAppSends() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("../../../../telemetry/test/builder-reports.json").standardizedFileURL
        let file = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let kept = try XCTUnwrap(file["reports"] as? [[String: Any]])
        let made = try madeEvents()
        let bodies = try made.map { try TelemetryFormat.json($0) }
        XCTAssertEqual(kept.count, made.count)
        for (index, (body, report)) in zip(bodies, kept).enumerated() {
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(body.utf8)) as? [String: Any])
            XCTAssertEqual(paths(of: object), paths(of: report), "builder-reports.json should be: \(TelemetryFormat.batch(bodies))")
            let decoded = try JSONDecoder().decode(TelemetryEvent.self, from: JSONSerialization.data(withJSONObject: report))
            XCTAssertEqual(decoded, made[index])
        }
    }

    /// What the app sends at a batch's end (BuilderTelemetry.batchEvents):
    /// why each game was not built as names and numbers, the nxnative
    /// commit it was built from, a game skipped once tried (a full disk),
    /// and the batch on an older commit; never a name, an error or a path.
    func testTheEventsOfABatch() throws {
        let json = #"""
            {"state": "done", "scheduled": true, "head": "6da69001c0ffee00", "latest": "7867152deadbeef0",
             "started": "2026-11-11T20:00:00+00:00", "ended": "2026-11-11T21:30:00+00:00",
             "fallback": {"from": "7867152deadbeef0", "to": "6da69001c0ffee00"},
             "games": [
               {"title_id": "0100152000022000", "name": "Mario Kart World", "state": "built", "reasons": ["named"], "duration": 5412.4,
                "commit": "6da69001c0ff", "fallback": true},
               {"title_id": "01007EF00011E000", "name": "Zelda", "state": "failed", "reasons": ["profile"], "duration": 1260, "stage": "app build",
                "commit": "7867152deadb", "fallback": false, "cause": "app_build", "exit": 1, "error": "xcodebuild failed in /Users/player/x"},
               {"title_id": "010093801237C000", "name": "Another", "state": "skipped", "reasons": ["new"], "duration": 312, "stage": "unpack v0",
                "commit": "6da69001c0ff", "fallback": true, "cause": "no_space", "exit": 1, "failure": {}, "error": "Your Mac's disk is full"},
               {"title_id": "010028600EBDA000", "name": "Not reached", "state": "skipped"},
               {"title_id": "0100000000010000", "name": "Stopped", "state": "stopped", "cause": "stopped", "error": "stopped"},
               {"title_id": "01006A800016E000", "name": "Its own error", "state": "failed", "reasons": ["source"], "duration": 2410, "stage": "deliver",
                "commit": "not a commit", "cause": "builder", "failure": {"exception": "PermissionError", "where": "ipa.deliver", "errno": 13}}]}
            """#
        let status = try JSONDecoder().decode(BatchStatus.self, from: Data(json.utf8))
        let events = BuilderTelemetry.batchEvents(status, library: nil, jobs: 2)
        XCTAssertEqual(events.map(\.name), ["builder.built", "builder.failed", "builder.skipped", "builder.failed", "builder.batch"])
        XCTAssertEqual(events.map(\.game), ["0100152000022000", "01007EF00011E000", "010093801237C000", "01006A800016E000", nil])
        XCTAssertEqual(events[0].fields, ["fallback": .flag(true), "nxnative": .text("6da69001c0ff"), "reasons": .text("named"), "seconds": .number(5412)])
        XCTAssertEqual(events[1].fields, ["cause": .text("app_build"), "exit": .count(1), "nxnative": .text("7867152deadb"), "reasons": .text("profile"),
                                          "seconds": .number(1260), "stage": .text("app build")])
        XCTAssertEqual(events[2].fields, ["cause": .text("no_space"), "exit": .count(1), "fallback": .flag(true), "nxnative": .text("6da69001c0ff"),
                                          "reasons": .text("new"), "seconds": .number(312), "stage": .text("unpack v0")])
        // A commit that is not one is not sent: the batch's is.
        XCTAssertEqual(events[3].fields, ["cause": .text("builder"), "errno": .count(13), "exception": .text("PermissionError"),
                                          "nxnative": .text("6da69001c0ff"), "reasons": .text("source"), "seconds": .number(2410),
                                          "stage": .text("deliver"), "where": .text("ipa.deliver")])
        XCTAssertEqual(events[4].fields, ["built": .count(1), "failed": .count(2), "fallback": .flag(true), "games": .count(6), "jobs": .count(2),
                                          "minutes": .number(90), "nxnative": .text("6da69001c0ff"), "scheduled": .flag(true),
                                          "skipped": .count(2), "state": .text("done"), "stopped": .count(1)])
        // Each is an event the server takes.
        for (index, event) in events.enumerated() {
            XCTAssertNotNil(TelemetryEvent(id: "6a1d9e3c-0000-4000-8000-00000000010\(index)", seq: index + 1, context: context,
                                           name: event.name, game: event.game, fields: event.fields), event.name)
        }
    }

    func testAReportHasTheFieldsEveryReportNeeds() throws {
        let event = try XCTUnwrap(TelemetryEvent(id: "6a1d9e3c-0000-4000-8000-000000000001", seq: 1, context: context, name: "builder.paired",
                                                 fields: ["allowed": .flag(true)]))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(try TelemetryFormat.json(event).utf8)) as? [String: Any])
        XCTAssertEqual(object["schema"] as? Int, 1)
        XCTAssertEqual(object["kind"] as? String, "event")
        for key in ["id", "seq", "install", "cartouche", "device", "ios", "language", "name", "fields"] {
            XCTAssertNotNil(object[key], key)
        }
        XCTAssertNil(object["game"])
        XCTAssertNil(object["context"])
        XCTAssertTrue(TelemetryFormat.matches(TelemetryFormat.model, context.device))
        XCTAssertTrue(TelemetryFormat.matches(TelemetryFormat.version, context.cartouche))
        XCTAssertTrue(TelemetryFormat.batch(["{}", "{}"]) == "{\"reports\":[{},{}]}")
    }

    func testAnEventKeepsOnlyWordsShortTextAndATitleID() throws {
        XCTAssertNil(TelemetryEvent(id: "a", seq: 1, context: context, name: "Builder.opened"))
        XCTAssertNil(TelemetryEvent(id: "a", seq: 1, context: context, name: "builder..opened"))
        XCTAssertNil(TelemetryEvent(id: "a", seq: 1, context: context, name: "builder.error/../x"))
        XCTAssertNil(TelemetryEvent(id: "a", seq: 1, context: context, name: "builder." + String(repeating: "a", count: 48)))

        var many: [String: TelemetryValue] = ["not a word": .text("x"), "nan": .number(.nan), "long": .text(String(repeating: "s", count: 400))]
        for index in 0..<30 { many["field\(String(format: "%02ld", index))"] = .count(index) }
        let event = try XCTUnwrap(TelemetryEvent(id: "a", seq: 1, context: context, name: "builder.built", game: "0100152000022000".lowercased(), fields: many))
        XCTAssertEqual(event.game, "0100152000022000")
        let fields = try XCTUnwrap(event.fields)
        XCTAssertEqual(fields.count, TelemetryEvent.maximumFields)
        XCTAssertNil(fields["not a word"])
        XCTAssertNil(fields["nan"])
        XCTAssertEqual(fields["field00"], .count(0))
        XCTAssertNil(fields["long"], "the 24 first keys in order: field00 to field23")

        let short = try XCTUnwrap(TelemetryEvent(id: "a", seq: 1, context: context, name: "builder.error", game: "/Users/player/Games",
                                                 fields: ["long": .text(String(repeating: "s", count: 400))]))
        XCTAssertNil(short.game)
        XCTAssertEqual(short.fields?["long"], .text(String(repeating: "s", count: TelemetryEvent.maximumText)))

        let bare = try XCTUnwrap(TelemetryEvent(id: "a", seq: 1, context: context, name: "builder.opened"))
        XCTAssertNil(bare.fields)
        XCTAssertFalse(try TelemetryFormat.json(bare).contains("\"fields\""))
    }

    func testTheQueueSendsTheOldestFirstInBatchesTheServerTakes() {
        let now = Date(timeIntervalSince1970: 1_794_330_000)
        var queue = TelemetryQueue()
        XCTAssertNil(queue.batch(now: now))
        for index in 0..<40 {
            queue.add(TelemetryQueue.Entry(id: "r\(index)", created: now.addingTimeInterval(Double(index)), body: "{\"seq\":\(index)}"))
        }
        queue.add(TelemetryQueue.Entry(id: "r0", created: now, body: "{}"))
        XCTAssertEqual(queue.entries.count, 40)
        let first = queue.batch(now: now)
        XCTAssertEqual(first?.count, TelemetryQueue.batchCount)
        XCTAssertEqual(first?.first?.id, "r0")
        queue.remove(Set((first ?? []).map(\.id)))
        XCTAssertEqual(queue.entries.count, 15)

        var large = TelemetryQueue()
        for index in 0..<5 {
            large.add(TelemetryQueue.Entry(id: "big\(index)", created: now, body: String(repeating: "x", count: 25_000)))
        }
        XCTAssertEqual(large.batch(now: now)?.count, 2, "60,000 bytes at most")

        var full = TelemetryQueue()
        for index in 0..<(TelemetryQueue.capacity + 10) {
            full.add(TelemetryQueue.Entry(id: "f\(index)", created: now, body: "{}"))
        }
        XCTAssertEqual(full.entries.count, TelemetryQueue.capacity)
        XCTAssertEqual(full.entries.first?.id, "f10", "the newest are kept")

        var old = TelemetryQueue()
        old.add(TelemetryQueue.Entry(id: "old", created: now.addingTimeInterval(-31 * 86_400), body: "{}"))
        old.add(TelemetryQueue.Entry(id: "new", created: now.addingTimeInterval(-86_400), body: "{}"))
        old.prune(now: now)
        XCTAssertEqual(old.entries.map(\.id), ["new"])
    }

    func testAFailedSendWaitsLongerEachTime() {
        let now = Date(timeIntervalSince1970: 1_794_330_000)
        var queue = TelemetryQueue()
        queue.add(TelemetryQueue.Entry(id: "r", created: now, body: "{}"))
        queue.failed(now: now)
        XCTAssertEqual(queue.retryAfter, now.addingTimeInterval(60))
        XCTAssertNil(queue.batch(now: now.addingTimeInterval(59)))
        XCTAssertNotNil(queue.batch(now: now.addingTimeInterval(61)))
        queue.failed(now: now)
        XCTAssertEqual(queue.retryAfter, now.addingTimeInterval(120))
        for _ in 0..<20 { queue.failed(now: now) }
        XCTAssertEqual(queue.retryAfter, now.addingTimeInterval(6 * 3600))
        queue.failed(now: now, serverWait: 30)
        XCTAssertEqual(queue.retryAfter, now.addingTimeInterval(30))
        queue.remove([])
        XCTAssertNil(queue.retryAfter)
        XCTAssertEqual(queue.failures, 0)
        XCTAssertEqual(queue.entries.count, 1)
    }

    func testErrorsAreTheirCodesNeverTheirWords() {
        let inner = NSError(domain: NSPOSIXErrorDomain, code: 28, userInfo: [NSLocalizedDescriptionKey: "No space left on /Volumes/Jeux"])
        let outer = NSError(domain: NSCocoaErrorDomain, code: 640, userInfo: [NSUnderlyingErrorKey: inner, NSFilePathErrorKey: "/Users/player/Games"])
        XCTAssertEqual(BuilderTelemetry.codes(of: outer), "NSCocoaErrorDomain 640 < NSPOSIXErrorDomain 28")
    }

    @MainActor
    func testNothingIsKeptOrSentWithoutAServerOrWhenOff() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("telemetry.json")

        let withoutServer = BuilderTelemetry(file: file, endpoint: nil, version: "0.2.1")
        withoutServer.event("builder.opened", fields: ["games": .count(3)])
        XCTAssertEqual(withoutServer.waiting, 0)
        XCTAssertTrue(withoutServer.isOn)

        withoutServer.setOn(false)
        XCTAssertFalse(withoutServer.isOn)
        let again = BuilderTelemetry(file: file, endpoint: nil, version: "0.2.1")
        XCTAssertFalse(again.isOn, "the switch is kept")
        XCTAssertEqual(again.context.cartouche, "0.2.1")
        XCTAssertTrue(TelemetryFormat.matches(TelemetryFormat.model, again.context.device))

        let odd = BuilderTelemetry(file: nil, endpoint: nil, version: "dev")
        XCTAssertEqual(odd.context.cartouche, "0.0.0")
    }
}
