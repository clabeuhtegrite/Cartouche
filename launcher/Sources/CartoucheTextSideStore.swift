//
//  CartoucheTextSideStore.swift
//  Cartouche
//
//  What Cartouche tells the player of the built-in SideStore's error, in
//  Cartouche.xcstrings with the other words (CartoucheText.swift): its own
//  words when Apple limits the requests or answers with a page, which
//  SideStore's would show as they are. A file of its own, since it reads
//  CartoucheFailure and CartoucheSignInMessage, which the storage tests
//  (launcher/StorageTests) build CartoucheText.swift without.
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
        case nil: return readable
        }
    }
}
