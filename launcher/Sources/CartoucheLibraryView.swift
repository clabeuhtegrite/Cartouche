//
//  CartoucheLibraryView.swift
//  Cartouche
//
//  Every game nxnative has a profile for, as cartridges: the player's own
//  first, then the others by name. Filters keep the player's games, those
//  nxnative plays on the iPhone or on the Mac, those still in bring-up, or
//  the Switch 2 games; a search finds a game by name or title ID.
//
//  With a controller, the D-pad moves between games, A plays the player's
//  own game or opens the sheet of another, X opens the sheet, B goes back
//  and the shoulder buttons change the filter.
//

import SwiftUI

@available(iOS 17.0, *)
struct CartoucheLibraryView: View {
    let entries: CartoucheCatalog.Entries
    /// Whether the library is on screen, with nothing over it, so that it
    /// takes the controller.
    let isActive: Bool
    let onPlay: (LCAppModel) -> Void
    let onSheet: (CartoucheEntry) -> Void
    let onBack: () -> Void
    /// Where a game's sheet grows out of its cartridge.
    let zoom: Namespace.ID?

    // Written out: before Swift 6.4 (SE-0502), the private state below made
    // the synthesized initializer private.
    init(entries: CartoucheCatalog.Entries, isActive: Bool, onPlay: @escaping (LCAppModel) -> Void,
         onSheet: @escaping (CartoucheEntry) -> Void, onBack: @escaping () -> Void,
         zoom: Namespace.ID? = nil) {
        self.entries = entries
        self.isActive = isActive
        self.onPlay = onPlay
        self.onSheet = onSheet
        self.onBack = onBack
        self.zoom = zoom
    }

    enum Filter: CaseIterable, Hashable {
        case all, owned, iphone, mac, bringup, switch2

        func includes(_ entry: CartoucheEntry) -> Bool {
            switch self {
            case .all: return true
            case .owned: return entry.isOwned
            case .iphone: return entry.playsOnIPhone
            // A game nxnative plays on the iPhone it plays on the Mac too, its
            // first platform (catalog/schema/nxnative.schema.json, status).
            case .mac: return entry.game?.status == "mac" || entry.game?.status == "iphone"
            case .bringup: return entry.game?.status == "bringup"
            case .switch2: return entry.platform == "switch2"
            }
        }

        var title: String {
            switch self {
            case .all: return CartoucheText.filterAll
            case .owned: return CartoucheText.homeLibrary
            case .iphone: return CartoucheText.statusIPhoneShort
            case .mac: return CartoucheText.statusMacShort
            case .bringup: return CartoucheText.statusBringupShort
            case .switch2: return CartoucheText.platform("switch2")
            }
        }

        var symbol: String {
            switch self {
            case .all: return "square.grid.2x2.fill"
            case .owned: return "checkmark.circle.fill"
            case .iphone: return CartouchePlayStatus.iphone.symbol
            case .mac: return CartouchePlayStatus.mac.symbol
            case .bringup: return CartouchePlayStatus.bringup.symbol
            case .switch2: return "2.circle.fill"
            }
        }
    }

    @ObservedObject private var gamepad = CartoucheGamepad.shared
    @State private var filter: Filter = .all
    @State private var query = ""
    @State private var focusIndex = 0
    @State private var columnCount = 3

    private var shown: [CartoucheEntry] {
        let words = query.split(separator: " ").map(String.init)
        return entries.all.filter { entry in
            filter.includes(entry) && words.allSatisfy { word in
                entry.name.range(of: word, options: [.caseInsensitive, .diacriticInsensitive]) != nil
                    || (entry.titleId?.range(of: word, options: [.caseInsensitive, .anchored]) != nil)
            }
        }
    }

    private var focused: CartoucheEntry? {
        let shown = self.shown
        guard !shown.isEmpty else { return nil }
        return shown[min(focusIndex, shown.count - 1)]
    }

    var body: some View {
        let shown = self.shown
        GeometryReader { proxy in
            let layout = Layout(width: proxy.size.width)
            ScrollViewReader { reader in
                ScrollView(.vertical) {
                    VStack(alignment: .leading, spacing: 18) {
                        filterBar
                        if shown.isEmpty {
                            ContentUnavailableView.search(text: query)
                                .frame(maxWidth: .infinity)
                                .padding(.top, 40)
                        } else {
                            grid(shown, layout: layout)
                        }
                    }
                    .padding(.horizontal, layout.margin)
                    .padding(.bottom, 24)
                }
                .scrollIndicators(.hidden)
                .onChange(of: focusIndex) { _, index in
                    guard index < shown.count else { return }
                    withAnimation(.easeOut(duration: 0.2)) {
                        reader.scrollTo(shown[index].id, anchor: .center)
                    }
                }
            }
            .onAppear { columnCount = layout.columns }
            .onChange(of: layout.columns) { _, columns in columnCount = columns }
        }
        .background(CartoucheStage(key: focused?.tileKey, artwork: focused?.cover?.artwork))
        .navigationTitle(CartoucheText.allGames)
        .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: CartoucheText.searchPrompt)
        .onChange(of: filter) { _, _ in focusIndex = 0 }
        .onChange(of: query) { _, _ in focusIndex = 0 }
        .onReceive(gamepad.inputs) { input in
            if isActive { handle(input) }
        }
        .safeAreaInset(edge: .bottom) {
            if gamepad.isConnected {
                hints
                    .padding(.bottom, 8)
            }
        }
    }

    private var filterBar: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                ForEach(Filter.allCases, id: \.self) { item in
                    let count = entries.all.filter(item.includes).count
                    if item == .all || count > 0 {
                        Button {
                            filter = item
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: item.symbol)
                                Text(item.title)
                                Text(verbatim: "\(count)")
                                    .monospacedDigit()
                                    .foregroundStyle(filter == item ? Color.white.opacity(0.8) : CartoucheTheme.tertiaryText)
                            }
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(filter == item ? Color.white : CartoucheTheme.secondaryText)
                            .padding(.horizontal, 14)
                            .frame(height: 36)
                            .background {
                                if filter == item {
                                    Capsule().fill(CartoucheTheme.brand)
                                }
                            }
                            .cartoucheGlass(in: Capsule(), interactive: true)
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(filter == item ? .isSelected : [])
                    }
                }
            }
            .padding(.vertical, 4)
        }
        .scrollIndicators(.hidden)
        .scrollClipDisabled()
    }

    private func grid(_ shown: [CartoucheEntry], layout: Layout) -> some View {
        let columns = Array(repeating: GridItem(.fixed(layout.tile), spacing: layout.spacing, alignment: .top), count: layout.columns)
        return LazyVGrid(columns: columns, alignment: .leading, spacing: layout.spacing * 1.4) {
            ForEach(Array(shown.enumerated()), id: \.element.id) { index, entry in
                Button {
                    if focusIndex == index || !gamepad.isConnected {
                        onSheet(entry)
                    }
                    focusIndex = index
                } label: {
                    VStack(alignment: .leading, spacing: 8) {
                        CartoucheGameCartridge(entry: entry, width: layout.tile,
                                               isFocused: gamepad.isConnected && focusIndex == index)
                            .cartoucheZoomSource(entry.id, in: zoom)
                        CartoucheStatusLabel(status: CartouchePlayStatus.of(entry))
                            .padding(.horizontal, 2)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .id(entry.id)
            }
        }
        .padding(.top, 6)
    }

    private var hints: some View {
        HStack(spacing: 16) {
            CartoucheHint(input: .a, title: focused?.app != nil ? CartoucheText.play : CartoucheText.details)
            CartoucheHint(input: .x, title: CartoucheText.details)
            CartoucheHint(inputs: [.previous, .next], title: CartoucheText.hintFilter)
            CartoucheHint(input: .b, title: CartoucheText.hintBack)
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 16)
        .cartoucheGlass(in: Capsule())
    }

    private func handle(_ input: CartoucheGamepad.Input) {
        let count = shown.count
        switch input {
        case .left:
            focusIndex = max(focusIndex - 1, 0)
        case .right:
            focusIndex = min(focusIndex + 1, max(count - 1, 0))
        case .up:
            if focusIndex >= columnCount { focusIndex -= columnCount }
        case .down:
            if focusIndex + columnCount < count { focusIndex += columnCount }
        case .a:
            guard let focused else { return }
            if let app = focused.app { onPlay(app) } else { onSheet(focused) }
        case .x:
            if let focused { onSheet(focused) }
        case .b:
            onBack()
        case .previous, .next:
            let filters = Filter.allCases.filter { $0 == .all || entries.all.contains(where: $0.includes) }
            guard let current = filters.firstIndex(of: filter) else { return }
            let next = input == .next ? current + 1 : current - 1
            filter = filters[(next + filters.count) % filters.count]
        case .y, .menu:
            break
        }
    }

    struct Layout {
        let width: CGFloat

        var margin: CGFloat { width >= 600 ? 28 : 18 }
        var spacing: CGFloat { width >= 600 ? 22 : 14 }
        var columns: Int {
            let minimum: CGFloat = width >= 600 ? 132 : 100
            return max(3, Int((width - 2 * margin + spacing) / (minimum + spacing)))
        }
        var tile: CGFloat {
            (width - 2 * margin - CGFloat(columns - 1) * spacing) / CGFloat(columns)
        }
    }
}
