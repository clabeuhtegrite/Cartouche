//
//  CartoucheMeasuredNoteTests.swift
//  CartoucheCoreTests
//
//  A tester's result of a game's sheet in Cartouche's language
//  (Sources/CartoucheMeasuredNote.swift, Sources/CartoucheTextResults.swift).
//  Of a result Cartouche's game measurements made, the figures of its
//  `measured`, said in the words of Cartouche.xcstrings with the numbers and
//  dates of the player's language, as telemetry/sheets.py says them in
//  English in its note and its engine; the devices an iPad's result counts
//  are iPads; a sheet made before `measured` said how sessions ended badly,
//  or which builds they reported, says what it can. What testers wrote stays
//  theirs, for the iPhone to translate.
//

import Foundation
import XCTest
@testable import CartoucheCore

final class CartoucheMeasuredNoteTests: XCTestCase {
    private static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    private let englishLocale = Locale(identifier: "en_US")
    private let frenchLocale = Locale(identifier: "fr_FR")

    /// The English of the code, which shows where a translation is missing.
    private var english: CartoucheMeasuredWords {
        CartoucheMeasuredWords(text: { _, english in english }, locale: englishLocale)
    }

    /// The words of Cartouche.xcstrings in LANGUAGE.
    private func catalogWords(_ language: String, locale: Locale) throws -> CartoucheMeasuredWords {
        struct Unit: Decodable { let value: String }
        struct Localization: Decodable { let stringUnit: Unit? }
        struct Entry: Decodable { let localizations: [String: Localization]? }
        struct Catalog: Decodable { let strings: [String: Entry] }
        let data = try Data(contentsOf: Self.root.appendingPathComponent("launcher/Sources/Cartouche.xcstrings"))
        let strings = try JSONDecoder().decode(Catalog.self, from: data).strings
        return CartoucheMeasuredWords(text: { key, _ in
            strings[key]?.localizations?[language]?.stringUnit?.value ?? "<no \(language) words for \(key)>"
        }, locale: locale)
    }

    private func french() throws -> CartoucheMeasuredWords {
        try catalogWords("fr", locale: frenchLocale)
    }

    private func measured(_ json: String) throws -> CartoucheMeasured {
        try JSONDecoder().decode(CartoucheMeasured.self, from: Data(json.utf8))
    }

    /// The results of the repository's sheet of Mario Kart World, as the app
    /// reads them.
    private struct Result: Decodable {
        let device: String
        let engine: String
        let notes: [String]?
        let measured: CartoucheMeasured?
    }

    private func repositorysResults() throws -> [Result] {
        let data = try Data(contentsOf: Self.root.appendingPathComponent("catalog/games/0400C3F00006E000.json"))
        struct Sheet: Decodable { let results: [Result] }
        return try JSONDecoder().decode(Sheet.self, from: data).results
    }

    // MARK: Tests

    func testInEnglishItSaysWhatSheetsPyWritesButForTheDates() throws {
        let results = try repositorysResults().filter { $0.measured != nil }
        XCTAssertEqual(results.count, 2)
        let catalogsEnglish = try catalogWords("en", locale: englishLocale)
        for result in results {
            let measured = try XCTUnwrap(result.measured)
            let period = CartoucheMeasuredNote.period(from: measured.from, to: measured.to, locale: englishLocale)
            let written = try XCTUnwrap(result.notes?.first)
                .replacingOccurrences(of: " sessions from \(measured.from) to \(measured.to)", with: " sessions (\(period))")
            let note = CartoucheMeasuredNote.note(measured, device: result.device, words: english)
            XCTAssertEqual(note, written, result.device)
            XCTAssertEqual(CartoucheMeasuredNote.note(measured, device: result.device, words: catalogsEnglish), note)
            XCTAssertEqual(CartoucheMeasuredNote.engine(measured, written: result.engine, words: english), result.engine)
        }
    }

    func testInFrenchEveryWordNumberAndDateIsFrench() throws {
        let french = try french()
        let results = try repositorysResults()
        let period = CartoucheMeasuredNote.period(from: "2026-11-11", to: "2026-11-12", locale: frenchLocale)
        XCTAssertTrue(period.contains("nov.") && !period.contains("2026-11"), period)

        let figures = try XCTUnwrap(results.first { $0.device == "iPhone19,4" && $0.measured != nil }?.measured)
        let note = CartoucheMeasuredNote.note(figures, device: "iPhone19,4", words: french)
        XCTAssertEqual(note, "Mesuré par Cartouche sur 4 iPhone, 9 sessions (\(period))\u{00A0}: 32,2 i/s sur 60 (médiane), "
                       + "83 saccades par minute. 3 sessions se sont mal terminées\u{00A0}: 3 plantages.")
        let noFigures = try XCTUnwrap(results.first { $0.device == "iPhone18,2" }?.measured)
        XCTAssertEqual(CartoucheMeasuredNote.note(noFigures, device: "iPhone18,2", words: french),
                       "Mesuré par Cartouche sur 3 iPhone, 5 sessions (\(period)). 1 session s’est mal terminée\u{00A0}: 1 n’a pas démarré.")
        XCTAssertEqual(CartoucheMeasuredNote.engine(figures, written: "nxnative, its build not reported", words: french),
                       "nxnative, version non indiquée")
        // None of the words of the sheet's English note shows.
        for word in ["Measured", "fps", "stutters", "ended badly", "crashes", "its build"] {
            XCTAssertFalse(note.contains(word), word)
        }
    }

    func testTheResultOfAnIPadCountsIPads() throws {
        let measured = try measured("""
        {"iPhones": 3, "sessions": 5, "from": "2026-11-10", "to": "2026-11-10", "endedBadlyPercent": 0}
        """)
        let day = CartoucheMeasuredNote.day("2026-11-10", locale: englishLocale)
        XCTAssertEqual(CartoucheMeasuredNote.note(measured, device: "iPad15,3", words: english),
                       "Measured by Cartouche on 3 iPads, 5 sessions (\(day)). None ended badly.")
        XCTAssertEqual(CartoucheMeasuredNote.note(measured, device: "iPad15,3", words: try french()),
                       "Mesuré par Cartouche sur 3 iPad, 5 sessions (\(CartoucheMeasuredNote.day("2026-11-10", locale: frenchLocale))). "
                       + "Aucune ne s’est mal terminée.")
        XCTAssertTrue(CartoucheMeasuredNote.note(measured, device: "iPhone18,2", words: english)
            .hasPrefix("Measured by Cartouche on 3 iPhones,"))
    }

    func testHowSessionsEndedBadlyTheMostFirstAsSheetsPyWritesThem() throws {
        let french = try french()
        // sheets.py: "2 sessions ended badly: 1 crash, 1 out of memory."
        let two = try measured("""
        {"iPhones": 3, "sessions": 3, "from": "2026-11-10", "to": "2026-11-10", "endedBadlyPercent": 66.7,
         "endedBadly": {"outOfMemory": 1, "crashes": 1}}
        """)
        XCTAssertTrue(CartoucheMeasuredNote.note(two, device: "iPhone17,2", words: english)
            .hasSuffix(". 2 sessions ended badly: 1 crash, 1 out of memory."))
        XCTAssertTrue(CartoucheMeasuredNote.note(two, device: "iPhone17,2", words: french)
            .hasSuffix(". 2 sessions se sont mal terminées\u{00A0}: 1 plantage, 1 par manque de mémoire."))
        let five = try measured("""
        {"iPhones": 3, "sessions": 9, "from": "2026-11-10", "to": "2026-11-11", "endedBadlyPercent": 55.6,
         "endedBadly": {"crashes": 2, "didNotStart": 2, "outOfMemory": 1}}
        """)
        XCTAssertTrue(CartoucheMeasuredNote.note(five, device: "iPhone17,2", words: english)
            .hasSuffix(". 5 sessions ended badly: 2 did not start, 2 crashes, 1 out of memory."))
        XCTAssertTrue(CartoucheMeasuredNote.note(five, device: "iPhone17,2", words: french)
            .hasSuffix(". 5 sessions se sont mal terminées\u{00A0}: 2 n’ont pas démarré, 2 plantages, 1 par manque de mémoire."))
        let one = try measured("""
        {"iPhones": 3, "sessions": 5, "from": "2026-11-10", "to": "2026-11-11", "endedBadlyPercent": 20,
         "endedBadly": {"didNotStart": 1}}
        """)
        XCTAssertTrue(CartoucheMeasuredNote.note(one, device: "iPhone18,2", words: english)
            .hasSuffix(". 1 session ended badly: 1 did not start."))
        XCTAssertTrue(CartoucheMeasuredNote.note(one, device: "iPhone18,2", words: french)
            .hasSuffix(". 1 session s’est mal terminée\u{00A0}: 1 n’a pas démarré."))
    }

    func testASheetThatDoesNotSayHowSaysHowMany() throws {
        let french = try french()
        // As the sheets made before measured.endedBadly: 33.3 % of 9.
        let old = try measured("""
        {"iPhones": 4, "sessions": 9, "from": "2026-11-11", "to": "2026-11-12", "fps": 32.2, "targetFps": 60,
         "stuttersPerMinute": 83, "endedBadlyPercent": 33.3}
        """)
        XCTAssertTrue(CartoucheMeasuredNote.note(old, device: "iPhone19,4", words: french)
            .hasSuffix(". 3 sessions se sont mal terminées."))
        XCTAssertTrue(CartoucheMeasuredNote.note(old, device: "iPhone19,4", words: english)
            .hasSuffix(". 3 sessions ended badly."))
        let fine = try measured("""
        {"iPhones": 3, "sessions": 4, "from": "2026-11-10", "to": "2026-11-11", "fps": 58, "slowestFps": 52,
         "targetFps": 60, "stuttersPerMinute": 1.4, "endedBadlyPercent": 0}
        """)
        let period = CartoucheMeasuredNote.period(from: "2026-11-10", to: "2026-11-11", locale: englishLocale)
        // sheets.py: "...: 58 fps for 60 (median), 52 fps in the slowest 5% of the time, 1.4 stutters a minute.
        // None ended badly."
        XCTAssertEqual(CartoucheMeasuredNote.note(fine, device: "iPhone19,4", words: english),
                       "Measured by Cartouche on 3 iPhones, 4 sessions (\(period)): 58 fps for 60 (median), "
                       + "52 fps in the slowest 5% of the time, 1.4 stutters a minute. None ended badly.")
        XCTAssertTrue(CartoucheMeasuredNote.note(fine, device: "iPhone19,4", words: french)
            .hasSuffix("58 i/s sur 60 (médiane), 52 i/s dans les 5\u{00A0}% du temps les plus lents, 1,4 saccades par minute. "
                       + "Aucune ne s’est mal terminée."))
        let noTarget = try measured("""
        {"iPhones": 3, "sessions": 4, "from": "2026-11-10", "to": "2026-11-11", "fps": 29.5, "endedBadlyPercent": 0}
        """)
        XCTAssertTrue(CartoucheMeasuredNote.note(noTarget, device: "iPhone19,4", words: french).contains(": 29,5 i/s (médiane)."))
    }

    func testTheBuildsTheSessionsReported() throws {
        let french = try french()
        let base = """
        "iPhones": 3, "sessions": 4, "from": "2026-11-10", "to": "2026-11-11", "endedBadlyPercent": 0
        """
        let three = try measured("{\(base), \"nxnative\": \"6c3aeb3d70a1\", \"otherBuilds\": 2}")
        XCTAssertEqual(CartoucheMeasuredNote.engine(three, written: "nxnative 6c3aeb3d70a1 and 2 other builds", words: english),
                       "nxnative 6c3aeb3d70a1 and 2 other builds")
        XCTAssertEqual(CartoucheMeasuredNote.engine(three, written: "", words: french), "nxnative 6c3aeb3d70a1 et 2 autres versions")
        let two = try measured("{\(base), \"nxnative\": \"6c3aeb3d70a1\", \"otherBuilds\": 1}")
        XCTAssertEqual(CartoucheMeasuredNote.engine(two, written: "", words: english), "nxnative 6c3aeb3d70a1 and 1 other build")
        XCTAssertEqual(CartoucheMeasuredNote.engine(two, written: "", words: french), "nxnative 6c3aeb3d70a1 et 1 autre version")
        let one = try measured("{\(base), \"nxnative\": \"6c3aeb3d70a1\"}")
        XCTAssertEqual(CartoucheMeasuredNote.engine(one, written: "", words: french), "nxnative 6c3aeb3d70a1")
        let none = try measured("{\(base)}")
        XCTAssertEqual(CartoucheMeasuredNote.engine(none, written: "nxnative, its build not reported", words: french),
                       "nxnative, version non indiquée")
        // A sheet made before measured named the builds: its engine is the
        // sheet's own words.
        XCTAssertNil(CartoucheMeasuredNote.engine(none, written: "nxnative 6c3aeb3d70a1 and 2 other builds", words: french))
    }

    func testWhatTestersWroteStaysTheirs() throws {
        let french = try french()
        let results = try repositorysResults()
        // A tester's result: theirs alone, for the iPhone to translate.
        let tester = try XCTUnwrap(results.first { $0.measured == nil })
        let lines = CartoucheMeasuredNote.lines(device: tester.device, engine: tester.engine, notes: tester.notes ?? [],
                                                measured: nil, words: french)
        XCTAssertEqual(lines.engine, .written("nxnative main with the switch2ios patches (0d9b6358)"))
        XCTAssertEqual(lines.notes, [.written("Ran smoothly at 1080p in handheld mode. Memory peak not recorded yet.")])

        // A measured result: Cartouche's words, but for a note a tester
        // added, and an engine an older sheet wrote its own way.
        let measured = try XCTUnwrap(results.first { $0.device == "iPhone19,4" && $0.measured != nil }?.measured)
        let said = CartoucheMeasuredNote.lines(device: "iPhone19,4", engine: "nxnative, its build not reported",
                                               notes: ["Measured by Cartouche on 4 iPhones...", "Tested docked too."],
                                               measured: measured, words: french)
        XCTAssertEqual(said.engine, .said("nxnative, version non indiquée"))
        XCTAssertEqual(said.notes, [.said(CartoucheMeasuredNote.note(measured, device: "iPhone19,4", words: french)),
                                    .written("Tested docked too.")])
        let older = CartoucheMeasuredNote.lines(device: "iPhone19,4", engine: "nxnative 6c3aeb3d70a1 and 2 other builds",
                                                notes: [], measured: measured, words: french)
        XCTAssertEqual(older.engine, .written("nxnative 6c3aeb3d70a1 and 2 other builds"))
        XCTAssertEqual(older.notes.count, 1)
    }

    func testDaysInTheLanguagesWords() {
        let day = CartoucheMeasuredNote.day("2026-11-12", locale: frenchLocale)
        XCTAssertTrue(day.contains("12") && day.contains("nov.") && day.contains("2026"), day)
        XCTAssertNotEqual(CartoucheMeasuredNote.day("2026-11-12", locale: englishLocale), day)
        // Not a day: as it is.
        XCTAssertEqual(CartoucheMeasuredNote.day("soon", locale: frenchLocale), "soon")
        // One day, alone.
        XCTAssertEqual(CartoucheMeasuredNote.period(from: "2026-11-12", to: "2026-11-12", locale: frenchLocale), day)
        XCTAssertNotEqual(CartoucheMeasuredNote.period(from: "2026-11-11", to: "2026-11-12", locale: frenchLocale), day)
    }

    func testFiguresAsSheetsPyRoundsThem() {
        XCTAssertEqual(CartoucheMeasuredNote.number(32.2, locale: frenchLocale), "32,2")
        XCTAssertEqual(CartoucheMeasuredNote.number(32.2, locale: englishLocale), "32.2")
        XCTAssertEqual(CartoucheMeasuredNote.number(83, locale: frenchLocale), "83")
        XCTAssertEqual(CartoucheMeasuredNote.number(1.44, locale: englishLocale), "1.4")
    }
}
