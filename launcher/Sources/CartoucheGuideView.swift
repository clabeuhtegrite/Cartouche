//
//  CartoucheGuideView.swift
//  Cartouche
//
//  The first game's guide (CartoucheGuide), over the console: five steps
//  from a new install to a game on the iPhone, each ticked from what
//  Cartouche sees. The step left first is open, with its action; a later
//  one opens with a tap, for a player who takes them in another order.
//  Each action is one Cartouche already has: LocalDevVPN connects and
//  brings Cartouche back by itself, the sign-in is the setup's own screen,
//  the games folder the storage page; the Mac's steps go to the Mac as a
//  link to Cartouche Builder's page of Cartouche's site, by AirDrop or
//  Messages. No thanks skips the Mac's step, which stays closed: a tap
//  opens it again. Installing or importing a game closes the guide, for
//  the console to show the install, then the game's sheet.
//
//  The card at the top of the home (CartoucheGuideCard) opens the guide,
//  and its × takes it off the home; the System page opens it then.
//

import SwiftUI
import UniformTypeIdentifiers

@available(iOS 17.0, *)
struct CartoucheGuideView: View {
    typealias Step = CartoucheGuide.Step

    let entries: CartoucheCatalog.Entries
    /// Installs a game of the games folder, once the guide has closed.
    let onInstall: (CartoucheStoredGame) -> Void
    /// Installs an IPA the player picked, once the guide has closed.
    let onImport: (URL) -> Void
    /// Starts the player's game, once the guide has closed.
    let onPlay: (LCAppModel) -> Void

    // Written out: before Swift 6.4 (SE-0502), the private state below made
    // the synthesized initializer private.
    init(entries: CartoucheCatalog.Entries, onInstall: @escaping (CartoucheStoredGame) -> Void,
         onImport: @escaping (URL) -> Void, onPlay: @escaping (LCAppModel) -> Void) {
        self.entries = entries
        self.onInstall = onInstall
        self.onImport = onImport
        self.onPlay = onPlay
    }

    @ObservedObject private var guide = CartoucheGuide.shared
    @ObservedObject private var setup = CartoucheSetup.shared
    @ObservedObject private var account = CartoucheAccount.shared
    @ObservedObject private var storedGames = CartoucheStoredGames.shared
    @ObservedObject private var storage = CartoucheStorageSettings.shared
    @Environment(\.openURL) private var openURL
    /// A later step the player opened; nil: the step left first.
    @State private var opened: Step?
    @State private var signingIn = false
    @State private var choosingIPA = false
    @State private var showingSetup = false
    @State private var showingStorage = false

    var body: some View {
        let progress = guide.progress(entries)
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                header(progress)
                ForEach(Step.allCases) { step in
                    card(step, progress: progress)
                }
                Label(CartoucheText.guideNoDownloads, systemImage: "lock.shield")
                    .font(.footnote)
                    .foregroundStyle(CartoucheTheme.tertiaryText)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 4)
            }
            .padding()
            .frame(maxWidth: 640)
            .frame(maxWidth: .infinity)
        }
        .background(CartoucheStage(key: nil))
        .navigationTitle(CartoucheText.guideTitle)
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(isPresented: $showingSetup) {
            CartoucheSetupView()
        }
        .navigationDestination(isPresented: $showingStorage) {
            CartoucheStorageView()
        }
        .sheet(isPresented: $signingIn) {
            CartoucheSignInView()
        }
        .fileImporter(isPresented: $choosingIPA, allowedContentTypes: [.ipa]) { result in
            if case .success(let url) = result { onImport(url) }
        }
        .modifier(CartoucheSetupRefresh())
        .onAppear {
            guide.noteOpened()
            guide.refreshVPN()
            storedGames.refresh()
            // Apple asks for a code while Cartouche signs in again by itself.
            if account.needsCode { signingIn = true }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
            // LocalDevVPN opens Cartouche again as it connects: its tunnel
            // can come up a moment later.
            guide.refreshVPN()
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { guide.refreshVPN() }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { guide.refreshVPN() }
            storedGames.refresh()
        }
        // While LocalDevVPN is the step left, look for its tunnel every two
        // seconds: the step ticks itself.
        .task(id: progress.current) {
            guard progress.current == .vpn else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                guide.refreshVPN()
            }
        }
        .onChange(of: account.needsCode) { _, needsCode in
            if needsCode { signingIn = true }
        }
        .onChange(of: progress) { _, progress in
            guide.note(progress)
            // The step the player opened is done: the next one left opens.
            if let opened, progress.isDone(opened) { self.opened = nil }
        }
    }

    // MARK: Header

    private func header(_ progress: CartoucheGuide.Progress) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(progress.isFinished ? CartoucheText.guideFinishedTitle : CartoucheText.guideTitle)
                .font(.system(.largeTitle, design: .rounded, weight: .heavy))
                .foregroundStyle(Color.white)
                .accessibilityAddTraits(.isHeader)
            Text(intro(progress))
                .font(.subheadline)
                .foregroundStyle(CartoucheTheme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 6) {
                ForEach(Step.allCases) { step in
                    Capsule()
                        .fill(capsuleStyle(step, progress))
                        .frame(height: 6)
                }
            }
            .accessibilityHidden(true)
        }
        .padding(.bottom, 4)
    }

    private func intro(_ progress: CartoucheGuide.Progress) -> String {
        guard progress.isFinished else { return CartoucheText.guideIntro }
        return progress.buildSkipped ? CartoucheText.guideFinishedIntroNoMac : CartoucheText.guideFinishedIntro
    }

    /// A step's mark over the steps: in Cartouche's colours once done, dim
    /// once skipped, lit while it is the step left.
    private func capsuleStyle(_ step: Step, _ progress: CartoucheGuide.Progress) -> AnyShapeStyle {
        if progress.isDone(step) { return AnyShapeStyle(CartoucheTheme.brand) }
        if progress.isSkipped(step) {
            return AnyShapeStyle(LinearGradient(colors: [CartoucheTheme.indigo.opacity(0.35), CartoucheTheme.pink.opacity(0.35)],
                                                startPoint: .leading, endPoint: .trailing))
        }
        return AnyShapeStyle(Color.white.opacity(progress.current == step ? 0.45 : 0.14))
    }

    // MARK: Steps

    static func title(_ step: Step) -> String {
        switch step {
        case .vpn: return CartoucheText.guideVPNTitle
        case .account: return CartoucheText.guideAccountTitle
        case .build: return CartoucheText.guideBuildTitle
        case .folder: return CartoucheText.guideFolderTitle
        case .play: return CartoucheText.guidePlayTitle
        }
    }

    /// The step shown open: the one the player opened, else the step left
    /// first.
    private func isOpen(_ step: Step, _ progress: CartoucheGuide.Progress) -> Bool {
        !progress.isDone(step) && (opened ?? progress.current) == step
    }

    private func card(_ step: Step, progress: CartoucheGuide.Progress) -> some View {
        let done = progress.isDone(step)
        let open = isOpen(step, progress)
        let skipped = progress.isSkipped(step)
        return HStack(alignment: .top, spacing: 14) {
            badge(step, done: done, open: open, skipped: skipped)
            VStack(alignment: .leading, spacing: 10) {
                Text(Self.title(step))
                    .font(.system(.title3, design: .rounded, weight: .bold))
                    .foregroundStyle(done || open ? Color.white : CartoucheTheme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                if done {
                    doneLine(step, progress)
                } else if open {
                    content(step, progress)
                } else if skipped {
                    detail(CartoucheText.guideBuildSkipped)
                }
            }
            Spacer(minLength: 0)
            if !done && !open {
                Image(systemName: "chevron.down")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(CartoucheTheme.tertiaryText)
                    .padding(.top, 8)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white.opacity(open ? 0.1 : 0.05), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(open ? CartoucheTheme.indigo : Color.clear, lineWidth: 1.5))
        .contentShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .onTapGesture {
            guard !done, !open else { return }
            withAnimation(.easeInOut(duration: 0.2)) { opened = step }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(done ? CartoucheText.guideStepDone(Self.title(step))
                            : skipped && !open ? CartoucheText.guideStepSkipped(Self.title(step)) : Self.title(step))
    }

    private func badge(_ step: Step, done: Bool, open: Bool, skipped: Bool) -> some View {
        ZStack {
            Circle()
                .fill(done ? Color.green : open ? CartoucheTheme.indigo : Color.white.opacity(0.14))
            if done {
                Image(systemName: "checkmark")
                    .font(.headline.weight(.heavy))
            } else if skipped && !open {
                Image(systemName: "forward.fill")
                    .font(.subheadline.weight(.heavy))
            } else {
                Text(String(step.number))
                    .font(.headline.monospacedDigit().weight(.heavy))
            }
        }
        .foregroundStyle(Color.white)
        .frame(width: 34, height: 34)
        .accessibilityHidden(true)
    }

    /// What a done step says.
    @ViewBuilder
    private func doneLine(_ step: Step, _ progress: CartoucheGuide.Progress) -> some View {
        switch step {
        case .vpn:
            detail(progress.vpnConnected ? CartoucheText.guideVPNDone : CartoucheText.guideDone)
        case .account:
            detail(setup.appleID.map(CartoucheText.guideAccountDone) ?? CartoucheText.guideDone)
        case .build:
            detail(CartoucheText.guideBuildDone)
        case .folder:
            detail((storage.location(.games)?.server.name ?? storedGames.serverName)
                .map(CartoucheText.guideFolderDone) ?? CartoucheText.guideDone)
        case .play:
            if let installed = entries.owned.first(where: { $0.app != nil }), let app = installed.app {
                detail(CartoucheText.guidePlayDone(installed.name))
                action(CartoucheText.play, systemImage: "play.fill", primary: true) { onPlay(app) }
            } else {
                detail(CartoucheText.guideDone)
            }
        }
    }

    /// An open step: what to do, and the buttons that do it.
    @ViewBuilder
    private func content(_ step: Step, _ progress: CartoucheGuide.Progress) -> some View {
        switch step {
        case .vpn:
            detail(CartoucheText.guideVPNHow)
            if guide.hasLocalDevVPN {
                action(CartoucheText.guideVPNConnect, systemImage: "network.badge.shield.half.filled", primary: true) {
                    guide.connectVPN()
                }
            } else {
                action(CartoucheText.guideVPNGet, systemImage: "arrow.down.app", primary: true) {
                    openURL(CartoucheGuide.localDevVPNAppStore)
                }
            }
        case .account:
            accountContent(progress)
        case .build:
            detail(CartoucheText.guideBuildHow)
            // Side by side where they fit, the one over the other otherwise,
            // and before what the Mac needs: No thanks shows without the
            // player scrolling for it, on an iPhone too.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) { buildActions }
                VStack(alignment: .leading, spacing: 10) { buildActions }
            }
            note(CartoucheText.guideBuildSendNote)
            VStack(alignment: .leading, spacing: 8) {
                requirement(CartoucheText.guideBuildMac, systemImage: "laptopcomputer")
                requirement(CartoucheText.guideBuildXcode, systemImage: "hammer.fill")
                requirement(CartoucheText.guideBuildGame, systemImage: "gamecontroller.fill")
            }
        case .folder:
            detail(progress.buildSkipped ? CartoucheText.guideFolderHowNoMac : CartoucheText.guideFolderHow)
            action(CartoucheText.guideFolderChoose, systemImage: "folder.badge.plus", primary: true) {
                showingStorage = true
            }
            action(CartoucheText.guideFolderImport, systemImage: "square.and.arrow.down", primary: false) {
                choosingIPA = true
            }
        case .play:
            let stored = entries.owned.filter { $0.app == nil && $0.stored != nil }
            if stored.isEmpty {
                detail(progress.buildSkipped ? CartoucheText.guidePlayWaitingNoMac : CartoucheText.guidePlayWaiting)
                action(CartoucheText.importCopy, systemImage: "square.and.arrow.down", primary: true) {
                    choosingIPA = true
                }
            } else {
                detail(CartoucheText.guidePlayReady)
                ForEach(Array(stored.prefix(3).enumerated()), id: \.element.id) { index, entry in
                    if let game = entry.stored {
                        action(CartoucheText.guidePlayInstall(entry.name), systemImage: "arrow.down.circle.fill",
                               primary: index == 0) { onInstall(game) }
                    }
                }
            }
        }
    }

    /// The Mac's step's buttons: its page sent to the Mac, and No thanks,
    /// which skips the step, or closes it again once skipped.
    @ViewBuilder
    private var buildActions: some View {
        ShareLink(item: CartoucheGuide.builderPage, subject: Text(CartoucheText.guideBuildShareSubject),
                  message: Text(CartoucheText.guideBuildShareMessage)) {
            Label(CartoucheText.guideBuildSend, systemImage: "laptopcomputer.and.arrow.down")
                .font(.headline)
                .padding(.horizontal, 6)
                .frame(minHeight: 30)
        }
        .controlSize(.large)
        .cartouchePrimaryButton()
        action(CartoucheText.guideBuildSkip, systemImage: "forward.fill", primary: false) {
            withAnimation(.easeInOut(duration: 0.2)) {
                guide.skipBuild()
                opened = nil
            }
        }
    }

    @ViewBuilder
    private func accountContent(_ progress: CartoucheGuide.Progress) -> some View {
        if !progress.signedIn && !progress.hasPairingFile {
            // Only a computer makes the pairing file, and the installer puts it
            // in place: without it, SideStore cannot register this iPhone.
            detail(CartoucheText.guideAccountNoPairing)
            action(CartoucheText.guideOpenSetup, systemImage: "checklist", primary: true) {
                showingSetup = true
            }
        } else if !progress.signedIn {
            detail(CartoucheText.guideAccountHow)
            action(CartoucheText.setupSignIn, systemImage: "person.crop.circle.badge.checkmark", primary: true) {
                signingIn = true
            }
        } else if progress.deviceLeft {
            // Apple accepted the account: only this iPhone is left to
            // register, which Cartouche does by itself once LocalDevVPN is
            // connected.
            detail(account.phase == .registeringDevice ? CartoucheText.setupBannerDeviceWorking : CartoucheText.signInDeviceHow)
            action(CartoucheText.signInDeviceButton, systemImage: "iphone.gen3", primary: true) {
                signingIn = true
            }
        } else if setup.certificateRefused && !account.isAutomatic {
            // iOS refused the certificate and signing in again by itself
            // did not bring a new one.
            detail(CartoucheText.setupBannerCertificateDetail)
            action(CartoucheText.signInAgain, systemImage: "person.crop.circle.badge.checkmark", primary: true) {
                signingIn = true
            }
        } else {
            HStack(spacing: 10) {
                ProgressView()
                    .tint(Color.white)
                detail(CartoucheText.guideAccountCertificate)
            }
            action(CartoucheText.guideOpenSetup, systemImage: "checklist", primary: false) {
                showingSetup = true
            }
        }
    }

    // MARK: Pieces

    private func detail(_ text: String) -> some View {
        Text(text)
            .font(.subheadline)
            .foregroundStyle(CartoucheTheme.secondaryText)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .font(.footnote)
            .foregroundStyle(CartoucheTheme.tertiaryText)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func requirement(_ text: String, systemImage: String) -> some View {
        Label {
            Text(text)
                .foregroundStyle(Color.white)
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            // One width for every icon, so that the lines start together.
            Image(systemName: systemImage)
                .foregroundStyle(CartoucheTheme.pink)
                .frame(width: 24)
        }
        .font(.subheadline)
    }

    @ViewBuilder
    private func action(_ title: String, systemImage: String, primary: Bool,
                        perform: @escaping () -> Void) -> some View {
        let button = Button(action: perform) {
            Label(title, systemImage: systemImage)
                .font(.headline)
                .padding(.horizontal, 6)
                .frame(minHeight: 30)
        }
        .controlSize(.large)
        if primary {
            button.cartouchePrimaryButton()
        } else {
            button.cartoucheSecondaryButton()
        }
    }
}

/// The guide at the top of the home, in place of the setup banner, until
/// the player's first game is installed: the step left, and a tap to the
/// guide. Its × takes it off the home for good, for a player who needs no
/// guide; the System page opens the guide then.
@available(iOS 17.0, *)
struct CartoucheGuideCard: View {
    let progress: CartoucheGuide.Progress
    let action: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Button(action: action) {
                HStack(spacing: 14) {
                    Image(systemName: "flag.checkered")
                        .font(.title3.weight(.semibold))
                        .frame(width: 42, height: 42)
                        .background(Color.white.opacity(0.2), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(CartoucheText.guideTitle)
                            .font(.headline)
                        Text(detail)
                            .font(.subheadline)
                            .opacity(0.85)
                            .lineLimit(2)
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Button {
                withAnimation(.easeInOut(duration: 0.25)) { CartoucheGuide.shared.hideCard() }
            } label: {
                Image(systemName: "xmark")
                    .font(.subheadline.weight(.bold))
                    .frame(width: 30, height: 30)
                    .background(Color.white.opacity(0.2), in: Circle())
                    // As tall as the flag, so that the card keeps its height.
                    .frame(width: 42, height: 42)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(CartoucheText.guideHide)
        }
        .foregroundStyle(Color.white)
        .padding(14)
        .background(
            LinearGradient(colors: [CartoucheTheme.indigo, CartoucheTheme.pink.opacity(0.85)],
                           startPoint: .topLeading, endPoint: .bottomTrailing),
            in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    private var detail: String {
        guard let step = progress.current else { return CartoucheText.guideFinishedTitle }
        return CartoucheText.guideCardDetail(step.number, CartoucheGuide.Step.allCases.count,
                                             CartoucheGuideView.title(step))
    }
}
