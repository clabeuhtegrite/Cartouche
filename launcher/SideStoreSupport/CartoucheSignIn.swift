//
//  CartoucheSignIn.swift
//  Cartouche
//
//  Lets the player sign the built-in SideStore in with their Apple ID from
//  Cartouche's own screens, without showing SideStore. The built-in SideStore
//  starts in LiveProcess, as it does to renew the app (CartoucheRefresh), and
//  runs its Sign In to Cartouche action (app/patches/sidestore/0011) with the
//  Apple ID and password Cartouche left in their shared keychain; it asks for
//  a verification code through the same keychain (CartoucheSignInMessage).
//
//  This file joins LiveContainer's SideStoreSupport framework, which
//  LiveContainer loads when the app carries the built-in SideStore. The
//  launcher cannot import that framework, so it finds this class by its
//  Objective-C name (CartoucheAccount).
//

import Foundation

@objc(CartoucheSignIn)
public final class CartoucheSignIn: NSObject {
    /// Signs SideStore in with the Apple ID in the keychain. `progress`
    /// counts to 100; `completion` runs on the main queue, with nil or the
    /// error's text.
    @objc(signInWithProgress:completion:)
    public static func signIn(progress: Progress, completion: @escaping (String?) -> Void) {
        guard #available(iOS 17.0, *) else {
            completion("Signing in from Cartouche needs iOS 17 or later.")
            return
        }
        Task { @MainActor in
            do {
                // CartoucheSignInIntent, in SideStore's module.
                try await performIntentRefresh(
                    identifier: "CartoucheSignInIntent",
                    mangledTypeName: "9SideStore21CartoucheSignInIntentV",
                    intentProgress: progress)
                completion(nil)
            } catch {
                completion(error.localizedDescription)
            }
        }
    }
}
