//
//  CartoucheReleaseNotesTests.swift
//  CartoucheCoreTests
//
//  The release notes Cartouche carries (Sources/CartoucheReleaseNotes.swift):
//  read as app/releases/ writes them, in the player's language when they are
//  written in it, and shown once after an update, never on a first install.
//

import Foundation
import XCTest
@testable import CartoucheCore

final class CartoucheReleaseNotesTests: XCTestCase {
    /// 0.12.1's notes, as app/releases/0.12.1.md has them.
    private let notes0121 = """
    A game behind the console shows on your TV, and Cartouche installed with your own certificate opens again.

    - TV mode, first version: while a game runs behind the console, plug your iPhone into a TV with a USB-C to HDMI cable, or use AirPlay, and the TV shows the game alone while your iPhone keeps the controls.
    - Press Home and the TV shows the game's card, paused, until you resume.
    - If your TV shows something else, send System > Report a problem, which now says what the TV did.
    - Your own certificate: Cartouche installed with your own certificate no longer closes as soon as you open it. If yours did, install it again the same way, since that version could not update itself. Thanks to javi11, who found and fixed it.
    - Games: Mario Kart World's sheet adds what Cartouche measured on players' iPhones in the 4 weeks before November 13.
    - Cartouche Installer 0.2.1, for Mac and Windows: the two-factor code and the choice of certificates to revoke can no longer be lost on the way from its window, which made the sign-in fail after two minutes.

    """

    private var folders: [URL] = []
    private var suites: [String] = []

    override func tearDown() {
        for folder in folders { try? FileManager.default.removeItem(at: folder) }
        for suite in suites { UserDefaults.standard.removePersistentDomain(forName: suite) }
        super.tearDown()
    }

    // MARK: Reading the notes

    func testTheNotesOfAVersionReadAsAppReleasesWritesThem() throws {
        let notes = try XCTUnwrap(CartoucheReleaseNotes(version: "0.12.1", text: notes0121))
        XCTAssertEqual(notes.version, "0.12.1")
        XCTAssertEqual(notes.summary, "A game behind the console shows on your TV, and Cartouche installed with your own certificate opens again.")
        XCTAssertEqual(notes.items.map(\.topic), ["TV mode, first version:", nil, nil, "Your own certificate:", "Games:", nil])
        XCTAssertEqual(notes.items[0].text.prefix(38), "while a game runs behind the console, ")
        XCTAssertEqual(notes.items[1].text, "Press Home and the TV shows the game's card, paused, until you resume.")
        // Too long for a topic: the words before the colon belong to the item.
        XCTAssertTrue(notes.items[5].text.hasPrefix("Cartouche Installer 0.2.1, for Mac and Windows: the two-factor code"))
    }

    func testATopicIsAFewWordsBeforeAColonAndASpace() {
        let item = CartoucheReleaseNotes.item
        XCTAssertEqual(item("Games: an IPA installs."), .init(topic: "Games:", text: "an IPA installs."))
        // French puts a space, often a no-break one, before the colon.
        XCTAssertEqual(item("Jeux : un IPA s’installe."), .init(topic: "Jeux :", text: "un IPA s’installe."))
        XCTAssertEqual(item("Jeux\u{00A0}: un IPA."), .init(topic: "Jeux\u{00A0}:", text: "un IPA."))
        XCTAssertEqual(item("Votre propre certificat\u{202F}: il s’ouvre."), .init(topic: "Votre propre certificat\u{202F}:", text: "il s’ouvre."))
        // A time or an address is no topic's colon; a later one can be.
        XCTAssertEqual(item("Renewals at 10:30 go on."), .init(topic: nil, text: "Renewals at 10:30 go on."))
        XCTAssertEqual(item("At 10:30 sharp: renewals."), .init(topic: "At 10:30 sharp:", text: "renewals."))
        // More than four words, more than thirty characters, or a sentence:
        // the item's own words.
        XCTAssertNil(item("A game controller drives every screen: A plays.").topic)
        XCTAssertNil(item("Setup is done for good now: nothing to do.").topic)
        XCTAssertNil(item("It does not. Games: none.").topic)
        // Nothing after the colon, or nothing before it.
        XCTAssertNil(item("Games:").topic)
        XCTAssertNil(item(": games.").topic)
    }

    func testLinesThatCarryOnASummaryOrAnItemJoinIt() throws {
        let text = "First line\nof the summary.\n\nA second paragraph.\n\n- An item\n  that goes on.\n- Games: another.\n\nA paragraph after the items.\n"
        let notes = try XCTUnwrap(CartoucheReleaseNotes(version: "1.0.0", text: text))
        XCTAssertEqual(notes.summary, "First line of the summary.\n\nA second paragraph.")
        XCTAssertEqual(notes.items, [.init(topic: nil, text: "An item that goes on."), .init(topic: "Games:", text: "another."),
                                     .init(topic: nil, text: "A paragraph after the items.")])
        // Windows line ends read the same: one line end, not a blank line.
        let crlf = try XCTUnwrap(CartoucheReleaseNotes(version: "1.0.0", text: "Summary\r\ngoes on.\r\n\r\n- One\r\n  more.\r\n- Two.\r\n"))
        XCTAssertEqual(crlf.summary, "Summary goes on.")
        XCTAssertEqual(crlf.items.map(\.text), ["One more.", "Two."])
    }

    func testFrenchMarksStayWithTheWordBeforeThem() throws {
        let french = try XCTUnwrap(CartoucheReleaseNotes(
            version: "0.12.2", text: "La télé montre le jeu : enfin !\n\n- Jeux : « Mario Kart World » démarre ; prêt ?\n"))
        XCTAssertEqual(french.summary, "La télé montre le jeu\u{00A0}: enfin\u{00A0}!")
        XCTAssertEqual(french.items, [.init(topic: "Jeux\u{00A0}:",
                                            text: "«\u{00A0}Mario Kart World\u{00A0}» démarre\u{00A0}; prêt\u{00A0}?")])
        // English puts no space there: its notes stay as they are.
        let english = try XCTUnwrap(CartoucheReleaseNotes(version: "0.12.2", text: "TV: at last!\n\n- Games: ready? Yes; go.\n"))
        XCTAssertEqual(english.summary, "TV: at last!")
        XCTAssertEqual(english.items, [.init(topic: "Games:", text: "ready? Yes; go.")])
    }

    func testOnAnIPadTheNotesCallItTheIPadAsCartouchesWordsDo() throws {
        let english = try XCTUnwrap(CartoucheReleaseNotes(
            version: "0.12.2", text: "Cartouche keeps your iPhone signed.\n\n- Renewal: this iPhone renews itself.\n- Games: an iPhone 15 Pro plays them.\n"))
        let onIPad = english.applying(CartoucheDeviceWords.onIPad)
        XCTAssertEqual(onIPad.version, "0.12.2")
        XCTAssertEqual(onIPad.summary, "Cartouche keeps your iPad signed.")
        // A model of iPhone stays one.
        XCTAssertEqual(onIPad.items, [.init(topic: "Renewal:", text: "this iPad renews itself."),
                                      .init(topic: "Games:", text: "an iPhone 15 Pro plays them.")])
        let french = try XCTUnwrap(CartoucheReleaseNotes(
            version: "0.12.2", text: "Cartouche se renouvelle sur votre iPhone.\n\n- Jeux : l’iPhone Duo et cet iPhone.\n"))
        let frenchOnIPad = french.applying(CartoucheDeviceWords.onIPad)
        XCTAssertEqual(frenchOnIPad.summary, "Cartouche se renouvelle sur votre iPad.")
        XCTAssertEqual(frenchOnIPad.items, [.init(topic: "Jeux\u{00A0}:", text: "l’iPhone Duo et cet iPad.")])
    }

    func testNotesThatSayNothingOrOfNoVersionAreNone() {
        XCTAssertNil(CartoucheReleaseNotes(version: "1.0.0", text: ""))
        XCTAssertNil(CartoucheReleaseNotes(version: "1.0.0", text: "\n  \n\n"))
        XCTAssertNil(CartoucheReleaseNotes(version: "1.0.0-beta", text: notes0121))
        XCTAssertNil(CartoucheReleaseNotes(version: "README", text: notes0121))
    }

    func testTheNotesInTheAppComeNewestFirstInThePlayersLanguage() throws {
        let folder = try makeFolder([
            "0.2.0.md": "Two.\n\n- Games: two.\n",
            "0.10.0.md": "Ten.\n\n- Games: ten.\n",
            "0.10.0.fr.md": "Dix.\n\n- Jeux : dix.\n",
            "0.9.1.md": "Nine.\n\n- Nine.\n",
            // A translation that says nothing gives way to the English.
            "0.9.1.fr.md": "\n",
            "0.9.0.fr-CA.md": "Neuf, au Canada.\n",
            "0.9.0.md": "Nine zero.\n",
            // A translation without its English is left out.
            "0.11.0.fr.md": "Onze.\n",
            "README.md": "# Releases\n",
            "notes.txt": "Not a version's notes.\n",
        ])
        let french = CartoucheReleaseNotes.all(in: folder, language: "fr")
        XCTAssertEqual(french.map(\.version), ["0.10.0", "0.9.1", "0.9.0", "0.2.0"])
        XCTAssertEqual(french.map(\.summary), ["Dix.", "Nine.", "Nine zero.", "Two."])
        XCTAssertEqual(french[0].items, [.init(topic: "Jeux\u{00A0}:", text: "dix.")])
        XCTAssertEqual(CartoucheReleaseNotes.all(in: folder, language: "fr-CA").map(\.summary), ["Dix.", "Nine.", "Neuf, au Canada.", "Two."])
        for english in ["en", "en-GB", "Base", nil] {
            XCTAssertEqual(CartoucheReleaseNotes.all(in: folder, language: english).map(\.summary), ["Ten.", "Nine.", "Nine zero.", "Two."],
                           "language \(english ?? "none")")
        }
        XCTAssertEqual(CartoucheReleaseNotes.all(in: folder, language: "de").map(\.summary), ["Ten.", "Nine.", "Nine zero.", "Two."])
        XCTAssertEqual(CartoucheReleaseNotes.all(in: folder.appendingPathComponent("missing"), language: "fr"), [])
    }

    // MARK: What the player sees as Cartouche opens

    private let versions = ["0.13.0", "0.12.2", "0.12.1", "0.12.0", "0.11.2", "0.11.1"]

    private var allNotes: [CartoucheReleaseNotes] {
        versions.compactMap { CartoucheReleaseNotes(version: $0, text: "Cartouche \($0).\n\n- Games: new in \($0).\n") }
    }

    func testANewInstallShowsNoNotesAndKeepsItsVersionAsSeen() {
        let record = makeRecord()
        XCTAssertEqual(record.notesToShow(running: "0.12.2", among: allNotes), [])
        XCTAssertEqual(record.seen, "0.12.2")
        // Nor the next time it opens.
        XCTAssertEqual(record.notesToShow(running: "0.12.2", among: allNotes), [])
    }

    func testAnUpdateShowsTheNotesOfTheNewVersionUntilThePlayerClosesThem() {
        let record = makeRecord(seen: "0.12.1")
        XCTAssertEqual(record.notesToShow(running: "0.12.2", among: allNotes).map(\.version), ["0.12.2"])
        // Cartouche closed before the player closed them: they show again.
        XCTAssertEqual(record.notesToShow(running: "0.12.2", among: allNotes).map(\.version), ["0.12.2"])
        record.noteSeen("0.12.2")
        XCTAssertEqual(record.seen, "0.12.2")
        XCTAssertEqual(record.notesToShow(running: "0.12.2", among: allNotes), [])
    }

    func testAnUpdateOverSeveralVersionsShowsEachNewestFirstThreeAtMost() {
        XCTAssertEqual(makeRecord(seen: "0.12.0").notesToShow(running: "0.13.0", among: allNotes).map(\.version),
                       ["0.13.0", "0.12.2", "0.12.1"])
        XCTAssertEqual(makeRecord(seen: "0.11.1").notesToShow(running: "0.13.0", among: allNotes).map(\.version),
                       ["0.13.0", "0.12.2", "0.12.1"])
        // Never a version above the one installed.
        XCTAssertEqual(makeRecord(seen: "0.11.2").notesToShow(running: "0.12.1", among: allNotes).map(\.version),
                       ["0.12.1", "0.12.0"])
    }

    func testAnUpdateFromACartoucheOlderThanTheRecordShowsTheNewVersionsNotesAlone() {
        // What an older Cartouche left: the guide done, an update it started,
        // and so on; a new install has none of it.
        for key in CartoucheWhatsNewRecord.earlierKeys {
            let record = makeRecord()
            record.defaults.set(key == "Cartouche.update.pending" ? "0.12.2" : true, forKey: key)
            XCTAssertEqual(record.notesToShow(running: "0.12.2", among: allNotes).map(\.version), ["0.12.2"], key)
            // Cartouche closed before the player closed them, and the update
            // it started is gone from the preferences: they show again.
            XCTAssertEqual(record.seen, "0.12.1", key)
            record.defaults.removeObject(forKey: key)
            XCTAssertEqual(record.notesToShow(running: "0.12.2", among: allNotes).map(\.version), ["0.12.2"], key)
            record.noteSeen("0.12.2")
            XCTAssertEqual(record.notesToShow(running: "0.12.2", among: allNotes), [], key)
        }
        // Below the oldest notes Cartouche carries, any version stands as
        // seen before.
        let oldest = makeRecord()
        oldest.defaults.set(true, forKey: "Cartouche.guide.finished")
        XCTAssertEqual(oldest.notesToShow(running: "0.11.1", among: allNotes).map(\.version), ["0.11.1"])
        XCTAssertEqual(oldest.seen, "0")
        XCTAssertEqual(oldest.notesToShow(running: "0.11.1", among: allNotes).map(\.version), ["0.11.1"])
        // Another key of Cartouche's, which an install writes as it opens,
        // tells nothing.
        let record = makeRecord()
        record.defaults.set(true, forKey: "Cartouche.keepConsoleOpen")
        XCTAssertEqual(record.notesToShow(running: "0.12.2", among: allNotes), [])
    }

    func testAVersionWithoutItsOwnNotesShowsNone() {
        // A build between two releases: the notes of 0.12.1 are not 0.12.3's.
        let record = makeRecord(seen: "0.12.0")
        XCTAssertEqual(record.notesToShow(running: "0.12.3", among: allNotes), [])
        XCTAssertEqual(record.seen, "0.12.3")
        let older = makeRecord()
        older.defaults.set(true, forKey: "Cartouche.guide.finished")
        XCTAssertEqual(older.notesToShow(running: "0.12.3", among: allNotes), [])
    }

    func testTheSameOrAnOlderVersionShowsNothingAndLeavesTheRecord() {
        let same = makeRecord(seen: "0.12.2")
        XCTAssertEqual(same.notesToShow(running: "0.12.2", among: allNotes), [])
        // An older Cartouche installed again, then the newer one again: its
        // notes were seen already.
        let older = makeRecord(seen: "0.12.2")
        XCTAssertEqual(older.notesToShow(running: "0.12.1", among: allNotes), [])
        XCTAssertEqual(older.seen, "0.12.2")
        XCTAssertEqual(older.notesToShow(running: "0.12.2", among: allNotes), [])
    }

    func testVersionsAreTheSameNumberByNumber() {
        XCTAssertTrue(CartoucheVersion.isSame("0.12.1", "0.12.1"))
        XCTAssertTrue(CartoucheVersion.isSame("1.2", "1.2.0"))
        XCTAssertFalse(CartoucheVersion.isSame("0.12.1", "0.12.10"))
        XCTAssertFalse(CartoucheVersion.isSame("beta", "beta"))
    }

    // MARK: Helpers

    private func makeFolder(_ files: [String: String]) throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("CartoucheReleases-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for (name, text) in files {
            try Data(text.utf8).write(to: folder.appendingPathComponent(name))
        }
        folders.append(folder)
        return folder
    }

    private func makeRecord(seen: String? = nil) -> CartoucheWhatsNewRecord {
        let suite = "CartoucheReleaseNotesTests-\(UUID().uuidString)"
        suites.append(suite)
        let defaults = UserDefaults(suiteName: suite)!
        if let seen { defaults.set(seen, forKey: CartoucheWhatsNewRecord.seenKey) }
        return CartoucheWhatsNewRecord(defaults: defaults)
    }
}
