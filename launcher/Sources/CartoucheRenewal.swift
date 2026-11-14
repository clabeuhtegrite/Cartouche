//
//  CartoucheRenewal.swift
//  Cartouche
//
//  Renewing Cartouche before its signature expires, and warning the player
//  in time. The built-in SideStore does the renewal: from the System page,
//  and by itself each time Cartouche comes to the front in the last days of
//  its signature (CartoucheAutomaticRenewal), through CartoucheRefresh
//  (launcher/SideStoreSupport), or every night, through an automation in
//  Shortcuts that runs its Refresh All Apps action.
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

    /// Renews Cartouche without leaving the app; its SideStore renews no
    /// other app (app/patches/sidestore/0017). LocalDevVPN has to be
    /// connected. A failure says why, as SideStore left it. AUTOMATIC:
    /// Cartouche renews itself, as it came to the front, and renewal.done
    /// says so, as it says whether Cartouche had LocalDevVPN connect for it
    /// (VPN).
    ///
    /// SideStore can stop, or iOS end it, as it finishes, before it says how
    /// the renewal went: Cartouche then reads the signature SideStore
    /// records for it. Newer than before, the renewal went through;
    /// otherwise Cartouche asks a new SideStore, once.
    @MainActor
    static func renew(progress: Progress, automatic: Bool = false,
                      vpn: CartoucheLocalDevVPN.Connection = .connectedAlready) async throws {
        guard !CartoucheImportedSigning.accountSigningDisabled else {
            throw Failure(message: CartoucheText.signingUpdateOnComputer, failure: nil)
        }
        guard let refresh = refreshAllApps else {
            throw Failure(message: CartoucheText.renewUnavailable, failure: CartoucheFailure(.bridgeMissing, stage: "start"))
        }
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
                fields["automatic"] = .flag(automatic)
                note(vpn, in: &fields)
                CartoucheTelemetry.shared.renewed(fields: fields)
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

    /// Whether Cartouche opened LocalDevVPN for what it measures, and how
    /// long it then waited for it in front: `vpnOpened` and `vpnWait`.
    static func note(_ vpn: CartoucheLocalDevVPN.Connection, in fields: inout [String: CartoucheTelemetryValue]) {
        guard vpn.opened else { return }
        fields["vpnOpened"] = .flag(true)
        fields["vpnWait"] = .number(vpn.seconds)
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

/// The renewal under way, from Renew now or by Cartouche itself as it comes
/// to the front, and why the last one failed: one at a time, as the
/// built-in SideStore takes its actions. The System page shows it, and
/// Cartouche's update, its sign-in and the registration of this iPhone wait
/// for its end before they hand SideStore their own: one started meanwhile
/// would fail with "Another refresh task is in progress".
@available(iOS 17.0, *)
@MainActor
final class CartoucheRenewals: ObservableObject {
    static let shared = CartoucheRenewals()

    /// How far the renewal under way has gone.
    @Published private(set) var progress: Progress?
    /// Whether Cartouche started it by itself.
    @Published private(set) var isAutomatic = false
    /// Why the last renewal failed, and the report on it.
    @Published private(set) var report: CartoucheReport?

    var isRenewing: Bool { progress != nil }

    /// When Cartouche last renewed itself, or tried to, kept across
    /// launches.
    static let lastTryKey = "Cartouche.renewal.automatic.last"

    /// How long an update, a sign-in or the registration of this iPhone
    /// waits for the renewal under way before it goes on: three minutes,
    /// when the longest renewal the measurements saw in the week of
    /// November 10 took 71 seconds. A renewal that never ends, SideStore no
    /// longer answering, holds them up no longer: SideStore, still at it,
    /// may then refuse them, and Cartouche says why.
    var waitLimit: TimeInterval = 180

    private init() {}

    /// Whether the built-in SideStore is at an action of Cartouche's: a
    /// renewal, an update, a sign-in or the registration of this iPhone,
    /// under way or waiting for LocalDevVPN.
    var sideStoreBusy: Bool {
        isRenewing || CartoucheUpdates.shared.phase != nil || CartoucheAccount.shared.phase != nil
    }

    /// Whether the player can renew now: Cartouche set up, and SideStore
    /// free.
    var canRenewNow: Bool {
        CartoucheRenewal.canRenew && CartoucheSetup.shared.isComplete && !sideStoreBusy
    }

    /// What Cartouche finds as it comes to the front.
    var situation: CartoucheAutomaticRenewal.Situation {
        let setup = CartoucheSetup.shared
        return CartoucheAutomaticRenewal.Situation(
            daysLeft: CartoucheSignature.current().daysLeft,
            canRenew: CartoucheRenewal.canRenew,
            isSetUp: setup.isComplete && !setup.needsDevice,
            vpnConnected: CartoucheLocalDevVPN.isConnected,
            sideStoreBusy: sideStoreBusy,
            signInsPaused: CartoucheAccount.shared.pausedUntil != nil,
            gameRunning: CartoucheGameActions.shared.running != nil,
            lastTry: UserDefaults.standard.object(forKey: Self.lastTryKey) as? Date)
    }

    /// Renew now, from the System page.
    func renewNow() {
        guard canRenewNow else { return }
        start(automatic: false)
    }

    /// Renews Cartouche by itself when it is due (CartoucheAutomaticRenewal):
    /// CartoucheSetupRefresh calls it each time Cartouche comes to the front,
    /// and once the setup is found complete, a few seconds after the launch.
    /// When only LocalDevVPN is missing, Cartouche has it connect first, if
    /// it can open it (CartoucheLocalDevVPN): otherwise it counts no try,
    /// and renews itself as it comes back once LocalDevVPN is connected.
    func renewIfDue() {
        let situation = self.situation
        switch CartoucheAutomaticRenewal.wait(situation, at: Date()) {
        case nil:
            break
        case .vpn:
            guard CartoucheLocalDevVPN.shared.decide(playerAsked: false) == .open else { return }
        default:
            return
        }
        UserDefaults.standard.set(Date(), forKey: Self.lastTryKey)
        CartoucheReports.note("Renewal started by itself, \(situation.daysLeft ?? 0) days left")
        start(automatic: true)
    }

    /// Runs ACTION, which hands the built-in SideStore an action, once no
    /// renewal is under way: at once when none is, otherwise once it has
    /// ended, or after `waitLimit` at most. WHAT names the action in the
    /// journal.
    func afterRenewal(_ what: String, _ action: @escaping @MainActor () -> Void) {
        guard isRenewing else {
            action()
            return
        }
        CartoucheReports.note(what + ": waiting for the renewal under way")
        let limit = waitLimit
        Task {
            let started = Date()
            while isRenewing, Date().timeIntervalSince(started) < limit {
                try? await Task.sleep(for: .milliseconds(250))
            }
            if isRenewing {
                CartoucheReports.note(what + ": the renewal under way has not ended after \(Int(limit)) s, going on")
            }
            action()
        }
    }

    private func start(automatic: Bool) {
        let progress = Progress(totalUnitCount: 100)
        self.progress = progress
        isAutomatic = automatic
        report = nil
        if !automatic { CartoucheReports.note("Renewal started") }
        Task {
            // SideStore reaches this iPhone through LocalDevVPN, which
            // Cartouche has connect first, when it is off.
            let vpn = await CartoucheLocalDevVPN.shared.connect(for: "Renewal", playerAsked: !automatic)
            do {
                try await CartoucheRenewal.renew(progress: progress, automatic: automatic, vpn: vpn)
                CartoucheReports.note("Renewal done")
            } catch {
                fail(error, automatic: automatic, fraction: progress.fractionCompleted, vpn: vpn)
            }
            self.progress = nil
            isAutomatic = false
            // SideStore scheduled its own warnings, in English and about
            // SideStore: Cartouche's take their place.
            CartoucheRenewal.scheduleWarnings()
        }
    }

    /// Why the renewal failed, as the System page shows it, and the report
    /// on it, which says whether Cartouche had LocalDevVPN connect for it
    /// (VPN).
    private func fail(_ error: Error, automatic: Bool, fraction: Double,
                      vpn: CartoucheLocalDevVPN.Connection = .connectedAlready) {
        var failure = CartoucheFailure.of(error, fraction: fraction)
        failure.details["automatic"] = .flag(automatic)
        CartoucheRenewal.note(vpn, in: &failure.details)
        report = CartoucheReports.make(.renewal, CartoucheText.renewFailed, message: error.localizedDescription,
                                       error: error,
                                       step: automatic ? "Renewing by itself, before it expires" : CartoucheText.renewing,
                                       fraction: fraction, failure: failure)
    }

    #if CARTOUCHE_GALLERY
    /// Cartouche renewing itself, FRACTION of the way, for the gallery's
    /// screens (launcher/Gallery).
    func showRenewingForGallery(at fraction: Double) {
        let progress = Progress(totalUnitCount: 100)
        progress.completedUnitCount = Int64(fraction * 100)
        self.progress = progress
        isAutomatic = true
    }

    /// The renewal Cartouche started by itself, failed with ERROR, for the
    /// gallery's screens.
    func showFailedForGallery(_ error: Error) {
        fail(error, automatic: true, fraction: 0.3)
    }
    #endif
}
