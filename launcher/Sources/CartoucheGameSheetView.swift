//
//  CartoucheGameSheetView.swift
//  Cartouche
//
//  A game's sheet: what it needs against what this iPhone has, the settings
//  testers recommend, and their results. Its one action is Play for the
//  player's own copy, or Import my copy.
//

import SwiftUI

@available(iOS 17.0, *)
struct CartoucheGameSheetView: View {
    let entry: CartoucheEntry
    let memory: CartoucheMemoryReading?
    let onPlay: (LCAppModel) -> Void
    /// Opens Files. The view that presents the sheet holds the one file
    /// importer of its presentation: SwiftUI presents only one of several.
    let onImport: () -> Void

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
            } else {
                Section {
                    Text(CartoucheText.noSheetMessage)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle(entry.name)
        .navigationBarTitleDisplayMode(.inline)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 14) {
            ZStack(alignment: .bottomLeading) {
                CartoucheTileArt(name: entry.app == nil ? entry.name : "", platform: entry.app == nil ? entry.sheet?.platform : nil, key: entry.tileKey)
                if let app = entry.app {
                    HStack(spacing: 14) {
                        CartoucheAppIcon(app: app, size: 84)
                        VStack(alignment: .leading, spacing: 4) {
                            if let platform = entry.sheet?.platform {
                                Text(CartoucheText.platform(platform).uppercased())
                                    .font(.caption2.weight(.heavy))
                                    .tracking(1.2)
                                    .foregroundStyle(Color.white.opacity(0.8))
                            }
                            Text(entry.name)
                                .font(.system(.title2, design: .rounded, weight: .bold))
                                .foregroundStyle(Color.white)
                                .lineLimit(2)
                                .minimumScaleFactor(0.7)
                        }
                    }
                    .padding(16)
                }
            }
            .frame(height: 170)
            .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))

            HStack {
                CartoucheFitBadge(fit: fit, owned: entry.app != nil)
                Spacer()
            }

            if let app = entry.app {
                Button {
                    onPlay(app)
                } label: {
                    Label(CartoucheText.play, systemImage: "play.fill")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            } else {
                Button(action: onImport) {
                    Label(CartoucheText.importCopy, systemImage: "square.and.arrow.down")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }
        }
        .padding(.vertical, 8)
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
