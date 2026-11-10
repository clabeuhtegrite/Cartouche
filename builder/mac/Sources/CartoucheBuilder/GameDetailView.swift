//
//  GameDetailView.swift
//  Cartouche Builder
//
//  A game's sheet, beside the library: why it is due, nxnative's commits
//  that touched it since its build, its build and its IPA, and what can be
//  done: rebuild it, follow it or not, name it as nxnative's commits do.
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
                if !game.detail.isEmpty || !game.reasons.isEmpty {
                    why
                }
                if let progress = model.progress(game.titleID) {
                    ProgressCard(progress: progress)
                }
                if let attempt = game.attempt, game.state == .failed || attempt.result == "failed" {
                    failure(attempt)
                }
                if !game.changes.isEmpty {
                    changes
                }
                build
                if game.canBuild {
                    AliasesEditor(game: game)
                }
            }
            .padding(20)
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 14) {
            CoverView(game: game)
                .frame(width: 96)
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
                    .padding(.top, 2)
            }
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder private var actions: some View {
        if game.canBuild {
            HStack(spacing: 10) {
                if model.progress(game.titleID) != nil {
                    Button(role: .destructive) {
                        model.stop()
                    } label: {
                        Label(tr("Stop", "Arrêter"), systemImage: "stop.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .controlSize(.large)
                } else {
                    Button {
                        model.build([game.titleID], force: game.state != .due)
                    } label: {
                        Label(game.state == .due ? tr("Rebuild", "Reconstruire") : tr("Build again", "Construire à nouveau"),
                              systemImage: game.state == .due ? "sparkles" : "arrow.clockwise")
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

    private var why: some View {
        SheetPart(title: tr("Why", "Pourquoi")) {
            VStack(alignment: .leading, spacing: 6) {
                if !game.detail.isEmpty {
                    Text(game.detail)
                        .font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    ForEach(game.reasons, id: \.self) { reason in
                        Label(reasonText(reason), systemImage: "smallcircle.filled.circle")
                            .font(.callout)
                    }
                }
            }
        }
    }

    private func failure(_ attempt: GameAttempt) -> some View {
        SheetPart(title: tr("Last attempt", "Dernière tentative")) {
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
            VStack(alignment: .leading, spacing: 10) {
                ForEach(game.changes.prefix(30)) { change in
                    ChangeRow(change: change, link: model.library?.engine?.page(of: change.sha))
                }
            }
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

struct ChangeRow: View {
    let change: Change
    let link: URL?

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(change.subject)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 6) {
                Text(changeKindText(change.kind))
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(change.kind == "shared" ? Color.secondary.opacity(0.15) : Theme.indigo.opacity(0.15)))
                if let link {
                    Link(change.short, destination: link)
                        .font(.caption.monospaced())
                } else {
                    Text(change.short)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                }
                Text(Format.relative(change.date))
                    .font(.caption)
                    .foregroundStyle(.secondary)
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

/// A game building now, or waiting its turn.
struct ProgressCard: View {
    let progress: GameProgress

    var body: some View {
        Card(padding: 14) {
            VStack(alignment: .leading, spacing: 8) {
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
}
