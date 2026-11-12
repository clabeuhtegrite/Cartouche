//
//  CartouchePickerMeasuresTests.swift
//  CartoucheCoreTests
//
//  What Cartouche tells of the Files picker a game is imported with
//  (Sources/CartouchePickerMeasures.swift): its journal line, the fields of
//  its `import.picker` event, and the measures kept on disk while it is
//  open.
//

import Foundation
import XCTest
@testable import CartoucheCore

final class CartouchePickerMeasuresTests: XCTestCase {
    private let opened = Date(timeIntervalSince1970: 1_794_470_000)
    private let context = CartoucheTelemetryContext(install: "8c1f6c2e-7a2f-4e19-8c3d-2f6a9b0e1d7c", cartouche: "0.11.2",
                                                    device: "iPhone19,4", ios: "27.1", language: "en")

    private func measures(place: String = "home", controller: Bool = false) -> CartouchePickerMeasures {
        CartouchePickerMeasures(place: place, opened: opened, controller: controller)
    }

    func testAPickerThatWentWellSaysWhenItShowedAndWhenItClosed() {
        var picker = measures()
        picker.shown = opened.addingTimeInterval(0.42)
        picker.answered(after: 0.01, at: opened.addingTimeInterval(1))
        let closed = opened.addingTimeInterval(12.3)

        XCTAssertEqual(picker.line(.picked, at: closed), "Files picker from the home: picked after 12.3 s, on screen after 0.4 s")
        let fields = picker.fields(.picked, at: closed)
        XCTAssertEqual(fields["outcome"], .text("picked"))
        XCTAssertEqual(fields["place"], .text("home"))
        XCTAssertEqual(fields["seconds"], .number(12))
        XCTAssertEqual(fields["shownMs"], .number(420))
        XCTAssertEqual(fields["longestStallMs"], .number(10))
        XCTAssertEqual(fields["stalls"], .number(0))
        XCTAssertEqual(fields["background"], .flag(false))
        XCTAssertEqual(fields["controller"], .flag(false))
    }

    func testWaitsOfTheMainThreadCountOnceOverHalfASecond() {
        var picker = measures(place: "guide", controller: true)
        picker.shown = opened.addingTimeInterval(0.5)
        picker.answered(after: 0.2, at: opened.addingTimeInterval(1))
        picker.answered(after: 0.8, at: opened.addingTimeInterval(2))
        picker.answered(after: 2.26, at: opened.addingTimeInterval(5))
        let closed = opened.addingTimeInterval(6)

        XCTAssertEqual(picker.stalls, 2)
        XCTAssertEqual(picker.longestWait, 2.26)
        XCTAssertEqual(picker.lastSeen, opened.addingTimeInterval(5))
        XCTAssertEqual(picker.fields(.cancelled, at: closed)["longestStallMs"], .number(2260))
        XCTAssertEqual(picker.fields(.cancelled, at: closed)["stalls"], .number(2))
        XCTAssertEqual(picker.line(.cancelled, at: closed),
                       "Files picker from the guide: cancelled after 6.0 s, on screen after 0.5 s, "
                           + "Cartouche busy for 2.3 s at the longest (2 times over half a second), a controller connected")
    }

    /// A wait that never ends counts as long as it has lasted, so that the
    /// measures written down before Cartouche ended say it.
    func testAWaitStillGoingOnCountsAsLongAsItHasLasted() {
        var picker = measures(place: "sheet")
        picker.shown = opened.addingTimeInterval(0.3)
        picker.stillWaiting(for: 4, at: opened.addingTimeInterval(5))
        picker.stillWaiting(for: 9, at: opened.addingTimeInterval(10))

        XCTAssertEqual(picker.longestWait, 9)
        XCTAssertEqual(picker.stalls, 0)
        XCTAssertEqual(picker.lastSeen, opened.addingTimeInterval(10))
        XCTAssertEqual(picker.line(.quit, at: picker.lastSeen),
                       "Files picker from a game's sheet: still open when Cartouche ended, 10.0 s after it opened, "
                           + "on screen after 0.3 s, Cartouche busy for 9.0 s at the longest")
        XCTAssertEqual(picker.fields(.quit, at: picker.lastSeen)["seconds"], .number(10))
        XCTAssertEqual(picker.fields(.quit, at: picker.lastSeen)["longestStallMs"], .number(9000))
    }

    func testAPickerNeverOnScreenSaysSo() {
        var picker = measures()
        picker.wentToBackground = true
        let closed = opened.addingTimeInterval(8)

        XCTAssertEqual(picker.line(.lost, at: closed),
                       "Files picker from the home: gone without an answer after 8.0 s, never on screen, "
                           + "Cartouche in the background meanwhile")
        let fields = picker.fields(.lost, at: closed)
        XCTAssertNil(fields["shownMs"])
        XCTAssertEqual(fields["background"], .flag(true))
        XCTAssertTrue(picker.line(.closed, at: closed).hasPrefix("Files picker from the home: closed with the controller after 8.0 s"))
    }

    /// The main thread's answers come in any order with the waits seen from
    /// the watch: the last time Cartouche was seen never goes back.
    func testTheLastTimeSeenNeverGoesBack() {
        var picker = measures()
        picker.stillWaiting(for: 3, at: opened.addingTimeInterval(3))
        picker.answered(after: 3.1, at: opened.addingTimeInterval(2.9))

        XCTAssertEqual(picker.lastSeen, opened.addingTimeInterval(3))
        XCTAssertEqual(picker.longestWait, 3.1)
    }

    /// The measures as they are written down while the picker is open, and
    /// read back at the next start.
    func testTheMeasuresComeBackWhole() throws {
        var picker = measures(place: "guide", controller: true)
        picker.shown = opened.addingTimeInterval(0.25)
        picker.answered(after: 0.75, at: opened.addingTimeInterval(3))
        picker.wentToBackground = true

        let data = try JSONEncoder().encode(picker)
        XCTAssertEqual(try JSONDecoder().decode(CartouchePickerMeasures.self, from: data), picker)
    }

    /// A picker still open when Cartouche ended is told once, at the next
    /// start; one that closed leaves nothing.
    func testTheMarkOfAPickerOpenIsReadOnce() throws {
        let suite = "CartouchePickerMeasuresTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let mark = CartouchePickerMark(defaults: defaults)
        var picker = measures(place: "sheet")
        picker.stillWaiting(for: 20, at: opened.addingTimeInterval(21))

        XCTAssertNil(mark.take())
        mark.write(picker)
        XCTAssertEqual(mark.take(), picker)
        XCTAssertNil(mark.take())

        mark.write(picker)
        mark.clear()
        XCTAssertNil(mark.take())
    }

    /// Every field is a word the server takes, every outcome a name.
    func testEveryFieldIsAWordTheServerTakes() {
        var picker = measures()
        picker.shown = opened
        for outcome in CartouchePickerMeasures.Outcome.allCases {
            let fields = picker.fields(outcome, at: opened.addingTimeInterval(1))
            XCTAssertEqual(fields["outcome"], .text(outcome.rawValue))
            for key in fields.keys {
                XCTAssertNotNil(key.range(of: "^[a-zA-Z][a-zA-Z0-9]{0,31}$", options: .regularExpression), key)
            }
            XCTAssertNotNil(CartoucheEventReport(id: "3d9b2f5e-0000-4000-8000-000000000001", seq: 1, context: context,
                                                 name: "import.picker", fields: fields))
        }
    }
}
