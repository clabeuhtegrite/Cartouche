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
//  When iOS no longer accepts that certificate, as after an install from
//  another computer that revoked it, Cartouche signs SideStore in again by
//  itself, with the Apple ID and password SideStore keeps: SideStore then
//  takes the certificate the installer put in Cartouche. The player sees
//  the sign-in only should Apple ask for a verification code.
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

    enum Phase: Equatable {
        /// SideStore signs in, registers this iPhone and fetches the
        /// certificate.
        case signingIn
        /// Apple asks for a verification code.
        case code(CartoucheSignInMessage.CodeRequest)
    }

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

    /// When the player can sign in again, while Apple's limit holds.
    var pausedUntil: Date? {
        guard let pause, pause.holds(at: Date()) else { return nil }
        return pause.until
    }

    /// Apple asks the player for a verification code.
    var needsCode: Bool {
        if case .code = phase { return true }
        return false
    }

    /// The requests the player has answered, which SideStore may not have
    /// cleared yet.
    private var answered: Set<String> = []
    private var watching: Task<Void, Never>?
    /// When the sign-in started.
    private var started: Date?

    private static let pauseKey = "CartoucheSignInPause"

    private init() {
        pause = UserDefaults.standard.data(forKey: Self.pauseKey)
            .flatMap { try? JSONDecoder().decode(CartoucheSignInPause.self, from: $0) }
    }

    private func keep(_ pause: CartoucheSignInPause?) {
        self.pause = pause
        if let data = pause.flatMap({ try? JSONEncoder().encode($0) }) {
            UserDefaults.standard.set(data, forKey: Self.pauseKey)
        } else {
            UserDefaults.standard.removeObject(forKey: Self.pauseKey)
        }
    }

    // MARK: The bridge to the built-in SideStore

    private typealias SignIn = @convention(c) (
        AnyObject, Selector, Progress, @escaping @convention(block) (NSString?) -> Void) -> Void

    private static let signInSelector = NSSelectorFromString("signInWithProgress:completion:")

    /// CartoucheSignIn is in SideStoreSupport, which LiveContainer loads only
    /// when the app carries the built-in SideStore.
    private static var bridge: (receiver: AnyObject, call: SignIn)? {
        guard let signIn = NSClassFromString("CartoucheSignIn"),
              let method = class_getClassMethod(signIn, signInSelector) else { return nil }
        return (signIn as AnyObject, unsafeBitCast(method_getImplementation(method), to: SignIn.self))
    }

    // MARK: Signing in

    /// Has the built-in SideStore sign in with this Apple ID, unless Apple's
    /// limit on sign-ins still holds.
    func signIn(appleID: String, password: String) {
        guard !CartoucheImportedSigning.accountSigningDisabled, phase == nil, pausedUntil == nil,
              CartoucheSignInMessage.canSignIn(appleID: appleID, password: password) else { return }
        problemReport = nil
        signedIn = false
        isAutomatic = false
        // SideStore keeps the Apple ID only once signed in.
        CartoucheReports.redactTyped(accounts: [appleID])
        guard let bridge = Self.bridge, CartoucheStoreKeychain.service != nil else {
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
    /// password it keeps, for the certificate that signs Cartouche. Does
    /// nothing when it keeps none, or while Apple's limit on sign-ins holds:
    /// the setup then asks the player.
    func signInAgain() {
        guard !CartoucheImportedSigning.accountSigningDisabled, phase == nil, pausedUntil == nil,
              let appleID = CartoucheStoreKeychain.string("appleIDEmailAddress"),
              let password = CartoucheStoreKeychain.string("appleIDPassword") else { return }
        signIn(appleID: appleID, password: password)
        isAutomatic = phase != nil
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
                guard let self, self.phase != nil else { return }
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
            if CartoucheSignInMessage.trouble(in: CartoucheSignInMessage.readable(message), failure: failure) == .tooManyRequests {
                // Apple refuses more sign-ins for now: none until the wait
                // is over, which the measurements send with the error.
                let limit = CartoucheSignInPause.after(self.pause, at: Date(), retryAfter: outcome?.retryAfter)
                keep(limit)
                failure.cause = .tooManyAttempts
                failure.details["wait"] = .number(Double(limit.seconds))
                failure.details["inARow"] = .number(Double(limit.inARow))
                CartoucheReports.note("Sign-in: Apple limits the sign-ins, \(limit.seconds / 60) min to wait")
            }
            failed(CartoucheText.sideStoreMessage(message, failure: failure, signIn: true), fraction: fraction, failure: failure)
        } else {
            CartoucheReports.note("Sign-in done")
            var fields = CartoucheFailure.sideStoreSuccess(outcome: outcome, seconds: seconds)
            fields["automatic"] = .flag(isAutomatic)
            // How many sign-ins in a row Apple had limited, in the day
            // before this one.
            if let pause, Date().timeIntervalSince(pause.last) < 86_400 {
                fields["limitedBefore"] = .number(Double(pause.inARow))
            }
            keep(nil)
            CartoucheTelemetry.shared.event("account.signedIn", fields: fields)
        }
        signedIn = message == nil
        isAutomatic = false
        CartoucheSetup.shared.refresh()
    }

    /// The sign-in failed, as MESSAGE says, for the reason FAILURE gives.
    private func failed(_ message: String, fraction: Double? = nil, failure: CartoucheFailure) {
        var failure = failure
        failure.details["automatic"] = .flag(isAutomatic)
        problemReport = CartoucheReports.make(.signIn, CartoucheText.signInFailedTitle, message: message,
                                              step: isAutomatic ? "Signing in again by itself, for a new certificate" : "Signing in",
                                              fraction: fraction, failure: failure)
    }

    /// The page an error asks the player to open, such as Apple's own when it
    /// asks to review the account.
    var problemLink: URL? { problem.flatMap(CartoucheSignInMessage.link(in:)) }

    #if CARTOUCHE_GALLERY
    /// Shows a verification code request, for the gallery's screens.
    func requestCodeForGallery(_ request: CartoucheSignInMessage.CodeRequest) {
        phase = .code(request)
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
    #endif
}
