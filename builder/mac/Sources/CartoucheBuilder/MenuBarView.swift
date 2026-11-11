//
//  MenuBarView.swift
//  Cartouche Builder
//
//  The item in the menu bar, there while the window is closed: what is
//  being built and how far it is, the games nxnative improved with the
//  button that rebuilds them, or adds them to the build running, the
//  update that waits, and the way back to the window. Its label opens the
//  window again when the app asks for it (a notification clicked while the
//  window is closed).
//

import AppKit
import BuilderKit
import SwiftUI

struct MenuBarLabel: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: model.isBuilding ? "hammer.fill" : "gamecontroller.fill")
            if let percent = buildingPercent {
                Text(percent)
                    .monospacedDigit()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .openMainWindow)) { _ in
            openWindow(id: AppModel.mainWindow)
            NSApp.activate()
        }
    }

    private var buildingPercent: String? {
        guard model.isBuilding, let current = model.status?.current.first, let fraction = current.overall ?? current.frac else { return nil }
        return Format.percent(fraction)
    }
}

struct MenuBarView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var updater: Updater
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            if model.isBuilding {
                building
            }
            if model.starting == nil, !model.dueOutsideBatch.isEmpty {
                improved(model.dueOutsideBatch)
            }
            if case let .ready(release) = updater.state {
                updateReady(release)
            }
            Divider()
            footer
        }
        .padding(14)
        .frame(width: 330)
    }

    private var header: some View {
        HStack(spacing: 10) {
            AppIconView()
                .frame(width: 34, height: 34)
            VStack(alignment: .leading, spacing: 2) {
                Text("Cartouche Builder")
                    .font(.headline)
                Text(summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 0)
            if model.checking {
                ProgressView()
                    .controlSize(.small)
            }
        }
    }

    private var summary: String {
        if model.isBuilding {
            let left = model.waiting.count + (model.status?.current.count ?? 0)
            return left > 1 ? tr("Building: \(left) games to go", "Construction : encore \(left) jeux") : tr("Building a game", "Construction d’un jeu")
        }
        if model.engine == nil || !model.setup.ready {
            return tr("This Mac’s tools are not all there yet", "Les outils du Mac ne sont pas encore tous là")
        }
        let due = model.library?.due.count ?? 0
        if due > 0 {
            return due == 1 ? tr("1 game to rebuild", "1 jeu à reconstruire") : tr("\(due) games to rebuild", "\(due) jeux à reconstruire")
        }
        if let checked = model.library?.checked.flatMap(ISODate.parse) {
            return tr("Everything is up to date, checked ", "Tout est à jour, vérifié ") + Format.relative(checked)
        }
        return tr("Everything is up to date", "Tout est à jour")
    }

    @ViewBuilder private var building: some View {
        if let status = model.status {
            ForEach(status.current, id: \.titleID) { progress in
                HStack(spacing: 10) {
                    cover(progress.titleID)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(progress.name)
                            .font(.callout.weight(.medium))
                            .lineLimit(1)
                        Text(stageText(progress.stage))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        ProgressView(value: progress.overall ?? progress.frac ?? 0)
                            .controlSize(.small)
                    }
                }
            }
        }
        HStack {
            if let eta = model.status?.current.first?.eta, eta > 0 {
                Text(tr("about \(Format.duration(eta)) left", "encore \(Format.duration(eta)) environ"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button(model.waiting.isEmpty ? tr("Stop", "Arrêter") : tr("Stop all", "Tout arrêter")) { model.stop() }
                .controlSize(.small)
        }
    }

    private func improved(_ due: [Game]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(due.prefix(3)) { game in
                Button {
                    model.section = .library
                    model.selection = game.titleID
                    show()
                } label: {
                    HStack(spacing: 10) {
                        cover(game.titleID)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(game.name)
                                .font(.callout.weight(.medium))
                                .lineLimit(1)
                            Text(GameLook(game, progress: nil).text)
                                .font(.caption)
                                .foregroundStyle(.orange)
                        }
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            if due.count > 3 {
                Text(tr("and \(due.count - 3) more", "et \(due.count - 3) autres"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Button {
                model.build()
            } label: {
                if model.isBuilding {
                    Label(due.count == 1 ? tr("Add it to the queue", "L’ajouter à la file") : tr("Add them to the queue (\(due.count))", "Les ajouter à la file (\(due.count))"),
                          systemImage: "text.badge.plus")
                        .frame(maxWidth: .infinity)
                } else {
                    Label(due.count == 1 ? tr("Rebuild it", "Le reconstruire") : tr("Rebuild them (\(due.count))", "Les reconstruire (\(due.count))"),
                          systemImage: "sparkles")
                        .frame(maxWidth: .infinity)
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(!model.canBuild)
        }
    }

    private func updateReady(_ release: BuilderRelease) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "arrow.down.circle.fill")
                .font(.title3)
                .foregroundStyle(Theme.indigo)
            Text(tr("Version \(release.version) is ready", "La version \(release.version) est prête"))
                .font(.callout)
            Spacer(minLength: 0)
            Button(tr("Restart", "Redémarrer")) {
                Task { await updater.install(relaunch: true) }
            }
            .controlSize(.small)
            .disabled(model.isBuilding)
        }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Button(tr("Open Cartouche Builder", "Ouvrir Cartouche Builder")) { show() }
                .keyboardShortcut("o")
            Spacer()
            Button {
                Task { await model.refreshLibrary(update: true) }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .help(tr("Check nxnative now", "Vérifier nxnative maintenant"))
            .disabled(model.engine == nil || model.checking)
            SettingsLink {
                Image(systemName: "gearshape")
            }
            .help(tr("Settings", "Réglages"))
            Button {
                NSApp.terminate(nil)
            } label: {
                Image(systemName: "power")
            }
            .help(tr("Quit Cartouche Builder", "Quitter Cartouche Builder"))
        }
        .buttonStyle(.borderless)
    }

    private func cover(_ titleID: String) -> some View {
        Group {
            if let game = model.game(titleID) {
                CoverView(game: game)
            } else {
                Theme.gradient
            }
        }
        .frame(width: 36, height: 48)
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
    }

    private func show() {
        openWindow(id: AppModel.mainWindow)
        NSApp.activate()
    }
}
