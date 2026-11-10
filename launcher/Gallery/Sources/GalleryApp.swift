//
//  GalleryApp.swift
//  CartoucheGallery
//
//  Shows one scenario of scenarios.json, which capture.sh passes as launch
//  arguments: a launcher screen at the scenario's size, in the top left
//  corner of the screen, with that iPhone's safe area; or, without a size,
//  the whole screen of the simulator it runs on, such as the iPhone Duo's,
//  with its own safe area, size classes and system bars.
//
//      -GalleryScreen games|library|sheet|settings|setup|signin|system|storage
//      -GalleryWidth 402 -GalleryHeight 874     (none: the whole screen)
//      -GalleryInsets 62,0,34,0          top, leading, bottom, trailing
//      -GalleryWidthClass compact        the width class at a scenario's
//                                        size, where iOS gives another one
//                                        than its width says: an iPhone 17
//                                        Pro sideways is compact
//      -GalleryOwned 0400C3F00006E000,…  the player's games
//      -GallerySetup 1 -GalleryController 1
//      -GallerySheet <title ID>          the game of the sheet, of its
//                                        settings, or being installed
//      -GalleryWork installing           a game being installed, over the
//                                        console; update: a new version of
//                                        Cartouche on offer; code: Apple
//                                        asks for a verification code, on
//                                        the sign-in; paused: the sheet's
//                                        game, or the first of the
//                                        player's, paused behind the console
//      -GalleryOrientation landscape     the gallery turns itself sideways,
//                                        as a game does; the simulator
//                                        stays upright
//      -GalleryReady <scenario>          once the screen has settled, the
//                                        gallery writes
//                                        tmp/ready-<scenario>.json in its
//                                        container (Ready below)
//      -GalleryCategory Controls         the settings page's category, one
//                                        of nxnative's sections
//

import SwiftUI
import UIKit

struct GalleryScenario {
    var screen = "games"
    /// nil: the whole screen of the simulator.
    var size: CGSize?
    var insets = EdgeInsets()
    /// nil: regular from 600 points wide, as an unfolded Duo is.
    var widthClass: UserInterfaceSizeClass?
    var owned: [String] = []
    var setupDone = false
    var controller = false
    var sheet: String?
    var work: String?
    var landscape = false
    /// The name of the file that says the screen has settled.
    var ready: String?
    var category: String?

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
        switch defaults.string(forKey: "GalleryWidthClass") {
        case "compact": scenario.widthClass = .compact
        case "regular": scenario.widthClass = .regular
        default: break
        }
        scenario.owned = (defaults.string(forKey: "GalleryOwned") ?? "").split(separator: ",").map(String.init)
        scenario.setupDone = defaults.bool(forKey: "GallerySetup")
        scenario.controller = defaults.bool(forKey: "GalleryController")
        scenario.sheet = defaults.string(forKey: "GallerySheet")
        scenario.work = defaults.string(forKey: "GalleryWork")
        scenario.landscape = defaults.string(forKey: "GalleryOrientation") == "landscape"
        scenario.ready = defaults.string(forKey: "GalleryReady")
        scenario.category = defaults.string(forKey: "GalleryCategory")
        return scenario
    }

    /// Puts the files the stand-ins read where the launcher looks for them.
    func prepare() {
        GalleryState.setupDone = setupDone
        GalleryState.certificateRefused = work == "certificate"
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
            if work == "install-failed" {
                // An install the network dropped halfway, with its report.
                let name = sheet.flatMap { CartoucheCatalog.shared.game(titleId: $0)?.name } ?? "Game"
                let error = URLError(.networkConnectionLost)
                let report = CartoucheReports.make(.install, CartoucheText.installFailed, message: error.localizedDescription,
                                                   error: error, step: CartoucheText.installTitle(name) + ": " + CartoucheText.installUnpacking,
                                                   fraction: 0.42, facts: [.init("IPA", name + " [" + (sheet ?? "") + "].ipa")])
                CartoucheGameActions.shared.notice = CartoucheGameNotice(title: report.title, message: report.message, report: report)
            }
            if work == "update" {
                // A higher version than the gallery's own (project.yml).
                CartoucheUpdates.shared.offerForGallery(CartoucheRelease(version: "0.4.0", notes: "", size: 36_802_806))
            }
            if work == "code" {
                CartoucheAccount.shared.requestCodeForGallery(.init(
                    id: "gallery", mode: .sms, phone: "+33 •• •• •• •• 78", canTextMessage: false, error: nil))
            }
            if work == "newer-build", let titleId = updatedTitle, let game = CartoucheCatalog.shared.game(titleId: titleId) {
                // Cartouche Builder built the game again last night.
                let stored = CartoucheStoredGame(
                    path: "/Jeux/\(game.name) [\(titleId)].ipa", size: 21_474_836_480, modified: Date().addingTimeInterval(-5 * 3_600),
                    bundleId: "org.nxnative." + titleId.lowercased(), displayName: game.name, version: "1.0.0",
                    build: CartoucheGameBuild(version: "1.0.0", commit: "7bddb8c1e2f3", chain: "adec7d81d970",
                                              builtAt: Date().addingTimeInterval(-5 * 3_600 - 120)),
                    titleId: titleId, isGame: true)
                CartoucheStoredGames.shared.showForGallery([stored], server: "NAS")
            }
        }
    }

    /// The game a newer build is in the games folder of (work: newer-build):
    /// the sheet's, or the first of the player's.
    private var updatedTitle: String? { work == "newer-build" ? sheet ?? owned.first : nil }

    /// The sheet's game, or the first of the player's, paused behind the
    /// console (work: paused).
    @MainActor
    func pause(among apps: [LCAppModel]) {
        guard work == "paused", let titleId = sheet ?? owned.first,
              let app = apps.first(where: { $0.appInfo.relativeBundlePath == titleId + ".app" }) else { return }
        CartoucheGameActions.shared.showRunningForGallery(app)
    }

    /// What capture.sh needs to cut the screen out of the simulator's
    /// screenshot, or to turn it the right way up (screenshot.swift).
    struct Ready: Encodable {
        let scale: Double
        /// The size of the window's screen in pixels, upright: on a simulator
        /// with more than one display, such as the iPhone Duo with its outer
        /// and inner ones, capture.sh takes the display of this size.
        let pixels: [Double]
        /// The window's top left corner on the screen, in points.
        let origin: [Double]
        let window: [Double]
        let orientation: String
    }

    /// Turns the gallery sideways if the scenario asks, then, once the
    /// layout, the stage's colours and the cartridges have settled, says so.
    @MainActor
    func settle() {
        let scene = UIApplication.shared.connectedScenes.lazy.compactMap { $0 as? UIWindowScene }.first
        if landscape, let scene {
            scene.requestGeometryUpdate(.iOS(interfaceOrientations: .landscapeRight)) { error in
                NSLog("[Gallery] cannot turn sideways: %@", String(describing: error))
            }
        }
        guard let ready else { return }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(3))
            // The covers the screen shows, from IGDB, for up to 20 s more.
            for _ in 0..<40 {
                let pending = await CartoucheCoverStore.shared.pending
                if pending == 0 { break }
                try? await Task.sleep(for: .milliseconds(500))
            }
            guard let scene, let window = scene.windows.first else {
                NSLog("[Gallery] no window to measure")
                return
            }
            let frame = window.convert(window.bounds, to: scene.screen.coordinateSpace)
            let orientation = switch scene.effectiveGeometry.interfaceOrientation {
            case .landscapeLeft: "landscapeLeft"
            case .landscapeRight: "landscapeRight"
            case .portraitUpsideDown: "portraitUpsideDown"
            default: "portrait"
            }
            let pixels = scene.screen.nativeBounds.size
            let report = Ready(scale: Double(scene.screen.scale),
                               pixels: [Double(pixels.width), Double(pixels.height)],
                               origin: [Double(frame.minX), Double(frame.minY)],
                               window: [Double(frame.width), Double(frame.height)],
                               orientation: orientation)
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("ready-\(ready).json")
            do {
                try JSONEncoder().encode(report).write(to: url, options: .atomic)
            } catch {
                NSLog("[Gallery] cannot write %@: %@", url.path, String(describing: error))
            }
        }
    }

    func apps() -> [LCAppModel] {
        owned.compactMap { titleId in
            guard let game = CartoucheCatalog.shared.game(titleId: titleId) else { return nil }
            let info = LCAppInfo(name: game.name, identifier: "org.nxnative." + titleId.lowercased(),
                                 folder: titleId + ".app", icon: GalleryIcon.make(name: game.name, key: titleId))
            if titleId == updatedTitle {
                // Installed four days ago, from an older commit of nxnative.
                info.infoPlist = NSMutableDictionary(dictionary: ["CFBundleShortVersionString": "1.0.0", "DMCommit": "52124866a1b2",
                                                                  "DMChain": "844bf1a5ea8f"])
                info.installationDate = Date().addingTimeInterval(-4 * 86_400)
            }
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
                .onAppear {
                    model.apps = scenario.apps()
                    scenario.pause(among: model.apps)
                    scenario.settle()
                }
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
            .environment(\.horizontalSizeClass, scenario.widthClass ?? (size.width >= 600 ? .regular : .compact))
            .environment(\.verticalSizeClass, size.height >= 600 ? .regular : .compact)
            .statusBarHidden()
            .persistentSystemOverlays(.hidden)
        } else {
            screen
        }
    }

    @ViewBuilder
    private var screen: some View {
        let entries = CartoucheCatalog.shared.entries(for: model.apps, stored: CartoucheStoredGames.shared.games)
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
                    CartoucheGameSettingsView(model: settings(for: app, entry: entry), onNxnativeScreen: {})
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
        case "signin":
            CartoucheSignInView()
        case "system":
            CartoucheSystemView()
        case "storage":
            NavigationStack {
                CartoucheStorageView()
            }
        default:
            CartoucheGamesView()
        }
    }

    /// The game's settings, on the scenario's category.
    private func settings(for app: LCAppModel, entry: CartoucheEntry) -> CartoucheGameSettingsModel {
        let settings = CartoucheGameActions.shared.settings(for: app, tileKey: entry.tileKey)
        settings.category = scenario.category
        return settings
    }
}
