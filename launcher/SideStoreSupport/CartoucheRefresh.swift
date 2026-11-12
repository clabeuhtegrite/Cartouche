//
//  CartoucheRefresh.swift
//  Cartouche
//
//  Lets Cartouche's System tab renew the app without leaving it. It runs
//  the same refresh as the Refresh All Apps action of Shortcuts: the
//  built-in SideStore starts in LiveProcess, renews Cartouche, and no other
//  app (app/patches/sidestore/0017), and reports its progress.
//
//  This file joins LiveContainer's SideStoreSupport framework, which
//  LiveContainer loads when the app carries the built-in SideStore. The
//  launcher cannot import that framework, so it finds this class by its
//  Objective-C name.
//

import Foundation

@objc(CartoucheRefresh)
public final class CartoucheRefresh: NSObject {
    /// Renews Cartouche through the built-in SideStore. `progress` counts to
    /// 100; `completion` runs on the main queue, with nil or the error's text.
    @objc(refreshAllAppsWithProgress:completion:)
    public static func refreshAllApps(progress: Progress, completion: @escaping (String?) -> Void) {
        guard #available(iOS 17.0, *) else {
            completion("Renewing from Cartouche needs iOS 17 or later.")
            return
        }
        Task { @MainActor in
            do {
                // The names the Refresh All Apps action passes (SideStore.swift).
                try await performIntentRefresh(
                    identifier: "RefreshAllIntent",
                    mangledTypeName: "9SideStore20RefreshAllAppsIntentV",
                    intentProgress: progress)
                completion(nil)
            } catch {
                completion(error.localizedDescription)
            }
        }
    }
}
