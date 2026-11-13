//
//  CartoucheTextSideStore.swift
//  Cartouche
//
//  What Cartouche tells the player of the built-in SideStore's error, in
//  Cartouche.xcstrings with the other words (CartoucheText.swift): its own
//  words when Apple limits the requests or answers with a page, which
//  SideStore's would show as they are, and when SideStore could not reach
//  this iPhone for the sign-in, which SideStore's would send to its own
//  settings. A file of its own, since it reads CartoucheFailure and
//  CartoucheSignInMessage, which the storage tests (launcher/StorageTests)
//  build CartoucheText.swift without.
//

import Foundation

extension CartoucheText {
    // MARK: Apple's answers the built-in SideStore could not read

    static var appleTooManyRequests: String { s("apple.tooManyRequests", "Apple is refusing more requests for now, after too many in a short time from this Apple ID or from this network. Wait a while, then try again.") }
    static func applePage(_ status: Int) -> String { f("apple.page", "Apple’s servers sent back an error page (%lld) instead of an answer. Try again in a few minutes.", status) }
    static var appleUnreadable: String { s("apple.unreadable", "Cartouche could not read Apple’s answer. Check this iPhone’s connection, then try again.") }

    /// What Cartouche tells the player of the built-in SideStore's MESSAGE,
    /// FAILURE being what Cartouche told of how its action ended: its own
    /// words when Apple limits the requests or answered with a page, those
    /// of a SIGN-IN when it is one; SideStore's otherwise, without the App
    /// Intents error's name.
    static func sideStoreMessage(_ message: String, failure: CartoucheFailure, signIn: Bool = false) -> String {
        let readable = CartoucheSignInMessage.readable(message)
        switch CartoucheSignInMessage.trouble(in: readable, failure: failure) {
        case .tooManyRequests?: return signIn ? signInTooManyRequests : appleTooManyRequests
        case .unreadable(let status?)?: return applePage(status)
        case .unreadable(nil)?: return appleUnreadable
        case nil:
            guard signIn, let trouble = CartoucheSignInMessage.deviceTrouble(in: failure) else { return readable }
            // Before Apple, or once it accepted the account.
            switch CartoucheSignInMessage.deviceMoment(of: failure) {
            case .beforeApple: return deviceMessage(trouble) + " " + deviceBeforeApple
            case .afterApple: return deviceMessage(trouble) + " " + deviceAfterApple
            case .elsewhere: return deviceMessage(trouble)
            }
        }
    }

    // MARK: This iPhone, through LocalDevVPN

    static var deviceVPN: String { s("signIn.device.vpn", "LocalDevVPN is not connected, or does not carry this iPhone’s traffic. Connect it, or disconnect it and connect it again.") }
    static var deviceWiFi: String { s("signIn.device.wifi", "This iPhone is not on Wi-Fi, which LocalDevVPN needs to reach it. Join a Wi-Fi network.") }
    static var devicePairing: String { s("signIn.device.pairing", "This iPhone did not accept its pairing file. Put the pairing file in Cartouche again with the Cartouche Installer, on your computer.") }
    static var devicePairingRefused: String { s("signIn.device.pairingRefused", "This iPhone refused its pairing file, made before it stopped trusting your computer, or for another device. On your computer, in the Cartouche Installer’s Settings, choose Delete the stored pairing, choose this iPhone again, then Put the pairing file in Cartouche again, and tap Trust on this iPhone when it asks.") }
    static var deviceOlderPairing: String { s("signIn.device.olderPairing", "This iPhone’s pairing file is of an older kind, which Cartouche can no longer use on this iPhone since iOS 26.4. On your computer, choose Put the pairing file in Cartouche again in the Cartouche Installer: it makes one of the newer kind.") }
    static var deviceNoAnswer: String { s("signIn.device.noAnswer", "This iPhone did not answer through LocalDevVPN. Disconnect LocalDevVPN, connect it again, then try again. If it happens again, restart this iPhone.") }
    static var deviceBeforeApple: String { s("signIn.device.beforeApple", "Nothing was sent to Apple yet: sign in again once this is fixed.") }
    static var deviceAfterApple: String { s("signIn.device.afterApple", "Apple accepted your Apple ID: only this iPhone is left to register, which Cartouche does by itself once LocalDevVPN is connected.") }

    /// What to do about TROUBLE.
    static func deviceMessage(_ trouble: CartoucheSignInMessage.DeviceTrouble) -> String {
        switch trouble {
        case .vpn: return deviceVPN
        case .wifi: return deviceWiFi
        case .pairing: return devicePairing
        case .pairingRefused: return devicePairingRefused
        case .olderPairing: return deviceOlderPairing
        case .noAnswer: return deviceNoAnswer
        }
    }

    /// What Cartouche tells the player when registering this iPhone alone
    /// (CartoucheAccount.registerDevice) ended with SideStore's MESSAGE, as
    /// FAILURE tells: what to do when SideStore did not reach the iPhone,
    /// the sign-in's words otherwise.
    static func deviceStepMessage(_ message: String, failure: CartoucheFailure) -> String {
        if let trouble = CartoucheSignInMessage.deviceTrouble(in: failure) { return deviceMessage(trouble) }
        return sideStoreMessage(message, failure: failure, signIn: true)
    }
}
