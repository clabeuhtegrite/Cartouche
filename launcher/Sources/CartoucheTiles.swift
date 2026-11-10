//
//  CartoucheTiles.swift
//  Cartouche
//
//  Every game shows as the front of its game case: its official cover from
//  IGDB (CartoucheCovers.swift), whole, in a rounded rectangle of a case's
//  proportions; until it has loaded and when there is none, the icon of
//  the player's own copy over its name, or a label we draw from the game's
//  name and genre. The cartridge itself stays Cartouche's icon and mark.
//

import SwiftUI

/// A cartridge's body: a rounded rectangle whose corners follow its width.
struct CartoucheCartridgeShape: InsettableShape {
    var insetAmount: CGFloat = 0

    func path(in rect: CGRect) -> Path {
        let radius = max(0, rect.width * 0.11 - insetAmount)
        return Path(roundedRect: rect.insetBy(dx: insetAmount, dy: insetAmount), cornerRadius: radius, style: .continuous)
    }

    func inset(by amount: CGFloat) -> CartoucheCartridgeShape {
        var shape = self
        shape.insetAmount += amount
        return shape
    }
}

/// A game's tile of any width, as the front of a game case: its cover fills
/// a rounded rectangle of a case's proportions, its height
/// CartoucheTheme.cartridgeAspect times its width. Import and every game
/// are outlines of the same shape.
@available(iOS 17.0, *)
struct CartoucheCartridge<Content: View>: View {
    let width: CGFloat
    let key: String
    var isFocused = false
    var isOutline = false
    @ViewBuilder let label: () -> Content

    var body: some View {
        let w = width
        let h = w * CartoucheTheme.cartridgeAspect
        let radius = w * 0.08
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        // The focused tile's ring, around it, its corners following the
        // tile's.
        let ringGap = max(4, w * 0.04)
        let glow = CartoucheTheme.colors(for: key).light
        ZStack {
            if isOutline {
                shape.fill(Color.white.opacity(0.05))
                shape.strokeBorder(Color.white.opacity(0.38), style: StrokeStyle(lineWidth: max(1.5, w * 0.016), dash: [w * 0.06, w * 0.045]))
                label()
            } else {
                label()
                    .frame(width: w, height: h)
                    .clipShape(shape)
                    // A faint sheen from the top, as on a case's film.
                    .overlay(shape.fill(LinearGradient(colors: [Color.white.opacity(0.1), Color.white.opacity(0)],
                                                       startPoint: .top, endPoint: UnitPoint(x: 0.5, y: 0.35))))
                    .overlay(shape.strokeBorder(Color.white.opacity(0.14), lineWidth: 1))
            }
        }
        .frame(width: w, height: h)
        .background {
            if isFocused {
                RoundedRectangle(cornerRadius: radius + ringGap, style: .continuous)
                    .stroke(Color.white, lineWidth: max(2.5, w * 0.025))
                    .padding(-ringGap)
                    .shadow(color: glow.opacity(0.9), radius: w * 0.16)
            }
        }
        .shadow(color: Color.black.opacity(isOutline ? 0 : 0.45), radius: w * 0.06, y: w * 0.04)
        .scaleEffect(isFocused ? 1.05 : 1)
        .offset(y: isFocused ? -w * 0.03 : 0)
        .animation(.spring(response: 0.32, dampingFraction: 0.72), value: isFocused)
        .contentShape(shape)
    }
}

/// The label we draw for a game the player does not have, when IGDB has no
/// cover for it: its colours, its genre and its name.
@available(iOS 17.0, *)
struct CartoucheLabelArt: View {
    let name: String
    let platform: String?
    let genre: String?
    let key: String
    /// The label's side, which sets the size of everything on it.
    let side: CGFloat

    var body: some View {
        let colors = CartoucheTheme.colors(for: key)
        ZStack(alignment: .bottomLeading) {
            LinearGradient(colors: [colors.light, colors.dark], startPoint: .topLeading, endPoint: .bottomTrailing)
            // A band of light across the label, as on a printed sticker.
            LinearGradient(colors: [Color.white.opacity(0), Color.white.opacity(0.13), Color.white.opacity(0)],
                           startPoint: UnitPoint(x: 0, y: 0.25), endPoint: UnitPoint(x: 1, y: 0.65))
            Image(systemName: CartoucheTheme.symbol(genre: genre))
                .font(.system(size: side * 0.46, weight: .bold))
                .foregroundStyle(Color.white.opacity(0.17))
                .rotationEffect(.degrees(-12))
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                .offset(x: side * 0.08, y: -side * 0.04)
            VStack(alignment: .leading, spacing: side * 0.03) {
                if let platform, side >= 70 {
                    Text(CartoucheText.platform(platform).uppercased())
                        .font(.system(size: max(7, side * 0.075), weight: .heavy, design: .rounded))
                        .tracking(side * 0.008)
                        .foregroundStyle(Color.white)
                        .padding(.horizontal, side * 0.04)
                        .padding(.vertical, side * 0.015)
                        .background(Color.black.opacity(0.28), in: Capsule())
                }
                Spacer(minLength: 0)
                Text(name)
                    .font(.system(size: max(8, side * 0.135), weight: .bold, design: .rounded))
                    .foregroundStyle(Color.white)
                    .lineLimit(side >= 70 ? 3 : 2)
                    .minimumScaleFactor(0.6)
                    .multilineTextAlignment(.leading)
                    .shadow(color: Color.black.opacity(0.35), radius: 2, y: 1)
            }
            .padding(side * 0.075)
        }
    }
}

/// The icon of the player's own copy, from LiveContainer's cache.
@available(iOS 17.0, *)
struct CartoucheAppIcon: View {
    let app: LCAppModel
    var size: CGFloat = 64
    /// Square, to fill a cartridge's label, or rounded as on the home screen.
    var rounded = true

    var body: some View {
        Group {
            if let icon = app.appInfo.iconIsDarkIcon(true) {
                Image(uiImage: icon).resizable().scaledToFill()
            } else {
                ZStack {
                    CartoucheTheme.brand
                    Image(systemName: "gamecontroller.fill")
                        .font(.system(size: size * 0.4, weight: .bold))
                        .foregroundStyle(Color.white)
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: rounded ? size * 0.225 : 0, style: .continuous))
    }
}

/// A game as a cartridge: its official cover, whole, the player's copy or
/// not; without one, the icon of the player's copy or our label.
@available(iOS 17.0, *)
struct CartoucheGameCartridge: View {
    let entry: CartoucheEntry
    let width: CGFloat
    var isFocused = false
    /// The game runs behind the console, paused there.
    var isPaused = false

    var body: some View {
        let side = width
        CartoucheCartridge(width: width, key: entry.tileKey, isFocused: isFocused) {
            if let cover = entry.cover?.cover {
                CartoucheCoverImage(id: cover, whole: true) {
                    drawnLabel(side: side)
                }
            } else {
                drawnLabel(side: side)
            }
        }
        // A newer build of the installed game is in the games folder.
        .overlay(alignment: .topTrailing) {
            if entry.update != nil {
                Image(systemName: "arrow.down.circle.fill")
                    .font(.system(size: max(14, width * 0.16), weight: .bold))
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(Color.white, CartouchePlayStatus.update.color)
                    .shadow(color: Color.black.opacity(0.35), radius: 2, y: 1)
                    .padding(width * 0.04)
            }
        }
        .overlay(alignment: .topLeading) {
            if isPaused {
                Image(systemName: CartouchePlayStatus.paused.symbol)
                    .font(.system(size: max(14, width * 0.16), weight: .bold))
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(Color.white, CartouchePlayStatus.paused.color)
                    .shadow(color: Color.black.opacity(0.35), radius: 2, y: 1)
                    .padding(width * 0.04)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(entry.name))
        .accessibilityValue(Text(isPaused ? CartouchePlayStatus.paused.short : CartouchePlayStatus.of(entry).short))
    }

    /// Until the cover has loaded, and for a game IGDB has no cover for: the
    /// icon of the player's copy over its name, or the label we design.
    @ViewBuilder
    private func drawnLabel(side: CGFloat) -> some View {
        if let app = entry.app {
            let colors = CartoucheTheme.colors(for: entry.tileKey)
            ZStack(alignment: .top) {
                LinearGradient(colors: [colors.light, colors.dark], startPoint: .topLeading, endPoint: .bottomTrailing)
                VStack(alignment: .leading, spacing: side * 0.06) {
                    CartoucheAppIcon(app: app, size: side, rounded: false)
                    Text(entry.name)
                        .font(.system(size: max(8, side * 0.12), weight: .bold, design: .rounded))
                        .foregroundStyle(Color.white)
                        .lineLimit(2)
                        .minimumScaleFactor(0.7)
                        .padding(.horizontal, side * 0.07)
                }
            }
        } else {
            CartoucheLabelArt(name: entry.name, platform: entry.platform, genre: entry.genre, key: entry.tileKey, side: side)
        }
    }
}

/// The cartridge that imports a game: an outline with a plus.
@available(iOS 17.0, *)
struct CartoucheImportCartridge: View {
    let width: CGFloat
    var isFocused = false

    var body: some View {
        CartoucheCartridge(width: width, key: "import", isFocused: isFocused, isOutline: true) {
            VStack(spacing: width * 0.06) {
                Image(systemName: "plus")
                    .font(.system(size: width * 0.24, weight: .semibold))
                Text(CartoucheText.importTile)
                    .font(.system(size: max(8, width * 0.1), weight: .semibold, design: .rounded))
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .minimumScaleFactor(0.7)
            }
            .foregroundStyle(Color.white.opacity(0.85))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(CartoucheText.importCopy))
        .accessibilityAddTraits(.isButton)
    }
}

/// The cartridge at the end of a shelf that opens the list of every game.
@available(iOS 17.0, *)
struct CartoucheAllGamesCartridge: View {
    let width: CGFloat
    let count: Int
    var isFocused = false

    var body: some View {
        CartoucheCartridge(width: width, key: "all", isFocused: isFocused, isOutline: true) {
            VStack(spacing: width * 0.05) {
                Image(systemName: "square.grid.2x2.fill")
                    .font(.system(size: width * 0.22, weight: .semibold))
                Text(CartoucheText.allGames)
                    .font(.system(size: max(8, width * 0.1), weight: .semibold, design: .rounded))
                    .lineLimit(2)
                    .minimumScaleFactor(0.7)
                Text(verbatim: "\(count)")
                    .font(.system(size: max(7, width * 0.085), weight: .bold, design: .rounded).monospacedDigit())
                    .foregroundStyle(CartoucheTheme.secondaryText)
            }
            .multilineTextAlignment(.center)
            .foregroundStyle(Color.white.opacity(0.85))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(CartoucheText.allGames))
        .accessibilityAddTraits(.isButton)
    }
}

/// Where a game plays, in a word or two with its symbol.
@available(iOS 17.0, *)
struct CartoucheStatusLabel: View {
    let status: CartouchePlayStatus
    var font: Font = .caption.weight(.semibold)

    var body: some View {
        Label(status.short, systemImage: status.symbol)
            .font(font)
            .foregroundStyle(status.color)
            .labelStyle(CartoucheTightLabelStyle())
            .lineLimit(1)
            .minimumScaleFactor(0.75)
    }
}

/// A label's icon close to its title.
struct CartoucheTightLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 4) {
            configuration.icon
            configuration.title
        }
    }
}

/// How a game fits this iPhone, from its testers' sheet.
@available(iOS 17.0, *)
struct CartoucheFitBadge: View {
    let fit: CartoucheFit?
    var owned = false

    var body: some View {
        Label(text, systemImage: symbol)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(color)
            .labelStyle(CartoucheTightLabelStyle())
            .lineLimit(2)
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
        case .recommended: return CartouchePlayStatus.ready.color
        case .untested: return owned ? CartouchePlayStatus.ready.color : CartoucheTheme.secondaryText
        case .notRecommended: return .orange
        case .unsupported: return .red
        case nil: return CartoucheTheme.secondaryText
        }
    }
}
