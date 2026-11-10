//
//  CartoucheGamePlaceTests.swift
//  CartoucheCoreTests
//
//  Where a game has the memory it needs, behind the console or in
//  Cartouche's place (Sources/CartoucheGamePlace.swift), with the limits of
//  an iPhone Duo with Increased Memory Limit: 6,143 MiB for Cartouche, and
//  for the game's process 3,376 MiB without the capability, or 8,192 MiB.
//

import XCTest
@testable import CartoucheCore

final class CartoucheGamePlaceTests: XCTestCase {
    private let own = 6_143

    func testBeforeAnyGameRanBehindTheConsoleEveryGameTriesThere() {
        XCTAssertTrue(CartoucheGamePlace.startsBehind(needsIML: true, peakMiB: 9_000, behindMiB: nil, ownMiB: own))
        XCTAssertTrue(CartoucheGamePlace.staysInPlace(behindMiB: nil, ownMiB: own))
        XCTAssertEqual(CartoucheGamePlace.gameLimitMiB(behindMiB: nil, ownMiB: own), own)
        XCTAssertNil(CartoucheGamePlace.gameLimitMiB(behindMiB: nil, ownMiB: nil))
    }

    func testWithLessBehindTheConsoleAGameShortOfMemoryThereStartsInCartouchesPlace() {
        let behind = 3_376
        XCTAssertTrue(CartoucheGamePlace.cartoucheHasMore(than: behind, ownMiB: own))
        XCTAssertFalse(CartoucheGamePlace.startsBehind(needsIML: false, peakMiB: 5_000, behindMiB: behind, ownMiB: own))
        // Without a peak, by the capability it needs and the process lacks.
        XCTAssertFalse(CartoucheGamePlace.startsBehind(needsIML: true, peakMiB: nil, behindMiB: behind, ownMiB: own))
        XCTAssertTrue(CartoucheGamePlace.startsBehind(needsIML: false, peakMiB: 3_000, behindMiB: behind, ownMiB: own))
        XCTAssertTrue(CartoucheGamePlace.startsBehind(needsIML: false, peakMiB: nil, behindMiB: behind, ownMiB: own))
        XCTAssertTrue(CartoucheGamePlace.staysInPlace(behindMiB: behind, ownMiB: own))
        XCTAssertEqual(CartoucheGamePlace.gameLimitMiB(behindMiB: behind, ownMiB: own), own)
    }

    func testANearlyEqualLimitBehindTheConsoleHasTheCapability() {
        XCTAssertTrue(CartoucheGamePlace.startsBehind(needsIML: true, peakMiB: nil, behindMiB: 6_000, ownMiB: own))
        XCTAssertFalse(CartoucheGamePlace.startsBehind(needsIML: true, peakMiB: nil, behindMiB: 5_800, ownMiB: own))
    }

    func testWithMoreBehindTheConsoleEveryGameStaysThere() {
        let behind = 8_192
        XCTAssertFalse(CartoucheGamePlace.cartoucheHasMore(than: behind, ownMiB: own))
        XCTAssertTrue(CartoucheGamePlace.startsBehind(needsIML: true, peakMiB: 7_000, behindMiB: behind, ownMiB: own))
        // Even one that needs more than either: Cartouche's place has less.
        XCTAssertTrue(CartoucheGamePlace.startsBehind(needsIML: true, peakMiB: 9_000, behindMiB: behind, ownMiB: own))
        // One iOS stopped there before, near its limit, goes back there.
        XCTAssertFalse(CartoucheGamePlace.staysInPlace(behindMiB: behind, ownMiB: own))
        XCTAssertEqual(CartoucheGamePlace.gameLimitMiB(behindMiB: behind, ownMiB: own), behind)
    }

    func testTheSameLimitInBothPlacesKeepsTheConsole() {
        XCTAssertFalse(CartoucheGamePlace.cartoucheHasMore(than: own, ownMiB: own))
        XCTAssertTrue(CartoucheGamePlace.startsBehind(needsIML: true, peakMiB: 7_000, behindMiB: own, ownMiB: own))
        XCTAssertFalse(CartoucheGamePlace.staysInPlace(behindMiB: own, ownMiB: own))
    }

    func testWithoutCartouchesOwnLimitItsPlaceCountsAsHavingMore() {
        XCTAssertTrue(CartoucheGamePlace.cartoucheHasMore(than: 8_192, ownMiB: nil))
        XCTAssertFalse(CartoucheGamePlace.startsBehind(needsIML: false, peakMiB: 9_000, behindMiB: 8_192, ownMiB: nil))
        XCTAssertTrue(CartoucheGamePlace.startsBehind(needsIML: true, peakMiB: nil, behindMiB: 8_192, ownMiB: nil))
        XCTAssertTrue(CartoucheGamePlace.staysInPlace(behindMiB: 8_192, ownMiB: nil))
        XCTAssertEqual(CartoucheGamePlace.gameLimitMiB(behindMiB: 8_192, ownMiB: nil), 8_192)
    }
}
