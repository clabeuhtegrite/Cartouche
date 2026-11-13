//
//  CartoucheRenewal.swift
//  Cartouche
//
//  Renewing Cartouche before its signature expires, and warning the player
//  in time. The built-in SideStore does the renewal: from the System page,
//  through CartoucheRefresh (launcher/SideStoreSupport), or every night,
//  through an automation in Shortcuts that runs its Refresh All Apps action.
//

import Foundation
import UIKit
import UserNotifications

@available(iOS 17.0, *)
enum CartoucheRenewal {
    struct Failure: LocalizedError, CartoucheExplainedError {
        let message: String
        /// Why, as the built-in SideStore left it (CartoucheSideStoreOutcome).
        var failure: CartoucheFailure?
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

    static var canRenew: Bool { !CartoucheImportedSigning.accountSigningDisabled && refreshAllApps != nil }

    /// Whether Renew now is under way, which a reset of Cartouche waits for
    /// (CartoucheReset).
    @MainActor private(set) static var isRenewing = false

    /// Renews Cartouche without leaving the app; its SideStore renews no
    /// other app (app/patches/sidestore/0017). LocalDevVPN has to be
    /// connected. A failure says why, as SideStore left it.
    ///
    /// SideStore can stop, or iOS end it, as it finishes, before it says how
    /// the renewal went: Cartouche then reads the signature SideStore
    /// records for it. Newer than before, the renewal went through;
    /// otherwise Cartouche asks a new SideStore, once.
    @MainActor
    static func renew(progress: Progress) async throws {
        guard !CartoucheImportedSigning.accountSigningDisabled else {
            throw Failure(message: CartoucheText.signingUpdateOnComputer, failure: nil)
        }
        guard let refresh = refreshAllApps else {
            throw Failure(message: CartoucheText.renewUnavailable, failure: CartoucheFailure(.bridgeMissing, stage: "start"))
        }
        isRenewing = true
        defer { isRenewing = false }
        let started = Date()
        var attempt = 1
        while true {
            let before = CartoucheSignature.current()
            CartoucheStoreKeychain.remove(CartoucheSideStoreOutcome.account)
            let message: String? = await withCheckedContinuation { continuation in
                refresh.call(refresh.receiver, refreshSelector, progress) { message in
                    continuation.resume(returning: message.map { $0 as String })
                }
            }
            let outcome = CartoucheStoreKeychain.data(CartoucheSideStoreOutcome.account)
                .flatMap { CartoucheSideStoreOutcome(data: $0, expecting: .refresh) }
            CartoucheStoreKeychain.remove(CartoucheSideStoreOutcome.account)
            let seconds = Date().timeIntervalSince(started)
            let failure = message.map {
                CartoucheFailure.sideStore(outcome: outcome, message: $0, fraction: progress.fractionCompleted,
                                           seconds: seconds, vpn: CartoucheVPN.isConnected, pairing: CartouchePairing.exists)
            }
            let renewed = CartoucheSignature.current().isRenewal(of: before)
            switch CartoucheFailure.renewalEnd(failure: failure, outcome: outcome, renewed: renewed) {
            case .renewed(let despite):
                var fields = CartoucheFailure.sideStoreSuccess(outcome: outcome, seconds: seconds)
                if let despite {
                    CartoucheReports.note("Renewal: SideStore failed on its way back (\(despite.cause.rawValue)), yet Cartouche is renewed")
                    fields["recovered"] = .flag(true)
                    fields["cause"] = .text(despite.cause.rawValue)
                }
                if attempt > 1 {
                    fields["attempts"] = .number(Double(attempt))
                }
                CartoucheTelemetry.shared.event("renewal.done", fields: fields)
                return
            case .quit where attempt == 1:
                // A new SideStore starts in a new LiveProcess, LiveContainer's
                // bridge having let the last one go.
                CartoucheReports.note("Renewal: SideStore quit before it answered, asking again")
                attempt += 1
                progress.completedUnitCount = 0
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            case .quit, .failed:
                guard let message, let failure else {
                    throw Failure(message: CartoucheText.renewFailed, failure: failure)
                }
                // Never Apple's page for an error, as SideStore's words would show it.
                throw Failure(message: CartoucheText.sideStoreMessage(message, failure: failure), failure: failure)
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

    /// Where the warnings are scheduled, one call after the other, away from
    /// the main thread: removePendingNotificationRequests waits there for
    /// usernotificationsd to answer, which can take minutes right after the
    /// iPhone starts. On the iPhone Duo simulator of run 42266582948, the
    /// games page's first frame waited for it for more than five minutes,
    /// on a white screen.
    private static let warningQueue = DispatchQueue(label: "io.github.clabeuhtegrite.cartouche.warnings", qos: .utility)

    /// Schedules the warnings for the current expiry date. Without the
    /// player's permission iOS drops them, so this is safe to call often. It
    /// returns at once: warningQueue does the work.
    static func scheduleWarnings() {
        warningQueue.async {
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
