//
//  LibraryView.swift
//  Cartouche Builder
//
//  Every game: those of the sources folder and those of the games folder
//  that have only their IPA, by their covers, with what nxnative improved
//  and a button that rebuilds them, or adds them to the build running. A
//  game chosen opens its sheet beside them, and chosen again closes it.
//

import BuilderKit
import SwiftUI

enum LibraryFilter: String, CaseIterable, Identifiable {
    case all, due, upToDate, problems

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: return tr("All", "Tous")
        case .due: return tr("To rebuild", "À reconstruire")
        case .upToDate: return tr("Up to date", "À jour")
        case .problems: return tr("To look at", "À regarder")
        }
    }

    func keeps(_ game: Game) -> Bool {
        switch self {
        case .all: return true
        case .due: return game.state == .due || game.state == .building || game.state == .queued
        case .upToDate: return game.state == .upToDate
        case .problems: return [GameState.failed, .noProfile, .notFollowed].contains(game.state)
        }
    }
}

struct LibraryView: View {
    @EnvironmentObject private var model: AppModel
    @State private var filter: LibraryFilter = .all
    @State private var search = ""

    private var games: [Game] {
        let all = model.library?.games ?? []
        let words = search.trimmingCharacters(in: .whitespaces)
        return all.filter { game in
            filter.keeps(game) && (words.isEmpty || game.name.localizedCaseInsensitiveContains(words) || game.titleID.localizedCaseInsensitiveContains(words))
        }
    }

    var body: some View {
        HStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    PageHeader(title: tr("Library", "Bibliothèque"), subtitle: subtitle) {
                        FilterPicker(filter: $filter)
                    }
                    if let problems = model.library?.problems, !problems.isEmpty {
                        ProblemsCard(problems: problems)
                    }
                    if filter == .all || filter == .problems, let issues = model.library?.issues, !issues.isEmpty {
                        IssuesCard(issues: issues, open: model.library?.games.isEmpty ?? true)
                    }
                    if filter != .upToDate, !model.dueOutsideBatch.isEmpty {
                        DueCard(due: model.dueOutsideBatch)
                    }
                    if model.library == nil {
                        LoadingCard()
                    } else if games.isEmpty {
                        EmptyLibrary(filter: filter, searching: !search.isEmpty)
                    } else {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 150, maximum: 190), spacing: 22, alignment: .top)], alignment: .leading, spacing: 26) {
                            ForEach(games) { game in
                                GameCard(game: game, selected: model.selection == game.titleID)
                                    .onTapGesture { model.selection = model.selection == game.titleID ? nil : game.titleID }
                                    .contextMenu { GameMenu(game: game) }
                            }
                        }
                    }
                }
                .padding(28)
            }
            // The game's sheet, in a column of its own width (Columns): not
            // the system's inspector, which on macOS 27 made the page wider
            // than the window until AppKit ended the app.
            if let game = model.game(model.selection) {
                Divider()
                GameDetailView(game: game)
                    .frame(width: Columns.sheet)
                    .transition(.move(edge: .trailing))
            }
        }
        .animation(.snappy(duration: 0.25), value: model.selection != nil)
        .searchable(text: $search, placement: .toolbar, prompt: tr("Search a game", "Chercher un jeu"))
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                if model.isBuilding {
                    Button {
                        model.section = .activity
                    } label: {
                        Label(tr("Builds", "Constructions"), systemImage: "hammer.fill")
                    }
                } else {
                    Button {
                        model.build()
                    } label: {
                        Label(tr("Rebuild what is due", "Reconstruire ce qui est dû"), systemImage: "sparkles")
                    }
                    .disabled(!model.canBuild || model.dueOutsideBatch.isEmpty)
                    .help(tr("Builds every game nxnative improved", "Construit chaque jeu que nxnative a amélioré"))
                }
            }
        }
    }

    private var subtitle: String {
        guard let library = model.library else { return tr("Reading your games…", "Lecture de vos jeux…") }
        let count = library.games.count
        let gamesText = tr("\(count) game\(count == 1 ? "" : "s")", "\(count) jeu\(count == 1 ? "" : "x")")
        var parts = [gamesText]
        // While a batch builds: its games, and those still to rebuild.
        let states = library.games.compactMap { model.progress($0.titleID)?.state }
        let building = states.filter { $0 == "building" }.count
        let waiting = states.filter { $0 == "queued" }.count
        if building > 0 { parts.append(tr("\(building) building", "\(building) en construction")) }
        if waiting > 0 { parts.append(tr("\(waiting) waiting", "\(waiting) en attente")) }
        let due = model.dueOutsideBatch.count
        if due > 0 { parts.append(tr("\(due) to rebuild", "\(due) à reconstruire")) }
        guard parts.count > 1 else { return gamesText + tr(", all up to date", ", tous à jour") }
        return parts.joined(separator: " · ")
    }
}

/// Which games the library shows: in segments, or in a menu when the page
/// is too narrow for them.
struct FilterPicker: View {
    @Binding var filter: LibraryFilter

    var body: some View {
        ViewThatFits(in: .horizontal) {
            picker
                .pickerStyle(.segmented)
                .fixedSize()
            picker
                .pickerStyle(.menu)
                .fixedSize()
        }
    }

    private var picker: some View {
        Picker(tr("Show", "Afficher"), selection: $filter) {
            ForEach(LibraryFilter.allCases) { Text($0.title).tag($0) }
        }
        .labelsHidden()
    }
}

/// A game's cover, its name and how it is.
struct GameCard: View {
    @EnvironmentObject private var model: AppModel
    let game: Game
    let selected: Bool
    @State private var hovering = false

    var body: some View {
        let progress = model.progress(game.titleID)
        let look = GameLook(game, progress: progress)
        VStack(alignment: .leading, spacing: 8) {
            CoverView(game: game)
                .overlay(alignment: .topTrailing) {
                    Image(systemName: look.symbol)
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(.white, look.color)
                        .symbolRenderingMode(.palette)
                        .padding(5)
                        .background(Circle().fill(.ultraThinMaterial))
                        .padding(8)
                        .opacity(game.state == .upToDate && progress == nil ? 0 : 1)
                }
                .overlay(alignment: .bottom) {
                    if let progress, progress.state == "building" {
                        ProgressView(value: progress.overall ?? progress.frac ?? 0)
                            .progressViewStyle(.linear)
                            .tint(.white)
                            .padding(10)
                            .background(LinearGradient(colors: [.clear, .black.opacity(0.55)], startPoint: .top, endPoint: .bottom))
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(selected ? Theme.indigo : Color.primary.opacity(0.08), lineWidth: selected ? 3 : 1)
                )
                .shadow(color: .black.opacity(hovering ? 0.28 : 0.16), radius: hovering ? 12 : 6, y: hovering ? 6 : 3)
                .scaleEffect(hovering ? 1.025 : 1)
            Text(game.name)
                .font(.callout.weight(.semibold))
                .lineLimit(2)
                .multilineTextAlignment(.leading)
            HStack(spacing: 5) {
                Circle()
                    .fill(look.color)
                    .frame(width: 7, height: 7)
                Text(look.text)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .contentShape(Rectangle())
        .onHover { inside in
            withAnimation(.snappy(duration: 0.18)) { hovering = inside }
        }
    }
}

/// The cover, or the game's icon, or its initials on Cartouche's colours.
struct CoverView: View {
    @EnvironmentObject private var covers: CoverStore
    let game: Game
    var corner: CGFloat = 0

    var body: some View {
        ZStack {
            if let image = covers.image(game.titleID) {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                Theme.gradient
                Text(initials)
                    .font(.system(size: 34, weight: .heavy, design: .rounded))
                    .foregroundStyle(.white.opacity(0.92))
                    .padding(12)
                    .multilineTextAlignment(.center)
            }
        }
        .aspectRatio(3 / 4, contentMode: .fit)
        .frame(maxWidth: .infinity)
        .clipped()
        .task(id: game.titleID) {
            await covers.load(game.titleID, icon: game.icon)
        }
    }

    private var initials: String {
        let words = game.name.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).prefix(3)
        return words.compactMap(\.first).map(String.init).joined().uppercased()
    }
}

/// The games nxnative improved, and one button for all of them, which adds
/// them to the build running if one is: in a row, the button under them
/// when the page is narrower, and the covers above the words when it is
/// narrower still.
struct DueCard: View {
    @EnvironmentObject private var model: AppModel
    let due: [Game]

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 18) {
                covers
                texts
                    .frame(idealWidth: 260, maxWidth: .infinity, alignment: .leading)
                button
            }
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 14) {
                    covers
                    texts
                        .frame(idealWidth: 200, maxWidth: .infinity, alignment: .leading)
                }
                button
            }
            VStack(alignment: .leading, spacing: 12) {
                covers
                texts
                button
            }
        }
        .padding(18)
        .background(
            RoundedRectangle(cornerRadius: Theme.corner, style: .continuous)
                .fill(Theme.gradient)
                .opacity(0.14)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.corner, style: .continuous)
                .strokeBorder(Theme.indigo.opacity(0.25))
        )
    }

    private var covers: some View {
        HStack(spacing: -18) {
            ForEach(due.prefix(4)) { game in
                CoverView(game: game)
                    .frame(width: 54)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(.background, lineWidth: 2))
                    .shadow(radius: 3)
            }
        }
    }

    private var texts: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.headline)
                .fixedSize(horizontal: false, vertical: true)
            Text(names)
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
    }

    private var button: some View {
        Button {
            model.build()
        } label: {
            Group {
                if model.isBuilding {
                    Label(due.count == 1 ? tr("Add it to the queue", "L’ajouter à la file") : tr("Add them to the queue", "Les ajouter à la file"),
                          systemImage: "text.badge.plus")
                } else {
                    Label(tr("Rebuild all", "Tout reconstruire"), systemImage: "sparkles")
                }
            }
            .padding(.horizontal, 6)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .disabled(!model.canBuild)
        .help(model.isBuilding ? tr("A build is running: these games are built after it, and after the games waiting.",
                                    "Une construction est en cours : ces jeux se construiront après elle, et après les jeux en attente.") : "")
    }

    private var title: String {
        let improved = due.filter { $0.reasons != ["new"] }.count
        if improved == 0 {
            return due.count == 1 ? tr("1 game to build", "1 jeu à construire") : tr("\(due.count) games to build", "\(due.count) jeux à construire")
        }
        return improved == 1 ? tr("nxnative improved 1 of your games", "nxnative a amélioré 1 de vos jeux")
            : tr("nxnative improved \(improved) of your games", "nxnative a amélioré \(improved) de vos jeux")
    }

    private var names: String {
        due.prefix(5).map(\.name).joined(separator: ", ") + (due.count > 5 ? "…" : "")
    }
}

/// What keeps the builder from working: folders not chosen or not there.
struct ProblemsCard: View {
    @EnvironmentObject private var model: AppModel
    let problems: [String]

    var body: some View {
        Card {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: "folder.badge.questionmark")
                    .font(.title)
                    .foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 6) {
                    Text(tr("Cartouche Builder needs your folders", "Cartouche Builder a besoin de vos dossiers"))
                        .font(.headline)
                    ForEach(problems, id: \.self) { problem in
                        Text(problem)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    ViewThatFits(in: .horizontal) {
                        HStack { buttons }
                        VStack(alignment: .leading) { buttons }
                    }
                    .padding(.top, 4)
                }
            }
        }
    }

    @ViewBuilder private var buttons: some View {
        SettingsLink {
            Text(tr("Choose the folders…", "Choisir les dossiers…"))
        }
        if model.library?.folders?.remote == true {
            Button(tr("Connect the NAS again", "Reconnecter le NAS")) { model.mountShares() }
        }
    }
}

/// What the engine left aside in the sources folder, and why, as it says it
/// (library.py): a file whose name does not say its game while prod.keys
/// are not chosen, a file cut short, a second copy of a game. Open when no
/// game was found, as the reasons are then what the player needs; one line
/// to open otherwise, as a copy the player keeps on purpose is no news.
struct IssuesCard: View {
    @EnvironmentObject private var model: AppModel
    let issues: [String]
    let open: Bool
    @State private var expanded = false
    @State private var all = false

    private static let shown = 4

    var body: some View {
        Card {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: "questionmark.folder")
                    .font(.title)
                    .foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 6) {
                    ViewThatFits(in: .horizontal) {
                        HStack(alignment: .firstTextBaseline) {
                            heading
                            Spacer(minLength: 12)
                            toggle
                        }
                        VStack(alignment: .leading, spacing: 4) {
                            heading
                            toggle
                        }
                    }
                    if open || expanded {
                        ForEach(all ? issues : Array(issues.prefix(IssuesCard.shown)), id: \.self) { issue in
                            Text(issue)
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        if !all && issues.count > IssuesCard.shown {
                            Button(tr("Show the \(issues.count - IssuesCard.shown) others", "Afficher les \(issues.count - IssuesCard.shown) autres")) { all = true }
                                .buttonStyle(.link)
                        }
                        ViewThatFits(in: .horizontal) {
                            HStack { buttons }
                            VStack(alignment: .leading) { buttons }
                        }
                        .padding(.top, 4)
                    }
                }
            }
        }
    }

    private var heading: some View {
        Text(issues.count == 1 ? tr("1 file or folder left aside in your dumps", "1 fichier ou dossier laissé de côté dans vos dumps")
             : tr("\(issues.count) files or folders left aside in your dumps", "\(issues.count) fichiers ou dossiers laissés de côté dans vos dumps"))
            .font(.headline)
            .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder private var toggle: some View {
        if !open {
            Button(expanded ? tr("Hide", "Masquer") : tr("See why", "Voir pourquoi")) { expanded.toggle() }
                .buttonStyle(.link)
        }
    }

    @ViewBuilder private var buttons: some View {
        if let sources = model.config?.sources, !sources.isEmpty {
            Button(tr("Show the dumps folder", "Afficher le dossier des dumps")) { model.open(sources) }
        }
        SettingsLink {
            Text(tr("Settings…", "Réglages…"))
        }
    }
}

struct LoadingCard: View {
    var body: some View {
        HStack(spacing: 12) {
            ProgressView()
                .controlSize(.small)
            Text(tr("Reading your games…", "Lecture de vos jeux…"))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 200)
    }
}

struct EmptyLibrary: View {
    @EnvironmentObject private var model: AppModel
    let filter: LibraryFilter
    let searching: Bool

    var body: some View {
        ContentUnavailableView {
            Label(title, systemImage: searching ? "magnifyingglass" : filter == .due ? "checkmark.seal" : "gamecontroller")
        } description: {
            Text(text)
        } actions: {
            if !searching && filter == .all && model.foldersMissing {
                Button(tr("Choose my folders", "Choisir mes dossiers")) {
                    model.openSetup(at: (model.config?.sources ?? "").isEmpty ? .sources : .games)
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 280)
    }

    private var title: String {
        if searching { return tr("No game by that name", "Aucun jeu de ce nom") }
        switch filter {
        case .due: return tr("Nothing to rebuild", "Rien à reconstruire")
        case .upToDate: return tr("No game up to date yet", "Aucun jeu à jour pour l’instant")
        case .problems: return tr("Nothing to look at", "Rien à regarder")
        case .all: return tr("No game yet", "Pas encore de jeu")
        }
    }

    private var text: String {
        if searching { return "" }
        switch filter {
        case .due: return tr("Every game is built from nxnative’s latest improvements.", "Chaque jeu est construit avec les dernières améliorations de nxnative.")
        case .all:
            if !(model.library?.issues.isEmpty ?? true) {
                return tr("Above, what Cartouche Builder left aside in your dumps folder, and why.",
                          "Ci-dessus, ce que Cartouche Builder a laissé de côté dans votre dossier des dumps, et pourquoi.")
            }
            return tr("Put your dumps in your dumps folder: loose, or each in a folder.", "Mettez vos dumps dans votre dossier des dumps : en vrac, ou chacun dans un dossier.")
        default: return ""
        }
    }
}

/// What can be done to a game, from its card.
struct GameMenu: View {
    @EnvironmentObject private var model: AppModel
    let game: Game

    var body: some View {
        if game.canBuild {
            if let progress = model.progress(game.titleID) {
                // In the build running: this game alone, the others go on.
                if progress.state == "building" {
                    Button(tr("Stop its build", "Arrêter sa construction")) { model.stopBuild(game.titleID) }
                        .disabled(model.stopping(game.titleID))
                } else {
                    Button(tr("Remove from the queue", "Retirer de la file")) { model.takeOut(game.titleID) }
                        .disabled(!model.canTakeOut(game.titleID))
                }
            } else if model.isBuilding {
                Button(tr("Add to the queue", "Ajouter à la file")) {
                    model.build([game.titleID], force: game.state != .due)
                }
                .disabled(!model.canBuild)
            } else {
                Button(game.state == .due ? tr("Rebuild now", "Reconstruire maintenant") : tr("Build again", "Construire à nouveau")) {
                    model.build([game.titleID], force: game.state != .due)
                }
                .disabled(!model.canBuild)
            }
            Button(game.followed ? tr("Stop following", "Ne plus suivre") : tr("Follow", "Suivre")) {
                model.follow(game, !game.followed)
            }
        }
        if let ipa = game.ipa, ipa.present {
            Divider()
            Button(tr("Show the IPA in the Finder", "Afficher l’IPA dans le Finder")) { model.reveal(ipa.path) }
        }
        if let source = game.source, !source.isEmpty {
            Button(tr("Show its sources in the Finder", "Afficher ses sources dans le Finder")) { model.reveal(source) }
        }
    }
}
