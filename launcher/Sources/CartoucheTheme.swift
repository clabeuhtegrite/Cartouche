//
//  CartoucheTheme.swift
//  Cartouche
//
//  The look of the console screens: a dark stage lit by the colours of the
//  game in focus, Cartouche's own indigo and pink, and Liquid Glass where
//  iOS has it (iOS 26 and later), frosted material before.
//

import SwiftUI

@available(iOS 17.0, *)
enum CartoucheTheme {
    /// The stage behind every console screen.
    static let stage = Color(red: 0.035, green: 0.039, blue: 0.067)
    /// Cartouche's colours, those of its icon.
    static let indigo = Color(red: 0.310, green: 0.275, blue: 0.898)
    static let pink = Color(red: 0.925, green: 0.282, blue: 0.600)
    static let brand = LinearGradient(colors: [indigo, pink], startPoint: .leading, endPoint: .trailing)
    /// The gold of a cartridge's contacts.
    static let gold = LinearGradient(
        colors: [Color(red: 1.0, green: 0.859, blue: 0.494), Color(red: 0.910, green: 0.647, blue: 0.208)],
        startPoint: .top, endPoint: .bottom)

    /// A cartridge's height for its width.
    static let cartridgeAspect: CGFloat = 1.32

    static let secondaryText = Color.white.opacity(0.68)
    /// A step that cannot be undone, such as Uninstall, legible on the stage.
    static let danger = Color(red: 1.0, green: 0.45, blue: 0.45)
    static let tertiaryText = Color.white.opacity(0.45)

    /// Two colours from a game's title ID, the same on every launch and
    /// every iPhone: a light one and a deep one.
    static func colors(for key: String) -> (light: Color, dark: Color) {
        let hue = hue(for: key)
        let shifted = (hue + 0.07).truncatingRemainder(dividingBy: 1)
        return (Color(hue: hue, saturation: 0.62, brightness: 0.90),
                Color(hue: shifted, saturation: 0.80, brightness: 0.40))
    }

    /// The cartridge's own body colour: the game's hue, darker and calmer
    /// than its label.
    static func bodyColors(for key: String) -> (top: Color, bottom: Color) {
        let hue = hue(for: key)
        return (Color(hue: hue, saturation: 0.42, brightness: 0.34),
                Color(hue: hue, saturation: 0.50, brightness: 0.19))
    }

    private static func hue(for key: String) -> Double {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in key.utf8 {
            hash = (hash ^ UInt64(byte)) &* 0x100000001b3
        }
        return Double(hash % 360) / 360
    }

    /// A symbol for each genre of nxnative.json.
    static func symbol(genre: String?) -> String {
        switch genre {
        case "action": return "bolt.fill"
        case "adventure": return "map.fill"
        case "rpg": return "shield.lefthalf.filled"
        case "puzzle": return "puzzlepiece.fill"
        case "strategy": return "crown.fill"
        case "simulation": return "building.2.fill"
        case "racing": return "flag.checkered"
        case "sports": return "sportscourt.fill"
        case "board": return "dice.fill"
        case "card": return "suit.spade.fill"
        case "family": return "figure.2.and.child.holdinghands"
        case "music": return "music.note"
        default: return "gamecontroller.fill"
        }
    }
}

/// Where a game plays, as the catalogue shows it.
@available(iOS 17.0, *)
enum CartouchePlayStatus: Hashable {
    /// The player has a copy and Cartouche can start it.
    case ready
    case iphone
    case mac
    case bringup
    case unknown

    static func of(_ entry: CartoucheEntry) -> CartouchePlayStatus {
        if entry.isOwned { return .ready }
        if entry.playsOnIPhone { return .iphone }
        switch entry.game?.status {
        case "mac": return .mac
        case "bringup": return .bringup
        case "iphone": return .iphone
        default: return .unknown
        }
    }

    var symbol: String {
        switch self {
        case .ready: return "checkmark.circle.fill"
        case .iphone: return "iphone"
        case .mac: return "laptopcomputer"
        case .bringup: return "hammer.fill"
        case .unknown: return "questionmark.circle.fill"
        }
    }

    var color: Color {
        switch self {
        case .ready: return Color(red: 0.204, green: 0.827, blue: 0.494)
        case .iphone: return Color(red: 0.204, green: 0.827, blue: 0.494)
        case .mac: return Color(red: 0.384, green: 0.639, blue: 1.0)
        case .bringup: return Color(red: 1.0, green: 0.690, blue: 0.247)
        case .unknown: return Color.white.opacity(0.55)
        }
    }

    /// A word or two, under a tile.
    var short: String {
        switch self {
        case .ready: return CartoucheText.statusReadyShort
        case .iphone: return CartoucheText.statusIPhoneShort
        case .mac: return CartoucheText.statusMacShort
        case .bringup: return CartoucheText.statusBringupShort
        case .unknown: return CartoucheText.statusUnknownShort
        }
    }

    /// A sentence, on the game's sheet.
    var long: String {
        switch self {
        case .ready, .iphone: return CartoucheText.statusIPhoneLong
        case .mac: return CartoucheText.statusMacLong
        case .bringup: return CartoucheText.statusBringupLong
        case .unknown: return CartoucheText.statusUnknownLong
        }
    }
}

@available(iOS 17.0, *)
extension View {
    /// Liquid Glass in this shape on iOS 26 and later, frosted material
    /// before.
    @ViewBuilder
    func cartoucheGlass<S: Shape>(in shape: S, interactive: Bool = false) -> some View {
        if #available(iOS 26.0, *) {
            self.glassEffect(interactive ? Glass.regular.interactive() : Glass.regular, in: shape)
        } else {
            self.background(.ultraThinMaterial, in: shape)
                .overlay(shape.stroke(Color.white.opacity(0.12), lineWidth: 1))
        }
    }

    /// The main action of a screen: glass in Cartouche's colours on iOS 26
    /// and later, a filled button before.
    @ViewBuilder
    func cartouchePrimaryButton() -> some View {
        if #available(iOS 26.0, *) {
            self.buttonStyle(.glassProminent).tint(CartoucheTheme.indigo)
        } else {
            self.buttonStyle(.borderedProminent).tint(CartoucheTheme.indigo)
        }
    }

    /// A second action beside the main one.
    @ViewBuilder
    func cartoucheSecondaryButton() -> some View {
        if #available(iOS 26.0, *) {
            self.buttonStyle(.glass)
        } else {
            self.buttonStyle(.bordered).tint(.white)
        }
    }
}

/// The stage: dark, lit from above by the colours of the game in focus.
@available(iOS 17.0, *)
struct CartoucheStage: View {
    /// The tile key of the game in focus, or nil for Cartouche's colours.
    let key: String?

    var body: some View {
        let colors = key.map(CartoucheTheme.colors(for:)) ?? (light: CartoucheTheme.indigo, dark: CartoucheTheme.pink)
        ZStack {
            CartoucheTheme.stage
            RadialGradient(colors: [colors.light.opacity(0.55), colors.light.opacity(0)],
                           center: UnitPoint(x: 0.15, y: 0.0), startRadius: 0, endRadius: 520)
            RadialGradient(colors: [colors.dark.opacity(0.65), colors.dark.opacity(0)],
                           center: UnitPoint(x: 0.95, y: 0.35), startRadius: 0, endRadius: 460)
            LinearGradient(colors: [Color.black.opacity(0), Color.black.opacity(0.55)],
                           startPoint: .center, endPoint: .bottom)
        }
        .animation(.easeInOut(duration: 0.45), value: key)
        .ignoresSafeArea()
    }
}

/// Cartouche's name, in its colours.
@available(iOS 17.0, *)
struct CartoucheWordmark: View {
    var size: CGFloat = 24

    var body: some View {
        HStack(spacing: size * 0.32) {
            CartoucheCartridgeShape()
                .fill(CartoucheTheme.brand)
                .frame(width: size * 0.72, height: size * 0.95)
                .overlay(alignment: .top) {
                    VStack(spacing: size * 0.06) {
                        ForEach(0..<2, id: \.self) { _ in
                            Capsule().fill(Color.white.opacity(0.55)).frame(width: size * 0.32, height: size * 0.05)
                        }
                    }
                    .padding(.top, size * 0.11)
                }
            Text(verbatim: "Cartouche")
                .font(.system(size: size, weight: .heavy, design: .rounded))
                .foregroundStyle(CartoucheTheme.brand)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: "Cartouche"))
        .accessibilityAddTraits(.isHeader)
    }
}
