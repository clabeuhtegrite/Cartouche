//
//  CartoucheStorageDriveView.swift
//  Cartouche
//
//  The player's Google Drive on the Storage page (CartoucheStorageView):
//  the form that adds it, with the ID of the player's own OAuth client and
//  the guide that makes one; Google's sign-in page, in the sheet iOS shows
//  for it; and Sign in again, in one tap, once Google ended the sign-in.
//  The Drive itself is in CartoucheStorageDrive.swift.
//

import AuthenticationServices
import SwiftUI
import UIKit

// MARK: Google's sign-in page

/// Google's sign-in page, in the sheet iOS shows for it, with the cookies
/// of Safari: the player signs in to their Google account there, or picks
/// it, and lets their client reach their Drive. Google sends them back to
/// the address of the client's scheme, which only this sheet takes.
@MainActor
final class CartoucheDriveWebSignIn: NSObject, ASWebAuthenticationPresentationContextProviding {
    private var session: ASWebAuthenticationSession?

    /// The address Google sent the player back to, from PAGE; nil when they
    /// closed the sheet.
    func run(_ page: URL, scheme: String) async throws -> URL? {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<URL?, Error>) in
            let once = CartoucheOnce()
            let finish: (URL?, Error?) -> Void = { [weak self] url, error in
                guard once.claim() else { return }
                Task { @MainActor in self?.session = nil }
                if let error = error as? ASWebAuthenticationSessionError, error.code == .canceledLogin {
                    continuation.resume(returning: nil)
                } else if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: url)
                }
            }
            let session: ASWebAuthenticationSession
            if #available(iOS 17.4, *) {
                session = ASWebAuthenticationSession(url: page, callback: .customScheme(scheme), completionHandler: finish)
            } else {
                session = ASWebAuthenticationSession(url: page, callbackURLScheme: scheme, completionHandler: finish)
            }
            session.presentationContextProvider = self
            self.session = session
            if !session.start() {
                finish(nil, CartoucheStorageError(.webSignIn, CartoucheText.storageDrivePageFailed("ASWebAuthenticationSession")))
            }
        }
    }

    // iOS asks on the main thread, as the sheet opens.
    nonisolated func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        MainActor.assumeIsolated { Self.window() }
    }

    /// The window in front, which the sheet shows over.
    private static func window() -> ASPresentationAnchor {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        if let window = scenes.flatMap(\.windows).first(where: \.isKeyWindow) ?? scenes.first?.windows.first {
            return window
        }
        if let scene = scenes.first {
            return UIWindow(windowScene: scene)
        }
        return ASPresentationAnchor(frame: .zero)
    }
}

/// A sign-in to the player's Drive: Google's page with their client, the
/// tokens for the code it gives, then the Drive kept, signed in.
@MainActor
final class CartoucheDriveSigning: ObservableObject {
    @Published private(set) var isBusy = false
    private let web = CartoucheDriveWebSignIn()

    /// Signs SERVER in on Google's page, with the client whose ID is in its
    /// username, and keeps it: its account, and its refresh token in the
    /// keychain. The games folder is read again and the saves waiting go.
    /// Nil when the player closed the page.
    func signIn(_ server: CartoucheStorageServer) async throws -> CartoucheStorageServer? {
        guard let client = CartoucheDriveClient(server.username) else {
            throw CartoucheStorageError(.badClient, CartoucheText.storageDriveBadClient)
        }
        isBusy = true
        defer { isBusy = false }
        // What the player typed stays out of reports.
        CartoucheReports.redactTyped(servers: [server.host], names: [server.name], accounts: [server.username])
        var consent = false
        while true {
            let pkce = CartoucheDrivePKCE()
            let state = CartoucheDrivePKCE.randomText()
            guard let page = CartoucheDriveSignIn.page(client, challenge: pkce.challenge, state: state,
                                                       account: server.host.isEmpty ? nil : server.host,
                                                       consent: consent) else {
                throw CartoucheStorageError(.badClient, CartoucheText.storageDriveBadClient)
            }
            guard let callback = try await web.run(page, scheme: client.scheme) else { return nil }
            let code: String
            do {
                code = try CartoucheDriveSignIn.code(in: callback, client: client, state: state)
            } catch CartoucheDriveSignInFailure.refused {
                throw CartoucheStorageError(.webSignIn, CartoucheText.storageDriveRefusedOnPage)
            } catch {
                throw CartoucheStorageError(.webSignIn, CartoucheText.storageDriveSignInFailed(error.localizedDescription),
                                            underlying: error)
            }
            let signed: (remote: CartoucheDrive, refreshToken: String, account: String?)
            do {
                signed = try await CartoucheDrive.signIn(code: code, verifier: pkce.verifier, server: server)
            } catch let error as CartoucheStorageError where error.kind == .noLastingSignIn && !consent {
                // Google gives a lasting sign-in when the player allows the
                // client: asked again, it does.
                consent = true
                continue
            }
            var saved = server
            if let account = signed.account, !account.isEmpty {
                saved.host = account
            }
            let settings = CartoucheStorageSettings.shared
            settings.save(saved, secret: signed.refreshToken)
            CartoucheDriveSessions.shared.renew(saved.id)
            CartoucheReports.note("Storage: signed in to Google Drive")
            // Back: the games folder is read again, and the saves waiting
            // for it go (CartoucheGamesView).
            CartoucheStorageReach.shared.noteAnswered(saved)
            // Whether the account may write at the Drive's root, for the
            // choice of the saves folder.
            await settings.checkAccess(signed.remote, server: saved.id, path: "")
            await signed.remote.disconnect()
            CartoucheStoredGames.shared.refresh()
            return saved
        }
    }
}

// MARK: Adding the Drive

@available(iOS 17.0, *)
struct CartoucheStorageDriveForm: View {
    @State private var server: CartoucheStorageServer
    @State private var clientText: String
    /// Why the last sign-in failed, with its report, or, when it is no
    /// problem to report, its words alone.
    @State private var problem: CartoucheReport?
    @State private var note: String?
    /// Where the player turns the Drive API on, when Google said it is off.
    @State private var activation: URL?
    @StateObject private var signing = CartoucheDriveSigning()
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    private let isNew: Bool

    init(server: CartoucheStorageServer) {
        _server = State(initialValue: server)
        _clientText = State(initialValue: server.username)
        isNew = CartoucheStorageSettings.shared.server(server.id) == nil
    }

    private var client: CartoucheDriveClient? { CartoucheDriveClient.find(in: clientText) }

    var body: some View {
        Form {
            Section {
                TextField(CartoucheText.storageDriveClientField, text: $clientText, axis: .vertical)
                    .lineLimit(1 ... 3)
                    .font(.callout.monospaced())
                    .keyboardType(.asciiCapable)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                if client == nil, !clientText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text(CartoucheText.storageDriveBadClient)
                        .font(.footnote)
                        .foregroundStyle(Color.orange)
                }
                NavigationLink {
                    CartoucheDriveGuideView()
                } label: {
                    Label(CartoucheText.storageDriveHowTo, systemImage: "list.number")
                }
            } header: {
                Text(CartoucheText.storageDriveClient)
            } footer: {
                Text(CartoucheText.storageDriveClientFooter)
            }
            Section {
                if !server.host.isEmpty {
                    LabeledContent(CartoucheText.storageDriveAccount) {
                        Text(server.host)
                            .lineLimit(1)
                    }
                }
                Button {
                    Task { await signIn() }
                } label: {
                    HStack {
                        Label(isNew ? CartoucheText.storageDriveSignIn : CartoucheText.storageDriveSignInAgain,
                              systemImage: "person.badge.key")
                        if signing.isBusy {
                            Spacer()
                            ProgressView()
                        }
                    }
                }
                .disabled(client == nil || signing.isBusy)
                if let note {
                    Text(note)
                        .font(.footnote)
                        .foregroundStyle(Color.orange)
                }
                if let problem {
                    Text(problem.message)
                        .font(.footnote)
                        .foregroundStyle(Color.orange)
                    if let activation {
                        Button(CartoucheText.storageDriveTurnOn, systemImage: "power") { openURL(activation) }
                    }
                    CartoucheReportButton(report: problem)
                }
            } header: {
                Text(CartoucheText.storageDriveAccount)
            } footer: {
                Text(CartoucheText.storageDriveAccountFooter)
            }
            Section {
                TextField(CartoucheText.storageDriveTitle, text: $server.name)
            } header: {
                Text(CartoucheText.storageNameTitle)
            }
        }
        .cartoucheStageBackground()
        .navigationTitle(isNew ? CartoucheText.storageAddDrive : server.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button(CartoucheText.cancel) { dismiss() }
            }
            // A new Drive is kept once signed in; one kept already can take
            // another name.
            if !isNew {
                ToolbarItem(placement: .confirmationAction) {
                    Button(CartoucheText.storageSave) { save() }
                        .disabled(signing.isBusy)
                }
            }
        }
    }

    /// Google's page with the client the form holds; the Drive is kept, and
    /// the form goes, once the player is signed in.
    private func signIn() async {
        guard let client else { return }
        problem = nil
        note = nil
        activation = nil
        var candidate = server
        candidate.username = client.id
        candidate.name = server.name.trimmingCharacters(in: .whitespaces)
        if candidate.name.isEmpty {
            candidate.name = CartoucheText.storageDriveTitle
        }
        do {
            guard try await signing.signIn(candidate) != nil else { return }
            dismiss()
        } catch let away as CartoucheStorageOffline {
            // No problem to report: Google does not answer from here.
            note = away.localizedDescription
        } catch let error as CartoucheStorageError where error.kind == .webSignIn && error.underlyingError == nil {
            // The player did not allow the client: theirs to choose.
            note = error.localizedDescription
        } catch {
            activation = ((error as? CartoucheStorageError)?.underlyingError as? CartoucheDriveFailure)?.activation
            problem = CartoucheReports.connectionFailed(to: candidate, error: error)
        }
    }

    /// The Drive kept under another name.
    private func save() {
        var saved = server
        saved.name = saved.name.trimmingCharacters(in: .whitespaces)
        if saved.name.isEmpty {
            saved.name = CartoucheText.storageDriveTitle
        }
        CartoucheStorageSettings.shared.save(saved, secret: nil)
        // Whether the account may write at the Drive's root, for the choice
        // of the saves folder, which saving forgets.
        Task { await CartoucheStorageSettings.shared.checkAccess(of: saved) }
        dismiss()
    }
}

// MARK: Making the client

/// The steps that make the player's own OAuth client in Google Cloud, once,
/// each with a button that opens its page there.
@available(iOS 17.0, *)
struct CartoucheDriveGuideView: View {
    @Environment(\.openURL) private var openURL
    @State private var copied = false

    private struct Step: Identifiable {
        let number: Int
        let title: String
        let detail: String
        var page: String?
        /// The bundle ID to type in Google Cloud, with a button that copies it.
        var showsBundleID = false
        var id: Int { number }
    }

    private static let console = "https://console.cloud.google.com/"

    private var steps: [Step] {
        [
            Step(number: 1, title: CartoucheText.storageDriveStepProject, detail: CartoucheText.storageDriveStepProjectDetail,
                 page: Self.console + "projectcreate"),
            Step(number: 2, title: CartoucheText.storageDriveStepAPI, detail: CartoucheText.storageDriveStepAPIDetail,
                 page: Self.console + "apis/library/drive.googleapis.com"),
            Step(number: 3, title: CartoucheText.storageDriveStepBranding, detail: CartoucheText.storageDriveStepBrandingDetail,
                 page: Self.console + "auth/overview"),
            Step(number: 4, title: CartoucheText.storageDriveStepTester, detail: CartoucheText.storageDriveStepTesterDetail,
                 page: Self.console + "auth/audience"),
            Step(number: 5, title: CartoucheText.storageDriveStepClient, detail: CartoucheText.storageDriveStepClientDetail,
                 page: Self.console + "auth/clients/create", showsBundleID: true),
            Step(number: 6, title: CartoucheText.storageDriveStepSignIn, detail: CartoucheText.storageDriveStepSignInDetail),
        ]
    }

    /// Cartouche's own bundle ID, as installed on this iPhone.
    private var bundleID: String { Bundle.main.bundleIdentifier ?? "" }

    var body: some View {
        List {
            Section {
                Text(CartoucheText.storageDriveGuideIntro)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            ForEach(steps) { step in
                Section {
                    Label {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(step.title)
                                .font(.headline)
                            Text(step.detail)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    } icon: {
                        Image(systemName: "\(step.number).circle.fill")
                            .foregroundStyle(Color.accentColor)
                    }
                    if step.showsBundleID, !bundleID.isEmpty {
                        LabeledContent {
                            Text(bundleID)
                                .font(.caption.monospaced())
                                .lineLimit(2)
                                .multilineTextAlignment(.trailing)
                                .textSelection(.enabled)
                        } label: {
                            Text(CartoucheText.storageDriveBundleID)
                        }
                        Button {
                            UIPasteboard.general.string = bundleID
                            copied = true
                        } label: {
                            Label(copied ? CartoucheText.storageDriveCopied : CartoucheText.storageDriveCopy,
                                  systemImage: copied ? "checkmark.circle.fill" : "doc.on.doc")
                        }
                    }
                    if let page = step.page.flatMap(URL.init(string:)) {
                        Button {
                            openURL(page)
                        } label: {
                            Label(CartoucheText.storageDriveOpenStep, systemImage: "safari")
                        }
                    }
                }
            }
            Section {
                Text(CartoucheText.storageDriveWeekly)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .cartoucheStageBackground()
        .navigationTitle(CartoucheText.storageDriveGuideTitle)
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: Signing in again

/// Sign in again, for a Google Drive whose sign-in Google ended: Google's
/// page at once, without the form. Once signed in, the games folder is read
/// again and the saves waiting go.
@available(iOS 17.0, *)
struct CartoucheDriveSignInAgainButton: View {
    let server: CartoucheStorageServer
    @StateObject private var signing = CartoucheDriveSigning()
    @State private var problem: CartoucheReport?
    @State private var note: String?

    var body: some View {
        Button {
            Task { await signIn() }
        } label: {
            HStack {
                Label(CartoucheText.storageDriveSignInAgain, systemImage: "person.badge.key")
                if signing.isBusy {
                    Spacer()
                    ProgressView()
                }
            }
        }
        .disabled(signing.isBusy)
        if let note {
            Text(note)
                .font(.footnote)
                .foregroundStyle(Color.orange)
        }
        if let problem {
            Text(problem.message)
                .font(.footnote)
                .foregroundStyle(Color.orange)
            CartoucheReportButton(report: problem)
        }
    }

    private func signIn() async {
        problem = nil
        note = nil
        // The Drive as the settings hold it now.
        let current = CartoucheStorageSettings.shared.server(server.id) ?? server
        do {
            _ = try await signing.signIn(current)
        } catch let away as CartoucheStorageOffline {
            note = away.localizedDescription
        } catch let error as CartoucheStorageError where error.kind == .webSignIn && error.underlyingError == nil {
            note = error.localizedDescription
        } catch {
            problem = CartoucheReports.connectionFailed(to: current, error: error)
        }
    }
}
