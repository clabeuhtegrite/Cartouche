//
//  CartoucheUpdates.swift
//  Cartouche
//
//  Cartouche's own updates, without a computer and without showing
//  SideStore. Cartouche reads its source, the one its built-in SideStore
//  reads (CartoucheSourceURL in its Info.plist, from app/config.env), when
//  it opens and, at most once an hour, when it comes back, and offers a
//  higher version than its own over the console, once a day at most. The
//  System page always shows it.
//
//  The built-in SideStore installs it, in LiveProcess, as it renews the
//  app: its Update Cartouche action (app/patches/sidestore/0010) through
//  the bridge CartoucheUpdate (launcher/SideStoreSupport). iOS replaces an
//  app only once it has left the screen, so when SideStore starts the
//  install it says so with a Darwin notification, and Cartouche goes to the
//  home screen by itself. iOS closes it and installs the new version; the
//  player opens Cartouche again, which says how it went.
//

import Foundation
import UIKit

/// Why an update could not start or finish.
struct CartoucheUpdateError: LocalizedError, CartoucheExplainedError {
    let message: String
    var failure: CartoucheFailure?
    var errorDescription: String? { message }
}

@available(iOS 17.0, *)
@MainActor
final class CartoucheUpdates: ObservableObject {
    static let shared = CartoucheUpdates()

    enum Phase: Equatable {
        /// SideStore downloads, checks and signs the new version.
        case preparing
        /// SideStore installs it, which iOS does once Cartouche has left the
        /// screen.
        case installing
    }

    /// The newest version the source lists for this iOS, when it is higher
    /// than this one.
    @Published private(set) var available: CartoucheRelease?
    /// Whether the console asks the player about it.
    @Published private(set) var isOffered = false
    @Published private(set) var isChecking = false
    /// When the source was last read.
    @Published private(set) var checked: Date?
    /// Why the source could not be read, the last time, and the report on
    /// it.
    @Published private(set) var checkReport: CartoucheReport?
    var checkProblem: String? { checkReport?.message }
    /// The version being installed, and how far it has gone.
    @Published private(set) var target: CartoucheRelease?
    @Published private(set) var phase: Phase?
    @Published private(set) var progress: Progress?
    /// When the update started.
    private var started: Date?
    /// Why the last update failed, for the System page, and the report on
    /// it.
    @Published private(set) var problemReport: CartoucheReport?
    var problem: String? { problemReport?.message }
    /// What came of an update, over the console.
    @Published private(set) var notice: CartoucheGameNotice?

    private let defaults = UserDefaults.standard
    private var checking: Task<Void, Never>?
    private var background: UIBackgroundTaskIdentifier = .invalid

    /// The version being installed, kept until Cartouche opens again: iOS
    /// closes it to install the new one.
    private static let pendingKey = "Cartouche.update.pending"
    /// The version the player put off, and when.
    private static let laterVersionKey = "Cartouche.update.later.version"
    private static let laterDateKey = "Cartouche.update.later.date"

    private init() {
        observeInstall()
        reportPendingUpdate()
    }

    // MARK: This version and the source

    /// Cartouche's version (app/config.env).
    static var runningVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    /// Cartouche's bundle identifier without the team suffix, which its
    /// source names it by (app/scripts/package.sh).
    private static var bundleIdentifier: String? {
        Bundle.main.object(forInfoDictionaryKey: "CartoucheBundleIdentifier") as? String
    }

    /// The source the built-in SideStore reads (app/scripts/package.sh).
    private static var sourceURL: URL? {
        guard let text = Bundle.main.object(forInfoDictionaryKey: "CartoucheSourceURL") as? String,
              let url = URL(string: text), url.scheme == "https" else { return nil }
        return url
    }

    // MARK: The bridge to the built-in SideStore

    private typealias UpdateCartouche = @convention(c) (
        AnyObject, Selector, Progress, @escaping @convention(block) (NSString?) -> Void) -> Void

    private static let updateSelector = NSSelectorFromString("updateCartoucheWithProgress:completion:")

    /// CartoucheUpdate is in SideStoreSupport, which LiveContainer loads only
    /// when the app carries the built-in SideStore.
    private static var bridge: (receiver: AnyObject, call: UpdateCartouche)? {
        guard let update = NSClassFromString("CartoucheUpdate"),
              let method = class_getClassMethod(update, updateSelector) else { return nil }
        return (update as AnyObject, unsafeBitCast(method_getImplementation(method), to: UpdateCartouche.self))
    }

    /// Whether this build can update itself.
    var canUpdate: Bool { !CartoucheImportedSigning.accountSigningDisabled && Self.bridge != nil && Self.sourceURL != nil && Self.bundleIdentifier != nil }

    /// Whether the player can start the update now: the built-in SideStore
    /// needs the certificate and the pairing file, as for a renewal.
    var canStart: Bool {
        canUpdate && phase == nil && available != nil && CartoucheSetup.shared.isComplete
    }

    /// Whether the console shows the offer, the update or what came of it.
    var isShowing: Bool {
        phase != nil || notice != nil || (isOffered && available != nil)
    }

    // MARK: Checking

    /// Reads the source, unless it was read less than an hour ago.
    func checkIfDue() {
        if let checked, Date().timeIntervalSince(checked) < 3600 { return }
        check(offering: true)
    }

    /// Reads the source now, from the System page: a new version shows
    /// there, without the console's offer.
    func checkNow() {
        check(offering: false)
    }

    private func check(offering: Bool) {
        guard checking == nil, phase == nil, let url = Self.sourceURL, let bundleIdentifier = Self.bundleIdentifier else { return }
        isChecking = true
        checking = Task {
            defer {
                isChecking = false
                checking = nil
            }
            do {
                let newest = try await Self.newest(at: url, bundleIdentifier: bundleIdentifier)
                checked = Date()
                checkReport = nil
                if let newest, CartoucheVersion.isHigher(newest.version, than: Self.runningVersion) {
                    available = newest
                    if offering && shouldOffer(newest) { isOffered = true }
                } else {
                    available = nil
                    isOffered = false
                }
            } catch {
                // A check Cartouche makes by itself fails whenever the
                // iPhone is offline: its report is not kept.
                checkReport = CartoucheReports.make(.update, CartoucheText.updateCheckFailedTitle,
                                                    message: CartoucheText.updateCheckFailed(error.localizedDescription),
                                                    error: error, step: "Reading Cartouche's source", stage: "source",
                                                    inBackground: offering)
            }
        }
    }

    nonisolated private static func newest(at url: URL, bundleIdentifier: String) async throws -> CartoucheRelease? {
        let request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200 ..< 300).contains(http.statusCode) {
            throw CartoucheUpdateError(message: CartoucheText.updateSourceStatus(http.statusCode),
                                       failure: CartoucheFailure(.serverStatus, stage: "source",
                                                                 details: ["http": .number(Double(http.statusCode))]))
        }
        let system = ProcessInfo.processInfo.operatingSystemVersion
        let systemVersion = "\(system.majorVersion).\(system.minorVersion).\(system.patchVersion)"
        return try CartoucheRelease.newest(in: data, bundleIdentifier: bundleIdentifier, systemVersion: systemVersion)
    }

    /// Offered once a day at most, and only once Cartouche is set up.
    private func shouldOffer(_ release: CartoucheRelease) -> Bool {
        guard canUpdate, phase == nil, notice == nil, CartoucheSetup.shared.isComplete else { return false }
        if defaults.string(forKey: Self.laterVersionKey) == release.version,
           let asked = defaults.object(forKey: Self.laterDateKey) as? Date,
           Date().timeIntervalSince(asked) < 24 * 3600 {
            return false
        }
        return true
    }

    /// The player puts the update off: the console asks again tomorrow.
    func later() {
        isOffered = false
        guard let available else { return }
        defaults.set(available.version, forKey: Self.laterVersionKey)
        defaults.set(Date(), forKey: Self.laterDateKey)
    }

    func dismissNotice() {
        notice = nil
    }

    #if CARTOUCHE_GALLERY
    /// A version on offer, for the launcher's gallery (launcher/Gallery).
    func offerForGallery(_ release: CartoucheRelease) {
        available = release
        isOffered = true
    }
    #endif

    // MARK: Updating

    /// Has the built-in SideStore install the available version.
    func start() {
        guard !CartoucheImportedSigning.accountSigningDisabled else { return }
        guard phase == nil, let release = available else { return }
        isOffered = false
        notice = nil
        problemReport = nil
        CartoucheReports.note("Update to Cartouche " + release.version + " started")
        guard let bridge = Self.bridge else {
            failed(CartoucheText.updateUnavailable, version: release.version, step: nil, fraction: nil,
                   failure: CartoucheFailure(.bridgeMissing, stage: "start"))
            return
        }
        let progress = Progress(totalUnitCount: 100)
        self.progress = progress
        target = release
        phase = .preparing
        started = Date()
        defaults.set(release.version, forKey: Self.pendingKey)
        // SideStore takes one action at a time: a renewal under way, as when
        // Cartouche renews itself as it opens, ends first.
        let selector = Self.updateSelector
        CartoucheRenewals.shared.afterRenewal("Update") { [weak self] in
            CartoucheStoreKeychain.remove(CartoucheSideStoreOutcome.account)
            bridge.call(bridge.receiver, selector, progress) { message in
                let text = message.map { $0 as String }
                Task { @MainActor in self?.finished(text) }
            }
        }
    }

    /// SideStore is done: iOS has not closed Cartouche, so the install
    /// either failed or finished while Cartouche was still running.
    private func finished(_ message: String?) {
        let version = target?.version ?? ""
        let step = phase == .installing ? CartoucheText.updateInstallingTitle(version) : CartoucheText.updatePreparingTitle(version)
        let fraction = phase == .preparing ? progress?.fractionCompleted : nil
        let seconds = started.map { Date().timeIntervalSince($0) }
        phase = nil
        progress = nil
        target = nil
        started = nil
        endBackground()
        defaults.removeObject(forKey: Self.pendingKey)
        // How SideStore's action ended, which it left for Cartouche.
        let outcome = Self.takeOutcome()
        if let message {
            let failure = CartoucheFailure.sideStore(outcome: outcome, message: message, fraction: fraction, seconds: seconds,
                                                     vpn: CartoucheVPN.isConnected, pairing: CartouchePairing.exists)
            // Never Apple's page for an error, as SideStore's words would show it.
            failed(CartoucheText.sideStoreMessage(message, failure: failure), version: version, step: step, fraction: fraction,
                   failure: failure)
        } else {
            CartoucheReports.note("Update to Cartouche " + version + " installed")
            notice = CartoucheGameNotice(title: CartoucheText.updateInstalledTitle(version), message: CartoucheText.updateInstalledMessage)
        }
    }

    /// What the built-in SideStore left of how its last update ended, once:
    /// AGE at most ago.
    private static func takeOutcome(maximumAge: TimeInterval = 3_600) -> CartoucheSideStoreOutcome? {
        let outcome = CartoucheStoreKeychain.data(CartoucheSideStoreOutcome.account)
            .flatMap { CartoucheSideStoreOutcome(data: $0, expecting: .update, maximumAge: maximumAge) }
        if outcome != nil {
            CartoucheStoreKeychain.remove(CartoucheSideStoreOutcome.account)
        }
        return outcome
    }

    /// The update to VERSION failed at STEP, as SideStore's MESSAGE says,
    /// for the reason FAILURE gives.
    private func failed(_ message: String, version: String, step: String?, fraction: Double?, failure: CartoucheFailure) {
        let report = CartoucheReports.make(.update, CartoucheText.updateFailedTitle, message: message, step: step,
                                           fraction: fraction, failure: failure, facts: [.init("New version", version)])
        problemReport = report
        notice = CartoucheGameNotice(title: CartoucheText.updateFailedTitle, message: CartoucheText.updateFailed(message), report: report)
    }

    /// What came of the update that was under way when Cartouche closed.
    private func reportPendingUpdate() {
        guard let pending = defaults.string(forKey: Self.pendingKey) else { return }
        defaults.removeObject(forKey: Self.pendingKey)
        let running = Self.runningVersion
        if CartoucheVersion.isHigher(pending, than: running) {
            let message = CartoucheText.updateUnfinished(pending)
            // SideStore may have ended after Cartouche left the screen: what
            // it left says how, a day at most after.
            var failure = CartoucheFailure.sideStore(outcome: Self.takeOutcome(maximumAge: 86_400), message: nil, fraction: nil,
                                                     seconds: nil, vpn: nil, pairing: nil)
            failure.details["unfinished"] = .flag(true)
            let report = CartoucheReports.make(.update, CartoucheText.updateUnfinishedTitle, message: message,
                                               failure: failure, facts: [.init("New version", pending)])
            notice = CartoucheGameNotice(title: CartoucheText.updateUnfinishedTitle, message: message, report: report)
        } else {
            CartoucheReports.note("Update to Cartouche " + pending + " installed")
            notice = CartoucheGameNotice(title: CartoucheText.updateInstalledTitle(running), message: CartoucheText.updatedMessage)
        }
    }

    // MARK: Leaving the screen for the install

    /// SideStore posts "<bundle identifier>.SelfReinstall" as it starts
    /// installing over Cartouche (app/patches/sidestore/0010).
    private func observeInstall() {
        guard let bundleIdentifier = Self.bundleIdentifier else { return }
        CFNotificationCenterAddObserver(
            CFNotificationCenterGetDarwinNotifyCenter(),
            Unmanaged.passUnretained(self).toOpaque(),
            { _, _, _, _, _ in
                Task { @MainActor in CartoucheUpdates.shared.installStarted() }
            },
            "\(bundleIdentifier).SelfReinstall" as CFString,
            nil,
            .deliverImmediately)
    }

    fileprivate func installStarted() {
        guard phase == .preparing else { return }
        phase = .installing
        beginBackground()
        Task {
            // A moment to read why Cartouche leaves.
            try? await Task.sleep(for: .seconds(3))
            if phase == .installing { leaveToHomeScreen() }
        }
    }

    /// The home screen, as the Home button would: iOS can then close
    /// Cartouche and install the new version.
    func leaveToHomeScreen() {
        _ = UIApplication.shared.perform(NSSelectorFromString("suspend"))
    }

    /// Time for SideStore, which runs in Cartouche's LiveProcess, to hand
    /// the app to iOS once Cartouche has left the screen.
    private func beginBackground() {
        guard background == .invalid else { return }
        background = UIApplication.shared.beginBackgroundTask(withName: "Cartouche update") { [weak self] in
            // iOS calls this on the main thread, as the time runs out.
            Task { @MainActor in self?.endBackground() }
        }
    }

    private func endBackground() {
        guard background != .invalid else { return }
        UIApplication.shared.endBackgroundTask(background)
        background = .invalid
    }
}
