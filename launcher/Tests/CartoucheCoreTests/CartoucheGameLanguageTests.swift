//
//  CartoucheGameLanguageTests.swift
//  CartoucheCoreTests
//
//  The language a game starts in (Sources/CartoucheGameLanguage.swift): the
//  first of the iPhone's languages that the game has, unless the player
//  chose one.
//

import Foundation
import XCTest
@testable import CartoucheCore

final class CartoucheGameLanguageTests: XCTestCase {
    private typealias Language = CartoucheGameLanguage
    private typealias Record = CartoucheGameLanguage.Record

    /// A game's languages as nxnative lists them (its nacp.py order).
    private let european = ["en-US", "en-GB", "ja", "fr", "de", "es-419", "es", "it", "nl", "fr-CA", "pt", "ru", "ko", "zh-Hant", "zh-Hans", "pt-BR"]
    private let japanAndAmerica = ["en-US", "ja"]

    func testReadsTheIPhonesIdentifiers() {
        let traditional = Language.parts(of: "zh-Hant-TW")
        XCTAssertEqual(traditional.language, "zh")
        XCTAssertEqual(traditional.script, "Hant")
        XCTAssertEqual(traditional.region, "TW")
        let british = Language.parts(of: "en_GB")
        XCTAssertEqual(british.language, "en")
        XCTAssertNil(british.script)
        XCTAssertEqual(british.region, "GB")
        XCTAssertEqual(Language.parts(of: "es-419").region, "419")
        XCTAssertEqual(Language.parts(of: "de-DE@calendar=gregorian").region, "DE")
        XCTAssertEqual(Language.parts(of: "FR-ca").language, "fr")
        XCTAssertEqual(Language.parts(of: "FR-ca").region, "CA")
        XCTAssertEqual(Language.parts(of: "sr-latn").script, "Latn")
        let bare = Language.parts(of: "fr")
        XCTAssertNil(bare.script)
        XCTAssertNil(bare.region)
        XCTAssertEqual(Language.parts(of: "").language, "")
    }

    func testEachLanguageStandsForItsSwitchForms() {
        XCTAssertEqual(Language.codes(for: "fr-FR"), ["fr", "fr-CA"])
        XCTAssertEqual(Language.codes(for: "fr-CA"), ["fr-CA", "fr"])
        XCTAssertEqual(Language.codes(for: "fr-BE"), ["fr", "fr-CA"])
        XCTAssertEqual(Language.codes(for: "ja-JP"), ["ja"])
        XCTAssertEqual(Language.codes(for: "de-CH"), ["de"])
        XCTAssertEqual(Language.codes(for: "ko-KR"), ["ko"])
        XCTAssertEqual(Language.codes(for: "nl-BE"), ["nl"])
        XCTAssertEqual(Language.codes(for: "it-IT"), ["it"])
        XCTAssertEqual(Language.codes(for: "ru-RU"), ["ru"])
        // No Switch game is in Polish, Arabic or Swedish.
        XCTAssertEqual(Language.codes(for: "pl-PL"), [])
        XCTAssertEqual(Language.codes(for: "ar"), [])
        XCTAssertEqual(Language.codes(for: "sv-SE"), [])
    }

    func testEnglishAndSpanishGoByTheAmericas() {
        XCTAssertEqual(Language.codes(for: "en-US"), ["en-US", "en-GB"])
        XCTAssertEqual(Language.codes(for: "en"), ["en-US", "en-GB"])
        XCTAssertEqual(Language.codes(for: "en-CA"), ["en-US", "en-GB"])
        XCTAssertEqual(Language.codes(for: "en-GB"), ["en-GB", "en-US"])
        XCTAssertEqual(Language.codes(for: "en-AU"), ["en-GB", "en-US"])
        // English on an iPhone set to France: a European Switch's English.
        XCTAssertEqual(Language.codes(for: "en-FR"), ["en-GB", "en-US"])
        XCTAssertEqual(Language.codes(for: "es-ES"), ["es", "es-419"])
        XCTAssertEqual(Language.codes(for: "es"), ["es", "es-419"])
        XCTAssertEqual(Language.codes(for: "es-MX"), ["es-419", "es"])
        XCTAssertEqual(Language.codes(for: "es-US"), ["es-419", "es"])
        XCTAssertEqual(Language.codes(for: "es-419"), ["es-419", "es"])
        XCTAssertEqual(Language.codes(for: "pt-BR"), ["pt-BR", "pt"])
        XCTAssertEqual(Language.codes(for: "pt"), ["pt-BR", "pt"])
        XCTAssertEqual(Language.codes(for: "pt-PT"), ["pt", "pt-BR"])
    }

    func testChineseGoesByItsScript() {
        XCTAssertEqual(Language.codes(for: "zh-Hans-CN"), ["zh-Hans", "zh-CN", "zh-Hant", "zh-TW"])
        XCTAssertEqual(Language.codes(for: "zh-Hant-TW"), ["zh-Hant", "zh-TW", "zh-Hans", "zh-CN"])
        XCTAssertEqual(Language.codes(for: "zh-Hant-HK"), ["zh-Hant", "zh-TW", "zh-Hans", "zh-CN"])
        XCTAssertEqual(Language.codes(for: "zh-Hans-HK"), ["zh-Hans", "zh-CN", "zh-Hant", "zh-TW"])
        // Without a script, by the region.
        XCTAssertEqual(Language.codes(for: "zh-TW").first, "zh-Hant")
        XCTAssertEqual(Language.codes(for: "zh-HK").first, "zh-Hant")
        XCTAssertEqual(Language.codes(for: "zh-CN").first, "zh-Hans")
        XCTAssertEqual(Language.codes(for: "zh").first, "zh-Hans")
        // Cantonese reads Traditional Chinese.
        XCTAssertEqual(Language.codes(for: "yue-Hant-HK").first, "zh-Hant")
        XCTAssertEqual(Language.codes(for: "yue-Hans-CN").first, "zh-Hans")
    }

    func testTheFirstOfTheIPhonesLanguagesTheGameHas() {
        XCTAssertEqual(Language.best(for: ["fr-FR", "en-FR"], among: european), "fr")
        XCTAssertEqual(Language.best(for: ["en-FR", "fr-FR"], among: european), "en-GB")
        // No French: the iPhone's next language, in the form the game has.
        XCTAssertEqual(Language.best(for: ["fr-FR", "en-FR"], among: japanAndAmerica), "en-US")
        XCTAssertEqual(Language.best(for: ["fr-CA"], among: ["en-US", "fr"]), "fr")
        XCTAssertEqual(Language.best(for: ["pl-PL", "de-DE"], among: european), "de")
        XCTAssertEqual(Language.best(for: ["es-MX"], among: ["es", "en-GB"]), "es")
        // A Switch set to Traditional Chinese shows a game's Simplified
        // Chinese rather than its English.
        XCTAssertEqual(Language.best(for: ["zh-Hant-TW", "en-TW"], among: ["en-US", "zh-Hans"]), "zh-Hans")
        // Older games' lists may spell Chinese zh-CN and zh-TW.
        XCTAssertEqual(Language.best(for: ["zh-Hant-TW"], among: ["zh-CN", "zh-TW"]), "zh-TW")
        XCTAssertEqual(Language.best(for: ["EN-gb"], among: ["en-GB"]), "en-GB")
        // None of them: nil, and the game keeps its own.
        XCTAssertNil(Language.best(for: ["pl-PL"], among: japanAndAmerica))
        XCTAssertNil(Language.best(for: ["fr-FR"], among: japanAndAmerica))
        XCTAssertNil(Language.best(for: [], among: european))
    }

    func testAGameFollowsTheIPhoneAtFirst() {
        let record = Language.beforeStart(Record(), preferred: ["fr-FR", "en-FR"], offered: european, gameDefault: "en-US")
        XCTAssertEqual(record, Record(saved: "fr", source: .iPhone, iPhone: "fr"))
        // Saved even when it is the game's own language: a later build,
        // packed with another, starts in it too.
        let own = Language.beforeStart(Record(), preferred: ["fr-FR"], offered: european, gameDefault: "fr")
        XCTAssertEqual(own, Record(saved: "fr", source: .iPhone, iPhone: "fr"))
    }

    func testAGameWithNoneOfTheIPhonesLanguagesKeepsItsOwn() {
        let record = Language.beforeStart(Record(), preferred: ["pl-PL"], offered: japanAndAmerica, gameDefault: "ja")
        XCTAssertEqual(record, Record(saved: "ja", source: .iPhone, iPhone: "ja"))
    }

    func testALanguageSavedBeforeCartoucheChoseIsThePlayers() {
        // Chosen on nxnative's screen, or in Cartouche's settings before it
        // followed the iPhone.
        let record = Language.beforeStart(Record(saved: "ja"), preferred: ["fr-FR"], offered: european, gameDefault: "en-US")
        XCTAssertEqual(record, Record(saved: "ja", source: .player, iPhone: nil))
        // One the game no longer has is no choice: the iPhone's.
        let gone = Language.beforeStart(Record(saved: "ko"), preferred: ["fr-FR"], offered: japanAndAmerica + ["fr"],
                                        gameDefault: "en-US")
        XCTAssertEqual(gone, Record(saved: "fr", source: .iPhone, iPhone: "fr"))
    }

    func testTheGameFollowsTheIPhonesLanguageWhenItChanges() {
        let before = Record(saved: "fr", source: .iPhone, iPhone: "fr")
        XCTAssertEqual(Language.beforeStart(before, preferred: ["de-DE", "fr-FR"], offered: european, gameDefault: "en-US"),
                       Record(saved: "de", source: .iPhone, iPhone: "de"))
        XCTAssertEqual(Language.beforeStart(before, preferred: ["fr-FR"], offered: european, gameDefault: "en-US"), before)
    }

    func testAChangeOnNxnativesScreenIsThePlayers() {
        let before = Record(saved: "fr", source: .iPhone, iPhone: "fr")
        // Another language chosen on nxnative's screen.
        XCTAssertEqual(Language.beforeStart(Record(saved: "ja", source: .iPhone, iPhone: "fr"), preferred: ["fr-FR"],
                                            offered: european, gameDefault: "en-US"),
                       Record(saved: "ja", source: .player, iPhone: nil))
        // The game's own chosen there: nxnative then saves nothing.
        XCTAssertEqual(Language.beforeStart(Record(saved: nil, source: .iPhone, iPhone: "fr"), preferred: ["fr-FR"],
                                            offered: european, gameDefault: "en-US"),
                       Record(saved: nil, source: .player, iPhone: nil))
        // Its Play without a change: nxnative saves nothing for the game's
        // own language, which is still Cartouche's choice.
        XCTAssertEqual(Language.beforeStart(Record(saved: nil, source: .iPhone, iPhone: "fr"), preferred: ["fr-FR"],
                                            offered: european, gameDefault: "fr"),
                       Record(saved: "fr", source: .iPhone, iPhone: "fr"))
        XCTAssertEqual(Language.beforeStart(before, preferred: ["fr-FR"], offered: european, gameDefault: "fr"), before)
    }

    func testANewBuildOfTheGameIsNoChangeOfThePlayers() {
        let before = Record(saved: "fr", source: .iPhone, iPhone: "fr")
        // Packed with another language: still the iPhone's.
        XCTAssertEqual(Language.beforeStart(before, preferred: ["fr-FR"], offered: european, gameDefault: "ja"), before)
        // Without that language: the iPhone's next one the game has.
        XCTAssertEqual(Language.beforeStart(before, preferred: ["fr-FR", "en-FR"], offered: japanAndAmerica, gameDefault: "ja"),
                       Record(saved: "en-US", source: .iPhone, iPhone: "en-US"))
    }

    func testThePlayersChoiceStays() {
        let chosen = Language.chosen("en-US")
        XCTAssertEqual(chosen, Record(saved: "en-US", source: .player, iPhone: nil))
        XCTAssertEqual(Language.beforeStart(chosen, preferred: ["fr-FR"], offered: european, gameDefault: "en-US"), chosen)
        XCTAssertEqual(Language.beforeStart(Record(saved: nil, source: .player), preferred: ["fr-FR"], offered: european,
                                            gameDefault: "en-US"),
                       Record(saved: nil, source: .player))
        // Following the iPhone again.
        XCTAssertEqual(Language.following(["fr-FR"], offered: european, gameDefault: "en-US"),
                       Record(saved: "fr", source: .iPhone, iPhone: "fr"))
    }

    func testTheLanguageTheGameStartsIn() {
        XCTAssertEqual(Language.language(of: Record(saved: "fr"), offered: european, gameDefault: "en-US"), "fr")
        XCTAssertEqual(Language.language(of: Record(saved: "pl"), offered: european, gameDefault: "en-US"), "en-US")
        XCTAssertEqual(Language.language(of: Record(), offered: european, gameDefault: "en-US"), "en-US")
    }
}
