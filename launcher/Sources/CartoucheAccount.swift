//
//  CartoucheAccount.swift
//  Cartouche
//
//  The player signs in with their Apple ID on Cartouche's own screens
//  (CartoucheSignInView), and the built-in SideStore signs in with it
//  without showing itself, as it renews the app: its Sign In to Cartouche
//  action (app/patches/sidestore/0011), in LiveProcess, through the bridge
//  CartoucheSignIn (launcher/SideStoreSupport).
//
//  Cartouche leaves the Apple ID and password in the keychain it shares with
//  SideStore, which reads them once. When Apple asks for a verification code,
//  SideStore leaves a request there, which Cartouche shows, and Cartouche
//  leaves the player's answer (CartoucheSignInMessage). Once SideStore is
//  signed in, it keeps the Apple ID and password in its own keychain items,
//  as after any sign-in, renews Cartouche with them, and Cartouche hands its
//  certificate to LiveContainer (CartoucheSetup).
//
//  SideStore registers this iPhone with the account through LocalDevVPN, as
//  it reaches the iPhone for each renewal. Without LocalDevVPN, Cartouche
//  waits for it before it hands SideStore the sign-in, unless the player
//  goes on without it, and SideStore's action checks that it reaches the
//  iPhone before anything goes to Apple (patch 0019): a sign-in that Apple
//  accepts and that then stops at that step costs the player a verification
//  code, and Apple one more sign-in, which it limits. One that stops there
//  all the same leaves that step alone (CartoucheSetup.deviceStepLeft):
//  SideStore's Register Cartouche's iPhone takes it with the account it
//  kept, without a password or a code, as the player asks, and by itself
//  once LocalDevVPN connects.
//
//  When iOS no longer accepts that certificate, as after an install from
//  another computer that revoked it, Cartouche signs SideStore in again by
//  itself, with the Apple ID and password SideStore keeps, once LocalDevVPN
//  is connected: SideStore then takes the certificate the installer put in
//  Cartouche. The player sees the sign-in only should Apple ask for a
//  verification code.
//
//  SideStore keeps the Apple ID and password as soon as Apple has accepted
//  the account, before the team's and the certificate's steps, and keeps
//  them should the sign-in stop there, in a keychain that outlives
//  Cartouche. The setup then says that the sign-in stopped, and why, from
//  the report Cartouche keeps on it (CartoucheSignInStep): a reinstall,
//  which the error on a certificate the account has already asks for,
//  brings no sign-in of its own, so Cartouche signs in again by itself,
//  once per installation (resumeSignIn).
//
//  However the sign-in ends, SideStore leaves the step it reached and its
//  error as names and numbers (CartoucheSideStoreOutcome, patch 0014):
//  Cartouche's measurements send them, never the error's words.
//
//  When Apple refuses more sign-ins for now (HTTP 429, Too Many Requests,
//  or its codes for too many attempts), Cartouche says so in its own words
//  and keeps the player, and itself, from signing in again for a while
//  (CartoucheSignInPause): a burst of attempts only makes Apple's limit
//  last longer. The machine the sign-in goes as stays the same (patch 0016).
//

import Foundation

@available(iOS 17.0, *)
@MainActor
final class CartoucheAccount: ObservableObject {
    static let shared = CartoucheAccount()

    /// Where the sign-in stands (CartoucheSignInMessage.swift, which swift
    /// test checks).
    typealias Phase = CartoucheSignInPhase

    @Published private(set) var phase: Phase?
    @Published private(set) var progress: Progress?
    /// Why the last sign-in failed, and the report on it.
    @Published private(set) var problemReport: CartoucheReport?
    var problem: String? { problemReport?.message }
    /// Whether the last sign-in went through.
    @Published private(set) var signedIn = false
    /// Whether Cartouche started this sign-in by itself, for a new
    /// certificate: the setup then opens should Apple ask for a code.
    @Published private(set) var isAutomatic = false
    /// The wait Apple's limit on sign-ins asks for, kept across launches.
    @Published private(set) var pause: CartoucheSignInPause?
    /// Where and when the last sign-in started, kept across launches.
    @Published private(set) var lastSignIn: CartoucheLastSignIn?

    /// When the player can sign in again, while Apple's limit holds.
    var pausedUntil: Date? {
        guard let pause, pause.holds(at: Date()) else { return nil }
        return pause.until
    }

    /// Apple asks the player for a verification code.
    var needsCode: Bool { phase?.needsCode ?? false }

    /// Whether Cartouche waits for LocalDevVPN.
    var isWaitingForVPN: Bool { phase?.isWaitingForVPN ?? false }

    /// The requests the player has answered, which SideStore may not have
    /// cleared yet.
    private var answered: Set<String> = []
    private var watching: Task<Void, Never>?
    /// When the sign-in, or the step that registers this iPhone, started.
    private var started: Date?

    /// What waits for LocalDevVPN, since when, and for how long at most.
    private enum Pending {
        case signIn(appleID: String, password: String)
        case device
    }
    private var pending: Pending?
    private var vpnWaiting: CartoucheVPNWait?
    private var waiting: Task<Void, Never>?
    /// How long the player waited for LocalDevVPN before what runs now, and
    /// whether they went on without it, for the measurements.
    private var vpnWait: TimeInterval?
    private var wentOnWithoutVPN = false

    /// Whether Cartouche started the step that registers this iPhone by
    /// itself, and when it does so (CartoucheDeviceStepWatch).
    private var deviceStepIsAutomatic = false
    private var deviceStepWatch = CartoucheDeviceStepWatch()

    private static let pauseKey = "CartoucheSignInPause"
    private static let lastSignInKey = "CartoucheLastSignIn"

    private init() {
        pause = UserDefaults.standard.data(forKey: Self.pauseKey)
            .flatMap { try? JSONDecoder().decode(CartoucheSignInPause.self, from: $0) }
        lastSignIn = UserDefaults.standard.data(forKey: Self.lastSignInKey)
            .flatMap { try? JSONDecoder().decode(CartoucheLastSignIn.self, from: $0) }
    }

    private func keep(_ pause: CartoucheSignInPause?) {
        self.pause = pause
        if let data = pause.flatMap({ try? JSONEncoder().encode($0) }) {
            UserDefaults.standard.set(data, forKey: Self.pauseKey)
        } else {
            UserDefaults.standard.removeObject(forKey: Self.pauseKey)
        }
    }

    /// Whether LocalDevVPN is connected: always, in the simulator, which has
    /// none, and where SideStore does not go through it.
    private static var vpnConnected: Bool {
        #if targetEnvironment(simulator)
        return true
        #else
        return CartoucheVPN.isConnected
        #endif
    }

    // MARK: The bridge to the built-in SideStore

    private typealias Action = @convention(c) (
        AnyObject, Selector, Progress, @escaping @convention(block) (NSString?) -> Void) -> Void

    private static let signInSelector = NSSelectorFromString("signInWithProgress:completion:")
    private static let registerDeviceSelector = NSSelectorFromString("registerDeviceWithProgress:completion:")

    /// CartoucheSignIn is in SideStoreSupport, which LiveContainer loads only
    /// when the app carries the built-in SideStore.
    private static func bridge(_ selector: Selector) -> (receiver: AnyObject, call: Action)? {
        guard let signIn = NSClassFromString("CartoucheSignIn"),
              let method = class_getClassMethod(signIn, selector) else { return nil }
        return (signIn as AnyObject, unsafeBitCast(method_getImplementation(method), to: Action.self))
    }

    // MARK: Signing in

    /// Has the built-in SideStore sign in with this Apple ID, unless Apple's
    /// limit on sign-ins still holds. Without LocalDevVPN, which SideStore
    /// needs to register this iPhone, Cartouche first waits for it, unless
    /// WAITING FOR VPN is false.
    func signIn(appleID: String, password: String, waitingForVPN: Bool = true) {
        guard !CartoucheImportedSigning.accountSigningDisabled, phase == nil, pausedUntil == nil,
              CartoucheSignInMessage.canSignIn(appleID: appleID, password: password) else { return }
        problemReport = nil
        signedIn = false
        isAutomatic = false
        vpnWait = nil
        wentOnWithoutVPN = false
        // SideStore keeps the Apple ID only once signed in.
        CartoucheReports.redactTyped(accounts: [appleID])
        if waitingForVPN && !Self.vpnConnected {
            wait(for: .signIn(appleID: appleID, password: password))
        } else {
            start(appleID: appleID, password: password)
        }
    }

    private func start(appleID: String, password: String) {
        noteStart()
        guard let bridge = Self.bridge(Self.signInSelector), CartoucheStoreKeychain.service != nil else {
            failed(CartoucheText.signInUnavailable, failure: CartoucheFailure(.bridgeMissing, stage: "start"))
            return
        }
        // What an earlier sign-in may have left.
        CartoucheStoreKeychain.remove(CartoucheSignInMessage.requestAccount)
        CartoucheStoreKeychain.remove(CartoucheSignInMessage.responseAccount)
        CartoucheStoreKeychain.remove(CartoucheSideStoreOutcome.account)
        guard CartoucheStoreKeychain.set(CartoucheSignInMessage.credentials(appleID: appleID, password: password),
                                         for: CartoucheSignInMessage.credentialsAccount) else {
            failed(CartoucheText.signInKeychainFailed, failure: CartoucheFailure(.keychain, stage: "start"))
            return
        }
        answered = []
        started = Date()
        let progress = Progress(totalUnitCount: 100)
        self.progress = progress
        phase = .signingIn
        CartoucheReports.note("Sign-in started")
        watchForRequests()
        bridge.call(bridge.receiver, Self.signInSelector, progress) { [weak self] message in
            let text = message.map { $0 as String }
            Task { @MainActor in self?.finished(text) }
        }
    }

    /// Has the built-in SideStore sign in again with the Apple ID and
    /// password it keeps, for the certificate that signs Cartouche. Returns
    /// whether it tried: not while SideStore keeps none, while Apple's limit
    /// on sign-ins holds, or without LocalDevVPN, which the setup tries again
    /// with each time Cartouche comes to the front.
    @discardableResult
    func signInAgain() -> Bool {
        guard !CartoucheImportedSigning.accountSigningDisabled, phase == nil, pausedUntil == nil, Self.vpnConnected,
              let appleID = CartoucheStoreKeychain.string("appleIDEmailAddress"),
              let password = CartoucheStoreKeychain.string("appleIDPassword") else { return false }
        signIn(appleID: appleID, password: password, waitingForVPN: false)
        isAutomatic = phase != nil
        return true
    }

    /// Answers Apple's request for a verification code.
    func answer(_ answer: CartoucheSignInMessage.Answer) {
        guard case .code(let request) = phase else { return }
        answered.insert(request.id)
        CartoucheStoreKeychain.set(CartoucheSignInMessage.response(to: request.id, answer),
                                   for: CartoucheSignInMessage.responseAccount)
        phase = .signingIn
    }

    /// Looks for SideStore's requests twice a second while it signs in.
    private func watchForRequests() {
        watching?.cancel()
        watching = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(500))
                guard let self, self.phase == .signingIn || self.needsCode else { return }
                self.readRequest()
            }
        }
    }

    private func readRequest() {
        let request = CartoucheStoreKeychain.data(CartoucheSignInMessage.requestAccount)
            .flatMap(CartoucheSignInMessage.request(from:))
        if let request, !answered.contains(request.id) {
            if phase != .code(request) {
                CartoucheReports.note("Sign-in: Apple asks for a code")
                phase = .code(request)
            }
        } else if case .code = phase {
            // SideStore went on without an answer.
            phase = .signingIn
        }
    }

    private func finished(_ message: String?) {
        let fraction = progress?.fractionCompleted
        let seconds = started.map { Date().timeIntervalSince($0) }
        let automatic = isAutomatic
        watching?.cancel()
        watching = nil
        phase = nil
        progress = nil
        started = nil
        // Should SideStore not have started, the password goes too.
        CartoucheStoreKeychain.remove(CartoucheSignInMessage.credentialsAccount)
        CartoucheStoreKeychain.remove(CartoucheSignInMessage.responseAccount)
        // How SideStore's action ended, which it left for Cartouche.
        let outcome = CartoucheStoreKeychain.data(CartoucheSideStoreOutcome.account)
            .flatMap { CartoucheSideStoreOutcome(data: $0, expecting: .signIn) }
        CartoucheStoreKeychain.remove(CartoucheSideStoreOutcome.account)
        if let message {
            var failure = CartoucheFailure.sideStore(outcome: outcome, message: message, fraction: fraction, seconds: seconds,
                                                     vpn: CartoucheVPN.isConnected, pairing: CartouchePairing.exists)
            noteWait(in: &failure.details)
            if CartoucheSignInMessage.trouble(in: CartoucheSignInMessage.readable(message), failure: failure) == .tooManyRequests {
                pauseSignIns(retryAfter: outcome?.retryAfter, failure: &failure)
            }
            if CartoucheSignInMessage.leavesDeviceStep(failure) {
                // Apple accepted the account, and SideStore kept it: only
                // the step that registers this iPhone is left.
                CartoucheReports.note("Sign-in: only this iPhone is left to register")
                CartoucheSetup.shared.noteDeviceStep(left: true)
            }
            failed(CartoucheText.sideStoreMessage(message, failure: failure, signIn: true), fraction: fraction, failure: failure)
        } else {
            CartoucheReports.note("Sign-in done")
            var fields = CartoucheFailure.sideStoreSuccess(outcome: outcome, seconds: seconds)
            fields["automatic"] = .flag(isAutomatic)
            noteWait(in: &fields)
            // How many sign-ins in a row Apple had limited, in the day
            // before this one.
            if let pause, Date().timeIntervalSince(pause.last) < 86_400 {
                fields["limitedBefore"] = .number(Double(pause.inARow))
            }
            keep(nil)
            CartoucheSetup.shared.noteDeviceStep(left: false)
            CartoucheTelemetry.shared.event("account.signedIn", fields: fields)
        }
        signedIn = message == nil
        isAutomatic = false
        // A step left is taken by itself once LocalDevVPN connects again,
        // not while it stays as it was.
        deviceStepWatch.ended(connected: Self.vpnConnected)
        CartoucheSetup.shared.refresh()
        // Signed in, and LiveContainer has no certificate all the same: the
        // one SideStore took did not open (CartoucheCertificate.handOff),
        // which the setup would otherwise show without a reason.
        if message == nil, CartoucheSetup.shared.signInStep == .unfinished {
            failed(CartoucheText.signInCertificateUnopened, failure: CartoucheFailure(.certificate, stage: "handOff"),
                   automatic: automatic)
        }
    }

    /// The sign-in failed, as MESSAGE says, for the reason FAILURE gives.
    /// AUTOMATIC: whether Cartouche started it by itself, which it is still
    /// doing unless said.
    private func failed(_ message: String, fraction: Double? = nil, failure: CartoucheFailure, automatic: Bool? = nil) {
        let automatic = automatic ?? isAutomatic
        var failure = failure
        failure.details["automatic"] = .flag(automatic)
        problemReport = CartoucheReports.make(.signIn, CartoucheText.signInFailedTitle, message: message,
                                              step: automatic ? "Signing in again by itself, for a new certificate" : "Signing in",
                                              fraction: fraction, failure: failure)
    }

    /// Apple refuses more requests for now: no sign-in until the wait is
    /// over, which the measurements send with the error.
    private func pauseSignIns(retryAfter: Int?, failure: inout CartoucheFailure) {
        let limit = CartoucheSignInPause.after(pause, at: Date(), retryAfter: retryAfter)
        keep(limit)
        failure.cause = .tooManyAttempts
        failure.details["wait"] = .number(Double(limit.seconds))
        failure.details["inARow"] = .number(Double(limit.inARow))
        CartoucheReports.note("Sign-in: Apple limits the sign-ins, \(limit.seconds / 60) min to wait")
    }

    // MARK: A sign-in that stopped before the certificate

    /// This installation of Cartouche (CartoucheLastSignIn.installation(of:)).
    private static var installation: String { CartoucheLastSignIn.installation(of: Bundle.main.bundleURL) }

    /// Keeps where and when this sign-in started: in this installation,
    /// Cartouche signs in again by itself no more, and the setup takes a
    /// report from before as the reason no more.
    private func noteStart() {
        let last = CartoucheLastSignIn(installation: Self.installation, started: Date())
        lastSignIn = last
        if let data = try? JSONEncoder().encode(last) {
            UserDefaults.standard.set(data, forKey: Self.lastSignInKey)
        }
    }

    /// Signs in again by itself, once per installation of Cartouche, when the
    /// last sign-in stopped before the certificate in an earlier one: the
    /// player installed Cartouche again, as the error on a certificate the
    /// account has already asks, or as the setup said up to 0.11.2, and a
    /// reinstall brings no sign-in of its own. With the Apple ID and password
    /// SideStore keeps, the pairing file and LocalDevVPN connected
    /// (CartoucheLastSignIn.signsInAgain); called each time Cartouche comes to
    /// the front. Apple asks for a code at most, which the setup shows.
    func resumeSignIn() {
        #if !CARTOUCHE_GALLERY
        let setup = CartoucheSetup.shared
        guard phase == nil,
              CartoucheLastSignIn.signsInAgain(after: lastSignIn, at: setup.signInStep, installation: Self.installation,
                                               hasPairingFile: setup.hasPairingFile, vpnConnected: Self.vpnConnected)
        else { return }
        signInAgain()
        if isAutomatic { CartoucheReports.note("Sign-in: the last one stopped before the certificate, signing in again by itself") }
        #endif
    }

    /// Why the last sign-in stopped, and the report on it: this launch's, or
    /// the one Cartouche kept, redacted, from an earlier launch or an
    /// earlier installation, such as one of 0.11.2.
    var lastProblem: CartoucheReport? {
        problemReport ?? CartoucheLastSignIn.report(after: lastSignIn, among: CartoucheReports.recent)
    }

    /// The page an error asks the player to open, such as Apple's own when it
    /// asks to review the account.
    var problemLink: URL? { problem.flatMap(CartoucheSignInMessage.link(in:)) }

    // MARK: Waiting for LocalDevVPN

    /// Waits for LocalDevVPN, ten minutes at most, then goes on with PENDING.
    private func wait(for pending: Pending) {
        self.pending = pending
        vpnWaiting = CartoucheVPNWait(started: Date())
        if case .device = pending {
            phase = .waitingForVPN(deviceStep: true)
        } else {
            phase = .waitingForVPN(deviceStep: false)
        }
        CartoucheReports.note("Waiting for LocalDevVPN")
        waiting?.cancel()
        waiting = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(500))
                guard let self, self.isWaitingForVPN, let current = self.vpnWaiting else { return }
                switch current.next(connected: Self.vpnConnected, at: Date()) {
                case .goOn:
                    self.goOn()
                    return
                case .stop:
                    CartoucheReports.note("LocalDevVPN did not connect in time")
                    self.stopWaiting()
                    return
                case .keepWaiting:
                    continue
                }
            }
        }
    }

    /// Goes on with what waits for LocalDevVPN: now that it is connected, or
    /// without it, as the player asks.
    func goOn() {
        guard isWaitingForVPN, let pending = self.pending else { return }
        vpnWait = vpnWaiting?.seconds(at: Date())
        wentOnWithoutVPN = !Self.vpnConnected
        endWait()
        switch pending {
        case .signIn(let appleID, let password):
            start(appleID: appleID, password: password)
        case .device:
            startDeviceStep(automatic: false)
        }
    }

    /// Stops waiting for LocalDevVPN, as the player asks.
    func stopWaiting() {
        guard isWaitingForVPN else { return }
        endWait()
    }

    private func endWait() {
        waiting?.cancel()
        waiting = nil
        pending = nil
        vpnWaiting = nil
        phase = nil
    }

    /// The wait for LocalDevVPN before what just ended, for its event.
    private func noteWait(in fields: inout [String: CartoucheTelemetryValue]) {
        if let vpnWait { fields["vpnWait"] = .number(max(0, vpnWait.rounded())) }
        if wentOnWithoutVPN { fields["withoutVPN"] = .flag(true) }
        vpnWait = nil
        wentOnWithoutVPN = false
    }

    // MARK: Registering this iPhone alone

    /// Has the built-in SideStore register this iPhone alone, with the
    /// account it kept after a sign-in that stopped at that step, as the
    /// player asks: once LocalDevVPN is connected, which Cartouche waits for.
    func registerDevice() {
        guard !CartoucheImportedSigning.accountSigningDisabled, phase == nil, pausedUntil == nil else { return }
        problemReport = nil
        vpnWait = nil
        wentOnWithoutVPN = false
        if Self.vpnConnected {
            startDeviceStep(automatic: false)
        } else {
            wait(for: .device)
        }
    }

    /// Takes the step left by itself as soon as LocalDevVPN connects: once
    /// each time it does, three times at most while Cartouche is open
    /// (CartoucheDeviceStepWatch). CartoucheSetupRefresh calls it whenever
    /// Cartouche comes to the front, and every two seconds while that step
    /// is left.
    func resumeDeviceStep() {
        #if CARTOUCHE_GALLERY
        // The gallery has no SideStore: its screens show the step as it is.
        return
        #else
        guard deviceStepWatch.look(connected: Self.vpnConnected, left: CartoucheSetup.shared.needsDevice,
                                   idle: phase == nil && pausedUntil == nil) else { return }
        vpnWait = nil
        wentOnWithoutVPN = false
        startDeviceStep(automatic: true)
        #endif
    }

    private func startDeviceStep(automatic: Bool) {
        problemReport = nil
        signedIn = false
        guard let bridge = Self.bridge(Self.registerDeviceSelector), CartoucheStoreKeychain.service != nil else {
            deviceStepFailed(CartoucheText.signInUnavailable, automatic: automatic,
                             failure: CartoucheFailure(.bridgeMissing, stage: "start"))
            return
        }
        CartoucheStoreKeychain.remove(CartoucheSideStoreOutcome.account)
        deviceStepIsAutomatic = automatic
        started = Date()
        let progress = Progress(totalUnitCount: 100)
        self.progress = progress
        phase = .registeringDevice
        CartoucheReports.note(automatic ? "Registering this iPhone, by itself" : "Registering this iPhone")
        bridge.call(bridge.receiver, Self.registerDeviceSelector, progress) { [weak self] message in
            let text = message.map { $0 as String }
            Task { @MainActor in self?.deviceStepFinished(text) }
        }
    }

    private func deviceStepFinished(_ message: String?) {
        let fraction = progress?.fractionCompleted
        let seconds = started.map { Date().timeIntervalSince($0) }
        let automatic = deviceStepIsAutomatic
        deviceStepIsAutomatic = false
        phase = nil
        progress = nil
        started = nil
        let outcome = CartoucheStoreKeychain.data(CartoucheSideStoreOutcome.account)
            .flatMap { CartoucheSideStoreOutcome(data: $0, expecting: .device) }
        CartoucheStoreKeychain.remove(CartoucheSideStoreOutcome.account)
        if let message {
            var failure = CartoucheFailure.sideStore(outcome: outcome, message: message, fraction: fraction, seconds: seconds,
                                                     vpn: CartoucheVPN.isConnected, pairing: CartouchePairing.exists)
            if CartoucheSignInMessage.trouble(in: CartoucheSignInMessage.readable(message), failure: failure) == .tooManyRequests {
                pauseSignIns(retryAfter: outcome?.retryAfter, failure: &failure)
            }
            if CartoucheSignInMessage.needsSignIn(afterDeviceStep: failure) {
                // SideStore kept no account: the whole sign-in is left.
                CartoucheSetup.shared.noteDeviceStep(left: false)
            }
            deviceStepFailed(CartoucheText.deviceStepMessage(message, failure: failure), automatic: automatic,
                             fraction: fraction, failure: failure)
        } else {
            CartoucheReports.note("This iPhone is registered")
            var fields = CartoucheFailure.sideStoreSuccess(outcome: outcome, seconds: seconds)
            fields["automatic"] = .flag(automatic)
            fields["deviceOnly"] = .flag(true)
            noteWait(in: &fields)
            CartoucheSetup.shared.noteDeviceStep(left: false)
            CartoucheTelemetry.shared.event("account.signedIn", fields: fields)
            signedIn = true
        }
        deviceStepWatch.ended(connected: Self.vpnConnected)
        CartoucheSetup.shared.refresh()
    }

    /// Registering this iPhone alone failed, as MESSAGE says, for the reason
    /// FAILURE gives. What Cartouche tried by itself stays out of the
    /// reports the System page lists.
    private func deviceStepFailed(_ message: String, automatic: Bool, fraction: Double? = nil, failure: CartoucheFailure) {
        var failure = failure
        failure.details["automatic"] = .flag(automatic)
        failure.details["deviceOnly"] = .flag(true)
        noteWait(in: &failure.details)
        problemReport = CartoucheReports.make(.signIn, CartoucheText.signInDeviceFailedTitle, message: message,
                                              step: automatic ? "Registering this iPhone by itself" : "Registering this iPhone",
                                              fraction: fraction, failure: failure, inBackground: automatic)
    }

    #if CARTOUCHE_GALLERY
    /// Shows a verification code request, for the gallery's screens.
    func requestCodeForGallery(_ request: CartoucheSignInMessage.CodeRequest) {
        phase = .code(request)
    }

    /// Shows the reason of a sign-in that stopped before the certificate,
    /// the account having one the built-in SideStore does not hold, for the
    /// gallery's screens.
    func showUnfinishedForGallery() {
        let message = "This Apple account already has a certificate, which signs the apps installed with it. "
            + "This SideStore never revokes it and does not create another one.\n\n"
            + "Install Cartouche again with the Cartouche Installer, over this copy: "
            + "it gives Cartouche the certificate it signs with. Then sign in again."
        problemReport = CartoucheReports.make(.signIn, CartoucheText.signInFailedTitle, message: message, step: "Signing in",
                                              failure: CartoucheFailure(.certificateRefused, stage: "certificate", seconds: 23))
    }

    /// Shows the sign-in Apple refused for too many requests, with the wait
    /// it asks for under way, for the gallery's screens.
    func showTooManyRequestsForGallery() {
        let now = Date()
        pause = CartoucheSignInPause(until: now.addingTimeInterval(14 * 60 + 32), inARow: 1, last: now.addingTimeInterval(-28))
        var failure = CartoucheFailure(.tooManyAttempts, stage: "verification", seconds: 41,
                                       details: ["http": .number(429), "kind": .text("httpStatus"), "service": .text("grandSlam")])
        failure.details["wait"] = .number(900)
        problemReport = CartoucheReports.make(.signIn, CartoucheText.signInFailedTitle, message: CartoucheText.signInTooManyRequests,
                                              step: "Signing in", failure: failure)
    }

    /// Shows the sign-in waiting for LocalDevVPN, for the gallery's screens.
    func waitForVPNForGallery() {
        phase = .waitingForVPN(deviceStep: false)
    }

    /// Shows a sign-in that Apple accepted and that stopped at the step that
    /// registers this iPhone, LocalDevVPN being off, for the gallery's
    /// screens.
    func showDeviceStepForGallery() {
        CartoucheSetup.shared.showDeviceStepForGallery()
        let failure = CartoucheFailure(.vpn, stage: "device", fraction: 0.5, seconds: 38,
                                       details: ["kind": .text("noVPN"), "vpn": .flag(false), "pairing": .flag(true)])
        problemReport = CartoucheReports.make(.signIn, CartoucheText.signInFailedTitle,
                                              message: CartoucheText.deviceVPN + " " + CartoucheText.deviceAfterApple,
                                              step: "Signing in", failure: failure)
    }
    #endif
}
