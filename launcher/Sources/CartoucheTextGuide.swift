//
//  CartoucheTextGuide.swift
//  Cartouche
//
//  The words of the first game's guide (CartoucheGuideView), in
//  Cartouche.xcstrings with the others (CartoucheText.swift).
//

import Foundation

extension CartoucheText {
    // MARK: First game guide

    static var guideTitle: String { s("guide.title", "Your first game") }
    static var guideIntro: String { s("guide.intro", "Five steps from here to your first game. Each one ticks itself once it is done.") }
    static var guideFinishedTitle: String { s("guide.finished.title", "You’re all set") }
    static var guideFinishedIntro: String { s("guide.finished.intro", "Your first game is on this iPhone. The next ones go the same way: build, then install.") }
    static func guideCardDetail(_ step: Int, _ count: Int, _ title: String) -> String { f("guide.card.detail", "Step %1$lld of %2$lld: %3$@", step, count, title) }
    static func guideStepDone(_ title: String) -> String { f("guide.step.done", "%@, done", title) }
    static var guideDone: String { s("guide.done", "Done.") }
    static var guideNoDownloads: String { s("guide.noDownloads", "Cartouche never downloads a game: you build yours from your own console.") }
    static var guideOpenSetup: String { s("guide.openSetup", "Open the setup") }

    static var guideVPNTitle: String { s("guide.vpn.title", "Connect LocalDevVPN") }
    static var guideVPNHow: String { s("guide.vpn.how", "Cartouche signs in and renews itself through LocalDevVPN, a free app from the App Store. Its traffic never leaves this iPhone, so you can leave it on.") }
    static var guideVPNGet: String { s("guide.vpn.get", "Get LocalDevVPN") }
    static var guideVPNConnect: String { s("guide.vpn.connect", "Connect LocalDevVPN") }
    static var guideVPNDone: String { s("guide.vpn.done", "LocalDevVPN is connected.") }

    static var guideAccountTitle: String { s("guide.account.title", "Sign in with your Apple ID") }
    static var guideAccountHow: String { s("guide.account.how", "Use the Apple ID you gave the Cartouche Installer; a free one will do. Cartouche signs your games with it and renews itself every week.") }
    static var guideAccountNoPairing: String { s("guide.account.noPairing", "The pairing file is missing. Install Cartouche again with the Cartouche Installer, from your computer: it puts the file in place. You can also choose it in the setup.") }
    static var guideAccountCertificate: String { s("guide.account.certificate", "Signed in. Cartouche is fetching its certificate…") }
    static func guideAccountDone(_ appleID: String) -> String { f("guide.account.done", "Signed in as %@.", appleID) }

    static var guideBuildTitle: String { s("guide.build.title", "Build your game on a Mac") }
    static var guideBuildHow: String { s("guide.build.how", "nxnative turns your own copy of a game into an app for the iPhone, and only a Mac can do it. Cartouche Builder does it for you, and builds your games again when nxnative improves them.") }
    static var guideBuildMac: String { s("guide.build.mac", "A Mac with Apple silicon (M1 or later), on macOS 26.6 or later") }
    static var guideBuildXcode: String { s("guide.build.xcode", "Xcode 27.2, free from Apple") }
    static var guideBuildGame: String { s("guide.build.game", "Your game, copied from your own console, with your console’s keys (prod.keys) for a Switch game") }
    static var guideBuildSend: String { s("guide.build.send", "Send the steps to my Mac") }
    static var guideBuildSendNote: String { s("guide.build.sendNote", "By AirDrop or Messages. On the Mac, the page gives Cartouche Builder: drag it into Applications, and it installs its tools itself.") }
    /// The page of the guide for the Mac, in the player's language.
    static var guideBuildLink: String { s("guide.build.link", "https://github.com/clabeuhtegrite/Cartouche/blob/main/docs/getting-started.md#2-build-your-game-on-your-mac") }
    static var guideBuildShareSubject: String { s("guide.build.share.subject", "Cartouche on your Mac") }
    static var guideBuildShareMessage: String { s("guide.build.share.message", "Install Cartouche Builder, then build your game with it.") }
    static var guideBuildDone: String { s("guide.build.done", "A game of yours is ready.") }

    static var guideFolderTitle: String { s("guide.folder.title", "Choose your games folder") }
    static var guideFolderHow: String { s("guide.folder.how", "Cartouche Builder puts your games in a folder, on the Mac or on your NAS. Add your Mac here once, with the code both screens show, or choose the folder on your NAS: Cartouche lists your games and offers their updates.") }
    static var guideFolderChoose: String { s("guide.folder.choose", "Choose the games folder") }
    static var guideFolderImport: String { s("guide.folder.import", "Import an IPA instead") }
    static func guideFolderDone(_ server: String) -> String { f("guide.folder.done", "Your games folder is on %@.", server) }

    static var guidePlayTitle: String { s("guide.play.title", "Install your game and play") }
    static var guidePlayReady: String { s("guide.play.ready", "Your game is in your games folder. Cartouche installs it on this iPhone, then shows Play.") }
    static var guidePlayWaiting: String { s("guide.play.waiting", "No game in your games folder yet. Yours shows here as soon as Cartouche Builder has built it. You can also import an IPA.") }
    static func guidePlayInstall(_ game: String) -> String { f("guide.play.install", "Install %@", game) }
    static func guidePlayDone(_ game: String) -> String { f("guide.play.done", "%@ is on this iPhone.", game) }
}
