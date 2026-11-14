//
//  CartoucheGameNamesTests.swift
//  CartoucheCoreTests
//
//  The names Siri and Shortcuts know the player's games by
//  (Sources/CartoucheGameNames.swift): the shorter names a player says, kept
//  away from the other games', and what a word typed in Shortcuts finds.
//

import XCTest
@testable import CartoucheCore

final class CartoucheGameNamesTests: XCTestCase {
    private let mario = "Mario Kart World"
    private let bananza = "Donkey Kong Bananza"
    private let ocarina = "The Legend of Zelda: Ocarina of Time"
    private let awakening = "The Legend of Zelda: Link's Awakening"

    func testAGameOfThreeWordsGoesByItsFirstTwo() {
        XCTAssertEqual(CartoucheGameNames.synonyms(of: mario, among: [mario, bananza]), ["Mario Kart"])
        XCTAssertEqual(CartoucheGameNames.synonyms(of: bananza, among: [mario, bananza]), ["Donkey Kong"])
        XCTAssertEqual(CartoucheGameNames.synonyms(of: "Xenoblade Chronicles 3", among: []), ["Xenoblade Chronicles"])
    }

    func testAColonOrADashCutsTheNameInTwo() {
        XCTAssertEqual(CartoucheGameNames.synonyms(of: ocarina, among: [ocarina]),
                       ["The Legend of Zelda", "Legend of Zelda", "Ocarina of Time", "Legend of Zelda: Ocarina of Time"])
        XCTAssertEqual(CartoucheGameNames.synonyms(of: "Metroid Prime 4: Beyond", among: []), ["Metroid Prime 4", "Beyond"])
        XCTAssertEqual(CartoucheGameNames.synonyms(of: "Hades – Supergiant Edition", among: []), ["Hades", "Supergiant Edition"])
        // A dash inside a word cuts nothing.
        XCTAssertEqual(CartoucheGameNames.synonyms(of: "Pokémon Legends Z-A", among: []), ["Pokémon Legends"])
    }

    func testANameTheOtherGamesCouldAlsoTakeGoesToNone() {
        // Both Zeldas could be "The Legend of Zelda": Siri would have to ask.
        XCTAssertEqual(CartoucheGameNames.synonyms(of: ocarina, among: [ocarina, awakening, mario]),
                       ["Ocarina of Time", "Legend of Zelda: Ocarina of Time"])
        XCTAssertEqual(CartoucheGameNames.synonyms(of: awakening, among: [ocarina, awakening, mario]),
                       ["Link's Awakening", "Legend of Zelda: Link's Awakening"])
        // Nor one that is another game's own name.
        XCTAssertEqual(CartoucheGameNames.synonyms(of: "Super Mario Odyssey", among: ["Super Mario"]), [])
        XCTAssertEqual(CartoucheGameNames.synonyms(of: "Super Mario Odyssey", among: ["Super Mario Galaxy"]), [])
    }

    func testANameAloneOrTooShortGivesNothing() {
        XCTAssertEqual(CartoucheGameNames.synonyms(of: "Splatoon 3", among: []), [])
        XCTAssertEqual(CartoucheGameNames.synonyms(of: "Tetris", among: []), [])
        XCTAssertEqual(CartoucheGameNames.synonyms(of: "The Witness", among: []), ["Witness"])
        // An article alone, or a single letter, is no name.
        XCTAssertEqual(CartoucheGameNames.synonyms(of: "The: Game", among: []), ["Game"])
        XCTAssertEqual(CartoucheGameNames.synonyms(of: "X: Origins", among: []), ["Origins"])
        XCTAssertEqual(CartoucheGameNames.synonyms(of: "L'Aventure de Toto", among: []), ["Aventure de Toto"])
        // Nor a name that ends on a word that only joins two others.
        XCTAssertEqual(CartoucheGameNames.synonyms(of: "Tales of Arise", among: []), [])
        XCTAssertEqual(CartoucheGameNames.synonyms(of: "Kirby and Friends", among: []), [])
    }

    func testASearchFindsTheGamesWhoseWordsItBegins() {
        XCTAssertTrue(CartoucheGameNames.matches("mario kart", name: mario))
        XCTAssertTrue(CartoucheGameNames.matches("Mario", name: mario))
        XCTAssertTrue(CartoucheGameNames.matches("kart wor", name: mario))
        XCTAssertTrue(CartoucheGameNames.matches("ZELDA", name: ocarina))
        XCTAssertTrue(CartoucheGameNames.matches("links awakening", name: awakening))
        XCTAssertTrue(CartoucheGameNames.matches("link’s", name: awakening))
        XCTAssertTrue(CartoucheGameNames.matches("pokemon", name: "Pokémon Legends Z-A"))
        XCTAssertFalse(CartoucheGameNames.matches("zelda", name: mario))
        XCTAssertFalse(CartoucheGameNames.matches("art", name: mario), "a word begins a word, never ends one")
        XCTAssertFalse(CartoucheGameNames.matches("", name: mario))
        XCTAssertFalse(CartoucheGameNames.matches("  ", name: mario))
    }

    func testASearchFindsAGameByAShorterNameToo() {
        XCTAssertTrue(CartoucheGameNames.matches("dk", name: "Donkey Kong Bananza", synonyms: ["DK Bananza"]))
        XCTAssertFalse(CartoucheGameNames.matches("dk", name: "Donkey Kong Bananza"))
    }

    func testNamesCompareWithoutCaseAccentsOrPunctuation() {
        XCTAssertEqual(CartoucheGameNames.folded("  Pokémon:  LEGENDS Z-A "), "pokemon legends z a")
        XCTAssertEqual(CartoucheGameNames.folded("Link’s Awakening"), CartoucheGameNames.folded("Links Awakening"))
    }
}
