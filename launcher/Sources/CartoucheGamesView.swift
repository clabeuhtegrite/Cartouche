//
//  CartoucheGamesView.swift
//  Cartouche
//
//  The home screen: every game Cartouche supports, the player's own first.
//  In a compact width a game's sheet opens over the catalogue; in a regular
//  width (an unfolded iPhone Duo, an iPad) the catalogue and the sheet sit
//  side by side, one on each side of the fold. The layout follows the size
//  class and the space this view is given, never the iPhone model.
//
//  Installing and starting a game stay LiveContainer's: the catalogue hands
//  the IPA or the game to the Apps tab, as a link from another app would.
//

import SwiftUI
import UniformTypeIdentifiers

@available(iOS 17.0, *)
struct CartoucheGamesView: View {
    @EnvironmentObject private var sharedModel: SharedModel
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var selectedID: String?
    @State private var choosingIPA = false
    @State private var choosingIPAInSheet = false
    @State private var memory = CartoucheMemoryReading.now()
    @State private var showingSetup = false
    @ObservedObject private var setup = CartoucheSetup.shared

    private let catalog = CartoucheCatalog.shared

    private var isRegular: Bool { horizontalSizeClass == .regular }

    var body: some View {
        let entries = catalog.entries(for: sharedModel.apps)
        GeometryReader { proxy in
            // Side by side when this view is wider than tall, one above the
            // other otherwise. The catalogue stays the first child in every
            // layout, so folding or rotating keeps its scroll position.
            let stacked = isRegular && proxy.size.height > proxy.size.width
            let layout = stacked ? AnyLayout(VStackLayout(spacing: 0)) : AnyLayout(HStackLayout(spacing: 0))
            layout {
                NavigationStack {
                    catalogue(entries)
                        .navigationTitle(CartoucheText.gamesTab)
                        .toolbar {
                            ToolbarItem(placement: .primaryAction) {
                                Button {
                                    choosingIPA = true
                                } label: {
                                    Label(CartoucheText.importCopy, systemImage: "square.and.arrow.down")
                                }
                            }
                        }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                if isRegular {
                    Divider()
                    NavigationStack {
                        detail(entries)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .fileImporter(isPresented: $choosingIPA, allowedContentTypes: [.ipa]) { result in
            if case .success(let url) = result {
                importCopy(url)
            }
        }
        .sheet(isPresented: compactSheet) {
            if let entry = entries.entry(id: selectedID) {
                NavigationStack {
                    sheetView(entry, onImport: { choosingIPAInSheet = true })
                        .toolbar {
                            ToolbarItem(placement: .confirmationAction) {
                                Button(CartoucheText.done) { selectedID = nil }
                            }
                        }
                }
                .fileImporter(isPresented: $choosingIPAInSheet, allowedContentTypes: [.ipa]) { result in
                    if case .success(let url) = result {
                        importCopy(url)
                    }
                }
            }
        }
        .sheet(isPresented: $showingSetup) {
            NavigationStack {
                CartoucheSetupView()
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button(CartoucheText.done) { showingSetup = false }
                        }
                    }
            }
        }
        // Hands the built-in SideStore's certificate to LiveContainer as soon
        // as the player has signed in, before they pick a game.
        .modifier(CartoucheSetupRefresh())
        // A pairing file opened with Cartouche: the setup shows how it went.
        .onChange(of: setup.openedPairingFile) { _, opened in
            guard opened else { return }
            setup.openedPairingFile = false
            showingSetup = true
        }
        .onAppear {
            memory = CartoucheMemoryReading.now()
            CartoucheRenewal.scheduleWarnings()
        }
        // A renewal in the background moves the expiry date: warn for the
        // new one each time the player comes back.
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
            CartoucheRenewal.scheduleWarnings()
        }
    }

    /// The sheet over the catalogue, in a compact width only. Unfolding
    /// moves the selected game into the side pane instead of closing it.
    private var compactSheet: Binding<Bool> {
        Binding(
            get: { !isRegular && selectedID != nil },
            set: { presented in
                if !presented && !isRegular { selectedID = nil }
            })
    }

    private func catalogue(_ entries: CartoucheCatalog.Entries) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                CartoucheSetupBanner()
                VStack(alignment: .leading, spacing: 12) {
                    sectionTitle(CartoucheText.yourGames)
                    if entries.owned.isEmpty {
                        emptyCard
                    } else {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 300), spacing: 16)], spacing: 16) {
                            ForEach(entries.owned) { entry in
                                CartoucheOwnedCard(
                                    entry: entry,
                                    fit: fit(entry),
                                    isSelected: isRegular && selectedID == entry.id,
                                    onPlay: { if let app = entry.app { play(app) } })
                                    .onTapGesture { selectedID = entry.id }
                                    .accessibilityAddTraits(.isButton)
                            }
                        }
                    }
                }

                if !entries.others.isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        sectionTitle(CartoucheText.supportedGames)
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 14)], spacing: 18) {
                            ForEach(entries.others) { entry in
                                Button {
                                    selectedID = entry.id
                                } label: {
                                    CartoucheGameTile(entry: entry, fit: fit(entry), isSelected: isRegular && selectedID == entry.id)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }

                Text(CartoucheText.supportedFooter)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .padding()
        }
    }

    @ViewBuilder
    private func detail(_ entries: CartoucheCatalog.Entries) -> some View {
        if let entry = entries.entry(id: selectedID) {
            sheetView(entry, onImport: { choosingIPA = true })
        } else {
            ContentUnavailableView(CartoucheText.gamesTab, systemImage: "gamecontroller", description: Text(CartoucheText.selectGame))
        }
    }

    private func sheetView(_ entry: CartoucheEntry, onImport: @escaping () -> Void) -> some View {
        CartoucheGameSheetView(entry: entry, memory: memory, onPlay: play, onImport: onImport)
            .id(entry.id)
    }

    private func sectionTitle(_ title: String) -> some View {
        Text(title)
            .font(.system(.title2, design: .rounded, weight: .bold))
    }

    private var emptyCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(CartoucheText.emptyTitle, systemImage: "square.stack.3d.down.forward")
                .font(.headline)
            Text(CartoucheText.emptyMessage)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Button {
                choosingIPA = true
            } label: {
                Label(CartoucheText.importCopy, systemImage: "square.and.arrow.down")
            }
            .buttonStyle(.bordered)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
    }

    private func fit(_ entry: CartoucheEntry) -> CartoucheFit? {
        entry.sheet.map { CartoucheFit.of($0, memory: memory) }
    }

    /// LiveContainer starts the game from its Apps tab, as it does for a
    /// livecontainer-launch link; only the link's host and query count.
    private func play(_ app: LCAppModel) {
        // Without the certificate, LiveContainer could only refuse to start
        // the game: show what is missing instead, once the game's sheet,
        // which may hold the Play button, has gone.
        CartoucheSetup.shared.refresh()
        guard CartoucheSetup.shared.canPlay else {
            let sheetWasOpen = compactSheet.wrappedValue
            selectedID = nil
            DispatchQueue.main.asyncAfter(deadline: .now() + (sheetWasOpen ? 0.6 : 0)) { showingSetup = true }
            return
        }
        var components = URLComponents()
        components.scheme = "cartouche"
        components.host = "livecontainer-launch"
        components.queryItems = [URLQueryItem(name: "bundle-name", value: app.appInfo.relativeBundlePath)]
        guard let url = components.url else { return }
        selectedID = nil
        sharedModel.selectedTab = .apps
        sharedModel.deepLink = url
    }

    /// LiveContainer installs the IPA from its Apps tab, as it does an IPA
    /// opened from another app. It reads the file in place, after this
    /// returns, from a URL it rebuilds from the path, so the access granted
    /// by the picker stays open until Cartouche quits: a game's IPA is too
    /// large to copy first.
    private func importCopy(_ url: URL) {
        _ = url.startAccessingSecurityScopedResource()
        selectedID = nil
        sharedModel.selectedTab = .apps
        sharedModel.deepLink = url
    }
}
