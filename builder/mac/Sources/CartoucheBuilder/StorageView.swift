//
//  StorageView.swift
//  Cartouche Builder
//
//  What the builder keeps on the Mac, by size, and the space of each disk
//  it uses: the games' build folders (their extracted files, shaders and
//  app), the IPA copies that take room besides the games folder, the logs,
//  and the games' apps it put on this Mac. Each can be freed here; only
//  the builder's own folders and files are, and a Mac app goes to the
//  Trash, the game then no longer built for this Mac.
//

import BuilderKit
import SwiftUI

struct StorageView: View {
    @EnvironmentObject private var model: AppModel
    @State private var confirm: Confirmation?
    @State private var trash: MacAppCopy?

    struct Confirmation: Identifiable {
        let id = UUID()
        let title: String
        let message: String
        let what: String
        let paths: [String]
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                PageHeader(title: tr("Storage", "Stockage"), subtitle: subtitle) {
                    Button {
                        Task { await model.loadStorage() }
                    } label: {
                        Label(tr("Measure again", "Mesurer à nouveau"), systemImage: "arrow.clockwise")
                    }
                    .disabled(model.loadingStorage)
                }
                if let storage = model.storage {
                    disks(storage)
                    freeable(storage)
                    if !storage.folders.isEmpty {
                        folders(storage)
                    }
                    if !storage.apps.isEmpty {
                        macApps(storage)
                    }
                    StorageSettingsCard()
                } else {
                    LoadingCard()
                }
            }
            .padding(28)
        }
        .task {
            if model.storage == nil { await model.loadStorage() }
        }
        .confirmationDialog(confirm?.title ?? "", isPresented: Binding(get: { confirm != nil }, set: { if !$0 { confirm = nil } }), presenting: confirm) { asked in
            Button(tr("Free", "Libérer"), role: .destructive) { model.clean(asked.what, paths: asked.paths) }
        } message: { asked in
            Text(asked.message)
        }
    }

    private func trashMessage(_ app: MacAppCopy) -> String {
        if app.isInstalledCopy {
            return (model.gamesOnShare
                ? tr("Its app stays on the NAS: it is installed again when you play the game. ", "Son app reste sur le NAS : elle se réinstalle quand vous jouez au jeu. ")
                : tr("Its app stays in the games folder: it is installed again when you play the game. ", "Son app reste dans le dossier des jeux : elle se réinstalle quand vous jouez au jeu. "))
                + tr("Its saves stay on this Mac.", "Ses sauvegardes restent sur ce Mac.")
        }
        let alone = !(model.config?.onIOS(app.titleID) ?? true)
        return (alone ? tr("The game is then no longer built: it was built for this Mac alone. ", "Le jeu n’est alors plus construit : il l’était pour ce Mac seul. ")
                      : tr("The game is then no longer built for this Mac; its IPA still is. ", "Le jeu n’est alors plus construit pour ce Mac ; son IPA l’est toujours. "))
            + tr("Its saves stay on this Mac.", "Ses sauvegardes restent sur ce Mac.")
    }

    private var subtitle: String {
        guard let storage = model.storage else { return tr("Measuring…", "Mesure en cours…") }
        let kept = storage.buildFolders + storage.total("ipa_copies") + storage.total("logs") + storage.total("mac_apps")
        return tr("Cartouche Builder keeps \(Format.size(kept)) on this Mac", "Cartouche Builder garde \(Format.size(kept)) sur ce Mac")
    }

    private func disks(_ storage: StorageReport) -> some View {
        HStack(alignment: .top, spacing: 16) {
            if let disk = storage.workspaceDisk {
                DiskCard(title: tr("Build disk", "Disque des constructions"), symbol: "internaldrive", disk: disk,
                         note: tr("Keeps \(model.config?.minFreeGB ?? 20) GB free: the oldest build folders go first.",
                                  "Garde \(model.config?.minFreeGB ?? 20) Go libres : les plus vieux dossiers partent d’abord."))
            }
            if let disk = storage.gamesDisk {
                DiskCard(title: tr("Games folder", "Dossier des jeux"), symbol: model.library?.folders?.games?.isShare == true ? "externaldrive.connected.to.line.below" : "folder",
                         disk: disk, note: model.library?.folders?.games?.isShare == true ? tr("On your NAS", "Sur votre NAS") : tr("On this Mac", "Sur ce Mac"))
            }
        }
    }

    private func freeable(_ storage: StorageReport) -> some View {
        Card(padding: 6) {
            VStack(spacing: 0) {
                StorageRow(symbol: "doc.zipper", title: tr("Extracted game files", "Fichiers extraits des jeux"),
                           detail: tr("As big as the games; only a faster next build needs them.", "Aussi gros que les jeux ; seule une reconstruction plus rapide en a besoin."),
                           size: storage.total("extracted"), action: storage.total("extracted") > 0 ? tr("Free", "Libérer") : nil) {
                    confirm = Confirmation(title: tr("Free the extracted files?", "Libérer les fichiers extraits ?"),
                                           message: tr("The next build of each game extracts it again.", "La prochaine construction de chaque jeu les extraira à nouveau."),
                                           what: "extracted", paths: [])
                }
                Divider().padding(.leading, 48)
                let copies = storage.ipaCopies.filter { !$0.sameDisk }
                StorageRow(symbol: "shippingbox", title: tr("IPA copies", "Copies d’IPA"),
                           detail: copies.isEmpty
                               ? tr("Those beside the games folder, on the same disk, take no room (APFS clones).", "Celles à côté du dossier des jeux, sur le même disque, ne prennent pas de place (clones APFS).")
                               : tr("\(copies.count) copies on another disk than the games folder.", "\(copies.count) copies sur un autre disque que le dossier des jeux."),
                           size: storage.total("ipa_copies_freeable"), action: copies.isEmpty ? nil : tr("Free", "Libérer")) {
                    confirm = Confirmation(title: tr("Free the IPA copies?", "Libérer les copies d’IPA ?"),
                                           message: tr("Your games folder keeps its IPAs.", "Votre dossier des jeux garde ses IPA."),
                                           what: "ipa_copies", paths: copies.map(\.path))
                }
                Divider().padding(.leading, 48)
                StorageRow(symbol: "sparkles.rectangle.stack", title: tr("Shaders and apps of the builds", "Shaders et apps des constructions"),
                           detail: tr("Make the next builds faster.", "Accélèrent les prochaines constructions."),
                           size: storage.total("shaders") + storage.total("app") + storage.total("packages") + storage.total("other"), action: nil) {}
                Divider().padding(.leading, 48)
                StorageRow(symbol: "doc.text", title: tr("Logs", "Journaux"),
                           detail: tr("Those older than a week can go.", "Ceux de plus d’une semaine peuvent partir."),
                           size: storage.total("logs"), action: storage.total("logs") > 0 ? tr("Clean", "Nettoyer") : nil) {
                    model.clean("logs")
                }
                Divider().padding(.leading, 48)
                StorageRow(symbol: "shippingbox.circle", title: tr("nxnative and its Python", "nxnative et son Python"),
                           detail: tr("Needed for every build.", "Nécessaires à chaque construction."),
                           size: storage.total("engine") + storage.total("python"), action: nil) {}
            }
        }
    }

    private func folders(_ storage: StorageReport) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(tr("Build folders", "Dossiers de construction").uppercased())
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Card(padding: 6) {
                VStack(spacing: 0) {
                    ForEach(Array(storage.folders.sorted { $0.size > $1.size }.enumerated()), id: \.element.id) { index, folder in
                        if index > 0 { Divider().padding(.leading, 12) }
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(folder.name.isEmpty ? folder.titleID : folder.name)
                                    .font(.callout.weight(.medium))
                                Text(folderDetail(folder))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text(Format.size(folder.size))
                                .font(.callout.monospacedDigit())
                            Button {
                                confirm = Confirmation(title: tr("Delete this build folder?", "Supprimer ce dossier de construction ?"),
                                                       message: tr("The next build of \(folder.name) starts from scratch, and takes longer.",
                                                                   "La prochaine construction de \(folder.name) repart de zéro, et prend plus de temps."),
                                                       what: "folders", paths: [folder.path])
                            } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.borderless)
                            .disabled(model.isBuilding)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                    }
                }
            }
        }
    }

    /// The games' apps the builder put on this Mac, still where it put them.
    private func macApps(_ storage: StorageReport) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(tr("Games on this Mac", "Jeux sur ce Mac").uppercased())
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Card(padding: 6) {
                VStack(spacing: 0) {
                    ForEach(Array(storage.apps.enumerated()), id: \.element.id) { index, app in
                        if index > 0 { Divider().padding(.leading, 12) }
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(app.name.isEmpty ? app.titleID : app.name)
                                    .font(.callout.weight(.medium))
                                Text(appDetail(app))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            Spacer()
                            Text(Format.size(app.size))
                                .font(.callout.monospacedDigit())
                            Button {
                                model.reveal(app.path)
                            } label: {
                                Image(systemName: "folder")
                            }
                            .buttonStyle(.borderless)
                            .help(tr("Show in the Finder", "Afficher dans le Finder"))
                            Button {
                                trash = app
                            } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.borderless)
                            .disabled(model.isBuilding)
                            .help(tr("Move to the Trash", "Mettre à la Corbeille"))
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                    }
                }
            }
        }
        // Its own dialog: the page's frees the builder's folders.
        .confirmationDialog(tr("Move \(trash?.name ?? "") to the Trash?", "Mettre \(trash?.name ?? "") à la Corbeille ?"),
                            isPresented: Binding(get: { trash != nil }, set: { if !$0 { trash = nil } }), presenting: trash) { app in
            Button(tr("Move to the Trash", "Mettre à la Corbeille"), role: .destructive) { model.removeMacApp(app) }
        } message: { app in
            Text(trashMessage(app))
        }
    }

    private func appDetail(_ app: MacAppCopy) -> String {
        var parts: [String] = []
        if app.isInstalledCopy {
            parts.append(model.gamesOnShare ? tr("installed from the NAS", "installée depuis le NAS") : tr("installed from the games folder", "installée depuis le dossier des jeux"))
        }
        if let date = app.date { parts.append(tr("built ", "construite ") + Format.relative(date)) }
        if !app.on { parts.append(tr("no longer built", "plus construite")) }
        if app.sharesBuild == true {
            parts.append(tr("its game files share their room with its build folder’s extracted files", "ses fichiers de jeu partagent leur place avec les fichiers extraits de son dossier de construction"))
        }
        return parts.joined(separator: " · ")
    }

    private func folderDetail(_ folder: BuildFolder) -> String {
        var parts: [String] = []
        if folder.extracted > 0 { parts.append(tr("extracted ", "extraits ") + Format.size(folder.extracted)) }
        if folder.shaders > 0 { parts.append("shaders " + Format.size(folder.shaders)) }
        if let used = folder.used, used > 0 { parts.append(tr("used ", "utilisé ") + Format.relative(Date(timeIntervalSince1970: used))) }
        return parts.joined(separator: " · ")
    }
}

struct DiskCard: View {
    let title: String
    let symbol: String
    let disk: Disk
    let note: String

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                Label(title, systemImage: symbol)
                    .font(.headline)
                let used = disk.total > disk.free ? disk.total - disk.free : 0
                ProgressView(value: disk.total > 0 ? Double(used) / Double(disk.total) : 0)
                    .tint(Double(disk.free) < Double(disk.total) * 0.1 ? .orange : Theme.indigo)
                Text(tr("\(Format.size(disk.free)) free of \(Format.size(disk.total))", "\(Format.size(disk.free)) libres sur \(Format.size(disk.total))"))
                    .font(.callout.monospacedDigit())
                Text(note)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

struct StorageRow: View {
    @EnvironmentObject private var model: AppModel
    let symbol: String
    let title: String
    let detail: String
    let size: UInt64
    let action: String?
    let perform: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: symbol)
                .font(.title3)
                .foregroundStyle(Theme.indigo)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.callout.weight(.medium))
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            Text(Format.size(size))
                .font(.callout.monospacedDigit().weight(.semibold))
            if let action {
                Button(action, action: perform)
                    .disabled(model.cleaning || model.isBuilding)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }
}

/// How much the builder keeps, the same settings as in the Settings.
struct StorageSettingsCard: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        if let config = model.config {
            Card {
                VStack(alignment: .leading, spacing: 12) {
                    Toggle(isOn: Binding(get: { config.keepExtracted }, set: { on in model.update { $0.keepExtracted = on } })) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(tr("Keep the extracted files", "Garder les fichiers extraits"))
                            Text(tr("Faster rebuilds, as much room as the games.", "Reconstructions plus rapides, autant de place que les jeux."))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Divider()
                    Stepper(value: Binding(get: { config.minFreeGB }, set: { value in model.update { $0.minFreeGB = value } }), in: 5...500, step: 5) {
                        Text(tr("Keep at least \(config.minFreeGB) GB free", "Garder au moins \(config.minFreeGB) Go libres"))
                    }
                }
            }
        }
    }
}
