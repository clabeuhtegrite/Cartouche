//
//  CartoucheResetView.swift
//  Cartouche
//
//  System › Reset Cartouche (CartoucheReset): what the reset erases and
//  what stays, the games whose saves it would lose, which can go to the
//  saves folder first, and the button that erases everything once the
//  player has said so twice: the button, then its confirmation. Erasing,
//  then restarting, covers the page.
//

import SwiftUI

@available(iOS 17.0, *)
struct CartoucheResetView: View {
    @ObservedObject private var reset = CartoucheReset.shared
    @ObservedObject private var backups = CartoucheSaveBackups.shared
    // What may hold the reset back (CartoucheReset.blocker).
    @ObservedObject private var actions = CartoucheGameActions.shared
    @ObservedObject private var account = CartoucheAccount.shared
    @ObservedObject private var updates = CartoucheUpdates.shared
    @ObservedObject private var setup = CartoucheSetup.shared
    @EnvironmentObject private var sharedModel: SharedModel
    @State private var confirming = false
    /// Whether the confirmation shows as the page opens, as the launcher's
    /// gallery shows it (launcher/Gallery).
    private let confirmsAtOnce: Bool

    init(confirming: Bool = false) {
        confirmsAtOnce = confirming
    }

    var body: some View {
        List {
            Section {
                Text(CartoucheText.resetIntro)
            }
            Section(CartoucheText.resetGoesHeader) {
                item(CartoucheText.resetGoesGames, "gamecontroller.fill", erased: true)
                item(CartoucheText.resetGoesStorage, "externaldrive.fill", erased: true)
                if !CartoucheImportedSigning.accountSigningDisabled {
                    item(CartoucheText.resetGoesAccount, "person.crop.circle.fill", erased: true)
                }
                item(CartoucheText.resetGoesSettings, "slider.horizontal.3", erased: true)
            }
            Section(CartoucheText.resetStaysHeader) {
                item(CartoucheText.resetStaysSigning, "checkmark.seal.fill", erased: false)
                item(CartoucheText.resetStaysStorage, "folder.fill", erased: false)
                item(CartoucheText.resetStaysTelemetry, "chart.bar.xaxis", erased: false)
                item(CartoucheText.resetStaysSystem, "lock.shield.fill", erased: false)
            }
            savesSection
            eraseSection
        }
        .cartoucheStageBackground()
        .navigationTitle(CartoucheText.resetTitle)
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(reset.phase != nil)
        .task {
            await reset.checkSaves(of: sharedModel.apps)
            if confirmsAtOnce { confirming = true }
        }
        .confirmationDialog(CartoucheText.resetConfirmTitle, isPresented: $confirming, titleVisibility: .visible) {
            Button(CartoucheText.resetConfirmErase, role: .destructive) {
                reset.reset()
            }
            Button(CartoucheText.cancel, role: .cancel) {}
        } message: {
            // The Apple ID, only when there is one to erase.
            Text(setup.appleID == nil ? CartoucheText.resetConfirmMessage : CartoucheText.resetConfirmMessageAccount)
        }
        .overlay {
            if let phase = reset.phase {
                progress(phase)
            }
        }
    }

    /// What the reset erases, or what stays.
    private func item(_ text: String, _ symbol: String, erased: Bool) -> some View {
        Label {
            Text(text)
        } icon: {
            Image(systemName: symbol)
                .foregroundStyle(erased ? CartoucheTheme.danger : Color.green)
        }
    }

    // MARK: The saves

    private var savesSection: some View {
        Section(CartoucheText.resetSavesHeader) {
            if let atRisk = reset.savesAtRisk {
                if atRisk.isEmpty {
                    Label(backups.isOn ? CartoucheText.resetSavesSafe : CartoucheText.resetSavesNone,
                          systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.secondary)
                } else {
                    Label(CartoucheText.resetSavesAtRisk(ListFormatter.localizedString(byJoining: atRisk)),
                          systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    if !backups.isOn {
                        Text(CartoucheText.resetSavesNoFolder)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    } else if reset.isSendingSaves {
                        HStack(spacing: 10) {
                            ProgressView()
                            Text(CartoucheText.resetSavesSending)
                                .foregroundStyle(.secondary)
                        }
                    } else {
                        Button(CartoucheText.resetSavesSend, systemImage: "arrow.up.doc") {
                            Task { await reset.sendSavesAtRisk(of: sharedModel.apps) }
                        }
                        .disabled(reset.phase != nil)
                        if let problem = backups.problemReport {
                            Label(problem.message, systemImage: "exclamationmark.triangle.fill")
                                .font(.footnote)
                                .foregroundStyle(.red)
                            CartoucheReportButton(report: problem)
                                .font(.footnote)
                        }
                    }
                }
            } else {
                HStack(spacing: 10) {
                    ProgressView()
                    Text(CartoucheText.resetSavesChecking)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: Erasing

    private var eraseSection: some View {
        Section {
            Button(role: .destructive) {
                confirming = true
            } label: {
                Label(CartoucheText.resetErase, systemImage: "arrow.counterclockwise")
                    .foregroundStyle(CartoucheTheme.danger)
            }
            .disabled(reset.phase != nil || reset.blocker != nil)
            if let report = reset.report, reset.phase == nil {
                Label(report.message, systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote)
                    .foregroundStyle(.red)
                CartoucheReportButton(report: report)
                    .font(.footnote)
                Button(CartoucheText.resetRestart, systemImage: "arrow.clockwise") {
                    reset.restartNow()
                }
            }
        } footer: {
            if reset.phase == nil, let blocker = reset.blocker {
                Text(blocker)
            }
        }
    }

    /// Over the page while Cartouche erases, then starts again.
    private func progress(_ phase: CartoucheReset.Phase) -> some View {
        ZStack {
            Color.black.opacity(0.55)
                .ignoresSafeArea()
            VStack(spacing: 14) {
                ProgressView()
                    .controlSize(.large)
                Text(phase == .erasing ? CartoucheText.resetErasing : CartoucheText.resetRestarting)
                    .font(.headline)
            }
            .padding(.horizontal, 32)
            .padding(.vertical, 24)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        }
        // Nothing under it answers meanwhile.
        .contentShape(Rectangle())
    }
}
