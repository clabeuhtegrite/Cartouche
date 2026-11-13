//
//  CartoucheGameOrientationTests.swift
//  CartoucheCoreTests
//
//  Which ways the screen of a game behind the console turns
//  (Sources/CartoucheGameOrientation.swift): as the Info.plist in the
//  game's bundle allows, not as LiveContainer's settings for the game.
//

import Foundation
import XCTest
@testable import CartoucheCore

final class CartoucheGameOrientationTests: XCTestCase {
    private var bundle: URL!

    private let upright: CartoucheGameOrientations = [.portrait]
    private let iPhone: CartoucheGameOrientations = [.portrait, .landscapeLeft, .landscapeRight]
    private let iPad: CartoucheGameOrientations = [.portrait, .portraitUpsideDown, .landscapeLeft, .landscapeRight]

    override func setUpWithError() throws {
        bundle = FileManager.default.temporaryDirectory
            .appendingPathComponent("CartoucheGameOrientationTests-\(UUID().uuidString)/Game.app", isDirectory: true)
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: bundle.deletingLastPathComponent())
    }

    private func write(_ plist: [String: Any], as name: String,
                       format: PropertyListSerialization.PropertyListFormat = .binary) throws {
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: format, options: 0)
        try data.write(to: bundle.appendingPathComponent(name))
    }

    /// An nxnative game is made to be played sideways (dm/ios/project.yml):
    /// its Info.plist, binary once LiveContainer has written it again, says
    /// so. LiveContainer's own settings for the game, beside it, name no
    /// orientation, and once let it turn upright with the iPhone.
    func testAnNxnativeGameTurnsSidewaysOnly() throws {
        try write(["LCDataUUID": "A1B2C3D4", "LCOrientationLock": 0, "isJITNeeded": false],
                  as: "LCAppInfo.plist", format: .xml)
        try write(["CFBundleIdentifier": "org.nxnative.09d00e8a5d61a000", "UIRequiresFullScreen": true,
                   "UISupportedInterfaceOrientations": ["UIInterfaceOrientationLandscapeRight",
                                                        "UIInterfaceOrientationLandscapeLeft"]],
                  as: "Info.plist")
        XCTAssertEqual(CartoucheGameOrientations(bundle: bundle, isPad: false), .landscape)
        XCTAssertEqual(CartoucheGameOrientations(bundle: bundle, isPad: true), .landscape)
    }

    /// As iOS reads them: the iPhone's or the iPad's own list first, else
    /// the one for both.
    func testTheListOfTheDeviceComesFirst() {
        let key = "UISupportedInterfaceOrientations"
        let both: [String: Any] = [key: ["UIInterfaceOrientationPortrait"]]
        XCTAssertEqual(CartoucheGameOrientations(info: both, isPad: false), upright)
        XCTAssertEqual(CartoucheGameOrientations(info: both, isPad: true), upright)

        var each = both
        each[key + "~iphone"] = ["UIInterfaceOrientationLandscapeRight"]
        each[key + "~ipad"] = ["UIInterfaceOrientationLandscapeLeft", "UIInterfaceOrientationPortraitUpsideDown"]
        XCTAssertEqual(CartoucheGameOrientations(info: each, isPad: false), .landscapeRight)
        XCTAssertEqual(CartoucheGameOrientations(info: each, isPad: true), [.landscapeLeft, .portraitUpsideDown])
    }

    /// Among Cartouche's own: never upside down on an iPhone.
    func testNeverUpsideDownOnAnIPhone() {
        let every: [String: Any] = ["UISupportedInterfaceOrientations": [
            "UIInterfaceOrientationPortrait", "UIInterfaceOrientationPortraitUpsideDown",
            "UIInterfaceOrientationLandscapeLeft", "UIInterfaceOrientationLandscapeRight",
        ]]
        XCTAssertEqual(CartoucheGameOrientations(info: every, isPad: false), iPhone)
        XCTAssertEqual(CartoucheGameOrientations(info: every, isPad: true), iPad)

        let upsideDown: [String: Any] = ["UISupportedInterfaceOrientations": ["UIInterfaceOrientationPortraitUpsideDown"]]
        XCTAssertEqual(CartoucheGameOrientations(info: upsideDown, isPad: false), iPhone)
        XCTAssertEqual(CartoucheGameOrientations(info: upsideDown, isPad: true), .portraitUpsideDown)
    }

    /// A game that names no orientation, or has no Info.plist to read,
    /// turns as Cartouche does.
    func testAGameThatNamesNoneTurnsAsCartouche() throws {
        XCTAssertEqual(CartoucheGameOrientations.ofCartouche(isPad: false), iPhone)
        XCTAssertEqual(CartoucheGameOrientations.ofCartouche(isPad: true), iPad)

        XCTAssertEqual(CartoucheGameOrientations(bundle: bundle, isPad: false), iPhone)
        XCTAssertEqual(CartoucheGameOrientations(bundle: bundle, isPad: true), iPad)

        try write(["CFBundleIdentifier": "com.example.game"], as: "Info.plist", format: .xml)
        XCTAssertEqual(CartoucheGameOrientations(bundle: bundle, isPad: false), iPhone)

        try write(["UISupportedInterfaceOrientations": ["UIInterfaceOrientationUnknown"]], as: "Info.plist")
        XCTAssertEqual(CartoucheGameOrientations(bundle: bundle, isPad: false), iPhone)

        try Data("not a property list".utf8).write(to: bundle.appendingPathComponent("Info.plist"))
        XCTAssertEqual(CartoucheGameOrientations(bundle: bundle, isPad: true), iPad)
    }

    /// On an iPad, which turns the game's screen as it is held, whatever
    /// the game allows, and turned nxnative's games upright mid-game: an
    /// nxnative game, sideways only, keeps the way it is turned once it is
    /// sideways, as the iPad tilts upright, upside down or lies flat.
    func testAGameMadeToBePlayedSidewaysStaysSidewaysOnAnIPad() {
        let game = CartoucheGameOrientations.landscape
        for current in [CartoucheGameOrientations.landscapeLeft, .landscapeRight] {
            for held in [CartoucheGameOrientations.portrait, .portraitUpsideDown, [], current] {
                XCTAssertTrue(game.keeps(current, held: held, isPad: true), "turned \(current.rawValue), held \(held.rawValue)")
            }
        }
    }

    /// It turns from one side to the other as the iPad does: the screen lets
    /// go while the iPad is held the other side up, for iOS to turn it.
    func testItTurnsFromOneSideToTheOtherWithTheIPad() {
        let game = CartoucheGameOrientations.landscape
        XCTAssertFalse(game.keeps(.landscapeLeft, held: .landscapeRight, isPad: true))
        XCTAssertFalse(game.keeps(.landscapeRight, held: .landscapeLeft, isPad: true))
    }

    /// Turned a way the game does not allow, as when it starts on an iPad
    /// held upright, the screen keeps nothing: the player turns the iPad
    /// sideways, and the game with it.
    func testUprightItWaitsForThePlayerToTurnTheIPad() {
        let game = CartoucheGameOrientations.landscape
        for held in [CartoucheGameOrientations.portrait, .portraitUpsideDown, .landscapeLeft, .landscapeRight, []] {
            XCTAssertFalse(game.keeps(.portrait, held: held, isPad: true))
            XCTAssertFalse(game.keeps(.portraitUpsideDown, held: held, isPad: true))
        }
        XCTAssertFalse(game.keeps([], held: .landscapeLeft, isPad: true), "turned no way iOS could tell")
    }

    /// A game that turns every way Cartouche does keeps nothing; one that
    /// turns upright only keeps upright.
    func testOnlyAGameThatTurnsFewerWaysKeepsOne() {
        let every = CartoucheGameOrientations.ofCartouche(isPad: true)
        for current in [CartoucheGameOrientations.portrait, .portraitUpsideDown, .landscapeLeft, .landscapeRight] {
            XCTAssertFalse(every.keeps(current, held: [], isPad: true))
        }
        XCTAssertTrue(upright.keeps(.portrait, held: .landscapeLeft, isPad: true))
        XCTAssertFalse(upright.keeps(.landscapeLeft, held: .portrait, isPad: true))
    }

    /// An iPad held upright shows a game made to be played sideways
    /// upright: the player is asked to turn it, and only then.
    func testAnIPadHeldUprightAsksToTurnItSideways() {
        let game = CartoucheGameOrientations.landscape
        XCTAssertTrue(game.asksToTurnSideways(.portrait, isPad: true))
        XCTAssertTrue(game.asksToTurnSideways(.portraitUpsideDown, isPad: true))
        XCTAssertTrue(CartoucheGameOrientations.landscapeRight.asksToTurnSideways(.portrait, isPad: true))
        for current in [CartoucheGameOrientations.landscapeLeft, .landscapeRight, []] {
            XCTAssertFalse(game.asksToTurnSideways(current, isPad: true), "turned \(current.rawValue)")
        }
        XCTAssertFalse(game.asksToTurnSideways(.portrait, isPad: false), "an iPhone turns the screen itself")
    }

    /// A game that may be played upright, or not sideways, asks nothing.
    func testAGameThatTurnsUprightAsksNothing() {
        XCTAssertFalse(CartoucheGameOrientations.ofCartouche(isPad: true).asksToTurnSideways(.portrait, isPad: true))
        XCTAssertFalse(upright.asksToTurnSideways(.portraitUpsideDown, isPad: true))
        XCTAssertFalse(CartoucheGameOrientations([.portraitUpsideDown, .landscapeLeft]).asksToTurnSideways(.portrait, isPad: true))
    }
}
