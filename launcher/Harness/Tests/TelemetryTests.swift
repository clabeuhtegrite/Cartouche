//
//  TelemetryTests.swift
//  CartoucheHarnessTests
//
//  Cartouche's telemetry as it leaves the iPhone (CartoucheTelemetry.swift):
//  the queue, the requests the server gets, what each of its answers does,
//  the player's switch, and the erasing of what was sent. The server is
//  the harness's (HarnessNetwork), at the address in the harness's
//  Info.plist; its answer is the test's, or none, as without network.
//

import UIKit
import XCTest
@testable import CartoucheHarness

final class TelemetryTests: HarnessCase {
    private var telemetry: CartoucheTelemetry { CartoucheTelemetry.shared }

    override func setUp() async throws {
        try await super.setUp()
        // Nothing waiting, and no wait the server asked for.
        telemetry.setOn(false)
        telemetry.setOn(true)
        XCTAssertEqual(telemetry.waiting, 0)
    }

    override func tearDown() async throws {
        telemetry.setOn(true)
        try await super.tearDown()
    }

    /// Every report the server got, in order, as JSON.
    private var reports: [[String: Any]] {
        HarnessNetwork.requests.filter { $0.url.path == "/v1/reports" }.flatMap { request -> [[String: Any]] in
            let body = (try? JSONSerialization.jsonObject(with: request.body)) as? [String: Any]
            return body?["reports"] as? [[String: Any]] ?? []
        }
    }

    private func report(named name: String) -> [String: Any]? {
        reports.last { $0["name"] as? String == name }
    }

    /// The number of this copy of Cartouche a report gives, with what it
    /// says of the iPhone, beside the report's own keys.
    private func install(of report: [String: Any]?) -> String? {
        report?["install"] as? String
    }

    private func answer(_ status: Int, headers: [String: String] = [:]) {
        HarnessNetwork.answer { request in
            request.url.host == "telemetry.harness.invalid" ? HarnessNetwork.Answer(status: status, headers: headers) : nil
        }
    }

    // MARK: Sending

    func testAnEventGoesToTheServerAndLeavesTheQueue() async throws {
        answer(200)
        let sent = telemetry.sent
        telemetry.event("harness.checked", fields: ["step": .text("one"), "count": .number(2), "ok": .flag(true)])
        try await waitUntil("the server took it") { telemetry.sent == sent + 1 }
        XCTAssertEqual(telemetry.waiting, 0)
        XCTAssertNotNil(telemetry.lastSent)

        let request = try XCTUnwrap(HarnessNetwork.requests.last { $0.url.path == "/v1/reports" })
        XCTAssertEqual(request.method, "POST")
        XCTAssertEqual(request.url.scheme, "https")
        XCTAssertEqual(request.headers["Content-Type"], "application/json")
        let report = try XCTUnwrap(report(named: "harness.checked"))
        XCTAssertEqual(report["kind"] as? String, "event")
        XCTAssertEqual(report["schema"] as? Int, CartoucheTelemetryFormat.schema)
        let fields = try XCTUnwrap(report["fields"] as? [String: Any])
        XCTAssertEqual(fields["step"] as? String, "one")
        XCTAssertEqual(fields["count"] as? Double, 2)
        XCTAssertEqual(fields["ok"] as? Bool, true)
        // What it says of the copy and the iPhone, beside its own keys.
        XCTAssertEqual(report["cartouche"] as? String, CartoucheUpdates.runningVersion)
        XCTAssertNotNil(UUID(uuidString: try XCTUnwrap(install(of: report))), "a random number, nothing else")
        XCTAssertEqual(report["device"] as? String, CartoucheDevice.modelIdentifier)
        XCTAssertNil(report["context"], "no context of its own")
        // Never the iPhone's name.
        let text = String(decoding: request.body, as: UTF8.self)
        if let name = ProcessInfo.processInfo.environment["SIMULATOR_DEVICE_NAME"], !name.isEmpty {
            XCTAssertFalse(text.contains(name))
        }
    }

    func testAnEventThatIsNoEventsNameIsNotSent() async throws {
        answer(200)
        telemetry.event("Not an event!")
        XCTAssertEqual(telemetry.waiting, 0)
        try await pause(0.3)
        XCTAssertTrue(reports.isEmpty)
    }

    func testReportsTheServerRefusesForGoodAreDropped() async throws {
        for status in [400, 413, 422] {
            answer(status)
            let sent = telemetry.sent
            let asked = HarnessNetwork.requests.count
            telemetry.event("harness.refused", fields: ["status": .number(Double(status))])
            XCTAssertEqual(telemetry.waiting, 1)
            try await waitUntil("\(status) drops the report") { telemetry.waiting == 0 }
            XCTAssertEqual(HarnessNetwork.requests.count, asked + 1)
            XCTAssertEqual(telemetry.sent, sent, "\(status) is not counted as sent")
        }
    }

    func testReportsWaitAsLongAsTheServerAsks() async throws {
        answer(503, headers: ["Retry-After": "1"])
        let sent = telemetry.sent
        telemetry.event("harness.later")
        try await waitUntil("the server was asked") { !HarnessNetwork.requests.isEmpty }
        try await pause(0.3)
        XCTAssertEqual(telemetry.waiting, 1, "kept")

        // Not before the server said.
        let asked = HarnessNetwork.requests.count
        telemetry.send()
        try await pause(0.3)
        XCTAssertEqual(HarnessNetwork.requests.count, asked)

        answer(200)
        try await pause(1)
        telemetry.send()
        try await waitUntil("the server took it") { telemetry.waiting == 0 }
        XCTAssertEqual(telemetry.sent, sent + 1)
    }

    func testWithoutNetworkReportsWaitForTheNextTry() async throws {
        let sent = telemetry.sent
        telemetry.event("harness.offline")
        try await waitUntil("the server was tried") { !HarnessNetwork.requests.isEmpty }
        try await pause(0.3)
        XCTAssertEqual(telemetry.waiting, 1)
        XCTAssertEqual(telemetry.sent, sent)
        // A minute before the next try.
        let asked = HarnessNetwork.requests.count
        telemetry.event("harness.offline.again")
        try await pause(0.3)
        XCTAssertEqual(HarnessNetwork.requests.count, asked)
        XCTAssertEqual(telemetry.waiting, 2)
    }

    func testReportsGoInTheOrderTheyWereMade() async throws {
        answer(200)
        for index in 1...5 {
            telemetry.event("harness.queued", fields: ["index": .number(Double(index))])
        }
        try await waitUntil("the server took them") { telemetry.waiting == 0 }
        let indexes = reports.filter { $0["name"] as? String == "harness.queued" }
            .compactMap { ($0["fields"] as? [String: Any])?["index"] as? Double }
        XCTAssertEqual(indexes, [1, 2, 3, 4, 5])
    }

    // MARK: The player's switch

    func testTurnedOffNothingIsKeptNorSent() async throws {
        answer(200)
        // The report is on its way as the player turns telemetry off: not
        // even the batch made before the switch goes.
        telemetry.event("harness.before")
        XCTAssertEqual(telemetry.waiting, 1)
        telemetry.setOn(false)
        XCTAssertFalse(telemetry.isOn)
        XCTAssertEqual(telemetry.waiting, 0)

        telemetry.event("harness.off")
        telemetry.send()
        try await pause(0.5)
        XCTAssertEqual(telemetry.waiting, 0)
        XCTAssertNil(report(named: "harness.before"), "the batch on its way did not go")
        XCTAssertNil(report(named: "harness.off"))
        XCTAssertFalse(HarnessNetwork.requests.contains { $0.url.path == "/v1/reports" }, "no report asked of the server")

        // On again, the next report goes at once: the batch the switch
        // stopped did not fail.
        telemetry.setOn(true)
        XCTAssertTrue(telemetry.isOn)
        telemetry.event("harness.on")
        try await waitUntil("the server took it", timeout: 5) { self.report(named: "harness.on") != nil }
        XCTAssertNil(report(named: "harness.before"))
    }

    // MARK: Erasing

    func testErasingHasTheServerForgetThisCopyWhichTakesANewNumber() async throws {
        answer(200)
        telemetry.event("harness.before")
        try await waitUntil("the server took it") { telemetry.waiting == 0 }
        let before = try XCTUnwrap(install(of: report(named: "harness.before")))

        let erased = await telemetry.erase()
        XCTAssertTrue(erased)
        let forget = try XCTUnwrap(HarnessNetwork.requests.last { $0.url.path == "/v1/forget" })
        XCTAssertEqual(forget.method, "POST")
        let body = try XCTUnwrap(try JSONSerialization.jsonObject(with: forget.body) as? [String: Any])
        XCTAssertEqual(body as? [String: String], ["install": before])
        XCTAssertEqual(telemetry.sent, 0)
        XCTAssertNil(telemetry.lastSent)
        XCTAssertNil(telemetry.lastReport)

        telemetry.event("harness.after")
        try await waitUntil("the server took it") { telemetry.waiting == 0 }
        let after = try XCTUnwrap(install(of: report(named: "harness.after")))
        XCTAssertNotEqual(after, before)
    }

    func testErasingWithoutNetworkChangesNothing() async throws {
        answer(200)
        telemetry.event("harness.before")
        try await waitUntil("the server took it") { telemetry.waiting == 0 }
        let before = try XCTUnwrap(install(of: report(named: "harness.before")))

        HarnessNetwork.answer(nil)
        let erased = await telemetry.erase()
        XCTAssertFalse(erased)

        answer(200)
        telemetry.setOn(false)
        telemetry.setOn(true)
        telemetry.event("harness.after")
        try await waitUntil("the server took it") { telemetry.waiting == 0 }
        XCTAssertEqual(install(of: report(named: "harness.after")), before, "the same number")
    }

    // MARK: Cartouche's own events

    func testCartouchesStartItsInstallsAndItsErrorsAreReported() async throws {
        answer(200)
        telemetry.start()
        let game = HarnessGame.plain()
        _ = try await installed(game)
        try await waitUntil("Cartouche reported its start", timeout: 10) { self.report(named: "app.opened") != nil }
        try await waitUntil("the install is reported") { self.report(named: "game.installed") != nil }
        let installedReport = try XCTUnwrap(report(named: "game.installed"))
        XCTAssertEqual(installedReport["game"] as? String, game.titleId.uppercased())
        XCTAssertEqual((installedReport["fields"] as? [String: Any])?["version"] as? String, game.version)

        // An install that fails: what failed, by its names and numbers,
        // never the words the player reads.
        _ = try await install(try HarnessIPA.notAZip())
        try await waitUntil("the error is reported") { self.report(named: "error") != nil }
        let error = try XCTUnwrap(report(named: "error"))
        let fields = try XCTUnwrap(error["fields"] as? [String: Any])
        XCTAssertEqual(fields["origin"] as? String, "install")
        XCTAssertEqual(fields["background"] as? Bool, false)
        let text = String(decoding: try JSONSerialization.data(withJSONObject: error), as: UTF8.self)
        XCTAssertFalse(text.contains("lc.appList.urlFileIsNotIpaError".loc), "never the message's words")
        XCTAssertFalse(text.contains(HarnessIPA.folder.path), "never a path of the iPhone")
    }
}
