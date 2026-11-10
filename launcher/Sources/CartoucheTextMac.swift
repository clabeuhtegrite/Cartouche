//
//  CartoucheTextMac.swift
//  Cartouche
//
//  The words of the player's Mac as storage, through Cartouche Builder
//  (CartoucheStorageMac.swift, CartoucheStorageMacView.swift), in
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
}
