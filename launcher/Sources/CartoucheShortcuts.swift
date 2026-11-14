//
//  CartoucheShortcuts.swift
//  Cartouche
//
//  Siri and the Shortcuts app start the player's games as Play does on the
//  console: "Play Mario Kart World in Cartouche", « Lance Mario Kart dans
//  Cartouche », or Play a Game, an action of Cartouche's for a shortcut,
//  which the player can put on the Home Screen, an icon for each game
//  (CartoucheGameShortcutsView says how). They are App Intents of Cartouche's
//  own, in the app: no extension, no App ID of their own, no entitlement and
//  no key in its Info.plist, as App Shortcuts need none.
//
//  - A game is one of the player's installed games, known by its bundle
//    identifier, which stays when the player renames it or installs it
//    again, and named as the console names it (CartoucheCatalog), with the
//    shorter names a player says, "Mario Kart" for Mario Kart World
//    (CartoucheGameNames). The console tells iOS whenever they change, for
//    Siri to know them.
//  - Play a Game opens Cartouche, whose console then takes the game asked
//    for: it closes what is over it, the System page, a game's sheet, the
//    setup or the guide, and starts the game as Play does, behind the
//    console or in Cartouche's place, the game running behind the console
//    coming back to the screen, another asking first whether to quit it,
//    and without the certificate the setup showing what is missing
//    (CartoucheGamesView). An install, an uninstall or a copy under way
//    makes Siri say so, rather than start the game once it is over; a game
//    since uninstalled, too.
//
//  iOS reads an app's App Intents from the Metadata.appintents of the app
//  itself. Xcode writes this file's into LiveContainerSwiftUI.framework,
//  where the launcher is built, and app/scripts/app_intents.py merges them
//  into the app's, beside the built-in SideStore's, with their French
//  (launcher/AppIntents/fr.json) in the app's own strings, where iOS looks
//  for the words of an app's intents (docs/decisions.md, 90).
//

import AppIntents
import Foundation

/// One of the player's installed games, as Siri and Shortcuts know it.
@available(iOS 17.0, *)
struct CartoucheGameEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Game"
    static let defaultQuery = CartoucheGameQuery()

    /// The game's bundle identifier.
    let id: String
    /// Its name, as the console shows it.
    let name: String
    /// The shorter names Siri also takes (CartoucheGameNames).
    let synonyms: [String]

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)", subtitle: nil, image: nil,
                              synonyms: synonyms.map { synonym -> LocalizedStringResource in "\(synonym)" })
    }
}

/// The player's installed games, for Siri, which asks for those it may
/// name, and for Shortcuts, where the player picks one or types its name.
@available(iOS 17.0, *)
struct CartoucheGameQuery: EntityStringQuery {
    func entities(for identifiers: [String]) async throws -> [CartoucheGameEntity] {
        let games = await MainActor.run { CartoucheGameShortcuts.games() }
        return identifiers.compactMap { id in games.first { $0.id == id } }
    }

    func entities(matching string: String) async throws -> [CartoucheGameEntity] {
        let games = await MainActor.run { CartoucheGameShortcuts.games() }
        return games.filter { CartoucheGameNames.matches(string, name: $0.name, synonyms: $0.synonyms) }
    }

    func suggestedEntities() async throws -> [CartoucheGameEntity] {
        await MainActor.run { CartoucheGameShortcuts.games() }
    }
}

/// Play a Game: Cartouche opens and starts the game, as Play does.
@available(iOS 17.0, *)
struct CartouchePlayGameIntent: AppIntent {
    static let title: LocalizedStringResource = "Play a Game"
    static let description = IntentDescription("Opens Cartouche and starts one of your games, as Play does.")
    static let openAppWhenRun: Bool = true

    @Parameter(title: "Game", requestValueDialog: IntentDialog("Which game?"))
    var game: CartoucheGameEntity

    static var parameterSummary: some ParameterSummary {
        Summary("Play \(\.$game)")
    }

    init() {}

    init(game: CartoucheGameEntity) {
        self.game = game
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        try CartoucheGameShortcuts.shared.start(game)
        return .result()
    }
}

/// What Siri says, and Shortcuts shows, when Cartouche cannot start the
/// game: in the player's language already, as the launcher's own words.
@available(iOS 17.0, *)
struct CartoucheShortcutError: Error, CustomLocalizedStringResourceConvertible {
    enum Kind: String {
        /// The game was uninstalled since the shortcut was made.
        case notInstalled
        /// Cartouche installs, uninstalls, copies or starts a game.
        case busy
    }

    let kind: Kind
    let message: String

    var localizedStringResource: LocalizedStringResource {
        "\(message)"
    }
}

/// Siri's phrases, and the action the Shortcuts app shows under Cartouche,
/// with a tile for each of the player's games.
@available(iOS 17.0, *)
struct CartoucheShortcutsProvider: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: CartouchePlayGameIntent(),
                    phrases: [
                        "Play \(\.$game) in \(.applicationName)",
                        "Play \(\.$game) with \(.applicationName)",
                        "Start \(\.$game) in \(.applicationName)",
                        "Launch \(\.$game) in \(.applicationName)",
                        "Open \(\.$game) in \(.applicationName)",
                        "Play a game in \(.applicationName)",
                    ],
                    shortTitle: "Play a Game",
                    systemImageName: "gamecontroller.fill")
    }

    static var shortcutTileColor: ShortcutTileColor { .purple }
}

/// The game Siri or a shortcut asked for, until the console takes it, and
/// the player's games, as Siri and Shortcuts name them.
@available(iOS 17.0, *)
@MainActor
final class CartoucheGameShortcuts: ObservableObject {
    static let shared = CartoucheGameShortcuts()

    struct Request: Equatable {
        /// The game's bundle identifier.
        let id: String
        let name: String
        let asked: Date
    }

    /// The game asked for, until the console takes it.
    @Published private(set) var request: Request?
    /// The games iOS was told of since Cartouche started.
    private var told: [String]?

    /// The player's installed games, by the names the console gives them,
    /// each with the shorter names no other of their games could take.
    static func games(of apps: [LCAppModel] = DataManager.shared.model.apps) -> [CartoucheGameEntity] {
        let installed = CartoucheCatalog.shared.entries(for: apps).owned.filter { $0.app != nil }
        let names = installed.map(\.name)
        return installed.compactMap { entry in
            guard let id = entry.app?.appInfo.bundleIdentifier(), !entry.name.isEmpty else { return nil }
            return CartoucheGameEntity(id: id, name: entry.name, synonyms: CartoucheGameNames.synonyms(of: entry.name, among: names))
        }
    }

    /// What iOS is told of the player's games: each one's identifier and
    /// name, which the console watches.
    static func names(of entries: CartoucheCatalog.Entries) -> [String] {
        entries.owned.compactMap { entry in
            guard let id = entry.app?.appInfo.bundleIdentifier() else { return nil }
            return id + "=" + entry.name
        }.sorted()
    }

    /// Asks for GAME, which the console starts as Play does. Throws, for
    /// Siri to say why, when the game is no longer installed or Cartouche
    /// is busy with a game: it would start once that is over, the player
    /// having long given up on it.
    func start(_ game: CartoucheGameEntity) throws {
        guard let app = DataManager.shared.model.apps.first(where: { $0.appInfo.bundleIdentifier() == game.id }) else {
            note(nil, outcome: "notInstalled")
            CartoucheReports.note(game.name + ": asked by Siri or Shortcuts, no longer installed")
            throw CartoucheShortcutError(kind: .notInstalled, message: CartoucheText.shortcutNotInstalled(game.name))
        }
        if let work = CartoucheGameActions.shared.work {
            note(app, outcome: "busy")
            CartoucheReports.note(app.displayName + ": asked by Siri or Shortcuts while " + work.title)
            throw CartoucheShortcutError(kind: .busy, message: CartoucheText.shortcutBusy(work.title))
        }
        CartoucheReports.note(app.displayName + ": asked by Siri or Shortcuts")
        request = Request(id: game.id, name: app.displayName, asked: Date())
    }

    /// The console takes REQUEST, to start its game.
    func take(_ request: Request) {
        guard self.request == request else { return }
        self.request = nil
        let app = DataManager.shared.model.apps.first { $0.appInfo.bundleIdentifier() == request.id }
        note(app, outcome: app == nil ? "gone" : "started", waited: Date().timeIntervalSince(request.asked))
    }

    /// Drops the game asked for, should the console not take it.
    func drop() {
        request = nil
    }

    /// Tells iOS the player's games, NAMES, when they changed since it was
    /// last told: Siri knows their names from then on.
    func tellIOS(_ names: [String]) {
        guard names != told else { return }
        told = names
        CartoucheShortcutsProvider.updateAppShortcutParameters()
    }

    /// One `game.shortcut` event (telemetry/README.md): how Cartouche took
    /// the game asked for, and how long the console took to take it.
    private func note(_ app: LCAppModel?, outcome: String, waited: TimeInterval? = nil) {
        var fields: [String: CartoucheTelemetryValue] = ["outcome": .text(outcome)]
        if let waited { fields["waitedMs"] = .number((waited * 1_000).rounded()) }
        let catalog = CartoucheCatalog.shared
        let game = app.flatMap { app in
            catalog.gameTitle(of: app).flatMap { $0.isEmpty ? catalog.titleId(matchingName: app.displayName) : $0 }
        }
        CartoucheTelemetry.shared.event("game.shortcut", game: game, fields: fields)
    }
}
