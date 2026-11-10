//
//  Gallery.swift
//  Cartouche Builder
//
//  Pictures of the app's pages with sample games, for the Builder workflow
//  and the docs: `Cartouche Builder --gallery FOLDER` saves each page as a
//  PNG, in French in light and dark and in English in light, then ends.
//  Nothing runs: no engine, no check of the Mac, no server, and nothing of
//  the player's is read or kept. The games are real ones nxnative builds,
//  with their covers from IGDB as the app shows them; their folders, sizes
//  and builds are made up, as are the Mac's name and its iPhones. Each page
//  is a window of its own, taken as the window server shows it.
//

import AppKit
import BuilderKit
import CartoucheCore
import ScreenCaptureKit
import SwiftUI

@MainActor
enum Gallery {
    enum Page: String, CaseIterable {
        case library, game, activity, storage, iphone, setup, settings, menubar, menubarBuilding = "menubar-building"
        case assistantWelcome = "assistant-welcome", assistantTools = "assistant-tools", assistantSources = "assistant-sources"
        case assistantGames = "assistant-games", assistantKeys = "assistant-keys", assistantBuilds = "assistant-builds"
        case assistantIPhone = "assistant-iphone", assistantDone = "assistant-done"

        /// The setup assistant's step the page shows.
        var step: SetupStep? {
            switch self {
            case .assistantWelcome: return .welcome
            case .assistantTools: return .tools
            case .assistantSources: return .sources
            case .assistantGames: return .games
            case .assistantKeys: return .keys
            case .assistantBuilds: return .builds
            case .assistantIPhone: return .iphone
            case .assistantDone: return .done
            default: return nil
            }
        }

        var size: CGSize {
            if step != nil { return SetupAssistant.size }
            switch self {
            case .settings: return SettingsTab.size
            case .menubar, .menubarBuilding: return CGSize(width: 330, height: 0)
            default: return CGSize(width: 1220, height: 780)
            }
        }

        var inEnglish: Bool { [.library, .game, .setup, .menubar, .assistantWelcome, .assistantGames].contains(self) }

        /// The window as the app opens it: the settings as the Settings
        /// scene does, the menu bar's panel without a frame, the setup
        /// assistant as the sheet it is, without a title bar.
        var styleMask: NSWindow.StyleMask {
            if step != nil { return [.titled, .fullSizeContentView] }
            switch self {
            case .settings: return [.titled, .closable]
            case .menubar, .menubarBuilding: return [.borderless]
            default: return [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
            }
        }
    }

    /// Pictures AppKit drew itself, as ScreenCaptureKit could not take them.
    private static var drawnByAppKit = 0

    static func run(into folder: URL) {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        app.finishLaunching()
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        // The bridge on and the menu bar item, for this run only.
        UserDefaults.standard.setVolatileDomain([AppSettings.bridgeKey: true, AppSettings.menuBarKey: true], forName: UserDefaults.argumentDomain)
        let samples: Samples
        do {
            samples = try Samples()
        } catch {
            FileHandle.standardError.write(Data("gallery: the samples do not decode: \(error)\n".utf8))
            exit(1)
        }
        loadCovers(samples.library.games.map(\.titleID))
        var saved = 0
        for language in ["fr", "en"] {
            L10n.use(language)
            for page in Page.allCases where language == "fr" || page.inEnglish {
                for dark in language == "fr" ? [false, true] : [false] {
                    let file = folder.appendingPathComponent("\(page.rawValue)-\(language)-\(dark ? "dark" : "light").png")
                    if render(page, samples: samples, dark: dark, to: file) { saved += 1 }
                }
            }
        }
        print("gallery: \(saved) pictures in \(folder.path)"
              + (drawnByAppKit > 0 ? ", \(drawnByAppKit) drawn by AppKit without the window server's effects" : ""))
        exit(saved > 0 ? 0 : 1)
    }

    /// The covers, downloaded before the pages are drawn.
    private static func loadCovers(_ titleIDs: [String]) {
        final class Done { var value = false }
        let done = Done()
        Task { @MainActor in
            for titleID in titleIDs { await CoverStore.shared.load(titleID) }
            done.value = true
        }
        wait(until: Date().addingTimeInterval(60)) { done.value }
    }

    private static func wait(until deadline: Date, _ finished: () -> Bool = { false }) {
        while !finished() && Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
    }

    private static func render(_ page: Page, samples: Samples, dark: Bool, to file: URL) -> Bool {
        let model = samples.model(for: page)
        var size = page.size
        let controller: NSViewController
        switch page {
        case .settings:
            controller = settings(model)
        case .menubar, .menubarBuilding:
            let panel = hosted(MenuBarView().background(Color(nsColor: .windowBackgroundColor)), model)
            size.height = ceil(panel.sizeThatFits(in: CGSize(width: size.width, height: 2000)).height)
            controller = panel
        default:
            if let step = page.step {
                controller = hosted(SetupAssistant(start: step), model, bridged: false)
            } else {
                controller = hosted(ContentView(), model)
            }
        }
        let window = NSWindow(contentRect: CGRect(origin: CGPoint(x: 80, y: 80), size: size),
                              styleMask: page.styleMask, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.title = page == .settings ? SettingsTab.general.title : "Cartouche Builder"
        if page == .settings {
            window.toolbarStyle = .preference
        }
        if page.step != nil {
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
                window.standardWindowButton(button)?.isHidden = true
            }
        }
        window.contentViewController = controller
        window.setContentSize(size)
        window.orderFrontRegardless()
        wait(until: Date().addingTimeInterval(2.5))
        defer {
            window.orderOut(nil)
            window.close()
        }
        var picture = captured(window, for: file)
        if picture == nil {
            drawnByAppKit += 1
            picture = drawn(window)
        }
        guard let data = picture?.representation(using: .png, properties: [:]) else { return false }
        do {
            try data.write(to: file)
            return true
        } catch {
            complain(file, "\(error)")
            return false
        }
    }

    /// A page with the app's models; its toolbar and its title become the
    /// window's, as in the app's window, unless the page is one of a tab
    /// view controller's.
    private static func hosted<Content: View>(_ content: Content, _ model: AppModel, bridged: Bool = true) -> NSHostingController<AnyView> {
        let controller = NSHostingController(rootView: AnyView(content
            .environmentObject(model)
            .environmentObject(model.setup)
            .environmentObject(model.bridge)
            .environmentObject(model.covers)
            .environmentObject(model.updater)
            .environmentObject(model.telemetry)
            .environment(\.locale, L10n.locale)))
        controller.sceneBridgingOptions = bridged ? [.toolbars, .title] : []
        return controller
    }

    /// The settings as the Settings scene shows them, which a TabView in a
    /// window of its own does not: a tab in the middle of the toolbar for
    /// each, the first one open, its name as the window's title.
    private static func settings(_ model: AppModel) -> NSViewController {
        let tabs = NSTabViewController()
        tabs.tabStyle = .toolbar
        for tab in SettingsTab.allCases {
            let page = hosted(tab.content.frame(width: SettingsTab.size.width, height: SettingsTab.size.height), model, bridged: false)
            page.title = tab.title
            let item = NSTabViewItem(viewController: page)
            item.label = tab.title
            item.image = NSImage(systemSymbolName: tab.symbol, accessibilityDescription: tab.title)
            tabs.addTabViewItem(item)
        }
        return tabs
    }

    /// The window as the window server shows it, with what only the window
    /// server draws: the sidebar's selection, the labels over the sidebar,
    /// the glass of the toolbar's buttons. Nil, said on standard error,
    /// when ScreenCaptureKit cannot take it.
    private static func captured(_ window: NSWindow, for file: URL) -> NSBitmapImageRep? {
        final class Capture { var image: CGImage?; var done = false }
        let capture = Capture()
        let number = CGWindowID(window.windowNumber)
        Task { @MainActor in
            defer { capture.done = true }
            do {
                // The app's own windows, which need no permission to record
                // the screen.
                let content = try await SCShareableContent.currentProcess
                guard let shown = content.windows.first(where: { $0.windowID == number }) else {
                    Gallery.complain(file, "ScreenCaptureKit does not list the window")
                    return
                }
                let filter = SCContentFilter(desktopIndependentWindow: shown)
                let configuration = SCStreamConfiguration()
                let scale = CGFloat(filter.pointPixelScale)
                configuration.width = Int((filter.contentRect.width * scale).rounded())
                configuration.height = Int((filter.contentRect.height * scale).rounded())
                configuration.showsCursor = false
                configuration.ignoreShadowsSingleWindow = true
                // All of a window wider than the screen.
                configuration.ignoreGlobalClipSingleWindow = true
                capture.image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
            } catch {
                Gallery.complain(file, "ScreenCaptureKit: \(error.localizedDescription)")
            }
        }
        wait(until: Date().addingTimeInterval(20)) { capture.done }
        return capture.image.map { NSBitmapImageRep(cgImage: $0) }
    }

    /// The window as AppKit draws it, without what the window server adds:
    /// the selection comes out black, and the labels over the sidebar faint.
    private static func drawn(_ window: NSWindow) -> NSBitmapImageRep? {
        guard let drawn = window.contentView?.superview ?? window.contentView else { return nil }
        drawn.layoutSubtreeIfNeeded()
        guard let picture = drawn.bitmapImageRepForCachingDisplay(in: drawn.bounds) else { return nil }
        drawn.cacheDisplay(in: drawn.bounds, to: picture)
        return picture
    }

    private static func complain(_ file: URL, _ message: String) {
        FileHandle.standardError.write(Data("gallery: \(file.lastPathComponent): \(message)\n".utf8))
    }

    // MARK: The samples

    /// The engine's answers for a player with ten games on a NAS: two that
    /// nxnative improved, one that failed, one nxnative has no profile for,
    /// one there is only an IPA of.
    @MainActor
    struct Samples {
        let library: Library
        let building: BatchStatus
        let storage: StorageReport
        let config: BuilderConfig
        let info: BuilderInfo

        init() throws {
            let decoder = JSONDecoder()
            library = try decoder.decode(Library.self, from: Gallery.dated(Gallery.libraryJSON))
            building = try decoder.decode(BatchStatus.self, from: Gallery.dated(Gallery.buildingJSON))
            storage = try decoder.decode(StorageReport.self, from: Gallery.dated(Gallery.storageJSON))
            config = try decoder.decode(BuilderConfig.self, from: Data(Gallery.configJSON.utf8))
            info = try decoder.decode(BuilderInfo.self, from: Data(Gallery.infoJSON.utf8))
        }

        func model(for page: Page) -> AppModel {
            let building = page == .activity || page == .menubarBuilding
            let model = AppModel.sampled(library: library, status: building ? self.building : nil, storage: storage, config: config, info: info)
            switch page {
            case .library, .activity, .storage, .iphone: model.section = AppSection(rawValue: page.rawValue) ?? .library
            case .game: model.section = .library
            case .setup: model.section = .setup
            default: break
            }
            if page == .game { model.selection = "0100152000022000" }
            if page == .setup || page == .assistantTools {
                model.setup.preview([
                    .mac: .ready("macOS 26.1"),
                    .xcode: .ready("Xcode 27.2"),
                    .xcodeReady: .ready(""),
                    .iosPlatform: .ready("iOS 27.2"),
                    .metal: .working(tr("Downloading the Metal toolchain…", "Téléchargement de la Metal toolchain…"), 0.42),
                    .homebrew: .ready("Homebrew 5.0.4"),
                    .tools: .missing(tr("Missing: zstd, glslang.", "Manque : zstd, glslang.")),
                    .nxnative: .blocked,
                ], xcode: "/Applications/Xcode-27.2.app")
            } else {
                model.setup.preview([
                    .mac: .ready("macOS 26.1"),
                    .xcode: .ready("Xcode 27.2"),
                    .iosPlatform: .ready("iOS 27.2"),
                    .homebrew: .ready("Homebrew 5.0.4"),
                    .tools: .ready("Python 3.13, XcodeGen, zstd, glslang"),
                    .nxnative: .ready("6c3aeb3"),
                ], xcode: "/Applications/Xcode-27.2.app")
            }
            let now = Date()
            let iphones = [
                PairedDevice(id: "5D1C9A70-3E1B-4A7C-9D51-2F0E6B8A4C13", name: "iPhone 17 Pro", key: Data(repeating: 7, count: 32),
                             paired: now.addingTimeInterval(-6 * 86_400), seen: now.addingTimeInterval(-90)),
                PairedDevice(id: "A0F4E2B6-81C3-4D9E-B7A5-6C2D1E3F4A5B", name: "iPhone Duo", key: Data(repeating: 9, count: 32),
                             paired: now.addingTimeInterval(-2 * 86_400), seen: now.addingTimeInterval(-26 * 3600)),
            ]
            model.bridge.preview(devices: iphones, connected: [iphones[0].id], games: config.games,
                                 name: "MacBook Air", saves: URL(fileURLWithPath: info.home).appendingPathComponent("Saves", isDirectory: true))
            if page == .menubar {
                let release = BuilderRelease(version: "0.3.0", tag: "builder-v0.3.0", notes: "",
                                             page: URL(string: "https://github.com/clabeuhtegrite/Cartouche/releases/tag/builder-v0.3.0")!,
                                             image: URL(string: "https://github.com/clabeuhtegrite/Cartouche/releases/download/builder-v0.3.0/Cartouche-Builder-0.3.0.dmg")!,
                                             checksum: URL(string: "https://github.com/clabeuhtegrite/Cartouche/releases/download/builder-v0.3.0/Cartouche-Builder-0.3.0.dmg.sha256")!,
                                             size: 31_000_000)
                model.updater.preview(.ready(release))
            } else {
                model.updater.preview(.upToDate)
            }
            return model
        }
    }

    /// JSON whose "@-SECONDS" are dates and "#-SECONDS" times, that many
    /// seconds ago.
    static func dated(_ text: String, now: Date = Date()) -> Data {
        let expression = try! NSRegularExpression(pattern: "\"([@#])(-?[0-9]+)\"")
        let source = text as NSString
        let formatter = ISO8601DateFormatter()
        var result = ""
        var last = 0
        for match in expression.matches(in: text, range: NSRange(location: 0, length: source.length)) {
            result += source.substring(with: NSRange(location: last, length: match.range.location - last))
            let date = now.addingTimeInterval(Double(source.substring(with: match.range(at: 2))) ?? 0)
            result += source.substring(with: match.range(at: 1)) == "@"
                ? "\"\(formatter.string(from: date))\""
                : String(Int(date.timeIntervalSince1970))
            last = match.range.location + match.range.length
        }
        result += source.substring(from: last)
        return Data(result.utf8)
    }

    static let head = "6c3aeb3d70a1c2b94f5e8d7a6b5c4d3e2f1a0b9c"

    static let libraryJSON = """
    {
      "checked": "@-5400",
      "language": "fr",
      "folders": {
        "sources": {"path": "/Volumes/Jeux/Switch", "present": true, "share": "smb://nas.local/Jeux", "mounted": true},
        "games": {"path": "/Volumes/Jeux/iPhone", "present": true, "share": "smb://nas.local/Jeux", "mounted": true},
        "keys": {"path": "/Users/player/Switch/prod.keys", "present": true},
        "remote": true
      },
      "engine": {"head": "\(head)", "short": "6c3aeb3", "time": "#-10800", "subject": "Kirby: water reflections without the black frames",
                 "url": "https://github.com/seedds/nxnative", "branch": "main", "commit_url": "https://github.com/seedds/nxnative/commit/\(head)"},
      "games": [
        {"title_id": "0100152000022000", "name": "Mario Kart 8 Deluxe", "kind": "nup", "source": "/Volumes/Jeux/Switch/Mario Kart 8 Deluxe",
         "source_size": 7340032000, "followed": true, "profile": true, "state": "due", "due": true, "reasons": ["profile", "shared"],
         "ipa": {"name": "Mario Kart 8 Deluxe.ipa", "path": "/Volumes/Jeux/iPhone/Mario Kart 8 Deluxe.ipa", "size": 6410000000, "present": true},
         "build": {"commit": "4f1d2c9a7b3e", "built_at": "@-777600", "version": "3.0.3", "duration": 1260, "origin": "app", "toolchain": "27.2", "size": 6410000000},
         "changes": [
           {"sha": "e2a94c1b7d6f5a3b2c1d0e9f8a7b6c5d4e3f2a1b", "short": "e2a94c1", "subject": "mk8dx: lighter kart shadows, 60 fps in the menus", "time": "#-14400", "kind": "profile"},
           {"sha": "b81e2f4a9c7d6e5f4a3b2c1d0e9f8a7b6c5d4e3f", "short": "b81e2f4", "subject": "mk8dx: no more flicker on the last track", "time": "#-190000", "kind": "profile"},
           {"sha": "9d2c7a1e8b6f5c4d3e2a1b0c9f8e7d6a5b4c3d2e", "short": "9d2c7a1", "subject": "Shader cache: compile the pipelines in parallel", "time": "#-260000", "kind": "shared"},
           {"sha": "7c1b0a9f8e7d6c5b4a3f2e1d0c9b8a7f6e5d4c3b", "short": "7c1b0a9", "subject": "Audio: fewer underruns when the iPhone is busy", "time": "#-430000", "kind": "shared"}
         ],
         "change_counts": {"profile": 2, "named": 0, "shared": 4}},
        {"title_id": "01004D300C5AE000", "name": "Kirby and the Forgotten Land", "kind": "dump", "source": "/Volumes/Jeux/Switch/Kirby",
         "source_size": 6012000000, "followed": true, "profile": true, "state": "due", "due": true, "reasons": ["named"],
         "ipa": {"name": "Kirby and the Forgotten Land.ipa", "path": "/Volumes/Jeux/iPhone/Kirby and the Forgotten Land.ipa", "size": 5480000000, "present": true},
         "build": {"commit": "4f1d2c9a7b3e", "built_at": "@-777600", "version": "1.0.0", "duration": 980, "origin": "app", "toolchain": "27.2", "size": 5480000000},
         "changes": [
           {"sha": "\(head)", "short": "6c3aeb3", "subject": "Kirby: water reflections without the black frames", "time": "#-10800", "kind": "named"}
         ],
         "change_counts": {"profile": 0, "named": 1, "shared": 4}},
        {"title_id": "010093801237C000", "name": "Metroid Dread", "kind": "nup", "source": "/Volumes/Jeux/Switch/Metroid Dread",
         "source_size": 4510000000, "followed": true, "profile": true, "state": "failed", "reasons": ["shared"],
         "attempt": {"commit": "6c3aeb3d70a1", "at": "@-9000", "result": "failed", "error": "Les shaders n’ont pas compilé : pipeline 1187.", "log": "/tmp/metroid.log"},
         "ipa": {"name": "Metroid Dread.ipa", "path": "/Volumes/Jeux/iPhone/Metroid Dread.ipa", "size": 4120000000, "present": true},
         "build": {"commit": "a3b2c1d0e9f8", "built_at": "@-1900000", "version": "2.1.0", "duration": 840, "origin": "app", "toolchain": "27.2", "size": 4120000000},
         "change_counts": {"profile": 0, "named": 0, "shared": 6}},
        {"title_id": "0100000000010000", "name": "Super Mario Odyssey", "kind": "zip", "source": "/Volumes/Jeux/Switch/Super Mario Odyssey.zip",
         "source_size": 5650000000, "followed": true, "profile": true, "state": "up_to_date",
         "ipa": {"name": "Super Mario Odyssey.ipa", "path": "/Volumes/Jeux/iPhone/Super Mario Odyssey.ipa", "size": 5320000000, "present": true},
         "build": {"commit": "\(head)", "built_at": "@-7000", "version": "1.3.0", "duration": 1130, "origin": "app", "toolchain": "27.2", "size": 5320000000}},
        {"title_id": "01007EF00011E000", "name": "The Legend of Zelda: Breath of the Wild", "kind": "nup", "source": "/Volumes/Jeux/Switch/Zelda BotW",
         "source_size": 16200000000, "followed": true, "profile": true, "state": "up_to_date",
         "ipa": {"name": "Zelda BotW.ipa", "path": "/Volumes/Jeux/iPhone/Zelda BotW.ipa", "size": 15100000000, "present": true},
         "build": {"commit": "\(head)", "built_at": "@-6400", "version": "1.6.0", "duration": 2410, "origin": "app", "toolchain": "27.2", "size": 15100000000}},
        {"title_id": "01006F8002326000", "name": "Animal Crossing: New Horizons", "kind": "nup", "source": "/Volumes/Jeux/Switch/Animal Crossing",
         "source_size": 10500000000, "followed": true, "profile": true, "state": "up_to_date",
         "ipa": {"name": "Animal Crossing.ipa", "path": "/Volumes/Jeux/iPhone/Animal Crossing.ipa", "size": 9800000000, "present": true},
         "build": {"commit": "\(head)", "built_at": "@-90000", "version": "2.0.6", "duration": 1500, "origin": "app", "toolchain": "27.2", "size": 9800000000}},
        {"title_id": "01006A800016E000", "name": "Super Smash Bros. Ultimate", "kind": "nup", "source": "/Volumes/Jeux/Switch/Smash",
         "source_size": 16900000000, "followed": true, "profile": true, "state": "up_to_date",
         "ipa": {"name": "Smash.ipa", "path": "/Volumes/Jeux/iPhone/Smash.ipa", "size": 15700000000, "present": true},
         "build": {"commit": "\(head)", "built_at": "@-95000", "version": "13.0.3", "duration": 2700, "origin": "app", "toolchain": "27.2", "size": 15700000000}},
        {"title_id": "010028600EBDA000", "name": "Super Mario 3D World + Bowser’s Fury", "kind": "nup", "source": "/Volumes/Jeux/Switch/3D World",
         "source_size": 2900000000, "followed": false, "profile": true, "state": "not_followed",
         "ipa": {"name": "3D World.ipa", "path": "/Volumes/Jeux/iPhone/3D World.ipa", "size": 2700000000, "present": true},
         "build": {"commit": "a3b2c1d0e9f8", "built_at": "@-2600000", "version": "1.1.0", "duration": 700, "origin": "app", "toolchain": "27.2", "size": 2700000000}},
        {"title_id": "010074F013262000", "name": "Xenoblade Chronicles 3", "kind": "nup", "source": "/Volumes/Jeux/Switch/Xenoblade 3",
         "source_size": 15100000000, "followed": true, "profile": false, "state": "no_profile"},
        {"title_id": "01001F5010DFA000", "name": "Pokémon Legends: Arceus", "kind": "ipa", "followed": true, "state": "no_source",
         "ipa": {"name": "Pokemon Legends Arceus.ipa", "path": "/Volumes/Jeux/iPhone/Pokemon Legends Arceus.ipa", "size": 6900000000, "present": true}}
      ]
    }
    """

    static let buildingJSON = """
    {
      "pid": 4242, "scheduled": false, "state": "building", "started": "@-1500", "updated": "@-1", "head": "\(head)", "running": true,
      "games": [
        {"title_id": "01004D300C5AE000", "name": "Kirby and the Forgotten Land", "reasons": ["named"], "state": "built",
         "started": "@-1500", "ended": "@-610", "duration": 890, "ipa": "/Volumes/Jeux/iPhone/Kirby and the Forgotten Land.ipa"},
        {"title_id": "0100152000022000", "name": "Mario Kart 8 Deluxe", "reasons": ["profile", "shared"], "state": "building", "stage": "shaders",
         "step": "Pipelines 1 412 / 2 300", "k": 1412, "n": 2300, "frac": 0.61, "overall": 0.68, "eta": 380, "started": "@-600"},
        {"title_id": "010093801237C000", "name": "Metroid Dread", "reasons": ["shared"], "state": "queued"}
      ],
      "lines": [
        "Kirby and the Forgotten Land: IPA copied to the games folder (5.5 GB)",
        "Mario Kart 8 Deluxe: extracted",
        "Mario Kart 8 Deluxe: shaders 1412/2300"
      ]
    }
    """

    static let storageJSON = """
    {
      "workspace": "/Users/player/Library/Application Support/Cartouche Builder/Builds",
      "disks": {
        "workspace": {"path": "/", "free": 182000000000, "total": 994000000000, "present": true},
        "games": {"path": "/Volumes/Jeux", "free": 2310000000000, "total": 7990000000000, "present": true}
      },
      "folders": [
        {"path": "/Builds/0100152000022000", "workspace": "/Builds", "title_id": "0100152000022000", "name": "Mario Kart 8 Deluxe", "kind": "build",
         "size": 2140000000, "parts": {"shaders": 1310000000, "app": 830000000}, "used": "#-777600"},
        {"path": "/Builds/01007EF00011E000", "workspace": "/Builds", "title_id": "01007EF00011E000", "name": "The Legend of Zelda: Breath of the Wild", "kind": "build",
         "size": 15600000000, "parts": {"extracted": 13900000000, "shaders": 1100000000, "app": 600000000}, "used": "#-6400"},
        {"path": "/Builds/0100000000010000", "workspace": "/Builds", "title_id": "0100000000010000", "name": "Super Mario Odyssey", "kind": "build",
         "size": 1650000000, "parts": {"shaders": 1020000000, "app": 630000000}, "used": "#-7000"},
        {"path": "/Builds/01006A800016E000", "workspace": "/Builds", "title_id": "01006A800016E000", "name": "Super Smash Bros. Ultimate", "kind": "build",
         "size": 1270000000, "parts": {"shaders": 640000000, "app": 630000000}, "used": "#-95000"}
      ],
      "ipa_copies": [],
      "totals": {"extracted": 13900000000, "shaders": 4070000000, "app": 2690000000, "packages": 0, "temporary": 0, "other": 120000000,
                 "logs": 48000000, "ipa_copies": 0, "ipa_copies_freeable": 0, "engine": 410000000, "python": 260000000},
      "settings": {"keep_extracted": false, "keep_ipa": false, "min_free_gb": 20, "workspace_limit_gb": 0}
    }
    """

    static let configJSON = """
    {"sources": "/Volumes/Jeux/Switch", "games": "/Volumes/Jeux/iPhone", "keys": "/Users/player/Switch/prod.keys", "language": "fr",
     "schedule": true, "schedule_hour": 3, "schedule_minute": 30, "jobs": 1, "engine_policy": "weekly", "refresh_days": 7, "min_free_gb": 20}
    """

    static let infoJSON = """
    {"version": "0.2.0", "home": "/Users/player/Library/Application Support/Cartouche Builder",
     "workspace": "/Users/player/Library/Application Support/Cartouche Builder/Builds", "python": "/opt/homebrew/bin/python3.13", "scheduled": true}
    """
}
