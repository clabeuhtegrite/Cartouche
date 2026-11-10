//
//  CartoucheGamesView.swift
//  Cartouche
//
//  The Games tab, Cartouche's console: the home (CartoucheHomeView), every
//  game (CartoucheLibraryView), and a game's sheet, with the game's
//  settings one step further (CartoucheGameSettingsView). The console takes
//  the whole screen, dark: the home's dock opens the System page over it
//  (CartoucheRootView).
//
//  In a compact width, on any iPhone and on the iPhone Duo's outer display,
//  a game's sheet opens over the home or every game. In a regular width,
//  on the Duo's inner display or an iPad, with iOS 27.1 or later, the sheet
//  of the game in focus stands beside them instead, on the other side of
//  the Duo's fold (CartoucheArrangement): moving the focus, with a tap or
//  the controller, changes the game it shows, and the home leaves out the
//  description of the game in focus that the sheet gives in full. On the
//  cover that imports a game, or the one for every game, what it does
//  stands there instead (CartoucheFocusPanel), and the import's before the
//  player has a game. Unfolding the Duo moves an open sheet beside the
//  console; folding it puts the settings page open beside the console back
//  in a sheet over it, and otherwise leaves the game the sheet showed in
//  focus.
//
//  Cartouche installs, starts and uninstalls a game itself, on these
//  screens (CartoucheGameActions): the player never lands in the Apps tab.
//  A game the player has just imported opens on its sheet, Play first. The
//  games of the player's games folder are among theirs, installed or not
//  (CartoucheStoredGames), and the saves of the games that changed are
//  copied to the saves folder whenever Cartouche comes back, after a game
//  (CartoucheSaveBackups), when the games' play times are read again too
//  (CartoucheGameStats). A step that fails says why, with the report the
//  player can copy (CartoucheReporting.swift).
//
//  A player new to Cartouche follows its guide to their first game
//  (CartoucheGuideView): it opens by itself on the first launch, then from
//  the home's card, until their first game is installed.
//
//  A game can run behind the console, paused while the console shows
//  (CartoucheGameHost): Play on it brings it back, and Play on another
//  asks first whether to quit it, over the sheet if one is open
//  (CartoucheRunningGameQuestions). Cartouche's own update waits until it
//  has ended, since the update closes Cartouche.
//

import SwiftUI
import UniformTypeIdentifiers

@available(iOS 17.0, *)
struct CartoucheGamesView: View {
    @EnvironmentObject private var sharedModel: SharedModel
    @Environment(\.horizontalSizeClass) private var widthClass
    @ObservedObject private var setup = CartoucheSetup.shared
    @ObservedObject private var actions = CartoucheGameActions.shared
    @ObservedObject private var storedGames = CartoucheStoredGames.shared
    @ObservedObject private var updates = CartoucheUpdates.shared
    @ObservedObject private var account = CartoucheAccount.shared
    @ObservedObject private var guide = CartoucheGuide.shared
    @State private var path: [Route] = []
    /// The game whose sheet is open over the console, in a compact width.
    @State private var sheetID: String?
    /// The game in focus, or the last one whose sheet opened: the game of
    /// the sheet beside the console, in a regular width.
    @State private var paneID: String?
    /// The home's cover in focus when it is not a game's: what stands
    /// beside the console instead of the game's sheet.
    @State private var paneCover: CartoucheFocusPanel.Kind?
    @State private var choosingIPA = false
    @State private var choosingIPAInSheet = false
    @State private var memory = CartoucheMemoryReading.now()
    @State private var showingSetup = false
    @State private var showingGuide = false
    /// The game whose uninstall the player is asked about, from the home or
    /// from the sheet, over the console or beside it.
    @State private var uninstalling: LCAppModel?
    @State private var uninstallingInSheet: LCAppModel?
    /// The settings page open over the game's sheet, over the console or
    /// beside it.
    @State private var gameSettings: CartoucheGameSettingsModel?
    /// The report of a failure was just copied, from its alert.
    @State private var reportCopied = false
    /// A game's sheet grows out of its cartridge.
    @Namespace private var zoom

    enum Route: Hashable {
        case library
    }

    /// Newer covers show as soon as they arrive.
    @ObservedObject private var catalog = CartoucheCatalog.shared

    /// The console and the sheet of the game in focus side by side, around
    /// the fold of an iPhone Duo unfolded (CartoucheArrangement).
    private var splits: Bool { widthClass == .regular && CartoucheSplit.isAvailable }

    private var onGames: Bool { sharedModel.selectedTab == .games }
    /// Nothing over the console, but maybe a game's settings page open
    /// beside it.
    private var nothingOverConsole: Bool {
        sheetID == nil && !showingSetup && !showingGuide && !choosingIPA && uninstalling == nil
            && actions.work == nil && actions.notice == nil && !showsUpdate
            && actions.switching == nil && actions.quitQuestion == nil
    }
    /// Nothing over the console or beside it that takes the controller.
    private var nothingOver: Bool { nothingOverConsole && gameSettings == nil }
    /// Cartouche's own update shows over the console alone, once nothing
    /// else is over it.
    private var showsUpdate: Bool {
        updates.isShowing && onGames && sheetID == nil && !showingSetup && !showingGuide && !choosingIPA
            && uninstalling == nil && actions.work == nil && actions.notice == nil
            && actions.running == nil && actions.switching == nil && actions.quitQuestion == nil
    }

    var body: some View {
        let entries = catalog.entries(for: sharedModel.apps, stored: storedGames.games)
        CartoucheArrangement(splits: splits) {
            console(entries)
        } secondary: {
            if splits {
                if let kind = paneKind(in: entries) {
                    CartoucheFocusPanel(kind: kind, gameCount: entries.all.count) {
                        switch kind {
                        case .importGame: choosingIPA = true
                        case .allGames: path.append(.library)
                        }
                    }
                } else if let entry = paneEntry(in: entries) {
                    gameSheet(entry, beside: true)
                        .modifier(CartoucheUninstallQuestion(app: $uninstallingInSheet, onAnswer: uninstall, onCopyFirst: copyThenUninstall))
                        // The settings page beside the console takes the
                        // controller; the console has it otherwise.
                        .onReceive(CartoucheGamepad.shared.inputs) { input in
                            guard onGames, nothingOverConsole, uninstallingInSheet == nil else { return }
                            _ = handleSettings(input)
                        }
                }
            }
        }
        // Dark always, under the System page too, which covers it.
        .preferredColorScheme(.dark)
        .fileImporter(isPresented: $choosingIPA, allowedContentTypes: [.ipa]) { result in
            if case .success(let url) = result {
                importCopy(url)
            }
        }
        .sheet(isPresented: sheetPresented) {
            if let entry = entries.entry(id: sheetID) {
                gameSheet(entry, beside: false)
                    .cartoucheZoom(from: entry.id, in: zoom)
                    .preferredColorScheme(.dark)
                    .fileImporter(isPresented: $choosingIPAInSheet, allowedContentTypes: [.ipa]) { result in
                        if case .success(let url) = result {
                            importCopy(url)
                        }
                    }
                    .modifier(CartoucheUninstallQuestion(app: $uninstallingInSheet, onAnswer: uninstall, onCopyFirst: copyThenUninstall))
                    // Over the sheet, which the other game's start closes.
                    .modifier(CartoucheRunningGameQuestions(shown: true, onSwitch: { sheetID = nil }))
                    .onReceive(CartoucheGamepad.shared.inputs) { input in
                        guard uninstallingInSheet == nil, actions.switching == nil, actions.quitQuestion == nil,
                              !handleSettings(input) else { return }
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
                            doneButton { showingSetup = false }
                        }
                    }
            }
            .onReceive(CartoucheGamepad.shared.inputs) { input in
                if input == .b { showingSetup = false }
            }
        }
        // The guide's steps act on the console: it closes for a game to
        // install, to import or to play.
        .sheet(isPresented: $showingGuide) {
            NavigationStack {
                CartoucheGuideView(
                    entries: entries,
                    onInstall: { game in
                        showingGuide = false
                        installStored(game)
                    },
                    onImport: { url in
                        showingGuide = false
                        importCopy(url)
                    },
                    onPlay: { app in
                        showingGuide = false
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { play(app) }
                    })
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            doneButton { showingGuide = false }
                        }
                    }
            }
            .preferredColorScheme(.dark)
            .onReceive(CartoucheGamepad.shared.inputs) { input in
                if input == .b { showingGuide = false }
            }
        }
        .modifier(CartoucheUninstallQuestion(app: $uninstalling, onAnswer: uninstall, onCopyFirst: copyThenUninstall))
        // Over the console, or the sheet beside it; the sheet over the
        // console asks itself.
        .modifier(CartoucheRunningGameQuestions(shown: sheetID == nil))
        .overlay {
            if let work = actions.work {
                CartoucheGameWorkView(work: work)
                    .transition(.opacity)
            } else if showsUpdate {
                CartoucheUpdateView(updates: updates)
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: actions.work)
        .animation(.easeInOut(duration: 0.2), value: showsUpdate)
        // The sheet over the console closed: its settings page goes too. It
        // stays when the sheet moves beside the console.
        .onChange(of: sheetID) { _, id in
            if id == nil && !splits { gameSettings = nil }
        }
        // The iPhone Duo unfolded: the sheet open over the console moves
        // beside it, with its settings page. Folded: the settings page open
        // beside the console comes back over it, in the game's sheet; the
        // sheet alone stays behind, as the game in focus.
        .onChange(of: splits) { _, splits in
            if splits {
                if let sheetID {
                    paneID = sheetID
                    paneCover = nil
                }
                sheetID = nil
            } else if gameSettings != nil {
                sheetID = paneID
            }
        }
        .alert(actions.notice?.title ?? "", isPresented: noticeShown, presenting: actions.notice) { notice in
            if let report = notice.report {
                Button(CartoucheText.reportCopy) {
                    CartoucheReports.copy(report)
                    actions.notice = nil
                    reportCopied = true
                }
                Button(CartoucheText.done, role: .cancel) { actions.notice = nil }
            } else {
                Button(CartoucheText.done) { actions.notice = nil }
            }
        } message: { notice in
            Text(notice.message)
        }
        // A controller answers the alert: A or B closes it, Y copies the
        // report. It closes once every view has had the input, so that the
        // console and the page beside it, which wait for it to close, do not
        // take that input too.
        .onReceive(CartoucheGamepad.shared.inputs) { input in
            guard let notice = actions.notice else { return }
            switch input {
            case .a, .b:
                break
            case .y:
                guard let report = notice.report else { return }
                CartoucheReports.copy(report)
                reportCopied = true
            default:
                return
            }
            DispatchQueue.main.async { actions.notice = nil }
        }
        .overlay(alignment: .top) {
            if reportCopied {
                CartoucheReportCopiedBanner()
                    .padding(.top, 8)
                    .padding(.horizontal, 16)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.spring(duration: 0.35), value: reportCopied)
        .sensoryFeedback(.success, trigger: reportCopied) { _, now in now }
        .task(id: reportCopied) {
            guard reportCopied else { return }
            AccessibilityNotification.Announcement(CartoucheText.reportCopied).post()
            try? await Task.sleep(for: .seconds(2.5))
            reportCopied = false
        }
        // A game just imported: its sheet, with Play, unless there is
        // something to tell first.
        .onChange(of: actions.installed) { _, app in
            guard let app else { return }
            actions.installed = nil
            let entries = catalog.entries(for: sharedModel.apps, stored: storedGames.games)
            // The player's first game: the guide has done its job.
            guide.note(guide.progress(entries))
            guard actions.notice == nil,
                  let entry = entries.owned.first(where: { $0.app === app }) else { return }
            path.removeAll()
            showSheet(entry)
        }
        // Hands the built-in SideStore's certificate to LiveContainer as soon
        // as the player has signed in, before they pick a game.
        .modifier(CartoucheSetupRefresh())
        // A pairing file opened with Cartouche: the setup shows how it went.
        .onChange(of: setup.openedPairingFile) { _, opened in
            guard opened else { return }
            setup.openedPairingFile = false
            let guideWasOpen = showingGuide
            showingGuide = false
            DispatchQueue.main.asyncAfter(deadline: .now() + (guideWasOpen ? 0.6 : 0)) { showingSetup = true }
        }
        // Apple asks for a code while Cartouche signs in again by itself, for
        // a new certificate: the setup opens on the sign-in, unless the
        // guide, which shows the sign-in too, is open.
        .onChange(of: account.needsCode) { _, needsCode in
            guard needsCode, account.isAutomatic, !showingSetup, !showingGuide else { return }
            sheetID = nil
            showingSetup = true
        }
        .onAppear {
            memory = CartoucheMemoryReading.now()
            CartoucheRenewal.scheduleWarnings()
            storedGames.refresh()
            actions.copySaves(of: sharedModel.apps)
            CartoucheGameStats.shared.cameBack(sharedModel.apps)
            updates.checkIfDue()
            catalog.refreshCoversIfDue()
            openGuideIfNew()
        }
        // A renewal in the background moves the expiry date: warn for the
        // new one each time the player comes back. A game may have saved and
        // counted its play time meanwhile, and the games folder changed.
        // Cartouche's source may list a new version, newer covers may be out.
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
            CartoucheRenewal.scheduleWarnings()
            storedGames.refresh()
            actions.copySaves(of: sharedModel.apps)
            CartoucheGameStats.shared.cameBack(sharedModel.apps)
            updates.checkIfDue()
            catalog.refreshCoversIfDue()
        }
    }

    /// The home, and every game one step further.
    private func console(_ entries: CartoucheCatalog.Entries) -> some View {
        NavigationStack(path: $path) {
            CartoucheHomeView(
                entries: entries,
                gameCount: entries.all.count,
                isActive: onGames && path.isEmpty && nothingOver,
                onPlay: { play($0) },
                onImport: { choosingIPA = true },
                onInstall: { installStored($0) },
                onUninstall: { uninstalling = $0 },
                onSheet: { showSheet($0) },
                onLibrary: { path.append(.library) },
                onSetup: { showingSetup = true },
                onGuide: { showingGuide = true },
                onTab: { sharedModel.selectedTab = $0 },
                // One cartridge per game to grow from: the library's, once
                // it is over the home.
                zoom: path.isEmpty ? zoom : nil,
                // Beside the console, the sheet describes the game in focus.
                showsHero: !splits,
                onFocus: { focusShelf($0) })
                .toolbar(.hidden, for: .navigationBar)
                .toolbar(.hidden, for: .tabBar)
                .navigationDestination(for: Route.self) { route in
                    switch route {
                    case .library:
                        CartoucheLibraryView(
                            entries: entries,
                            isActive: onGames && path.last == .library && nothingOver,
                            onPlay: { play($0) },
                            onSheet: { showSheet($0) },
                            onBack: { if !path.isEmpty { path.removeLast() } },
                            zoom: zoom,
                            onFocus: { focus($0) })
                            .toolbar(.hidden, for: .tabBar)
                    }
                }
        }
    }

    /// A game's sheet, with its settings page one step further: over the
    /// console, with Done, or BESIDE it, where the player's games are
    /// imported, and asked about, by the console's own file importer and
    /// questions.
    private func gameSheet(_ entry: CartoucheEntry, beside: Bool) -> some View {
        NavigationStack {
            CartoucheGameSheetView(
                entry: entry,
                memory: memory,
                onPlay: { play($0) },
                onSettings: { app in
                    // The sheet shows the game the console falls back on:
                    // the settings page is for it.
                    if beside { paneID = entry.id }
                    gameSettings = actions.settings(for: app, tileKey: entry.tileKey)
                },
                onImport: {
                    if beside { choosingIPA = true } else { choosingIPAInSheet = true }
                },
                onUninstall: { uninstallingInSheet = $0 },
                onInstallStored: { installStored($0) },
                onExport: { exportCopy($0) })
                .id(entry.id)
                // Beside the console, the sheet's bar would hold nothing.
                .toolbar(beside ? .hidden : .automatic, for: .navigationBar)
                .toolbar {
                    if !beside {
                        ToolbarItem(placement: .confirmationAction) {
                            doneButton { sheetID = nil }
                        }
                    }
                }
                .navigationDestination(item: $gameSettings) { settings in
                    CartoucheGameSettingsView(model: settings) {
                        if let app = entry.app { play(app, showingSettings: true) }
                    }
                    .toolbar {
                        if !beside {
                            ToolbarItem(placement: .confirmationAction) {
                                doneButton { sheetID = nil }
                            }
                        }
                    }
                }
        }
    }

    /// Done, with a symbol as well as its name: the iPhone Duo shows the
    /// bars of a sheet down the side of its outer display, where an item
    /// with a name alone does not appear.
    private func doneButton(_ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(CartoucheText.done, systemImage: "checkmark")
        }
    }

    /// The game of the sheet beside the console: the game in focus, or the
    /// last whose sheet opened; before any, the player's first game.
    private func paneEntry(in entries: CartoucheCatalog.Entries) -> CartoucheEntry? {
        entries.entry(id: paneID) ?? entries.owned.first
    }

    /// What stands beside the console instead of a game's sheet: the home's
    /// cover in focus when it is not a game's, or, before the player has a
    /// game, the one that imports a game, rather than a game they do not
    /// have.
    private func paneKind(in entries: CartoucheCatalog.Entries) -> CartoucheFocusPanel.Kind? {
        if let paneCover { return paneCover }
        return paneEntry(in: entries) == nil ? .importGame : nil
    }

    /// On the controller, a game's settings page open: L and R change the
    /// category, B goes back to the sheet. Whether the page took the input.
    private func handleSettings(_ input: CartoucheGamepad.Input) -> Bool {
        guard let settings = gameSettings else { return false }
        switch input {
        case .b: gameSettings = nil
        case .previous: settings.moveCategory(by: -1)
        case .next: settings.moveCategory(by: 1)
        default: break
        }
        return true
    }

    /// The game in focus on the home or in every game: the sheet beside the
    /// console shows it. Another game in focus closes the settings page of
    /// the last. With a sheet over the console, the focus does not move.
    private func focus(_ entry: CartoucheEntry) {
        guard sheetID == nil else { return }
        if paneID != entry.id { gameSettings = nil }
        paneID = entry.id
        paneCover = nil
    }

    /// The cover in focus on the home's shelf: a game's, or the one that
    /// imports a game or opens every game, which stands beside the console
    /// in the game's sheet's place, its settings page closed.
    private func focusShelf(_ item: CartoucheHomeView.Item) {
        let cover: CartoucheFocusPanel.Kind
        switch item {
        case .game(let entry):
            focus(entry)
            return
        case .importGame: cover = .importGame
        case .allGames: cover = .allGames
        case .dock: return
        }
        guard sheetID == nil, paneCover != cover else { return }
        gameSettings = nil
        paneCover = cover
    }

    /// A game's sheet: beside the console in a split, over it otherwise.
    private func showSheet(_ entry: CartoucheEntry) {
        if paneID != entry.id { gameSettings = nil }
        paneID = entry.id
        paneCover = nil
        if !splits { sheetID = entry.id }
    }

    /// A new install: the guide opens by itself, once, over the console.
    /// A player who already has a game never sees it.
    private func openGuideIfNew() {
        let progress = guide.progress(catalog.entries(for: sharedModel.apps, stored: storedGames.games))
        guide.note(progress)
        #if !CARTOUCHE_GALLERY
        guard guide.opensByItself(progress) else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            if nothingOver { showingGuide = true }
        }
        #endif
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

    /// Starts the game, behind the console or in Cartouche's place. With
    /// showingSettings, nxnative's settings screen comes first.
    private func play(_ app: LCAppModel, showingSettings: Bool = false) {
        // A game runs behind the console: it comes back on screen, or the
        // player is asked whether to quit it for another, where they are.
        if actions.running != nil {
            if actions.isRunning(app) && !showingSettings { sheetID = nil }
            actions.play(app, showingSettings: showingSettings)
            return
        }
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

    /// The games folder's server, when the game has no copy there yet and
    /// the player's account can write there.
    @MainActor
    static func copyServer(for app: LCAppModel) -> String? {
        guard let server = CartoucheStorageSettings.shared.location(.games)?.server,
              !CartoucheStorageSettings.shared.isReadOnly(.games),
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
