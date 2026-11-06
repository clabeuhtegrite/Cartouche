//
//  CartoucheLabView.swift
//  Cartouche
//
//  The lab: nxnative's rewriter on the modules of the player's own game, on
//  this iPhone, compared with the files their Mac's build wrote (spike S2,
//  CartoucheLab.swift).
//

import SwiftUI
import UniformTypeIdentifiers

@available(iOS 17.0, *)
struct CartoucheLabView: View {
    @ObservedObject private var lab = CartoucheLab.shared
    @State private var choosingFolder = false

    var body: some View {
        List {
            Section {
                Text(CartoucheText.labIntro)
            }
            folderSection
            runSection
            if let status = lab.status {
                resultSection(status)
                if let files = status.files, !files.isEmpty {
                    filesSection(files, onlyOnMac: status.onlyOnMac ?? [])
                }
            }
            runtimeSection
        }
        .navigationTitle(CartoucheText.labRewrite)
        .navigationBarTitleDisplayMode(.inline)
        .fileImporter(isPresented: $choosingFolder, allowedContentTypes: [.folder]) { result in
            if case .success(let url) = result {
                lab.choose(url)
            }
        }
        .onAppear {
            if !lab.phase.isActive { lab.rescan() }
        }
    }

    // MARK: The folder

    private var folderSection: some View {
        Section {
            if let name = lab.folderName {
                LabeledContent(CartoucheText.labFolder, value: name)
            }
            if let folder = lab.folder {
                LabeledContent(CartoucheText.labModules, value: folder.modules.map(\.name).joined(separator: ", "))
                LabeledContent(CartoucheText.labReference,
                               value: folder.reference != nil ? CartoucheLab.referenceName : CartoucheText.labReferenceNone)
            } else if let error = lab.folderError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            }
            Button(CartoucheText.labChoose, systemImage: "folder") {
                choosingFolder = true
            }
            .disabled(lab.phase.isActive)
        } header: {
            Text(CartoucheText.labFolderTitle)
        } footer: {
            Text(CartoucheText.labFolderFooter)
        }
    }

    // MARK: Running

    private var runSection: some View {
        Section {
            switch lab.phase {
            case .copying(let done, let total):
                ProgressView(value: Double(done), total: Double(max(total, 1))) {
                    Text(CartoucheText.labCopying)
                }
            case .starting:
                Label(CartoucheText.labStarting, systemImage: "hourglass")
                    .foregroundStyle(.secondary)
            case .running:
                runningRows
            default:
                Button(CartoucheText.labRun, systemImage: "hammer") {
                    lab.run()
                }
                .disabled(lab.folder == nil || !CartouchePython.isBundled)
            }
            if lab.phase.isActive || lab.memory.peakMiB != nil {
                LabeledContent(CartoucheText.labPeakMemory, value: memoryText(lab.memory.peakMiB, of: lab.memory.limitMiB))
            }
            if lab.interrupted {
                Label(CartoucheText.labInterrupted, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            }
            if case .failed(let reason) = lab.phase {
                Label(reason, systemImage: "xmark.octagon.fill")
                    .foregroundStyle(.red)
            }
            if !CartouchePython.isBundled {
                Text(CartoucheText.labNoPython)
                    .foregroundStyle(.secondary)
            }
        } footer: {
            Text(CartoucheText.labRunFooter)
        }
    }

    @ViewBuilder
    private var runningRows: some View {
        let current = lab.status?.modules?.first { $0.name == lab.status?.current }
        Label(CartoucheText.labRewriting(current?.name ?? "…"), systemImage: "gearshape.2")
        if let modules = lab.status?.modules {
            let done = modules.filter { $0.state == "done" }.count
            ProgressView(value: Double(done), total: Double(max(modules.count, 1)))
        }
        TimelineView(.periodic(from: .now, by: 1)) { context in
            VStack(alignment: .leading, spacing: 4) {
                if let began = current?.began {
                    LabeledContent(CartoucheText.labElapsed, value: duration(context.date.timeIntervalSince1970 - began))
                }
                LabeledContent(CartoucheText.labMemoryNow, value: memoryText(lab.memory.nowMiB, of: lab.memory.limitMiB))
            }
        }
    }

    // MARK: Results

    private func resultSection(_ status: CartoucheLabStatus) -> some View {
        Section {
            if let game = status.game {
                LabeledContent(CartoucheText.labGame, value: game.name.isEmpty ? game.id : game.name)
            } else if status.modules != nil {
                LabeledContent(CartoucheText.labGame, value: CartoucheText.labGameUnknown)
            }
            if let summary = status.summary {
                if let same = summary.same {
                    let identical = same == summary.files && (summary.onlyOnMac ?? 0) == 0
                    Label(CartoucheText.labSame(same, summary.files),
                          systemImage: identical ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(identical ? Color.green : Color.orange)
                        .font(.headline)
                    if let different = summary.different, different > 0 {
                        LabeledContent(CartoucheText.labDifferent, value: String(different))
                    }
                    if let absent = summary.absent, absent > 0 {
                        LabeledContent(CartoucheText.labAbsent, value: String(absent))
                    }
                    if let only = summary.onlyOnMac, only > 0 {
                        LabeledContent(CartoucheText.labOnlyOnMac, value: String(only))
                    }
                } else {
                    LabeledContent(CartoucheText.labWritten, value: String(summary.files))
                }
            }
            ForEach(status.modules ?? [], id: \.name) { module in
                LabeledContent(module.name, value: module.seconds.map(duration) ?? CartoucheText.labWaiting)
            }
            if let total = totalSeconds(status) {
                LabeledContent(CartoucheText.labTotal, value: duration(total))
            }
            if let exported = lab.reportExported {
                Label(exported ? CartoucheText.labReportExported(CartoucheLab.reportName) : CartoucheText.labReportKept,
                      systemImage: exported ? "doc.text" : "exclamationmark.triangle")
                    .font(.footnote)
                    .foregroundStyle(exported ? Color.secondary : Color.orange)
            }
        } header: {
            Text(CartoucheText.labResult)
        }
    }

    private func filesSection(_ files: [CartoucheLabStatus.File], onlyOnMac: [String]) -> some View {
        Section(CartoucheText.labFiles) {
            ForEach(files, id: \.name) { file in
                HStack {
                    Image(systemName: icon(file.mac))
                        .foregroundStyle(color(file.mac))
                        .accessibilityLabel(fileState(file.mac))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(file.name)
                        Text(String(file.sha256.prefix(16)) + "…")
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                    }
                }
            }
            ForEach(onlyOnMac, id: \.self) { name in
                Label(name, systemImage: "questionmark.circle")
                    .foregroundStyle(.orange)
                    .accessibilityHint(CartoucheText.labOnlyOnMac)
            }
        }
    }

    private var runtimeSection: some View {
        Section(CartoucheText.labRuntime) {
            LabeledContent("Python", value: CartouchePython.version ?? "—")
            LabeledContent("nxnative", value: CartouchePython.nxnativeCommit ?? "—")
        }
    }

    // MARK: Formatting

    private func icon(_ mac: String?) -> String {
        switch mac {
        case "same": return "checkmark.circle.fill"
        case "different": return "xmark.circle.fill"
        case "absent": return "questionmark.circle"
        default: return "circle"
        }
    }

    private func color(_ mac: String?) -> Color {
        switch mac {
        case "same": return .green
        case "different": return .red
        case "absent": return .orange
        default: return .secondary
        }
    }

    private func fileState(_ mac: String?) -> String {
        switch mac {
        case "same": return CartoucheText.labFileSame
        case "different": return CartoucheText.labDifferent
        case "absent": return CartoucheText.labAbsent
        default: return CartoucheText.labReferenceNone
        }
    }

    private func totalSeconds(_ status: CartoucheLabStatus) -> Double? {
        let seconds = (status.modules ?? []).compactMap(\.seconds)
        return seconds.isEmpty ? nil : seconds.reduce(0, +)
    }

    private func duration(_ seconds: Double) -> String {
        Duration.seconds(seconds).formatted(.time(pattern: seconds >= 3600 ? .hourMinuteSecond : .minuteSecond))
    }

    private func memoryText(_ mebibytes: Int?, of limit: Int?) -> String {
        guard let mebibytes else { return "—" }
        guard let limit else { return CartoucheText.memoryAmount(mebibytes: mebibytes) }
        return CartoucheText.labMemoryOf(CartoucheText.memoryAmount(mebibytes: mebibytes), CartoucheText.memoryAmount(mebibytes: limit))
    }
}
