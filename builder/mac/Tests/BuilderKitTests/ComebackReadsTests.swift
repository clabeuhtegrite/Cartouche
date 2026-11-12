//
//  ComebackReadsTests.swift
//  BuilderKitTests
//
//  When the app reads the dumps and the games folder again as the player
//  comes back to it (ComebackReads.swift): a game put there from the Finder
//  showed only at the next look, up to six hours later.
//

import Foundation
import XCTest
@testable import BuilderKit

final class ComebackReadsTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_794_486_000)

    func testReadsAgainAtMostOnceInTenSeconds() {
        var reads = ComebackReads()
        reads.read(at: start)
        XCTAssertFalse(reads.comeBack(at: start + 3), "the read as the app opens counts")
        XCTAssertTrue(reads.comeBack(at: start + 10))
        XCTAssertFalse(reads.comeBack(at: start + 19.9))
        XCTAssertTrue(reads.comeBack(at: start + 20))
        XCTAssertTrue(reads.comeBack(at: start + 3_600))
    }

    func testTheFirstComingBackReads() {
        var reads = ComebackReads()
        XCTAssertTrue(reads.comeBack(at: start))
        XCTAssertFalse(reads.comeBack(at: start + 1))
    }

    func testAnotherInterval() {
        var reads = ComebackReads(interval: 60)
        reads.read(at: start)
        XCTAssertFalse(reads.comeBack(at: start + 59))
        XCTAssertTrue(reads.comeBack(at: start + 60))
    }
}
