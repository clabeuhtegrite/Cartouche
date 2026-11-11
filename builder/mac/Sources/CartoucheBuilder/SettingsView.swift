//
//  SettingsView.swift
//  Cartouche Builder
//
//  Every setting, without a Terminal: the folders, what is built and when,
//  what is kept on the disk, the bridge, the updates and the measures, and
//  the app's own (language, menu bar, opening at login).
//

import AppKit
import BuilderKit
import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    var body: some View {
        TabView {
            ForEach(SettingsTab.allCases) { tab in
                tab.content
                    .tabItem { Label(tab.title, systemImage: tab.symbol) }
            }
        }
        .frame(width: SettingsTab.size.width, height: SettingsTab.size.height)
    }
}

/// The settings' tabs, in order: the Settings scene's toolbar, and the
/// gallery's picture of it (Gallery.swift).
enum SettingsTab: CaseIterable, Identifiable {
    case general, folders, builds, storage, advanced

    static let size = CGSize(width: 600, height: 520)

    var id: Self { self }

    var title: String {
        switch self {
        case .general: return tr("General", "Général")
        case .folders: return tr("Folders", "Dossiers")
        case .builds: return tr("Builds", "Constructions")
        case .storage: return tr("Storage", "Stockage")
        case .advanced: return tr("Advanced", "Avancé")
        }
    }

    var symbol: String {
        switch self {
        case .general: return "gearshape"
        case .folders: return "folder"
        case .builds: return "hammer"
        case .storage: return "internaldrive"
        case .advanced: return "slider.horizontal.3"
        }
    }

    @MainActor @ViewBuilder
    var content: some View {
        switch self {
        case .general: GeneralSettings()
        case .folders: FolderSettings()
        case .builds: BuildSettings()
        case .storage: StorageSettings()
        case .advanced: AdvancedSettings()
        }
    }
}

/// A setting of the engine, as a binding that saves it.
@MainActor
func setting<Value>(_ model: AppModel, _ key: WritableKeyPath<BuilderConfig, Value>, _ fallback: Value) -> Binding<Value> {
    Binding(get: { model.config?[keyPath: key] ?? fallback },
            set: { value in model.update { $0[keyPath: key] = value } })
}

struct GeneralSettings: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var updater: Updater
    @EnvironmentObject private var telemetry: BuilderTelemetry
    @AppStorage(AppSettings.menuBarKey) private var menuBar = true
    @State private var askErase = false
    @State private var erased: Bool?

    var body: some View {
        Form {
            Section {
                Picker(tr("Language", "Langue"), selection: setting(model, \.language, "")) {
                    Text(tr("The Mac’s", "Celle du Mac")).tag("")
                    Text("Français").tag("fr")
                    Text("English").tag("en")
                }
                Toggle(tr("Notifications when a build ends or nxnative improves a game", "Notifications quand une construction finit ou que nxnative améliore un jeu"),
                       isOn: setting(model, \.notifications, true))
                Toggle(tr("Icon in the menu bar", "Icône dans la barre des menus"), isOn: $menuBar)
                Toggle(tr("Open at login", "Ouvrir à l’ouverture de session"), isOn: Binding(get: { model.opensAtLogin }, set: { model.setOpensAtLogin($0) }))
            }
            Section(tr("Updates", "Mises à jour")) {
                Toggle(tr("Install updates by itself", "Installer les mises à jour toute seule"), isOn: Binding(get: { updater.automatic }, set: { updater.automatic = $0 }))
                LabeledContent(tr("Version", "Version")) {
                    HStack {
                        Text(updater.current)
                        UpdateStateText()
                    }
                }
                HStack {
                    Button(tr("Check for an update", "Rechercher une mise à jour")) {
                        Task { await updater.check(force: true) }
                    }
                    .disabled(updater.busy || !updater.enabled)
                    Spacer()
                    UpdateActions()
                }
            }
            Section {
                Toggle(tr("Send usage measures", "Envoyer des mesures d’utilisation"), isOn: Binding(get: { telemetry.isOn }, set: { telemetry.setOn($0) }))
                Text(tr("Builds, their times and failures, this Mac’s model and tools: never a file name, a path, a game’s content or your Apple account.",
                        "Les constructions, leurs durées et leurs échecs, le modèle du Mac et ses outils : jamais un nom de fichier, un chemin, le contenu d’un jeu ni votre compte Apple."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack {
                    Link(tr("What is sent", "Ce qui est envoyé"), destination: BuilderTelemetry.privacy)
                    Spacer()
                    if let erased {
                        Text(erased ? tr("Erased.", "Effacé.") : tr("The server did not answer: try again later.", "Le serveur n’a pas répondu : réessayez plus tard."))
                            .foregroundStyle(.secondary)
                    }
                    Button(tr("Erase what this Mac sent…", "Effacer ce que ce Mac a envoyé…")) { askErase = true }
                        .disabled(telemetry.isErasing)
                }
                .font(.caption)
            } header: {
                Text(tr("Measures", "Mesures"))
            }
        }
        .formStyle(.grouped)
        .confirmationDialog(tr("Erase what this Mac sent?", "Effacer ce que ce Mac a envoyé ?"), isPresented: $askErase) {
            Button(tr("Erase", "Effacer"), role: .destructive) {
                Task { erased = await telemetry.erase() }
            }
        } message: {
            Text(tr("The server deletes every report of this Mac; the app then takes a new number.",
                    "Le serveur supprime tous les rapports de ce Mac ; l’app prend ensuite un nouveau numéro."))
        }
    }
}

/// What can be done with the update found: download it, or restart for it.
struct UpdateActions: View {
    @EnvironmentObject private var updater: Updater

    var body: some View {
        switch updater.state {
        case let .available(release):
            Link(tr("What’s new", "Nouveautés"), destination: release.page)
            Button(tr("Download \(release.version)", "Télécharger la \(release.version)")) {
                Task { await updater.download(release) }
            }
            .buttonStyle(.borderedProminent)
        case let .ready(release):
            Link(tr("What’s new", "Nouveautés"), destination: release.page)
            Button(tr("Restart to update", "Redémarrer pour mettre à jour")) {
                Task { await updater.install(relaunch: true) }
            }
            .buttonStyle(.borderedProminent)
        default:
            EmptyView()
        }
    }
}

struct UpdateStateText: View {
    @EnvironmentObject private var updater: Updater

    var body: some View {
        switch updater.state {
        case .idle:
            EmptyView()
        case .upToDate:
            Text(tr("up to date", "à jour"))
                .foregroundStyle(.secondary)
        case .checking:
            ProgressView().controlSize(.small)
        case let .available(release):
            Text(tr("\(release.version) available", "\(release.version) disponible"))
                .foregroundStyle(Theme.indigo)
        case let .downloading(release):
            Text(tr("downloading \(release.version)…", "téléchargement de la \(release.version)…"))
                .foregroundStyle(.secondary)
        case let .ready(release):
            Text(tr("\(release.version) ready: it installs when the app quits", "\(release.version) prête : elle s’installe quand l’app quitte"))
                .foregroundStyle(Theme.indigo)
        case .installing:
            Text(tr("installing…", "installation…"))
                .foregroundStyle(.secondary)
        case let .failed(text):
            Text(text)
                .foregroundStyle(.orange)
                .lineLimit(2)
        }
    }
}

struct FolderSettings: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        Form {
            Section {
                FolderField(title: tr("Game sources", "Sources des jeux"),
                            help: tr("Your games: packages, .nup files, dumps or zipped dumps, loose or in folders.", "Vos jeux : paquets, fichiers .nup, dumps ou dumps zippés, en vrac ou dans des dossiers."),
                            path: model.config?.sources ?? "") { path in model.update { $0.sources = path } }
                FolderField(title: tr("Games folder", "Dossier des jeux"),
                            help: tr("Where the IPAs go: the folder Cartouche reads, on this Mac or on your NAS.", "Où vont les IPA : le dossier que lit Cartouche, sur ce Mac ou sur votre NAS."),
                            path: model.config?.games ?? "") { path in model.update { $0.games = path } }
                KeysField()
            } header: {
                Text(tr("Your games", "Vos jeux"))
            } footer: {
                Text(tr("A folder on your NAS works: connect its share in the Finder once; Cartouche Builder connects it again by itself.",
                        "Un dossier sur votre NAS convient : connectez son partage dans le Finder une fois, Cartouche Builder le reconnecte ensuite tout seul."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section(tr("Builds", "Constructions")) {
                FolderField(title: tr("Build folders", "Dossiers de construction"),
                            help: tr("Where games are built; empty for Cartouche Builder’s own folder.", "Où les jeux se construisent ; vide pour le dossier de Cartouche Builder."),
                            path: model.config?.workspace ?? "", clearable: true) { path in model.update { $0.workspace = path } }
            }
        }
        .formStyle(.grouped)
    }
}

struct FolderField: View {
    let title: String
    let help: String
    let path: String
    var clearable = false
    let choose: (String) -> Void

    var body: some View {
        LabeledContent {
            HStack {
                Text(path.isEmpty ? tr("Not chosen", "Pas choisi") : (path as NSString).abbreviatingWithTildeInPath)
                    .foregroundStyle(path.isEmpty ? .secondary : .primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: 260, alignment: .trailing)
                if clearable && !path.isEmpty {
                    Button {
                        choose("")
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                    }
                    .buttonStyle(.borderless)
                }
                Button(tr("Choose…", "Choisir…")) {
                    if let url = FolderPicker.choose(title: title, directory: path.isEmpty ? nil : URL(fileURLWithPath: path)) {
                        choose(url.path)
                    }
                }
            }
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(help)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

/// prod.keys: whether it is chosen, never where it is.
struct KeysField: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        let chosen = !(model.config?.keys ?? "").isEmpty
        let present = model.library?.folders?.keys?.present ?? chosen
        LabeledContent {
            HStack {
                Label(chosen ? (present ? tr("Chosen", "Choisi") : tr("Not found", "Introuvable")) : tr("Not chosen", "Pas choisi"),
                      systemImage: chosen && present ? "checkmark.seal.fill" : "key")
                    .foregroundStyle(chosen && present ? Color.green : Color.secondary)
                Button(tr("Choose…", "Choisir…")) {
                    if let url = FolderPicker.chooseFile(title: "prod.keys") {
                        model.update { $0.keys = url.path }
                    }
                }
            }
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text("prod.keys")
                Text(tr("Your console’s keys, for games given as packages. They stay on this Mac.", "Les clés de votre console, pour les jeux en paquets. Elles restent sur ce Mac."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

struct BuildSettings: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        Form {
            Section {
                Picker(tr("When nxnative’s shared code changes", "Quand le code commun de nxnative change"), selection: setting(model, \.enginePolicy, "weekly")) {
                    Text(tr("Rebuild, at most every few days", "Reconstruire, au plus tous les quelques jours")).tag("weekly")
                    Text(tr("Rebuild each time", "Reconstruire à chaque fois")).tag("always")
                    Text(tr("Do not rebuild", "Ne pas reconstruire")).tag("never")
                }
                if model.config?.enginePolicy == "weekly" {
                    Stepper(value: setting(model, \.refreshDays, 7), in: 1...60) {
                        Text(tr("At most every \(model.config?.refreshDays ?? 7) days", "Au plus tous les \(model.config?.refreshDays ?? 7) jours"))
                    }
                }
            } header: {
                Text(tr("Rebuilds", "Reconstructions"))
            } footer: {
                Text(tr("A change to a game’s own profile, or a fix that names it, always rebuilds it.",
                        "Un changement du profil d’un jeu, ou un correctif qui le nomme, le reconstruit toujours."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section(tr("At night", "La nuit")) {
                Toggle(tr("Build what is due every night", "Construire ce qui est dû chaque nuit"), isOn: setting(model, \.schedule, false))
                DatePicker(tr("At", "À"), selection: Binding(get: { nightlyDate }, set: { date in
                    let parts = Calendar.current.dateComponents([.hour, .minute], from: date)
                    model.update {
                        $0.scheduleHour = parts.hour ?? 3
                        $0.scheduleMinute = parts.minute ?? 30
                    }
                }), displayedComponents: .hourAndMinute)
                .disabled(!(model.config?.schedule ?? false))
            }
            Section {
                Picker(tr("Games built at once", "Jeux construits en même temps"), selection: setting(model, \.jobs, 1)) {
                    ForEach(1...4, id: \.self) { Text("\($0)").tag($0) }
                }
                Picker(tr("Language of the games", "Langue des jeux"), selection: setting(model, \.gameLanguage, "")) {
                    ForEach(GameLanguages.all, id: \.code) { language in
                        Text(language.name).tag(language.code)
                    }
                }
                Toggle(tr("Also build games nxnative has no profile for (they may not start)", "Construire aussi les jeux sans profil nxnative (ils peuvent ne pas démarrer)"),
                       isOn: setting(model, \.unprofiled, false))
            } header: {
                Text(tr("Games", "Jeux"))
            } footer: {
                Text(tr("Cartouche starts each game in the iPhone’s language when the game has it; this one otherwise.",
                        "Cartouche lance chaque jeu dans la langue de l’iPhone quand le jeu l’a ; sinon dans celle-ci."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private var nightlyDate: Date {
        let config = model.config
        return Calendar.current.date(bySettingHour: config?.scheduleHour ?? 3, minute: config?.scheduleMinute ?? 30, second: 0, of: Date()) ?? Date()
    }
}

/// The languages nxnative's -l takes (its nacp.py's codes).
enum GameLanguages {
    struct Language {
        let code: String
        let name: String
    }

    static var all: [Language] {
        [
            Language(code: "", name: tr("nxnative’s (English)", "Celle de nxnative (anglais)")),
            Language(code: "fr", name: "Français"),
            Language(code: "fr-CA", name: "Français (Canada)"),
            Language(code: "en-US", name: "English (US)"),
            Language(code: "en-GB", name: "English (UK)"),
            Language(code: "de", name: "Deutsch"),
            Language(code: "it", name: "Italiano"),
            Language(code: "es", name: "Español"),
            Language(code: "es-419", name: "Español (Latinoamérica)"),
            Language(code: "nl", name: "Nederlands"),
            Language(code: "pt", name: "Português"),
            Language(code: "pt-BR", name: "Português (Brasil)"),
            Language(code: "ja", name: "日本語"),
            Language(code: "ko", name: "한국어"),
            Language(code: "zh-Hans", name: "简体中文"),
            Language(code: "zh-Hant", name: "繁體中文"),
            Language(code: "ru", name: "Русский"),
        ]
    }
}

struct StorageSettings: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        Form {
            Section {
                Stepper(value: setting(model, \.minFreeGB, 20), in: 0...500, step: 5) {
                    Text(tr("Keep at least \(model.config?.minFreeGB ?? 20) GB free", "Garder au moins \(model.config?.minFreeGB ?? 20) Go libres"))
                }
                Stepper(value: setting(model, \.workspaceLimitGB, 0), in: 0...2000, step: 10) {
                    let limit = model.config?.workspaceLimitGB ?? 0
                    Text(limit == 0 ? tr("No limit to the build folders", "Pas de limite aux dossiers de construction")
                                    : tr("Build folders: at most \(limit) GB", "Dossiers de construction : \(limit) Go au plus"))
                }
            } footer: {
                Text(tr("When the disk fills, the build folders used the longest ago go first.", "Quand le disque se remplit, les dossiers de construction utilisés il y a le plus longtemps partent d’abord."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section {
                Toggle(tr("Keep the extracted game files", "Garder les fichiers extraits des jeux"), isOn: setting(model, \.keepExtracted, false))
                Toggle(tr("Keep each IPA in its build folder, even on another disk", "Garder chaque IPA dans son dossier de construction, même sur un autre disque"),
                       isOn: setting(model, \.keepIPA, false))
            } footer: {
                Text(tr("Kept, the extracted files make the next build faster but take as much room as the game. On the games folder’s disk, an IPA copy takes no room.",
                        "Gardés, les fichiers extraits accélèrent la prochaine construction mais prennent autant de place que le jeu. Sur le disque du dossier des jeux, une copie d’IPA ne prend pas de place."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

struct AdvancedSettings: View {
    @EnvironmentObject private var model: AppModel
    @State private var url = ""
    @State private var branch = ""

    var body: some View {
        Form {
            Section {
                TextField(tr("Repository", "Dépôt"), text: $url)
                    .onSubmit { save() }
                TextField(tr("Branch", "Branche"), text: $branch)
                    .onSubmit { save() }
                HStack {
                    Button(tr("Back to nxnative’s", "Revenir à celui de nxnative")) {
                        url = BuilderConfig.engineURL
                        branch = BuilderConfig.engineBranch
                        save()
                    }
                    Spacer()
                    Button(tr("Save", "Enregistrer")) { save() }
                        .disabled(url == model.config?.engineURL && branch == model.config?.engineBranch)
                }
            } header: {
                Text("nxnative")
            } footer: {
                Text(tr("The nxnative games are built from. Change it only to try a fork.", "Le nxnative avec lequel les jeux sont construits. À changer seulement pour essayer une variante."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section(tr("Cartouche Builder", "Cartouche Builder")) {
                LabeledContent(tr("Version", "Version"), value: model.info?.version ?? "—")
                LabeledContent("Python", value: model.engine?.python.path ?? "—")
                Button(tr("Show its folder in the Finder", "Afficher son dossier dans le Finder")) { model.reveal(model.home.root.path) }
                Button(tr("Open the setup assistant", "Ouvrir l’assistant de configuration")) {
                    model.showMainWindow()
                    model.openSetup()
                }
            }
        }
        .formStyle(.grouped)
        .onAppear {
            url = model.config?.engineURL ?? BuilderConfig.engineURL
            branch = model.config?.engineBranch ?? BuilderConfig.engineBranch
        }
    }

    private func save() {
        let url = url.trimmingCharacters(in: .whitespaces)
        let branch = branch.trimmingCharacters(in: .whitespaces)
        guard !url.isEmpty, !branch.isEmpty else { return }
        model.update {
            $0.engineURL = url
            $0.engineBranch = branch
        }
    }
}

/// The Finder's panel, to choose a folder or a file.
@MainActor
enum FolderPicker {
    static func choose(title: String, directory: URL?) -> URL? {
        let panel = NSOpenPanel()
        panel.message = title
        panel.prompt = tr("Choose", "Choisir")
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        if let directory { panel.directoryURL = directory }
        return panel.runModal() == .OK ? panel.url : nil
    }

    static func chooseFile(title: String) -> URL? {
        let panel = NSOpenPanel()
        panel.message = title
        panel.prompt = tr("Choose", "Choisir")
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        return panel.runModal() == .OK ? panel.url : nil
    }
}
