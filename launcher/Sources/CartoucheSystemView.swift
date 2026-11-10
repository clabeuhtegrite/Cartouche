//
//  CartoucheSystemView.swift
//  Cartouche
//
//  What Cartouche has on this iPhone: the player's storage, where their
//  games and saves are kept; the memory limit iOS sets for it, which its
//  games share; when its signature expires, and how it is renewed; the
//  device that the game sheets are compared with; and Cartouche's
//  updates. It opens over the console (CartoucheRootView), and OK or the
//  controller's Menu button closes it.
//

import SwiftUI
import UserNotifications

@available(iOS 17.0, *)
struct CartoucheSystemView: View {
    @State private var memory = CartoucheMemoryReading.now()
    @State private var signature = CartoucheSignature.current()
    @State private var renewal: Progress?
    @State private var renewalError: String?
    @State private var alertStatus: UNAuthorizationStatus?
    @ObservedObject private var setup = CartoucheSetup.shared
    @ObservedObject private var storage = CartoucheStorageSettings.shared
    @ObservedObject private var updates = CartoucheUpdates.shared
    @EnvironmentObject private var sharedModel: SharedModel

    private let catalog = CartoucheCatalog.shared

    var body: some View {
        NavigationStack {
            List {
                setupSection
                storageSection
                memorySection
                signatureSection
                automaticRenewalSection
                deviceSection
                updateSection
                cartoucheSection
            }
            .cartoucheStageBackground()
            .navigationTitle(CartoucheText.systemTab)
            .refreshable { measure() }
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(CartoucheText.done, action: close)
                }
            }
        }
        // Dark like the console under it, whatever the iPhone's appearance.
        .preferredColorScheme(.dark)
        .onAppear(perform: measure)
        .onReceive(CartoucheGamepad.shared.inputs) { input in
            if input == .menu { close() }
        }
    }

    /// Back to the console.
    private func close() {
        sharedModel.selectedTab = .games
    }

    private func measure() {
        setup.refresh()
        memory = CartoucheMemoryReading.now()
        signature = CartoucheSignature.current()
        CartoucheRenewal.scheduleWarnings()
        Task { alertStatus = await CartoucheRenewal.alertStatus() }
    }

    // MARK: Setup

    private var setupSection: some View {
        Section {
            NavigationLink {
                CartoucheSetupView()
            } label: {
                LabeledContent {
                    Label(setup.isComplete ? CartoucheText.setupStatusDone : CartoucheText.setupStatusToDo,
                          systemImage: setup.isComplete ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                        .foregroundStyle(setup.isComplete ? Color.green : Color.orange)
                } label: {
                    Label(CartoucheText.setupTitle, systemImage: "checklist")
                }
            }
        }
    }

    // MARK: Storage

    private var storageSection: some View {
        Section {
            NavigationLink {
                CartoucheStorageView()
            } label: {
                LabeledContent {
                    Text(storage.location(.games)?.server.name ?? CartoucheText.storageNotSet)
                        .lineLimit(1)
                } label: {
                    Label(CartoucheText.storageTitle, systemImage: "externaldrive.fill")
                }
            }
        }
    }

    // MARK: Memory

    private var memorySection: some View {
        Section {
            if let memory {
                VStack(alignment: .leading, spacing: 10) {
                    LabeledContent(CartoucheText.memoryLimit, value: CartoucheText.memoryAmount(mebibytes: memory.limitMiB))
                        .font(.headline)
                    Gauge(value: Double(memory.footprintBytes), in: 0...Double(max(memory.limitBytes, 1))) {
                        Text(CartoucheText.memoryUsed)
                    }
                    .gaugeStyle(.linearCapacity)
                    .labelsHidden()
                }
                .padding(.vertical, 4)
                LabeledContent(CartoucheText.memoryUsed, value: CartoucheText.memoryAmount(mebibytes: memory.footprintMiB))
                LabeledContent(CartoucheText.memoryAvailable, value: CartoucheText.memoryAmount(mebibytes: memory.availableMiB))
            } else {
                Text(CartoucheText.memoryUnavailable)
                    .foregroundStyle(.secondary)
            }
            LabeledContent(CartoucheText.imlRequirement) {
                let active = CartoucheDevice.hasIncreasedMemoryLimit
                Label(active ? CartoucheText.imlOn : CartoucheText.imlOff,
                      systemImage: active ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(active ? Color.green : Color.orange)
            }
            Button(CartoucheText.measureAgain, systemImage: "arrow.clockwise", action: measure)
        } header: {
            Text(CartoucheText.memory)
        } footer: {
            Text(memoryFooter)
        }
    }

    private var memoryFooter: String {
        var text = CartoucheText.memoryFooter
        if let known = knownLimitMiB {
            text += " " + CartoucheText.memoryKnown(CartoucheText.memoryAmount(mebibytes: known))
        }
        return text
    }

    /// The latest limit testers measured on this model with the capability.
    private var knownLimitMiB: Int? {
        catalog.device(CartoucheDevice.modelIdentifier)?.measurements
            .filter(\.increasedMemoryLimit)
            .max { $0.date < $1.date }?
            .appMemoryLimitMiB
    }

    // MARK: Signature

    private var signatureSection: some View {
        Section {
            if let expirationDate = signature.expirationDate, let daysLeft = signature.daysLeft {
                LabeledContent(CartoucheText.expires, value: expirationDate.formatted(date: .abbreviated, time: .shortened))
                LabeledContent(CartoucheText.daysLeft) {
                    Text(daysLeft < 0 ? CartoucheText.expired : String(daysLeft))
                        .foregroundStyle(daysLeft < 0 ? Color.red : daysLeft <= 2 ? Color.orange : Color.secondary)
                        .fontWeight(daysLeft <= 2 ? .semibold : .regular)
                }
            } else {
                Text(CartoucheText.profileUnknown)
                    .foregroundStyle(.secondary)
            }
            if let renewalDate = signature.renewalDate {
                LabeledContent(CartoucheText.renewed, value: renewalDate.formatted(date: .abbreviated, time: .shortened))
            }
            if let teamName = signature.teamName {
                LabeledContent(CartoucheText.team, value: teamName)
            }
            if CartoucheRenewal.canRenew {
                renewRow
            }
        } header: {
            Text(CartoucheText.signature)
        } footer: {
            Text(CartoucheText.signatureFooter)
        }
    }

    @ViewBuilder
    private var renewRow: some View {
        if let renewal {
            VStack(alignment: .leading, spacing: 8) {
                Label(CartoucheText.renewing, systemImage: "arrow.triangle.2.circlepath")
                    .foregroundStyle(.secondary)
                // SideStore reports its progress from another thread: read it
                // twice a second instead of observing it.
                TimelineView(.periodic(from: .now, by: 0.5)) { _ in
                    ProgressView(value: renewal.fractionCompleted)
                }
            }
            .padding(.vertical, 4)
        } else {
            Button(CartoucheText.renewNow, systemImage: "arrow.triangle.2.circlepath", action: renew)
        }
        if let renewalError {
            Label(renewalError, systemImage: "exclamationmark.triangle.fill")
                .font(.footnote)
                .foregroundStyle(.red)
        }
    }

    private func renew() {
        let progress = Progress(totalUnitCount: 100)
        renewal = progress
        renewalError = nil
        Task {
            do {
                try await CartoucheRenewal.renew(progress: progress)
            } catch {
                renewalError = error.localizedDescription
            }
            renewal = nil
            measure()
        }
    }

    // MARK: Automatic renewal

    private var automaticRenewalSection: some View {
        Section {
            NavigationLink {
                CartoucheNightlyRenewalView()
            } label: {
                Label(CartoucheText.renewEveryNight, systemImage: "moon.zzz")
            }
            LabeledContent(CartoucheText.alerts) {
                alertControl
            }
        } header: {
            Text(CartoucheText.automaticRenewal)
        } footer: {
            Text(CartoucheText.automaticRenewalFooter)
        }
    }

    @ViewBuilder
    private var alertControl: some View {
        switch alertStatus {
        case .authorized?, .provisional?, .ephemeral?:
            Label(CartoucheText.alertsOn, systemImage: "checkmark.circle.fill")
                .foregroundStyle(Color.green)
        case .notDetermined?:
            Button(CartoucheText.alertsTurnOn) {
                Task {
                    await CartoucheRenewal.allowAlerts()
                    alertStatus = await CartoucheRenewal.alertStatus()
                }
            }
        case .denied?:
            if let url = CartoucheRenewal.notificationSettingsURL {
                Link(CartoucheText.alertsInSettings, destination: url)
            }
        default:
            EmptyView()
        }
    }

    // MARK: This iPhone

    private var deviceSection: some View {
        let device = catalog.device(CartoucheDevice.modelIdentifier)
        return Section(CartoucheText.thisIPhone) {
            LabeledContent(CartoucheText.model, value: CartoucheDevice.modelIdentifier)
            if let device {
                LabeledContent(CartoucheText.chip, value: device.chip)
                LabeledContent(CartoucheText.ram, value: CartoucheText.gigabytes(device.memoryGB))
            } else {
                LabeledContent(CartoucheText.ram, value: CartoucheText.memoryAmount(
                    mebibytes: Int(ProcessInfo.processInfo.physicalMemory / 1_048_576)))
            }
            LabeledContent("iOS", value: CartoucheDevice.iOSVersion)
            LabeledContent(CartoucheText.bcRequirement,
                           value: CartoucheDevice.supportsBCTextureCompression ? CartoucheText.gpuSupported : CartoucheText.gpuUnsupported)
        }
    }

    // MARK: Updates

    @ViewBuilder
    private var updateSection: some View {
        if updates.canUpdate {
            Section {
                updateRows
            } header: {
                Text(CartoucheText.updatesTitle)
            } footer: {
                Text(CartoucheText.updatesFooter)
            }
        }
    }

    @ViewBuilder
    private var updateRows: some View {
        if let phase = updates.phase {
            let version = updates.target?.version ?? ""
            VStack(alignment: .leading, spacing: 8) {
                Label(phase == .installing ? CartoucheText.updateInstallingTitle(version) : CartoucheText.updatePreparingTitle(version),
                      systemImage: "arrow.down.circle")
                    .foregroundStyle(.secondary)
                if phase == .preparing, let progress = updates.progress {
                    // SideStore reports its progress from another thread:
                    // read it twice a second instead of observing it.
                    TimelineView(.periodic(from: .now, by: 0.5)) { _ in
                        ProgressView(value: progress.fractionCompleted)
                    }
                } else {
                    Text(CartoucheText.updateInstallingMessage)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 4)
        } else if let available = updates.available {
            LabeledContent(CartoucheText.updateAvailable, value: available.version)
            Button(CartoucheText.updateTo(available.version), systemImage: "arrow.down.circle") {
                updates.start()
            }
            .disabled(!updates.canStart)
            if !setup.isComplete {
                Text(CartoucheText.updateNeedsSetup)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            if !available.notes.isEmpty {
                DisclosureGroup(CartoucheText.updateNotes) {
                    Text(available.notes)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        } else {
            if updates.isChecking {
                ProgressView()
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Text(updates.checked == nil ? CartoucheText.updateNotChecked : CartoucheText.updateUpToDate(CartoucheUpdates.runningVersion))
                    .foregroundStyle(.secondary)
            }
            Button(CartoucheText.updateCheck, systemImage: "arrow.clockwise") {
                updates.checkNow()
            }
            .disabled(updates.isChecking)
        }
        if updates.phase == nil, let problem = updates.problem ?? updates.checkProblem {
            Label(problem, systemImage: "exclamationmark.triangle.fill")
                .font(.footnote)
                .foregroundStyle(.red)
        }
    }

    // MARK: Cartouche

    private var cartoucheSection: some View {
        Section {
            LabeledContent(CartoucheText.version, value: version)
            if let basedOn {
                LabeledContent(CartoucheText.basedOn, value: basedOn)
            }
            LabeledContent(CartoucheText.sheets, value: String(catalog.sheets.count))
        } header: {
            Text(verbatim: "Cartouche")
        } footer: {
            Text(CartoucheText.coversCredit)
        }
    }

    /// Cartouche's version and the commit it was built from (app/scripts/package.sh).
    private var version: String {
        let info = Bundle.main.infoDictionary
        var text = info?["CFBundleShortVersionString"] as? String ?? "?"
        if let build = info?["LCVersionInfo"] as? String, !build.isEmpty {
            text += " (" + build + ")"
        }
        return text
    }

    /// The versions of LiveContainer and SideStore that this build carries.
    private var basedOn: String? {
        let info = Bundle.main.infoDictionary ?? [:]
        let bases: [(name: String, key: String)] = [
            ("LiveContainer", "CartoucheLiveContainerVersion"),
            ("SideStore", "CartoucheSideStoreVersion"),
        ]
        let parts = bases.compactMap { base -> String? in
            guard let version = info[base.key] as? String else { return nil }
            return "\(base.name)\u{00A0}\(version)"
        }
        return parts.isEmpty ? nil : parts.joined(separator: ", ")
    }
}

/// How to have Shortcuts renew Cartouche every night.
@available(iOS 17.0, *)
struct CartoucheNightlyRenewalView: View {
    private var steps: [String] {
        [
            CartoucheText.dailyStepVPN,
            CartoucheText.dailyStepAutomation,
            CartoucheText.dailyStepTime,
            CartoucheText.dailyStepAction,
            CartoucheText.dailyStepCheck,
        ]
    }

    var body: some View {
        List {
            Section {
                Text(CartoucheText.dailyIntro)
            }
            Section {
                ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        Text(String(index + 1))
                            .font(.subheadline.monospacedDigit().weight(.bold))
                            .foregroundStyle(.white)
                            .frame(width: 26, height: 26)
                            .background(Color.accentColor, in: Circle())
                            .accessibilityHidden(true)
                        Text(step)
                    }
                    .padding(.vertical, 2)
                }
            }
            Section {
                Link(destination: CartoucheRenewal.shortcutsURL) {
                    Label(CartoucheText.openShortcuts, systemImage: "square.2.layers.3d")
                }
            }
        }
        .cartoucheStageBackground()
        .navigationTitle(CartoucheText.renewEveryNight)
        .navigationBarTitleDisplayMode(.inline)
    }
}
