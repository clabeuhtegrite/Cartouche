//
//  CartoucheTextMac.swift
//  Cartouche
//
//  The words of the player's Mac as storage, through Cartouche Builder
//  (CartoucheStorageMac.swift, CartoucheStorageMacView.swift), and of a
//  game's builds there (CartoucheMacBuildsView.swift), in
//  Cartouche.xcstrings with the others (CartoucheText.swift).
//

import Foundation

extension CartoucheText {
    // MARK: Your Mac, through Cartouche Builder

    static var storageAddMac: String { s("storage.mac.add", "Add your Mac (Cartouche Builder)") }
    static var storageMacTitle: String { s("storage.mac.title", "Your Mac") }
    static var storageMacNearby: String { s("storage.mac.nearby", "Macs nearby") }
    static var storageMacLooking: String { s("storage.mac.looking", "Looking for Cartouche Builder on this network…") }
    static var storageMacHow: String { s("storage.mac.how", "On your Mac, open Cartouche Builder and turn on Share with Cartouche on the iPhone, on its iPhone page. This iPhone and the Mac must be on the same Wi-Fi.") }
    static var storageMacPairAgain: String { s("storage.mac.pairAgain", "Choose your Mac again to pair once more, when it no longer knows this iPhone.") }
    static var storageMacPaired: String { s("storage.mac.paired", "Paired") }
    static var storageMacAdded: String { s("storage.mac.added", "Added") }
    static var storageMacLocalNetwork: String { s("storage.mac.localNetwork", "iOS does not let Cartouche look for your Mac: allow Cartouche in Settings › Privacy & Security › Local Network.") }
    static func storageMacReaching(_ name: String) -> String { f("storage.mac.reaching", "Reaching %@…", name) }
    static func storageMacPairing(_ name: String) -> String { f("storage.mac.pairing", "Pairing with %@", name) }
    static var storageMacCheckCode: String { s("storage.mac.checkCode", "Check that your Mac shows the same digits, then click Allow on it.") }
    static var storageMacUseGames: String { s("storage.mac.useGames", "Install your games from this Mac") }
    static var storageMacUseSaves: String { s("storage.mac.useSaves", "Keep your saves on this Mac") }
    static var storageMacUseFooter: String { s("storage.mac.use.footer", "Its Games folder holds the games Cartouche Builder builds, on the Mac or on your NAS, and its Saves folder the copies of your saves. You can change both later in Storage.") }
    static var storageMacLastAddress: String { s("storage.mac.lastAddress", "Last address") }
    static func storageMacOffline(_ mac: String) -> String { f("storage.mac.offline", "%@ does not answer on this network. Open Cartouche Builder on it with Share with Cartouche on the iPhone turned on: Cartouche tries again as soon as the iPhone is back on its Wi-Fi or on your VPN.", mac) }
    static func storageMacNotFound(_ item: String) -> String { f("storage.mac.notFound", "%@ is not on the Mac.", item) }
    static func storageMacDenied(_ item: String) -> String { f("storage.mac.denied", "The Mac does not let Cartouche reach %@.", item) }
    static func storageMacExists(_ item: String) -> String { f("storage.mac.exists", "%@ is already on the Mac.", item) }
    static func storageMacLost(_ mac: String) -> String { f("storage.mac.lost", "The connection to %@ was lost.", mac) }
    static func storageMacNotPaired(_ mac: String) -> String { f("storage.mac.notPaired", "%@ no longer knows this iPhone: pair it again in Storage.", mac) }
    static func storageMacRefused(_ mac: String) -> String { f("storage.mac.refused", "%@ did not allow this iPhone.", mac) }
    static func storageMacBusy(_ mac: String) -> String { f("storage.mac.busy", "%@ is pairing another iPhone, or was asked too often: try again in a few minutes.", mac) }
    static var storageMacUpdate: String { s("storage.mac.update", "Cartouche and Cartouche Builder do not speak the same version of the bridge: update both.") }
    static func storageMacFailed(_ mac: String, _ message: String) -> String { f("storage.mac.failed", "%1$@ could not do it: %2$@", mac, message) }

    // MARK: A game's builds on your Mac (CartoucheMacBuildsView.swift)

    static func macBuildsTitle(_ mac: String) -> String { f("mac.builds.title", "Builds on %@", mac) }
    static func macBuildsTooOld(_ mac: String) -> String { f("mac.builds.tooOld", "Update the app on %@ to see its builds here and start one.", mac) }
    static var macBuildsFooter: String { s("mac.builds.footer", "Once built, the game is in the Mac’s games folder, where Cartouche offers to install it or update it.") }
    static func macBuildBuilding(_ percent: String) -> String { f("mac.build.building", "Building on the Mac, %@", percent) }
    static var macBuildBuildingNow: String { s("mac.build.building.now", "Building on the Mac") }
    static func macBuildLeft(_ duration: String) -> String { f("mac.build.left", "about %@ left", duration) }
    static var macBuildNext: String { s("mac.build.next", "Next to build on the Mac") }
    static var macBuildWaiting: String { s("mac.build.waiting", "Waiting its turn on the Mac") }
    static var macBuildWaitingOne: String { s("mac.build.waiting.one", "Waiting its turn on the Mac, after 1 game") }
    static func macBuildWaitingAfter(_ count: Int) -> String { f("mac.build.waiting.after", "Waiting its turn on the Mac, after %lld games", count) }
    static var macBuildNew: String { s("mac.build.new", "Never built on the Mac") }
    static var macBuildImproved: String { s("mac.build.improved", "nxnative improved it since its last build on the Mac") }
    static var macBuildUpToDate: String { s("mac.build.upToDate", "Up to date on the Mac") }
    static func macBuildUpToDateBuilt(_ date: String) -> String { f("mac.build.upToDate.built", "Up to date on the Mac, built %@", date) }
    static var macBuildFailed: String { s("mac.build.failed", "Its last build on the Mac failed") }
    static func macBuildFailedOn(_ date: String) -> String { f("mac.build.failed.on", "Its last build on the Mac failed, %@", date) }
    static var macBuildNotFollowed: String { s("mac.build.notFollowed", "Not followed on the Mac: built there only when you ask") }
    static var macBuildNoProfile: String { s("mac.build.noProfile", "nxnative has no profile for it yet: the Mac builds it once it has one") }
    static var macBuildIPAOnly: String { s("mac.build.ipaOnly", "Only its IPA is on the Mac: its dump is not in the Mac’s sources folder") }
    static var macBuildActionBuild: String { s("mac.build.action.build", "Build on the Mac") }
    static var macBuildActionRebuild: String { s("mac.build.action.rebuild", "Rebuild on the Mac") }
    static var macBuildActionAgain: String { s("mac.build.action.again", "Build again on the Mac") }
    static var macBuildActionQueue: String { s("mac.build.action.queue", "Add to the Mac’s queue") }
    static var macBuildAsking: String { s("mac.build.asking", "Asking the Mac…") }
    static var macBuildsAll: String { s("mac.builds.all", "All the Mac’s builds") }
    static var macBuildsBuilding: String { s("mac.builds.building", "Building") }
    static var macBuildsWaiting: String { s("mac.builds.waiting", "Waiting their turn") }
    static var macBuildsDone: String { s("mac.builds.done", "Finished") }
    static var macBuildsNone: String { s("mac.builds.none", "Nothing built on the Mac yet") }
    static func macBuildsBuilt(_ date: String) -> String { f("mac.builds.built", "Built %@", date) }
    static func macBuildsFailed(_ date: String) -> String { f("mac.builds.failed", "Failed %@", date) }
}
