//
//  CartoucheReset.swift
//  Cartouche
//
//  System › Reset Cartouche (CartoucheResetView, decision 99): Cartouche
//  erases what the player put in it and what it learned since, as
//  CartoucheResetPlan says, then starts again as a new player finds it the
//  first time it opens after the Cartouche Installer: without a computer,
//  and without installing it again. The certificate, the pairing file and
//  the game measurements' number stay.
//
//  Before it, Cartouche names the games whose saves are not in the saves
//  folder as they are here, which the reset would lose, and sends them
//  there first if the player asks. It waits for a game, an install, a
//  sign-in, an update or a renewal under way.
//
//  The erase leaves nothing for what still runs to write back: Cartouche's
//  own models first, through their own calls; then the keychain; then the
//  preferences, through cfprefsd, which would hand back what it keeps of a
//  file gone; then the files. It runs twice, for what a model wrote
//  meanwhile. LiveContainer then starts Cartouche again, as it starts a
//  game in its place, which ends this process at once. What could not go
//  stops the reset there, with a report, before Cartouche starts again.
//

import Foundation
import Security
import UIKit

@available(iOS 17.0, *)
@MainActor
final class CartoucheReset: ObservableObject {
    static let shared = CartoucheReset()

    enum Phase: Equatable {
        case erasing
        /// LiveContainer starts Cartouche again.
        case restarting
    }

    /// Where the reset stands, while it runs.
    @Published private(set) var phase: Phase?
    /// Why the last reset did not erase everything, and the report on it.
    @Published private(set) var report: CartoucheReport?
    /// The games whose saves the reset would lose, by name: those whose
    /// saves are not in the saves folder as they are here. Nil until
    /// Cartouche has looked.
    @Published private(set) var savesAtRisk: [String]?
    /// Whether the saves at risk are on their way to the saves folder.
    @Published private(set) var isSendingSaves = false

    private var targetsAtRisk: [CartoucheSaveTarget] = []

    /// What stays besides what CartoucheResetPlan keeps: in the harness,
    /// the file its standard error goes to, which its tests read
    /// (HarnessStandardError).
    var alsoKept: [URL] = []

    private init() {
        #if CARTOUCHE_HARNESS
        alsoKept = [HarnessStandardError.file]
        #endif
    }

    /// Why Cartouche cannot be reset now, if it cannot: a game running, or
    /// what the reset would cut short.
    var blocker: String? {
        let actions = CartoucheGameActions.shared
        if let running = actions.running {
            return CartoucheText.resetWhilePlaying(running.name)
        }
        if let work = actions.work {
            return CartoucheText.resetBusy(work.title)
        }
        if isSendingSaves || CartoucheSaveBackups.shared.isSyncing || CartoucheAccount.shared.phase != nil
            || CartoucheUpdates.shared.phase != nil || CartoucheSetup.shared.isImportingSigning
            || CartoucheTelemetry.shared.isErasing || CartoucheRenewal.isRenewing {
            return CartoucheText.resetWait
        }
        return nil
    }

    // MARK: The saves

    /// Looks for the games among APPS whose saves the reset would lose.
    func checkSaves(of apps: [LCAppModel]) async {
        let actions = CartoucheGameActions.shared
        let backups = CartoucheSaveBackups.shared
        var atRisk: [CartoucheSaveTarget] = []
        for target in apps.compactMap({ actions.saves(of: $0) }) {
            let inStep = await backups.isInStep(target)
            if !inStep { atRisk.append(target) }
        }
        targetsAtRisk = atRisk
        savesAtRisk = atRisk.map(\.name)
    }

    /// Sends the saves at risk to the saves folder, one game after another,
    /// then looks again among APPS.
    func sendSavesAtRisk(of apps: [LCAppModel]) async {
        guard !isSendingSaves, phase == nil else { return }
        isSendingSaves = true
        CartoucheReports.note("Reset: sending the saves of \(targetsAtRisk.count) games before it")
        for target in targetsAtRisk {
            _ = await CartoucheSaveBackups.shared.syncNow(target)
        }
        isSendingSaves = false
        await checkSaves(of: apps)
    }

    // MARK: Erasing

    /// Erases Cartouche, then starts it again.
    func reset() {
        guard phase == nil, blocker == nil else { return }
        phase = .erasing
        report = nil
        Task { await run() }
    }

    /// Starts Cartouche again as it is, after a reset that could not erase
    /// everything, as the player asks.
    func restartNow() {
        guard phase == nil else { return }
        #if CARTOUCHE_GALLERY
        report = nil
        #else
        restart()
        #endif
    }

    #if CARTOUCHE_GALLERY
    /// The gallery's reset erases nothing: it shows each phase a moment.
    private func run() async {
        try? await Task.sleep(for: .seconds(2))
        phase = .restarting
        try? await Task.sleep(for: .seconds(1))
        phase = nil
    }

    /// The reset at PHASE, for the launcher's gallery (launcher/Gallery).
    func showForGallery(_ phase: Phase) {
        self.phase = phase
    }
    #else
    private func run() async {
        let started = Date()
        let application = UIApplication.shared
        // A few seconds more, should the player leave Cartouche meanwhile.
        let background = application.beginBackgroundTask(withName: "Cartouche reset")
        defer {
            if background != .invalid { application.endBackgroundTask(background) }
        }
        let found = CartoucheResetErase.find()
        let savesLost = targetsAtRisk.count
        var failures: [CartoucheResetPlan.Failure] = []
        for round in 1...2 {
            if round == 2 {
                // What a model wrote meanwhile, from a sink of its own.
                try? await Task.sleep(for: .milliseconds(500))
            }
            failures = CartoucheResetErase.eraseState(found)
            failures += await CartoucheResetErase.eraseFiles(found, alsoKept: alsoKept)
        }
        targetsAtRisk = []
        savesAtRisk = nil
        let seconds = Date().timeIntervalSince(started)
        CartoucheReports.note("Reset: Cartouche erased: \(found.games) games, \(found.storages) storage places, "
                              + (found.signedIn ? "the Apple ID" : "no Apple ID") + "; "
                              + "\(failures.count) items left, in " + String(format: "%.1f s", seconds))
        // Its number and its reports not sent yet stay: the next start
        // sends it.
        CartoucheTelemetry.shared.event("app.reset", fields: [
            "games": .number(Double(found.games)),
            "storages": .number(Double(found.storages)),
            "signedIn": .flag(found.signedIn),
            "savesLost": .number(Double(savesLost)),
            "failures": .number(Double(failures.count)),
            "seconds": .number((seconds * 10).rounded() / 10),
        ])
        guard failures.isEmpty else {
            let shown = failures.prefix(10).map { failure in
                CartoucheReport.Fact("Left", Self.shortPath(failure.path) + ": " + failure.reason)
            }
            report = CartoucheReports.make(.reset, CartoucheText.resetFailed,
                                           message: CartoucheText.resetFailedMessage(failures.count),
                                           step: CartoucheText.resetErasing, stage: "erasing", seconds: seconds,
                                           facts: [.init("Items left", String(failures.count))] + shown)
            phase = nil
            return
        }
        restart()
    }

    /// Starts Cartouche again, as LiveContainer starts a game in its place:
    /// iOS opens Cartouche again, here with no game chosen, so on its
    /// console, and this process ends at once.
    private func restart() {
        phase = .restarting
        CartoucheReports.flush()
        UserDefaults.standard.synchronize()
        LCSharedUtils.launchToGuestApp(withClassicMode: 0)
        #if CARTOUCHE_HARNESS
        // The harness records the start and goes on (HarnessLC.launches).
        phase = nil
        #else
        // Should iOS not open it again, Cartouche ends all the same: the
        // player opens it as new.
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { exit(0) }
        #endif
    }

    /// PATH's first three parts, for a report: never the names of the
    /// player's files deeper down.
    private static func shortPath(_ path: String) -> String {
        let parts = path.split(separator: "/")
        return parts.prefix(3).joined(separator: "/") + (parts.count > 3 ? "/…" : "")
    }
    #endif
}

#if !CARTOUCHE_GALLERY
/// The steps of a reset (CartoucheReset), as CartoucheResetPlan says.
@available(iOS 17.0, *)
@MainActor
enum CartoucheResetErase {
    /// What the reset found before it erased anything.
    struct Found {
        /// Cartouche's home, its app's container.
        let home: URL
        let documents: URL
        let appGroup: URL?
        let appGroupID: String?
        /// The folders of the player's storage, where their bookmarks lead.
        let playerFolders: [URL]
        /// The games' data folders, by name.
        let dataFolders: [String]
        let games: Int
        let storages: Int
        let signedIn: Bool
        /// Apple's limit on sign-ins, as Cartouche keeps it, while it counts.
        let signInPause: Data?
    }

    static func find() -> Found {
        let documents = LCPath.docPath
        let settings = CartoucheStorageSettings.shared
        let folders = settings.servers.compactMap { server -> URL? in
            guard server.kind == .folder, let bookmark = server.bookmark else { return nil }
            var stale = false
            return try? URL(resolvingBookmarkData: bookmark, options: [], relativeTo: nil, bookmarkDataIsStale: &stale)
        }
        let applications = documents.appendingPathComponent("Applications", isDirectory: true)
        let games = ((try? FileManager.default.contentsOfDirectory(atPath: applications.path)) ?? [])
            .filter { $0.hasSuffix(".app") }.count
        let pause = UserDefaults.standard.data(forKey: CartoucheAccount.pauseKey)
        let appGroup: URL? = LCSharedUtils.appGroupPath()
        let appGroupID: String? = LCSharedUtils.appGroupID()
        return Found(home: URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true), documents: documents,
                     appGroup: appGroup, appGroupID: appGroupID, playerFolders: folders,
                     dataFolders: CartoucheResetPlan.gameDataFolders(documents: documents), games: games,
                     storages: settings.servers.count, signedIn: CartoucheSetup.shared.appleID != nil,
                     signInPause: CartoucheResetPlan.keepsSignInPause(pause, at: Date()) ? pause : nil)
    }

    /// Erases what Cartouche's models keep, the keychain items and the
    /// preferences: what could not go.
    static func eraseState(_ found: Found) -> [CartoucheResetPlan.Failure] {
        // Through the models' own calls, which none then writes back. The
        // telemetry forgets the games; its number stays.
        CartoucheTelemetry.shared.forgetGames()
        CartoucheReports.forget()
        let settings = CartoucheStorageSettings.shared
        for server in settings.servers {
            settings.remove(server)
        }
        for role in CartoucheStorageRole.allCases where settings.place(role) != nil {
            settings.setPlace(nil, for: role)
        }
        // The keychain: each game's items, the storage's, and the built-in
        // SideStore's but the certificate and what Apple knows this device
        // by.
        for folder in found.dataFolders {
            LCUtils.removeAppKeychain(dataUUID: folder)
        }
        var failures: [CartoucheResetPlan.Failure] = []
        if let failure = CartoucheResetKeychain.remove(service: CartoucheResetPlan.storageService) {
            failures.append(failure)
        }
        if let service = CartoucheStoreKeychain.service {
            for account in CartoucheResetKeychain.accounts(of: service) where !CartoucheResetPlan.keepsStoreItem(account: account) {
                if let failure = CartoucheResetKeychain.remove(service: service, account: account) {
                    failures.append(failure)
                }
            }
        }
        erasePreferences(found)
        return failures
    }

    private static func erasePreferences(_ found: Found) {
        // The built-in SideStore's, in its home, opened as LiveContainer's
        // own Preferences page opens a guest's: key by key, through cfprefsd,
        // before their files go. Those of the app group's name are
        // SideStore's own there: what the app group's lost of
        // LiveContainer's, should cfprefsd take them for the app group's own,
        // comes back.
        let shared = UserDefaults.lcShared()
        let before = found.appGroupID.flatMap { shared.persistentDomain(forName: $0) } ?? [:]
        let storeHome = found.documents.appendingPathComponent(CartoucheResetPlan.storeHome, isDirectory: true)
        let storePreferences = CartoucheResetPlan.storePreferences(documents: found.documents)
        for domain in CartoucheResetPlan.storePreferenceDomains(documents: found.documents)
        where domain != Bundle.main.bundleIdentifier {
            guard let defaults = UserDefaults()._init(withSuiteName: domain, container: storeHome) else { continue }
            let file = storePreferences.appendingPathComponent(domain + ".plist")
            CartoucheResetPlan.remove(CartoucheResetPlan.keys(ofPreferences: file), from: defaults)
            defaults.synchronize()
        }
        if let domain = found.appGroupID {
            let after = shared.persistentDomain(forName: domain) ?? [:]
            for (key, value) in CartoucheResetPlan.lostSharedPreferences(before: before, after: after) {
                shared.set(value, forKey: key)
            }
            // Cartouche's own in the app group; LiveContainer's stay.
            for defaults in [LCUtils.appGroupUserDefault, shared] {
                CartoucheResetPlan.remove(CartoucheResetPlan.cartouchesKeys(in: defaults, domain: domain), from: defaults)
            }
        }
        // Cartouche's own, with LiveContainer's in Cartouche: every one, as on
        // a new install, but Apple's limit on sign-ins while it counts.
        let standard = UserDefaults.standard
        if let domain = Bundle.main.bundleIdentifier {
            CartoucheResetPlan.remove(Array((standard.persistentDomain(forName: domain) ?? [:]).keys), from: standard)
            standard.removePersistentDomain(forName: domain)
        }
        if let pause = found.signInPause {
            standard.set(pause, forKey: CartoucheAccount.pauseKey)
        }
        standard.synchronize()
    }

    /// Erases the files, but those that stay, off the main thread: what
    /// could not go.
    static func eraseFiles(_ found: Found, alsoKept: [URL]) async -> [CartoucheResetPlan.Failure] {
        let home = found.home
        let appGroup = found.appGroup
        let kept = CartoucheResetPlan.kept(home: home, appGroup: appGroup, playerFolders: found.playerFolders, also: alsoKept)
        return await Task.detached(priority: .userInitiated) {
            CartoucheResetPlan.eraseFiles(home: home, appGroup: appGroup, keeping: kept)
        }.value
    }
}

/// The keychain items a reset removes, synced through iCloud or not, as
/// the built-in SideStore keeps some.
enum CartoucheResetKeychain {
    /// The accounts of SERVICE's items.
    static func accounts(of service: String) -> [String] {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrSynchronizable as String: kSecAttrSynchronizableAny,
            kSecMatchLimit as String: kSecMatchLimitAll,
            kSecReturnAttributes as String: true,
        ]
        var found: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &found) == errSecSuccess,
              let items = found as? [[String: Any]] else { return [] }
        return Array(Set(items.compactMap { $0[kSecAttrAccount as String] as? String })).sorted()
    }

    /// Removes SERVICE's item of ACCOUNT, or all of SERVICE's: why not, if
    /// it could not.
    static func remove(service: String, account: String? = nil) -> CartoucheResetPlan.Failure? {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrSynchronizable as String: kSecAttrSynchronizableAny,
        ]
        if let account {
            query[kSecAttrAccount as String] = account
        }
        let status = SecItemDelete(query as CFDictionary)
        guard status != errSecSuccess, status != errSecItemNotFound else { return nil }
        let place = service == CartoucheResetPlan.storageService ? "storage" : "SideStore"
        return CartoucheResetPlan.Failure(path: "Keychain/" + place + (account.map { "/" + $0 } ?? ""),
                                          reason: "OSStatus \(status)")
    }
}
#endif
