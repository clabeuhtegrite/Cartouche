//
//  CartoucheGamesView.swift
//  Cartouche
//
//  The Games tab, Cartouche's console: the home (CartoucheHomeView), every
//  game (CartoucheLibraryView), and a game's sheet over either. The tab
//  takes the whole screen, dark, without the tab bar: the home's dock
//  leads to the other tabs, whose bar leads back here.
//
//  Installing and starting a game stay LiveContainer's: the console hands
//  the IPA or the game to the Apps tab, as a link from another app would.
//

import SwiftUI
import UniformTypeIdentifiers

@available(iOS 17.0, *)
struct CartoucheGamesView: View {
    @EnvironmentObject private var sharedModel: SharedModel
    @ObservedObject private var setup = CartoucheSetup.shared
    @State private var path: [Route] = []
    @State private var sheetID: String?
    @State private var choosingIPA = false
    @State private var choosingIPAInSheet = false
    @State private var memory = CartoucheMemoryReading.now()
    @State private var showingSetup = false

    enum Route: Hashable {
        case library
    }

    private let catalog = CartoucheCatalog.shared

    private var onGames: Bool { sharedModel.selectedTab == .games }
    private var nothingOver: Bool { sheetID == nil && !showingSetup && !choosingIPA }

    var body: some View {
        let entries = catalog.entries(for: sharedModel.apps)
        NavigationStack(path: $path) {
            CartoucheHomeView(
                entries: entries,
                gameCount: entries.all.count,
                isActive: onGames && path.isEmpty && nothingOver,
                onPlay: play,
                onImport: { choosingIPA = true },
                onSheet: { sheetID = $0.id },
                onLibrary: { path.append(.library) },
                onSetup: { showingSetup = true },
                onTab: { sharedModel.selectedTab = $0 })
                .toolbar(.hidden, for: .navigationBar)
                .toolbar(.hidden, for: .tabBar)
                .navigationDestination(for: Route.self) { route in
                    switch route {
                    case .library:
                        CartoucheLibraryView(
                            entries: entries,
                            isActive: onGames && path.last == .library && nothingOver,
                            onPlay: play,
                            onSheet: { sheetID = $0.id },
                            onBack: { if !path.isEmpty { path.removeLast() } })
                            .toolbar(.hidden, for: .tabBar)
                    }
                }
        }
        .preferredColorScheme(onGames ? .dark : nil)
        .fileImporter(isPresented: $choosingIPA, allowedContentTypes: [.ipa]) { result in
            if case .success(let url) = result {
                importCopy(url)
            }
        }
        .sheet(isPresented: sheetPresented) {
            if let entry = entries.entry(id: sheetID) {
                NavigationStack {
                    CartoucheGameSheetView(entry: entry, memory: memory, onPlay: play, onImport: { choosingIPAInSheet = true })
                        .id(entry.id)
                        .toolbar {
                            ToolbarItem(placement: .confirmationAction) {
                                Button(CartoucheText.done) { sheetID = nil }
                            }
                        }
                }
                .preferredColorScheme(.dark)
                .fileImporter(isPresented: $choosingIPAInSheet, allowedContentTypes: [.ipa]) { result in
                    if case .success(let url) = result {
                        importCopy(url)
                    }
                }
                .onReceive(CartoucheGamepad.shared.inputs) { input in
                    switch input {
                    case .b:
                        sheetID = nil
                    case .a:
                        if let app = entry.app { play(app) }
                    default:
                        break
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
            .onReceive(CartoucheGamepad.shared.inputs) { input in
                if input == .b { showingSetup = false }
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

    private var sheetPresented: Binding<Bool> {
        Binding(
            get: { sheetID != nil },
            set: { presented in
                if !presented { sheetID = nil }
            })
    }

    /// LiveContainer starts the game from its Apps tab, as it does for a
    /// livecontainer-launch link; only the link's host and query count.
    private func play(_ app: LCAppModel) {
        // Without the certificate, LiveContainer could only refuse to start
        // the game: show what is missing instead, once the game's sheet,
        // which may hold the Play button, has gone.
        CartoucheSetup.shared.refresh()
        guard CartoucheSetup.shared.canPlay else {
            let sheetWasOpen = sheetID != nil
            sheetID = nil
            DispatchQueue.main.asyncAfter(deadline: .now() + (sheetWasOpen ? 0.6 : 0)) { showingSetup = true }
            return
        }
        var components = URLComponents()
        components.scheme = "cartouche"
        components.host = "livecontainer-launch"
        components.queryItems = [URLQueryItem(name: "bundle-name", value: app.appInfo.relativeBundlePath)]
        guard let url = components.url else { return }
        sheetID = nil
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
        sheetID = nil
        sharedModel.selectedTab = .apps
        sharedModel.deepLink = url
    }
}
