//
//  CartoucheInstallQuestionsTests.swift
//  CartoucheCoreTests
//
//  The question an install asks first on an iPhone whose GPU nxnative
//  refuses (Sources/CartoucheInstallQuestions.swift): an iPhone 13 Pro, A15,
//  or an iPhone 15, A16, cannot read BC-compressed textures, and the games
//  players installed there closed before their first image.
//

import XCTest
@testable import CartoucheCore

final class CartoucheInstallQuestionsTests: XCTestCase {
    private var questions = CartoucheInstallQuestions<String>()

    func testOnAGPUThatReadsBCTexturesAnInstallStartsAtOnce() {
        let (starts, dropped) = questions.install("Silksong.ipa", readsBCTextures: true, answered: false)
        XCTAssertTrue(starts)
        XCTAssertNil(dropped)
        XCTAssertNil(questions.asked)
    }

    func testOnAGPUNxnativeRefusesAnInstallAsksFirst() {
        let (starts, dropped) = questions.install("Silksong.ipa", readsBCTextures: false, answered: false)
        XCTAssertFalse(starts)
        XCTAssertNil(dropped)
        XCTAssertEqual(questions.asked, "Silksong.ipa")
    }

    func testInstallAnywayStartsItAndCancelLeavesNothing() {
        _ = questions.install("Silksong.ipa", readsBCTextures: false, answered: false)
        // Install anyway: the question goes, and the install starts.
        questions.close("Silksong.ipa")
        XCTAssertNil(questions.asked)
        XCTAssertTrue(questions.install("Silksong.ipa", readsBCTextures: false, answered: true).starts)
        XCTAssertNil(questions.asked)
        // Cancel: nothing on screen, nothing installed.
        _ = questions.install("Wonder.ipa", readsBCTextures: false, answered: false)
        questions.close("Wonder.ipa")
        XCTAssertNil(questions.asked)
    }

    func testAnAnswerThatComesAsTheAlertClosesStillInstalls() {
        // The alert's binding may close the question before its button
        // answers it.
        _ = questions.install("Silksong.ipa", readsBCTextures: false, answered: false)
        questions.close("Silksong.ipa")
        questions.close("Silksong.ipa")
        XCTAssertTrue(questions.install("Silksong.ipa", readsBCTextures: false, answered: true).starts)
    }

    func testAnotherInstallMeanwhileTakesTheQuestionsPlace() {
        _ = questions.install("Silksong.ipa", readsBCTextures: false, answered: false)
        let (starts, dropped) = questions.install("Wonder.ipa", readsBCTextures: false, answered: false)
        XCTAssertFalse(starts)
        // The first goes unanswered, as Cancel leaves it.
        XCTAssertEqual(dropped, "Silksong.ipa")
        XCTAssertEqual(questions.asked, "Wonder.ipa")
        // A late answer to the first leaves the second on screen.
        questions.close("Silksong.ipa")
        XCTAssertEqual(questions.asked, "Wonder.ipa")
    }

    func testTheSameInstallAskedForAgainKeepsItsQuestion() {
        _ = questions.install("Silksong.ipa", readsBCTextures: false, answered: false)
        let (starts, dropped) = questions.install("Silksong.ipa", readsBCTextures: false, answered: false)
        XCTAssertFalse(starts)
        // Dropping it would take away the file the question installs.
        XCTAssertNil(dropped)
        XCTAssertEqual(questions.asked, "Silksong.ipa")
    }
}
