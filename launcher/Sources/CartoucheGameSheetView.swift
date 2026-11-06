//
//  CartoucheGameSheetView.swift
//  Cartouche
//
//  A game's sheet: where nxnative plays it and what its profile says, what
//  the game needs against what this iPhone has, the settings testers
//  recommend, and their results. Its main action is Play for the player's
//  own copy, with Game settings (the game's settings page) and Uninstall
//  under it, or Import my copy.
//

import SwiftUI

@available(iOS 17.0, *)
struct CartoucheGameSheetView: View {
    let entry: CartoucheEntry
    let memory: CartoucheMemoryReading?
    let onPlay: (LCAppModel) -> Void
    /// Opens the game's settings page.
    let onSettings: (LCAppModel) -> Void
    /// Opens Files. The view that presents the sheet holds the one file
    /// importer of its presentation: SwiftUI presents only one of several.
    let onImport: () -> Void
    /// Asks whether to uninstall the game, and whether its saves stay.
    let onUninstall: (LCAppModel) -> Void

    private var fit: CartoucheFit? {
        entry.sheet.map { CartoucheFit.of($0, memory: memory) }
    }

    var body: some View {
        List {
            Section {
                header
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
            }

            if let sheet = entry.sheet {
                if let fit, !fit.reasons.isEmpty {
                    Section {
                        ForEach(fit.reasons, id: \.self) { reason in
                            Label(reason, systemImage: "exclamationmark.triangle.fill")
                                .foregroundStyle(fit.isPlayable ? Color.primary : Color.orange)
                        }
                    }
                }
                requirements(sheet)
                if let recommended = sheet.recommended, recommended.resolution != nil || recommended.mode != nil {
                    Section(CartoucheText.recommendedSettings) {
                        if let resolution = recommended.resolution {
                            LabeledContent(CartoucheText.resolution, value: resolution)
                        }
                        if let mode = recommended.mode {
                            LabeledContent(CartoucheText.mode, value: CartoucheText.modeName(mode))
                        }
                    }
                }
                results(sheet)
            } else if entry.isOwned {
                Section {
                    Text(CartoucheText.noSheetMessage)
                        .foregroundStyle(.secondary)
                }
            }

            if let game = entry.game {
                nxnative(game)
            }
        }
        .scrollContentBackground(.hidden)
        .background(CartoucheStage(key: entry.tileKey))
        .navigationTitle(entry.name)
        .navigationBarTitleDisplayMode(.inline)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .center, spacing: 18) {
                CartoucheGameCartridge(entry: entry, width: 104)
                    .padding(.vertical, 8)
                VStack(alignment: .leading, spacing: 8) {
                    Text(entry.name)
                        .font(.system(.title2, design: .rounded, weight: .heavy))
                        .foregroundStyle(Color.white)
                        .lineLimit(3)
                        .minimumScaleFactor(0.7)
                    CartoucheMetaLine(entry: entry)
                    if entry.sheet != nil {
                        CartoucheFitBadge(fit: fit, owned: entry.app != nil)
                    }
                }
            }

            if let app = entry.app {
                Button {
                    onPlay(app)
                } label: {
                    Label(CartoucheText.play, systemImage: "play.fill")
                        .font(.headline)
                        .frame(maxWidth: .infinity, minHeight: 30)
                }
                .controlSize(.large)
                .cartouchePrimaryButton()
                HStack(spacing: 10) {
                    Button {
                        onSettings(app)
                    } label: {
                        Label(CartoucheText.gameSettings, systemImage: "slider.horizontal.3")
                            .font(.subheadline.weight(.semibold))
                            .frame(maxWidth: .infinity, minHeight: 26)
                    }
                    .cartoucheSecondaryButton()
                    Button(role: .destructive) {
                        onUninstall(app)
                    } label: {
                        Label(CartoucheText.uninstall, systemImage: "trash")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(CartoucheTheme.danger)
                            .frame(maxWidth: .infinity, minHeight: 26)
                    }
                    .cartoucheSecondaryButton()
                }
                .controlSize(.regular)
            } else {
                Button(action: onImport) {
                    Label(CartoucheText.importCopy, systemImage: "square.and.arrow.down")
                        .font(.headline)
                        .frame(maxWidth: .infinity, minHeight: 30)
                }
                .controlSize(.large)
                .cartouchePrimaryButton()
            }
        }
        .padding(.vertical, 8)
    }

    /// What nxnative's profile says about the game.
    private func nxnative(_ game: CartoucheNxGame) -> some View {
        let status = CartouchePlayStatus.of(entry)
        return Section(CartoucheText.sheetNxnative) {
            Label {
                Text(status.long)
            } icon: {
                Image(systemName: status == .ready ? CartouchePlayStatus.iphone.symbol : status.symbol)
                    .foregroundStyle(status.color)
            }
            LabeledContent(CartoucheText.sheetEngine, value: game.engine)
            LabeledContent(CartoucheText.sheetBuild, value: game.build)
            LabeledContent(CartoucheText.sheetSDK, value: game.sdk)
            LabeledContent(CartoucheText.sheetTitleID) {
                Text(verbatim: game.titleId)
                    .font(.body.monospaced())
                    .textSelection(.enabled)
            }
            ForEach(game.variants ?? [], id: \.self) { variant in
                LabeledContent(CartoucheText.region(variant.region)) {
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(verbatim: variant.titleId)
                            .font(.body.monospaced())
                            .textSelection(.enabled)
                        Text(variant.build)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private func requirements(_ sheet: CartoucheGameSheet) -> some View {
        Section(CartoucheText.onThisIPhone) {
            row(ok: CartoucheDevice.runsAtLeast(sheet.requirements.minimumIOS),
                title: CartoucheText.iosRequirement(sheet.requirements.minimumIOS),
                detail: CartoucheText.iosCurrent(CartoucheDevice.iOSVersion))
            if sheet.requirements.bcTextureCompression {
                row(ok: CartoucheDevice.supportsBCTextureCompression,
                    title: CartoucheText.bcRequirement,
                    detail: CartoucheDevice.supportsBCTextureCompression ? CartoucheText.gpuSupported : CartoucheText.gpuUnsupported)
            }
            if sheet.requirements.increasedMemoryLimit {
                let limit = memory.map { CartoucheText.memoryAmount(mebibytes: $0.limitMiB) } ?? "–"
                row(ok: CartoucheDevice.hasIncreasedMemoryLimit,
                    title: CartoucheText.imlRequirement,
                    detail: CartoucheDevice.hasIncreasedMemoryLimit ? CartoucheText.imlActive(limit) : CartoucheText.imlInactive(limit))
            }
            if let peak = sheet.peakMemoryMiB {
                let fits = memory.map { peak <= $0.limitMiB } ?? true
                row(ok: fits,
                    title: CartoucheText.memoryRequirement,
                    detail: CartoucheText.memoryNeeded(CartoucheText.memoryAmount(mebibytes: peak)))
            }
        }
    }

    private func row(ok: Bool, title: String, detail: String) -> some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(detail)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        } icon: {
            Image(systemName: ok ? "checkmark.circle.fill" : "xmark.circle.fill")
                .foregroundStyle(ok ? Color.green : Color.red)
        }
    }

    private func results(_ sheet: CartoucheGameSheet) -> some View {
        Section(CartoucheText.results) {
            if sheet.results.isEmpty {
                Text(CartoucheText.noResults)
                    .foregroundStyle(.secondary)
            }
            ForEach(sheet.results.sorted { $0.date > $1.date }, id: \.self) { result in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(CartoucheText.resultStatus(result.status))
                            .font(.headline)
                        Spacer()
                        Text(result.date)
                            .font(.footnote.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    Text(deviceName(result.device) + " · iOS " + result.iOS)
                        .font(.subheadline)
                    if let peak = result.peakMemoryMiB {
                        Text(CartoucheText.peak(CartoucheText.memoryAmount(mebibytes: peak)))
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    Text(result.engine)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    ForEach(result.notes ?? [], id: \.self) { note in
                        Text(note)
                            .font(.footnote)
                    }
                }
                .padding(.vertical, 2)
            }
        }
    }

    private func deviceName(_ identifier: String) -> String {
        var name = identifier
        if let device = CartoucheCatalog.shared.device(identifier) {
            name += " (" + device.chip + ", " + CartoucheText.gigabytes(device.memoryGB) + ")"
        }
        if identifier == CartoucheDevice.modelIdentifier {
            name = CartoucheText.thisModel + " · " + name
        }
        return name
    }
}
