//
//  ConsoleView.swift
//  Cartouche on the Mac
//
//  Cartouche's console on the Mac: its home and every game, with the sheet
//  of the game in focus beside them, as the iPhone Duo unfolded shows them
//  (launcher/Sources/CartoucheGamesView.swift). The screens are the
//  iPhone's own (Shared/); the app gives the console the games nxnative
//  built for this Mac, by their apps, and does what the player asks of
//  them: Play starts a game's app, Game settings starts it on nxnative's
//  settings window, Import and System lead to the app's own pages.
//
//  This is the console's only public part: the app imports it in one file,
//  so that its names never meet those of the launcher's other library,
//  CartoucheCore, which shares some of its files.
//

import SwiftUI

/// The console's games, and what the app does for it.
@MainActor
public final class CartoucheMacConsole: ObservableObject {
    public static let shared = CartoucheMacConsole()

    /// The games' apps, as the console's screens know a game.
    @Published private(set) var apps: [LCAppModel] = []
    private var models: [String: LCAppModel] = [:]

    /// Starts the game's app, on nxnative's settings window first when
    /// SHOWINGSETTINGS, or brings it to the front if it runs.
    public var onPlay: (_ game: URL, _ showingSettings: Bool) -> Void = { _, _ in }
    /// Asks the running game's app to quit.
    public var onQuit: (_ game: URL) -> Void = { _ in }
    /// Import, on the home or the sheet of a game the player has no copy
    /// of: the Builder adds games.
    public var onImport: () -> Void = {}
    /// System, on the home's dock.
    public var onSystem: () -> Void = {}
    /// Removes the game from this Mac; the app asks the player first.
    public var onUninstall: (_ game: URL) -> Void = { _ in }
    /// Whether the console asks Cartouche's server for newer covers and
    /// for what IGDB has of the games it does not know, as the iPhone's
    /// does: not for the app's gallery, which shows the covers it carries.
    public var asksServer = true

    private init() {
        CartoucheGameActions.shared.onQuit = { [weak self] app in self?.onQuit(app.appInfo.url) }
    }

    /// Where nxnative's apps keep each game's data on this Mac, its saves
    /// among them: ~/Library/Application Support/nxnative/<title ID>.
    public var dataFolder: URL {
        get { CartoucheGameActions.shared.dataRoot }
        set { CartoucheGameActions.shared.dataRoot = newValue }
    }

    /// The games built for this Mac, by their apps. A game the console
    /// showed already stays the same game, its focus and its sheet with it.
    public func show(games: [URL]) {
        var kept: [String: LCAppModel] = [:]
        var shown: [LCAppModel] = []
        for url in games {
            let key = url.standardizedFileURL.path
            guard kept[key] == nil else { continue }
            let model = models[key] ?? LCAppModel(appInfo: LCAppInfo(url: url))
            kept[key] = model
            shown.append(model)
        }
        models = kept
        apps = shown
        if let running = CartoucheGameActions.shared.running, !shown.contains(where: { $0 === running.app }) {
            CartoucheGameActions.shared.running = nil
        }
    }

    /// The game whose app runs, if one of the console's does, and whether
    /// it is the Mac's active app.
    public func showRunning(_ game: URL?, inFront: Bool) {
        let actions = CartoucheGameActions.shared
        guard let game, let app = models[game.standardizedFileURL.path] else {
            actions.running = nil
            return
        }
        if let running = actions.running, running.app === app {
            if running.isInFront != inFront { actions.running?.isInFront = inFront }
        } else {
            actions.running = CartoucheRunningGame(app: app, started: Date(), isInFront: inFront)
        }
    }

    /// The language the console speaks, as the app's settings choose it:
    /// "fr" or "en", or nil for the Mac's.
    @Published public private(set) var language: String?

    /// Speaks LANGUAGE from now on, "fr" or "en", or the Mac's language for
    /// nil: the console's words change at once, as the app's do.
    public func speak(_ language: String?) {
        speak(language, from: Bundle.main.resourceURL)
    }

    /// Speaks LANGUAGE with the words in RESOURCES/Console/<language>, which
    /// holds that language alone (bundle.sh, console/strings.py).
    func speak(_ language: String?, from resources: URL?) {
        let chosen = language.flatMap { ["fr", "en"].contains($0) ? $0 : nil }
        let folder = chosen.flatMap { resources?.appendingPathComponent("Console/" + $0, isDirectory: true) }
        CartoucheText.bundle = folder.flatMap { Bundle(url: $0) } ?? Bundle(for: CartoucheCatalog.self)
        self.language = chosen
    }

    /// Loads the covers and artworks the console shows of its games, and
    /// of EVERYGAME's covers too: the gallery waits for them before it
    /// takes its pictures.
    public func loadCovers(everyGame: Bool) async {
        let entries = CartoucheCatalog.shared.entries(for: apps)
        var arts = entries.owned.flatMap { [$0.coverArt, $0.backdrop].compactMap { $0 } }
        if everyGame {
            arts += entries.others.compactMap(\.coverArt)
        }
        for art in arts {
            _ = await CartoucheCoverStore.shared.image(art)
        }
    }
}

/// The console: the home, or every game, and the sheet of the game in
/// focus beside it once the player has a game here.
public struct CartoucheMacConsoleView: View {
    @ObservedObject private var console = CartoucheMacConsole.shared
    @ObservedObject private var catalog = CartoucheCatalog.shared
    @ObservedObject private var actions = CartoucheGameActions.shared
    @State private var path: [Route]
    /// The game in focus, or the last one whose sheet opened: the game of
    /// the sheet beside the console.
    @State private var paneID: String?
    @Namespace private var zoom

    enum Route: Hashable {
        case library
    }

    /// The console on its home, or with every game open, as the app's
    /// gallery shows it.
    public init(showingLibrary: Bool = false) {
        _path = State(initialValue: showingLibrary ? [.library] : [])
    }

    public var body: some View {
        let entries = catalog.entries(for: console.apps)
        HStack(spacing: 0) {
            home(entries)
                .frame(minWidth: 480, maxWidth: .infinity, maxHeight: .infinity)
            // Before the player has a game here, nothing stands beside the
            // console, never a game they do not have.
            if let entry = paneEntry(in: entries) {
                gameSheet(entry)
                    .frame(minWidth: 420, maxWidth: .infinity, maxHeight: .infinity)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        // Another language: every word again.
        .id(console.language ?? "")
        .animation(.easeInOut(duration: 0.25), value: entries.owned.isEmpty)
        .preferredColorScheme(.dark)
        .onAppear {
            guard console.asksServer else { return }
            catalog.refreshCoversIfDue()
            catalog.lookUpGamesIfDue(among: entries)
        }
        // A game added, removed or renamed: Cartouche asks its server about
        // those it does not know.
        .onChange(of: CartoucheCatalog.wanted(among: entries)) { _, _ in
            guard console.asksServer else { return }
            catalog.lookUpGamesIfDue(among: catalog.entries(for: console.apps))
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
            CartoucheGameStats.shared.cameBack(console.apps)
            guard console.asksServer else { return }
            catalog.refreshCoversIfDue()
        }
    }

    /// The home, and every game one step further.
    private func home(_ entries: CartoucheCatalog.Entries) -> some View {
        NavigationStack(path: $path) {
            CartoucheHomeView(
                entries: entries,
                gameCount: entries.all.count,
                isActive: path.isEmpty,
                onPlay: { play($0) },
                onImport: { console.onImport() },
                onUninstall: { console.onUninstall($0.appInfo.url) },
                onSheet: { focus($0) },
                onLibrary: { path.append(.library) },
                onSetup: {},
                onTab: { tab in
                    if tab == .system { console.onSystem() }
                },
                zoom: path.isEmpty ? zoom : nil,
                // Beside the console, the sheet describes the game in focus.
                showsHero: entries.owned.isEmpty,
                onFocus: { item in
                    if case .game(let entry) = item { focus(entry) }
                })
                .navigationDestination(for: Route.self) { route in
                    switch route {
                    case .library:
                        CartoucheLibraryView(
                            entries: entries,
                            isActive: path.last == .library,
                            onPlay: { play($0) },
                            onSheet: { focus($0) },
                            onBack: { if !path.isEmpty { path.removeLast() } },
                            zoom: zoom,
                            onFocus: { focus($0) })
                    }
                }
        }
    }

    /// A game's sheet, beside the console.
    private func gameSheet(_ entry: CartoucheEntry) -> some View {
        NavigationStack {
            CartoucheGameSheetView(
                entry: entry,
                memory: nil,
                onPlay: { play($0) },
                onSettings: { play($0, showingSettings: true) },
                onImport: { console.onImport() },
                onUninstall: { console.onUninstall($0.appInfo.url) })
                .id(entry.id)
        }
    }

    /// The game of the sheet beside the console: the game in focus, or the
    /// last whose sheet opened; before any, the player's first game.
    private func paneEntry(in entries: CartoucheCatalog.Entries) -> CartoucheEntry? {
        guard !entries.owned.isEmpty else { return nil }
        return entries.entry(id: paneID) ?? entries.owned.first
    }

    private func focus(_ entry: CartoucheEntry) {
        paneID = entry.id
    }

    /// Starts the game's app, or brings it back to the front.
    private func play(_ app: LCAppModel, showingSettings: Bool = false) {
        console.onPlay(app.appInfo.url, showingSettings)
    }
}
