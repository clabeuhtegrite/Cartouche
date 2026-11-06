//
//  CartoucheRenewal.swift
//  Cartouche
//
//  Renewing Cartouche before its signature expires, and warning the player
//  in time. The built-in SideStore does the renewal: from the System tab,
//  through CartoucheRefresh (launcher/SideStoreSupport), or every night,
//  through an automation in Shortcuts that runs its Refresh All Apps action.
//

import Foundation
import UIKit
import UserNotifications

@available(iOS 17.0, *)
enum CartoucheRenewal {
    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    static let shortcutsURL = URL(string: "shortcuts://")!

    // MARK: Renew now

    private typealias RefreshAllApps = @convention(c) (
        AnyObject, Selector, Progress, @escaping @convention(block) (NSString?) -> Void) -> Void

    private static let refreshSelector = NSSelectorFromString("refreshAllAppsWithProgress:completion:")

    /// CartoucheRefresh is in SideStoreSupport, which LiveContainer loads
    /// only when the app carries the built-in SideStore.
    private static var refreshAllApps: (receiver: AnyObject, call: RefreshAllApps)? {
        guard let refresh = NSClassFromString("CartoucheRefresh"),
              let method = class_getClassMethod(refresh, refreshSelector) else { return nil }
        return (refresh as AnyObject, unsafeBitCast(method_getImplementation(method), to: RefreshAllApps.self))
    }

    static var canRenew: Bool { refreshAllApps != nil }

    /// Renews Cartouche, and every app its SideStore manages, without
    /// leaving the app. LocalDevVPN has to be connected.
    @MainActor
    static func renew(progress: Progress) async throws {
        guard let refresh = refreshAllApps else {
            throw Failure(message: CartoucheText.renewUnavailable)
        }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            refresh.call(refresh.receiver, refreshSelector, progress) { message in
                if let message {
                    continuation.resume(throwing: Failure(message: message as String))
                } else {
                    continuation.resume()
                }
            }
        }
    }

    // MARK: Warnings before expiry

    /// SideStore schedules its own warnings under these identifiers each
    /// time it renews (ScheduleExpirationWarningNotificationOperation), in
    /// English and about "SideStore". Cartouche's replace them, and theirs
    /// replace Cartouche's after a renewal in the background, so that only
    /// one of each shows, always for the latest expiry date.
    private static var warnings: [(identifier: String, before: TimeInterval, title: String, body: String)] {
        [
            ("sidestore-expiration-warning.24h", 24 * 3600, CartoucheText.warning24hTitle, CartoucheText.warningBody),
            ("sidestore-expiration-warning.6h", 6 * 3600, CartoucheText.warning6hTitle, CartoucheText.warningBody),
            ("sidestore-expiration-warning.0h", 0, CartoucheText.warningExpiredTitle, CartoucheText.warningExpiredBody),
        ]
    }

    /// Schedules the warnings for the current expiry date. Without the
    /// player's permission iOS drops them, so this is safe to call often.
    static func scheduleWarnings() {
        let center = UNUserNotificationCenter.current()
        let warnings = Self.warnings
        center.removePendingNotificationRequests(withIdentifiers: warnings.map(\.identifier))
        guard let expirationDate = CartoucheSignature.current().expirationDate else { return }
        for warning in warnings {
            let interval = expirationDate.addingTimeInterval(-warning.before).timeIntervalSinceNow
            guard interval > 0 else { continue }
            let content = UNMutableNotificationContent()
            content.title = warning.title
            content.body = warning.body
            content.sound = .default
            let trigger = UNTimeIntervalNotificationTrigger(timeInterval: interval, repeats: false)
            let identifier = warning.identifier
            center.add(UNNotificationRequest(identifier: identifier, content: content, trigger: trigger)) { error in
                if let error {
                    NSLog("[Cartouche] cannot schedule %@: %@", identifier, String(describing: error))
                }
            }
        }
    }

    static func alertStatus() async -> UNAuthorizationStatus {
        await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
    }

    /// Asks for the permission to warn, then schedules the warnings.
    static func allowAlerts() async {
        _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
        scheduleWarnings()
    }

    @MainActor
    static var notificationSettingsURL: URL? {
        URL(string: UIApplication.openNotificationSettingsURLString)
    }
}
