//
//  CartoucheFocusPanel.swift
//  Cartouche
//
//  Beside the console, on an iPhone Duo unfolded or an iPad
//  (CartoucheGamesView): what the home's cover in focus does when it is not
//  a game's, the one that imports a game or the one that opens every game,
//  in the place a game's sheet takes for a game, and in its look: the
//  cover, its name, what it does and its button. Before the player has a
//  game, the import's stands there, never a game they do not have.
//

import SwiftUI

@available(iOS 17.0, *)
struct CartoucheFocusPanel: View {
    enum Kind: Hashable {
        case importGame
        case allGames
    }

    let kind: Kind
    /// The games of nxnative's list, for All games.
    let gameCount: Int
    let action: () -> Void

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 16) {
                    HStack(alignment: .center, spacing: 18) {
                        cartridge
                            .padding(.vertical, 8)
                        VStack(alignment: .leading, spacing: 8) {
                            Text(title)
                                .font(.system(.title2, design: .rounded, weight: .heavy))
                                .foregroundStyle(Color.white)
                                .lineLimit(3)
                                .minimumScaleFactor(0.7)
                                .accessibilityAddTraits(.isHeader)
                            Text(detail)
                                .font(.subheadline)
                                .foregroundStyle(CartoucheTheme.secondaryText)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    Button(action: action) {
                        Label(buttonTitle, systemImage: systemImage)
                            .font(.headline)
                            .foregroundStyle(Color.white)
                            .frame(maxWidth: .infinity, minHeight: 30)
                    }
                    .controlSize(.large)
                    .cartouchePrimaryButton()
                }
                .padding(.vertical, 8)
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
            }
        }
        .scrollContentBackground(.hidden)
        .background(CartoucheStage(key: nil))
    }

    @ViewBuilder
    private var cartridge: some View {
        switch kind {
        case .importGame:
            CartoucheImportCartridge(width: 104)
        case .allGames:
            CartoucheAllGamesCartridge(width: 104, count: gameCount)
        }
    }

    private var title: String {
        switch kind {
        case .importGame: return CartoucheText.importTile
        case .allGames: return CartoucheText.allGames
        }
    }

    private var detail: String {
        switch kind {
        case .importGame: return CartoucheText.emptyMessage
        case .allGames: return CartoucheText.allGamesDetail(gameCount)
        }
    }

    private var buttonTitle: String {
        switch kind {
        case .importGame: return CartoucheText.importCopy
        case .allGames: return CartoucheText.allGames
        }
    }

    private var systemImage: String {
        switch kind {
        case .importGame: return "square.and.arrow.down"
        case .allGames: return "square.grid.2x2.fill"
        }
    }
}
