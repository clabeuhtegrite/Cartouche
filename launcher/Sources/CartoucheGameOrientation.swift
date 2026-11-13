//
//  CartoucheGameOrientation.swift
//  Cartouche
//
//  Which ways the screen of a game behind the console turns
//  (CartoucheGameHost): as the game's Info.plist allows, by its
//  UISupportedInterfaceOrientations, the iPhone's or the iPad's own list
//  first, as iOS reads them, and never upside down on an iPhone, as
//  Cartouche itself. nxnative's games turn sideways only, to the left and
//  to the right. A game whose Info.plist names none turns as Cartouche
//  does: upright or sideways on an iPhone, every way on an iPad.
//
//  That Info.plist is the one in the game's bundle, binary once
//  LiveContainer has written it again. LiveContainer's info() is not it:
//  those are LiveContainer's own settings for the game (LCAppInfo.plist),
//  which name no orientation, so that a game made to be played sideways
//  turned upright with the iPhone.
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
}
