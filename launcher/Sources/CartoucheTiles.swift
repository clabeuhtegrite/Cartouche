//
//  CartoucheTiles.swift
//  Cartouche
//
//  The catalogue's cards. A game the player has shows the icon of their own
//  copy; any other game gets a tile we draw from its name, never official
//  cover art.
//

import SwiftUI

@available(iOS 17.0, *)
struct CartoucheTileArt: View {
    let name: String
    let platform: String?
    let key: String

    var body: some View {
        let colors = Self.colors(for: key)
        ZStack(alignment: .bottomLeading) {
            LinearGradient(colors: [colors.light, colors.dark], startPoint: .topLeading, endPoint: .bottomTrailing)
            Image(systemName: "gamecontroller.fill")
                .font(.system(size: 56, weight: .bold))
                .foregroundStyle(Color.white.opacity(0.14))
                .rotationEffect(.degrees(-12))
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                .padding(10)
            VStack(alignment: .leading, spacing: 3) {
                if let platform {
                    Text(CartoucheText.platform(platform).uppercased())
                        .font(.caption2.weight(.heavy))
                        .tracking(1.2)
                        .foregroundStyle(Color.white.opacity(0.8))
                }
                Text(name)
                    .font(.system(.headline, design: .rounded, weight: .bold))
                    .foregroundStyle(Color.white)
                    .lineLimit(3)
                    .minimumScaleFactor(0.7)
                    .multilineTextAlignment(.leading)
            }
            .padding(12)
        }
        .accessibilityElement(children: .combine)
    }

    /// Two colours from the key, the same on every launch and every iPhone.
    static func colors(for key: String) -> (light: Color, dark: Color) {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in key.utf8 {
            hash = (hash ^ UInt64(byte)) &* 0x100000001b3
        }
        let hue = Double(hash % 360) / 360
        let shifted = (hue + 0.07).truncatingRemainder(dividingBy: 1)
        return (Color(hue: hue, saturation: 0.62, brightness: 0.88),
                Color(hue: shifted, saturation: 0.78, brightness: 0.42))
    }
}

/// The icon of the player's own copy, from LiveContainer's cache.
@available(iOS 17.0, *)
struct CartoucheAppIcon: View {
    let app: LCAppModel
    var size: CGFloat = 64
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Group {
            if let icon = app.appInfo.iconIsDarkIcon(colorScheme == .dark) {
                Image(uiImage: icon).resizable().scaledToFill()
            } else {
                Image(systemName: "gamecontroller.fill").resizable().scaledToFit().padding(size / 5)
                    .foregroundStyle(Color.white)
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.225, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: size * 0.225, style: .continuous).strokeBorder(Color.white.opacity(0.25), lineWidth: 1))
        .shadow(color: Color.black.opacity(0.25), radius: 6, y: 3)
    }
}

/// A small coloured label for how a game fits this iPhone.
@available(iOS 17.0, *)
struct CartoucheFitBadge: View {
    let fit: CartoucheFit?
    var owned = false

    var body: some View {
        Label(text, systemImage: symbol)
            .font(.caption.weight(.semibold))
            .foregroundStyle(color)
            .labelStyle(.titleAndIcon)
            .lineLimit(1)
            .minimumScaleFactor(0.8)
    }

    private var text: String {
        guard let fit else { return CartoucheText.noSheet }
        if owned && fit.isPlayable { return CartoucheText.ready }
        return fit.title
    }

    private var symbol: String {
        switch fit {
        case .recommended: return "checkmark.circle.fill"
        case .untested: return owned ? "checkmark.circle.fill" : "circle.dashed"
        case .notRecommended: return "exclamationmark.triangle.fill"
        case .unsupported: return "xmark.octagon.fill"
        case nil: return "questionmark.circle"
        }
    }

    private var color: Color {
        switch fit {
        case .recommended: return .green
        case .untested: return owned ? .green : .secondary
        case .notRecommended: return .orange
        case .unsupported: return .red
        case nil: return .secondary
        }
    }
}

/// One of the player's games: large, with their icon and a Play button.
@available(iOS 17.0, *)
struct CartoucheOwnedCard: View {
    let entry: CartoucheEntry
    let fit: CartoucheFit?
    let isSelected: Bool
    let onPlay: () -> Void

    var body: some View {
        let colors = CartoucheTileArt.colors(for: entry.tileKey)
        HStack(alignment: .center, spacing: 14) {
            if let app = entry.app {
                CartoucheAppIcon(app: app, size: 72)
            }
            VStack(alignment: .leading, spacing: 6) {
                if let platform = entry.sheet?.platform {
                    Text(CartoucheText.platform(platform).uppercased())
                        .font(.caption2.weight(.heavy))
                        .tracking(1.2)
                        .foregroundStyle(Color.white.opacity(0.8))
                }
                Text(entry.name)
                    .font(.system(.title3, design: .rounded, weight: .bold))
                    .foregroundStyle(Color.white)
                    .lineLimit(2)
                    .minimumScaleFactor(0.75)
                CartoucheFitBadge(fit: fit, owned: true)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(Color.black.opacity(0.35)))
            }
            Spacer(minLength: 0)
            Button(action: onPlay) {
                Label(CartoucheText.play, systemImage: "play.fill")
                    .font(.headline)
            }
            .buttonStyle(.borderedProminent)
            .tint(Color.white.opacity(0.92))
            .foregroundStyle(colors.dark)
            .controlSize(.large)
        }
        .padding(16)
        .frame(maxWidth: .infinity, minHeight: 120, alignment: .leading)
        .background(
            LinearGradient(colors: [colors.light, colors.dark], startPoint: .topLeading, endPoint: .bottomTrailing),
            in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(isSelected ? Color.accentColor : Color.clear, lineWidth: 3))
        .contentShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
    }
}

/// A supported game the player has not imported: our tile and its fit.
@available(iOS 17.0, *)
struct CartoucheGameTile: View {
    let entry: CartoucheEntry
    let fit: CartoucheFit?
    let isSelected: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            CartoucheTileArt(name: entry.name, platform: entry.sheet?.platform, key: entry.tileKey)
                .aspectRatio(4.0 / 3.0, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .strokeBorder(isSelected ? Color.accentColor : Color.clear, lineWidth: 3))
                .shadow(color: Color.black.opacity(0.18), radius: 8, y: 4)
            CartoucheFitBadge(fit: fit)
                .padding(.horizontal, 4)
        }
        .contentShape(Rectangle())
    }
}
