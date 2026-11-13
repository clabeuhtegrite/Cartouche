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
}
