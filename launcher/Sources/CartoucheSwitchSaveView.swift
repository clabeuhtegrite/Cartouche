//
//  CartoucheSwitchSaveView.swift
//  Cartouche
//
//  A game's save between the player's Switch and this iPhone, from the
//  game's sheet › Saves (CartoucheSwitchSave, CartoucheSwitchSaveArchive):
//
//  - the save JKSV or Checkpoint exported on the Switch, picked in Files,
//    as a folder or a ZIP archive, read and checked, then put in place of
//    this iPhone's after a question; this iPhone's is kept, and put back on
//    request. With a saves folder, the save then goes there as the newest
//    copy, for the player's other iPhones (CartoucheSaveBackups);
//  - this iPhone's save as a ZIP archive JKSV restores on the Switch,
//    shared from here, as to Files on the microSD card, or to a Mac.
//

import SwiftUI
import UniformTypeIdentifiers

/// The game whose save comes from the Switch, or goes to it.
struct CartoucheSwitchSaveGame {
    let name: String
    let titleId: String?
    /// The game's version on this iPhone, which the Switch's should not
    /// pass.
    let version: String?
    /// A game of the Switch 2, whose saves no public tool exports yet.
    let isSwitch2: Bool
    /// The game's saves; nil for a game that never started, which has no
    /// data folder yet.
    let target: CartoucheSaveTarget?
    /// The game's saves, its data folder made now if it never started, as
    /// on its first start: for a save that comes before it.
    let makeTarget: () -> CartoucheSaveTarget?
    /// Whether the game runs behind the console now: the player may start
    /// it while a save comes, from the console under the sheet.
    let isRunningNow: @MainActor () -> Bool
}

@available(iOS 17.0, *)
struct CartoucheSwitchSaveView: View {
    let game: CartoucheSwitchSaveGame
    /// Whether the game runs behind the console, writing its saves: none
    /// comes or goes meanwhile.
    let isRunning: Bool
    @ObservedObject private var backups = CartoucheSaveBackups.shared

    /// What the player picked, read, and the folder of the game's Documents
    /// its save goes to.
    private struct Found {
        let pick: CartoucheSwitchSavePick
        let folder: String
    }

    @State private var choosing = false
    @State private var reading = false
    @State private var found: Found?
    /// Why what was picked cannot come.
    @State private var refusal: String?
    @State private var asking = false
    @State private var working = false
    @State private var imported = false
    @State private var putBackDone = false
    /// Why the last step failed, and the report on it.
    @State private var failure: CartoucheReport?
    /// The game's saves, once its data folder was made for an import.
    @State private var made: CartoucheSaveTarget?
    /// The saves the last import replaced, kept on this iPhone.
    @State private var before: CartoucheSwitchSaveBackup?
    @State private var askingPutBack = false
    /// Whether the game has a save on this iPhone, to send to the Switch.
    @State private var hasSave = false
    /// The archive made for the Switch, to share.
    @State private var archive: URL?
    @State private var making = false

    #if CARTOUCHE_GALLERY
    /// What the gallery picks as the page opens, for its screenshot.
    static var galleryPick: (() async -> URL?)?
    #endif

    init(game: CartoucheSwitchSaveGame, isRunning: Bool) {
        self.game = game
        self.isRunning = isRunning
    }

    private var target: CartoucheSaveTarget? { made ?? game.target }

    /// The game's title IDs, its regions' too: a save of any is the game's.
    private var titleIds: [String] {
        guard let titleId = game.titleId, !titleId.isEmpty else { return [] }
        return CartoucheCatalog.shared.game(titleId: titleId)?.titleIds ?? [titleId]
    }

    var body: some View {
        List {
            importSection
            if let found {
                foundSection(found)
            }
            if refusal != nil || failure != nil || imported || putBackDone {
                outcomeSection
            }
            if let before {
                putBackSection(before)
            }
            sendSection
        }
        .cartoucheStageBackground()
        .navigationTitle(CartoucheText.switchSaveTitle)
        .navigationBarTitleDisplayMode(.inline)
        .overlay {
            if reading || working || making {
                ProgressView()
                    .controlSize(.large)
                    .padding(28)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            }
        }
        .fileImporter(isPresented: $choosing, allowedContentTypes: [.zip, .folder]) { result in
            guard case .success(let url) = result else { return }
            Task { await read(url) }
        }
        .confirmationDialog(CartoucheText.switchSaveImportQuestion, isPresented: $asking, titleVisibility: .visible) {
            Button(CartoucheText.switchSaveImport, role: .destructive) {
                Task { await bringIn() }
            }
            Button(CartoucheText.cancel, role: .cancel) {}
        } message: {
            Text(backups.isOn ? CartoucheText.switchSaveImportMessageFolder : CartoucheText.switchSaveImportMessage)
        }
        .confirmationDialog(CartoucheText.switchSavePutBackQuestion, isPresented: $askingPutBack, titleVisibility: .visible) {
            Button(CartoucheText.switchSavePutBack, role: .destructive) {
                Task { await putBack() }
            }
            Button(CartoucheText.cancel, role: .cancel) {}
        } message: {
            Text(CartoucheText.switchSavePutBackMessage)
        }
        .task {
            look()
            #if CARTOUCHE_GALLERY
            if let pick = Self.galleryPick, let url = await pick() { await read(url) }
            #endif
        }
    }

    // MARK: Sections

    private var importSection: some View {
        Section {
            Text(CartoucheText.switchSaveIntro)
            if game.isSwitch2 {
                Label(CartoucheText.switchSaveSwitch2, systemImage: "info.circle")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Button {
                choosing = true
            } label: {
                Label(CartoucheText.switchSaveChoose, systemImage: "folder")
            }
            .disabled(isRunning || reading || working)
            if isRunning {
                Text(CartoucheText.switchSaveRunning)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text(CartoucheText.switchSaveImportHeader)
        }
    }

    private func foundSection(_ found: Found) -> some View {
        let export = found.pick.export
        let size = ByteCountFormatter.string(fromByteCount: Int64(clamping: export.size), countStyle: .file)
        return Section {
            LabeledContent(CartoucheText.switchSaveGame,
                           value: export.meta == nil ? CartoucheText.switchSaveUnchecked : CartoucheText.switchSaveChecked)
            LabeledContent(CartoucheText.switchSaveKind,
                           value: export.meta?.kind == .device ? CartoucheText.switchSaveDevice : CartoucheText.switchSaveAccount)
            LabeledContent(CartoucheText.switchSaveContent, value: CartoucheText.switchSaveFiles(export.files.count, size))
            if let version = game.version {
                LabeledContent(CartoucheText.switchSaveVersion, value: version)
            }
            Button {
                asking = true
            } label: {
                Label(CartoucheText.switchSaveImport, systemImage: "square.and.arrow.down")
            }
            .disabled(isRunning || working)
        } header: {
            Text(verbatim: found.pick.url.lastPathComponent)
        } footer: {
            Text(CartoucheText.switchSaveImportFooter)
        }
    }

    private var outcomeSection: some View {
        Section {
            if let refusal {
                Label(refusal, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(Color.orange)
            }
            if let failure {
                Label(failure.title, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(Color.orange)
                Text(failure.message)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                CartoucheReportButton(report: failure)
            }
            if imported {
                Label(CartoucheText.switchSaveImported, systemImage: "checkmark.circle.fill")
                    .foregroundStyle(Color.green)
                if backups.isOn {
                    Text(CartoucheText.switchSaveImportedSending)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            if putBackDone {
                Label(CartoucheText.switchSavePutBackDone, systemImage: "checkmark.circle.fill")
                    .foregroundStyle(Color.green)
            }
        }
    }

    private func putBackSection(_ before: CartoucheSwitchSaveBackup) -> some View {
        Section {
            Button {
                askingPutBack = true
            } label: {
                Label(CartoucheText.switchSavePutBack, systemImage: "clock.arrow.circlepath")
            }
            .disabled(isRunning || working)
        } footer: {
            Text(CartoucheText.switchSavePutBackFooter(before.date.formatted(date: .abbreviated, time: .shortened)))
        }
    }

    private var sendSection: some View {
        Section {
            if !hasSave {
                Text(CartoucheText.switchSaveSendNone)
                    .foregroundStyle(.secondary)
            } else if let archive {
                ShareLink(item: archive) {
                    Label(CartoucheText.switchSaveSendShare(archive.lastPathComponent), systemImage: "square.and.arrow.up")
                }
                .disabled(isRunning)
            } else {
                Button {
                    Task { await makeArchive() }
                } label: {
                    Label(CartoucheText.switchSaveSendMake, systemImage: "doc.zipper")
                }
                .disabled(isRunning || making || working || backups.isSyncing)
            }
        } header: {
            Text(CartoucheText.switchSaveSendHeader)
        } footer: {
            Text(CartoucheText.switchSaveSendFooter)
        }
    }

    // MARK: Steps

    /// What the game has on this iPhone: a save to send, and the one the last
    /// import replaced.
    private func look() {
        guard let target else {
            before = nil
            hasSave = false
            return
        }
        before = CartoucheSwitchSave.backups(CartoucheSwitchSave.beforeImport, in: target.documents).first
        let save = target.documents.appendingPathComponent(CartoucheSwitchSave.saveFolder, isDirectory: true)
        hasSave = !((try? FileManager.default.contentsOfDirectory(atPath: save.path)) ?? []).isEmpty
    }

    /// Reads URL, the folder or the archive the player picked.
    private func read(_ url: URL) async {
        reading = true
        found = nil
        refusal = nil
        failure = nil
        imported = false
        putBackDone = false
        defer { reading = false }
        do {
            let pick = try await Task.detached(priority: .userInitiated) {
                let accessing = url.startAccessingSecurityScopedResource()
                defer { if accessing { url.stopAccessingSecurityScopedResource() } }
                return try await CartoucheSwitchSaveArchive.read(url)
            }.value
            let folder = try CartoucheSwitchSave.folder(for: pick.export, game: titleIds, names: pick.names,
                                                        documents: target?.documents)
            found = Found(pick: pick, folder: folder)
            CartoucheReports.note("Save from the Switch read for " + game.name + ": " + String(pick.export.files.count) + " files, "
                                  + (pick.export.meta == nil ? "no JKSV fiche" : "JKSV's fiche") + ", for " + folder)
        } catch let problem as CartoucheSwitchSaveProblem {
            refuse(problem)
        } catch is CartoucheZipError {
            refusal = CartoucheText.switchSaveUnreadable
            CartoucheReports.note("Save from the Switch for " + game.name + ": not an archive Cartouche can read")
        } catch {
            failure = CartoucheReports.make(.saves, CartoucheText.switchSaveReadFailed, message: error.localizedDescription,
                                            error: error, step: "Reading a save from the Switch for " + game.name,
                                            stage: "switchSaveRead")
        }
    }

    /// Puts the save found in place of the game's on this iPhone.
    private func bringIn() async {
        guard let found else { return }
        working = true
        refusal = nil
        failure = nil
        imported = false
        putBackDone = false
        defer {
            working = false
            look()
        }
        if made == nil, game.target == nil { made = game.makeTarget() }
        guard let target else {
            refusal = CartoucheText.switchSaveUnreadable
            return
        }
        let pick = found.pick
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("CartoucheSwitchSave", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: work) }
        do {
            // Again: the game may have started since, as for the console's
            // save, or nxnative stopped while it brought in its cloud's.
            let folder = try CartoucheSwitchSave.folder(for: pick.export, game: titleIds, names: pick.names,
                                                        documents: target.documents)
            let staged = work.appendingPathComponent("staged", isDirectory: true)
            try await Task.detached(priority: .userInitiated) {
                let accessing = pick.url.startAccessingSecurityScopedResource()
                defer { if accessing { pick.url.stopAccessingSecurityScopedResource() } }
                try await CartoucheSwitchSaveArchive.stage(pick, as: folder, into: staged, work: work)
            }.value
            let kept = try await backups.bringIn(staged, of: target, running: game.isRunningNow)
            imported = true
            archive = nil
            self.found = nil
            CartoucheReports.note("Save of " + game.name + " from the Switch put in place, in " + folder + "; "
                                  + (kept == nil ? "the game had no save there" : "the save it replaced kept on this iPhone"))
        } catch let problem as CartoucheSwitchSaveProblem {
            refuse(problem)
        } catch {
            failure = CartoucheReports.make(.saves, CartoucheText.switchSaveImportFailed, message: error.localizedDescription,
                                            error: error, step: "Putting a save from the Switch in place of " + game.name + "'s",
                                            stage: "switchSaveImport",
                                            facts: [.init("Files", String(pick.export.files.count)),
                                                    .init("Size", CartoucheReport.bytes(Int64(clamping: pick.export.size)))])
        }
    }

    /// Puts back the save the last import replaced.
    private func putBack() async {
        guard let before, let target else { return }
        working = true
        refusal = nil
        failure = nil
        imported = false
        putBackDone = false
        defer {
            working = false
            look()
        }
        do {
            try await backups.putBack(beforeImport: before, of: target, running: game.isRunningNow)
            putBackDone = true
            archive = nil
            CartoucheReports.note("Save of " + game.name + " from before the import of " + CartoucheReport.timestamp(before.date)
                                  + " put back")
        } catch let problem as CartoucheSwitchSaveProblem {
            refuse(problem)
        } catch {
            failure = CartoucheReports.make(.saves, CartoucheText.switchSavePutBackFailed, message: error.localizedDescription,
                                            error: error, step: "Putting back " + game.name + "'s save from before an import",
                                            stage: "switchSavePutBack")
        }
    }

    /// Makes the archive JKSV restores on the Switch, of the game's save.
    private func makeArchive() async {
        guard let target else { return }
        making = true
        failure = nil
        defer { making = false }
        let save = target.documents.appendingPathComponent(CartoucheSwitchSave.saveFolder, isDirectory: true)
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("CartoucheSwitchSave", isDirectory: true)
            .appendingPathComponent("Send", isDirectory: true)
        let url = folder.appendingPathComponent(CartoucheSwitchSave.archiveName(at: Date()))
        do {
            let files = try await Task.detached(priority: .userInitiated) { () -> Int in
                try? FileManager.default.removeItem(at: folder)
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                let sink = try CartoucheFileSink(url)
                do {
                    let files = try await CartoucheSwitchSaveArchive.writeZip(ofSave: save, to: sink)
                    try sink.close()
                    return files
                } catch {
                    try? sink.close()
                    throw error
                }
            }.value
            archive = url
            CartoucheReports.note("Save of " + game.name + " made into a ZIP for JKSV: " + String(files) + " files")
        } catch {
            failure = CartoucheReports.make(.saves, CartoucheText.switchSaveSendFailed, message: error.localizedDescription,
                                            error: error, step: "Making a ZIP of " + game.name + "'s save for the Switch",
                                            stage: "switchSaveSend")
        }
    }

    private func refuse(_ problem: CartoucheSwitchSaveProblem) {
        refusal = Self.text(of: problem)
        CartoucheReports.note("Save from the Switch for " + game.name + " refused: " + String(describing: problem))
    }

    /// What the player reads of PROBLEM.
    static func text(of problem: CartoucheSwitchSaveProblem) -> String {
        switch problem {
        case .empty: return CartoucheText.switchSaveEmpty
        case .several: return CartoucheText.switchSaveSeveral
        case .unsafe: return CartoucheText.switchSaveUnreadable
        case .caseClash(let first, let second): return CartoucheText.switchSaveCaseClash(first, second)
        case .otherGame(let titleId):
            return CartoucheText.switchSaveOtherGame(CartoucheCatalog.shared.game(titleId: titleId)?.name ?? titleId)
        case .notAGame: return CartoucheText.switchSaveNotAGame
        case .startFirst: return CartoucheText.switchSaveStartFirst
        case .cloudPull: return CartoucheText.switchSaveCloudPull
        case .running: return CartoucheText.switchSaveRunning
        }
    }
}
