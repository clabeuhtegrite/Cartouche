//
//  CartoucheGameWorkView.swift
//  Cartouche
//
//  What Cartouche is doing with a game (CartoucheGameActions), over the
//  console: installing the player's copy, from Files or from the player's
//  games folder, starting a game, uninstalling one or copying it to the
//  games folder, and how far it has gone.
//

import SwiftUI

/// A step Cartouche takes with a game, and how far it has gone.
struct CartoucheGameWork: Equatable {
    enum Kind: Equatable {
        case installing, starting, uninstalling, exporting
    }

    var kind: Kind
    /// The game's name, or its IPA's until the IPA is read.
    var name: String
    /// What happens now.
    var step: String
    /// From 0 to 1, or nil while there is nothing to measure.
    var fraction: Double?
}

/// What the player should know once a step is over: why it failed, or what
/// came of it.
struct CartoucheGameNotice: Equatable {
    var title: String
    var message: String
}

@available(iOS 17.0, *)
struct CartoucheGameWorkView: View {
    let work: CartoucheGameWork

    private var title: String {
        switch work.kind {
        case .installing: return CartoucheText.installTitle(work.name)
        case .starting: return CartoucheText.startTitle(work.name)
        case .uninstalling: return CartoucheText.uninstallTitle(work.name)
        case .exporting: return CartoucheText.exportTitle(work.name)
        }
    }

    private var symbol: String {
        switch work.kind {
        case .installing: return "square.and.arrow.down.fill"
        case .starting: return "play.fill"
        case .uninstalling: return "trash.fill"
        case .exporting: return "externaldrive.fill.badge.plus"
        }
    }

    var body: some View {
        ZStack {
            Color.black.opacity(0.6)
                .ignoresSafeArea()
            VStack(spacing: 18) {
                Image(systemName: symbol)
                    .font(.system(size: 30, weight: .semibold))
                    .foregroundStyle(Color.white)
                    .frame(width: 72, height: 72)
                    .background(
                        LinearGradient(colors: [CartoucheTheme.indigo, CartoucheTheme.pink],
                                       startPoint: .topLeading, endPoint: .bottomTrailing),
                        in: Circle())
                    .symbolEffect(.pulse, options: .repeating, isActive: work.fraction == nil)
                VStack(spacing: 6) {
                    Text(title)
                        .font(.system(.title3, design: .rounded, weight: .heavy))
                        .foregroundStyle(Color.white)
                        .multilineTextAlignment(.center)
                        .lineLimit(3)
                        .minimumScaleFactor(0.8)
                    Text(work.step)
                        .font(.subheadline)
                        .foregroundStyle(CartoucheTheme.secondaryText)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let fraction = work.fraction {
                    VStack(spacing: 6) {
                        ProgressView(value: min(max(fraction, 0), 1))
                            .tint(Color.white)
                        Text(min(max(fraction, 0), 1).formatted(.percent.precision(.fractionLength(0))))
                            .font(.footnote.weight(.semibold).monospacedDigit())
                            .foregroundStyle(CartoucheTheme.secondaryText)
                    }
                } else {
                    ProgressView()
                        .tint(Color.white)
                }
            }
            .padding(28)
            .frame(maxWidth: 380)
            .cartoucheGlass(in: RoundedRectangle(cornerRadius: 30, style: .continuous))
            .padding(24)
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.updatesFrequently)
    }
}
