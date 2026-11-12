//
//  CartoucheGamePlaceTests.swift
//  CartoucheCoreTests
//
//  Where a game has the memory it needs, behind the console or in
//  Cartouche's place (Sources/CartoucheGamePlace.swift), with the limits
//  measured on an iPhone with 12 GB and Increased Memory Limit: 8,192 MiB for
//  Cartouche with Game Mode, 6,144 for a game's process behind the console,
//  and 3,376 for a process without the capability. What follows a game's
//  first measurement there, and its end, and what Cartouche keeps of the
//  capability from one launch to the next.
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

/// What follows the first measurement of a game behind the console, three
/// seconds in, and its end when iOS stopped it there.
final class CartoucheGamePlaceAfterTests: XCTestCase {
    private let own = 8_192

    private func afterMeasure(limit: Int, needsIML: Bool = false, peak: Int? = nil,
                              lacksIML: Bool) -> CartoucheGamePlace.AfterMeasure {
        CartoucheGamePlace.afterMeasure(limitMiB: limit, needsIML: needsIML, peakMiB: peak,
                                        behindLacksIML: lacksIML, ownMiB: own)
    }

    private func afterStop(limit: Int?, nearLimit: Bool = false, inFront: Bool = true, pending: Bool = false,
                           needsIML: Bool = false, peak: Int? = nil, lacksIML: Bool,
                           own: Int? = 8_192) -> CartoucheGamePlace.AfterStop {
        CartoucheGamePlace.afterStop(limitMiB: limit, nearLimit: nearLimit, wasInFront: inFront, startPending: pending,
                                     needsIML: needsIML, peakMiB: peak, behindLacksIML: lacksIML, ownMiB: own)
    }

    func testAGameMeasuredWithoutTheCapabilityStartsAgainInCartouchesPlaceUnmarked() {
        // Donkey Kong Bananza, which has no sheet, with 3,376 MiB.
        XCTAssertEqual(afterMeasure(limit: 3_376, lacksIML: true), .startsAgainInPlace(fromNowOn: false))
        XCTAssertEqual(afterMeasure(limit: 3_376, needsIML: true, peak: 6_074, lacksIML: true),
                       .startsAgainInPlace(fromNowOn: false))
        // A peak that fits there keeps the console.
        XCTAssertEqual(afterMeasure(limit: 3_376, peak: 2_500, lacksIML: true), .staysBehind)
    }

    func testAGameMeasuredWithTheCapabilityGoesByItsSheet() {
        XCTAssertEqual(afterMeasure(limit: 6_144, lacksIML: false), .staysBehind)
        XCTAssertEqual(afterMeasure(limit: 6_144, peak: 5_000, lacksIML: false), .staysBehind)
        // Mario Kart World, up to 6,074 MiB: in Cartouche's place from then on.
        XCTAssertEqual(afterMeasure(limit: 6_144, needsIML: true, peak: 6_074, lacksIML: false),
                       .startsAgainInPlace(fromNowOn: true))
        XCTAssertEqual(afterMeasure(limit: 6_144, needsIML: true, lacksIML: false), .startsAgainInPlace(fromNowOn: true))
        // A peak that does not fit 3,376 MiB, without the record of the
        // capability missing: marked, as before.
        XCTAssertEqual(afterMeasure(limit: 3_376, peak: 5_000, lacksIML: false), .startsAgainInPlace(fromNowOn: true))
    }

    func testAGameStoppedEarlyWithoutTheCapabilityStartsAgainInCartouchesPlace() {
        // Donkey Kong Bananza: iOS stopped it within two seconds, before its
        // first measurement, on screen.
        XCTAssertEqual(afterStop(limit: 3_376, lacksIML: true), .startsAgainInPlace)
        XCTAssertEqual(afterStop(limit: 3_376, nearLimit: true, lacksIML: true), .startsAgainInPlace)
        XCTAssertEqual(afterStop(limit: 3_376, needsIML: true, lacksIML: true), .startsAgainInPlace)
        // Without Game Mode, Cartouche's 6,143 MiB still are more.
        XCTAssertEqual(afterStop(limit: 3_376, lacksIML: true, own: 6_143), .startsAgainInPlace)
    }

    func testAGameStoppedForAnotherCauseDoesNotStartAgain() {
        // In the background, or without a reading: the console says so.
        XCTAssertEqual(afterStop(limit: 3_376, inFront: false, lacksIML: true), .stopped)
        XCTAssertEqual(afterStop(limit: nil, lacksIML: true), .stopped)
        // Already to start again, as after its first measurement.
        XCTAssertEqual(afterStop(limit: 3_376, pending: true, lacksIML: true), .stopped)
        // Its peak fits there: it did not stop for the capability.
        XCTAssertEqual(afterStop(limit: 3_376, peak: 2_500, lacksIML: true), .stopped)
        // Cartouche has no more, without the capability either.
        XCTAssertEqual(afterStop(limit: 3_376, lacksIML: true, own: 3_376), .stopped)
        // With the capability, far from its limit.
        XCTAssertEqual(afterStop(limit: 6_144, lacksIML: false), .stopped)
        XCTAssertEqual(afterStop(limit: 6_144, needsIML: true, lacksIML: false), .stopped)
    }

    func testAGameStoppedNearItsLimitGoesWhereItHasMore() {
        XCTAssertEqual(afterStop(limit: 6_144, nearLimit: true, lacksIML: false), .startsInPlaceFromNowOn)
        XCTAssertEqual(afterStop(limit: 6_144, nearLimit: true, lacksIML: false, own: 6_143), .staysBehind)
        XCTAssertEqual(afterStop(limit: 8_192, nearLimit: true, lacksIML: false), .staysBehind)
        XCTAssertEqual(afterStop(limit: 6_144, nearLimit: true, pending: true, lacksIML: false), .startsInPlaceFromNowOn)
        XCTAssertEqual(afterStop(limit: 6_144, nearLimit: true, inFront: false, lacksIML: false), .stopped)
        // A peak that fits 3,376 MiB, without the capability, near the limit.
        XCTAssertEqual(afterStop(limit: 3_376, nearLimit: true, peak: 2_500, lacksIML: true), .startsInPlaceFromNowOn)
        XCTAssertEqual(afterStop(limit: 3_376, nearLimit: true, lacksIML: true, own: 3_376), .staysBehind)
    }
}

/// What Cartouche keeps of the capability of the game's process from one
/// launch to the next.
final class CartoucheBehindIMLRecordTests: XCTestCase {
    private let suite = "CartoucheBehindIMLRecordTests"
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        UserDefaults().removePersistentDomain(forName: suite)
        defaults = UserDefaults(suiteName: suite)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
        defaults = nil
        super.tearDown()
    }

    private func record(_ install: String = "0.11.2 112 /Bundle/A/Cartouche.app") -> CartoucheBehindIMLRecord {
        CartoucheBehindIMLRecord(defaults: defaults, install: install)
    }

    func testAProcessWithoutTheCapabilityIsKeptForTheNextLaunch() {
        XCTAssertFalse(record().load())
        XCTAssertTrue(record().record(has: false, lacked: false))
        XCTAssertTrue(record().load())
        XCTAssertEqual(defaults.string(forKey: CartoucheBehindIMLRecord.key), "0.11.2 112 /Bundle/A/Cartouche.app")
    }

    func testAnotherInstallTriesBehindTheConsoleAgain() {
        XCTAssertTrue(record().record(has: false, lacked: false))
        // An update, or the same version installed again in another folder.
        XCTAssertFalse(record("0.12.0 120 /Bundle/B/Cartouche.app").load())
        XCTAssertNil(defaults.string(forKey: CartoucheBehindIMLRecord.key))
        XCTAssertFalse(record().load())
    }

    func testAReadingThatCannotTellChangesNothing() {
        XCTAssertTrue(record().record(has: false, lacked: false))
        XCTAssertTrue(record().record(has: nil, lacked: true))
        XCTAssertTrue(record().load())
        XCTAssertFalse(record().record(has: nil, lacked: false))
    }

    func testTheCapabilityBackOrTryingAgainForgetsIt() {
        XCTAssertTrue(record().record(has: false, lacked: false))
        XCTAssertFalse(record().record(has: true, lacked: true))
        XCTAssertFalse(record().load())
        XCTAssertTrue(record().record(has: false, lacked: false))
        record().clear()
        XCTAssertFalse(record().load())
    }
}
