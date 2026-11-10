//
//  FormatTests.swift
//  BuilderKitTests
//
//  Sizes, durations and percentages as the app writes them, in French and
//  in English (Format.swift, L10n.swift).
//

import Foundation
import XCTest
@testable import BuilderKit

final class FormatTests: XCTestCase {
    override func tearDown() {
        L10n.use("")
    }

    func testInEnglish() {
        L10n.use("en")
        XCTAssertEqual(tr("Library", "Bibliothèque"), "Library")
        XCTAssertEqual(L10n.code, "en")
        XCTAssertEqual(Format.size(999), "999 bytes")
        XCTAssertEqual(Format.size(1_234_567), "1.23 MB")
        XCTAssertEqual(Format.size(15_800_000_000), "15.8 GB")
        XCTAssertEqual(Format.size(512_000_000_000), "512 GB")
        XCTAssertEqual(Format.percent(0.684), "68%")
        XCTAssertEqual(Format.percent(1.4), "100%")
    }

    func testInFrench() {
        L10n.use("fr")
        XCTAssertEqual(tr("Library", "Bibliothèque"), "Bibliothèque")
        XCTAssertEqual(L10n.code, "fr")
        XCTAssertEqual(Format.size(15_800_000_000), "15,8 Go")
        XCTAssertEqual(Format.size(999), "999 o")
        XCTAssertEqual(Format.percent(0.684), "68 %")
    }

    func testDurationsAndTimes() {
        XCTAssertEqual(Format.duration(4576), "1 h 16 min")
        XCTAssertEqual(Format.duration(3600), "1 h")
        XCTAssertEqual(Format.duration(272), "4 min 32 s")
        XCTAssertEqual(Format.duration(720), "12 min")
        XCTAssertEqual(Format.duration(45), "45 s")
        XCTAssertEqual(Format.duration(-3), "0 s")
        XCTAssertEqual(Format.time(hour: 3, minute: 30), "03:30")
    }

    func testDates() {
        XCTAssertNotNil(ISODate.parse("2026-11-10T07:06:00+00:00"))
        XCTAssertNotNil(ISODate.parse("2026-11-10T07:06:00.123+00:00"))
        XCTAssertNil(ISODate.parse("yesterday"))
        L10n.use("en")
        let now = Date()
        XCTAssertEqual(Format.relative(now.addingTimeInterval(-20), now: now), "just now")
    }
}
