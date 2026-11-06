//
//  CartoucheUpdate.swift
//  Cartouche
//
//  Lets Cartouche update itself without a computer, and without showing
//  SideStore. The built-in SideStore starts in LiveProcess, as it does to
//  renew the app (CartoucheRefresh), and runs its Update Cartouche action
//  (app/patches/sidestore/0010): it reads Cartouche's source, downloads the
//  newest version, signs it and installs it over the app, and reports its
//  progress.
//
//  This file joins LiveContainer's SideStoreSupport framework, which
//  LiveContainer loads when the app carries the built-in SideStore. The
//  launcher cannot import that framework, so it finds this class by its
//  Objective-C name (CartoucheUpdates).
//

import Foundation

@objc(CartoucheUpdate)
public final class CartoucheUpdate: NSObject {
    /// Installs the newest version of Cartouche that its source lists.
    /// `progress` counts to 100; `completion` runs on the main queue, with
    /// nil or the error's text.
    @objc(updateCartoucheWithProgress:completion:)
    public static func updateCartouche(progress: Progress, completion: @escaping (String?) -> Void) {
        guard #available(iOS 17.0, *) else {
            completion("Updating from Cartouche needs iOS 17 or later.")
            return
        }
        Task { @MainActor in
            do {
                // UpdateCartoucheIntent, in SideStore's module.
                try await performIntentRefresh(
                    identifier: "UpdateCartoucheIntent",
                    mangledTypeName: "9SideStore21UpdateCartoucheIntentV",
                    intentProgress: progress)
                completion(nil)
            } catch {
                completion(error.localizedDescription)
            }
        }
    }
}
