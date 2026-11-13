//
//  CartoucheUpdateView.swift
//  Cartouche
//
//  Cartouche's own update over the console (CartoucheUpdates): the new
//  version on offer, how far the built-in SideStore has gone with it, then
//  what came of it, with the report on a failure to copy. Signed with the
//  player's own certificate, the new version on offer alone: its IPA to
//  download, signed on the iPhone, or the Cartouche Installer to install it
//  with. A controller answers with A and B, and copies the report with Y.
//

import SwiftUI

@available(iOS 17.0, *)
struct CartoucheUpdateView: View {
    @ObservedObject var updates: CartoucheUpdates
    @ObservedObject private var gamepad = CartoucheGamepad.shared
    /// The report was just copied: its button says so for a moment.
    @State private var copied = false

    /// A button of the card, and the controller's button for it.
    private struct Choice {
        let title: String
        let input: CartoucheGamepad.Input
        let action: () -> Void
    }

    private var version: String {
        updates.target?.version ?? updates.available?.version ?? ""
    }

    private var title: String {
        if let notice = updates.notice, updates.phase == nil { return notice.title }
        switch updates.phase {
        case .preparing: return CartoucheText.updatePreparingTitle(version)
        case .installing: return CartoucheText.updateInstallingTitle(version)
        case nil: return CartoucheText.updateOfferTitle(version)
        }
    }

    private var message: String {
        if let notice = updates.notice, updates.phase == nil { return notice.message }
        switch updates.phase {
        case .preparing: return CartoucheText.updatePreparingMessage
        case .installing: return CartoucheText.updateInstallingMessage
        case nil:
            let running = CartoucheUpdates.runningVersion
            var text = CartoucheImportedSigning.isSignedOnIPhone ? CartoucheText.updateOfferOnIPhone(running)
                : CartoucheImportedSigning.isImportedInstall ? CartoucheText.updateOfferOnComputer(running)
                : CartoucheText.updateOfferMessage(running)
            // The size of the IPA SideStore downloads, not of the one for
            // the player's own certificate.
            if !CartoucheImportedSigning.isImportedInstall, let size = updates.available?.size, size > 0 {
                text += "\n" + CartoucheText.updateSize(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))
            }
            return text
        }
    }

    private var symbol: String {
        if let notice = updates.notice, updates.phase == nil {
            return notice.report == nil ? "checkmark.seal.fill" : "exclamationmark.triangle.fill"
        }
        return updates.phase == .installing ? "arrow.down.app.fill" : "arrow.down.circle.fill"
    }

    private var choices: [Choice] {
        if let notice = updates.notice, updates.phase == nil {
            var choices = [Choice(title: CartoucheText.done, input: .a) { updates.dismissNotice() }]
            if let report = notice.report {
                choices.append(Choice(title: copied ? CartoucheText.reportCopied : CartoucheText.reportCopy, input: .y) {
                    CartoucheReports.copy(report)
                    copied = true
                })
            }
            return choices
        }
        switch updates.phase {
        case .preparing:
            return []
        case .installing:
            return [Choice(title: CartoucheText.updateLeaveNow, input: .a) { updates.leaveToHomeScreen() }]
        case nil:
            if CartoucheImportedSigning.isImportedInstall {
                // Nothing to install here: the IPA to download, signed on
                // the iPhone; the computer's Installer otherwise.
                guard updates.download != nil else {
                    return [Choice(title: CartoucheText.done, input: .a) { updates.later() }]
                }
                return [
                    Choice(title: CartoucheText.updateDownload, input: .a) { updates.openDownload() },
                    Choice(title: CartoucheText.updateLater, input: .b) { updates.later() },
                ]
            }
            return [
                Choice(title: CartoucheText.updateNow, input: .a) { updates.start() },
                Choice(title: CartoucheText.updateLater, input: .b) { updates.later() },
            ]
        }
    }

    var body: some View {
        ZStack {
            Color.black.opacity(0.6)
                .ignoresSafeArea()
            VStack(spacing: 18) {
                Image(systemName: symbol)
                    .font(.system(size: 30, weight: .semibold))
                    .foregroundStyle(Color.white)
                    .frame(width: 72, height: 72)
                    .background(
                        LinearGradient(colors: [CartoucheTheme.indigo, CartoucheTheme.pink],
                                       startPoint: .topLeading, endPoint: .bottomTrailing),
                        in: Circle())
                    .symbolEffect(.pulse, options: .repeating, isActive: updates.phase != nil)
                VStack(spacing: 6) {
                    Text(title)
                        .font(.system(.title3, design: .rounded, weight: .heavy))
                        .foregroundStyle(Color.white)
                        .multilineTextAlignment(.center)
                        .lineLimit(3)
                        .minimumScaleFactor(0.8)
                    Text(message)
                        .font(.subheadline)
                        .foregroundStyle(CartoucheTheme.secondaryText)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if updates.phase == .preparing, let progress = updates.progress {
                    // SideStore reports its progress from another thread:
                    // read it twice a second instead of observing it.
                    TimelineView(.periodic(from: .now, by: 0.5)) { _ in
                        progressBar(min(max(progress.fractionCompleted, 0), 1))
                    }
                } else if updates.phase == .installing {
                    ProgressView()
                        .tint(Color.white)
                }
                buttons
            }
            .padding(28)
            .frame(maxWidth: 380)
            .cartoucheGlass(in: RoundedRectangle(cornerRadius: 30, style: .continuous))
            .padding(24)
        }
        .accessibilityElement(children: .contain)
        .onReceive(CartoucheGamepad.shared.inputs) { input in
            choices.first { $0.input == input }?.action()
        }
        .sensoryFeedback(.success, trigger: copied) { _, now in now }
        .task(id: copied) {
            guard copied else { return }
            try? await Task.sleep(for: .seconds(2))
            copied = false
        }
    }

    private func progressBar(_ fraction: Double) -> some View {
        VStack(spacing: 6) {
            ProgressView(value: fraction)
                .tint(Color.white)
            Text(fraction.formatted(.percent.precision(.fractionLength(0))))
                .font(.footnote.weight(.semibold).monospacedDigit())
                .foregroundStyle(CartoucheTheme.secondaryText)
        }
    }

    @ViewBuilder
    private var buttons: some View {
        let choices = choices
        if !choices.isEmpty {
            VStack(spacing: 10) {
                ForEach(Array(choices.enumerated()), id: \.offset) { index, choice in
                    if index == 0 {
                        Button(action: choice.action) {
                            label(choice, font: .headline)
                        }
                        .controlSize(.large)
                        .cartouchePrimaryButton()
                    } else {
                        Button(action: choice.action) {
                            label(choice, font: .subheadline.weight(.semibold))
                        }
                        .controlSize(.regular)
                        .cartoucheSecondaryButton()
                    }
                }
            }
        }
    }

    private func label(_ choice: Choice, font: Font) -> some View {
        HStack(spacing: 8) {
            if gamepad.isConnected {
                Image(systemName: gamepad.symbol(for: choice.input))
            }
            Text(choice.title)
        }
        .font(font)
        .frame(maxWidth: .infinity, minHeight: 30)
    }
}
