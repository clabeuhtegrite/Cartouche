//
//  CartoucheGameActions.swift
//  Cartouche
//
//  What Cartouche does with a game, on its own screens: install the
//  player's IPA, start the game, open its settings, uninstall it. Each step
//  is the one LiveContainer's Apps tab takes (LCAppListView.installIpaFile,
//  LCAppModel.runApp, the container's Preferences page,
//  LCAppBannerViewController.uninstall), without its questions:
//
//  - the IPA of a game already installed replaces it in place, with its
//    settings and saves, as LiveContainer's Replace does;
//  - an uninstalled game leaves its data folder, saves inside, unless the
//    player erases them too, and the game's next install takes it back;
//  - Play starts the game at once. nxnative shows its settings screen
//    before a game unless Documents/env.txt holds DM_LAUNCHER=0 (main.m,
//    Launcher.swift), which Play writes there; the game then applies the
//    choices saved in its preferences, which the game's settings page in
//    Cartouche writes (CartoucheGameSettings.swift). Start on nxnative's
//    screen takes the line out, so that the screen shows.
//

import Combine
import SwiftUI
import UIKit

@MainActor
final class CartoucheGameActions: ObservableObject {
    static let shared = CartoucheGameActions()

    /// What Cartouche is doing with a game, shown over the console.
    @Published private(set) var work: CartoucheGameWork?
    /// Why the last step failed, or what the player should know of it.
    @Published var notice: CartoucheGameNotice?
    /// The game the last import installed: the console shows it.
    @Published var installed: LCAppModel?

    private var progressObservation: NSKeyValueObservation?
    private var signing: AnyCancellable?

    /// Whether a file another app opened Cartouche with is an app to
    /// install: Cartouche installs it itself instead of the Apps tab
    /// (CartouchePairing.openedFile).
    nonisolated static func takes(_ url: URL) -> Bool {
        url.isFileURL && ["ipa", "tipa"].contains(url.pathExtension.lowercased())
    }

    // MARK: Install

    /// Installs the IPA the player picked or opened Cartouche with, read in
    /// place: a game's IPA is too large to copy first, so the access the
    /// picker granted stays open until the end.
    func install(_ url: URL) {
        guard work == nil else { return }
        let model = DataManager.shared.model
        guard model.multiLCStatus != 2 else {
            notice = CartoucheGameNotice(title: CartoucheText.installFailed, message: "lc.appList.manageInPrimaryTip".loc)
            return
        }
        let accessing = url.startAccessingSecurityScopedResource()
        guard FileManager.default.isReadableFile(atPath: url.path) else {
            if accessing { url.stopAccessingSecurityScopedResource() }
            notice = CartoucheGameNotice(title: CartoucheText.installFailed, message: "lc.appList.ipaAccessError".loc)
            return
        }
        // Unpacking writes about as much as the IPA holds.
        let size = Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        let needed = size + 512 * 1_048_576
        if let free = Self.freeSpace(), free < needed {
            if accessing { url.stopAccessingSecurityScopedResource() }
            notice = CartoucheGameNotice(title: CartoucheText.installFailed,
                                         message: CartoucheText.installNoSpace(needed: CartoucheText.storageAmount(bytes: needed),
                                                                               free: CartoucheText.storageAmount(bytes: free)))
            return
        }

        work = CartoucheGameWork(kind: .installing, name: url.deletingPathExtension().lastPathComponent,
                                 step: CartoucheText.installUnpacking, fraction: 0)
        // A large game takes minutes to unpack: the iPhone must not lock
        // meanwhile, which would pause Cartouche.
        UIApplication.shared.isIdleTimerDisabled = true
        Task {
            do {
                let (app, warning) = try await installIPA(url, into: model)
                installed = app
                if let warning {
                    notice = CartoucheGameNotice(title: CartoucheText.installSignWarning, message: warning)
                } else if CartoucheCatalog.shared.entries(for: [app]).owned.isEmpty {
                    notice = CartoucheGameNotice(title: CartoucheText.installDone, message: CartoucheText.installNotAGame(app.displayName))
                }
            } catch {
                notice = CartoucheGameNotice(title: CartoucheText.installFailed, message: error.localizedDescription)
            }
            if accessing { url.stopAccessingSecurityScopedResource() }
            Self.removeIfInbox(url)
            progressObservation = nil
            UIApplication.shared.isIdleTimerDisabled = false
            work = nil
        }
    }

    private func installIPA(_ url: URL, into model: SharedModel) async throws -> (LCAppModel, String?) {
        let fileManager = FileManager.default
        let progress = Progress.discreteProgress(totalUnitCount: 100)
        let relay = CartoucheProgressRelay()
        // Called on the thread that unpacks or signs.
        progressObservation = progress.observe(\.fractionCompleted) { @Sendable progress, _ in
            let fraction = progress.fractionCompleted
            guard relay.changed(fraction) else { return }
            Task { @MainActor in
                CartoucheGameActions.shared.work?.fraction = fraction
            }
        }

        // Its own folder, apart from the one the Apps tab unpacks into.
        let folder = fileManager.temporaryDirectory.appendingPathComponent("CartoucheInstall", isDirectory: true)
        try? fileManager.removeItem(at: folder)
        try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: folder) }

        let unpacking = Progress.discreteProgress(totalUnitCount: 100)
        progress.addChild(unpacking, withPendingUnitCount: 80)
        guard await Self.unpack(url.path, into: folder.path, unpacking) == 0 else {
            throw "lc.appList.urlFileIsNotIpaError".loc
        }
        let payload = folder.appendingPathComponent("Payload", isDirectory: true)
        guard let bundleName = try fileManager.contentsOfDirectory(atPath: payload.path).first(where: { $0.hasSuffix(".app") }) else {
            throw "lc.appList.bundleNotFondError".loc
        }
        let unpacked = payload.appendingPathComponent(bundleName)
        guard let newInfo = LCAppInfo(bundlePath: unpacked.path), let bundleId = newInfo.bundleIdentifier() else {
            throw "lc.appList.infoPlistCannotReadError".loc
        }
        work?.name = newInfo.displayName() ?? work?.name ?? ""

        // The same game installed already: this copy takes its place.
        let previous = model.apps.first { $0.appInfo.bundleIdentifier() == bundleId }
        var relativePath = "\(bundleId.sanitizeNonACSII()).app"
        var destination = LCPath.bundlePath.appendingPathComponent(relativePath)
        if let previous, let previousPath = previous.appInfo.relativeBundlePath {
            relativePath = previousPath
            destination = (previous.uiIsShared ? LCPath.lcGroupBundlePath : LCPath.bundlePath).appendingPathComponent(relativePath)
            if fileManager.fileExists(atPath: destination.path) {
                try fileManager.removeItem(at: destination)
            }
        } else if fileManager.fileExists(atPath: destination.path)
                    || model.hiddenApps.contains(where: { $0.appInfo.bundleIdentifier() == bundleId }) {
            // A folder of that name that no app of the list uses, or a
            // hidden copy: a folder of its own, as the Apps tab makes.
            relativePath = "\(bundleId)_\(Int(CFAbsoluteTimeGetCurrent())).app"
            destination = LCPath.bundlePath.appendingPathComponent(relativePath)
        }
        try fileManager.moveItem(at: unpacked, to: destination)
        guard let info = LCAppInfo(bundlePath: destination.path) else {
            throw "lc.appList.appInfoInitError".loc
        }
        info.relativeBundlePath = relativePath

        work?.step = CartoucheText.installSigning
        if previous?.uiDontSign ?? false || LCUtils.appGroupUserDefault.bool(forKey: "LCDontSignApp") {
            info.dontSign = true
        }
        var signError: String?
        var signSuccess = false
        await withUnsafeContinuation { (continuation: UnsafeContinuation<Void, Never>) in
            info.patchExecAndSignIfNeed(completionHandler: { success, error in
                signError = error
                signSuccess = success
                continuation.resume()
            }, progressHandler: { signProgress in
                if let signProgress {
                    progress.addChild(signProgress, withPendingUnitCount: 20)
                }
            }, forceSign: false)
        }
        // Installed even if signing failed, as the Apps tab leaves it.
        var warning: String?
        if let signError {
            warning = signSuccess ? "\("lc.appList.signSuccessWithError".loc)\n\n\(signError)" : signError.loc
        }

        if let previous {
            Self.carry(previous.appInfo, to: info)
        } else {
            info.spoofSDKVersion = true
            // The saves an uninstalled copy of this game left.
            if let left = Self.leftData(of: bundleId, model: model) {
                info.containers = [left]
                info.dataUUID = left.folderName
            }
        }
        info.installationDate = Date.now

        let app = LCAppModel(appInfo: info, delegate: previous?.delegate ?? model.apps.lazy.compactMap(\.delegate).first)
        if let previous {
            model.apps.removeAll { $0 == previous }
        } else if let schemes = info.urlSchemes(), schemes.count > 0 {
            UserDefaults.lcShared().mutableArrayValue(forKey: "LCGuestURLSchemes").addObjects(from: schemes as! [Any])
        }
        model.apps.append(app)
        return (app, warning)
    }

    /// The settings of the copy an IPA replaces, as the Apps tab carries
    /// them over.
    private static func carry(_ old: LCAppInfo, to info: LCAppInfo) {
        info.autoSaveDisabled = true
        info.isLocked = old.isLocked
        info.isHidden = old.isHidden
        info.isJITNeeded = old.isJITNeeded
        info.isShared = old.isShared
        info.spoofSDKVersion = old.spoofSDKVersion
        info.doSymlinkInbox = old.doSymlinkInbox
        info.containerInfo = old.containerInfo
        info.tweakFolder = old.tweakFolder
        info.selectedLanguage = old.selectedLanguage
        info.dataUUID = old.dataUUID
        info.orientationLock = old.orientationLock
        info.dontInjectTweakLoader = old.dontInjectTweakLoader
        info.hideLiveContainer = old.hideLiveContainer
        info.dontLoadTweakLoader = old.dontLoadTweakLoader
        info.doUseLCBundleId = old.doUseLCBundleId
        info.fixFilePickerNew = old.fixFilePickerNew
        info.fixLocalNotification = old.fixLocalNotification
        info.lastLaunched = old.lastLaunched
        info.jitLaunchScriptJs = old.jitLaunchScriptJs
        info.multitaskSpecified = old.multitaskSpecified
        info.classicMode = old.classicMode
        info.autoSaveDisabled = false
        info.save()
    }

    /// The data folder an uninstalled copy of the game left: the newest one
    /// made for this bundle ID that no installed app uses.
    private static func leftData(of bundleId: String, model: SharedModel) -> LCContainer? {
        let used = Set((model.apps + model.hiddenApps).flatMap { $0.uiContainers.map(\.folderName) })
        let keys: [URLResourceKey] = [.contentModificationDateKey, .isDirectoryKey]
        guard let folders = try? FileManager.default.contentsOfDirectory(at: LCPath.dataPath, includingPropertiesForKeys: keys,
                                                                       options: .skipsHiddenFiles) else { return nil }
        var found: (folder: String, name: String, date: Date)?
        for folder in folders where !used.contains(folder.lastPathComponent) {
            guard let plist = NSDictionary(contentsOf: folder.appendingPathComponent("LCContainerInfo.plist")) as? [String: Any],
                  plist["appIdentifier"] as? String == bundleId else { continue }
            let date = (try? folder.resourceValues(forKeys: Set(keys)).contentModificationDate) ?? .distantPast
            if found == nil || date > found!.date {
                found = (folder.lastPathComponent, plist["name"] as? String ?? folder.lastPathComponent, date)
            }
        }
        guard let found else { return nil }
        return LCContainer(folderName: found.folder, name: found.name, isShared: false)
    }

    nonisolated private static func unpack(_ path: String, into destination: String, _ progress: Progress) async -> Int32 {
        extract(path, destination, progress)
    }

    nonisolated private static func freeSpace() -> Int64? {
        let values = try? LCPath.docPath.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage
    }

    /// The copy iOS makes in Documents/Inbox of a file opened from another
    /// app goes once installed, as the Apps tab deletes it.
    private static func removeIfInbox(_ url: URL) {
        let inbox = LCPath.docPath.appendingPathComponent("Inbox", isDirectory: true).standardizedFileURL
        if url.deletingLastPathComponent().standardizedFileURL == inbox {
            try? FileManager.default.removeItem(at: url)
        }
    }

    // MARK: Play

    /// Starts the game, signed for this iPhone first if it needs to be.
    /// Cartouche then opens again as the game. With showingSettings,
    /// nxnative shows its settings screen before the game.
    func play(_ app: LCAppModel, showingSettings: Bool = false) {
        guard work == nil, !app.isAppRunning else { return }
        work = CartoucheGameWork(kind: .starting, name: app.displayName,
                                 step: showingSettings ? CartoucheText.startSettings : CartoucheText.startSoon, fraction: nil)
        signing = app.$signProgress
            .combineLatest(app.$isSigningInProgress)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] value in
                let (fraction, inProgress) = value
                guard inProgress else { return }
                self?.work?.step = CartoucheText.installSigning
                self?.work?.fraction = fraction
            }
        Task {
            let delegate = app.delegate
            do {
                try Self.prepareStart(of: app, showingSettings: showingSettings)
                // The questions runApp may ask come to Cartouche.
                app.delegate = self
                try await app.runApp(multitask: false, forceJIT: false)
            } catch {
                notice = CartoucheGameNotice(title: CartoucheText.startFailed, message: error.localizedDescription)
            }
            // Still here: the game did not start.
            app.delegate = delegate
            signing = nil
            work = nil
        }
    }

    /// nxnative's switch for its settings screen, in the data folder the
    /// game starts with.
    private static func prepareStart(of app: LCAppModel, showingSettings: Bool) throws {
        let container = dataFolder(of: app)
        // Only an nxnative game reads it.
        guard let bundle = app.appInfo.bundlePath(),
              FileManager.default.fileExists(atPath: (bundle as NSString).appendingPathComponent("dm")),
              let container else { return }
        try CartoucheStartSwitch.write(showingSettings: showingSettings, home: container.containerURL)
    }

    /// The data folder runApp starts the game with, made as runApp makes it
    /// on a first start.
    private static func dataFolder(of app: LCAppModel) -> LCContainer? {
        if app.uiContainers.isEmpty, let bundleId = app.appInfo.bundleIdentifier() {
            let name = NSUUID().uuidString
            let container = LCContainer(folderName: name, name: name, isShared: app.uiIsShared)
            app.uiContainers.append(container)
            if app.uiSelectedContainer == nil {
                app.uiSelectedContainer = container
            }
            app.appInfo.containers = app.uiContainers
            container.makeLCContainerInfoPlist(appIdentifier: bundleId,
                                               keychainGroupId: Int.random(in: 0..<SharedModel.keychainAccessGroupCount))
            app.appInfo.dataUUID = name
            app.uiDefaultDataFolder = name
        }
        return app.uiSelectedContainer ?? app.uiContainers.first
    }

    /// The game's home, letter for letter as LiveContainer sets HOME for it
    /// (LCBootstrap.m), so that its preferences are the ones cfprefsd hands
    /// the game.
    private static func guestHome(of container: LCContainer) -> URL {
        if container.storageBookMark == nil, !container.isShared, let home = getenv("LC_HOME_PATH") {
            return URL(fileURLWithPath: String(cString: home) + "/Documents/Data/Application/" + container.folderName,
                       isDirectory: true)
        }
        return container.containerURL
    }

    // MARK: Settings

    /// The game's settings page: the rows of its dm/launcher.json, and the
    /// choices in the game's own preferences, in the data folder it starts
    /// with (made now if the game never started).
    func settings(for app: LCAppModel, tileKey: String) -> CartoucheGameSettingsModel {
        let bundle = app.appInfo.bundlePath().map { URL(fileURLWithPath: $0, isDirectory: true) }
        let container = Self.dataFolder(of: app)
        var choices: CartoucheGameChoices?
        // The game's domain: LiveContainer gives the game its own bundle ID,
        // the original one when the game borrows LiveContainer's.
        if let container, let domain = app.appInfo.bundleIdentifier() {
            choices = CartoucheGamePreferences(domain: domain, home: Self.guestHome(of: container))
        }
        return CartoucheGameSettingsModel(
            name: app.displayName,
            tileKey: tileKey,
            settings: bundle.flatMap { CartoucheGameSetting.rows(inBundle: $0) } ?? [],
            fixed: bundle.map { CartoucheGameSetting.fixedValues(home: container?.containerURL, bundle: $0) } ?? [:],
            choices: choices)
    }

    // MARK: Uninstall

    /// Removes the game. Its data folder stays, with the saves, unless
    /// erasingData: then it goes too, as LiveContainer deletes it. What the
    /// game makes again at each start goes either way.
    func uninstall(_ app: LCAppModel, erasingData: Bool) {
        guard work == nil, let bundlePath = app.appInfo.bundlePath() else { return }
        let model = DataManager.shared.model
        // Folders the player picked elsewhere are theirs: never deleted.
        let folders = app.uiContainers.filter { $0.storageBookMark == nil }.map { container in
            (name: container.folderName,
             url: (container.isShared ? LCPath.lcGroupDataPath : LCPath.dataPath).appendingPathComponent(container.folderName))
        }
        work = CartoucheGameWork(kind: .uninstalling, name: app.displayName, step: CartoucheText.uninstallStep, fraction: nil)
        Task {
            do {
                try await Self.remove(bundlePath: bundlePath, folders: folders.map(\.url), erasingData: erasingData)
                model.apps.removeAll { $0 == app }
                model.hiddenApps.removeAll { $0 == app }
                if erasingData {
                    for folder in folders {
                        LCUtils.removeAppKeychain(dataUUID: folder.name)
                        model.appDataFolderNames.removeAll { $0 == folder.name }
                    }
                }
            } catch {
                notice = CartoucheGameNotice(title: CartoucheText.uninstallFailed, message: error.localizedDescription)
            }
            work = nil
        }
    }

    /// Off the main thread: a game's bundle holds gigabytes.
    nonisolated private static func remove(bundlePath: String, folders: [URL], erasingData: Bool) async throws {
        let fileManager = FileManager.default
        try fileManager.removeItem(atPath: bundlePath)
        for folder in folders {
            if erasingData {
                try fileManager.removeItem(at: folder)
            } else {
                // The guest's memory files and caches; Documents keeps the saves.
                for leftover in ["tmp", "Library/Caches", "Documents/temp"] {
                    try? fileManager.removeItem(at: folder.appendingPathComponent(leftover))
                }
            }
        }
    }
}

// MARK: Questions from runApp

extension CartoucheGameActions: LCAppModelDelegate {
    nonisolated func closeNavigationView() {}

    nonisolated func changeAppVisibility(app: LCAppModel) {}

    // Play never asks for JIT (forceJIT: false): nxnative games run without.
    nonisolated func jitLaunch(appName: String, classicMode: UInt) async {}

    nonisolated func jitLaunch(withScript script: String, appName: String, classicMode: UInt) async {}

    nonisolated func jitLaunch(withPID pid: Int, withScript script: String?, appName: String) async {}

    /// An app runs in a window of its own: the player pressed Play, so it
    /// closes, as the Apps tab's Continue does.
    nonisolated func showRunWhenMultitaskAlert() async -> Bool? { true }
}

/// nxnative's switch for its settings screen, in a game's Documents/env.txt
/// (main.m reads it before the game starts). Cartouche keeps every other
/// line of the file.
enum CartoucheStartSwitch {
    static let key = "DM_LAUNCHER"
    static let note = "# Cartouche: Play starts the game at once; Game settings shows the settings screen first."

    static func write(showingSettings: Bool, home: URL) throws {
        let documents = home.appendingPathComponent("Documents", isDirectory: true)
        let file = documents.appendingPathComponent("env.txt")
        let old = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
        var lines = old.components(separatedBy: .newlines).filter { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            return !trimmed.hasPrefix(key + "=") && trimmed != note
        }
        while lines.last?.isEmpty == true {
            lines.removeLast()
        }
        if !showingSettings {
            lines += [note, key + "=0"]
        }
        let text = lines.isEmpty ? "" : lines.joined(separator: "\n") + "\n"
        guard text != old else { return }
        if text.isEmpty {
            try? FileManager.default.removeItem(at: file)
            return
        }
        try FileManager.default.createDirectory(at: documents, withIntermediateDirectories: true)
        try text.write(to: file, atomically: true, encoding: .utf8)
    }
}

/// A game's preferences, opened as LiveContainer's own Preferences page for
/// a data folder opens them (LCAppPreferenceView.swift): the game's domain
/// in its data folder, through cfprefsd, where the game's standard defaults
/// point (LiveContainer's NSUserDefaults.m). Going through cfprefsd as the
/// game does, neither side reads a stale copy.
final class CartoucheGamePreferences: CartoucheGameChoices {
    private let defaults: UserDefaults

    init?(domain: String, home: URL) {
        // cfprefsd writes the game's file there; the game makes it at its
        // first start.
        try? FileManager.default.createDirectory(at: home.appendingPathComponent("Library/Preferences", isDirectory: true),
                                                 withIntermediateDirectories: true)
        guard let defaults = UserDefaults()._init(withSuiteName: domain, container: home) else { return nil }
        self.defaults = defaults
    }

    func string(forKey key: String) -> String? {
        defaults.object(forKey: key) as? String
    }

    func data(forKey key: String) -> Data? {
        defaults.data(forKey: key)
    }

    func set(_ value: Any?, forKey key: String) {
        defaults.set(value, forKey: key)
        // Play quits Cartouche for the game at once: the change reaches
        // cfprefsd first.
        defaults.synchronize()
    }
}

/// Lets a progress through to the screen once per thousandth: unpacking
/// reports every block it writes, from another thread.
final class CartoucheProgressRelay: @unchecked Sendable {
    private let lock = NSLock()
    private var last = -1

    func changed(_ fraction: Double) -> Bool {
        let step = Int(fraction * 1000)
        lock.lock()
        defer { lock.unlock() }
        guard step != last else { return false }
        last = step
        return true
    }
}
