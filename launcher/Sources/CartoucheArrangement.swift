//
//  CartoucheArrangement.swift
//  Cartouche
//
//  The console and a game's sheet side by side, in a regular width with
//  iOS 27.1 or later: a split ArrangementView, which places them on either
//  side of the fold of an iPhone Duo unfolded, the console leading when the
//  screen is wider than tall, above when it is taller, and moves them
//  around the fold as the Duo folds partly. In a compact width, such as on
//  the Duo's outer display or any other iPhone, it shows the console alone,
//  and the sheet opens over it (CartoucheGamesView).
//
//  The same ArrangementView stays on screen whatever the width, with no
//  axis to split along in a compact one, so that folding or unfolding the
//  Duo keeps the console as it was: the game in focus, the shelves' scroll
//  positions, every game open over the home.
//

import SwiftUI

/// Whether this iOS lays out a split ArrangementView (iOS 27.1).
enum CartoucheSplit {
    static var isAvailable: Bool {
        if #available(iOS 27.1, *) {
            return true
        }
        return false
    }
}

@available(iOS 17.0, *)
struct CartoucheArrangement<Primary: View, Secondary: View>: View {
    /// The console and the sheet side by side; otherwise the console alone.
    let splits: Bool
    let primary: Primary
    let secondary: Secondary

    init(splits: Bool, @ViewBuilder primary: () -> Primary, @ViewBuilder secondary: () -> Secondary) {
        self.splits = splits
        self.primary = primary()
        self.secondary = secondary()
    }

    var body: some View {
        if #available(iOS 27.1, *) {
            ArrangementView {
                primary
            } secondary: {
                secondary
            }
            // Both halves the same size, as the fold divides the display: the
            // line between them stays where the fold is when the Duo folds
            // partly. With no axis, only the console shows.
            .arrangementViewStyle(splits ? SplitArrangementViewStyle() : SplitArrangementViewStyle().axes([]))
        } else {
            primary
        }
    }
}
