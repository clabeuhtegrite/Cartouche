//
//  CartoucheGameFitTests.swift
//  CartoucheCoreTests
//
//  How a game fits this iPhone (Sources/CartoucheGameFit.swift): nxnative
//  refuses a GPU that cannot read BC-compressed textures, the A16's and
//  older, for every game, with a sheet or without.
//

import XCTest
@testable import CartoucheCore

final class CartoucheGameFitTests: XCTestCase {
    /// Mario Kart World's sheet, on an iPhone with iOS 26, Increased Memory
    /// Limit and Game Mode.
    private func verdict(runsMinimumIOS: Bool = true, readsBCTextures: Bool = true, needsIML: Bool = true,
                         hasIML: Bool = true, peakMiB: Int? = 6_074, limitMiB: Int? = 8_192,
                         latestHere: String? = "playable") -> CartoucheGameFit.Verdict {
        CartoucheGameFit.verdict(minimumIOS: "26.0", runsMinimumIOS: runsMinimumIOS, readsBCTextures: readsBCTextures,
                                 needsIML: needsIML, hasIML: hasIML, peakMiB: peakMiB, limitMiB: limitMiB,
                                 latestHere: latestHere)
    }

    func testAGPUWithoutBCTexturesRefusesEveryGame() {
        // Whatever the sheet says, Mario Kart World's or one that asks for
        // nothing: the game would close before its first image.
        XCTAssertEqual(verdict(readsBCTextures: false), .unsupported([.gpu]))
        XCTAssertEqual(verdict(readsBCTextures: false, needsIML: false, peakMiB: nil, latestHere: nil),
                       .unsupported([.gpu]))
        XCTAssertEqual(verdict(runsMinimumIOS: false, readsBCTextures: false), .unsupported([.iOS(minimum: "26.0"), .gpu]))
    }

    func testAGameWithoutASheetSaysSoOnAGPUNxnativeRefuses() {
        // Silksong, Skyward Sword HD and Wonder, which have none, closed at
        // once on an iPhone 13 Pro and an iPhone 15.
        XCTAssertEqual(CartoucheGameFit.verdictWithoutSheet(readsBCTextures: false), .unsupported([.gpu]))
        XCTAssertNil(CartoucheGameFit.verdictWithoutSheet(readsBCTextures: true))
    }

    func testWithWhatTheGameNeedsTheTestersDecide() {
        XCTAssertEqual(verdict(), .recommended)
        XCTAssertEqual(verdict(latestHere: "playable-with-issues"), .recommended)
        XCTAssertEqual(verdict(latestHere: nil), .untested)
        XCTAssertEqual(verdict(latestHere: "starts"), .untested)
        XCTAssertEqual(verdict(latestHere: "does-not-run"), .notRecommended([.doesNotRun]))
    }

    func testWhatCartouchesSignatureAndMemoryLackAreWarnings() {
        XCTAssertEqual(verdict(hasIML: false), .notRecommended([.increasedMemoryLimit]))
        XCTAssertEqual(verdict(needsIML: false, hasIML: false), .recommended)
        XCTAssertEqual(verdict(limitMiB: 6_000), .notRecommended([.memory(neededMiB: 6_074, limitMiB: 6_000)]))
        XCTAssertEqual(verdict(limitMiB: nil), .recommended)
        XCTAssertEqual(verdict(hasIML: false, limitMiB: 3_376, latestHere: "does-not-run"),
                       .notRecommended([.increasedMemoryLimit, .memory(neededMiB: 6_074, limitMiB: 3_376), .doesNotRun]))
    }

    func testAnOlderIOSRefusesTheGame() {
        XCTAssertEqual(verdict(runsMinimumIOS: false), .unsupported([.iOS(minimum: "26.0")]))
        XCTAssertEqual(verdict(runsMinimumIOS: false, hasIML: false), .unsupported([.iOS(minimum: "26.0")]))
    }
}
