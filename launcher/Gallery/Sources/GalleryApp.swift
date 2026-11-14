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
//      -GalleryScreen games|library|sheet|settings|gameinfo|shortcuts|setup|signin|guide|system|storage|storage-mac|storage-drive|storage-drive-guide|telemetry|report|tv
//                                        library: every game, open over
//                                        the home; gameinfo: what the
//                                        player says of the sheet's game;
//                                        shortcuts: Siri and Home Screen,
//                                        from the sheet of the player's game;
//                                        storage-mac: Add your Mac, the
//                                        form that pairs this iPhone with a
//                                        Mac nearby; storage-drive: Add
//                                        Google Drive, with the player's
//                                        own client; storage-drive-guide:
//                                        the steps that make that client;
//                                        tv: the TV while the sheet's game,
//                                        or the first of the player's, runs
//                                        behind the console, its card where
//                                        the game leaves its own scene on
//                                        the TV empty (CartoucheTV.swift)
//      -GalleryWidth 402 -GalleryHeight 874     (none: the whole screen)
//      -GalleryInsets 62,0,34,0          top, leading, bottom, trailing
//      -GalleryWidthClass compact        the width class at a scenario's
//                                        size, where iOS gives another one
//                                        than its width says: an iPhone 17
//                                        Pro sideways is compact
//      -GalleryOwned 0400C3F00006E000,…  the player's games; TITLEID:Name
//                                        for one nxnative.json does not
//                                        have, which IGDB has by its name
//                                        when the catalogue has a game of
//                                        that name (showFound)
//      -GallerySetup 1 -GalleryController 1
//      -GalleryModel iPad15,3            the device of catalog/devices.json
//                                        the screen is drawn as, whose words
//                                        call an iPad the iPad (none: the
//                                        iPhone, iPhone19,4, CartoucheDevice)
//      -GallerySheet <title ID>          the game of the sheet, of its
//                                        settings, or being installed
//      -GalleryWork installing           a game being installed, over the
//                                        console; update: a new version of
//                                        Cartouche on offer; code: Apple
//                                        asks for a verification code, on
//                                        the sign-in; too-many: Apple
//                                        refused the sign-in for too many
//                                        requests, with the wait under
//                                        way; vpn-wait: the sign-in waiting
//                                        for LocalDevVPN; iphone-step: a
//                                        sign-in Apple accepted that
//                                        stopped at the step that registers
//                                        this iPhone, LocalDevVPN being
//                                        off; device-no-ipsec,
//                                        device-handshake,
//                                        device-port-closed: a sign-in that
//                                        stopped at the check of this
//                                        iPhone, which minimuxer could not
//                                        reach, LocalDevVPN connected
//                                        (deviceChecks); paused: the sheet's
//                                        game, or the first of the
//                                        player's, paused behind the console;
//                                        offline: the player's NAS, out of
//                                        reach, with a newer build of that
//                                        game in its games folder and two
//                                        games' saves waiting for it;
//                                        mac-nearby: two Macs nearby whose
//                                        Cartouche Builder shares with
//                                        Cartouche; mac-code: the same,
//                                        pairing with the first, with the
//                                        six digits on both screens;
//                                        mac-refused: none, iOS refusing
//                                        Cartouche the local network; mac:
//                                        the player's Mac, paired, as the
//                                        games folder and the saves folder;
//                                        mac-offline: that Mac out of reach,
//                                        away from home, with two games'
//                                        saves waiting for it; build-skipped:
//                                        No thanks said to the guide's Mac
//                                        step; own-cover: the sheet's game,
//                                        or the first of the player's, with
//                                        a cover of the player's own; saves:
//                                        that game's saves, and a folder in
//                                        Files as the saves folder, which
//                                        Cartouche's own sync uses
//                                        (GallerySaves); drive-signed-out:
//                                        the player's Google Drive as the
//                                        games folder and the saves folder,
//                                        whose sign-in Google ended, as after
//                                        7 days for a project in testing, with
//                                        two games' saves waiting for it;
//                                        on the TV (screen tv), paused: the
//                                        game paused behind the console,
//                                        starting: the game starting
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
//  The UI tests (launcher/Gallery/UITests) open the whole console, as
//  Cartouche shows it, and drive it (GalleryTesting.swift):
//
//      -GalleryScreen root               the console with the System page
//                                        over it, as Cartouche's root view
//      -GalleryTest 1                    a clean start, the IPA the Files
//                                        picker offers, and the watch on
//                                        the main thread
//      -GalleryPairing 1                 the pairing file without the rest
//                                        of the setup, to sign in
//      -GalleryHoldMainThread 1.5        the main thread held once, for
//                                        that many seconds, which the
//                                        watch must see
//      -GalleryKeyboard 1                for a test that types: the
//                                        keyboard shown and put away once,
//                                        before the watch counts
//      -GalleryShortcut <title ID>       Siri asks for that game as the
//                                        gallery opens, before its console
//                                        shows
//      -GalleryShortcutOnPost <title ID> Siri asks for that game each time
//                                        a test posts GalleryShortcut.posted
//      -GalleryTestName <name>           the test's, which the watch writes
//                                        down as the gallery starts
//

import Network
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

    /// The title IDs of the player's games.
    var ownedTitles: [String] { owned.map { item in String(item.prefix { $0 != ":" }) } }

    /// The checks of this iPhone that minimuxer failed, LocalDevVPN
    /// connected, by work: SideStore's
    /// kind of error, minimuxer's reason and the library's words behind it,
    /// the kind of pairing file minimuxer loaded (app/patches/sidestore/0022)
    /// and minimuxer's sentence.
    static let deviceChecks: [String: (kind: String, reason: String, detail: String?, pairingKind: String, sentence: String)] = [
        // A Lockdown pairing file, from iOS 26.4, without an IPsec interface.
        "device-no-ipsec": ("invalidVPN", "noIPsec", nil, "lockdown",
                            "utun is present but no ipsec/IKEv2 interface found — LocalDevVPN may not support the lockdown protocol on iOS 26.4+"),
        // A pairing file this iPhone refused at the handshake.
        "device-handshake": ("invalidPairingFile", "handshake", "reset", "rppairing",
                             "Handshake failed: Connection reset by peer (os error 54)"),
        // The tunnel up, and this iPhone not answering on its port.
        "device-port-closed": ("invalidVPN", "portClosed", nil, "rppairing",
                               "VPN tunnel iface is up and tunnel peer IP 10.7.0.1 is known, but TCP port poll failed — device may be unreachable on this interface"),
    ]

    /// The player's games that nxnative.json does not have: title ID and
    /// name.
    var unknownGames: [(titleId: String, name: String)] {
        owned.compactMap { item in
            guard let colon = item.firstIndex(of: ":") else { return nil }
            return (String(item[..<colon]), String(item[item.index(after: colon)...]))
        }
    }

    /// The name of the player's game of TITLEID.
    func name(of titleId: String) -> String? {
        unknownGames.first { $0.titleId == titleId }?.name ?? CartoucheCatalog.shared.game(titleId: titleId)?.name
    }

    /// Puts the files the stand-ins read where the launcher looks for them.
    func prepare() {
        GalleryState.setupDone = setupDone
        GalleryState.certificateRefused = work == "certificate"
        GalleryState.signInUnfinished = work == "sign-in-unfinished"
        GalleryState.vpnConnected = work.map { Self.deviceChecks[$0] != nil } ?? false
        let pairing = GalleryState.documents.appendingPathComponent("SideStore/Documents", isDirectory: true)
        try? FileManager.default.removeItem(at: pairing)
        if setupDone || GalleryState.signInUnfinished {
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
            CartoucheGuide.shared.startOverForGallery()
            if work == "build-skipped" { CartoucheGuide.shared.skipBuild() }
            if controller { CartoucheGamepad.shared.showHints() }
            showStats()
            showFound()
            if work == "own-cover", let titleId = sheet ?? ownedTitles.first {
                showOwnCover(of: titleId)
            }
            if work == "installing" {
                let name = sheet.flatMap { CartoucheCatalog.shared.game(titleId: $0)?.name } ?? "Game"
                // As from iOS 26, which goes on with it outside Cartouche.
                CartoucheGameActions.shared.work = CartoucheGameWork(kind: .installing, name: name,
                                                                     step: CartoucheText.installUnpacking, fraction: 0.42,
                                                                     outside: true)
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
            if work == "too-many" {
                CartoucheAccount.shared.showTooManyRequestsForGallery()
            }
            if work == "vpn-wait" {
                CartoucheAccount.shared.waitForVPNForGallery()
            }
            if work == "iphone-step" {
                CartoucheAccount.shared.showDeviceStepForGallery()
            }
            if let check = work.flatMap({ Self.deviceChecks[$0] }) {
                CartoucheAccount.shared.showDeviceCheckForGallery(kind: check.kind, reason: check.reason, detail: check.detail,
                                                                  pairingKind: check.pairingKind, sentence: check.sentence)
            }
            if work == "sign-in-unfinished" {
                CartoucheAccount.shared.showUnfinishedForGallery()
            }
            if let titleId = updatedTitle, let game = CartoucheCatalog.shared.game(titleId: titleId) {
                // Cartouche Builder built the game again last night.
                let stored = CartoucheStoredGame(
                    path: "/Jeux/\(game.name) [\(titleId)].ipa", size: 21_474_836_480, modified: Date().addingTimeInterval(-5 * 3_600),
                    bundleId: "org.nxnative." + titleId.lowercased(), displayName: game.name, version: "1.0.0",
                    build: CartoucheGameBuild(version: "1.0.0", commit: "7bddb8c1e2f3", chain: "adec7d81d970",
                                              builtAt: Date().addingTimeInterval(-5 * 3_600 - 120)),
                    titleId: titleId, isGame: true)
                CartoucheStoredGames.shared.showForGallery([stored], server: "NAS")
            }
            if work == "offline" {
                // Away from home: the NAS does not answer, and the saves of
                // two games wait for it.
                let nas = CartoucheStorageServer(kind: .smb, name: "NAS", host: "nas.local", username: "joueur", share: "Partage")
                CartoucheStorageSettings.shared.showForGallery(nas, games: "Jeux", saves: "Sauvegardes")
                CartoucheStorageReach.shared.showOfflineForGallery([nas.id])
                CartoucheSaveBackups.shared.showWaitingForGallery(2)
            }
            if ["mac-nearby", "mac-code", "mac-refused"].contains(work) {
                let refused = work == "mac-refused"
                CartoucheMacBrowser.gallery = (found: refused ? [] : GalleryMac.nearby, refused: refused)
                if work == "mac-code" {
                    CartoucheMacPairing.gallery = (mac: GalleryMac.nearby[0], code: "482915")
                }
            }
            if work == "saves", let titleId = sheet ?? ownedTitles.first {
                GallerySaves.prepare(titleId: titleId)
            }
            if work == "mac" || work == "mac-offline" {
                // The player's Mac, paired, with the games Cartouche Builder
                // built in its Games folder; offline, away from home, the
                // saves of two games wait for it.
                let mac = GalleryMac.paired()
                CartoucheStorageSettings.shared.showForGallery(mac, games: CartoucheBridge.gamesFolder,
                                                               saves: CartoucheBridge.savesFolder)
                CartoucheStoredGames.shared.showForGallery(storedGames(in: CartoucheBridge.gamesFolder), server: mac.name)
                if work == "mac-offline" {
                    CartoucheStorageReach.shared.showOfflineForGallery([mac.id])
                    CartoucheSaveBackups.shared.showWaitingForGallery(2)
                }
            }
            if work == "drive-signed-out" {
                // The player's Google Drive, seven days after the sign-in:
                // Google ended it, and the saves of two games wait for it.
                let drive = CartoucheStorageServer(kind: .drive, name: "Google Drive", host: "joueur@example.com",
                                                   username: "123456789012-cartouchegallery.apps.googleusercontent.com")
                CartoucheStorageSettings.shared.showForGallery(drive, games: "Jeux", saves: "Sauvegardes")
                CartoucheStoredGames.shared.showForGallery(storedGames(in: "Jeux"), server: drive.name)
                CartoucheDriveSessions.shared.end(drive.id)
                CartoucheStorageReach.shared.showOfflineForGallery([drive.id])
                CartoucheSaveBackups.shared.showWaitingForGallery(2)
            }
        }
    }

    /// The player's games as IPAs in FOLDER, as Cartouche Builder leaves
    /// them there: built last night.
    @MainActor
    private func storedGames(in folder: String) -> [CartoucheStoredGame] {
        ownedTitles.compactMap { titleId in
            guard let game = CartoucheCatalog.shared.game(titleId: titleId) else { return nil }
            let built = Date().addingTimeInterval(-9 * 3_600)
            return CartoucheStoredGame(
                path: "/\(folder)/\(game.name) [\(titleId)].ipa", size: 21_474_836_480, modified: built,
                bundleId: "org.nxnative." + titleId.lowercased(), displayName: game.name, version: "1.0.0",
                build: CartoucheGameBuild(version: "1.0.0", commit: "7bddb8c1e2f3", chain: "adec7d81d970",
                                          builtAt: built.addingTimeInterval(-120)),
                titleId: titleId, isGame: true)
        }
    }

    /// What Cartouche's server would answer about the player's games that
    /// nxnative.json does not have: what IGDB has of the catalogue's game
    /// of the same name, if there is one, as the server finds a game by its
    /// name.
    @MainActor
    private func showFound() {
        let catalog = CartoucheCatalog.shared
        var found: [String: CartoucheFoundGame] = [:]
        for game in unknownGames {
            let platform = CartoucheGameWanted.platform(titleId: game.titleId)
            guard let wanted = CartoucheGameWanted(name: game.name, platform: platform),
                  let known = catalog.titleId(matchingName: game.name), let cover = catalog.cover(titleId: known) else { continue }
            let profile = catalog.game(titleId: known)
            found[wanted.key] = CartoucheFoundGame(
                igdb: cover.igdb, name: profile?.name ?? game.name, cover: cover.cover, artwork: cover.artwork,
                genre: profile.flatMap { $0.genre == "other" ? nil : $0.genre } ?? cover.genre,
                platform: platform ?? profile?.platform, summary: cover.summary)
        }
        catalog.showFoundForGallery(found)
    }

    /// A cover of the player's own for the game of TITLEID, as one drawn by
    /// hand: never a game's own art.
    @MainActor
    private func showOwnCover(of titleId: String) {
        let catalog = CartoucheCatalog.shared
        guard let entry = catalog.entries(for: self.apps()).owned.first(where: { $0.titleId == titleId }),
              let picture = GalleryIcon.cover(name: entry.name, key: titleId).jpegData(compressionQuality: 0.9) else { return }
        do {
            try catalog.setPlayerInfo(nil, cover: CartouchePlayerInfoStore.jpeg(from: picture), for: entry)
        } catch {
            NSLog("[Gallery] cannot keep the player's cover: %@", String(describing: error))
        }
    }

    /// The size and the play time of the player's games: the first played
    /// for hours, until yesterday, the second for a while this morning, the
    /// third not yet.
    @MainActor
    private func showStats() {
        let sizes: [CartoucheGameSize] = [CartoucheGameSize(bundle: 21_474_836_480, data: 327_155_712),
                                          CartoucheGameSize(bundle: 14_173_392_076, data: 48_234_496),
                                          CartoucheGameSize(bundle: 3_113_851_290, data: 6_291_456)]
        let times: [CartouchePlayTime] = [
            CartouchePlayTime(seconds: 45_240, sessions: 23, firstPlayed: Date().addingTimeInterval(-9 * 86_400),
                              lastPlayed: Date().addingTimeInterval(-86_400)),
            CartouchePlayTime(seconds: 2_820, sessions: 2, firstPlayed: Date().addingTimeInterval(-4 * 3_600),
                              lastPlayed: Date().addingTimeInterval(-3 * 3_600)),
        ]
        var shownSizes: [String: CartoucheGameSize] = [:]
        var shownTimes: [String: CartouchePlayTime] = [:]
        for (index, titleId) in ownedTitles.enumerated() {
            let bundleId = "org.nxnative." + titleId.lowercased()
            if index < sizes.count { shownSizes[bundleId] = sizes[index] }
            if index < times.count { shownTimes[bundleId] = times[index] }
        }
        CartoucheGameStats.shared.showForGallery(sizes: shownSizes, playTimes: shownTimes)
    }

    /// The game a newer build is in the games folder of (work: newer-build,
    /// and offline, away from the games folder): the sheet's, or the first
    /// of the player's.
    private var updatedTitle: String? { work == "newer-build" || work == "offline" ? sheet ?? ownedTitles.first : nil }

    /// The sheet's game, or the first of the player's, paused behind the
    /// console (work: paused).
    @MainActor
    func pause(among apps: [LCAppModel]) {
        guard work == "paused", let titleId = sheet ?? ownedTitles.first,
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
            // Turned sideways first, for up to 30 s: on the iPhone Duo of run
            // 43275681933, beside two builds of the app on Ad's Mac, the
            // simulator had not turned the scene by the time the gallery
            // said it had settled, upright.
            if landscape, let scene {
                for _ in 0..<120 {
                    if scene.effectiveGeometry.interfaceOrientation.isLandscape { break }
                    try? await Task.sleep(for: .milliseconds(250))
                }
            }
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
        ownedTitles.compactMap { titleId in
            guard let name = name(of: titleId) else { return nil }
            let info = LCAppInfo(name: name, identifier: "org.nxnative." + titleId.lowercased(),
                                 folder: titleId + ".app", icon: GalleryIcon.make(name: name, key: titleId))
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
    /// LiveContainer's model, as the gallery stands it in.
    @ObservedObject private var model = DataManager.shared.model

    init() {
        GalleryTest.start()
        scenario = GalleryScenario.fromArguments()
        scenario.prepare()
        // The player's games before any screen, as LiveContainer lists them
        // as it starts: Siri may ask for one before the console shows.
        DataManager.shared.model.apps = scenario.apps()
        MainActor.assumeIsolated {
            GalleryTest.prepared()
            GalleryShortcut.start()
        }
    }

    var body: some Scene {
        WindowGroup {
            content
                .environmentObject(model)
                .preferredColorScheme(.dark)
                .overlay(alignment: .bottomLeading) {
                    if GalleryTest.isOn {
                        GalleryWatchReadout()
                            .frame(width: 2, height: 2)
                            .allowsHitTesting(false)
                    }
                }
                .onAppear {
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
            // Every game, open over the home as the player opens it, beside
            // the sheet of the game in focus on an iPhone Duo unfolded once
            // the player has a game.
            CartoucheGamesView(showingLibrary: true)
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
        case "gameinfo":
            if let entry = entries.owned.first(where: { $0.titleId == scenario.sheet }) {
                NavigationStack {
                    CartoucheGameInfoView(entry: entry, onClose: {})
                }
            }
        case "shortcuts":
            if let entry = entries.owned.first(where: { $0.titleId == scenario.sheet }),
               let id = entry.app?.appInfo.bundleIdentifier() {
                NavigationStack {
                    CartoucheGameShortcutsView(id: id, name: entry.name)
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
        case "guide":
            NavigationStack {
                CartoucheGuideView(entries: entries, onInstall: { _ in }, onImport: { _ in }, onPlay: { _ in })
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button(CartoucheText.done) {}
                        }
                    }
            }
        case "system":
            CartoucheSystemView()
        case "storage":
            NavigationStack {
                CartoucheStorageView()
            }
        case "storage-mac":
            // As the Storage page opens it, for a Mac not paired yet.
            NavigationStack {
                CartoucheStorageMacForm(server: CartoucheStorageServer(kind: .mac, name: ""))
            }
        case "storage-drive":
            // As the Storage page opens it, to add a Google Drive.
            NavigationStack {
                CartoucheStorageDriveForm(server: CartoucheStorageServer(kind: .drive, name: ""))
            }
        case "storage-drive-guide":
            NavigationStack {
                CartoucheDriveGuideView()
            }
        case "telemetry":
            NavigationStack {
                CartoucheTelemetryView()
            }
            .preferredColorScheme(.dark)
        case "report":
            NavigationStack {
                CartoucheReportView()
            }
        case "root":
            CartoucheRootView()
        case "tv":
            if #available(iOS 18.0, *) {
                if let entry = entries.owned.first(where: { $0.titleId == (scenario.sheet ?? scenario.ownedTitles.first) }) {
                    CartoucheTVCard(model: tvCard(for: entry))
                }
            }
        default:
            CartoucheGamesView()
        }
    }

    /// The TV's card for ENTRY's game, as the scenario has it: on screen,
    /// paused or starting.
    @available(iOS 18.0, *)
    @MainActor
    private func tvCard(for entry: CartoucheEntry) -> CartoucheTVCardModel {
        let card = CartoucheTVCardModel()
        card.show(name: entry.name, cover: entry.coverArt, backdrop: entry.backdrop, colorKey: entry.tileKey)
        switch scenario.work {
        case "paused": card.status = .paused
        case "starting": card.status = .starting
        default: card.status = .playing
        }
        return card
    }

    /// The game's settings, on the scenario's category.
    private func settings(for app: LCAppModel, entry: CartoucheEntry) -> CartoucheGameSettingsModel {
        let settings = CartoucheGameActions.shared.settings(for: app, tileKey: entry.tileKey)
        settings.category = scenario.category
        return settings
    }
}

/// The player's Mac with Cartouche Builder, as the gallery shows it: found
/// by Bonjour beside another Mac of the house, then paired. Made-up names,
/// ID and address.
enum GalleryMac {
    static let id = "6f1c2b9e-4d3a-4c8e-9b71-2a5d8e0f3c47"

    static let nearby = [
        CartoucheNearbyMac(name: "MacBook Air", macID: id, endpoint: service("MacBook Air")),
        CartoucheNearbyMac(name: "Mac mini", macID: "c2e7a4d1-8b5f-4e3a-a6d9-1f4b7c0e9a28", endpoint: service("Mac mini")),
    ]

    /// The Mac as Cartouche keeps it once paired, at the address it last
    /// reached it at.
    static func paired() -> CartoucheStorageServer {
        CartoucheStorageServer(kind: .mac, name: "MacBook Air", host: "192.168.1.20", port: Int(CartoucheBridge.port), macID: id)
    }

    private static func service(_ name: String) -> NWEndpoint {
        .service(name: name, type: CartoucheBridge.serviceType, domain: "local.", interface: nil)
    }
}

/// The saves of a game of the player's and the saves folder they are kept
/// in step with, a folder in Files as the player picks one, both in the
/// gallery's Application Support (work: saves): Cartouche's own sync and
/// copies run on them, as on an iPhone, with nothing stood in for but the
/// game's data folder, which LiveContainer gives a game.
enum GallerySaves {
    /// The folder's name, as the Storage page and the sheet show it.
    static let folderName = "Gallery saves"
    /// The game whose saves these are, once the scenario has them.
    @MainActor private static var titleId: String?

    private static var root: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("GallerySaves", isDirectory: true)
    }

    /// The game's Documents, where nxnative keeps its saves.
    private static var documents: URL { root.appendingPathComponent("Game/Documents", isDirectory: true) }

    /// Puts a save in the Documents of the game of TITLEID, as nxnative
    /// writes one, and the folder in Files in its place as the saves folder,
    /// with nothing in it yet.
    @MainActor
    static func prepare(titleId: String) {
        let manager = FileManager.default
        try? manager.removeItem(at: root)
        let save = documents.appendingPathComponent("save/0000000000000001", isDirectory: true)
        let folder = root.appendingPathComponent(folderName, isDirectory: true)
        do {
            try manager.createDirectory(at: save, withIntermediateDirectories: true)
            try manager.createDirectory(at: folder.appendingPathComponent("Saves", isDirectory: true),
                                        withIntermediateDirectories: true)
            // Two MiB of a game's progress, which compresses as little as a
            // real save.
            var progress = Data(count: 2 << 20)
            progress.withUnsafeMutableBytes { arc4random_buf($0.baseAddress, $0.count) }
            try progress.write(to: save.appendingPathComponent("progress.bin"))
            let server = CartoucheStorageServer(kind: .folder, name: folderName, bookmark: try CartoucheFolder.bookmark(of: folder))
            CartoucheStorageSettings.shared.showForGallery(server, games: "", saves: "Saves")
            self.titleId = titleId
        } catch {
            NSLog("[Gallery] cannot make the saves and their folder: %@", String(describing: error))
        }
    }

    /// The saves of APP, if it is the scenario's game.
    @MainActor
    static func target(of app: LCAppModel) -> CartoucheSaveTarget? {
        guard let titleId, app.appInfo.relativeBundlePath == titleId + ".app",
              let bundleId = app.appInfo.bundleIdentifier() else { return nil }
        return CartoucheSaveTarget(key: bundleId + "|gallery", name: app.displayName, titleId: titleId, documents: documents)
    }
}
