//
//  GalleryApp.swift
//  CartoucheGallery
//
//  Shows one scenario of scenarios.json, which the UI test passes as launch
//  arguments: a launcher screen at the scenario's size, in the top left
//  corner of the screen, with that iPhone's safe area; or, without a size,
//  the whole screen of the simulator it runs on, such as the iPhone Duo's,
//  with its own safe area, size classes and system bars.
//
//      -GalleryScreen games|library|sheet|settings|setup
//      -GalleryWidth 402 -GalleryHeight 874     (none: the whole screen)
//      -GalleryInsets 62,0,34,0          top, leading, bottom, trailing
//      -GalleryOwned 0400C3F00006E000,…  the player's games
//      -GallerySetup 1 -GalleryController 1
//      -GallerySheet <title ID>          the game of the sheet, of its
//                                        settings, or being installed
//      -GalleryWork installing           a game being installed, over the
//                                        console
//

import SwiftUI

struct GalleryScenario {
    var screen = "games"
    /// nil: the whole screen of the simulator.
    var size: CGSize?
    var insets = EdgeInsets()
    var owned: [String] = []
    var setupDone = false
    var controller = false
    var sheet: String?
    var work: String?

    static func fromArguments() -> GalleryScenario {
        let defaults = UserDefaults.standard
        var scenario = GalleryScenario()
        if let screen = defaults.string(forKey: "GalleryScreen") { scenario.screen = screen }
        let width = defaults.double(forKey: "GalleryWidth")
        let height = defaults.double(forKey: "GalleryHeight")
        if width > 0, height > 0 { scenario.size = CGSize(width: width, height: height) }
        let insets = (defaults.string(forKey: "GalleryInsets") ?? "").split(separator: ",").compactMap { Double($0) }
        if insets.count == 4 {
            scenario.insets = EdgeInsets(top: insets[0], leading: insets[1], bottom: insets[2], trailing: insets[3])
        }
        scenario.owned = (defaults.string(forKey: "GalleryOwned") ?? "").split(separator: ",").map(String.init)
        scenario.setupDone = defaults.bool(forKey: "GallerySetup")
        scenario.controller = defaults.bool(forKey: "GalleryController")
        scenario.sheet = defaults.string(forKey: "GallerySheet")
        scenario.work = defaults.string(forKey: "GalleryWork")
        return scenario
    }

    /// Puts the files the stand-ins read where the launcher looks for them.
    func prepare() {
        GalleryState.setupDone = setupDone
        let pairing = GalleryState.documents.appendingPathComponent("SideStore/Documents", isDirectory: true)
        try? FileManager.default.removeItem(at: pairing)
        if setupDone {
            try? FileManager.default.createDirectory(at: pairing, withIntermediateDirectories: true)
            try? Data("gallery".utf8).write(to: pairing.appendingPathComponent("ALTPairingFile.mobiledevicepairing"))
        }
        // The built-in SideStore's record of its last renewal.
        let renewal = """
        {"allApps": [{"bundleIdentifier": "\(Bundle.main.bundleIdentifier ?? "")",
                      "expirationDate": \(Date().addingTimeInterval(6 * 86_400 + 3_600).timeIntervalSinceReferenceDate),
                      "refreshedDate": \(Date().addingTimeInterval(-86_400).timeIntervalSinceReferenceDate)}]}
        """
        try? Data(renewal.utf8).write(to: GalleryState.appGroup.appendingPathComponent("widget_data.json"))
        MainActor.assumeIsolated {
            CartoucheSetup.shared.refresh()
            if controller { CartoucheGamepad.shared.showHints() }
            if work == "installing" {
                let name = sheet.flatMap { CartoucheCatalog.shared.game(titleId: $0)?.name } ?? "Game"
                CartoucheGameActions.shared.work = CartoucheGameWork(kind: .installing, name: name,
                                                                     step: CartoucheText.installUnpacking, fraction: 0.42)
            }
        }
    }

    func apps() -> [LCAppModel] {
        owned.compactMap { titleId in
            guard let game = CartoucheCatalog.shared.game(titleId: titleId) else { return nil }
            let info = LCAppInfo(name: game.name, identifier: "org.nxnative." + titleId.lowercased(),
                                 folder: titleId + ".app", icon: GalleryIcon.make(name: game.name, key: titleId))
            return LCAppModel(appInfo: info)
        }
    }
}

@main
struct CartoucheGalleryApp: App {
    private let scenario: GalleryScenario
    @StateObject private var model = SharedModel()

    init() {
        scenario = GalleryScenario.fromArguments()
        scenario.prepare()
    }

    var body: some Scene {
        WindowGroup {
            content
                .environmentObject(model)
                .preferredColorScheme(.dark)
                .onAppear { model.apps = scenario.apps() }
        }
    }

    @ViewBuilder
    private var content: some View {
        if let size = scenario.size {
            ZStack(alignment: .topLeading) {
                Color.black
                screen
                    .safeAreaPadding(scenario.insets)
                    .frame(width: size.width, height: size.height)
                    .clipped()
            }
            .ignoresSafeArea()
            .environment(\.horizontalSizeClass, size.width >= 600 ? .regular : .compact)
            .environment(\.verticalSizeClass, size.height >= 600 ? .regular : .compact)
            .statusBarHidden()
            .persistentSystemOverlays(.hidden)
        } else {
            screen
        }
    }

    @ViewBuilder
    private var screen: some View {
        let entries = CartoucheCatalog.shared.entries(for: model.apps)
        switch scenario.screen {
        case "library":
            NavigationStack {
                CartoucheLibraryView(entries: entries, isActive: true, onPlay: { _ in }, onSheet: { _ in }, onBack: {})
            }
        case "sheet":
            if let entry = entries.all.first(where: { $0.titleId == scenario.sheet }) {
                NavigationStack {
                    CartoucheGameSheetView(entry: entry, memory: CartoucheMemoryReading.now(), onPlay: { _ in },
                                           onSettings: { _ in }, onImport: {}, onUninstall: { _ in })
                        .toolbar {
                            ToolbarItem(placement: .confirmationAction) {
                                Button(CartoucheText.done) {}
                            }
                        }
                }
            }
        case "settings":
            if let entry = entries.all.first(where: { $0.titleId == scenario.sheet }), let app = entry.app {
                NavigationStack {
                    CartoucheGameSettingsView(model: CartoucheGameActions.shared.settings(for: app, tileKey: entry.tileKey),
                                              onNxnativeScreen: {})
                        .toolbar {
                            ToolbarItem(placement: .confirmationAction) {
                                Button(CartoucheText.done) {}
                            }
                        }
                }
            }
        case "setup":
            NavigationStack {
                CartoucheSetupView()
            }
        default:
            CartoucheGamesView()
        }
    }
}
