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

    private func report(what: String = "The game does not install from the NAS.\nIt stops at 42 %.",
                        errors: [String] = ["Installing Mario Kart World\nThe network connection was lost."]) -> CartoucheProblemReport {
        CartoucheProblemReport(
            what: what,
            report: "Problem report, 2026-11-10 07:12 UTC\nCartouche 0.9.0 (50e8079)\niPhone19,4, iOS 27.3\n",
            errors: errors, measurement: measurement, version: "0.9.0 (50e8079)", model: "iPhone19,4", iOS: "27.3")
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

    func testTheReportHoldsWhatHappenedTheReportTheMeasurementAndTheErrors() {
        XCTAssertEqual(report().text, """
            What happened
            The game does not install from the NAS.
            It stops at 42 %.

            Problem report, 2026-11-10 07:12 UTC
            Cartouche 0.9.0 (50e8079)
            iPhone19,4, iOS 27.3

            For catalog/devices.json:
            \(measurement.json)

            Last errors, newest first:
            Installing Mario Kart World
            The network connection was lost.
            """)
        XCTAssertEqual(report().title, "The game does not install from the NAS.")
        XCTAssertTrue(report().details.hasPrefix("Problem report, 2026-11-10 07:12 UTC\n"))
        XCTAssertFalse(report().details.contains("What happened"))
    }

    func testAReportWithNothingWrittenOrNoErrors() {
        let empty = report(what: " \n ", errors: [])
        XCTAssertTrue(empty.text.hasPrefix("What happened\n(nothing written)\n\nProblem report"))
        XCTAssertFalse(empty.text.contains("Last errors"))
        XCTAssertEqual(empty.title, "Cartouche 0.9.0 (50e8079) on iPhone19,4, iOS 27.3")
        let long = report(what: String(repeating: "a", count: 100))
        XCTAssertEqual(long.title, String(repeating: "a", count: 71) + "…")
    }

    func testErrorsAreSeparated() {
        let two = report(errors: ["First\nline", "Second"])
        XCTAssertTrue(two.text.hasSuffix("Last errors, newest first:\nFirst\nline\n\nSecond"))
    }

    // MARK: GitHub's bug report form

    func testTheIssueFillsInTheBugReportForm() throws {
        let url = try XCTUnwrap(report().issueURL())
        let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        XCTAssertEqual(components.scheme, "https")
        XCTAssertEqual(components.host, "github.com")
        XCTAssertEqual(components.path, "/clabeuhtegrite/Cartouche/issues/new")
        // The IDs of .github/ISSUE_TEMPLATE/bug_report.yml's fields.
        XCTAssertEqual(fields(url), [
            "template": "bug_report.yml",
            "title": "The game does not install from the NAS.",
            "what": "The game does not install from the NAS.\nIt stops at 42 %.",
            "device": "iPhone19,4",
            "ios": "27.3",
            "version": "0.9.0 (50e8079)",
            "logs": report().details,
        ])
        XCTAssertEqual(fields(try XCTUnwrap(report().issueURL(repository: "someone/Fork")))["template"], "bug_report.yml")
        XCTAssertTrue(try XCTUnwrap(report().issueURL(repository: "someone/Fork")).absoluteString
            .hasPrefix("https://github.com/someone/Fork/issues/new?template=bug_report.yml&"))
    }

    func testNothingWrittenLeavesTheFieldForGitHub() throws {
        let url = try XCTUnwrap(report(what: "", errors: []).issueURL())
        XCTAssertNil(fields(url)["what"])
        XCTAssertEqual(fields(url)["title"], "Cartouche 0.9.0 (50e8079) on iPhone19,4, iOS 27.3")
    }

    func testTheQueryKeepsPlusSignsAmpersandsAndAccents() {
        XCTAssertEqual(CartoucheIssueForm.encode("52124866+dirty & C=1 é\n"), "52124866%2Bdirty%20%26%20C%3D1%20%C3%A9%0A")
        let address = CartoucheIssueForm.address(repository: "o/r", template: "bug_report.yml",
                                                 fields: [(name: "version", value: "0.9.0 (52124866+dirty)"), (name: "logs", value: "")])
        XCTAssertEqual(address, "https://github.com/o/r/issues/new?template=bug_report.yml&version=0.9.0%20%2852124866%2Bdirty%29")
    }

    func testATooLongReportLosesItsOldestErrorsFirst() throws {
        let many = report(errors: (1...300).map { "Error \($0)\nSomething went wrong while copying the game." })
        let url = try XCTUnwrap(many.issueURL())
        XCTAssertLessThanOrEqual(url.absoluteString.utf8.count, CartoucheProblemReport.issueURLLimit)
        let logs = try XCTUnwrap(fields(url)["logs"])
        XCTAssertTrue(logs.hasPrefix("Problem report, 2026-11-10 07:12 UTC\n"))
        XCTAssertTrue(logs.contains(measurement.json))
        XCTAssertTrue(logs.contains("Error 1\n"))
        XCTAssertFalse(logs.contains("Error 300\n"))
        XCTAssertTrue(logs.hasSuffix("\n[Shortened for GitHub: send the report from Cartouche for all of it.]"))
        // The share sheet sends it all.
        XCTAssertTrue(many.text.contains("Error 300\n"))
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
