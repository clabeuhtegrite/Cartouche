//
//  CartoucheSetupView.swift
//  Cartouche
//
//  The setup, once per iPhone: the pairing file iloader places, the Apple ID
//  the built-in SideStore signs in with, then the certificate, which Cartouche
//  hands to LiveContainer on its own (CartoucheSetup.swift). Each step shows
//  where it stands, read again whenever Cartouche comes back to the front.
//

import SwiftUI
import UniformTypeIdentifiers

@available(iOS 17.0, *)
struct CartoucheSetupView: View {
    @ObservedObject private var setup = CartoucheSetup.shared
    @State private var choosingPairingFile = false

    static let localDevVPN = URL(string: "localdevvpn://")!
    static let localDevVPNAppStore = URL(string: "https://apps.apple.com/app/localdevvpn/id6755608044")!

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
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
                    if let pairingError = setup.pairingError {
                        Label(pairingError, systemImage: "exclamationmark.triangle.fill")
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }
                }
                step(
                    number: 2,
                    done: setup.appleID != nil || setup.hasCertificate,
                    title: CartoucheText.setupAppleIDTitle,
                    detail: setup.appleID.map(CartoucheText.setupAppleIDDone) ?? CartoucheText.setupAppleIDHow
                ) {
                    if setup.appleID == nil && !setup.hasCertificate {
                        // SideStore registers this iPhone at sign-in, through
                        // the pairing file.
                        Button {
                            setup.signIn()
                        } label: {
                            Label(CartoucheText.setupOpenSideStore, systemImage: "person.crop.circle.badge.checkmark")
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(!setup.hasPairingFile)
                    }
                }
                step(
                    number: 3,
                    done: setup.hasCertificate,
                    title: CartoucheText.setupCertificateTitle,
                    detail: setup.hasCertificate ? CartoucheText.setupCertificateDone : CartoucheText.setupCertificateHow
                ) {
                    if !setup.hasCertificate {
                        Button(CartoucheText.setupCheckAgain, systemImage: "arrow.clockwise") {
                            setup.refresh()
                        }
                        .buttonStyle(.bordered)
                    }
                }
                renewalNote
            }
            .padding()
            .frame(maxWidth: 640)
            .frame(maxWidth: .infinity)
        }
        .background(Color(uiColor: .systemGroupedBackground))
        .navigationTitle(CartoucheText.setupTitle)
        .navigationBarTitleDisplayMode(.inline)
        .modifier(CartoucheSetupRefresh())
        .fileImporter(isPresented: $choosingPairingFile, allowedContentTypes: CartouchePairing.contentTypes) { result in
            switch result {
            case .success(let url):
                setup.importPairingFile(url)
            case .failure(let error):
                setup.pairingError = error.localizedDescription
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(setup.isComplete ? CartoucheText.setupAllDone : CartoucheText.setupIntroTitle)
                .font(.system(.largeTitle, design: .rounded, weight: .bold))
            Text(setup.isComplete ? CartoucheText.setupAllDoneDetail : CartoucheText.setupIntro)
                .foregroundStyle(.secondary)
        }
        .padding(.bottom, 4)
    }

    private func step<Actions: View>(
        number: Int, done: Bool, title: String, detail: String,
        @ViewBuilder actions: () -> Actions
    ) -> some View {
        HStack(alignment: .top, spacing: 14) {
            ZStack {
                Circle()
                    .fill(done ? Color.green : Color.accentColor)
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

    var body: some View {
        if !setup.isComplete {
            NavigationLink {
                CartoucheSetupView()
            } label: {
                HStack(spacing: 14) {
                    Image(systemName: setup.canPlay ? "arrow.triangle.2.circlepath" : "checklist")
                        .font(.title2.weight(.semibold))
                        .frame(width: 44, height: 44)
                        .background(Color.white.opacity(0.18), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    VStack(alignment: .leading, spacing: 3) {
                        Text(setup.canPlay ? CartoucheText.setupBannerRenewal : CartoucheText.setupBannerTitle)
                            .font(.headline)
                        Text(setup.canPlay ? CartoucheText.setupBannerRenewalDetail : CartoucheText.setupBannerDetail)
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
