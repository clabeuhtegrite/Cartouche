//
//  CartoucheGameOrientation.swift
//  Cartouche
//
//  Which ways the screen of a game behind the console turns
//  (CartoucheGameHost). First, the ways the game allows, as its Info.plist
//  says by its UISupportedInterfaceOrientations, the iPhone's or the iPad's
//  own list first, as iOS reads them, and never upside down on an iPhone,
//  as Cartouche itself. nxnative's games allow sideways only on an iPhone,
//  to the left and to the right; on an iPad, those built since nxnative's
//  e2fadf2 (4 November 2026) allow every way, by their
//  UISupportedInterfaceOrientations~ipad, with a layout for an upright
//  screen, and those built before sideways only. A game whose Info.plist
//  names none turns as Cartouche does: upright or sideways on an iPhone,
//  every way on an iPad.
//
//  That Info.plist is the one in the game's bundle, binary once
//  LiveContainer has written it again. LiveContainer's info() is not it:
//  those are LiveContainer's own settings for the game (LCAppInfo.plist),
//  which name no orientation, so that a game made to be played sideways
//  turned upright with the iPhone, whether it could be played upright or not.
//
//  Then, behind the console, an iPhone turns the screen of a game that lays
//  itself out upright, upright too, as the player holds it, while the
//  game's picture is on the iPhone (behindTheConsole(isPad:laysOutUpright:
//  pictureOnTV:)). In Cartouche's place, iOS turns the game as its own
//  Info.plist allows, and Cartouche's code in the game's process makes it
//  allow upright too, by the same rule (launcher/Guest/
//  CartoucheUprightGame.m).
//
//  An iPhone turns the screen only the ways it allows. An iPad turns
//  Cartouche's scenes as it is held, whatever a game allows: the screen
//  keeps the way it is turned once the game allows it, and turns from one
//  side to the other as the iPad does (keeps(_:held:isPad:)).
//
//  Platform-independent: tested on its own by launcher/Package.swift.
//

import Foundation

/// The orientations of UIKit's UIInterfaceOrientationMask, without UIKit.
struct CartoucheGameOrientations: OptionSet {
    let rawValue: Int

    static let portrait = CartoucheGameOrientations(rawValue: 1 << 0)
    static let portraitUpsideDown = CartoucheGameOrientations(rawValue: 1 << 1)
    static let landscapeLeft = CartoucheGameOrientations(rawValue: 1 << 2)
    static let landscapeRight = CartoucheGameOrientations(rawValue: 1 << 3)
    static let landscape: CartoucheGameOrientations = [.landscapeLeft, .landscapeRight]
}

extension CartoucheGameOrientations {
    /// Cartouche's own, as its Info.plist lists them: upright or sideways
    /// on an iPhone, every way on an iPad.
    static func ofCartouche(isPad: Bool) -> CartoucheGameOrientations {
        isPad ? [.portrait, .portraitUpsideDown, .landscape] : [.portrait, .landscape]
    }

    /// Those an app's Info.plist INFO allows on an iPad or an iPhone, among
    /// Cartouche's own; Cartouche's own when it names none of them.
    init(info: [String: Any], isPad: Bool) {
        let key = "UISupportedInterfaceOrientations"
        let names = info[key + (isPad ? "~ipad" : "~iphone")] as? [String] ?? info[key] as? [String] ?? []
        var allowed: CartoucheGameOrientations = []
        for name in names {
            switch name {
            case "UIInterfaceOrientationPortrait": allowed.insert(.portrait)
            case "UIInterfaceOrientationPortraitUpsideDown": allowed.insert(.portraitUpsideDown)
            case "UIInterfaceOrientationLandscapeLeft": allowed.insert(.landscapeLeft)
            case "UIInterfaceOrientationLandscapeRight": allowed.insert(.landscapeRight)
            default: break
            }
        }
        let own = Self.ofCartouche(isPad: isPad)
        allowed.formIntersection(own)
        self = allowed.isEmpty ? own : allowed
    }

    /// Those the app installed at BUNDLE allows, by the Info.plist in it;
    /// Cartouche's own when it has none to read.
    init(bundle: URL, isPad: Bool) {
        let data = try? Data(contentsOf: bundle.appendingPathComponent("Info.plist"))
        let info = data.flatMap { try? PropertyListSerialization.propertyList(from: $0, format: nil) } as? [String: Any]
        self.init(info: info ?? [:], isPad: isPad)
    }

    /// Whether the app installed at BUNDLE lays itself out upright, in a
    /// view taller than wide: whether its Info.plist allows it upright on an
    /// iPad. nxnative's games do since its commit e2fadf2 of 4 November
    /// 2026, which lays their picture above their controls there (DmLayout)
    /// and lists every way for an iPad, but sideways only for an iPhone, so
    /// that their own app stays sideways on one. A game built before allows
    /// sideways only, on an iPad too: upright, its picture would stay in the
    /// middle of the screen, its controls laid out to be held sideways.
    static func laysOutUpright(bundle: URL) -> Bool {
        CartoucheGameOrientations(bundle: bundle, isPad: true).contains(.portrait)
    }

    /// The ways the screen of a game behind the console turns, for a game
    /// that allows these. On an iPhone, upright too for a game that lays
    /// itself out upright (LAYSOUTUPRIGHT, laysOutUpright(bundle:)), as the
    /// player holds the iPhone: its picture above, its controls under it, as
    /// the inner display of the iPhone Duo shows it, which iOS turns as it is
    /// held whatever the game allows. Not while the game's picture is on a TV
    /// (PICTUREONTV): nxnative leaves the iPhone its controls alone, laid out
    /// to be held sideways. On an iPad, as the game allows: every way for a
    /// game that lays itself out upright.
    func behindTheConsole(isPad: Bool, laysOutUpright: Bool, pictureOnTV: Bool) -> CartoucheGameOrientations {
        guard !isPad, laysOutUpright, !pictureOnTV else { return self }
        return union(.portrait)
    }

    /// Whether the screen of a game that allows these orientations keeps the
    /// way it is turned, CURRENT, while the device is held the way HELD
    /// (an empty set when it lies flat or iOS cannot tell). On an iPad iOS
    /// turns Cartouche's scenes as the iPad is held, whatever a game allows
    /// (Apple's TN3192): a game made to be played sideways on an iPad, as
    /// nxnative's built before 4 November are, turned upright with the
    /// iPad. iOS keeps the way a scene is turned only while it is
    /// asked to (UIViewController.prefersInterfaceOrientationLocked, iPadOS
    /// 26), so the screen asks once it is turned a way the game allows, and
    /// lets go while it is turned a way the game does not allow, for the
    /// player to turn it sideways, and while the iPad is held another way the
    /// game allows, for iOS to turn it there, as it turns a game from one
    /// side to the other on an iPhone. A game that turns every way Cartouche
    /// does keeps nothing.
    func keeps(_ current: CartoucheGameOrientations, held: CartoucheGameOrientations, isPad: Bool) -> Bool {
        guard !isSuperset(of: Self.ofCartouche(isPad: isPad)) else { return false }
        guard current.isOne, contains(current) else { return false }
        if held.isOne, held != current, contains(held) { return false }
        return true
    }

    /// Whether the player should turn the device sideways to play a game
    /// that allows these orientations while its screen is turned CURRENT:
    /// on an iPad, which shows the game as it is held, a game made to be
    /// played sideways there (nxnative's built before 4 November) shown
    /// upright or upside down. An iPhone turns the screen itself.
    func asksToTurnSideways(_ current: CartoucheGameOrientations, isPad: Bool) -> Bool {
        let upright: CartoucheGameOrientations = [.portrait, .portraitUpsideDown]
        return isPad && current.isOne && upright.contains(current) && isDisjoint(with: upright)
            && !isDisjoint(with: .landscape)
    }

    /// Exactly one orientation.
    private var isOne: Bool { rawValue.nonzeroBitCount == 1 }
}
