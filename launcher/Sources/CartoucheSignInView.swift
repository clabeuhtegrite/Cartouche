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
//  Without LocalDevVPN, Sign In waits for it, with the button that connects
//  it, then goes on by itself. Once Apple has accepted the account, should
//  only this iPhone be left to register, the screen offers that step alone,
//  without the password or a code.
//

import SwiftUI

@available(iOS 17.0, *)
struct CartoucheSignInView: View {
    @ObservedObject private var account = CartoucheAccount.shared
    @ObservedObject private var setup = CartoucheSetup.shared
    @ObservedObject private var guide = CartoucheGuide.shared
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    @State private var appleID = CartoucheSetup.shared.appleID ?? ""
    @State private var password = ""
    @State private var code = ""
    /// The player chose to sign in again, rather than to register this
    /// iPhone alone.
    @State private var signingInAgain = false

    private enum Field: Hashable {
        case appleID, password, code
    }
    @FocusState private var focus: Field?

    private var isBusy: Bool { account.phase != nil }

    private var request: CartoucheSignInMessage.CodeRequest? {
        if case .code(let request) = account.phase { return request }
        return nil
    }

    /// Whether the screen offers to register this iPhone alone.
    private var showsDeviceStep: Bool {
        switch account.phase {
        case .registeringDevice?, .waitingForVPN(deviceStep: true)?: return true
        case .signingIn?, .code?, .waitingForVPN(deviceStep: false)?: return false
        case nil: return setup.needsDevice && !signingInAgain
        }
    }

    /// Whether SideStore is at work, which nothing interrupts.
    private var sideStoreRuns: Bool {
        account.phase == .signingIn || account.phase == .registeringDevice
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
                    } else if showsDeviceStep {
                        deviceCard
                    } else {
                        accountCard
                    }
                    if let problem = account.problemReport, !isBusy, !showsDeviceStep {
                        problemCard(problem)
                    }
                    if !account.isWaitingForVPN {
                        vpnCard
                    }
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
                        } else if account.isWaitingForVPN {
                            account.stopWaiting()
                        } else {
                            dismiss()
                        }
                    }
                    .disabled(sideStoreRuns)
                }
            }
        }
        // Dark like the console under it, whatever the iPhone's appearance.
        .preferredColorScheme(.dark)
        .interactiveDismissDisabled(isBusy)
        .onAppear {
            if !showsDeviceStep { focus = appleID.isEmpty ? .appleID : .password }
        }
        .onChange(of: request?.id) { _, id in
            code = ""
            if id != nil { focus = .code }
        }
        .onChange(of: account.phase) { old, new in
            guard new == nil, old == .signingIn || isCode(old) else { return }
            // The sign-in ended: its password goes, unless it never left
            // this iPhone. A sign-in that leaves this iPhone to register
            // offers that step.
            if !CartoucheSignInMessage.keepsPassword(after: account.problemReport?.failure) { password = "" }
            signingInAgain = false
        }
        .onChange(of: account.signedIn) { _, signedIn in
            if signedIn { dismiss() }
        }
        // Whether LocalDevVPN is connected, as the player connects it.
        .task {
            while !Task.isCancelled {
                guide.refreshVPN()
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    private func isCode(_ phase: CartoucheAccount.Phase?) -> Bool {
        if case .code? = phase { return true }
        return false
    }

    // MARK: The Apple ID

    private var accountCard: some View {
        card {
            VStack(alignment: .leading, spacing: 12) {
                Group {
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
                }
                .disabled(isBusy)
                if account.isWaitingForVPN {
                    vpnWait
                } else if isBusy {
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
    }

    // MARK: This iPhone, alone

    private var deviceCard: some View {
        card {
            VStack(alignment: .leading, spacing: 12) {
                Label(CartoucheText.signInDeviceTitle, systemImage: "iphone.gen3")
                    .font(.system(.title3, design: .rounded, weight: .bold))
                Text(CartoucheText.signInDeviceHow)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let problem = account.problemReport, !isBusy {
                    Label(Self.problemLine(problem), systemImage: "exclamationmark.triangle.fill")
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                    CartoucheReportButton(report: problem)
                        .font(.footnote)
                        .buttonStyle(.bordered)
                }
                if account.isWaitingForVPN {
                    vpnWait
                } else if account.phase == .registeringDevice {
                    working(CartoucheText.signInDeviceWorking)
                } else if let until = account.pausedUntil {
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        if context.date < until {
                            waitButton(Self.timeLeft(until.timeIntervalSince(context.date)))
                        } else {
                            deviceButton
                        }
                    }
                } else {
                    deviceButton
                }
                if !isBusy {
                    // Should SideStore's account no longer do, as when Apple
                    // asks to sign in again.
                    Button(CartoucheText.signInAgain, systemImage: "person.crop.circle.badge.checkmark") {
                        signingInAgain = true
                        focus = appleID.isEmpty ? .appleID : .password
                    }
                    .buttonStyle(.bordered)
                }
            }
        }
    }

    private var deviceButton: some View {
        Button {
            account.registerDevice()
        } label: {
            Label(CartoucheText.signInDeviceButton, systemImage: "iphone.gen3")
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
    }

    /// The problem's words, or only what to do about this iPhone's
    /// connection, which the card already puts in context.
    private static func problemLine(_ problem: CartoucheReport) -> String {
        problem.failure.flatMap(CartoucheSignInMessage.deviceTrouble(in:)).map(CartoucheText.deviceMessage) ?? problem.message
    }

    // MARK: Waiting for LocalDevVPN

    private var vpnWait: some View {
        VStack(alignment: .leading, spacing: 12) {
            working(CartoucheText.signInVPNWaiting)
            connectVPNButton(prominent: true)
            Button(CartoucheText.signInVPNGoOn) {
                account.goOn()
            }
            .font(.footnote)
        }
    }

    /// Connects LocalDevVPN, which then opens Cartouche again; its page of
    /// the App Store when it is not on this iPhone.
    @ViewBuilder
    private func connectVPNButton(prominent: Bool) -> some View {
        let installed = guide.hasLocalDevVPN
        let button = Button {
            if installed {
                guide.connectVPN()
            } else {
                openURL(CartoucheGuide.localDevVPNAppStore)
            }
        } label: {
            Label(installed ? CartoucheText.guideVPNConnect : CartoucheText.guideVPNGet,
                  systemImage: installed ? "network.badge.shield.half.filled" : "arrow.down.app")
                .frame(maxWidth: prominent ? .infinity : nil)
        }
        if prominent {
            button
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
        } else {
            button
                .buttonStyle(.bordered)
        }
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
                Label(problem.title, systemImage: "exclamationmark.triangle.fill")
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
                if guide.vpnConnected {
                    Label(CartoucheText.guideVPNDone, systemImage: "checkmark.circle.fill")
                        .font(.headline)
                        .foregroundStyle(.green)
                } else {
                    Label(CartoucheText.signInVPNTitle, systemImage: "network.badge.shield.half.filled")
                        .font(.headline)
                }
                Text(CartoucheText.signInVPNHow)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if !guide.vpnConnected {
                    connectVPNButton(prominent: false)
                }
            }
        }
    }

    private func working(_ text: String) -> some View {
        HStack(spacing: 10) {
            ProgressView()
            Text(text)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
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
