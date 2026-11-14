//
//  CartoucheTranslationsTests.swift
//  CartoucheCoreTests
//
//  The iPhone's translations of the games' summaries, kept so that a sheet
//  shows one as it opens the next times, rather than wait a few seconds
//  again for the iPhone to translate it (Sources/CartoucheTranslations.swift):
//  kept for their text and language, in a file that outlives Cartouche, the
//  oldest going beyond the limit.
//

import Foundation
import XCTest
@testable import CartoucheCore

final class CartoucheTranslationsTests: XCTestCase {
    private let summary = "Two Yarnys, tied together, take on a world of their own."
    private let french = "Deux Yarnys, liés l'un à l'autre, partent à la découverte d'un monde."

    private func keptFile() -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        return folder.appendingPathComponent("Cartouche/SummaryTranslations.json")
    }

    func testATranslationShowsAgainForItsTextAndLanguageOnly() {
        let translations = CartoucheTranslations(file: keptFile())
        XCTAssertNil(translations.translation(of: summary, into: "fr"))
        translations.keep(french, of: summary, into: "fr")
        // The next sheet of the game shows it, without asking the iPhone.
        XCTAssertEqual(translations.translation(of: summary, into: "fr"), french)
        // In another language, or once IGDB's summary changed, the iPhone
        // translates again.
        XCTAssertNil(translations.translation(of: summary, into: "de"))
        XCTAssertNil(translations.translation(of: summary + " Together again.", into: "fr"))
    }

    func testTranslationsAreKeptWhenCartoucheStartsAgain() {
        let file = keptFile()
        CartoucheTranslations(file: file).keep(french, of: summary, into: "fr")
        // Another Cartouche, started later, after a game in its place.
        XCTAssertEqual(CartoucheTranslations(file: file).translation(of: summary, into: "fr"), french)
        XCTAssertEqual(CartoucheTranslations.kept(at: file),
                       [CartoucheTranslation(language: "fr", text: summary, translation: french)])
    }

    func testTheOldestGoBeyondTheLimit() {
        let file = keptFile()
        let translations = CartoucheTranslations(file: file, limit: 2)
        translations.keep("Un", of: "One", into: "fr")
        translations.keep("Deux", of: "Two", into: "fr")
        // Made again, the first is the latest.
        translations.keep("Une", of: "One", into: "fr")
        translations.keep("Trois", of: "Three", into: "fr")
        XCTAssertNil(translations.translation(of: "Two", into: "fr"))
        XCTAssertEqual(translations.translation(of: "One", into: "fr"), "Une")
        XCTAssertEqual(translations.translation(of: "Three", into: "fr"), "Trois")
        XCTAssertEqual(CartoucheTranslations.kept(at: file).map(\.text), ["One", "Three"])
        // Read with a lower limit, the latest stay.
        let fewer = CartoucheTranslations(file: file, limit: 1)
        XCTAssertNil(fewer.translation(of: "One", into: "fr"))
        XCTAssertEqual(fewer.translation(of: "Three", into: "fr"), "Trois")
    }

    func testWhatIsNoTranslationIsNotKept() {
        let file = keptFile()
        let translations = CartoucheTranslations(file: file)
        translations.keep("  \n", of: summary, into: "fr")
        translations.keep(french, of: " ", into: "fr")
        translations.keep(french, of: summary, into: "")
        translations.keep(french, of: summary, into: "../fr")
        translations.keep(String(repeating: "a", count: CartoucheTranslations.longest + 1), of: summary, into: "fr")
        XCTAssertNil(translations.translation(of: summary, into: "fr"))
        XCTAssertNil(translations.translation(of: summary, into: ""))
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    }

    func testAKeptFileThatIsNotAsCartoucheWritesItGivesNothingWrong() throws {
        let file = keptFile()
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("not a list".utf8).write(to: file)
        XCTAssertEqual(CartoucheTranslations.kept(at: file), [])
        XCTAssertNil(CartoucheTranslations(file: file).translation(of: summary, into: "fr"))

        let odd = """
        {"schema": 1, "translations": [
          {"language": "fr", "text": "One", "translation": ""},
          {"language": "", "text": "Two", "translation": "Deux"},
          {"language": "fr", "text": "Three", "translation": "Trois"}
        ]}
        """
        try Data(odd.utf8).write(to: file)
        XCTAssertEqual(CartoucheTranslations.kept(at: file), [CartoucheTranslation(language: "fr", text: "Three", translation: "Trois")])

        // Another schema, a later Cartouche's: nothing of it.
        try Data(odd.replacingOccurrences(of: "\"schema\": 1", with: "\"schema\": 2").utf8).write(to: file)
        XCTAssertEqual(CartoucheTranslations.kept(at: file), [])
    }

    func testATranslationShowsWhileCartoucheRunsWhenItCannotBeWritten() throws {
        // The folder of the file is a file.
        let file = keptFile()
        let folder = file.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: folder.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("a file".utf8).write(to: folder)
        let translations = CartoucheTranslations(file: file)
        translations.keep(french, of: summary, into: "fr")
        XCTAssertEqual(translations.translation(of: summary, into: "fr"), french)
        XCTAssertEqual(CartoucheTranslations.kept(at: file), [])
    }

    func testTranslationsAreKeptFromAnyThread() {
        // A sheet reads them on the main thread while the iPhone's
        // translations are kept from their own tasks.
        let file = keptFile()
        let translations = CartoucheTranslations(file: file)
        DispatchQueue.concurrentPerform(iterations: 40) { index in
            translations.keep("Résumé \(index)", of: "Summary \(index)", into: "fr")
            XCTAssertEqual(translations.translation(of: "Summary \(index)", into: "fr"), "Résumé \(index)")
        }
        XCTAssertEqual(CartoucheTranslations.kept(at: file).count, 40)
    }
}
