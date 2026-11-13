//
//  CartoucheGameOrientationTests.swift
//  CartoucheCoreTests
//
//  Which ways the screen of a game behind the console turns
//  (Sources/CartoucheGameOrientation.swift): as the Info.plist in the
//  game's bundle allows, not as LiveContainer's settings for the game, and
//  on an iPhone upright too for a game that lays itself out upright, while
//  its picture is on the iPhone.
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

    // MARK: Behind the console

    /// The Info.plist of a game nxnative built: since its commit e2fadf2 of
    /// 4 November 2026 (dm/ios/project.yml), sideways for an iPhone and
    /// every way for an iPad, where it lays its picture above its controls
    /// in a view taller than wide (DmLayout); before, sideways only.
    private func writeNxnativeGame(builtSinceNovember4: Bool) throws {
        var info: [String: Any] = [
            "CFBundleIdentifier": "org.nxnative.0100a3d008c5c000",
            "UISupportedInterfaceOrientations": ["UIInterfaceOrientationLandscapeRight",
                                                 "UIInterfaceOrientationLandscapeLeft"],
        ]
        if builtSinceNovember4 {
            info["UISupportedInterfaceOrientations~ipad"] = [
                "UIInterfaceOrientationPortrait", "UIInterfaceOrientationPortraitUpsideDown",
                "UIInterfaceOrientationLandscapeRight", "UIInterfaceOrientationLandscapeLeft",
            ]
        } else {
            info["UIRequiresFullScreen"] = true
        }
        try write(info, as: "Info.plist")
    }

    /// Behind the console, an iPhone turns a game nxnative built since 4
    /// November upright too, as the player holds it: its picture above, its
    /// controls under it, as the inner display of the iPhone Duo shows it,
    /// which iOS turns whatever the game allows. In 0.12, it stayed sideways
    /// on any other iPhone, and on the Duo's outer display.
    func testAnNxnativeGameTurnsUprightTooBehindTheConsoleOnAnIPhone() throws {
        try writeNxnativeGame(builtSinceNovember4: true)
        let allowed = CartoucheGameOrientations(bundle: bundle, isPad: false)
        XCTAssertEqual(allowed, .landscape, "its own app stays sideways on an iPhone")
        XCTAssertTrue(CartoucheGameOrientations.laysOutUpright(bundle: bundle))
        XCTAssertEqual(allowed.behindTheConsole(isPad: false, laysOutUpright: true, pictureOnTV: false), iPhone)
        // On an iPad, every way, as the game allows there.
        let onAnIPad = CartoucheGameOrientations(bundle: bundle, isPad: true)
        XCTAssertEqual(onAnIPad, iPad)
        XCTAssertEqual(onAnIPad.behindTheConsole(isPad: true, laysOutUpright: true, pictureOnTV: false), iPad)
    }

    /// While the game's picture is on a TV, the iPhone shows nxnative's
    /// controls alone, laid out to be held sideways: sideways only.
    func testAGameWhosePictureIsOnATVStaysSideways() throws {
        try writeNxnativeGame(builtSinceNovember4: true)
        let allowed = CartoucheGameOrientations(bundle: bundle, isPad: false)
        XCTAssertEqual(allowed.behindTheConsole(isPad: false, laysOutUpright: true, pictureOnTV: true), .landscape)
    }

    /// A game nxnative built before 4 November allows sideways only, on an
    /// iPad too: upright, its picture would stay in the middle, its controls
    /// laid out to be held sideways. It stays sideways behind the console.
    func testAGameBuiltBeforeNxnativeLaidGamesOutUprightStaysSideways() throws {
        try writeNxnativeGame(builtSinceNovember4: false)
        XCTAssertFalse(CartoucheGameOrientations.laysOutUpright(bundle: bundle))
        let allowed = CartoucheGameOrientations(bundle: bundle, isPad: false)
        XCTAssertEqual(allowed.behindTheConsole(isPad: false, laysOutUpright: false, pictureOnTV: false), .landscape)
    }

    /// The rule alone: upright too on an iPhone only, for a game that lays
    /// itself out upright, while its picture is on the iPhone, and never
    /// upside down. A game made to be played upright stays so.
    func testUprightTooOnAnIPhoneOnly() {
        let sideways = CartoucheGameOrientations.landscape
        XCTAssertEqual(sideways.behindTheConsole(isPad: false, laysOutUpright: true, pictureOnTV: false), iPhone)
        XCTAssertEqual(sideways.behindTheConsole(isPad: false, laysOutUpright: false, pictureOnTV: false), sideways)
        XCTAssertEqual(sideways.behindTheConsole(isPad: false, laysOutUpright: true, pictureOnTV: true), sideways)
        XCTAssertEqual(sideways.behindTheConsole(isPad: true, laysOutUpright: true, pictureOnTV: false), sideways)
        XCTAssertEqual(CartoucheGameOrientations.landscapeRight
            .behindTheConsole(isPad: false, laysOutUpright: true, pictureOnTV: false), [.portrait, .landscapeRight])
        XCTAssertEqual(upright.behindTheConsole(isPad: false, laysOutUpright: true, pictureOnTV: true), upright)
        XCTAssertEqual(iPhone.behindTheConsole(isPad: false, laysOutUpright: true, pictureOnTV: false), iPhone)
    }
}
