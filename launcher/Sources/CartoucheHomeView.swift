//
//  CartoucheHomeView.swift
//  Cartouche
//
//  The console's home: the player's games on the first shelf, then the
//  games nxnative plays on the iPhone, the game in focus described between
//  them with its main action, and a dock to the rest of Cartouche. The
//  stage takes the colours of the game in focus.
//
//  Touch and a game controller both drive it. A tap puts a game in focus,
//  a second tap opens its sheet; with a controller, the D-pad moves, A
//  does the main action of the game in focus, X opens its sheet, Y every
//  game and Menu the system page. While a controller is connected, the
//  buttons on screen show the controller's button that does the same.
//
//  The layout follows the space the screen gives it, never the iPhone
//  model: one column when the screen is taller than wide (an iPhone, the
//  iPhone Duo folded or unfolded upright), with the dock at the bottom;
//  the shelves beside the game in focus when it is wider, with the dock
//  in the top bar. The cartridges take the size that lets it all fit the
//  screen, down to a size under which the home scrolls instead.
//
//  Beside the sheet of the game in focus, on an iPhone Duo unfolded
//  (CartoucheGamesView), the home leaves out the game in focus, which the
//  sheet describes in full, and its shelves take the room.
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
    /// Opens the first game's guide (CartoucheGuideView).
    let onGuide: () -> Void
    let onTab: (LCTabIdentifier) -> Void
    /// Where a game's sheet grows out of its cartridge.
    let zoom: Namespace.ID?
    /// Whether the game in focus is described with its buttons between the
    /// shelves, or beside them: not when its sheet stands beside the home.
    let showsHero: Bool
    /// Tells which game is in focus, each time another one is.
    let onFocus: (CartoucheEntry) -> Void

    // Written out: before Swift 6.4 (SE-0502), the private state below made
    // the synthesized initializer private.
    init(entries: CartoucheCatalog.Entries, gameCount: Int, isActive: Bool,
         onPlay: @escaping (LCAppModel) -> Void, onImport: @escaping () -> Void,
         onInstall: @escaping (CartoucheStoredGame) -> Void = { _ in },
         onUninstall: @escaping (LCAppModel) -> Void, onSheet: @escaping (CartoucheEntry) -> Void,
         onLibrary: @escaping () -> Void, onSetup: @escaping () -> Void, onGuide: @escaping () -> Void = {},
         onTab: @escaping (LCTabIdentifier) -> Void, zoom: Namespace.ID? = nil,
         showsHero: Bool = true, onFocus: @escaping (CartoucheEntry) -> Void = { _ in }) {
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
        self.onGuide = onGuide
        self.onTab = onTab
        self.zoom = zoom
        self.showsHero = showsHero
        self.onFocus = onFocus
    }

    @ObservedObject private var setup = CartoucheSetup.shared
    @ObservedObject private var guide = CartoucheGuide.shared
    @ObservedObject private var gamepad = CartoucheGamepad.shared
    @State private var row = 0
    @State private var columns = [0, 0, 0]
    @State private var heroRow = 0
    @State private var signature = CartoucheSignature.current()
    /// Whether the shelves stand beside the game in focus, with the dock in
    /// the top bar, so that the D-pad goes up to the dock.
    @State private var isWide = false

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

    /// The signature's days left from which the top bar shows them: before,
    /// renewals take care of it and the System page says when it expires.
    static let expirySoonDays = 3

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

    /// The rows from the top of the screen to the bottom: the dock is in
    /// the top bar when the shelves stand beside the game in focus.
    private var visualRows: [Int] {
        isWide ? [2, 0, 1] : [0, 1, 2]
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
            // Until the first game is installed, the guide's card stands in
            // the setup banner's place, whose steps it begins with.
            let guideProgress = guide.progress(entries)
            let showsGuide = guide.showsCard(guideProgress)
            let metrics = Metrics(size: proxy.size, hasBanner: showsGuide || setup.needsSetup, hasHero: showsHero)
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: metrics.spacing) {
                    topBar(metrics)
                    if showsGuide {
                        CartoucheGuideCard(progress: guideProgress, action: onGuide)
                    } else if setup.needsSetup {
                        CartoucheHomeSetupBanner(action: onSetup)
                    }
                    if !showsHero {
                        shelf(0, title: CartoucheText.homeLibrary, width: metrics.bigTile)
                        shelf(1, title: CartoucheText.homeIPhone, width: metrics.smallTile)
                    } else if metrics.isWide {
                        HStack(alignment: .top, spacing: metrics.columnGap) {
                            VStack(alignment: .leading, spacing: metrics.spacing) {
                                shelf(0, title: CartoucheText.homeLibrary, width: metrics.bigTile)
                                shelf(1, title: CartoucheText.homeIPhone, width: metrics.smallTile)
                            }
                            .frame(width: metrics.shelvesWidth, alignment: .leading)
                            // The shelves end at their column, the covers past it
                            // fading out in the gap rather than running under the
                            // game in focus; above, below and on the left, the
                            // focused cover's ring and glow still show.
                            .mask {
                                LinearGradient(stops: [.init(color: .black, location: metrics.shelvesFadeStart),
                                                       .init(color: .clear, location: 1)],
                                               startPoint: .leading, endPoint: .trailing)
                                    .padding(.vertical, -metrics.bigTile * 0.5)
                                    .padding(.leading, -metrics.margin)
                                    .padding(.trailing, -metrics.columnGap)
                            }
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
                .padding(.vertical, metrics.verticalPadding)
            }
            .scrollBounceBehavior(.basedOnSize)
            .scrollIndicators(.hidden)
            // Upright, the dock stays at the bottom; the shelves scroll under
            // it only where the screen is too short for their smallest size.
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if !metrics.isWide {
                    dock(compact: false, labels: true)
                        .padding(.horizontal, metrics.margin)
                        .padding(.top, Metrics.dockTopPadding)
                        .padding(.bottom, Metrics.dockBottomPadding)
                        .background {
                            LinearGradient(colors: [CartoucheTheme.stage.opacity(0), CartoucheTheme.stage.opacity(0.88)],
                                           startPoint: .top, endPoint: UnitPoint(x: 0.5, y: 0.45))
                                .ignoresSafeArea(edges: .bottom)
                        }
                }
            }
            .onAppear { isWide = metrics.isWide }
            .onChange(of: metrics.isWide) { _, wide in isWide = wide }
        }
        .background(CartoucheStage(key: heroKey, artwork: heroArtwork))
        .onChange(of: hero) { _, hero in
            if case .game(let entry) = hero { onFocus(entry) }
        }
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

    private func topBar(_ metrics: Metrics) -> some View {
        HStack(spacing: 10) {
            CartoucheWordmark(size: metrics.isShort ? 22 : 24)
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
            // Renewals keep Cartouche signed: its expiry shows here only
            // when it comes close, and leads to the System page.
            if let days = signature.daysLeft, days <= Self.expirySoonDays {
                Button {
                    onTab(.system)
                } label: {
                    Label(CartoucheText.daysLeftShort(max(days, 0)), systemImage: "hourglass")
                        .font(.subheadline.weight(.semibold).monospacedDigit())
                        .labelStyle(CartoucheTightLabelStyle())
                        .foregroundStyle(days <= 1 ? CartoucheTheme.danger : Color.orange)
                        .padding(.horizontal, 12)
                        .frame(height: 34)
                        .cartoucheGlass(in: Capsule(), interactive: true)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(CartoucheText.expires))
                .accessibilityValue(Text(CartoucheText.daysLeftShort(max(days, 0))))
            }
            if metrics.isWide {
                dock(compact: true, labels: metrics.size.width >= 700)
            }
        }
        .frame(minHeight: Metrics.topBarHeight)
    }

    // MARK: Shelves

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
                    LazyHStack(alignment: .top, spacing: max(10, width * 0.12)) {
                        ForEach(Array(items.enumerated()), id: \.element) { column, item in
                            tile(item, width: width, isFocused: row == index && columns[index] == column)
                                .id(item)
                                .onTapGesture { tapped(item, row: index, column: column) }
                        }
                    }
                    // Room for the focused game's ring and glow.
                    .padding(.vertical, width * 0.1)
                    .padding(.horizontal, width * 0.06)
                }
                .scrollIndicators(.hidden)
                .scrollClipDisabled()
                // The height Metrics counts for the shelf: its covers and the
                // room for the focused one's ring, which a horizontal scroll
                // view did not always keep beside the game in focus.
                .frame(height: width * Metrics.tileHeight)
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
            if let update = entry.update {
                Button { onInstall(update) } label: { Label(updateTitle, systemImage: "arrow.down.circle.fill") }
            }
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

    /// The game in focus, at the same height whatever it is, so that the
    /// shelf under it stays in place as the focus moves.
    @ViewBuilder
    private func heroView(_ metrics: Metrics) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            switch hero {
            case .game(let entry):
                gameHero(entry, metrics: metrics)
            case .importGame:
                heroText(CartoucheText.importTile, CartoucheText.emptyMessage, metrics: metrics)
                actionButton(CartoucheText.importCopy, systemImage: "square.and.arrow.down", primary: true,
                             input: .a, action: onImport)
            case .allGames:
                heroText(CartoucheText.allGames, CartoucheText.allGamesDetail(gameCount), metrics: metrics)
                actionButton(CartoucheText.allGames, systemImage: "square.grid.2x2.fill", primary: true,
                             input: .a, action: onLibrary)
            case .dock, nil:
                EmptyView()
            }
        }
        .frame(maxWidth: 560, minHeight: metrics.isWide ? nil : metrics.heroHeight, alignment: .topLeading)
        .animation(.easeInOut(duration: 0.2), value: hero)
    }

    private func heroTitle(_ title: String, metrics: Metrics) -> some View {
        Text(title)
            .font(.system(size: metrics.titleSize, weight: .heavy, design: .rounded))
            .foregroundStyle(Color.white)
            .lineLimit(1)
            .minimumScaleFactor(0.55)
    }

    private func heroText(_ title: String, _ detail: String, metrics: Metrics) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            heroTitle(title, metrics: metrics)
            Text(detail)
                .font(.subheadline)
                .foregroundStyle(CartoucheTheme.secondaryText)
                .lineLimit(metrics.isShort ? 1 : 2)
        }
    }

    private func gameHero(_ entry: CartoucheEntry, metrics: Metrics) -> some View {
        let status = CartouchePlayStatus.of(entry)
        return VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                heroTitle(entry.name, metrics: metrics)
                CartoucheMetaLine(entry: entry)
                if let detail = heroDetail(status) {
                    Text(detail)
                        .font(.subheadline)
                        .foregroundStyle(CartoucheTheme.secondaryText)
                        .lineLimit(metrics.isShort ? 1 : 2)
                }
            }
            // With an update besides, the other buttons show only their
            // symbols when their names do not fit.
            ViewThatFits(in: .horizontal) {
                gameActions(entry, compact: 0)
                gameActions(entry, compact: 1)
                gameActions(entry, compact: 2)
            }
        }
    }

    /// The line under the badges: what stops the game, or what the player
    /// can do with it. A game ready to play needs none: its badge says so.
    private func heroDetail(_ status: CartouchePlayStatus) -> String? {
        switch status {
        case .ready, .update:
            if !setup.canPlay {
                return setup.bannerDetail(signingInAgain: CartoucheAccount.shared.isAutomatic)
            }
            return status == .update ? status.long : nil
        default:
            return status.long
        }
    }

    /// The buttons of the game in focus; with COMPACT, its last ones show
    /// only their symbols: Details at 1, Update and Details at 2.
    private func gameActions(_ entry: CartoucheEntry, compact: Int) -> some View {
        HStack(spacing: 10) {
            if let app = entry.app {
                actionButton(CartoucheText.play, systemImage: "play.fill", primary: true, input: .a) { onPlay(app) }
                if let update = entry.update {
                    actionButton(CartoucheText.updateGame, systemImage: "arrow.down.circle.fill", primary: false,
                                 iconOnly: compact >= 2) { onInstall(update) }
                }
            } else if let stored = entry.stored {
                actionButton(installTitle, systemImage: "arrow.down.circle.fill", primary: true, input: .a) { onInstall(stored) }
            } else {
                actionButton(CartoucheText.importCopy, systemImage: "square.and.arrow.down", primary: true,
                             input: .a, action: onImport)
            }
            actionButton(CartoucheText.details, systemImage: "info.circle", primary: false,
                         iconOnly: compact >= 1, input: .x) { onSheet(entry) }
        }
    }

    /// Install from the player's games folder, naming its server.
    private var installTitle: String {
        CartoucheText.installFrom(CartoucheStoredGames.shared.serverName ?? "")
    }

    /// Update from the player's games folder, naming its server.
    private var updateTitle: String {
        CartoucheText.updateFrom(CartoucheStoredGames.shared.serverName ?? "")
    }

    /// A button of the game in focus. While a controller is connected, it
    /// shows the controller's button that does the same, in place of its
    /// symbol.
    @ViewBuilder
    private func actionButton(_ title: String, systemImage: String, primary: Bool, iconOnly: Bool = false,
                              input: CartoucheGamepad.Input? = nil, action: @escaping () -> Void) -> some View {
        let symbol = gamepad.isConnected ? (input.map { gamepad.symbol(for: $0) } ?? systemImage) : systemImage
        let button = Button(action: action) {
            if iconOnly {
                Label(title, systemImage: symbol)
                    .labelStyle(.iconOnly)
                    .font(.headline)
                    .padding(.horizontal, 6)
                    .frame(minHeight: 30)
            } else {
                Label(title, systemImage: symbol)
                    .font(.headline)
                    .lineLimit(1)
                    .padding(.horizontal, 6)
                    .frame(minHeight: 30)
            }
        }
        .controlSize(.large)
        if primary {
            button.cartouchePrimaryButton()
        } else {
            button.cartoucheSecondaryButton()
        }
    }

    // MARK: Dock

    /// Every game, import and the System page: a bar at the bottom of an
    /// upright screen, a row of buttons in the top bar of a wide one, with
    /// their names where they fit (LABELS).
    private func dock(compact: Bool, labels: Bool) -> some View {
        HStack(spacing: compact ? 2 : 4) {
            ForEach(Array(Dock.allCases.enumerated()), id: \.element) { column, item in
                Button {
                    activate(.dock(item))
                } label: {
                    dockLabel(item, compact: compact, labels: labels, isFocused: row == 2 && columns[2] == column)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(Self.title(item)))
            }
        }
        .padding(compact ? 3 : 5)
        .frame(maxWidth: compact ? nil : CGFloat(440))
        .cartoucheGlass(in: Capsule())
        .frame(maxWidth: compact ? nil : CGFloat.infinity)
    }

    @ViewBuilder
    private func dockLabel(_ item: Dock, compact: Bool, labels: Bool, isFocused: Bool) -> some View {
        let glyph = gamepad.isConnected ? Self.input(item).map { gamepad.symbol(for: $0) } : nil
        Group {
            if compact {
                HStack(spacing: 6) {
                    Image(systemName: glyph ?? Self.symbol(item))
                        .font(.subheadline.weight(.semibold))
                    if labels {
                        Text(Self.title(item))
                            .font(.subheadline.weight(.semibold))
                            .lineLimit(1)
                    }
                }
                .padding(.horizontal, labels ? 12 : 10)
                .frame(minWidth: 38, minHeight: 34)
            } else {
                VStack(spacing: 3) {
                    Image(systemName: Self.symbol(item))
                        .font(.system(size: 19, weight: .semibold))
                        .frame(height: 24)
                    HStack(spacing: 3) {
                        if let glyph {
                            Image(systemName: glyph)
                                .font(.caption2.weight(.bold))
                        }
                        Text(Self.title(item))
                            .font(.caption2.weight(.semibold))
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                    }
                }
                .frame(maxWidth: .infinity, minHeight: 50)
            }
        }
        .foregroundStyle(isFocused ? Color.white : Color.white.opacity(0.82))
        .background {
            if isFocused {
                Capsule()
                    .fill(Color.white.opacity(0.18))
                    .overlay(Capsule().stroke(Color.white, lineWidth: 2))
            }
        }
        .contentShape(Capsule())
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: isFocused)
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

    /// The controller's button that does what a button of the dock does,
    /// from anywhere on the home.
    static func input(_ item: Dock) -> CartoucheGamepad.Input? {
        switch item {
        case .allGames: return .y
        case .importGame: return nil
        case .system: return .menu
        }
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

    /// A's action, the main button of the game in focus: Play, Install from
    /// the games folder, or Import.
    private func activate(_ item: Item) {
        switch item {
        case .game(let entry):
            if let app = entry.app {
                onPlay(app)
            } else if let stored = entry.stored {
                onInstall(stored)
            } else {
                onImport()
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
        case .up, .down:
            let order = visualRows
            guard let position = order.firstIndex(of: row) else { return }
            let next = position + (input == .up ? -1 : 1)
            guard order.indices.contains(next) else { return }
            let target = order[next]
            focus(row: target, column: min(columns[target], rows[target].count - 1))
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

    /// The sizes of the home for the space the screen gives it.
    struct Metrics {
        let size: CGSize
        /// The setup banner is over the shelves.
        var hasBanner = false
        /// The game in focus is between the shelves, or beside them.
        var hasHero = true

        static let topBarHeight: CGFloat = 44
        static let bannerHeight: CGFloat = 72
        /// A shelf's title and the space under it.
        static let shelfTitleHeight: CGFloat = 26
        /// The dock's bar (dockLabel, 50, and 5 around it) and the space
        /// around it at the bottom of the screen.
        static let dockHeight: CGFloat = 60
        static let dockTopPadding: CGFloat = 10
        static let dockBottomPadding: CGFloat = 6
        /// A cartridge's height for its width, with the room above and
        /// below it for the focused one's ring (shelf(_:title:width:)).
        static let tileHeight: CGFloat = CartoucheTheme.cartridgeAspect + 0.2
        /// The second shelf's cartridges, against the first's.
        static let smallRatio: CGFloat = 0.74

        /// Wider than tall: the shelves beside the game in focus, the dock
        /// in the top bar.
        var isWide: Bool { size.width > size.height * 1.15 }
        /// Too short for the roomy layout: the iPhone Duo folded, an iPhone
        /// sideways.
        var isShort: Bool { size.height < 720 }
        var margin: CGFloat { size.width >= 600 ? 28 : 18 }
        var spacing: CGFloat { isShort ? 12 : 20 }
        var verticalPadding: CGFloat { isShort ? 8 : 12 }
        var shelvesWidth: CGFloat { (size.width - 2 * margin) * (hasHero ? 0.6 : 1) }
        /// Beside the game in focus, the space between it and the shelves.
        var columnGap: CGFloat { spacing * 1.5 }
        /// Where the shelves start to fade, from the screen's margin to the
        /// end of the gap: at the end of their column.
        var shelvesFadeStart: CGFloat {
            (margin + shelvesWidth) / (margin + shelvesWidth + columnGap)
        }
        var titleSize: CGFloat { isWide || isShort ? 26 : (size.width >= 600 ? 34 : 30) }

        /// The height of the game in focus, upright: its name, its badges,
        /// two lines about it (one on a short screen) and its buttons.
        var heroHeight: CGFloat {
            let detail: CGFloat = isShort ? 20 : 40
            return titleSize * 1.2 + 6 + 22 + 6 + detail + 12 + 52
        }

        /// The height left to the shelves' cartridges once the top bar, the
        /// banner, the shelves' titles, the game in focus and the dock have
        /// theirs.
        private var shelvesHeight: CGFloat {
            var fixed = 2 * verticalPadding + Self.topBarHeight + 2 * Self.shelfTitleHeight
            if hasBanner { fixed += Self.bannerHeight + spacing }
            if isWide {
                // The shelves under the top bar, one above the other.
                fixed += 2 * spacing
            } else {
                // The first shelf, the game in focus and the second shelf
                // under the top bar, and the dock under them.
                fixed += 2 * spacing + Self.dockTopPadding + Self.dockHeight + Self.dockBottomPadding
                if hasHero { fixed += spacing + heroHeight }
            }
            return max(size.height - fixed, 0)
        }

        var bigTile: CGFloat {
            let byHeight = shelvesHeight / (Self.tileHeight * (1 + Self.smallRatio))
            let byWidth = isWide ? shelvesWidth * 0.3 : size.width * 0.3
            let smallest: CGFloat = isWide ? 60 : 78
            return min(max(min(byHeight, byWidth), smallest), 170)
        }

        var smallTile: CGFloat {
            max(bigTile * Self.smallRatio, isWide ? 46 : 56)
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
                .fixedSize()
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
