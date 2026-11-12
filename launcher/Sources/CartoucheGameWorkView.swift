//
//  CartoucheGameWorkView.swift
//  Cartouche
//
//  What Cartouche is doing with a game (CartoucheGameActions), over the
//  console: installing the player's copy, from Files or from the player's
//  games folder, starting a game, uninstalling one or copying it to the
//  games folder, how far it has gone, and whether the player can leave
//  Cartouche meanwhile.
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
    /// What happens now, as a key that stays the same in every language,
    /// for the measurements: "unpacking", "signing".
    var stage = ""
    /// The name of the server the game comes from or goes to; nil for a
    /// file on this iPhone.
    var place: String? = nil
    /// Whether iOS goes on with it once the player leaves Cartouche, and
    /// shows how far it has gone on the Lock Screen and in the Dynamic
    /// Island (CartoucheContinuedWork).
    var outside = false
    /// When it started.
    var started = Date()

    /// "Installing Mario Kart World".
    var title: String {
        switch kind {
        case .installing: return CartoucheText.installTitle(name)
        case .starting: return CartoucheText.startTitle(name)
        case .uninstalling: return CartoucheText.uninstallTitle(name)
        case .exporting: return CartoucheText.exportTitle(name)
        }
    }

    /// What the player may do meanwhile, for a step that takes minutes:
    /// leave Cartouche, once iOS goes on with it outside, or else keep it
    /// open.
    var advice: String? {
        switch kind {
        case .installing, .exporting: return outside ? CartoucheText.workCanLeave : CartoucheText.workKeepOpen
        case .starting, .uninstalling: return nil
        }
    }
}

/// What the player should know once a step is over: why it failed, or what
/// came of it.
struct CartoucheGameNotice: Equatable {
    var title: String
    var message: String
    /// The report on what failed, which the player can copy; nil when
    /// nothing failed.
    var report: CartoucheReport? = nil
}

@available(iOS 17.0, *)
struct CartoucheGameWorkView: View {
    let work: CartoucheGameWork

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
                    Text(work.title)
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
                    if let advice = work.advice {
                        Label(advice, systemImage: work.outside ? "lock.iphone" : "iphone")
                            .font(.footnote)
                            .foregroundStyle(work.outside ? Color.white : CartoucheTheme.secondaryText)
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.top, 4)
                    }
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
