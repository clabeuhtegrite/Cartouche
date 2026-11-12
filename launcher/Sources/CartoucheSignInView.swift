//
//  CartoucheSignInView.swift
//  Cartouche
//
//  The Apple ID sign-in, on Cartouche's own screen (CartoucheAccount): the
//  Apple ID and its password, then the verification code Apple sends, while
//  the built-in SideStore signs in without showing itself. It closes once
//  SideStore is signed in, and the setup shows the certificate coming in.
//  While Apple refuses more sign-ins for now, Sign In gives way to the time
//  left to wait (CartoucheSignInPause).
//

import SwiftUI

@available(iOS 17.0, *)
struct CartoucheSignInView: View {
    @ObservedObject private var account = CartoucheAccount.shared
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    @State private var appleID = CartoucheSetup.shared.appleID ?? ""
    @State private var password = ""
    @State private var code = ""

    private enum Field: Hashable {
        case appleID, password, code
    }
    @FocusState private var focus: Field?

    private var isBusy: Bool { account.phase != nil }

    private var request: CartoucheSignInMessage.CodeRequest? {
        if case .code(let request) = account.phase { return request }
        return nil
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(CartoucheText.signInTitle)
                            .font(.system(.largeTitle, design: .rounded, weight: .bold))
                        Text(CartoucheText.signInIntro)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.bottom, 4)
                    if let request {
                        codeCard(request)
                    } else {
                        accountCard
                    }
                    if let problem = account.problemReport, !isBusy {
                        problemCard(problem)
                    }
                    vpnCard
                }
                .padding()
                .frame(maxWidth: 560)
                .frame(maxWidth: .infinity)
            }
            .background(CartoucheStage(key: nil))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(CartoucheText.cancel) {
                        if request != nil {
                            account.answer(.cancel)
                        } else {
                            dismiss()
                        }
                    }
                    .disabled(account.phase == .signingIn)
                }
            }
        }
        // Dark like the console under it, whatever the iPhone's appearance.
        .preferredColorScheme(.dark)
        .interactiveDismissDisabled(isBusy)
        .onAppear {
            focus = appleID.isEmpty ? .appleID : .password
        }
        .onChange(of: request?.id) { _, id in
            code = ""
            if id != nil { focus = .code }
        }
        .onChange(of: account.signedIn) { _, signedIn in
            if signedIn { dismiss() }
        }
    }

    // MARK: The Apple ID

    private var accountCard: some View {
        card {
            VStack(alignment: .leading, spacing: 12) {
                TextField(CartoucheText.signInAppleID, text: $appleID)
                    .textContentType(.username)
                    .keyboardType(.emailAddress)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.next)
                    .focused($focus, equals: .appleID)
                    .onSubmit { focus = .password }
                    .modifier(FieldStyle())
                SecureField(CartoucheText.signInPassword, text: $password)
                    .textContentType(.password)
                    .submitLabel(.go)
                    .focused($focus, equals: .password)
                    .onSubmit(signIn)
                    .modifier(FieldStyle())
                Text(CartoucheText.signInFreeAccount)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if isBusy {
                    working(CartoucheText.signInWorking)
                } else if let until = account.pausedUntil {
                    // Apple refuses more sign-ins for now: the time left,
                    // then Sign In again.
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        if context.date < until {
                            waitButton(Self.timeLeft(until.timeIntervalSince(context.date)))
                        } else {
                            signInButton
                        }
                    }
                } else {
                    signInButton
                }
            }
        }
        .disabled(isBusy)
    }

    private var signInButton: some View {
        Button(action: signIn) {
            Label(CartoucheText.signInButton, systemImage: "person.crop.circle.badge.checkmark")
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .disabled(!CartoucheSignInMessage.canSignIn(appleID: appleID, password: password))
    }

    private func waitButton(_ timeLeft: String) -> some View {
        Button {} label: {
            Label(CartoucheText.signInWait(timeLeft), systemImage: "hourglass")
                .monospacedDigit()
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .disabled(true)
    }

    /// "14 min 32 s", in the iPhone's language.
    private static func timeLeft(_ seconds: TimeInterval) -> String {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = seconds >= 3_600 ? [.hour, .minute] : [.minute, .second]
        formatter.unitsStyle = .abbreviated
        formatter.maximumUnitCount = 2
        return formatter.string(from: max(1, seconds.rounded(.up))) ?? ""
    }

    private func signIn() {
        guard account.pausedUntil == nil, CartoucheSignInMessage.canSignIn(appleID: appleID, password: password) else { return }
        focus = nil
        account.signIn(appleID: appleID, password: password)
        // SideStore keeps the password in its own keychain items.
        password = ""
    }

    // MARK: The verification code

    private func codeMessage(_ request: CartoucheSignInMessage.CodeRequest) -> String {
        switch request.mode {
        case .trustedDevice:
            return CartoucheText.signInCodeTrustedDevice
        case .sms:
            return request.phone.map(CartoucheText.signInCodeSMS) ?? CartoucheText.signInCodeSMSAnyNumber
        case .voice:
            return request.phone.map(CartoucheText.signInCodeVoice) ?? CartoucheText.signInCodeVoiceAnyNumber
        }
    }

    private func codeCard(_ request: CartoucheSignInMessage.CodeRequest) -> some View {
        card {
            VStack(alignment: .leading, spacing: 12) {
                Label(CartoucheText.signInCodeTitle, systemImage: "lock.shield.fill")
                    .font(.system(.title3, design: .rounded, weight: .bold))
                Text(codeMessage(request))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let error = request.error {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
                TextField(CartoucheText.signInCodePlaceholder, text: $code)
                    .textContentType(.oneTimeCode)
                    .keyboardType(.numberPad)
                    .font(.system(.title2, design: .monospaced, weight: .semibold))
                    .multilineTextAlignment(.center)
                    .focused($focus, equals: .code)
                    .modifier(FieldStyle())
                    .onChange(of: code) { _, typed in
                        // A code iOS fills in from a text message goes by itself.
                        if let full = CartoucheSignInMessage.code(from: typed), typed.count == 6 {
                            account.answer(.code(full))
                        }
                    }
                Button {
                    if let full = CartoucheSignInMessage.code(from: code) { account.answer(.code(full)) }
                } label: {
                    Text(CartoucheText.signInCodeContinue)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(CartoucheSignInMessage.code(from: code) == nil)
                if request.canTextMessage {
                    Button(CartoucheText.signInCodeBySMS, systemImage: "message") {
                        account.answer(.textMessage)
                    }
                    .buttonStyle(.bordered)
                } else if request.mode != .trustedDevice {
                    Button(CartoucheText.signInCodeByDevice, systemImage: "iphone.gen3") {
                        account.answer(.trustedDevice)
                    }
                    .buttonStyle(.bordered)
                }
            }
        }
    }

    // MARK: What went wrong, and LocalDevVPN

    private func problemCard(_ problem: CartoucheReport) -> some View {
        card {
            VStack(alignment: .leading, spacing: 10) {
                Label(CartoucheText.signInFailedTitle, systemImage: "exclamationmark.triangle.fill")
                    .font(.headline)
                    .foregroundStyle(.red)
                Text(problem.message)
                    .font(.subheadline)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                if let link = account.problemLink {
                    Button(CartoucheText.signInOpenPage, systemImage: "safari") {
                        openURL(link)
                    }
                    .buttonStyle(.bordered)
                }
                CartoucheReportButton(report: problem)
                    .buttonStyle(.bordered)
            }
        }
    }

    private var vpnCard: some View {
        card {
            VStack(alignment: .leading, spacing: 10) {
                Label(CartoucheText.signInVPNTitle, systemImage: "network.badge.shield.half.filled")
                    .font(.headline)
                Text(CartoucheText.signInVPNHow)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button {
                    UIApplication.shared.open(CartoucheSetupView.localDevVPN) { opened in
                        if !opened { UIApplication.shared.open(CartoucheSetupView.localDevVPNAppStore) }
                    }
                } label: {
                    Label(CartoucheText.setupVPNOpen, systemImage: "arrow.up.forward.app")
                }
                .buttonStyle(.bordered)
            }
        }
    }

    private func working(_ text: String) -> some View {
        HStack(spacing: 10) {
            ProgressView()
            Text(text)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 6)
    }

    private func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content()
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(uiColor: .secondarySystemGroupedBackground),
                        in: RoundedRectangle(cornerRadius: 22, style: .continuous))
    }

    private struct FieldStyle: ViewModifier {
        func body(content: Content) -> some View {
            content
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .background(Color(uiColor: .tertiarySystemGroupedBackground),
                            in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
    }
}
