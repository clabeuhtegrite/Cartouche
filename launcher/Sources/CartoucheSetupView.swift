//
//  CartoucheSetupView.swift
//  Cartouche
//
//  The setup, once per iPhone: the pairing file the installer places, the Apple ID
//  the built-in SideStore signs in with, given here (CartoucheSignInView), then
//  the certificate, which Cartouche hands to LiveContainer on its own
//  (CartoucheSetup.swift). Each step shows
//  where it stands, read again whenever Cartouche comes back to the front.
//  The Apple ID's step stays open while this iPhone is left to register,
//  and while the sign-in stopped before the certificate, with why it
//  stopped.
//

import SwiftUI
import UniformTypeIdentifiers

@available(iOS 17.0, *)
struct CartoucheSetupView: View {
    @ObservedObject private var setup = CartoucheSetup.shared
    @ObservedObject private var account = CartoucheAccount.shared
    @State private var choosingPairingFile = false
    @State private var signingIn = false

    static let localDevVPN = URL(string: "localdevvpn://")!
    static let localDevVPNAppStore = URL(string: "https://apps.apple.com/app/localdevvpn/id6755608044")!

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                if !setup.usesImportedSigning {
                    step(
                        number: 1,
                        done: setup.hasPairingFile,
                        title: CartoucheText.setupPairingTitle,
                        detail: setup.hasPairingFile ? CartoucheText.setupPairingDone : CartoucheText.setupPairingHow
                    ) {
                        Button {
                            choosingPairingFile = true
                        } label: {
                            Label(setup.hasPairingFile ? CartoucheText.setupPairingReplace : CartoucheText.setupPairingChoose,
                                  systemImage: "doc.badge.plus")
                        }
                        .buttonStyle(.bordered)
                        if let pairingReport = setup.pairingReport {
                            Label(pairingReport.message, systemImage: "exclamationmark.triangle.fill")
                                .font(.footnote)
                                .foregroundStyle(.red)
                            CartoucheReportButton(report: pairingReport)
                                .font(.footnote)
                                .buttonStyle(.bordered)
                        }
                    }
                    step(
                        number: 2,
                        done: setup.signInStep == .done && !setup.needsDevice,
                        title: CartoucheText.setupAppleIDTitle,
                        detail: appleIDDetail
                    ) {
                        if setup.appleID == nil || !setup.hasCertificate || setup.certificateRefused || setup.needsDevice {
                            // SideStore registers this iPhone at sign-in, through
                            // the pairing file.
                            Button {
                                signingIn = true
                            } label: {
                                Label(appleIDButton, systemImage: setup.needsDevice ? "iphone.gen3" : "person.crop.circle.badge.checkmark")
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(!setup.hasPairingFile || account.phase == .registeringDevice)
                        }
                        // Why the sign-in stopped, once its screen has gone.
                        if setup.signInStep == .unfinished, account.phase == nil, let report = account.lastProblem {
                            Label(report.message, systemImage: "exclamationmark.triangle.fill")
                                .font(.footnote)
                                .foregroundStyle(.red)
                                .fixedSize(horizontal: false, vertical: true)
                            CartoucheReportButton(report: report)
                                .font(.footnote)
                                .buttonStyle(.bordered)
                        }
                    }
                }
                step(
                    number: setup.usesImportedSigning ? 1 : 3,
                    done: setup.hasCertificate && setup.certificateWorks == true,
                    title: CartoucheText.setupCertificateTitle,
                    detail: certificateDetail
                ) {
                    if CartoucheImportedSigning.isImportedInstall {
                        NavigationLink {
                            CartoucheSigningView()
                        } label: {
                            Label(CartoucheText.signingTitle, systemImage: "signature")
                        }
                        .buttonStyle(.bordered)
                    }
                    if let problem = setup.signingProblem {
                        Text(problem).font(.footnote).foregroundStyle(.red)
                    }
                    if setup.isImportingSigning { ProgressView(CartoucheText.setupCertificateChecking) }
                    if setup.usesImportedSigning {
                        Text(CartoucheImportedSigning.isSignedOnIPhone ? CartoucheText.signingUpdateOnIPhone
                             : CartoucheText.signingUpdateOnComputer)
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    // A sign-in that stopped: signing in again brings it.
                    if !setup.hasCertificate && setup.signInStep != .unfinished {
                        Button(CartoucheText.setupCheckAgain, systemImage: "arrow.clockwise") {
                            setup.refresh()
                        }
                        .buttonStyle(.bordered)
                    }
                }
                if setup.usesImportedSigning, let signature = CartoucheOwnSignature.current {
                    CartoucheOwnSignatureBox(signature: signature)
                }
                if !setup.usesImportedSigning { renewalNote }
            }
            .padding()
            .frame(maxWidth: 640)
            .frame(maxWidth: .infinity)
        }
        .background(CartoucheStage(key: nil))
        .navigationTitle(CartoucheText.setupTitle)
        .navigationBarTitleDisplayMode(.inline)
        .modifier(CartoucheSetupRefresh())
        .sheet(isPresented: $signingIn) {
            CartoucheSignInView()
        }
        // Apple asks for a code while Cartouche signs in again by itself.
        .onAppear { if account.needsCode { signingIn = true } }
        .onChange(of: account.needsCode) { _, needsCode in
            if needsCode { signingIn = true }
        }
        .fileImporter(isPresented: $choosingPairingFile, allowedContentTypes: CartouchePairing.contentTypes) { result in
            switch result {
            case .success(let url):
                setup.importPairingFile(url)
            case .failure(let error):
                setup.pairingFailed(error)
            }
        }
    }

    private var appleIDDetail: String {
        guard let appleID = setup.appleID else { return CartoucheText.setupAppleIDHow }
        // The sign-in stopped before the certificate: signing in again
        // brings it.
        if setup.signInStep == .unfinished {
            let working = account.phase == .signingIn || account.needsCode
            return working ? CartoucheText.signInWorking : CartoucheText.setupAppleIDUnfinished(appleID)
        }
        guard setup.needsDevice else { return CartoucheText.setupAppleIDDone(appleID) }
        return account.phase == .registeringDevice ? CartoucheText.setupBannerDeviceWorking : CartoucheText.setupAppleIDDevice(appleID)
    }

    private var appleIDButton: String {
        if setup.needsDevice { return CartoucheText.signInDeviceButton }
        return setup.appleID == nil ? CartoucheText.setupSignIn : CartoucheText.signInAgain
    }

    private var certificateDetail: String {
        if setup.usesImportedSigning {
            let onIPhone = CartoucheImportedSigning.isSignedOnIPhone
            if setup.certificateRefused { return onIPhone ? CartoucheText.signingRefusedOnIPhone : CartoucheText.signingRefused }
            if !setup.hasCertificate { return onIPhone ? CartoucheText.signingHowOnIPhone : CartoucheText.signingHow }
        }
        guard setup.hasCertificate else { return CartoucheText.setupCertificateHow }
        switch setup.certificateWorks {
        case true?: return CartoucheText.setupCertificateDone
        case nil: return CartoucheText.setupCertificateChecking
        case false?: return account.isAutomatic ? CartoucheText.setupCertificateRenewing : CartoucheText.setupCertificateRefused
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(setup.needsSetup ? CartoucheText.setupIntroTitle : CartoucheText.setupAllDone)
                .font(.system(.largeTitle, design: .rounded, weight: .bold))
            Text(headerDetail)
                .foregroundStyle(.secondary)
        }
        .padding(.bottom, 4)
    }

    /// With the player's own certificate, Cartouche renews nothing: the
    /// certificate is the only step.
    private var headerDetail: String {
        if setup.usesImportedSigning {
            return setup.needsSetup ? CartoucheText.setupIntroOwnCertificate : CartoucheText.setupAllDoneOwnCertificate
        }
        return setup.needsSetup ? CartoucheText.setupIntro : CartoucheText.setupAllDoneDetail
    }

    private func step<Actions: View>(
        number: Int, done: Bool, title: String, detail: String,
        @ViewBuilder actions: () -> Actions
    ) -> some View {
        HStack(alignment: .top, spacing: 14) {
            ZStack {
                Circle()
                    .fill(done ? Color.green : CartoucheTheme.indigo)
                if done {
                    Image(systemName: "checkmark")
                        .font(.headline.weight(.heavy))
                } else {
                    Text(String(number))
                        .font(.headline.monospacedDigit().weight(.heavy))
                }
            }
            .foregroundStyle(.white)
            .frame(width: 34, height: 34)
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 10) {
                Text(title)
                    .font(.system(.title3, design: .rounded, weight: .bold))
                Text(detail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                actions()
            }
            Spacer(minLength: 0)
        }
        .padding(16)
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(done ? CartoucheText.setupStepDone(title) : title)
    }

    private var renewalNote: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(CartoucheText.setupVPNTitle, systemImage: "network.badge.shield.half.filled")
                .font(.headline)
            Text(CartoucheText.setupVPNHow)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button {
                UIApplication.shared.open(Self.localDevVPN) { opened in
                    if !opened { UIApplication.shared.open(Self.localDevVPNAppStore) }
                }
            } label: {
                Label(CartoucheText.setupVPNOpen, systemImage: "arrow.up.forward.app")
            }
            .buttonStyle(.bordered)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
    }
}

/// The banner over the games while Cartouche is not set up.
@available(iOS 17.0, *)
struct CartoucheSetupBanner: View {
    @ObservedObject private var setup = CartoucheSetup.shared
    @ObservedObject private var account = CartoucheAccount.shared

    var body: some View {
        if setup.needsSetup {
            NavigationLink {
                CartoucheSetupView()
            } label: {
                HStack(spacing: 14) {
                    Image(systemName: setup.bannerIcon)
                        .font(.title2.weight(.semibold))
                        .frame(width: 44, height: 44)
                        .background(Color.white.opacity(0.18), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    VStack(alignment: .leading, spacing: 3) {
                        Text(setup.bannerTitle)
                            .font(.headline)
                        Text(setup.bannerDetail(signingInAgain: account.isAutomatic,
                                                registeringDevice: account.phase == .registeringDevice))
                            .font(.subheadline)
                            .opacity(0.85)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right")
                        .font(.headline)
                        .opacity(0.7)
                }
                .foregroundStyle(.white)
                .padding(16)
                .background(
                    LinearGradient(colors: [Color.accentColor, Color.accentColor.opacity(0.7)],
                                   startPoint: .topLeading, endPoint: .bottomTrailing),
                    in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            }
            .buttonStyle(.plain)
        }
    }
}

/// What the setup banners say, over the home and the games.
@available(iOS 17.0, *)
extension CartoucheSetup {
    var bannerIcon: String {
        certificateRefused ? "exclamationmark.shield.fill" : canPlay ? "arrow.triangle.2.circlepath" : "checklist"
    }

    var bannerTitle: String {
        if certificateRefused { return CartoucheText.setupBannerCertificate }
        return canPlay ? CartoucheText.setupBannerRenewal : CartoucheText.setupBannerTitle
    }

    func bannerDetail(signingInAgain: Bool, registeringDevice: Bool = false) -> String {
        if usesImportedSigning {
            if CartoucheImportedSigning.isSignedOnIPhone {
                return certificateRefused ? CartoucheText.signingRefusedOnIPhone : CartoucheText.signingHowOnIPhone
            }
            return certificateRefused ? CartoucheText.signingRefused : CartoucheText.signingHow
        }
        if certificateRefused {
            return signingInAgain ? CartoucheText.setupBannerCertificateRenewing : CartoucheText.setupBannerCertificateDetail
        }
        if signInStep == .unfinished {
            return signingInAgain ? CartoucheText.setupBannerCertificateRenewing : CartoucheText.setupBannerUnfinishedDetail
        }
        guard canPlay else { return CartoucheText.setupBannerDetail }
        guard hasPairingFile else { return CartoucheText.setupBannerRenewalDetail }
        guard needsDevice else { return CartoucheText.setupBannerSignInDetail }
        // Signed in, with this iPhone left to register.
        return registeringDevice ? CartoucheText.setupBannerDeviceWorking : CartoucheText.setupBannerDeviceDetail
    }
}

/// What Cartouche's signature gives it, signed with the player's own
/// certificate (CartoucheOwnSignature): Increased Memory Limit, without
/// which iOS gives Cartouche about 3 GB, and the games' keychains, with how
/// a missing one comes back.
@available(iOS 17.0, *)
struct CartoucheOwnSignatureBox: View {
    let signature: CartoucheOwnSignature

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(CartoucheText.signatureCheckTitle, systemImage: "signature")
                .font(.headline)
            row(CartoucheText.imlRequirement, granted: signature.increasedMemoryLimit == .granted,
                detail: memoryDetail, warning: true)
            row(CartoucheText.signatureKeychains, granted: signature.gameKeychains == .granted,
                detail: keychainDetail, warning: false)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .accessibilityElement(children: .contain)
    }

    private var memoryDetail: String? {
        switch signature.increasedMemoryLimit {
        case .granted: return nil
        case .leftOut: return CartoucheText.signatureMemoryLeftOut
        case .notInProfile: return CartoucheText.signatureMemoryNotInProfile
        }
    }

    private var keychainDetail: String? {
        switch signature.gameKeychains {
        case .granted: return CartoucheText.signatureKeychainsGranted
        case .leftOut: return CartoucheText.signatureKeychainsLeftOut
        case .notInProfile: return CartoucheText.signatureKeychainsNotInProfile
        }
    }

    /// A grant: ticked, or, missing, in orange when Cartouche needs it and
    /// in grey when the games seldom do.
    private func row(_ title: String, granted: Bool, detail: String?, warning: Bool) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            LabeledContent(title) {
                Label(granted ? CartoucheText.imlOn : CartoucheText.imlOff,
                      systemImage: granted ? "checkmark.circle.fill" : warning ? "exclamationmark.triangle.fill" : "info.circle")
                    .labelStyle(CartoucheTightLabelStyle())
                    .foregroundStyle(granted ? Color.green : warning ? Color.orange : Color.secondary)
            }
            .font(.subheadline.weight(.semibold))
            if let detail {
                Text(detail)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
