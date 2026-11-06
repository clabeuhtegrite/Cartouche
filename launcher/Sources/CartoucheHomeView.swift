//
//  CartoucheHomeView.swift
//  Cartouche
//
//  The console's home: the player's games on the first shelf, then the
//  games nxnative plays on the iPhone, the game in focus described under
//  them with its main action, and a dock to the rest of Cartouche. The
//  stage takes the colours of the game in focus.
//
//  Touch and a game controller both drive it. A tap puts a game in focus,
//  a second tap opens its sheet; with a controller, the D-pad moves, A
//  does the main action, X opens the sheet, Y every game and Menu the
//  system page.
//
//  The layout follows the space the screen gives it, never the iPhone
//  model: one column when the screen is taller than wide (an iPhone, the
//  iPhone Duo folded or unfolded upright), the shelves beside the game in
//  focus when it is wider.
//

import SwiftUI

@available(iOS 17.0, *)
struct CartoucheHomeView: View {
    let entries: CartoucheCatalog.Entries
    let gameCount: Int
    /// Whether the home is on screen, with nothing over it, so that it
    /// takes the controller.
    let isActive: Bool
    let onPlay: (LCAppModel) -> Void
    let onImport: () -> Void
    /// Installs a game from the player's games folder.
    let onInstall: (CartoucheStoredGame) -> Void
    let onUninstall: (LCAppModel) -> Void
    let onSheet: (CartoucheEntry) -> Void
    let onLibrary: () -> Void
    let onSetup: () -> Void
    let onTab: (LCTabIdentifier) -> Void
    /// Where a game's sheet grows out of its cartridge.
    let zoom: Namespace.ID?

    // Written out: before Swift 6.4 (SE-0502), the private state below made
    // the synthesized initializer private.
    init(entries: CartoucheCatalog.Entries, gameCount: Int, isActive: Bool,
         onPlay: @escaping (LCAppModel) -> Void, onImport: @escaping () -> Void,
         onInstall: @escaping (CartoucheStoredGame) -> Void = { _ in },
         onUninstall: @escaping (LCAppModel) -> Void, onSheet: @escaping (CartoucheEntry) -> Void,
         onLibrary: @escaping () -> Void, onSetup: @escaping () -> Void,
         onTab: @escaping (LCTabIdentifier) -> Void, zoom: Namespace.ID? = nil) {
        self.entries = entries
        self.gameCount = gameCount
        self.isActive = isActive
        self.onPlay = onPlay
        self.onImport = onImport
        self.onInstall = onInstall
        self.onUninstall = onUninstall
        self.onSheet = onSheet
        self.onLibrary = onLibrary
        self.onSetup = onSetup
        self.onTab = onTab
        self.zoom = zoom
    }

    @ObservedObject private var setup = CartoucheSetup.shared
    @ObservedObject private var gamepad = CartoucheGamepad.shared
    @State private var row = 0
    @State private var columns = [0, 0, 0]
    @State private var heroRow = 0
    @State private var signature = CartoucheSignature.current()

    enum Item: Hashable {
        case game(CartoucheEntry)
        case importGame
        case allGames
        case dock(Dock)
    }

    /// Cartouche's own pages only: LiveContainer's and the built-in
    /// SideStore's never show (docs/decisions.md, 24).
    enum Dock: CaseIterable, Hashable {
        case allGames, importGame, system
    }

    /// The player's games, then the cartridge that imports one.
    private var libraryShelf: [Item] {
        entries.owned.map(Item.game) + [.importGame]
    }

    /// The games nxnative plays on the iPhone that the player has not
    /// imported, then the cartridge that opens every game.
    private var iPhoneShelf: [Item] {
        entries.others.filter(\.playsOnIPhone).map(Item.game) + [.allGames]
    }

    private var rows: [[Item]] {
        [libraryShelf, iPhoneShelf, Dock.allCases.map(Item.dock)]
    }

    private func item(row: Int) -> Item? {
        let items = rows[row]
        guard !items.isEmpty else { return nil }
        return items[min(columns[row], items.count - 1)]
    }

    private var focused: Item? { item(row: row) }

    /// What the description under the shelves shows: the game in focus, or
    /// the last one when the focus is on the dock.
    private var hero: Item? { item(row: heroRow) }

    var body: some View {
        GeometryReader { proxy in
            let metrics = Metrics(size: proxy.size)
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: metrics.spacing) {
                    topBar
                    if setup.needsSetup {
                        CartoucheHomeSetupBanner(action: onSetup)
                    }
                    if metrics.isWide {
                        HStack(alignment: .top, spacing: metrics.spacing * 1.5) {
                            VStack(alignment: .leading, spacing: metrics.spacing) {
                                shelves(metrics)
                            }
                            .frame(width: metrics.shelvesWidth, alignment: .leading)
                            heroView(metrics)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    } else {
                        shelf(0, title: CartoucheText.homeLibrary, width: metrics.bigTile)
                        heroView(metrics)
                        shelf(1, title: CartoucheText.homeIPhone, width: metrics.smallTile)
                    }
                }
                .padding(.horizontal, metrics.margin)
                .padding(.vertical, 12)
            }
            .scrollBounceBehavior(.basedOnSize)
            .scrollIndicators(.hidden)
            // The dock stays at the bottom, the shelves scrolling under it
            // where the screen is short (the iPhone Duo folded, sideways).
            .safeAreaInset(edge: .bottom, spacing: 0) {
                VStack(spacing: 10) {
                    dock
                    if gamepad.isConnected {
                        hints
                    }
                }
                .padding(.horizontal, metrics.margin)
                .padding(.top, 14)
                .padding(.bottom, 4)
                .background {
                    LinearGradient(colors: [CartoucheTheme.stage.opacity(0), CartoucheTheme.stage.opacity(0.88)],
                                   startPoint: .top, endPoint: UnitPoint(x: 0.5, y: 0.45))
                        .ignoresSafeArea(edges: .bottom)
                }
            }
        }
        .background(CartoucheStage(key: heroKey, artwork: heroArtwork))
        .onReceive(gamepad.inputs) { input in
            if isActive { handle(input) }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
            signature = CartoucheSignature.current()
        }
    }

    private var heroKey: String? {
        if case .game(let entry) = hero { return entry.tileKey }
        return nil
    }

    private var heroArtwork: String? {
        if case .game(let entry) = hero { return entry.cover?.artwork }
        return nil
    }

    // MARK: Top bar

    private var topBar: some View {
        HStack(spacing: 10) {
            CartoucheWordmark(size: 24)
            Spacer(minLength: 8)
            if gamepad.isConnected {
                Image(systemName: "gamecontroller.fill")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(CartoucheTheme.secondaryText)
                    .padding(.horizontal, 12)
                    .frame(height: 34)
                    .cartoucheGlass(in: Capsule())
                    .accessibilityLabel(Text(CartoucheText.controllerConnected))
            }
            if let days = signature.daysLeft {
                Button {
                    onTab(.system)
                } label: {
                    Label(CartoucheText.daysLeftShort(max(days, 0)), systemImage: "hourglass")
                        .font(.subheadline.weight(.semibold).monospacedDigit())
                        .labelStyle(CartoucheTightLabelStyle())
                        .foregroundStyle(days <= 1 ? Color.orange : CartoucheTheme.secondaryText)
                        .padding(.horizontal, 12)
                        .frame(height: 34)
                        .cartoucheGlass(in: Capsule(), interactive: true)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(CartoucheText.expires))
                .accessibilityValue(Text(CartoucheText.daysLeftShort(max(days, 0))))
            }
        }
        .frame(minHeight: 44)
    }

    // MARK: Shelves

    @ViewBuilder
    private func shelves(_ metrics: Metrics) -> some View {
        shelf(0, title: CartoucheText.homeLibrary, width: metrics.bigTile)
        shelf(1, title: CartoucheText.homeIPhone, width: metrics.smallTile)
    }

    private func shelf(_ index: Int, title: String, width: CGFloat) -> some View {
        let items = rows[index]
        return VStack(alignment: .leading, spacing: 10) {
            Text(title.uppercased())
                .font(.caption.weight(.heavy))
                .tracking(1.4)
                .foregroundStyle(CartoucheTheme.secondaryText)
                .accessibilityAddTraits(.isHeader)
            ScrollViewReader { reader in
                ScrollView(.horizontal) {
                    LazyHStack(alignment: .top, spacing: width * 0.16) {
                        ForEach(Array(items.enumerated()), id: \.element) { column, item in
                            tile(item, width: width, isFocused: row == index && columns[index] == column)
                                .id(item)
                                .onTapGesture { tapped(item, row: index, column: column) }
                        }
                    }
                    // Room for the focused cartridge's ring and glow.
                    .padding(.vertical, width * 0.1)
                    .padding(.horizontal, width * 0.06)
                }
                .scrollIndicators(.hidden)
                .scrollClipDisabled()
                .onChange(of: columns[index]) { _, column in
                    guard row == index, column < items.count else { return }
                    withAnimation(.easeOut(duration: 0.25)) {
                        reader.scrollTo(items[column], anchor: .center)
                    }
                }
            }
            .padding(.horizontal, -width * 0.06)
        }
    }

    @ViewBuilder
    private func tile(_ item: Item, width: CGFloat, isFocused: Bool) -> some View {
        switch item {
        case .game(let entry):
            CartoucheGameCartridge(entry: entry, width: width, isFocused: isFocused)
                .cartoucheZoomSource(entry.id, in: zoom)
                .accessibilityAddTraits(.isButton)
                .accessibilityAction(named: Text(CartoucheText.details)) { onSheet(entry) }
                .contextMenu { gameMenu(entry) }
        case .importGame:
            CartoucheImportCartridge(width: width, isFocused: isFocused)
        case .allGames:
            CartoucheAllGamesCartridge(width: width, count: gameCount, isFocused: isFocused)
        case .dock:
            EmptyView()
        }
    }

    /// A long press on a game: what its sheet offers, the game's settings
    /// being in the sheet.
    @ViewBuilder
    private func gameMenu(_ entry: CartoucheEntry) -> some View {
        if let app = entry.app {
            Button { onPlay(app) } label: { Label(CartoucheText.play, systemImage: "play.fill") }
        } else if let stored = entry.stored {
            Button { onInstall(stored) } label: { Label(installTitle, systemImage: "arrow.down.circle.fill") }
        } else {
            Button(action: onImport) { Label(CartoucheText.importCopy, systemImage: "square.and.arrow.down") }
        }
        Button { onSheet(entry) } label: { Label(CartoucheText.details, systemImage: "info.circle") }
        if let app = entry.app {
            Divider()
            Button(role: .destructive) { onUninstall(app) } label: { Label(CartoucheText.uninstall, systemImage: "trash") }
        }
    }

    // MARK: The game in focus

    @ViewBuilder
    private func heroView(_ metrics: Metrics) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            switch hero {
            case .game(let entry):
                gameHero(entry, metrics: metrics)
            case .importGame:
                heroText(CartoucheText.importTile, CartoucheText.emptyMessage, metrics: metrics)
                actionButton(CartoucheText.importCopy, systemImage: "square.and.arrow.down", primary: true, action: onImport)
            case .allGames:
                heroText(CartoucheText.allGames, CartoucheText.allGamesDetail(gameCount), metrics: metrics)
                actionButton(CartoucheText.allGames, systemImage: "square.grid.2x2.fill", primary: true, action: onLibrary)
            case .dock, nil:
                EmptyView()
            }
        }
        .frame(maxWidth: 560, alignment: .leading)
        .animation(.easeInOut(duration: 0.2), value: hero)
    }

    private func heroText(_ title: String, _ detail: String, metrics: Metrics) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: metrics.titleSize, weight: .heavy, design: .rounded))
                .foregroundStyle(Color.white)
                .lineLimit(2)
                .minimumScaleFactor(0.7)
            Text(detail)
                .font(.subheadline)
                .foregroundStyle(CartoucheTheme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func gameHero(_ entry: CartoucheEntry, metrics: Metrics) -> some View {
        let status = CartouchePlayStatus.of(entry)
        return VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                Text(entry.name)
                    .font(.system(size: metrics.titleSize, weight: .heavy, design: .rounded))
                    .foregroundStyle(Color.white)
                    .lineLimit(2)
                    .minimumScaleFactor(0.7)
                CartoucheMetaLine(entry: entry)
                Text(status == .ready && !setup.canPlay ? CartoucheText.setupBannerDetail : status.long)
                    .font(.subheadline)
                    .foregroundStyle(CartoucheTheme.secondaryText)
                    .lineLimit(2)
            }
            HStack(spacing: 10) {
                if let app = entry.app {
                    actionButton(CartoucheText.play, systemImage: "play.fill", primary: true) { onPlay(app) }
                } else if let stored = entry.stored {
                    actionButton(installTitle, systemImage: "arrow.down.circle.fill", primary: true) { onInstall(stored) }
                } else {
                    actionButton(CartoucheText.importCopy, systemImage: "square.and.arrow.down", primary: true, action: onImport)
                }
                actionButton(CartoucheText.details, systemImage: "info.circle", primary: false) { onSheet(entry) }
            }
        }
    }

    /// Install from the player's games folder, naming its server.
    private var installTitle: String {
        CartoucheText.installFrom(CartoucheStoredGames.shared.serverName ?? "")
    }

    @ViewBuilder
    private func actionButton(_ title: String, systemImage: String, primary: Bool, action: @escaping () -> Void) -> some View {
        let button = Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.headline)
                .padding(.horizontal, 6)
                .frame(minHeight: 30)
        }
        .controlSize(.large)
        if primary {
            button.cartouchePrimaryButton()
        } else {
            button.cartoucheSecondaryButton()
        }
    }

    // MARK: Dock

    private var dock: some View {
        HStack(alignment: .top, spacing: 0) {
            ForEach(Array(Dock.allCases.enumerated()), id: \.element) { column, item in
                let isFocused = row == 2 && columns[2] == column
                Button {
                    activate(.dock(item))
                } label: {
                    VStack(spacing: 6) {
                        Image(systemName: Self.symbol(item))
                            .font(.system(size: 21, weight: .semibold))
                            .foregroundStyle(Color.white)
                            .frame(width: 54, height: 54)
                            .cartoucheGlass(in: Circle(), interactive: true)
                            .overlay(Circle().stroke(Color.white, lineWidth: isFocused ? 3 : 0).padding(-4))
                            .scaleEffect(isFocused ? 1.08 : 1)
                        Text(Self.title(item))
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(isFocused ? Color.white : CartoucheTheme.secondaryText)
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                    }
                    .frame(maxWidth: .infinity)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .animation(.spring(response: 0.3, dampingFraction: 0.7), value: isFocused)
            }
        }
        .frame(maxWidth: 520)
        .frame(maxWidth: .infinity)
    }

    static func symbol(_ item: Dock) -> String {
        switch item {
        case .allGames: return "square.grid.2x2.fill"
        case .importGame: return "square.and.arrow.down"
        case .system: return "cpu"
        }
    }

    static func title(_ item: Dock) -> String {
        switch item {
        case .allGames: return CartoucheText.allGames
        case .importGame: return CartoucheText.dockImport
        case .system: return CartoucheText.systemTab
        }
    }

    // MARK: Controller hints

    private var hints: some View {
        HStack(spacing: 16) {
            switch focused {
            case .game(let entry):
                CartoucheHint(input: .a, title: entry.app != nil ? CartoucheText.play : CartoucheText.details)
                CartoucheHint(input: .x, title: CartoucheText.details)
            case .importGame:
                CartoucheHint(input: .a, title: CartoucheText.dockImport)
            case .allGames, .dock, nil:
                CartoucheHint(input: .a, title: CartoucheText.hintOpen)
            }
            CartoucheHint(input: .y, title: CartoucheText.allGames)
            CartoucheHint(input: .menu, title: CartoucheText.systemTab)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .padding(.horizontal, 16)
        .cartoucheGlass(in: Capsule())
    }

    // MARK: Actions

    private func tapped(_ item: Item, row tappedRow: Int, column: Int) {
        switch item {
        case .game(let entry):
            if row == tappedRow && columns[tappedRow] == column {
                onSheet(entry)
            } else {
                focus(row: tappedRow, column: column)
            }
        default:
            focus(row: tappedRow, column: column)
            activate(item)
        }
    }

    private func focus(row newRow: Int, column: Int) {
        row = newRow
        columns[newRow] = column
        if newRow < 2 { heroRow = newRow }
    }

    private func activate(_ item: Item) {
        switch item {
        case .game(let entry):
            if let app = entry.app {
                onPlay(app)
            } else {
                onSheet(entry)
            }
        case .importGame, .dock(.importGame):
            onImport()
        case .allGames, .dock(.allGames):
            onLibrary()
        case .dock(.system):
            onTab(.system)
        }
    }

    private func handle(_ input: CartoucheGamepad.Input) {
        switch input {
        case .left:
            if columns[row] > 0 { focus(row: row, column: columns[row] - 1) }
        case .right:
            if columns[row] < rows[row].count - 1 { focus(row: row, column: columns[row] + 1) }
        case .up:
            if row > 0 { focus(row: row - 1, column: min(columns[row - 1], rows[row - 1].count - 1)) }
        case .down:
            if row < rows.count - 1 { focus(row: row + 1, column: min(columns[row + 1], rows[row + 1].count - 1)) }
        case .a:
            if let focused { activate(focused) }
        case .x:
            if case .game(let entry) = focused { onSheet(entry) }
        case .y:
            onLibrary()
        case .menu:
            onTab(.system)
        case .b:
            if row == 2 { focus(row: heroRow, column: columns[heroRow]) }
        case .previous, .next:
            break
        }
    }

    // MARK: Layout

    struct Metrics {
        let size: CGSize

        /// Wider than tall: the shelves beside the game in focus.
        var isWide: Bool { size.width > size.height * 1.15 }
        var margin: CGFloat { size.width >= 600 ? 28 : 18 }
        var spacing: CGFloat { size.height < 500 ? 12 : 20 }
        var shelvesWidth: CGFloat { (size.width - 2 * margin) * 0.6 }
        var titleSize: CGFloat { isWide ? 26 : (size.width >= 600 ? 36 : 30) }

        var bigTile: CGFloat {
            if isWide {
                // Both shelves, the bar and the dock fit the height.
                let byHeight = (size.height - 250) * 0.56 / CartoucheTheme.cartridgeAspect
                return min(max(min(shelvesWidth * 0.22, byHeight), 64), 170)
            }
            return min(max(size.width * 0.27, 92), 170)
        }

        var smallTile: CGFloat {
            isWide ? bigTile * 0.74 : min(max(size.width * 0.2, 70), 130)
        }
    }
}

/// The platform, the genre and where a game plays, on one line.
@available(iOS 17.0, *)
struct CartoucheMetaLine: View {
    let entry: CartoucheEntry
    /// Off where a badge under the line says it already.
    var showsStatus = true

    var body: some View {
        HStack(spacing: 8) {
            if let platform = entry.platform {
                Text(CartoucheText.platform(platform).uppercased())
                    .font(.caption2.weight(.heavy))
                    .tracking(1)
                    .foregroundStyle(Color.white)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(Color.white.opacity(0.16), in: Capsule())
            }
            if let genre = entry.genre, let name = CartoucheText.genre(genre) {
                Label(name, systemImage: CartoucheTheme.symbol(genre: genre))
                    .font(.caption.weight(.semibold))
                    .labelStyle(CartoucheTightLabelStyle())
                    .foregroundStyle(CartoucheTheme.secondaryText)
                    .lineLimit(1)
            }
            if showsStatus {
                CartoucheStatusLabel(status: CartouchePlayStatus.of(entry))
            }
        }
    }
}

/// Buttons of the controller and what they do here.
@available(iOS 17.0, *)
struct CartoucheHint: View {
    let inputs: [CartoucheGamepad.Input]
    let title: String
    @ObservedObject private var gamepad = CartoucheGamepad.shared

    init(input: CartoucheGamepad.Input, title: String) {
        self.inputs = [input]
        self.title = title
    }

    init(inputs: [CartoucheGamepad.Input], title: String) {
        self.inputs = inputs
        self.title = title
    }

    var body: some View {
        HStack(spacing: 5) {
            ForEach(inputs, id: \.self) { input in
                Image(systemName: gamepad.symbol(for: input))
                    .font(.body.weight(.semibold))
                    .foregroundStyle(Color.white)
            }
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(CartoucheTheme.secondaryText)
                .lineLimit(1)
        }
        .accessibilityElement(children: .combine)
    }
}

/// The banner over the home while Cartouche is not set up.
@available(iOS 17.0, *)
struct CartoucheHomeSetupBanner: View {
    let action: () -> Void
    @ObservedObject private var setup = CartoucheSetup.shared
    @ObservedObject private var account = CartoucheAccount.shared

    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Image(systemName: setup.bannerIcon)
                    .font(.title3.weight(.semibold))
                    .frame(width: 42, height: 42)
                    .background(Color.white.opacity(0.2), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text(setup.bannerTitle)
                        .font(.headline)
                    Text(setup.bannerDetail(signingInAgain: account.isAutomatic))
                        .font(.subheadline)
                        .opacity(0.85)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.headline)
                    .opacity(0.7)
            }
            .foregroundStyle(Color.white)
            .padding(14)
            .background(
                LinearGradient(colors: [CartoucheTheme.indigo, CartoucheTheme.pink.opacity(0.85)],
                               startPoint: .topLeading, endPoint: .bottomTrailing),
                in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}
