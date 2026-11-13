//
//  GameDetailView.swift
//  Cartouche Builder
//
//  A game's sheet, beside the library: why it is due, nxnative's commits
//  that touched it since its build, its build and its IPA, its app for this
//  Mac, and what can be done: rebuild it, follow it or not, build it for
//  the iPhone, for this Mac or for both, name it as nxnative's commits do.
//  nxnative writes its commits in English, a paragraph each: the sheet says
//  why in the player's words, and shows each commit's first lines, the
//  rest when asked.
//

import BuilderKit
import SwiftUI

struct GameDetailView: View {
    @EnvironmentObject private var model: AppModel
    let game: Game

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                actions
                if game.canBuild {
                    platforms
                }
                if !whyLines.isEmpty {
                    why
                }
                if let progress = model.progress(game.titleID) {
                    ProgressCard(progress: progress)
                }
                if let attempt = game.attempt, game.onIOS, game.state == .failed || attempt.result == "failed" {
                    failure(attempt)
                }
                if let attempt = game.mac?.attempt, attempt.result == "failed", game.onMac {
                    failure(attempt, mac: true)
                }
                if !game.changes.isEmpty {
                    changes
                }
                build
                if game.onMac || game.mac?.build != nil {
                    macApp
                }
                if game.canBuild {
                    AliasesEditor(game: game)
                }
            }
            .padding(20)
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            CoverView(game: game)
                .frame(width: 76)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .shadow(color: .black.opacity(0.2), radius: 6, y: 3)
            VStack(alignment: .leading, spacing: 6) {
                Text(game.name)
                    .font(.title2.weight(.bold))
                    .fixedSize(horizontal: false, vertical: true)
                Text(game.titleID)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                let look = GameLook(game, progress: model.progress(game.titleID))
                Label(look.text, systemImage: look.symbol)
                    .font(.callout.weight(.medium))
                    .foregroundStyle(look.color)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Button {
                model.selection = nil
            } label: {
                Image(systemName: "xmark")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .help(tr("Close its sheet", "Fermer sa fiche"))
        }
    }

    @ViewBuilder private var actions: some View {
        if game.canBuild {
            HStack(spacing: 10) {
                if let progress = model.progress(game.titleID) {
                    if progress.state == "building" {
                        // This game alone: the batch goes on with the next.
                        let stopping = model.stopping(game.titleID)
                        Button(role: .destructive) {
                            model.stopBuild(game.titleID)
                        } label: {
                            Label(stopping ? tr("Stopping…", "Arrêt…") : tr("Stop", "Arrêter"), systemImage: "stop.fill")
                                .frame(maxWidth: .infinity)
                        }
                        .controlSize(.large)
                        .disabled(stopping)
                        .help(tr("Stops this game’s build; the games waiting are built after it.",
                                 "Arrête la construction de ce jeu ; les jeux en attente se construisent ensuite."))
                    } else {
                        Button {
                            model.takeOut(game.titleID)
                        } label: {
                            Label(tr("Remove from the queue", "Retirer de la file"), systemImage: "minus.circle")
                                .frame(maxWidth: .infinity)
                        }
                        .controlSize(.large)
                        .disabled(!model.canTakeOut(game.titleID))
                    }
                } else if model.isBuilding {
                    // A build is running, or starting: this one waits its turn.
                    Button {
                        model.build([game.titleID], force: game.state != .due)
                    } label: {
                        Label(tr("Add to the queue", "Ajouter à la file"), systemImage: "text.badge.plus")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(!model.canBuild)
                    .help(tr("A build is running: this game is built after it, and after the games waiting.",
                             "Une construction est en cours : ce jeu se construira après elle, et après les jeux en attente."))
                } else {
                    // A game never built, with no IPA yet, is built for the
                    // first time; one nxnative improved, rebuilt.
                    let first = game.build == nil && !game.hasIPA
                    Button {
                        model.build([game.titleID], force: game.state != .due)
                    } label: {
                        Label(first ? tr("Build", "Construire") : game.state == .due ? tr("Rebuild", "Reconstruire") : tr("Build again", "Construire à nouveau"),
                              systemImage: first ? "hammer.fill" : game.state == .due ? "sparkles" : "arrow.clockwise")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(!model.canBuild)
                }
                Toggle(tr("Follow", "Suivre"), isOn: Binding(get: { game.followed }, set: { model.follow(game, $0) }))
                    .toggleStyle(.switch)
                    .help(tr("A followed game is rebuilt when nxnative improves it.", "Un jeu suivi est reconstruit quand nxnative l’améliore."))
            }
        } else {
            Card(padding: 14) {
                Label(tr("Only its IPA is here: put its dump in the sources folder to rebuild it.",
                         "Seule son IPA est là : mettez son dump dans le dossier des sources pour le reconstruire."),
                      systemImage: "info.circle")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// What the game is built for: its IPA for the iPhone, its app for this
    /// Mac, or both; never neither (the engine refuses it: a game built
    /// for neither is one no longer followed). One turned off for every
    /// game in the settings cannot be turned on here.
    private var platforms: some View {
        let config = model.config
        let ios = config?.ios ?? true
        let mac = config?.mac ?? true
        return SheetPart(title: tr("Built for", "Construit pour")) {
            VStack(alignment: .leading, spacing: 10) {
                PlatformToggle(title: "iPhone", symbol: "iphone", detail: iosDetail, on: game.onIOS,
                               locked: !ios ? tr("Turned off for every game in the settings.", "Désactivé pour tous les jeux dans les réglages.")
                                            : game.onIOS && !game.onMac ? lastOne : nil) { model.setPlatform(game, "ios", $0) }
                Divider()
                PlatformToggle(title: tr("This Mac", "Ce Mac"), symbol: "macbook", detail: macDetail, on: game.onMac,
                               locked: !mac ? tr("Turned off for every game in the settings.", "Désactivé pour tous les jeux dans les réglages.")
                                            : game.onMac && !game.onIOS ? lastOne : nil) { model.setPlatform(game, "mac", $0) }
            }
        }
    }

    private var lastOne: String {
        tr("A game is built for at least one of the two: to build it for neither, stop following it.",
           "Un jeu se construit pour au moins l’un des deux : pour ne plus le construire du tout, ne le suivez plus.")
    }

    private var iosDetail: String {
        guard game.onIOS else { return tr("Its IPA is no longer built.", "Son IPA n’est plus construite.") }
        return tr("Its IPA, in the games folder, for Cartouche.", "Son IPA, dans le dossier des jeux, pour Cartouche.")
    }

    /// Its Mac app as the engine says it (the next batch builds it, after
    /// its IPA or alone, or it is up to date), else where it goes.
    private var macDetail: String {
        guard game.onMac else {
            return game.hasMacApp ? tr("No longer built: its app stays on this Mac.", "Plus construit : son app reste sur ce Mac.")
                                  : tr("Its app for this Mac is not built.", "Son app pour ce Mac n’est pas construite.")
        }
        if let detail = game.mac?.detail, !detail.isEmpty { return detail }
        return tr("Its app, to play it on this Mac.", "Son app, pour y jouer sur ce Mac.")
    }

    private var why: some View {
        SheetPart(title: tr("Why", "Pourquoi")) {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(whyLines, id: \.self) { line in
                    Label {
                        Text(line)
                            .fixedSize(horizontal: false, vertical: true)
                    } icon: {
                        Image(systemName: "smallcircle.filled.circle")
                            .foregroundStyle(.secondary)
                    }
                    .font(.callout)
                }
            }
        }
    }

    /// Why the game is as it is, a line each. For a game to build, its
    /// reasons in the player's words: the engine's sentence quotes nxnative's
    /// commits, in English and cut short, which the list below shows whole.
    /// For a game up to date, the engine's sentence, which quotes none and
    /// says when nxnative's shared changes are due.
    private var whyLines: [String] {
        let reasons = game.reasons.filter { $0 != "up_to_date" }
        if reasons.isEmpty {
            return game.detail.split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        }
        return reasons.map { whyText($0, counts: game.changeCounts) }
    }

    private func failure(_ attempt: GameAttempt, mac: Bool = false) -> some View {
        SheetPart(title: mac ? tr("Last attempt of its Mac app", "Dernière tentative de son app Mac") : tr("Last attempt", "Dernière tentative")) {
            VStack(alignment: .leading, spacing: 8) {
                Text(attempt.error ?? tr("The build failed.", "La construction a échoué."))
                    .font(.callout)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    if let date = attempt.date {
                        Text(Format.relative(date))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if let log = attempt.log, !log.isEmpty {
                        Button(tr("Open its log", "Ouvrir son journal")) { model.open(log) }
                            .controlSize(.small)
                    }
                }
                Text(tr("It is tried again when nxnative changes it.", "Il sera réessayé quand nxnative le changera."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var changes: some View {
        SheetPart(title: tr("nxnative since its build", "nxnative depuis sa construction"), trailing: counts) {
            ChangeList(changes: Array(game.changes.prefix(30)), engine: model.library?.engine)
                .id(game.titleID)
        }
    }

    private var counts: String {
        guard let counts = game.changeCounts else { return "" }
        return tr("\(counts.own) for it, \(counts.shared) shared", "\(counts.own) pour lui, \(counts.shared) communs")
    }

    private var build: some View {
        SheetPart(title: tr("Its build", "Sa construction")) {
            VStack(alignment: .leading, spacing: 8) {
                if let build = game.build {
                    Fact(tr("Built", "Construit"), build.date.map { Format.date($0) } ?? build.builtAt)
                    Fact("nxnative", String(build.commit.prefix(12)), link: model.library?.engine?.page(of: build.commit))
                    if let duration = build.duration, duration > 0 { Fact(tr("Took", "Durée"), Format.duration(duration)) }
                    if let version = build.version, !version.isEmpty { Fact(tr("Version", "Version"), version) }
                    if let toolchain = build.toolchain, !toolchain.isEmpty { Fact(tr("With", "Avec"), toolchain) }
                } else {
                    Text(tr("Never built by Cartouche Builder.", "Jamais construit par Cartouche Builder."))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                if let ipa = game.ipa {
                    Divider()
                    Fact("IPA", ipa.present ? Format.size(ipa.size) : tr("missing", "absente"))
                    Text(ipa.name)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                    if ipa.present {
                        Button(tr("Show in the Finder", "Afficher dans le Finder")) { model.reveal(ipa.path) }
                            .controlSize(.small)
                    }
                }
                if let size = game.sourceSize, size > 0 {
                    Fact(tr("Its dump", "Son dump"), Format.size(size))
                }
            }
        }
    }

    /// Its app for this Mac: where it is, its build, or why it is not
    /// there (the engine's words).
    private var macApp: some View {
        SheetPart(title: tr("Its Mac app", "Son app Mac")) {
            VStack(alignment: .leading, spacing: 8) {
                if let app = game.mac?.app, app.present {
                    if let build = game.mac?.build {
                        Fact(tr("Built", "Construite"), build.date.map { Format.date($0) } ?? build.builtAt)
                        Fact("nxnative", String(build.commit.prefix(12)), link: model.library?.engine?.page(of: build.commit))
                        if let duration = build.duration, duration > 0 { Fact(tr("Took", "Durée"), Format.duration(duration)) }
                    }
                    Fact(tr("Size", "Taille"), Format.size(app.size))
                    Text(app.name)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                    Button(tr("Show in the Finder", "Afficher dans le Finder")) { model.reveal(app.path) }
                        .controlSize(.small)
                } else if let app = game.mac?.app, !app.name.isEmpty {
                    Text(tr("\(app.name) is no longer in its folder: it is built again.", "\(app.name) n’est plus dans son dossier : elle sera reconstruite."))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text(tr("Not built yet.", "Pas encore construite."))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                if let folder = game.mac?.folder, !folder.isEmpty {
                    Fact(tr("Folder", "Dossier"), (folder as NSString).abbreviatingWithTildeInPath)
                }
            }
        }
    }

    /// A titled part of the sheet.
    struct SheetPart<Content: View>: View {
        let title: String
        var trailing: String = ""
        @ViewBuilder var content: Content

        var body: some View {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text(title.uppercased())
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Spacer()
                    if !trailing.isEmpty {
                        Text(trailing)
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }
                Card(padding: 14) { content }
            }
        }
    }
}

struct Fact: View {
    let label: String
    let value: String
    var link: URL?

    init(_ label: String, _ value: String, link: URL? = nil) {
        self.label = label
        self.value = value
        self.link = link
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .foregroundStyle(.secondary)
            Spacer(minLength: 12)
            if let link {
                Link(value, destination: link)
                    .font(.callout.monospaced())
            } else {
                Text(value)
                    .multilineTextAlignment(.trailing)
                    .textSelection(.enabled)
            }
        }
        .font(.callout)
    }
}

/// nxnative's commits since the game's build, the newest first: the first
/// few, the others when asked.
struct ChangeList: View {
    static let shown = 4
    let changes: [Change]
    let engine: EngineCommit?
    @State private var all = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(all ? changes : Array(changes.prefix(ChangeList.shown))) { change in
                ChangeRow(change: change, link: engine?.page(of: change.sha))
            }
            if changes.count > ChangeList.shown {
                Button(all ? tr("Show fewer", "En montrer moins")
                           : tr("Show the \(changes.count - ChangeList.shown) others", "Voir les \(changes.count - ChangeList.shown) autres")) {
                    withAnimation(.snappy) { all.toggle() }
                }
                .buttonStyle(.link)
                .font(.callout)
            }
        }
    }
}

/// A commit of nxnative: its first lines, all of it when asked, its kind,
/// its link and when it was made.
struct ChangeRow: View {
    /// Longer than this, a commit's text is cut to its first lines.
    static let long = 80
    let change: Change
    let link: URL?
    @State private var open = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(change.subject)
                .font(.callout)
                .lineLimit(open ? nil : 2)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            HStack(spacing: 6) {
                Text(changeKindText(change.kind))
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(change.kind == "shared" ? Color.secondary.opacity(0.15) : Theme.indigo.opacity(0.15)))
                if let link {
                    Link(change.short.prefix(7), destination: link)
                        .font(.caption.monospaced())
                } else {
                    Text(change.short.prefix(7))
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                }
                Text(Format.relative(change.date))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 4)
                if change.subject.count > ChangeRow.long {
                    Button(open ? tr("Less", "Moins") : tr("More", "Plus")) {
                        withAnimation(.snappy) { open.toggle() }
                    }
                    .buttonStyle(.link)
                    .font(.caption)
                }
            }
        }
    }
}

/// The names nxnative's commits give the game, besides its own.
struct AliasesEditor: View {
    @EnvironmentObject private var model: AppModel
    let game: Game
    @State private var text = ""
    @State private var editing = false

    var body: some View {
        DisclosureGroup(isExpanded: $editing) {
            VStack(alignment: .leading, spacing: 8) {
                Text(tr("Other names of the game in nxnative’s commits, one per line: a fix that names it rebuilds it.",
                        "Autres noms du jeu dans les commits de nxnative, un par ligne : un correctif qui le nomme le reconstruit."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                TextEditor(text: $text)
                    .font(.callout)
                    .frame(minHeight: 60)
                    .scrollContentBackground(.hidden)
                    .padding(6)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .textBackgroundColor)))
                HStack {
                    Spacer()
                    Button(tr("Save", "Enregistrer")) {
                        let names = text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                        model.update { config in
                            if names.isEmpty {
                                config.aliases.removeValue(forKey: game.titleID)
                            } else {
                                config.aliases[game.titleID] = names
                            }
                        }
                    }
                    .controlSize(.small)
                }
            }
            .padding(.top, 6)
        } label: {
            Text(tr("Names in nxnative’s commits", "Noms dans les commits de nxnative"))
                .font(.callout.weight(.medium))
        }
        .onAppear { text = (model.config?.aliases[game.titleID] ?? game.aliases).joined(separator: "\n") }
        .onChange(of: game.titleID) { _, _ in
            text = (model.config?.aliases[game.titleID] ?? game.aliases).joined(separator: "\n")
        }
    }
}

/// A platform of a game's sheet: built for it, or not.
struct PlatformToggle: View {
    let title: String
    let symbol: String
    let detail: String
    let on: Bool
    /// Why it cannot be changed here, when it cannot.
    let locked: String?
    let change: (Bool) -> Void

    var body: some View {
        Toggle(isOn: Binding(get: { on }, set: { change($0) })) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: symbol)
                    .font(.title3)
                    .foregroundStyle(on ? Theme.indigo : .secondary)
                    .frame(width: 22)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.callout.weight(.medium))
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .toggleStyle(.switch)
        .disabled(locked != nil)
        .help(locked ?? "")
    }
}

/// A game building now, or waiting its turn: its IPA, then its app for
/// this Mac, or the Mac app alone.
struct ProgressCard: View {
    let progress: GameProgress

    var body: some View {
        Card(padding: 14) {
            VStack(alignment: .leading, spacing: 8) {
                if progress.buildsMac {
                    Text(platformLine)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                HStack {
                    Text(progress.state == "building" ? stageText(progress.stage) : tr("Waiting its turn", "En attente de son tour"))
                        .font(.callout.weight(.medium))
                    Spacer()
                    if let eta = progress.eta, eta > 0 {
                        Text(tr("about \(Format.duration(eta)) left", "encore \(Format.duration(eta)) environ"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                if progress.state == "building" {
                    ProgressView(value: progress.overall ?? progress.frac ?? 0)
                    if let step = progress.step, !step.isEmpty {
                        Text(step)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            }
        }
    }

    private var platformLine: String {
        if progress.macOnly == true { return tr("For this Mac", "Pour ce Mac") }
        return progress.onMacNow ? tr("iPhone done, now this Mac", "iPhone fait, maintenant ce Mac") : tr("For the iPhone, then this Mac", "Pour l’iPhone, puis ce Mac")
    }
}
