//
//  SetupAssistant.swift
//  Cartouche Builder
//
//  The setup assistant: at the first start, until it is gone through to
//  its end, and from the settings. A step at a time: what the app does,
//  this Mac's tools, the folder of the dumps, the games folder on this Mac
//  or on a NAS, prod.keys, the builds at night, the iPhone, and what is
//  ready. Nothing is chosen for the player: every folder starts empty, and
//  nothing of another app's is read. Each choice is saved as it is made,
//  so the assistant opens again where the player left it, its steps on
//  the left with what is done and what is missing.
//

import AppKit
import BuilderKit
import SwiftUI

/// A step of the setup assistant, in order.
enum SetupStep: Int, CaseIterable, Identifiable {
    case welcome, tools, sources, games, keys, builds, iphone, done

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .welcome: return tr("Welcome", "Bienvenue")
        case .tools: return tr("This Mac’s tools", "Outils du Mac")
        case .sources: return tr("Your dumps", "Vos dumps")
        case .games: return tr("Games folder", "Dossier des jeux")
        case .keys: return tr("Keys", "Clés")
        case .builds: return tr("At night", "La nuit")
        case .iphone: return "iPhone"
        case .done: return tr("Ready", "Prêt")
        }
    }

    var symbol: String {
        switch self {
        case .welcome: return "hand.wave.fill"
        case .tools: return "wrench.and.screwdriver.fill"
        case .sources: return "tray.full.fill"
        case .games: return "externaldrive.fill.badge.checkmark"
        case .keys: return "key.fill"
        case .builds: return "moon.stars.fill"
        case .iphone: return "iphone.radiowaves.left.and.right"
        case .done: return "checkmark.seal.fill"
        }
    }

    /// A step a build cannot do without: missing, it is marked on the left.
    var isNeeded: Bool { [.tools, .sources, .games].contains(self) }

    var next: SetupStep? { SetupStep(rawValue: rawValue + 1) }
    var previous: SetupStep? { SetupStep(rawValue: rawValue - 1) }
}

/// Where a folder is: on this Mac (or a disk plugged into it), or on a
/// share of the network.
enum FolderPlace {
    case mac, nas

    /// Where PATH is, as far as the Mac can tell: a folder of a share not
    /// mounted now is under /Volumes too.
    static func of(_ path: String) -> FolderPlace {
        guard !path.isEmpty else { return .mac }
        let url = URL(fileURLWithPath: path)
        if let local = try? url.resourceValues(forKeys: [.volumeIsLocalKey]).volumeIsLocal {
            return local ? .mac : .nas
        }
        return path.hasPrefix("/Volumes/") ? .nas : .mac
    }
}

struct SetupAssistant: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var setup: MacSetup
    @EnvironmentObject private var bridge: BridgeController
    @State private var step: SetupStep
    /// The furthest step shown: the steps after it wait their turn.
    @State private var reached: SetupStep
    /// The place chosen for the dumps and for the games, before a folder is.
    @State private var places: [SetupStep: FolderPlace] = [:]
    @State private var sourcesCount: Int?
    @State private var problem: String?

    nonisolated static let size = CGSize(width: 820, height: 580)

    init(start: SetupStep = .welcome) {
        _step = State(initialValue: start)
        _reached = State(initialValue: start)
    }

    var body: some View {
        HStack(spacing: 0) {
            StepRail(step: step, reached: reached, mark: railMark) { chosen in go(chosen) }
                .frame(width: 214)
            Divider()
            VStack(spacing: 0) {
                // One page at a time, the next over the one leaving.
                ZStack(alignment: .topLeading) {
                    page
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                        .id(step)
                        .transition(AnyTransition.opacity.combined(with: AnyTransition.offset(x: 24)))
                }
                .padding(.horizontal, 32)
                .padding(.top, 30)
                .padding(.bottom, 12)
                .clipped()
                // What went wrong, which the window shows above its page,
                // under the assistant.
                if let banner = model.banner, banner.kind == .error {
                    Label(banner.text, systemImage: "exclamationmark.triangle.fill")
                        .font(.callout)
                        .foregroundStyle(.orange)
                        .lineLimit(2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 32)
                        .padding(.bottom, 10)
                }
                Divider()
                footer
            }
            .background(Color(nsColor: .windowBackgroundColor))
        }
        .frame(width: Self.size.width, height: Self.size.height)
        .interactiveDismissDisabled()
        .task(id: config.sources) { await countSources() }
    }

    private var config: BuilderConfig { model.config ?? BuilderConfig() }

    // MARK: Moving between the steps

    private func go(_ target: SetupStep) {
        problem = nil
        if model.banner?.kind == .error { model.banner = nil }
        withAnimation(.snappy(duration: 0.28)) {
            step = target
            if target.rawValue > reached.rawValue { reached = target }
        }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            if step != .done {
                Button(config.setupDone ? tr("Close", "Fermer") : tr("Later", "Plus tard")) { model.showSetup = false }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if let previous = step.previous {
                Button(tr("Back", "Retour")) { go(previous) }
                    .controlSize(.large)
            }
            Button(primaryTitle) {
                if let next = step.next { go(next) } else { model.finishSetup() }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .keyboardShortcut(typesAddress ? nil : .defaultAction)
            .disabled(step == .games && gamesProblem != nil)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    /// The page has the NAS's address field: Return connects the share
    /// typed, rather than going on.
    private var typesAddress: Bool {
        switch step {
        case .sources: return place(.sources, path: config.sources).wrappedValue == .nas
        case .games: return place(.games, path: config.games).wrappedValue == .nas
        default: return false
        }
    }

    private var primaryTitle: String {
        switch step {
        case .welcome: return tr("Start", "Commencer")
        case .done: return tr("Done", "Terminer")
        case .sources where config.sources.isEmpty, .games where config.games.isEmpty, .keys where config.keys.isEmpty:
            return tr("Skip", "Passer")
        default: return tr("Continue", "Continuer")
        }
    }

    /// How each step shows on the left.
    private func railMark(_ item: SetupStep) -> StepRail.Mark {
        if item == step { return .current }
        if item.rawValue > reached.rawValue { return .ahead }
        switch item {
        case .tools: return setup.ready ? .done : .missing
        case .sources: return config.sources.isEmpty ? .missing : .done
        case .games: return config.games.isEmpty ? .missing : .done
        default: return .done
        }
    }

    // MARK: The pages

    @ViewBuilder private var page: some View {
        switch step {
        case .welcome: welcome
        case .tools: tools
        case .sources: sources
        case .games: games
        case .keys: keys
        case .builds: builds
        case .iphone: iphone
        case .done: done
        }
    }

    private var welcome: some View {
        VStack(spacing: 18) {
            Spacer(minLength: 0)
            AppIconView()
                .frame(width: 112, height: 112)
                .shadow(color: Theme.indigo.opacity(0.25), radius: 16, y: 6)
            Text(tr("Welcome to Cartouche Builder", "Bienvenue dans Cartouche Builder"))
                .font(.largeTitle.weight(.bold))
                .multilineTextAlignment(.center)
            Text(tr("It builds your games for Cartouche on the iPhone, from your own files, and builds them again each time nxnative makes them better.",
                    "Il construit vos jeux pour Cartouche sur l’iPhone, à partir de vos propres fichiers, et les reconstruit à chaque fois que nxnative les améliore."))
                .font(.title3)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 13) {
                Feature(symbol: "sparkles", text: tr("Follows each of your games, and says when nxnative improved one.",
                                                     "Suit chacun de vos jeux, et vous dit quand nxnative en a amélioré un."))
                Feature(symbol: "externaldrive.connected.to.line.below", text: tr("Your games on this Mac or on your NAS, without filling the disk.",
                                                                                  "Vos jeux sur ce Mac ou sur votre NAS, sans remplir le disque."))
                Feature(symbol: "iphone.radiowaves.left.and.right", text: tr("Cartouche installs them from this Mac, over your Wi-Fi.",
                                                                             "Cartouche les installe depuis ce Mac, par votre Wi-Fi."))
            }
            .padding(.top, 4)
            Spacer(minLength: 0)
            Text(tr("A few short steps, and nothing is chosen for you: each folder starts empty.",
                    "Quelques étapes courtes, et rien n’est choisi à votre place : chaque dossier part vide."))
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
    }

    private var tools: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top) {
                StepHeader(step: .tools, title: tr("This Mac’s tools", "Les outils du Mac"),
                           text: tr("What nxnative builds with, installed for you. macOS may ask for your password, and Xcode comes from the App Store: the next steps can be done while it downloads.",
                                    "Ce avec quoi nxnative construit, installé pour vous. macOS peut demander votre mot de passe, et Xcode vient de l’App Store : les étapes suivantes se font pendant son téléchargement."))
                SetupButtons()
                    .padding(.top, 4)
            }
            ScrollView {
                SetupList()
                    .padding(.bottom, 4)
            }
        }
        .task { await setup.refresh() }
    }

    private var sources: some View {
        VStack(alignment: .leading, spacing: 16) {
            StepHeader(step: .sources, title: tr("Where are your dumps?", "Où sont vos dumps ?"),
                       text: tr("The folder your games are in: packages (.nsp, .xci, .nsz, .xcz), .nup files, dumps or zipped dumps, loose or in folders. Cartouche Builder only reads it.",
                                "Le dossier où sont vos jeux : paquets (.nsp, .xci, .nsz, .xcz), fichiers .nup, dumps ou dumps zippés, en vrac ou rangés dans des dossiers. Cartouche Builder ne fait que le lire."))
            PlaceChoice(place: place(.sources, path: config.sources),
                        mac: tr("A folder of this Mac, or of a disk plugged into it.", "Un dossier du Mac, ou d’un disque branché dessus."),
                        nas: tr("A shared folder on your network, connected again by itself.", "Un dossier partagé de votre réseau, reconnecté tout seul."))
            if place(.sources, path: config.sources).wrappedValue == .nas {
                ShareConnect { share in chooseFolder(.sources, from: share) }
            }
            ChosenFolder(title: tr("Dumps folder", "Dossier des dumps"), path: config.sources, detail: sourcesDetail) {
                chooseFolder(.sources, from: nil)
            }
        }
    }

    private var sourcesDetail: String? {
        guard !config.sources.isEmpty, let count = sourcesCount else { return nil }
        switch count {
        case 0: return tr("No game in it for now.", "Aucun jeu dedans pour l’instant.")
        case 1: return tr("1 game found", "1 jeu trouvé")
        default: return tr("\(count) games found", "\(count) jeux trouvés")
        }
    }

    private var games: some View {
        VStack(alignment: .leading, spacing: 16) {
            StepHeader(step: .games, title: tr("Where do your games go?", "Où vont vos jeux ?"),
                       text: tr("The folder where Cartouche Builder puts each game’s IPA, and that Cartouche reads on the iPhone.",
                                "Le dossier où Cartouche Builder dépose l’IPA de chaque jeu, et que Cartouche lit sur l’iPhone."))
            PlaceChoice(place: place(.games, path: config.games),
                        mac: tr("Cartouche installs them from this Mac, over the Wi-Fi.", "Cartouche les installe depuis ce Mac, par le Wi-Fi."),
                        nas: tr("Cartouche reads them on the NAS, even while this Mac sleeps.", "Cartouche les lit sur le NAS, même quand le Mac dort."))
            if place(.games, path: config.games).wrappedValue == .nas {
                ShareConnect { share in chooseFolder(.games, from: share) }
            } else if config.games.isEmpty {
                Button {
                    createGamesFolder()
                } label: {
                    Label(tr("Create “\(SetupAssistant.gamesFolderName)” in your home folder", "Créer « \(SetupAssistant.gamesFolderName) » dans votre dossier personnel"),
                          systemImage: "folder.badge.plus")
                }
                .controlSize(.large)
            }
            ChosenFolder(title: tr("Games folder", "Dossier des jeux"), path: config.games, detail: nil) {
                chooseFolder(.games, from: nil)
            }
            if let text = gamesProblem ?? problem {
                Label(text, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.orange)
            }
        }
    }

    /// The games folder's name the assistant offers in the home folder.
    static var gamesFolderName: String { tr("Cartouche Games", "Jeux Cartouche") }

    /// What keeps the games folder chosen from working, as the engine says
    /// it (config.py, problems).
    private var gamesProblem: String? {
        let sources = config.sources, games = config.games
        guard !sources.isEmpty, !games.isEmpty else { return nil }
        let a = URL(fileURLWithPath: sources).standardizedFileURL.path
        let b = URL(fileURLWithPath: games).standardizedFileURL.path
        if a == b {
            return tr("Choose a folder other than the dumps’ one.", "Choisissez un autre dossier que celui des dumps.")
        }
        if b.hasPrefix(a.hasSuffix("/") ? a : a + "/") {
            return tr("The games folder cannot be inside the dumps folder.", "Le dossier des jeux ne peut pas être dans celui des dumps.")
        }
        return nil
    }

    private var keys: some View {
        let chosen = !config.keys.isEmpty
        let present = model.library?.folders?.keys?.present ?? chosen
        return VStack(alignment: .leading, spacing: 18) {
            StepHeader(step: .keys, title: tr("Your console’s keys", "Les clés de votre console"),
                       text: tr("prod.keys, for games given as packages (.nsp, .xci, .nsz, .xcz). A dump or a .nup needs none.",
                                "Le fichier prod.keys, pour les jeux en paquets (.nsp, .xci, .nsz, .xcz). Un dump ou un .nup n’en a pas besoin."))
            Card(padding: 14) {
                HStack(spacing: 12) {
                    Image(systemName: chosen && present ? "checkmark.seal.fill" : "key.fill")
                        .font(.title2)
                        .foregroundStyle(chosen && present ? Color.green : Color.secondary)
                        .frame(width: 30)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("prod.keys")
                            .font(.callout.weight(.semibold))
                        Text(chosen ? (present ? tr("Chosen", "Choisi") : tr("Not found where it was chosen", "Introuvable là où il a été choisi"))
                                    : tr("Not chosen", "Pas choisi"))
                            .font(.callout)
                            .foregroundStyle(chosen && !present ? Color.orange : Color.secondary)
                    }
                    Spacer(minLength: 8)
                    Button(chosen ? tr("Change…", "Changer…") : tr("Choose the file…", "Choisir le fichier…")) {
                        if let url = FolderPicker.chooseFile(title: "prod.keys") {
                            model.update { $0.keys = url.path }
                        }
                    }
                    .controlSize(.large)
                }
            }
            Label(tr("They stay on this Mac: Cartouche Builder hands them to nxnative for your builds and sends them nowhere.",
                     "Elles restent sur ce Mac : Cartouche Builder les donne à nxnative pour vos constructions et ne les envoie nulle part."),
                  systemImage: "lock.fill")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var builds: some View {
        VStack(alignment: .leading, spacing: 18) {
            StepHeader(step: .builds, title: tr("Build at night", "Construire la nuit"),
                       text: tr("Cartouche Builder follows every game of your dumps folder and says when nxnative improves one. It can also build them at night, while you sleep.",
                                "Cartouche Builder suit chaque jeu de votre dossier des dumps et vous dit quand nxnative en améliore un. Il peut aussi les construire la nuit, pendant que vous dormez."))
            Card(padding: 16) {
                VStack(alignment: .leading, spacing: 12) {
                    SwitchRow(title: tr("Build what is due every night", "Construire chaque nuit ce qui est à reconstruire"), symbol: "moon.stars",
                              isOn: setting(model, \.schedule, false))
                    DatePicker(tr("At", "À"), selection: Binding(get: { nightly }, set: { date in
                        let parts = Calendar.current.dateComponents([.hour, .minute], from: date)
                        model.update {
                            $0.scheduleHour = parts.hour ?? 3
                            $0.scheduleMinute = parts.minute ?? 30
                        }
                    }), displayedComponents: .hourAndMinute)
                    .disabled(!config.schedule)
                    Text(tr("The Mac stays awake while it builds; asleep at that time, it builds when it wakes.",
                            "Le Mac reste éveillé le temps des constructions ; endormi à cette heure-là, il construit à son réveil."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Card(padding: 16) {
                SwitchRow(title: tr("Tell me when a build ends or nxnative improves a game", "Me prévenir quand une construction finit ou que nxnative améliore un jeu"),
                          symbol: "bell.badge", isOn: setting(model, \.notifications, true))
            }
        }
    }

    private var nightly: Date {
        Calendar.current.date(bySettingHour: config.scheduleHour, minute: config.scheduleMinute, second: 0, of: Date()) ?? Date()
    }

    private var iphone: some View {
        VStack(alignment: .leading, spacing: 16) {
            StepHeader(step: .iphone, title: tr("Cartouche on the iPhone", "Cartouche sur l’iPhone"),
                       text: tr("This Mac can be one of Cartouche’s storage places: the iPhone installs your games from it and keeps your saves on it, encrypted on the way.",
                                "Ce Mac peut devenir un stockage de Cartouche : l’iPhone y installe vos jeux et y garde vos sauvegardes, chiffrées en chemin."))
            Card(padding: 16) {
                VStack(alignment: .leading, spacing: 12) {
                    SwitchRow(title: tr("Share with Cartouche on the iPhone", "Partager avec Cartouche sur l’iPhone"), symbol: "iphone.radiowaves.left.and.right",
                              isOn: Binding(get: { bridge.enabled }, set: { bridge.setEnabled($0) }))
                    if bridge.enabled {
                        Divider()
                        HowTo(number: 1, text: tr("In Cartouche: System › Storage › Add your Mac (Cartouche Builder).",
                                                  "Dans Cartouche : Système › Stockage › Ajouter votre Mac (Cartouche Builder)."))
                        HowTo(number: 2, text: tr("Choose “\(bridge.name)” under Macs nearby.", "Choisissez « \(bridge.name) » sous Macs à proximité."))
                        HowTo(number: 3, text: tr("Both screens show six digits: when they match, click Allow here.",
                                                  "Les deux écrans affichent six chiffres : s’ils sont les mêmes, cliquez sur Autoriser ici."))
                    }
                }
            }
            Card(padding: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    SwitchRow(title: tr("Open Cartouche Builder at login", "Ouvrir Cartouche Builder à l’ouverture de session"), symbol: "power",
                              isOn: Binding(get: { model.opensAtLogin }, set: { model.setOpensAtLogin($0) }))
                    Text(tr("The iPhone finds this Mac while the app is open, in the menu bar too.",
                            "L’iPhone trouve ce Mac tant que l’app est ouverte, même dans la barre des menus seulement."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            if FolderPlace.of(config.games) == .nas, !config.games.isEmpty {
                Label(tr("Your games folder is on a NAS: Cartouche can also read it there (System › Storage), even while this Mac sleeps.",
                         "Votre dossier des jeux est sur un NAS : Cartouche peut aussi le lire là-bas (Système › Stockage), même quand le Mac dort."),
                      systemImage: "info.circle")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var done: some View {
        let complete = setup.ready && !config.sources.isEmpty && !config.games.isEmpty
        return VStack(alignment: .leading, spacing: 16) {
            StepHeader(step: .done, title: complete ? tr("All set", "Tout est prêt") : tr("Almost there", "Presque prêt"),
                       text: complete
                           ? tr("Your games show in the library. Build one now, or let the night do it.",
                                "Vos jeux s’affichent dans la bibliothèque. Construisez-en un maintenant, ou laissez la nuit s’en charger.")
                           : tr("What is missing can be finished later, from the library or here.",
                                "Ce qui manque se termine plus tard, depuis la bibliothèque ou ici."))
            Card(padding: 6) {
                VStack(spacing: 0) {
                    SummaryRow(step: .tools, value: toolsSummary, ok: setup.ready) { go(.tools) }
                    Divider().padding(.leading, 48)
                    SummaryRow(step: .sources, value: folderSummary(config.sources), ok: !config.sources.isEmpty) { go(.sources) }
                    Divider().padding(.leading, 48)
                    SummaryRow(step: .games, value: folderSummary(config.games), ok: !config.games.isEmpty) { go(.games) }
                    Divider().padding(.leading, 48)
                    SummaryRow(step: .keys, value: config.keys.isEmpty ? tr("Not chosen", "Pas choisi") : tr("Chosen", "Choisi"), ok: true) { go(.keys) }
                    Divider().padding(.leading, 48)
                    SummaryRow(step: .builds, value: config.schedule
                        ? tr("Every night at \(clock)", "Chaque nuit à \(clock)")
                        : tr("Only when you ask", "Seulement quand vous le demandez"), ok: true) { go(.builds) }
                    Divider().padding(.leading, 48)
                    SummaryRow(step: .iphone, value: bridge.enabled ? tr("Shared with Cartouche", "Partagé avec Cartouche") : tr("Not shared", "Pas partagé"),
                               ok: true) { go(.iphone) }
                }
            }
        }
    }

    private var toolsSummary: String {
        if setup.ready { return tr("Ready", "Prêts") }
        if setup.running { return tr("Installing…", "Installation en cours…") }
        let missing = setup.missingCount
        return missing == 1 ? tr("1 to install", "1 à installer") : tr("\(missing) to install", "\(missing) à installer")
    }

    private func folderSummary(_ path: String) -> String {
        path.isEmpty ? tr("To choose", "À choisir") : (path as NSString).abbreviatingWithTildeInPath
    }

    private var clock: String {
        String(format: "%02d:%02d", config.scheduleHour, config.scheduleMinute)
    }

    // MARK: Folders

    /// Where the folder of STEP is chosen to be: as the player said, or
    /// where it is.
    private func place(_ step: SetupStep, path: String) -> Binding<FolderPlace> {
        Binding(get: { places[step] ?? FolderPlace.of(path) },
                set: { places[step] = $0 })
    }

    /// The Finder's panel for the folder of STEP, at SHARE when given.
    private func chooseFolder(_ step: SetupStep, from share: URL?) {
        problem = nil
        let current = step == .sources ? config.sources : config.games
        let start = share ?? (current.isEmpty ? nil : URL(fileURLWithPath: current))
        let title = step == .sources ? tr("The folder your dumps are in", "Le dossier de vos dumps")
                                     : tr("Where your games go", "Où vont vos jeux")
        guard let url = FolderPicker.choose(title: title, directory: start) else { return }
        model.update {
            if step == .sources { $0.sources = url.path } else { $0.games = url.path }
        }
    }

    private func createGamesFolder() {
        let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(SetupAssistant.gamesFolderName, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            model.update { $0.games = url.path }
        } catch {
            problem = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    private func countSources() async {
        sourcesCount = nil
        let path = config.sources
        guard !path.isEmpty else { return }
        if model.sample {
            sourcesCount = model.library?.games.filter { $0.source != nil }.count
        } else {
            sourcesCount = await SetupFiles.countGames(at: path)
        }
    }
}

// MARK: The parts of the assistant

/// The steps, on the left: each with its number, a tick once done, and a
/// mark when a step a build needs was left without its choice.
struct StepRail: View {
    enum Mark { case current, done, missing, ahead }

    let step: SetupStep
    let reached: SetupStep
    let mark: (SetupStep) -> Mark
    let go: (SetupStep) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 10) {
                AppIconView()
                    .frame(width: 34, height: 34)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Cartouche Builder")
                        .font(.headline)
                    Text(tr("Setup", "Configuration"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.bottom, 20)
            ForEach(SetupStep.allCases) { item in
                Button {
                    go(item)
                } label: {
                    row(item, mark(item))
                }
                .buttonStyle(.plain)
                .disabled(item.rawValue > reached.rawValue)
            }
            Spacer(minLength: 0)
            Text(tr("Everything here can be changed later in the settings.", "Tout ceci se change ensuite dans les réglages."))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(18)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(
            LinearGradient(colors: [Theme.indigo.opacity(0.11), Theme.pink.opacity(0.06)], startPoint: .topLeading, endPoint: .bottomTrailing)
        )
    }

    private func row(_ item: SetupStep, _ state: Mark) -> some View {
        HStack(spacing: 10) {
            ZStack {
                Circle()
                    .fill(fill(state))
                    .frame(width: 22, height: 22)
                switch state {
                case .done:
                    Image(systemName: "checkmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(Color.white)
                case .missing:
                    Image(systemName: "exclamationmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(Color.white)
                case .current:
                    Text(verbatim: "\(item.rawValue + 1)")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(Color.white)
                case .ahead:
                    Text(verbatim: "\(item.rawValue + 1)")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Color.secondary)
                }
            }
            Text(item.title)
                .font(.callout.weight(state == .current ? .semibold : .regular))
                .foregroundStyle(state == .ahead ? Color.secondary : Color.primary)
            Spacer(minLength: 0)
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 8)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(state == .current ? Theme.indigo.opacity(0.16) : Color.clear)
        )
        .contentShape(Rectangle())
    }

    private func fill(_ state: Mark) -> Color {
        switch state {
        case .current: return Theme.indigo
        case .done: return Color.green
        case .missing: return Color.orange
        case .ahead: return Color.secondary.opacity(0.18)
        }
    }
}

/// A step's symbol, title and what it is about.
struct StepHeader: View {
    let step: SetupStep
    let title: String
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            Image(systemName: step.symbol)
                .font(.system(size: 24, weight: .semibold))
                .foregroundStyle(Color.white)
                .frame(width: 52, height: 52)
                .background(RoundedRectangle(cornerRadius: 13, style: .continuous).fill(Theme.gradient))
            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                    .font(.title.weight(.bold))
                Text(text)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
    }
}

/// On this Mac, or on a NAS: two cards, one chosen.
struct PlaceChoice: View {
    @Binding var place: FolderPlace
    let mac: String
    let nas: String

    var body: some View {
        HStack(spacing: 12) {
            card(.mac, symbol: "laptopcomputer", title: tr("On this Mac", "Sur ce Mac"), text: mac)
            card(.nas, symbol: "server.rack", title: tr("On a NAS", "Sur un NAS"), text: nas)
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private func card(_ value: FolderPlace, symbol: String, title: String, text: String) -> some View {
        let chosen = place == value
        return Button {
            withAnimation(.snappy) { place = value }
        } label: {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: symbol)
                    .font(.title2)
                    .foregroundStyle(chosen ? Theme.indigo : Color.secondary)
                    .frame(width: 30)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.headline)
                    Text(text)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                Image(systemName: chosen ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(chosen ? Theme.indigo : Color.secondary.opacity(0.5))
            }
            .padding(14)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(chosen ? Theme.indigo : Color.primary.opacity(0.1), lineWidth: chosen ? 2 : 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}

/// A folder chosen, or not yet, and the button that opens the Finder's panel.
struct ChosenFolder: View {
    let title: String
    let path: String
    let detail: String?
    let choose: () -> Void

    var body: some View {
        Card(padding: 14) {
            HStack(spacing: 12) {
                Image(systemName: path.isEmpty ? "folder.badge.questionmark" : "folder.fill")
                    .font(.title2)
                    .foregroundStyle(path.isEmpty ? Color.secondary : Theme.indigo)
                    .frame(width: 30)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.callout.weight(.semibold))
                    Text(path.isEmpty ? tr("Not chosen yet", "Pas encore choisi") : (path as NSString).abbreviatingWithTildeInPath)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if let detail {
                        Text(detail)
                            .font(.caption.weight(.medium))
                            .foregroundStyle(Theme.indigo)
                    }
                }
                Spacer(minLength: 8)
                Button(path.isEmpty ? tr("Choose…", "Choisir…") : tr("Change…", "Changer…"), action: choose)
                    .controlSize(.large)
            }
        }
    }
}

/// A NAS's share: its address to connect it, and the shares connected now,
/// to choose a folder in.
struct ShareConnect: View {
    @EnvironmentObject private var model: AppModel
    let choose: (URL) -> Void
    @State private var address = ""
    @State private var shares: [NetworkShare] = []
    @State private var refused = false

    var body: some View {
        Card(padding: 14) {
            VStack(alignment: .leading, spacing: 10) {
                Text(tr("Connect your NAS’s share: macOS asks for its password once and keeps it in the keychain, and Cartouche Builder connects it again by itself, at night too.",
                        "Connectez le partage de votre NAS : macOS demande son mot de passe une fois et le garde dans le trousseau, puis Cartouche Builder le reconnecte tout seul, la nuit aussi."))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    TextField(tr("Address", "Adresse"), text: $address, prompt: Text(verbatim: "smb://nas.local/" + tr("Games", "Jeux")))
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(connect)
                    Button(tr("Connect", "Se connecter"), action: connect)
                        .disabled(address.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                if refused {
                    Text(tr("An address such as smb://nas.local/Games.", "Une adresse comme smb://nas.local/Jeux."))
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                if !shares.isEmpty {
                    Text(tr("Connected now: choose the folder in one", "Connectés maintenant : choisissez le dossier dans l’un d’eux"))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    ForEach(shares) { share in
                        Button {
                            choose(share.url)
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: "server.rack")
                                    .foregroundStyle(Theme.indigo)
                                Text(share.name)
                                    .font(.callout.weight(.medium))
                                if !share.address.isEmpty {
                                    Text(share.address)
                                        .font(.callout)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer(minLength: 0)
                                Image(systemName: "chevron.right")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.vertical, 6)
                            .padding(.horizontal, 10)
                            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(0.05)))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .onAppear(perform: refresh)
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didMountNotification)) { _ in refresh() }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didUnmountNotification)) { _ in refresh() }
    }

    private func refresh() {
        shares = model.sample ? NetworkShare.samples : NetworkShare.mounted()
    }

    /// Asks macOS to connect the share typed: the Finder asks for its
    /// password, and the share shows above once it is mounted.
    private func connect() {
        guard let url = NetworkShare.address(address) else {
            refused = true
            return
        }
        refused = false
        NSWorkspace.shared.open(url)
    }
}

/// A share of the network mounted now: a NAS's, as the Finder shows it.
struct NetworkShare: Identifiable, Hashable {
    /// Where it is mounted.
    let url: URL
    let name: String
    /// Its address, without the user's name.
    let address: String

    var id: URL { url }

    /// The gallery's NAS.
    static let samples = [NetworkShare(url: URL(fileURLWithPath: "/Volumes/Jeux", isDirectory: true), name: "Jeux", address: "smb://nas.local/Jeux")]

    static func mounted() -> [NetworkShare] {
        let keys: [URLResourceKey] = [.volumeIsLocalKey, .volumeNameKey, .volumeURLForRemountingKey]
        let volumes = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) ?? []
        return volumes.compactMap { url in
            guard let values = try? url.resourceValues(forKeys: Set(keys)), values.volumeIsLocal == false else { return nil }
            var address = ""
            if let remount = values.volumeURLForRemounting, var parts = URLComponents(url: remount, resolvingAgainstBaseURL: false) {
                parts.user = nil
                parts.password = nil
                address = parts.string ?? ""
            }
            return NetworkShare(url: url, name: values.volumeName ?? url.lastPathComponent, address: address)
        }
    }

    /// The address TYPED as the Finder connects it: smb:// when it says no
    /// scheme; nil when it is not a share's.
    static func address(_ typed: String) -> URL? {
        var text = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if !text.contains("://") { text = "smb://" + text }
        guard let url = URL(string: text), let scheme = url.scheme?.lowercased(), ["smb", "afp", "nfs", "cifs"].contains(scheme),
              let host = url.host, !host.isEmpty else { return nil }
        return url
    }
}

/// A setting turned on or off: its symbol and title, its switch at the
/// end of the row.
struct SwitchRow: View {
    let title: String
    let symbol: String
    @Binding var isOn: Bool

    var body: some View {
        HStack(spacing: 12) {
            Label(title, systemImage: symbol)
                .font(.headline)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 12)
            Toggle(title, isOn: $isOn)
                .labelsHidden()
                .toggleStyle(.switch)
        }
    }
}

/// A numbered line of a how-to.
struct HowTo: View {
    let number: Int
    let text: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(verbatim: "\(number)")
                .font(.caption.weight(.bold))
                .foregroundStyle(Color.white)
                .frame(width: 20, height: 20)
                .background(Circle().fill(Theme.indigo))
            Text(text)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// A line of the last step: what a step chose, and a button back to it.
struct SummaryRow: View {
    let step: SetupStep
    let value: String
    let ok: Bool
    let change: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: step.symbol)
                .font(.callout)
                .foregroundStyle(ok ? Theme.indigo : Color.orange)
                .frame(width: 26)
            Text(step.title)
                .font(.callout.weight(.semibold))
            Spacer(minLength: 12)
            Text(value)
                .font(.callout)
                .foregroundStyle(ok ? Color.secondary : Color.orange)
                .lineLimit(1)
                .truncationMode(.middle)
            Button(tr("Change", "Modifier"), action: change)
                .controlSize(.small)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
    }
}

/// The files the assistant looks at, away from the main thread.
enum SetupFiles {
    static let packageExtensions: Set<String> = ["nsp", "xci", "nsz", "xcz"]
    /// How deep games are looked for, as the engine does (library.py).
    static let depth = 4

    /// How many games the dumps folder at PATH holds, as the engine finds
    /// them (library.py), loose or in folders of folders: each .nup, each
    /// dump folder and zipped dump, and the packages of each game, known by
    /// the title ID in their names or their folder's; nil when it cannot be
    /// read. The engine reads a file named without its ID in the file
    /// itself: here each counts as a game.
    static func countGames(at path: String) async -> Int? {
        let url = URL(fileURLWithPath: path, isDirectory: true)
        return await Task.detached(priority: .utility) { () -> Int? in
            guard (try? FileManager.default.contentsOfDirectory(atPath: url.path)) != nil else { return nil }
            var named = Set<String>()
            var unnamed = 0
            SetupFiles.count(url, top: true, depth: 0, named: &named, unnamed: &unnamed)
            return named.count + unnamed
        }.value
    }

    private static func count(_ folder: URL, top: Bool, depth: Int, named: inout Set<String>, unnamed: inout Int) {
        guard let items = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isDirectoryKey],
                                                                       options: [.skipsHiddenFiles]) else { return }
        var files: [URL] = [], folders: [URL] = []
        for item in items.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            if (try? item.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
                let name = item.lastPathComponent
                if !(name.lowercased().hasSuffix("_build") || name.lowercased().hasSuffix("_dump") || name == "__MACOSX") { folders.append(item) }
            } else {
                files.append(item)
            }
        }
        let packages = files.filter { SetupFiles.packageExtensions.contains($0.pathExtension.lowercased()) }
        let nups = files.filter { $0.pathExtension.lowercased() == "nup" }
        if !packages.isEmpty {
            let folderID = top ? nil : SetupFiles.baseTitleID(in: folder.lastPathComponent)
            let ids = Set(packages.compactMap { SetupFiles.baseTitleID(in: $0.lastPathComponent) })
            if !top, let id = folderID ?? (ids.count == 1 ? ids.first : nil), ids.isSubset(of: [id]) {
                named.insert(id)
            } else {
                named.formUnion(ids)
                unnamed += packages.filter { SetupFiles.baseTitleID(in: $0.lastPathComponent) == nil }.count
            }
        }
        for nup in nups {
            if let id = SetupFiles.baseTitleID(in: nup.lastPathComponent) ?? (nups.count == 1 && packages.isEmpty && !top ? SetupFiles.baseTitleID(in: folder.lastPathComponent) : nil) {
                named.insert(id)
            } else {
                unnamed += 1
            }
        }
        if packages.isEmpty && nups.isEmpty {
            if SetupFiles.isDump(folder) {
                unnamed += 1
                return
            }
            unnamed += files.filter { $0.pathExtension.lowercased() == "zip" }.count
        }
        guard depth < SetupFiles.depth else { return }
        for sub in folders { SetupFiles.count(sub, top: false, depth: depth + 1, named: &named, unnamed: &unnamed) }
    }

    /// Whether FOLDER is laid out as nxnative takes a dump (library.is_dump).
    private static func isDump(_ folder: URL) -> Bool {
        let manager = FileManager.default
        let has = { (path: String) in manager.fileExists(atPath: folder.appendingPathComponent(path).path) }
        let versions = ((try? manager.contentsOfDirectory(atPath: folder.appendingPathComponent("updates").path)) ?? []).filter { Int($0) != nil }
        if has("base/exefs/main.npdm") {
            return has("base/romfs") || versions.contains { has("updates/\($0)/romfs") }
        }
        if has("exefs/main.npdm") && has("romfs") { return true }
        return versions.contains { has("updates/\($0)/exefs/main.npdm") && has("updates/\($0)/romfs") }
    }

    /// The base game of the first title ID a name carries, as the engine
    /// reads it (titles.py): an update's or a DLC's ID gives its game's.
    static func baseTitleID(in name: String) -> String? {
        guard let match = name.range(of: "(?<![0-9A-Fa-f])[0-9A-Fa-f]{16}(?![0-9A-Fa-f])", options: .regularExpression),
              let value = UInt64(name[match], radix: 16) else { return nil }
        let low = value & 0xFFF
        let base = low == 0 ? value : low == 0x800 ? value & ~0xFFF : (value & ~0xFFF) &- 0x1000
        return String(format: "%016llX", base)
    }
}

struct Feature: View {
    let symbol: String
    let text: String

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: symbol)
                .font(.title2)
                .foregroundStyle(Theme.gradient)
                .frame(width: 32)
            Text(text)
                .font(.body)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// The app's icon, as the Finder shows it.
struct AppIconView: View {
    var body: some View {
        Image(nsImage: NSApp.applicationIconImage ?? NSImage())
            .resizable()
            .aspectRatio(contentMode: .fit)
    }
}
