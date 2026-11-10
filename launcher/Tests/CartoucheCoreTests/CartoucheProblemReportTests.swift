//
//  CartoucheProblemReportTests.swift
//  CartoucheCoreTests
//
//  What System › Report a problem sends (Sources/CartoucheProblemReport.swift):
//  the report as text, this iPhone's entry for catalog/devices.json, and
//  GitHub's bug report form filled in.
//

import Foundation
import XCTest
@testable import CartoucheCore

final class CartoucheProblemReportTests: XCTestCase {
    private let measurement = CartoucheDeviceMeasurement(
        identifier: "iPhone19,4", chip: "A20 Pro", memoryGB: 12, date: "2026-11-10", iOS: "27.3",
        increasedMemoryLimit: true, appMemoryLimitMiB: 6143)

    private let environment = CartoucheReport.Environment(
        cartouche: "0.9.0 (50e8079)", basedOn: "LiveContainer 3.8.11, SideStore 0.7.0", system: "27.3 (25B72)",
        device: "iPhone19,4 (A20 Pro, 12 GB)", language: "fr (fr-FR)",
        facts: [.init("Memory", "limit 6143 MiB, used 212 MiB, Increased Memory Limit on"), .init("Storage", "games on SMB")])
    private let date = Date(timeIntervalSince1970: 1_794_294_720)
    /// The player's settings, as CartoucheReports reads them.
    private let player = CartoucheRedaction(servers: ["192.168.1.2"], names: ["NAS d'Ad"], accounts: ["Ad Example"])
    private let error = """
        Cartouche report, 2026-11-09 21:03:11 +0100
        Problem: The game was not installed
        Message: The network connection was lost.
        """

    private func report(what: String = "The game does not install from the NAS.\nIt stops at 42 %.",
                        errors: [String]? = nil) -> CartoucheProblemReport {
        CartoucheProblemReport(
            what: what, environment: environment,
            journal: ["Cartouche 0.9.0 (50e8079) started, iOS 27.3 (25B72), iPhone19,4", "Installing Celeste: Unpacking"],
            date: date, errors: errors ?? [error], measurement: measurement, redaction: player)
    }

    private func fields(_ url: URL) -> [String: String] {
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        return Dictionary(items.map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { first, _ in first })
    }

    // MARK: The entry for devices.json

    func testTheMeasurementIsAnEntryOfDevicesJSON() throws {
        XCTAssertEqual(measurement.json, #"{"identifier": "iPhone19,4", "chip": "A20 Pro", "memoryGB": 12, "measurements": "# +
                       #"[{"date": "2026-11-10", "iOS": "27.3", "increasedMemoryLimit": true, "appMemoryLimitMiB": 6143}]}"#)
        let entry = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(measurement.json.utf8)) as? [String: Any])
        XCTAssertEqual(Set(entry.keys), ["identifier", "chip", "memoryGB", "measurements"])
        let measured = try XCTUnwrap((entry["measurements"] as? [[String: Any]])?.first)
        XCTAssertEqual(Set(measured.keys), ["date", "iOS", "increasedMemoryLimit", "appMemoryLimitMiB"])
        XCTAssertEqual(measured["appMemoryLimitMiB"] as? Int, 6143)

        // A model the catalog does not know: iOS does not say its chip.
        var unknown = measurement
        unknown.identifier = "iPhone18,1"
        unknown.chip = nil
        unknown.increasedMemoryLimit = false
        unknown.appMemoryLimitMiB = 3376
        XCTAssertEqual(unknown.json, #"{"identifier": "iPhone18,1", "memoryGB": 12, "measurements": "# +
                       #"[{"date": "2026-11-10", "iOS": "27.3", "increasedMemoryLimit": false, "appMemoryLimitMiB": 3376}]}"#)
    }

    func testModelIdentifiers() {
        XCTAssertTrue(CartoucheDeviceMeasurement.isModelIdentifier("iPhone18,1"))
        XCTAssertTrue(CartoucheDeviceMeasurement.isModelIdentifier("iPad16,3"))
        // A simulator without SIMULATOR_MODEL_IDENTIFIER, a Mac, or anything else.
        for identifier in ["arm64", "x86_64", "Mac16,10", "iPhone", "iPhone18,1 ", "iPhone18,1\n", ""] {
            XCTAssertFalse(CartoucheDeviceMeasurement.isModelIdentifier(identifier), identifier)
        }
    }

    func testMemoryInGBAsAppleCountsIt() {
        XCTAssertEqual(CartoucheDeviceMeasurement.memoryGB(physicalMemory: 12_884_901_888), 12)
        // What iOS reports can be a little less than the memory fitted.
        XCTAssertEqual(CartoucheDeviceMeasurement.memoryGB(physicalMemory: 12_133_282_611), 12)
        XCTAssertEqual(CartoucheDeviceMeasurement.memoryGB(physicalMemory: 8_053_063_680), 8)
        XCTAssertEqual(CartoucheDeviceMeasurement.memoryGB(physicalMemory: 0), 1)
    }

    func testTheDayIsUTCs() {
        XCTAssertEqual(CartoucheDeviceMeasurement.day(Date(timeIntervalSince1970: 1_794_294_720)), "2026-11-10")
        // 23:30 UTC on the 10th is already the 11th in Paris, still the 10th here.
        XCTAssertEqual(CartoucheDeviceMeasurement.day(Date(timeIntervalSince1970: 1_794_353_400)), "2026-11-10")
    }

    // MARK: The report

    func testTheReportIsCartouchesWithWhatThePlayerWroteTheMeasurementAndTheErrors() {
        XCTAssertEqual(report().text, """
            Cartouche report, \(CartoucheReport.timestamp(date))
            Problem: Reported by the player
            Message: The game does not install from the NAS.
                It stops at 42 %.
            Cartouche: 0.9.0 (50e8079), LiveContainer 3.8.11, SideStore 0.7.0
            iOS: 27.3 (25B72)
            Device: iPhone19,4 (A20 Pro, 12 GB)
            Language: fr (fr-FR)
            Memory: limit 6143 MiB, used 212 MiB, Increased Memory Limit on
            Storage: games on SMB

            Last steps:
            Cartouche 0.9.0 (50e8079) started, iOS 27.3 (25B72), iPhone19,4
            Installing Celeste: Unpacking

            For catalog/devices.json:
            \(measurement.json)

            Last errors, newest first:

            Cartouche report, 2026-11-09 21:03:11 +0100
            Problem: The game was not installed
            Message: The network connection was lost.
            """)
        XCTAssertEqual(report().title, "The game does not install from the NAS.")
        // The page shows it in three parts.
        XCTAssertEqual(report().parts.count, 3)
        XCTAssertEqual(report().parts.joined(separator: "\n\n"), report().text)
    }

    func testWhatThePlayerWritesIsRedactedAsTheRest() throws {
        let said = report(what: "Mon NAS 192.168.1.2 ne répond plus depuis NAS d'Ad.\nÉquipe Ad Example, ad@icloud.com")
        XCTAssertTrue(said.text.contains("Message: Mon NAS <server> ne répond plus depuis <name>.\n    Équipe <account>, <e-mail>\n"))
        XCTAssertEqual(said.title, "Mon NAS <server> ne répond plus depuis <name>.")
        let url = try XCTUnwrap(said.issueURL())
        XCTAssertEqual(fields(url)["what"], "Mon NAS <server> ne répond plus depuis <name>.\nÉquipe <account>, <e-mail>")
        for kept in ["192.168.1.2", "NAS d'Ad", "Ad Example", "icloud"] {
            XCTAssertFalse(said.text.contains(kept), kept)
            XCTAssertFalse(url.absoluteString.removingPercentEncoding?.contains(kept) ?? true, kept)
        }
    }

    func testAReportWithNothingWrittenOrNoErrors() {
        let empty = report(what: " \n ", errors: [])
        XCTAssertTrue(empty.text.contains("\nMessage: (nothing written)\n"))
        XCTAssertFalse(empty.text.contains("Last errors"))
        XCTAssertEqual(empty.parts.count, 2)
        XCTAssertEqual(empty.title, "Cartouche 0.9.0 on iPhone19,4, iOS 27.3")
        let long = report(what: String(repeating: "a", count: 100))
        XCTAssertEqual(long.title, String(repeating: "a", count: 71) + "…")
    }

    func testErrorsAreSeparated() {
        let two = report(errors: ["First\nline\n", "Second"])
        XCTAssertTrue(two.text.hasSuffix("Last errors, newest first:\n\nFirst\nline\n\nSecond"))
    }

    // MARK: GitHub's bug report form

    func testTheIssueFillsInTheBugReportForm() throws {
        let url = try XCTUnwrap(report().issueURL())
        let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        XCTAssertEqual(components.scheme, "https")
        XCTAssertEqual(components.host, "github.com")
        XCTAssertEqual(components.path, "/clabeuhtegrite/Cartouche/issues/new")
        // The IDs of .github/ISSUE_TEMPLATE/bug_report.yml's fields; what
        // the player wrote has its own.
        let logs = report().text.replacingOccurrences(
            of: "Message: The game does not install from the NAS.\n    It stops at 42 %.", with: "Message: (see What happened)")
        XCTAssertEqual(fields(url), [
            "template": "bug_report.yml",
            "title": "The game does not install from the NAS.",
            "what": "The game does not install from the NAS.\nIt stops at 42 %.",
            "device": "iPhone19,4 (A20 Pro, 12 GB)",
            "ios": "27.3 (25B72)",
            "version": "0.9.0 (50e8079)",
            "logs": logs,
        ])
        XCTAssertTrue(try XCTUnwrap(report().issueURL(repository: "someone/Fork")).absoluteString
            .hasPrefix("https://github.com/someone/Fork/issues/new?template=bug_report.yml&"))
    }

    func testNothingWrittenLeavesTheFieldForGitHub() throws {
        let url = try XCTUnwrap(report(what: "", errors: []).issueURL())
        XCTAssertNil(fields(url)["what"])
        XCTAssertEqual(fields(url)["title"], "Cartouche 0.9.0 on iPhone19,4, iOS 27.3")
    }

    func testTheQueryKeepsPlusSignsAmpersandsAndAccents() {
        XCTAssertEqual(CartoucheIssueForm.encode("52124866+dirty & C=1 é\n"), "52124866%2Bdirty%20%26%20C%3D1%20%C3%A9%0A")
        let address = CartoucheIssueForm.address(repository: "o/r", template: "bug_report.yml",
                                                 fields: [(name: "version", value: "0.9.0 (52124866+dirty)"), (name: "logs", value: "")])
        XCTAssertEqual(address, "https://github.com/o/r/issues/new?template=bug_report.yml&version=0.9.0%20%2852124866%2Bdirty%29")
    }

    func testATooLongReportLosesItsOldestErrorsFirst() throws {
        let errors = (1...300).map { "Cartouche report, 2026-11-09 21:03:11 +0100\nProblem: Error \($0)\nMessage: Something went wrong while copying the game." }
        let many = report(errors: errors)
        let url = try XCTUnwrap(many.issueURL())
        let length = url.absoluteString.utf8.count
        XCTAssertLessThanOrEqual(length, CartoucheProblemReport.issueURLLimit)
        // As many lines as fit: one more would not.
        XCTAssertGreaterThan(length, CartoucheProblemReport.issueURLLimit - 300)
        let logs = try XCTUnwrap(fields(url)["logs"])
        XCTAssertTrue(logs.hasPrefix("Cartouche report, "))
        XCTAssertTrue(logs.contains(measurement.json))
        XCTAssertTrue(logs.contains("Problem: Error 1\n"))
        XCTAssertFalse(logs.contains("Problem: Error 300\n"))
        XCTAssertTrue(logs.hasSuffix("\n" + CartoucheProblemReport.shortenedNote))
        // The share sheet sends it all.
        XCTAssertTrue(many.text.contains("Problem: Error 300\n"))
        // What the player wrote stays whole.
        XCTAssertEqual(fields(url)["what"], "The game does not install from the NAS.\nIt stops at 42 %.")
    }

    func testWhatThePlayerWroteIsShortenedLast() throws {
        let essay = report(what: String(repeating: "é", count: 6_000), errors: [])
        let url = try XCTUnwrap(essay.issueURL())
        XCTAssertLessThanOrEqual(url.absoluteString.utf8.count, CartoucheProblemReport.issueURLLimit)
        let what = try XCTUnwrap(fields(url)["what"])
        XCTAssertTrue(what.hasSuffix("…"))
        XCTAssertTrue(what.count > 100)
        XCTAssertEqual(fields(url)["logs"], CartoucheProblemReport.shortenedNote)
        // Too small a limit for anything: no address.
        XCTAssertNil(essay.issueURL(limit: 50))
    }

    // MARK: Send to Cartouche

    private let submissionID = "6f1c2a3b-4d5e-4f60-8a7b-9c0d1e2f3a4b"

    func testTheSubmissionHoldsTheFormsFields() throws {
        let submission = try XCTUnwrap(report().submission(id: submissionID))
        let form = fields(try XCTUnwrap(report().issueURL()))
        XCTAssertEqual(submission.schema, 1)
        XCTAssertEqual(submission.id, submissionID)
        XCTAssertEqual(submission.title, form["title"])
        XCTAssertEqual(submission.what, form["what"])
        XCTAssertEqual(submission.device, form["device"])
        XCTAssertEqual(submission.ios, form["ios"])
        XCTAssertEqual(submission.version, form["version"])
        XCTAssertEqual(submission.logs, form["logs"])
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: submission.json()) as? [String: Any])
        XCTAssertEqual(Set(json.keys), ["schema", "id", "title", "what", "device", "ios", "version", "logs"])
        // As the server reads a random number.
        let id = CartoucheProblemSubmission.newID()
        XCTAssertNotNil(id.range(of: #"^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$"#, options: .regularExpression))
    }

    /// telemetry/test/app-problem.json holds this submission, so that the
    /// Worker's tests send what Cartouche sends (telemetry/test/worker.test.js).
    func testTheServersTestsSendWhatCartoucheSends() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("../../../telemetry/test/app-problem.json").standardizedFileURL
        let kept = try JSONDecoder().decode(CartoucheProblemSubmission.self, from: Data(contentsOf: url))
        var made = try XCTUnwrap(report().submission(id: submissionID))
        // The report's time is in the time zone the tests run in.
        made.logs = made.logs.replacingOccurrences(of: CartoucheReport.timestamp(date), with: "2026-11-10 07:12:00 +0000")
        let json = String(decoding: try made.json(), as: UTF8.self)
        XCTAssertEqual(kept, made, "app-problem.json should be: \(json)")
    }

    func testATooLongSubmissionLosesItsOldestErrorsFirst() throws {
        let errors = (1...600).map {
            "Cartouche report, 2026-11-09 21:03:11 +0100\nProblem: Error \($0)\nMessage: Something went wrong while copying the game."
        }
        let submission = try XCTUnwrap(report(errors: errors).submission(id: submissionID))
        let size = try submission.json().count
        XCTAssertLessThanOrEqual(size, CartoucheProblemReport.submissionLimit)
        XCTAssertGreaterThan(size, CartoucheProblemReport.submissionLimit - 300)
        XCTAssertTrue(submission.logs.contains("Problem: Error 1\n"))
        XCTAssertFalse(submission.logs.contains("Problem: Error 600\n"))
        XCTAssertTrue(submission.logs.hasSuffix("\n" + CartoucheProblemReport.shortenedForServerNote))
        XCTAssertEqual(submission.what, "The game does not install from the NAS.\nIt stops at 42 %.")
    }

    func testWhatThePlayerWroteKeepsToTheServersLimit() throws {
        let essay = try XCTUnwrap(report(what: String(repeating: "é", count: 20_000)).submission(id: submissionID))
        XCTAssertEqual(essay.what.utf16.count, CartoucheProblemReport.submissionWhatLimit)
        XCTAssertTrue(essay.what.hasSuffix("…"))
        // The report goes whole with it.
        XCTAssertTrue(essay.logs.hasSuffix("Message: The network connection was lost."))
        // Emoji are two code units each.
        let emoji = try XCTUnwrap(report(what: String(repeating: "🎮", count: 9_000)).submission(id: submissionID))
        XCTAssertLessThanOrEqual(emoji.what.utf16.count, CartoucheProblemReport.submissionWhatLimit)
        XCTAssertLessThanOrEqual(emoji.title.utf16.count, 256)
    }

    func testCarriageReturnsBecomeLineFeeds() {
        let pasted = report(what: "First line\r\nSecond line\rThird")
        XCTAssertEqual(pasted.title, "First line")
        XCTAssertTrue(pasted.text.contains("Message: First line\n    Second line\n    Third\n"))
    }

    func testTheRepositoryFollowsCartouchesSource() {
        XCTAssertEqual(CartoucheProblemReport.repository(
            sourceURL: "https://raw.githubusercontent.com/clabeuhtegrite/Cartouche/main/app/sidestore-source.json"), "clabeuhtegrite/Cartouche")
        XCTAssertEqual(CartoucheProblemReport.repository(
            sourceURL: "https://raw.githubusercontent.com/someone/Fork/main/app/sidestore-source.json"), "someone/Fork")
        XCTAssertEqual(CartoucheProblemReport.repository(sourceURL: nil), "clabeuhtegrite/Cartouche")
        XCTAssertEqual(CartoucheProblemReport.repository(sourceURL: "https://example.com/source.json"), "clabeuhtegrite/Cartouche")
        XCTAssertEqual(CartoucheProblemReport.repository(sourceURL: "https://raw.githubusercontent.com/someone"), "clabeuhtegrite/Cartouche")
    }
}
