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
    /// Why the last sign-in failed.
    @Published private(set) var problem: String?
    /// Whether the last sign-in went through.
    @Published private(set) var signedIn = false

    /// The requests the player has answered, which SideStore may not have
    /// cleared yet.
    private var answered: Set<String> = []
    private var watching: Task<Void, Never>?

    private init() {}

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

    /// Has the built-in SideStore sign in with this Apple ID.
    func signIn(appleID: String, password: String) {
        guard phase == nil, CartoucheSignInMessage.canSignIn(appleID: appleID, password: password) else { return }
        problem = nil
        signedIn = false
        guard let bridge = Self.bridge, CartoucheStoreKeychain.service != nil else {
            problem = CartoucheText.signInUnavailable
            return
        }
        // What an earlier sign-in may have left.
        CartoucheStoreKeychain.remove(CartoucheSignInMessage.requestAccount)
        CartoucheStoreKeychain.remove(CartoucheSignInMessage.responseAccount)
        guard CartoucheStoreKeychain.set(CartoucheSignInMessage.credentials(appleID: appleID, password: password),
                                         for: CartoucheSignInMessage.credentialsAccount) else {
            problem = CartoucheText.signInKeychainFailed
            return
        }
        answered = []
        let progress = Progress(totalUnitCount: 100)
        self.progress = progress
        phase = .signingIn
        watchForRequests()
        bridge.call(bridge.receiver, Self.signInSelector, progress) { [weak self] message in
            let text = message.map { $0 as String }
            Task { @MainActor in self?.finished(text) }
        }
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
            if phase != .code(request) { phase = .code(request) }
        } else if case .code = phase {
            // SideStore went on without an answer.
            phase = .signingIn
        }
    }

    private func finished(_ message: String?) {
        watching?.cancel()
        watching = nil
        phase = nil
        progress = nil
        // Should SideStore not have started, the password goes too.
        CartoucheStoreKeychain.remove(CartoucheSignInMessage.credentialsAccount)
        CartoucheStoreKeychain.remove(CartoucheSignInMessage.responseAccount)
        problem = message
        signedIn = message == nil
        CartoucheSetup.shared.refresh()
    }

    /// The page an error asks the player to open, such as Apple's own when it
    /// asks to review the account.
    var problemLink: URL? { problem.flatMap(CartoucheSignInMessage.link(in:)) }

    #if CARTOUCHE_GALLERY
    /// Shows a verification code request, for the gallery's screens.
    func requestCodeForGallery(_ request: CartoucheSignInMessage.CodeRequest) {
        phase = .code(request)
    }
    #endif
}
