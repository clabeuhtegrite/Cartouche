//
//  ActivityView.swift
//  Cartouche Builder
//
//  The builds: the game building now, its step and how far it is, the
//  games waiting their turn, and what the last batch did. A batch goes on
//  when the window, or the app, is closed; the Mac stays awake for it.
//

import BuilderKit
import SwiftUI

struct ActivityView: View {
    @EnvironmentObject private var model: AppModel
    @State private var showLines = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                PageHeader(title: tr("Builds", "Constructions"), subtitle: subtitle) {
                    if model.isBuilding {
                        Button(role: .destructive) {
                            model.stop()
                        } label: {
                            Label(tr("Stop", "Arrêter"), systemImage: "stop.fill")
                        }
                        .controlSize(.large)
                    } else {
                        Button {
                            model.build()
                        } label: {
                            Label(tr("Build what is due", "Construire ce qui est dû"), systemImage: "sparkles")
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                        .disabled(!model.canBuild || (model.library?.due.isEmpty ?? true))
                    }
                }
                if let status = model.status {
                    if status.running == true {
                        ForEach(status.current, id: \.titleID) { game in
                            CurrentCard(progress: game)
                        }
                        if status.current.isEmpty {
                            Card {
                                HStack(spacing: 12) {
                                    ProgressView().controlSize(.small)
                                    Text(status.message ?? tr("Getting ready: checking nxnative and the games…", "Préparation : vérification de nxnative et des jeux…"))
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    } else if model.starting != nil {
                        Card {
                            HStack(spacing: 12) {
                                ProgressView().controlSize(.small)
                                Text(tr("Starting…", "Démarrage…"))
                                    .foregroundStyle(.secondary)
                            }
                        }
                    } else {
                        LastBatchCard(status: status)
                    }
                    if !status.queued.isEmpty {
                        GameList(title: tr("Waiting their turn", "En attente"), games: status.queued)
                    }
                    if !status.finished.isEmpty {
                        GameList(title: status.running == true ? tr("Done in this batch", "Faits dans cette série") : tr("Last batch", "Dernière série"),
                                 games: status.finished)
                    }
                    if !status.lines.isEmpty {
                        DisclosureGroup(isExpanded: $showLines) {
                            ScrollView {
                                Text(status.lines.suffix(80).joined(separator: "\n"))
                                    .font(.caption.monospaced())
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(10)
                            }
                            .frame(maxHeight: 260)
                            .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .textBackgroundColor)))
                        } label: {
                            Text(tr("Details", "Détails"))
                                .font(.callout.weight(.medium))
                        }
                    }
                } else if model.starting != nil {
                    Card {
                        HStack(spacing: 12) {
                            ProgressView().controlSize(.small)
                            Text(tr("Starting…", "Démarrage…"))
                                .foregroundStyle(.secondary)
                        }
                    }
                } else {
                    ContentUnavailableView(tr("No build yet", "Pas encore de construction"), systemImage: "hammer",
                                           description: Text(tr("Builds show here while they run, and what they did after.",
                                                                "Les constructions s’affichent ici pendant qu’elles tournent, et ce qu’elles ont fait ensuite.")))
                        .frame(minHeight: 300)
                }
                NightlyCard()
            }
            .padding(28)
        }
    }

    private var subtitle: String {
        guard let status = model.status else { return tr("Nothing running", "Rien en cours") }
        if status.running == true {
            let left = status.queued.count + status.current.count
            return tr("\(left) game\(left == 1 ? "" : "s") to go", "\(left) jeu\(left == 1 ? "" : "x") à faire")
                + tr(" · the Mac stays awake", " · le Mac reste éveillé")
        }
        if let ended = status.endedDate { return tr("Last batch ", "Dernière série ") + Format.relative(ended) }
        return tr("Nothing running", "Rien en cours")
    }
}

/// The game building now.
struct CurrentCard: View {
    @EnvironmentObject private var model: AppModel
    let progress: GameProgress

    var body: some View {
        Card(padding: 20) {
            HStack(alignment: .top, spacing: 20) {
                if let game = model.game(progress.titleID) {
                    CoverView(game: game)
                        .frame(width: 110)
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .shadow(color: .black.opacity(0.2), radius: 6, y: 3)
                }
                VStack(alignment: .leading, spacing: 10) {
                    Text(progress.name)
                        .font(.title2.weight(.bold))
                    Text(stageText(progress.stage) + (progress.k.flatMap { k in progress.n.map { " · \(k)/\($0)" } } ?? ""))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    ProgressView(value: progress.overall ?? progress.frac ?? 0)
                        .progressViewStyle(.linear)
                        .tint(Theme.indigo)
                    HStack {
                        Text(Format.percent(progress.overall ?? progress.frac ?? 0))
                            .font(.callout.monospacedDigit().weight(.semibold))
                        Spacer()
                        if let eta = progress.eta, eta > 0 {
                            Text(tr("about \(Format.duration(eta)) left", "encore \(Format.duration(eta)) environ"))
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        } else if let started = progress.startedDate {
                            Text(tr("started ", "commencé ") + Format.relative(started))
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                    }
                    if let step = progress.step, !step.isEmpty {
                        Text(step)
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                    if let note = progress.note ?? progress.message, !note.isEmpty {
                        Text(note)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }
            }
        }
    }
}

/// What the last batch did, in one line.
struct LastBatchCard: View {
    let status: BatchStatus

    var body: some View {
        let built = status.games.filter { $0.state == "built" }.count
        let failed = status.games.filter { $0.state == "failed" }.count
        Card {
            HStack(spacing: 14) {
                Image(systemName: failed > 0 ? "exclamationmark.triangle.fill" : status.state == "stopped" ? "stop.circle.fill" : "checkmark.circle.fill")
                    .font(.largeTitle)
                    .foregroundStyle(failed > 0 ? Color.orange : status.state == "stopped" ? Color.secondary : Color.green)
                VStack(alignment: .leading, spacing: 4) {
                    Text(headline(built: built, failed: failed))
                        .font(.headline)
                    if let error = status.error, !error.isEmpty {
                        Text(error)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    } else if let ended = status.endedDate {
                        Text(Format.date(ended))
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private func headline(built: Int, failed: Int) -> String {
        if status.state == "failed" { return tr("The batch could not run", "La série n’a pas pu tourner") }
        if status.state == "stopped" { return tr("Stopped", "Arrêtée") + (built > 0 ? tr(" after \(built) game\(built == 1 ? "" : "s")", " après \(built) jeu\(built == 1 ? "" : "x")") : "") }
        if built == 0 && failed == 0 { return tr("Nothing was due", "Rien n’était à faire") }
        var parts: [String] = []
        if built > 0 { parts.append(tr("\(built) built", "\(built) construit\(built == 1 ? "" : "s")")) }
        if failed > 0 { parts.append(tr("\(failed) failed", "\(failed) échec\(failed == 1 ? "" : "s")")) }
        return parts.joined(separator: ", ")
    }
}

/// Games of a batch, with how each went.
struct GameList: View {
    @EnvironmentObject private var model: AppModel
    let title: String
    let games: [GameProgress]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title.uppercased())
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Card(padding: 6) {
                VStack(spacing: 0) {
                    ForEach(Array(games.enumerated()), id: \.element.titleID) { index, game in
                        if index > 0 { Divider().padding(.leading, 52) }
                        row(game)
                    }
                }
            }
        }
    }

    private func row(_ game: GameProgress) -> some View {
        HStack(spacing: 12) {
            if let found = model.game(game.titleID) {
                CoverView(game: found)
                    .frame(width: 32)
                    .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
            } else {
                RoundedRectangle(cornerRadius: 5).fill(Theme.gradient).frame(width: 32, height: 43)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(game.name)
                    .font(.callout.weight(.medium))
                if let error = game.error, !error.isEmpty, game.state == "failed" {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            Spacer()
            Text(stateText(game))
                .font(.callout)
                .foregroundStyle(stateColor(game))
            if let log = game.log, !log.isEmpty, game.state == "failed" {
                Button {
                    model.open(log)
                } label: {
                    Image(systemName: "doc.text.magnifyingglass")
                }
                .buttonStyle(.borderless)
                .help(tr("Open its log", "Ouvrir son journal"))
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }

    private func stateText(_ game: GameProgress) -> String {
        switch game.state {
        case "built": return tr("Built", "Construit") + (game.duration.map { " · " + Format.duration($0) } ?? "")
        case "failed": return tr("Failed", "Échec")
        case "stopped": return tr("Stopped", "Arrêté")
        case "skipped": return tr("Skipped", "Passé")
        case "queued": return tr("Waiting", "En attente")
        case "building": return tr("Building", "Construction")
        default: return game.state
        }
    }

    private func stateColor(_ game: GameProgress) -> Color {
        switch game.state {
        case "built": return .green
        case "failed": return .red
        default: return .secondary
        }
    }
}

/// The nightly run, on or off, and its hour.
struct NightlyCard: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        if let config = model.config {
            Card {
                HStack(spacing: 14) {
                    Image(systemName: "moon.stars.fill")
                        .font(.title2)
                        .foregroundStyle(Theme.gradient)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(tr("Build at night", "Construire la nuit"))
                            .font(.headline)
                        Text(config.schedule
                             ? tr("Every night at \(Format.time(hour: config.scheduleHour, minute: config.scheduleMinute)), what is due is built, even with the app closed.",
                                  "Chaque nuit à \(Format.time(hour: config.scheduleHour, minute: config.scheduleMinute)), ce qui est dû se construit, même app fermée.")
                             : tr("Off: games are built when you ask.", "Désactivé : les jeux se construisent quand vous le demandez."))
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Toggle("", isOn: Binding(get: { config.schedule }, set: { on in model.update { $0.schedule = on } }))
                        .toggleStyle(.switch)
                        .labelsHidden()
                }
            }
        }
    }
}
