//
//  CartoucheGamesView.swift
//  Cartouche
//
//  The Games tab, Cartouche's console: the home (CartoucheHomeView), every
//  game (CartoucheLibraryView), and a game's sheet over either, with the
//  game's settings one step further (CartoucheGameSettingsView). The tab
//  takes the whole screen, dark, without the tab bar: the home's dock
//  leads to the other tabs, whose bar leads back here.
//
//  Cartouche installs, starts and uninstalls a game itself, on these
//  screens (CartoucheGameActions): the player never lands in the Apps tab.
//  A game the player has just imported opens on its sheet, Play first. The
//  games of the player's games folder are among theirs, installed or not
//  (CartoucheStoredGames), and the saves of the games that changed are
//  copied to the saves folder whenever Cartouche comes back, after a game
//  (CartoucheSaveBackups).
//

import SwiftUI
import UniformTypeIdentifiers

@available(iOS 17.0, *)
struct CartoucheGamesView: View {
    @EnvironmentObject private var sharedModel: SharedModel
    @ObservedObject private var setup = CartoucheSetup.shared
    @ObservedObject private var actions = CartoucheGameActions.shared
    @ObservedObject private var storedGames = CartoucheStoredGames.shared
    @State private var path: [Route] = []
    @State private var sheetID: String?
    @State private var choosingIPA = false
    @State private var choosingIPAInSheet = false
    @State private var memory = CartoucheMemoryReading.now()
    @State private var showingSetup = false
    /// The game whose uninstall the player is asked about, from the home or
    /// from the sheet.
    @State private var uninstalling: LCAppModel?
    @State private var uninstallingInSheet: LCAppModel?
    /// The settings page open over the game's sheet.
    @State private var gameSettings: CartoucheGameSettingsModel?
    /// A game's sheet grows out of its cartridge.
    @Namespace private var zoom

    enum Route: Hashable {
        case library
    }

    private let catalog = CartoucheCatalog.shared

    private var onGames: Bool { sharedModel.selectedTab == .games }
    private var nothingOver: Bool {
        sheetID == nil && !showingSetup && !choosingIPA && uninstalling == nil
            && actions.work == nil && actions.notice == nil
    }

    var body: some View {
        let entries = catalog.entries(for: sharedModel.apps, stored: storedGames.games)
        NavigationStack(path: $path) {
            CartoucheHomeView(
                entries: entries,
                gameCount: entries.all.count,
                isActive: onGames && path.isEmpty && nothingOver,
                onPlay: { play($0) },
                onImport: { choosingIPA = true },
                onInstall: { installStored($0) },
                onUninstall: { uninstalling = $0 },
                onSheet: { sheetID = $0.id },
                onLibrary: { path.append(.library) },
                onSetup: { showingSetup = true },
                onTab: { sharedModel.selectedTab = $0 },
                // One cartridge per game to grow from: the library's, once
                // it is over the home.
                zoom: path.isEmpty ? zoom : nil)
                .toolbar(.hidden, for: .navigationBar)
                .toolbar(.hidden, for: .tabBar)
                .navigationDestination(for: Route.self) { route in
                    switch route {
                    case .library:
                        CartoucheLibraryView(
                            entries: entries,
                            isActive: onGames && path.last == .library && nothingOver,
                            onPlay: { play($0) },
                            onSheet: { sheetID = $0.id },
                            onBack: { if !path.isEmpty { path.removeLast() } },
                            zoom: zoom)
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
                    CartoucheGameSheetView(
                        entry: entry,
                        memory: memory,
                        onPlay: { play($0) },
                        onSettings: { gameSettings = actions.settings(for: $0, tileKey: entry.tileKey) },
                        onImport: { choosingIPAInSheet = true },
                        onUninstall: { uninstallingInSheet = $0 },
                        onInstallStored: { installStored($0) },
                        onExport: { exportCopy($0) })
                        .id(entry.id)
                        .toolbar {
                            ToolbarItem(placement: .confirmationAction) {
                                Button(CartoucheText.done) { sheetID = nil }
                            }
                        }
                        .navigationDestination(item: $gameSettings) { settings in
                            CartoucheGameSettingsView(model: settings) {
                                if let app = entry.app { play(app, showingSettings: true) }
                            }
                            .toolbar {
                                ToolbarItem(placement: .confirmationAction) {
                                    Button(CartoucheText.done) { sheetID = nil }
                                }
                            }
                        }
                }
                .cartoucheZoom(from: entry.id, in: zoom)
                .preferredColorScheme(.dark)
                .fileImporter(isPresented: $choosingIPAInSheet, allowedContentTypes: [.ipa]) { result in
                    if case .success(let url) = result {
                        importCopy(url)
                    }
                }
                .modifier(CartoucheUninstallQuestion(app: $uninstallingInSheet, onAnswer: uninstall, onCopyFirst: copyThenUninstall))
                .onReceive(CartoucheGamepad.shared.inputs) { input in
                    guard uninstallingInSheet == nil else { return }
                    // On the settings page, L and R change the category and B
                    // goes back to the sheet.
                    if let settings = gameSettings {
                        switch input {
                        case .b: gameSettings = nil
                        case .previous: settings.moveCategory(by: -1)
                        case .next: settings.moveCategory(by: 1)
                        default: break
                        }
                        return
                    }
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
        .modifier(CartoucheUninstallQuestion(app: $uninstalling, onAnswer: uninstall, onCopyFirst: copyThenUninstall))
        .overlay {
            if let work = actions.work {
                CartoucheGameWorkView(work: work)
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: actions.work)
        // Another game's sheet, or none: its settings page goes too.
        .onChange(of: sheetID) { _, _ in gameSettings = nil }
        .alert(actions.notice?.title ?? "", isPresented: noticeShown, presenting: actions.notice) { _ in
            Button(CartoucheText.done) { actions.notice = nil }
        } message: { notice in
            Text(notice.message)
        }
        // A game just imported: its sheet, with Play, unless there is
        // something to tell first.
        .onChange(of: actions.installed) { _, app in
            guard let app else { return }
            actions.installed = nil
            guard actions.notice == nil,
                  let entry = catalog.entries(for: sharedModel.apps, stored: storedGames.games).owned
                    .first(where: { $0.app === app }) else { return }
            path.removeAll()
            sheetID = entry.id
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
            storedGames.refresh()
            actions.copySaves(of: sharedModel.apps)
        }
        // A renewal in the background moves the expiry date: warn for the
        // new one each time the player comes back. A game may have saved
        // meanwhile, and the games folder changed.
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
            CartoucheRenewal.scheduleWarnings()
            storedGames.refresh()
            actions.copySaves(of: sharedModel.apps)
        }
    }

    private var sheetPresented: Binding<Bool> {
        Binding(
            get: { sheetID != nil },
            set: { presented in
                if !presented { sheetID = nil }
            })
    }

    private var noticeShown: Binding<Bool> {
        Binding(
            get: { actions.notice != nil },
            set: { shown in
                if !shown { actions.notice = nil }
            })
    }

    /// Starts the game from Cartouche, which opens again as the game. With
    /// showingSettings, nxnative's settings screen comes first.
    private func play(_ app: LCAppModel, showingSettings: Bool = false) {
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
        sheetID = nil
        actions.play(app, showingSettings: showingSettings)
    }

    /// Installs the IPA the player picked, here: Cartouche reads it in place.
    private func importCopy(_ url: URL) {
        sheetID = nil
        actions.install(url)
    }

    private func uninstall(_ app: LCAppModel, erasingData: Bool) {
        sheetID = nil
        actions.uninstall(app, erasingData: erasingData)
    }

    /// Installs the game's IPA from the player's games folder, read there.
    private func installStored(_ game: CartoucheStoredGame) {
        sheetID = nil
        actions.install(stored: game)
    }

    /// Copies the installed game to the player's games folder.
    private func exportCopy(_ app: LCAppModel) {
        sheetID = nil
        actions.export(app, titleId: ownTitleId(of: app))
    }

    /// Copies the game to the games folder, then uninstalls it, keeping its
    /// saves: the library still lists it, to install again.
    private func copyThenUninstall(_ app: LCAppModel) {
        sheetID = nil
        actions.export(app, titleId: ownTitleId(of: app)) {
            actions.uninstall(app, erasingData: false)
        }
    }

    /// The app's own title ID, its region's.
    private func ownTitleId(of app: LCAppModel) -> String? {
        guard let found = catalog.gameTitle(of: app) else { return nil }
        return found.isEmpty ? catalog.titleId(matchingName: app.displayName) : found
    }
}

/// Asks before a game is uninstalled, whether its saves stay, and, when the
/// player has a games folder without a copy of the game, whether to copy it
/// there first.
@available(iOS 17.0, *)
struct CartoucheUninstallQuestion: ViewModifier {
    @Binding var app: LCAppModel?
    let onAnswer: (LCAppModel, Bool) -> Void
    /// Copies the game to the games folder, then uninstalls it, keeping its
    /// saves.
    var onCopyFirst: ((LCAppModel) -> Void)? = nil

    private var asking: Binding<Bool> {
        Binding(
            get: { app != nil },
            set: { asked in
                if !asked { app = nil }
            })
    }

    func body(content: Content) -> some View {
        content.confirmationDialog(
            app.map { CartoucheText.uninstallQuestion($0.displayName) } ?? "",
            isPresented: asking,
            titleVisibility: .visible,
            presenting: app
        ) { app in
            if let onCopyFirst, let server = Self.copyServer(for: app) {
                Button(CartoucheText.uninstallCopyFirst(server)) { onCopyFirst(app) }
            }
            Button(CartoucheText.uninstallKeepSaves, role: .destructive) { onAnswer(app, false) }
            Button(CartoucheText.uninstallEraseSaves, role: .destructive) { onAnswer(app, true) }
            Button(CartoucheText.cancel, role: .cancel) {}
        } message: { app in
            Text(Self.message(for: app))
        }
    }

    /// The copy of the game in the games folder, if there is one.
    @MainActor
    static func storedCopy(of app: LCAppModel) -> CartoucheStoredGame? {
        let found = CartoucheCatalog.shared.gameTitle(of: app)
        let titleId = found.flatMap { $0.isEmpty ? nil : $0 }
        return CartoucheStoredGames.shared.game(titleId: titleId, bundleId: app.appInfo.bundleIdentifier())
    }

    /// The games folder's server, when the game has no copy there yet.
    @MainActor
    static func copyServer(for app: LCAppModel) -> String? {
        guard let server = CartoucheStorageSettings.shared.location(.games)?.server,
              CartoucheCatalog.shared.gameTitle(of: app) != nil, storedCopy(of: app) == nil else { return nil }
        return server.name
    }

    @MainActor
    static func message(for app: LCAppModel) -> String {
        if storedCopy(of: app) != nil, let server = CartoucheStoredGames.shared.serverName {
            return CartoucheText.uninstallMessageStored(server)
        }
        return CartoucheText.uninstallMessage
    }
}
