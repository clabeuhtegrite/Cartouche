//
//  CartoucheGamePlaceTests.swift
//  CartoucheCoreTests
//
//  Where a game has the memory it needs, behind the console or in
//  Cartouche's place (Sources/CartoucheGamePlace.swift), with the limits
//  measured on an iPhone with 12 GB and Increased Memory Limit: 8,192 MiB for
//  Cartouche with Game Mode, 6,144 for a game's process behind the console,
//  and 3,376 for a process without the capability.
//

import XCTest
@testable import CartoucheCore

final class CartoucheGamePlaceTests: XCTestCase {
    private let own = 8_192

    func testBeforeAnyGameRanBehindTheConsoleEveryGameTriesThere() {
        XCTAssertTrue(CartoucheGamePlace.startsBehind(needsIML: true, peakMiB: 9_000, behindMiB: nil, ownMiB: own))
        XCTAssertTrue(CartoucheGamePlace.staysInPlace(behindMiB: nil, ownMiB: own))
        XCTAssertEqual(CartoucheGamePlace.gameLimitMiB(behindMiB: nil, ownMiB: own), own)
        XCTAssertNil(CartoucheGamePlace.gameLimitMiB(behindMiB: nil, ownMiB: nil))
    }

    func testWithGameModeCartouchesPlaceHasMoreForTheGamesThatNeedIt() {
        let behind = 6_144
        XCTAssertTrue(CartoucheGamePlace.cartoucheHasMore(than: behind, ownMiB: own))
        // A game whose peak leaves it room keeps the console.
        XCTAssertTrue(CartoucheGamePlace.startsBehind(needsIML: false, peakMiB: 5_000, behindMiB: behind, ownMiB: own))
        XCTAssertTrue(CartoucheGamePlace.startsBehind(needsIML: true, peakMiB: 5_376, behindMiB: behind, ownMiB: own))
        XCTAssertTrue(CartoucheGamePlace.startsBehind(needsIML: false, peakMiB: nil, behindMiB: behind, ownMiB: own))
        // One that needs more, or all it can have, has 8,192 in Cartouche's
        // place: Mario Kart World peaked at up to 6,074 MiB.
        XCTAssertFalse(CartoucheGamePlace.startsBehind(needsIML: true, peakMiB: 6_074, behindMiB: behind, ownMiB: own))
        XCTAssertFalse(CartoucheGamePlace.startsBehind(needsIML: false, peakMiB: 5_400, behindMiB: behind, ownMiB: own))
        XCTAssertFalse(CartoucheGamePlace.startsBehind(needsIML: false, peakMiB: 7_000, behindMiB: behind, ownMiB: own))
        XCTAssertFalse(CartoucheGamePlace.startsBehind(needsIML: true, peakMiB: nil, behindMiB: behind, ownMiB: own))
        XCTAssertTrue(CartoucheGamePlace.staysInPlace(behindMiB: behind, ownMiB: own))
        XCTAssertEqual(CartoucheGamePlace.gameLimitMiB(behindMiB: behind, ownMiB: own), own)
    }

    func testAProcessWithoutTheCapabilitySendsTheGamesThatNeedItToCartouchesPlace() {
        let behind = 3_376
        XCTAssertFalse(CartoucheGamePlace.startsBehind(needsIML: true, peakMiB: nil, behindMiB: behind, ownMiB: own))
        XCTAssertFalse(CartoucheGamePlace.startsBehind(needsIML: false, peakMiB: 5_000, behindMiB: behind, ownMiB: own))
        XCTAssertTrue(CartoucheGamePlace.startsBehind(needsIML: false, peakMiB: 2_500, behindMiB: behind, ownMiB: own))
        XCTAssertFalse(CartoucheGamePlace.startsBehind(needsIML: false, peakMiB: 3_000, behindMiB: behind, ownMiB: own))
        // Until the process says it ran without the capability (below).
        XCTAssertTrue(CartoucheGamePlace.startsBehind(needsIML: false, peakMiB: nil, behindMiB: behind, ownMiB: own))
        XCTAssertFalse(CartoucheGamePlace.sendsGamesInPlace(behindMiB: behind, behindLacksIML: false, ownMiB: own))
    }

    func testOnceTheProcessRanWithoutTheCapabilityOnlyAGameWhosePeakFitsStaysThere() {
        let behind = 3_376
        // Donkey Kong Bananza, which has no sheet: iOS stopped it there
        // within seconds, four times.
        XCTAssertFalse(CartoucheGamePlace.startsBehind(needsIML: false, peakMiB: nil, behindMiB: behind,
                                                       behindLacksIML: true, ownMiB: own))
        XCTAssertFalse(CartoucheGamePlace.startsBehind(needsIML: true, peakMiB: nil, behindMiB: behind,
                                                       behindLacksIML: true, ownMiB: own))
        XCTAssertFalse(CartoucheGamePlace.startsBehind(needsIML: true, peakMiB: 6_074, behindMiB: behind,
                                                       behindLacksIML: true, ownMiB: own))
        XCTAssertTrue(CartoucheGamePlace.startsBehind(needsIML: false, peakMiB: 2_500, behindMiB: behind,
                                                      behindLacksIML: true, ownMiB: own))
        XCTAssertTrue(CartoucheGamePlace.sendsGamesInPlace(behindMiB: behind, behindLacksIML: true, ownMiB: own))
        // Without Game Mode, Cartouche's place still has more.
        XCTAssertTrue(CartoucheGamePlace.sendsGamesInPlace(behindMiB: behind, behindLacksIML: true, ownMiB: 6_143))
        // Without the capability in Cartouche either, it has no more: every
        // game stays behind the console.
        XCTAssertTrue(CartoucheGamePlace.startsBehind(needsIML: false, peakMiB: nil, behindMiB: behind,
                                                      behindLacksIML: true, ownMiB: 3_376))
        XCTAssertFalse(CartoucheGamePlace.sendsGamesInPlace(behindMiB: behind, behindLacksIML: true, ownMiB: 3_376))
        // Nothing measured there yet: every game tries there.
        XCTAssertTrue(CartoucheGamePlace.startsBehind(needsIML: false, peakMiB: nil, behindMiB: nil,
                                                      behindLacksIML: true, ownMiB: own))
        XCTAssertFalse(CartoucheGamePlace.sendsGamesInPlace(behindMiB: nil, behindLacksIML: true, ownMiB: own))
        // The capability back: the sheet decides, as before.
        XCTAssertTrue(CartoucheGamePlace.startsBehind(needsIML: false, peakMiB: nil, behindMiB: 6_144,
                                                      behindLacksIML: false, ownMiB: own))
        XCTAssertFalse(CartoucheGamePlace.sendsGamesInPlace(behindMiB: 6_144, behindLacksIML: false, ownMiB: own))
    }

    func testAGameKeepsAnEighthOfItsLimitOrHalfAGibibyte() {
        XCTAssertEqual(CartoucheGamePlace.roomMiB(under: 6_144), 768)
        XCTAssertEqual(CartoucheGamePlace.roomMiB(under: 8_192), 1_024)
        XCTAssertEqual(CartoucheGamePlace.roomMiB(under: 3_376), 512)
    }

    func testLimitsWithinTheMarginCountAsTheSame() {
        // Increased Memory Limit gave Cartouche 6,143 MiB and a game's process 6,144.
        XCTAssertFalse(CartoucheGamePlace.cartoucheHasMore(than: 6_144, ownMiB: 6_143))
        XCTAssertFalse(CartoucheGamePlace.cartoucheHasMore(than: 6_143, ownMiB: 6_144))
        XCTAssertTrue(CartoucheGamePlace.startsBehind(needsIML: true, peakMiB: nil, behindMiB: 8_000, ownMiB: own))
        XCTAssertFalse(CartoucheGamePlace.startsBehind(needsIML: true, peakMiB: nil, behindMiB: 7_800, ownMiB: own))
        XCTAssertFalse(CartoucheGamePlace.staysInPlace(behindMiB: 8_000, ownMiB: own))
    }

    func testWithGameModeBehindTheConsoleTooEveryGameStaysThere() {
        let behind = own
        XCTAssertFalse(CartoucheGamePlace.cartoucheHasMore(than: behind, ownMiB: own))
        XCTAssertTrue(CartoucheGamePlace.startsBehind(needsIML: true, peakMiB: nil, behindMiB: behind, ownMiB: own))
        // Even one that needs more than either: Cartouche's place has no more.
        XCTAssertTrue(CartoucheGamePlace.startsBehind(needsIML: true, peakMiB: 9_000, behindMiB: behind, ownMiB: own))
        // One iOS stopped there before, near its limit, goes back there.
        XCTAssertFalse(CartoucheGamePlace.staysInPlace(behindMiB: behind, ownMiB: own))
        XCTAssertEqual(CartoucheGamePlace.gameLimitMiB(behindMiB: behind, ownMiB: own), own)
    }

    func testWithMoreBehindTheConsoleTheSheetCountsThatLimit() {
        let behind = 9_216
        XCTAssertFalse(CartoucheGamePlace.cartoucheHasMore(than: behind, ownMiB: own))
        XCTAssertTrue(CartoucheGamePlace.startsBehind(needsIML: false, peakMiB: 9_000, behindMiB: behind, ownMiB: own))
        XCTAssertFalse(CartoucheGamePlace.staysInPlace(behindMiB: behind, ownMiB: own))
        XCTAssertEqual(CartoucheGamePlace.gameLimitMiB(behindMiB: behind, ownMiB: own), behind)
    }

    func testWithoutCartouchesOwnLimitItsPlaceCountsAsHavingMore() {
        XCTAssertTrue(CartoucheGamePlace.cartoucheHasMore(than: 8_192, ownMiB: nil))
        XCTAssertFalse(CartoucheGamePlace.startsBehind(needsIML: false, peakMiB: 9_000, behindMiB: 6_144, ownMiB: nil))
        XCTAssertFalse(CartoucheGamePlace.startsBehind(needsIML: true, peakMiB: nil, behindMiB: 6_144, ownMiB: nil))
        XCTAssertTrue(CartoucheGamePlace.startsBehind(needsIML: false, peakMiB: 5_000, behindMiB: 6_144, ownMiB: nil))
        XCTAssertTrue(CartoucheGamePlace.staysInPlace(behindMiB: 6_144, ownMiB: nil))
        XCTAssertEqual(CartoucheGamePlace.gameLimitMiB(behindMiB: 6_144, ownMiB: nil), 6_144)
    }
}
