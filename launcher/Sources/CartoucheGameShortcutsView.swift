//
//  CartoucheGameShortcutsView.swift
//  Cartouche
//
//  Siri and Home Screen, from the sheet of a game the player has installed:
//  what to say to Siri for the game to start, with its shorter name when
//  it has one, and the steps that give it an icon of its own on the Home
//  Screen, through a shortcut, which Cartouche cannot make itself. Both
//  start the game as Play does (CartoucheShortcuts.swift).
//

import SwiftUI

@available(iOS 17.0, *)
struct CartoucheGameShortcutsView: View {
    /// The game's bundle identifier.
    let id: String
    /// The game's name, as the console shows it and Siri knows it.
    let name: String

    /// The shorter names Siri also takes, as Siri is told them: none that
    /// another of the player's games could take (CartoucheGameNames).
    private var shorter: [String] {
        CartoucheGameShortcuts.games().first { $0.id == id }?.synonyms ?? []
    }

    /// The steps in Shortcuts, which name the shortcut SHORT, as the player
    /// would say it.
    private func steps(naming short: String) -> [String] {
        [
            CartoucheText.shortcutsStepNew,
            CartoucheText.shortcutsStepAction,
            CartoucheText.shortcutsStepGame(name),
            CartoucheText.shortcutsStepName(short),
            CartoucheText.shortcutsStepHome,
        ]
    }

    var body: some View {
        let short = shorter.first
        List {
            Section {
                Text(CartoucheText.shortcutsIntro(name))
            }
            Section {
                Label {
                    Text(CartoucheText.shortcutsPhrase(name))
                        .font(.headline)
                } icon: {
                    Image(systemName: "mic.fill")
                }
                if let short {
                    Text(CartoucheText.shortcutsShorter(short))
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text(CartoucheText.shortcutsSiri)
            } footer: {
                Text(CartoucheText.shortcutsSiriFooter)
            }
            Section(CartoucheText.shortcutsHome) {
                ForEach(Array(steps(naming: short ?? name).enumerated()), id: \.offset) { index, step in
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        Text(String(index + 1))
                            .font(.subheadline.monospacedDigit().weight(.bold))
                            .foregroundStyle(.white)
                            .frame(width: 26, height: 26)
                            .background(Color.accentColor, in: Circle())
                            .accessibilityHidden(true)
                        Text(step)
                    }
                    .padding(.vertical, 2)
                }
            }
            Section {
                Link(destination: CartoucheRenewal.shortcutsURL) {
                    Label(CartoucheText.openShortcuts, systemImage: "square.2.layers.3d")
                }
            }
        }
        .cartoucheStageBackground()
        .navigationTitle(CartoucheText.shortcutsTitle)
        .navigationBarTitleDisplayMode(.inline)
    }
}
