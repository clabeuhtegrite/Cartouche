//
//  CartoucheResetPlan.swift
//  Cartouche
//
//  What System › Reset Cartouche erases and keeps (CartoucheReset.swift,
//  decision 99): Cartouche starts again as a new player finds it, the first
//  time it opens after the Cartouche Installer, without the computer.
//
//  Erased: everything the player put into Cartouche, and everything it
//  learned since: the games, with their data folders, which hold their
//  saves, settings and play time, and their keychain items, those of the
//  games uninstalled with their saves kept too; Cartouche's preferences;
//  the storage servers, with their passwords and tokens; the Apple ID the
//  built-in SideStore signed in with, its password and tokens, with
//  SideStore's own preferences and files; the names and covers the player
//  gave their games; the caches; the reports and their journal.
//
//  Kept:
//  - what only a computer gives back: the pairing file, where the built-in
//    SideStore reads it, and the signing certificate, the built-in
//    SideStore's or the player's own. Signing in again without the
//    certificate would end, whenever the account's certificate is not one
//    the app holds, in installing Cartouche again from a computer
//    (app/patches/sidestore/0004);
//  - what Apple knows this iPhone by: the machine Apple's anisette server
//    knows it as, as SideStore's own Sign Out keeps it, so that the next
//    sign-in comes from the same machine; and Apple's limit on sign-ins
//    while it counts (CartoucheSignInPause), which a sign-in before its end
//    would only make last longer;
//  - the telemetry's random number, its switch and the reports not sent
//    yet (Ad, 13 November): the dashboard follows the same copy of
//    Cartouche across a reset. What it knew of the games goes with them;
//  - the folders of the player's storage, even one they picked in
//    Cartouche's own space in Files, with the copies of their games and
//    saves: theirs, not Cartouche's;
//  - in the app group, all but Cartouche's own folder and preferences: the
//    built-in SideStore's database and LiveContainer's preferences, which
//    any SideStore or LiveContainer signed with the same Apple account
//    shares;
//  - what iOS keeps of the app: its signature and profile, the alerts
//    before it expires, its permissions, and its other preferences, such
//    as those of Apple's own frameworks.
//
//  Platform-independent: tested on its own by launcher/Package.swift.
//

import Foundation

/// What resetting Cartouche erases and keeps.
enum CartoucheResetPlan {
    /// The names the built-in SideStore reads a pairing file under, in the
    /// Documents of its home (CartouchePairing.fileNames).
    static let pairingFileNames = ["PairingFile_RemoteRP.plist", "PairingFile_Lockdown.plist", "ALTPairingFile.mobiledevicepairing"]

    /// The built-in SideStore's home, in Cartouche's Documents, where
    /// LiveContainer starts it.
    static let storeHome = "SideStore"

    /// The folders of Cartouche's Documents that hold LiveContainer's and
    /// the built-in SideStore's own: the games, their data folders, the
    /// tweaks, SideStore's home, and what other apps opened Cartouche with.
    static let ownFolders: Set<String> = ["Applications", "Data", storeHome, "Tweaks", "Inbox"]

    /// Cartouche's own folder in the app group (CartoucheRunningGame.swift,
    /// CartoucheGuest.m).
    static let appGroupFolder = "Cartouche"

    /// The telemetry's file, in Cartouche's home (CartoucheTelemetry), which
    /// stays.
    static let telemetryFile = "Library/Application Support/Cartouche/Telemetry.json"

    // MARK: The keychain

    /// The keychain service of Cartouche's storage servers: their settings
    /// and secrets (CartoucheStorageSettings). Every item goes.
    static let storageService = "Cartouche storage"

    /// The built-in SideStore's keychain items that stay, by account: its
    /// certificate, as it keeps it now and as it kept it before 0.6.4, which
    /// it moves by itself; the machine Apple's anisette server knows this
    /// iPhone as, and how Cartouche's SideStore made it (patch 0015); and
    /// the player's own certificate (CartoucheImportedSigning). The Apple
    /// ID, its password and tokens, the iPhone's identifier and whatever
    /// Cartouche and SideStore leave each other go.
    static let keptStoreAccounts: Set<String> = [
        "signingCertificate", "signingCertificatePassword",
        "signingCertificatePrivateKey", "signingCertificateSerialNumber",
        "identifier", "adiPb", "cartoucheAnisette",
        "Cartouche.importedSigning.material",
    ]

    /// The certificates SideStore imported, an item each, under their
    /// serial number.
    static let keptStoreAccountPrefixes = ["importedCert_"]

    /// Whether the built-in SideStore's keychain item of ACCOUNT stays.
    static func keepsStoreItem(account: String) -> Bool {
        keptStoreAccounts.contains(account) || keptStoreAccountPrefixes.contains { account.hasPrefix($0) }
    }

    // MARK: Preferences

    /// Whether KEY, in the app group's preferences, is Cartouche's own. The
    /// others are LiveContainer's, which a LiveContainer signed with the
    /// same Apple account shares, the certificate it signs games with among
    /// them.
    static func isCartouches(appGroupKey key: String) -> Bool {
        key.hasPrefix("Cartouche")
    }

    /// Whether Apple's limit on sign-ins, as Cartouche keeps it in DATA
    /// (CartoucheAccount.pauseKey), stays at NOW: while it counts, a
    /// sign-in would only make it last longer, or the next one.
    static func keepsSignInPause(_ data: Data?, at now: Date) -> Bool {
        guard let data, let pause = try? JSONDecoder().decode(CartoucheSignInPause.self, from: data) else { return false }
        return pause.holds(at: now) || pause.counts(at: now)
    }

    /// Removes KEYS from DEFAULTS, one by one: a UserDefaults that read them
    /// keeps them in memory otherwise, as cfprefsd does, which would hand
    /// them back, or write them again, after their file went.
    static func remove(_ keys: [String], from defaults: UserDefaults) {
        for key in keys {
            defaults.removeObject(forKey: key)
        }
    }

    /// Cartouche's own keys in the app group's preferences, DOMAIN, as
    /// DEFAULTS reads them.
    static func cartouchesKeys(in defaults: UserDefaults, domain: String) -> [String] {
        (defaults.persistentDomain(forName: domain) ?? [:]).keys.filter(isCartouches(appGroupKey:)).sorted()
    }

    /// What the app group's preferences lost of LiveContainer's between
    /// BEFORE and AFTER the built-in SideStore's preferences went, to put
    /// back. SideStore keeps those of the app group's name in its own home,
    /// where LiveContainer puts them, which Cartouche opens as
    /// LiveContainer's own Preferences page does: should cfprefsd take that
    /// name for the app group's own, LiveContainer's would go with them.
    static func lostSharedPreferences(before: [String: Any], after: [String: Any]) -> [String: Any] {
        before.filter { !isCartouches(appGroupKey: $0.key) && after[$0.key] == nil }
    }

    /// The preferences' domains of the built-in SideStore, by the files
    /// cfprefsd keeps them in, in its home: they go through cfprefsd before
    /// their files, or cfprefsd would hand SideStore what it kept of them.
    static func storePreferenceDomains(documents: URL, fileManager: FileManager = .default) -> [String] {
        let names = (try? fileManager.contentsOfDirectory(atPath: storePreferences(documents: documents).path)) ?? []
        return names.filter { $0.hasSuffix(".plist") && $0.count > ".plist".count }
            .map { String($0.dropLast(".plist".count)) }.sorted()
    }

    /// The folder of the built-in SideStore's preferences.
    static func storePreferences(documents: URL) -> URL {
        documents.appendingPathComponent(storeHome, isDirectory: true)
            .appendingPathComponent("Library/Preferences", isDirectory: true)
    }

    /// The keys of the preferences in FILE, as cfprefsd last wrote them.
    static func keys(ofPreferences file: URL) -> [String] {
        guard let data = try? Data(contentsOf: file),
              let values = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else { return [] }
        return values.keys.sorted()
    }

    // MARK: Files

    /// The data folders of Cartouche's games, by name, in its Documents:
    /// each one's keychain items go with it (LCUtils.removeAppKeychain),
    /// those of an uninstalled game whose saves were kept too.
    static func gameDataFolders(documents: URL, fileManager: FileManager = .default) -> [String] {
        let folder = documents.appendingPathComponent("Data/Application", isDirectory: true)
        let names = (try? fileManager.contentsOfDirectory(atPath: folder.path)) ?? []
        return names.filter { isFolder(folder.appendingPathComponent($0), fileManager) }.sorted()
    }

    /// What stays of FOLDER, a folder of the player's storage, in HOME,
    /// Cartouche's home: the folder, with what it holds, wherever the
    /// player picked it, as in Cartouche's own space in Files, On My
    /// iPhone › Cartouche, which is its Documents; for Documents itself,
    /// what it holds but the folders LiveContainer and SideStore keep
    /// their own in, which go whatever they hold. Nothing outside HOME,
    /// which the reset never touches.
    static func keptPlayerItems(_ folder: URL, home: URL, fileManager: FileManager = .default) -> [URL] {
        guard let parts = relativeParts(of: folder, in: home), let root = parts.first,
              erasedFolders.contains(root) else { return [] }
        let rootFolder = home.appendingPathComponent(root, isDirectory: true)
        guard parts.count > 1 else {
            // Library and tmp no picker shows.
            guard root == "Documents" else { return [] }
            let names = (try? fileManager.contentsOfDirectory(atPath: rootFolder.path)) ?? []
            return names.filter { !ownFolders.contains($0) }.sorted().map { rootFolder.appendingPathComponent($0) }
        }
        if root == "Documents", ownFolders.contains(parts[1]) { return [] }
        return [folder]
    }

    /// What stays in HOME, Cartouche's home: the pairing files; the
    /// preferences, which go through cfprefsd (UserDefaults), never by
    /// their files, which cfprefsd would write back; the telemetry's file;
    /// the app group, when it lies in it, as for an install with the
    /// player's own certificate, which has no app group of iOS, but for
    /// Cartouche's own folder there; what stays of the folders of the
    /// player's storage, FOLDERS (keptPlayerItems); and ALSO.
    static func kept(home: URL, appGroup: URL?, playerFolders folders: [URL], also: [URL] = [],
                     fileManager: FileManager = .default) -> [URL] {
        let documents = home.appendingPathComponent("Documents", isDirectory: true)
        let storeDocuments = documents.appendingPathComponent(storeHome, isDirectory: true)
            .appendingPathComponent("Documents", isDirectory: true)
        var kept = pairingFileNames.map { storeDocuments.appendingPathComponent($0) }
        kept.append(home.appendingPathComponent("Library/Preferences", isDirectory: true))
        kept.append(home.appendingPathComponent(telemetryFile))
        if let appGroup, relativeParts(of: appGroup, in: home) != nil {
            kept.append(appGroup)
        }
        kept += folders.flatMap { keptPlayerItems($0, home: home, fileManager: fileManager) }
        kept += also
        return kept
    }

    /// What a reset could not erase.
    struct Failure: Equatable, CustomStringConvertible {
        /// Where, in Cartouche's home or app group: "Documents/Applications".
        let path: String
        let reason: String

        var description: String { path + ": " + reason }
    }

    /// The folders of HOME whose files go, but those KEPT: Documents,
    /// Library and tmp. Never the home itself, where iOS keeps what it
    /// knows of the app's container.
    static let erasedFolders = ["Documents", "Library", "tmp"]

    /// Erases the files of Cartouche's HOME but those KEPT, and the folders
    /// that lead to them, and Cartouche's own folder in APPGROUP. A link is
    /// removed, never followed. What could not go comes back.
    static func eraseFiles(home: URL, appGroup: URL?, keeping kept: [URL],
                           fileManager: FileManager = .default) -> [Failure] {
        let home = home.resolvingSymlinksInPath()
        let keptPaths = Set(kept.map { $0.resolvingSymlinksInPath().standardizedFileURL.path })
        var failures: [Failure] = []

        func remove(_ item: URL, shownAs path: String) {
            do {
                try fileManager.removeItem(at: item)
            } catch {
                // Gone meanwhile, as a file a cache drops: not a failure.
                guard (try? fileManager.attributesOfItem(atPath: item.path)) != nil else { return }
                failures.append(Failure(path: path, reason: describe(error)))
            }
        }

        func erase(_ folder: URL, shownAs shown: String) {
            let names = ((try? fileManager.contentsOfDirectory(atPath: folder.path)) ?? []).sorted()
            for name in names {
                let item = folder.appendingPathComponent(name)
                let path = item.standardizedFileURL.path
                let shownPath = shown + "/" + name
                if keptPaths.contains(path) { continue }
                if keptPaths.contains(where: { $0.hasPrefix(path + "/") }), isFolder(item, fileManager) {
                    erase(item, shownAs: shownPath)
                    continue
                }
                remove(item, shownAs: shownPath)
            }
        }

        for name in erasedFolders {
            let folder = home.appendingPathComponent(name, isDirectory: true)
            guard isFolder(folder, fileManager), !keptPaths.contains(folder.standardizedFileURL.path) else { continue }
            erase(folder, shownAs: name)
        }
        if let appGroup {
            let own = appGroup.appendingPathComponent(appGroupFolder, isDirectory: true)
            if (try? fileManager.attributesOfItem(atPath: own.path)) != nil {
                remove(own, shownAs: "AppGroup/" + appGroupFolder)
            }
        }
        return failures
    }

    // MARK: Helpers

    /// Whether ITEM is a folder, not a link to one.
    private static func isFolder(_ item: URL, _ fileManager: FileManager) -> Bool {
        (try? fileManager.attributesOfItem(atPath: item.path))?[.type] as? FileAttributeType == .typeDirectory
    }

    /// The parts of ITEM's path under FOLDER, both read through their links,
    /// as /var and /private/var on an iPhone: nil when ITEM is not under it,
    /// or is FOLDER itself.
    static func relativeParts(of item: URL, in folder: URL) -> [String]? {
        let itemPath = item.resolvingSymlinksInPath().standardizedFileURL.path
        let folderPath = folder.resolvingSymlinksInPath().standardizedFileURL.path
        guard itemPath.hasPrefix(folderPath + "/") else { return nil }
        let parts = itemPath.dropFirst(folderPath.count + 1).split(separator: "/").map(String.init)
        return parts.isEmpty ? nil : parts
    }

    /// An error as its domain and code, never its words, which may name the
    /// player's files.
    private static func describe(_ error: Error) -> String {
        let error = error as NSError
        return "\(error.domain) \(error.code)"
    }
}
