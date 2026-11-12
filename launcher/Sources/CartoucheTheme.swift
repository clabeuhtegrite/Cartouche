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

    /// A game's tile, its width over its height: a game case's, so that a
    /// game's official cover shows whole. IGDB's covers run from about 0.6,
    /// a Switch case, to 0.75; a narrower or wider one shows over a blurred
    /// copy of itself (CartoucheCoverImage).
    static let labelAspect: CGFloat = 0.68

    /// A game's tile's height for its width: its cover, nothing around it.
    static let cartridgeAspect: CGFloat = 1 / labelAspect

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
    /// The player has a copy, and a newer build of it is in their games
    /// folder.
    case update
    /// The player's copy is in their games folder, not on this iPhone.
    case stored
    /// The player's copy runs behind the console, paused there.
    case paused
    case iphone
    case mac
    case bringup
    case unknown

    static func of(_ entry: CartoucheEntry) -> CartouchePlayStatus {
        if entry.isInstalled { return entry.update != nil ? .update : .ready }
        if entry.stored != nil { return .stored }
        if entry.playsOnIPhone { return .iphone }
        switch entry.game?.status {
        case "mac": return .mac
        case "bringup": return .bringup
        case "iphone": return .iphone
        default: return .unknown
        }
    }

    /// As of(_:), with the game that runs behind the console paused there.
    @MainActor
    static func of(_ entry: CartoucheEntry, in actions: CartoucheGameActions) -> CartouchePlayStatus {
        actions.isRunning(entry.app) ? .paused : of(entry)
    }

    var symbol: String {
        switch self {
        case .ready: return "checkmark.circle.fill"
        case .update: return "arrow.down.circle.fill"
        case .stored: return "externaldrive.fill"
        case .paused: return "pause.circle.fill"
        case .iphone: return "iphone"
        case .mac: return "laptopcomputer"
        case .bringup: return "hammer.fill"
        case .unknown: return "questionmark.circle.fill"
        }
    }

    var color: Color {
        switch self {
        case .ready: return Color(red: 0.204, green: 0.827, blue: 0.494)
        case .update, .stored: return Color(red: 0.392, green: 0.824, blue: 1.0)
        case .paused: return CartoucheTheme.pink
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
        case .update: return CartoucheText.statusUpdateShort
        case .stored: return CartoucheText.statusStoredShort
        case .paused: return CartoucheText.statusPausedShort
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
        case .update: return CartoucheText.statusUpdateLong
        case .stored: return CartoucheText.statusStoredLong
        case .paused: return CartoucheText.pausedDetail
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

    /// A list or a form on the console's dark stage, as a game's sheet has
    /// it, in place of the system's grouped background: the System page
    /// and the pages under it look like the console they open over.
    func cartoucheStageBackground(key: String? = nil) -> some View {
        self.scrollContentBackground(.hidden)
            .background(CartoucheStage(key: key))
    }

    /// A game's cartridge that its sheet grows out of (iOS 18 and later).
    @ViewBuilder
    func cartoucheZoomSource(_ id: String, in namespace: Namespace.ID?) -> some View {
        if #available(iOS 18.0, *), let namespace {
            self.matchedTransitionSource(id: id, in: namespace)
        } else {
            self
        }
    }

    /// A game's sheet, grown out of its cartridge and shrinking back into it
    /// (iOS 18 and later); it slides up from the bottom before.
    @ViewBuilder
    func cartoucheZoom(from id: String?, in namespace: Namespace.ID?) -> some View {
        if #available(iOS 18.0, *), let id, let namespace {
            self.navigationTransition(.zoom(sourceID: id, in: namespace))
        } else {
            self
        }
    }
}

/// The stage: dark, lit from above by the colours of the game in focus,
/// with its image faintly behind them when it has one: its official
/// artwork, else its cover, or the player's own cover
/// (CartoucheEntry.backdrop).
@available(iOS 17.0, *)
struct CartoucheStage: View {
    /// The tile key of the game in focus, or nil for Cartouche's colours.
    let key: String?
    /// The game's image, shown faintly at the top.
    var art: CartoucheArt? = nil

    var body: some View {
        let colors = key.map(CartoucheTheme.colors(for:)) ?? (light: CartoucheTheme.indigo, dark: CartoucheTheme.pink)
        ZStack {
            CartoucheTheme.stage
            if let art {
                GeometryReader { frame in
                    CartoucheCoverImage(art: art, anchor: 0.5) { Color.clear }
                        .frame(width: frame.size.width, height: frame.size.height * 0.62)
                        .blur(radius: 10)
                        .opacity(0.5)
                        .mask(LinearGradient(colors: [Color.black, Color.black.opacity(0)],
                                             startPoint: .top, endPoint: .bottom))
                }
                .id(art)
                .transition(.opacity)
            }
            RadialGradient(colors: [colors.light.opacity(0.55), colors.light.opacity(0)],
                           center: UnitPoint(x: 0.15, y: 0.0), startRadius: 0, endRadius: 520)
            RadialGradient(colors: [colors.dark.opacity(0.65), colors.dark.opacity(0)],
                           center: UnitPoint(x: 0.95, y: 0.35), startRadius: 0, endRadius: 460)
            LinearGradient(colors: [Color.black.opacity(0), Color.black.opacity(0.55)],
                           startPoint: .center, endPoint: .bottom)
        }
        .animation(.easeInOut(duration: 0.45), value: key)
        .animation(.easeInOut(duration: 0.45), value: art)
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
