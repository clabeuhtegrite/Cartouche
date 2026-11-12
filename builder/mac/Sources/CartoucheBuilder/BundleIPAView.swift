// An existing slim nxnative IPA and its matching game data, without a build.

import AppKit
import BuilderKit
import SwiftUI
import UniformTypeIdentifiers

struct BundleIPAView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var ipa: URL?
    @State private var image: URL?
    @State private var result: String?
    @State private var problem: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(tr("Import IPA + ROMFS", "Importer IPA + ROMFS"))
                .font(.title2.bold())
            Text(tr("Add matching game data to an existing nxnative IPA without compiling. The build must support romfs.img inside its app bundle. Your original files stay as they are.",
                    "Ajoutez les fichiers du jeu à une IPA nxnative existante, sans compiler. Cette version doit accepter romfs.img dans l’app. Vos fichiers d’origine sont conservés."))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            fileRow("IPA", url: ipa) { ipa = chooseFile("IPA", extension: "ipa") }
            fileRow("romfs.img", url: image) { image = chooseFile("romfs.img", extension: "img") }
            if model.bundling {
                HStack {
                    ProgressView().controlSize(.small)
                    Text(model.bundleMessage).font(.callout)
                }
            }
            if let problem { Text(problem).foregroundStyle(.red).textSelection(.enabled) }
            if let result {
                Text(tr("The complete IPA is in your games folder. Refresh Cartouche on the iPhone to install it.",
                        "L’IPA complète est dans le dossier des jeux. Actualisez Cartouche sur l’iPhone pour l’installer."))
                Button(tr("Show in Finder", "Afficher dans le Finder")) {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: result)])
                }
            }
            HStack {
                Spacer()
                Button(tr("Close", "Fermer")) { dismiss() }
                    .disabled(model.bundling)
                    .keyboardShortcut(.cancelAction)
                if result == nil {
                    Button(tr("Create complete IPA", "Créer l’IPA complète")) { importIPA() }
                        .buttonStyle(.borderedProminent)
                        .disabled(ipa == nil || image == nil || model.bundling)
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(24)
        .frame(width: 500)
        .interactiveDismissDisabled(model.bundling)
    }

    private func fileRow(_ title: String, url: URL?, choose: @escaping () -> Void) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.headline)
                Text(url?.lastPathComponent ?? tr("Not chosen yet", "Pas encore choisi"))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            Button(tr("Choose…", "Choisir…"), action: choose)
                .disabled(model.bundling || result != nil)
        }
    }

    private func chooseFile(_ title: String, extension suffix: String) -> URL? {
        let panel = NSOpenPanel()
        panel.message = title
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        if let type = UTType(filenameExtension: suffix) { panel.allowedContentTypes = [type] }
        return panel.runModal() == .OK ? panel.url : nil
    }

    private func importIPA() {
        guard let ipa, let image else { return }
        problem = nil
        Task {
            do { result = try await model.bundleIPA(ipa, image: image) }
            catch { problem = error.localizedDescription }
        }
    }
}
