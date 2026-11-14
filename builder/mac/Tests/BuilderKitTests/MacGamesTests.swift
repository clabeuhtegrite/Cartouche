//
//  MacGamesTests.swift
//  BuilderKitTests
//
//  The games played on this Mac, on what needs no game: the processes the
//  builder follows (MacGames.swift). A game played from end to end is in
//  EndToEndTests.swift.
//

import Foundation
import XCTest
@testable import BuilderKit

final class MacGamesTests: XCTestCase {
    /// LaunchServices says -1 of a game that ended as soon as it started,
    /// which kill() takes for every process the builder may signal, and 0
    /// for its own group: neither is a game running.
    func testOnlyAProcessOfItsOwnIsAlive() {
        XCTAssertFalse(MacGames.alive(-1))
        XCTAssertFalse(MacGames.alive(0))
        XCTAssertTrue(MacGames.alive(getpid()))
    }
}
