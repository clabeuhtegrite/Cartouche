//
//  ResetTests.swift
//  CartoucheHarnessTests
//
//  System › Reset Cartouche (CartoucheReset, decision 97), on a Cartouche
//  a player has used: a game installed, the data folder of one uninstalled
//  with its saves kept, their storage, a folder of it in Cartouche's own
//  space in Files and a server with its password, the Apple ID the
//  built-in SideStore signed in with, its preferences and files, the
//  pairing file, Cartouche's preferences and LiveContainer's in the app
//  group, the caches, the journal and a report. The reset erases what the
//  player put into Cartouche and what it learned since, keeps the
//  certificate, the pairing file, what Apple knows the iPhone by, the
//  telemetry's number and the player's folders with what they hold, then
//  starts Cartouche again on its console (HarnessLC.launches). It waits
//  for a game or an install under way, and names the games whose saves
//  are here alone, which go to the saves folder first if the player asks,
//  and come back from there with the games.
//

import Security
import XCTest
@testable import CartoucheHarness

final class ResetTests: HarnessCase {
    private var reset: CartoucheReset { CartoucheReset.shared }
    private var telemetry: CartoucheTelemetry { CartoucheTelemetry.shared }
    private var fileManager: FileManager { FileManager.default }
    /// Cartouche's home, its app's container.
    private var home: URL { URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true) }
    /// The built-in SideStore's home, where LiveContainer starts it.
    private var storeHome: URL { LCPath.docPath.appendingPathComponent(CartoucheResetPlan.storeHome, isDirectory: true) }

    /// The built-in SideStore's keychain items once it signed in, beside
    /// its certificate: the Apple ID and what goes with it, and what Apple
    /// knows this iPhone by, which stays.
    private let signedIn = [
        "appleIDEmailAddress": "player@example.com", "appleIDPassword": "harness-password",
        "appleIDAdsid": "000000-00-harness", "deviceUDID": "00008150-HARNESS",
        "identifier": "harness-machine", "adiPb": "harness-provisioning", "cartoucheAnisette": "harness-anisette",
    ]
    private let keptMachine = ["identifier", "adiPb", "cartoucheAnisette"]

    override func setUp() async throws {
        try await super.setUp()
        // Nothing waiting, and the telemetry's server takes what comes.
        telemetry.setOn(false)
        telemetry.setOn(true)
        HarnessNetwork.answer { request in
            request.url.host == "telemetry.harness.invalid" ? HarnessNetwork.Answer(status: 200) : nil
        }
    }

    override func tearDown() async throws {
        // What the next test's setup does not take back.
        for account in Array(signedIn.keys) + ["appleIDXcodeToken"] {
            CartoucheStoreKeychain.remove(account)
        }
        UserDefaults.standard.removeObject(forKey: CartoucheAccount.pauseKey)
        try await super.tearDown()
    }

    // MARK: Helpers

    /// Resets Cartouche as the player does once they said so twice, and
    /// waits until it has started again.
    private func resetCartouche(file: StaticString = #filePath, line: UInt = #line) async throws {
        try await waitUntil("nothing holds the reset back", file: file, line: line) { reset.blocker == nil }
        let launches = HarnessLC.launches.count
        reset.reset()
        XCTAssertEqual(reset.phase, .erasing, "the page says so at once", file: file, line: line)
        try await waitUntil("the reset is over", file: file, line: line) { reset.phase == nil }
        XCTAssertNil(reset.report, "everything went: " + (reset.report.map { CartoucheReports.text(of: $0) } ?? ""),
                     file: file, line: line)
        XCTAssertEqual(HarnessLC.launches.count, launches + 1, "Cartouche starts again", file: file, line: line)
    }

    /// A folder the player picked for their storage, at PATH in Cartouche's
    /// home, as Files shows Cartouche's own space, its Documents: the place
    /// for ROLES.
    private func picked(_ path: String, for roles: [CartoucheStorageRole]) throws -> URL {
        let url = home.appendingPathComponent(path, isDirectory: true)
        try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
        var server = CartoucheStorageServer(kind: .folder, name: url.lastPathComponent)
        server.bookmark = try CartoucheFolder.bookmark(of: url)
        let settings = CartoucheStorageSettings.shared
        settings.save(server, secret: nil)
        for role in roles {
            settings.setPlace(CartoucheStoragePlace(server: server.id, path: ""), for: role)
        }
        return url
    }

    /// Leaves TEXT for the built-in SideStore under ACCOUNT as it keeps its
    /// own items, synced through iCloud: whether the Simulator took it.
    private func storeSyncedItem(_ text: String, for account: String) -> Bool {
        guard let service = CartoucheStoreKeychain.service else { return false }
        CartoucheStoreKeychain.remove(account)
        let item: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: true,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
            kSecValueData as String: Data(text.utf8),
        ]
        return SecItemAdd(item as CFDictionary, nil) == errSecSuccess
    }

    /// The last report named NAME the telemetry's server got, as JSON.
    private func report(named name: String) -> [String: Any]? {
        HarnessNetwork.requests.filter { $0.url.path == "/v1/reports" }.flatMap { request -> [[String: Any]] in
            let body = (try? JSONSerialization.jsonObject(with: request.body)) as? [String: Any]
            return body?["reports"] as? [[String: Any]] ?? []
        }.last { $0["name"] as? String == name }
    }

    /// The report named NAME, once the telemetry's server got it.
    private func measurement(named name: String, file: StaticString = #filePath,
                             line: UInt = #line) async throws -> [String: Any] {
        try await waitUntil("the measurement left", file: file, line: line) { report(named: name) != nil }
        return try XCTUnwrap(report(named: name), file: file, line: line)
    }

    /// The copies of GAME's saves in the saves folder FOLDER.
    private func copies(of game: HarnessGame, in folder: URL) -> [URL] {
        let gameFolder = folder.appendingPathComponent(CartoucheStoragePath.fileName(game.name) + " [\(game.titleId)]")
        let found = (try? fileManager.contentsOfDirectory(at: gameFolder, includingPropertiesForKeys: nil)) ?? []
        return found.filter { $0.pathExtension == "zip" }
    }

    private func samePath(_ one: URL, _ other: URL) -> Bool {
        one.resolvingSymlinksInPath().standardizedFileURL.path == other.resolvingSymlinksInPath().standardizedFileURL.path
    }

    // MARK: Erasing

    func testAResetErasesWhatThePlayerPutInCartoucheAndKeepsWhatOnlyAComputerGivesBack() async throws {
        let documents = LCPath.docPath
        let library = home.appendingPathComponent("Library", isDirectory: true)
        // Where the reset looks is where Cartouche keeps them.
        XCTAssertEqual(CartouchePairing.fileNames, CartoucheResetPlan.pairingFileNames)
        XCTAssertTrue(samePath(CartouchePairing.storeDocuments, storeHome.appendingPathComponent("Documents")))
        XCTAssertTrue(samePath(CartoucheTelemetry.file, home.appendingPathComponent(CartoucheResetPlan.telemetryFile)))
        let memoryFile = try XCTUnwrap(CartoucheGameMemoryReading.file)
        XCTAssertTrue(samePath(memoryFile.deletingLastPathComponent(),
                               HarnessLC.appGroup.appendingPathComponent(CartoucheResetPlan.appGroupFolder)))

        // The telemetry's number, which stays.
        telemetry.event("harness.before")
        try await waitUntil("the server took it") { report(named: "harness.before") != nil && telemetry.waiting == 0 }
        let number = try XCTUnwrap(report(named: "harness.before")?["install"] as? String)

        // A game, the data folder of one uninstalled with its saves kept,
        // what another app opened Cartouche with, and a file the player put
        // in Cartouche's own space in Files.
        let app = try await installed(HarnessGame.plain(7))
        let gameBundle = try bundle(of: app)
        let uninstalled = UUID().uuidString
        try write("progress", in: LCPath.dataPath, at: uninstalled + "/Documents/save/0000000000000001/progress.bin")
        try write("ipa", in: documents, at: "Inbox/Game.ipa")
        try write("notes", in: documents, at: "notes.txt")

        // Their storage: the games folder, the saves folder in Cartouche's
        // own space in Files, and a server with its password.
        let (_, gamesFolder) = try HarnessStorage.folder("Jeux", for: [.games])
        try write("notes", in: gamesFolder, at: "Notes.txt")
        let savesFolder = try picked("Documents/Mes sauvegardes", for: [.saves])
        try write("zip", in: savesFolder, at: "Game [0100000000000000]/2026-11-13 18.00.00.zip")
        var nas = CartoucheStorageServer(kind: .smb, name: "NAS")
        nas.host = "nas.harness.invalid"
        nas.username = "player"
        nas.share = "Jeux"
        let storage = CartoucheStorageSettings.shared
        storage.save(nas, secret: "harness-password")
        XCTAssertEqual(storage.secret(of: nas), "harness-password")
        XCTAssertTrue(CartoucheResetKeychain.accounts(of: CartoucheResetPlan.storageService).contains(nas.id.uuidString),
                      "the storage's keychain service, as CartoucheStorageSettings names it")

        // The built-in SideStore signed in, with its certificate, the
        // pairing file, its files, and its preferences as cfprefsd keeps
        // them once it ran: its own, and those of the app group's name,
        // which LiveContainer keeps in its home too.
        XCTAssertTrue(CartoucheStoreKeychain.set(certificate.data, for: "signingCertificate"))
        XCTAssertTrue(CartoucheStoreKeychain.set(Data(certificate.password.utf8), for: "signingCertificatePassword"))
        for (account, text) in signedIn {
            XCTAssertTrue(CartoucheStoreKeychain.set(Data(text.utf8), for: account), account)
        }
        let synced = storeSyncedItem("harness-token", for: "appleIDXcodeToken")
        CartoucheSetup.shared.refresh()
        XCTAssertEqual(CartoucheSetup.shared.appleID, "player@example.com")
        let pairing = CartouchePairing.storeDocuments.appendingPathComponent(CartouchePairing.importName)
        try write("pairing", in: CartouchePairing.storeDocuments, at: CartouchePairing.importName)
        try write("log", in: storeHome, at: "Documents/Logs/SideStore.log")
        try write("database", in: storeHome, at: "Library/Application Support/SideStore/Apps.sqlite")
        let storePreferences = CartoucheResetPlan.storePreferences(documents: documents)
        try fileManager.createDirectory(at: storePreferences, withIntermediateDirectories: true)
        let storeDomain = "com.SideStore.SideStore"
        let storeFile = storePreferences.appendingPathComponent(storeDomain + ".plist")
        let groupFile = storePreferences.appendingPathComponent(HarnessLC.appGroupID + ".plist")
        try HarnessIPA.plist(["SideStoreKey": "store"]).write(to: storeFile)
        try HarnessIPA.plist(["LCGuestURLSchemes": ["store"], "SideStoreGroupKey": "group"]).write(to: groupFile)
        let store = try XCTUnwrap(CartoucheGamePreferences(domain: storeDomain, home: storeHome))
        store.set("store", forKey: "SideStoreKey")
        XCTAssertEqual(store.string(forKey: "SideStoreKey"), "store")

        // Cartouche's preferences, the game it would start, and Apple's
        // limit on sign-ins, which counts; LiveContainer's in the app group,
        // Cartouche's own there, and its folder there.
        let defaults = UserDefaults.standard
        defaults.set(true, forKey: "CartoucheHarnessSetting")
        defaults.set(gameBundle.lastPathComponent, forKey: "selected")
        defaults.set(uninstalled, forKey: "selectedContainer")
        let pause = CartoucheSignInPause(until: Date().addingTimeInterval(15 * 60), inARow: 1, last: Date())
        let pauseData = try JSONEncoder().encode(pause)
        defaults.set(pauseData, forKey: CartoucheAccount.pauseKey)
        let shared = UserDefaults.lcShared()
        shared.set(["mkw"], forKey: "LCGuestURLSchemes")
        LCUtils.appGroupUserDefault.set(true, forKey: "CartoucheHarnessFlag")
        try write("memory", in: memoryFile.deletingLastPathComponent(), at: memoryFile.lastPathComponent)
        try write("database", in: HarnessLC.appGroup, at: "Database/SideStore.sqlite")

        // The caches, what Cartouche learned of the games, the journal and
        // a report.
        try write("cache", in: library, at: "Caches/Harness/cover.jpg")
        try write("cover", in: library, at: "Application Support/Cartouche/Covers/cover.jpg")
        try write("part", in: fileManager.temporaryDirectory, at: "Harness/part")
        CartoucheReports.note("Harness: before the reset")
        _ = CartoucheReports.make(.reset, "Harness", message: "before the reset")
        XCTAssertFalse(CartoucheReports.recent.isEmpty)

        await reset.checkSaves(of: model.apps)
        XCTAssertEqual(reset.savesAtRisk, [], "no game played here yet")
        try await resetCartouche()

        // Cartouche starts again on its console, no game chosen.
        XCTAssertEqual(HarnessLC.launches.last, HarnessLC.Launch(bundle: nil, container: nil, classicMode: 0))
        XCTAssertNil(reset.savesAtRisk)

        // The games go, with their data folders, the saves of the game
        // uninstalled among them, and their keychain items; what other apps
        // opened Cartouche with, and what the player put in its space.
        XCTAssertFalse(fileManager.fileExists(atPath: gameBundle.path), "the game goes")
        XCTAssertFalse(exists(documents, "Applications"))
        XCTAssertFalse(exists(documents, "Data"))
        XCTAssertTrue(HarnessLC.removedKeychains.contains(uninstalled))
        XCTAssertFalse(exists(documents, "Inbox"))
        XCTAssertFalse(exists(documents, "notes.txt"))

        // The storage goes, with its passwords; the player's folders stay,
        // with what they hold, even in Cartouche's own space in Files.
        XCTAssertTrue(storage.servers.isEmpty)
        XCTAssertNil(storage.place(.games))
        XCTAssertNil(storage.place(.saves))
        XCTAssertEqual(CartoucheResetKeychain.accounts(of: CartoucheResetPlan.storageService), [])
        XCTAssertTrue(exists(gamesFolder, "Notes.txt"))
        XCTAssertTrue(exists(savesFolder, "Game [0100000000000000]/2026-11-13 18.00.00.zip"))

        // The Apple ID goes, with what went with it; the certificate, what
        // Apple knows this iPhone by and the pairing file stay. SideStore's
        // files and preferences go, through cfprefsd.
        for account in ["appleIDEmailAddress", "appleIDPassword", "appleIDAdsid", "deviceUDID"] {
            XCTAssertNil(CartoucheStoreKeychain.data(account), account)
        }
        if synced {
            XCTAssertNil(CartoucheStoreKeychain.data("appleIDXcodeToken"), "synced through iCloud or not")
        }
        XCTAssertEqual(CartoucheStoreKeychain.data("signingCertificate"), certificate.data)
        XCTAssertEqual(CartoucheStoreKeychain.string("signingCertificatePassword"), certificate.password)
        for account in keptMachine {
            XCTAssertEqual(CartoucheStoreKeychain.string(account), signedIn[account], account)
        }
        let storeService = try XCTUnwrap(CartoucheStoreKeychain.service)
        let left = CartoucheResetKeychain.accounts(of: storeService)
        XCTAssertTrue(left.allSatisfy(CartoucheResetPlan.keepsStoreItem(account:)), "\(left)")
        XCTAssertEqual(try? Data(contentsOf: pairing), Data("pairing".utf8), "the pairing file stays")
        XCTAssertFalse(exists(storeHome, "Documents/Logs"))
        XCTAssertFalse(exists(storeHome, "Library/Application Support"))
        XCTAssertEqual(CartoucheResetPlan.keys(ofPreferences: storeFile), [])
        XCTAssertEqual(CartoucheResetPlan.keys(ofPreferences: groupFile), [])
        XCTAssertNil(CartoucheGamePreferences(domain: storeDomain, home: storeHome)?.string(forKey: "SideStoreKey"),
                     "nor does cfprefsd hand them back")

        // Cartouche's preferences go, but Apple's limit on sign-ins while it
        // counts; LiveContainer's stay in the app group, its certificate
        // among them, and Cartouche's own go, with its folder there.
        XCTAssertNil(defaults.object(forKey: "CartoucheHarnessSetting"))
        XCTAssertNil(defaults.string(forKey: "selected"))
        let keptPause = try XCTUnwrap(defaults.data(forKey: CartoucheAccount.pauseKey))
        XCTAssertEqual(try JSONDecoder().decode(CartoucheSignInPause.self, from: keptPause), pause)
        XCTAssertEqual(shared.data(forKey: "LCCertificateData"), certificate.data)
        XCTAssertEqual(shared.stringArray(forKey: "LCGuestURLSchemes"), ["mkw"])
        XCTAssertNil(LCUtils.appGroupUserDefault.object(forKey: "CartoucheHarnessFlag"))
        XCTAssertNil(shared.object(forKey: "CartoucheHarnessFlag"))
        XCTAssertFalse(exists(HarnessLC.appGroup, CartoucheResetPlan.appGroupFolder))
        XCTAssertTrue(exists(HarnessLC.appGroup, "Database/SideStore.sqlite"))

        // The caches and what Cartouche learned go; the telemetry's file
        // stays, and the harness's standard error.
        XCTAssertFalse(exists(library, "Caches/Harness"))
        XCTAssertFalse(exists(library, "Application Support/Cartouche/Covers"))
        XCTAssertFalse(exists(fileManager.temporaryDirectory, "Harness"))
        XCTAssertTrue(fileManager.fileExists(atPath: CartoucheTelemetry.file.path))
        XCTAssertTrue(fileManager.fileExists(atPath: HarnessStandardError.file.path))

        // The journal starts again from the reset, without the reports.
        let journal = CartoucheReports.journal(last: CartoucheReports.journalShown)
        XCTAssertFalse(journal.contains { $0.contains("Harness: before the reset") }, journal.joined(separator: "\n"))
        XCTAssertTrue(journal.contains { $0.contains("Reset: Cartouche erased: 1 games, 3 storage places, the Apple ID; 0 items left") },
                      journal.joined(separator: "\n"))
        XCTAssertTrue(CartoucheReports.recent.isEmpty)

        // The telemetry's number stays: the dashboard follows this copy of
        // Cartouche across the reset, which it measures, never with the
        // Apple ID.
        let measured = try await measurement(named: "app.reset")
        XCTAssertEqual(measured["install"] as? String, number)
        let fields = try XCTUnwrap(measured["fields"] as? [String: Any])
        XCTAssertEqual(fields["games"] as? Double, 1)
        XCTAssertEqual(fields["storages"] as? Double, 3)
        XCTAssertEqual(fields["signedIn"] as? Bool, true)
        XCTAssertEqual(fields["savesLost"] as? Double, 0)
        XCTAssertEqual(fields["failures"] as? Double, 0)
        XCTAssertNotNil(fields["seconds"] as? Double)
        for request in HarnessNetwork.requests {
            XCTAssertFalse(String(decoding: request.body, as: UTF8.self).contains("player@example.com"))
        }

        // The setup asks for the Apple ID again, and only for it.
        CartoucheSetup.shared.refresh()
        XCTAssertNil(CartoucheSetup.shared.appleID)
        XCTAssertTrue(CartoucheSetup.shared.hasCertificate)
        XCTAssertTrue(CartoucheSetup.shared.hasPairingFile)
        // LiveContainer finds no game as Cartouche starts again.
        HarnessLC.loadApps()
        XCTAssertTrue(model.apps.isEmpty)
    }

    func testNothingIsErasedWhileAGamePlaysOrInstalls() async throws {
        let (app, _) = try await started(HarnessGame.plain(9))
        let gameBundle = try bundle(of: app)
        let launches = HarnessLC.launches.count
        XCTAssertEqual(reset.blocker, CartoucheText.resetWhilePlaying(app.displayName))
        reset.reset()
        XCTAssertNil(reset.phase, "the reset waits for the game")
        try await pause(0.3)
        XCTAssertTrue(fileManager.fileExists(atPath: gameBundle.path))
        XCTAssertEqual(HarnessLC.launches.count, launches)
        actions.quitRunningGame()
        try await waitUntil("the game has ended") { actions.running == nil && actions.work == nil }

        // Nor while a game installs.
        actions.installed = nil
        actions.install(try HarnessIPA.game(HarnessGame.plain(10)))
        let work = try XCTUnwrap(actions.work, "the install shows over the console at once")
        XCTAssertEqual(reset.blocker, CartoucheText.resetBusy(work.title))
        reset.reset()
        XCTAssertNil(reset.phase, "the reset waits for the install")
        try await waitUntil("the install is over") { actions.work == nil }
        XCTAssertNotNil(actions.installed, "the install went on")
        XCTAssertTrue(fileManager.fileExists(atPath: gameBundle.path))
        XCTAssertNil(reset.blocker)
    }

    // MARK: The saves

    func testTheSavesHereAloneAreNamedAndGoToTheSavesFolderFirstWhenThePlayerAsks() async throws {
        let game = HarnessGame.plain(8)
        // Played without a saves folder: its saves are here alone.
        let (app, _) = try await started(game)
        let documents = try dataFolder(of: app).appendingPathComponent("Documents", isDirectory: true)
        let save = Data((0..<4096).map { UInt8(truncatingIfNeeded: $0 &* 11) })
        try fileManager.createDirectory(at: documents.appendingPathComponent("save/0000000000000001"),
                                        withIntermediateDirectories: true)
        try save.write(to: documents.appendingPathComponent("save/0000000000000001/progress.bin"))
        actions.quitRunningGame()
        try await waitUntil("the game has ended") { actions.running == nil && actions.work == nil }
        await reset.checkSaves(of: model.apps)
        XCTAssertEqual(reset.savesAtRisk, [game.name])

        // A saves folder alone does not hold them yet; sent there, they are.
        let (_, saves) = try HarnessStorage.folder("Sauvegardes", for: [.saves])
        await reset.checkSaves(of: model.apps)
        XCTAssertEqual(reset.savesAtRisk, [game.name], "not in the saves folder yet")
        await reset.sendSavesAtRisk(of: model.apps)
        XCTAssertFalse(reset.isSendingSaves)
        XCTAssertEqual(reset.savesAtRisk, [])
        XCTAssertEqual(copies(of: game, in: saves).count, 1)
        await CartoucheSaveBackups.shared.finish()

        // The reset erases them here, and leaves them there.
        try await resetCartouche()
        XCTAssertFalse(fileManager.fileExists(atPath: documents.path))
        XCTAssertEqual(copies(of: game, in: saves).count, 1, "the saves folder keeps them")
        let measured = try await measurement(named: "app.reset")
        let fields = try XCTUnwrap(measured["fields"] as? [String: Any])
        XCTAssertEqual(fields["savesLost"] as? Double, 0)

        // As the page says: the saves folder added again, they come back
        // with the game.
        HarnessLC.loadApps()
        XCTAssertTrue(model.apps.isEmpty)
        _ = try HarnessStorage.folder("Sauvegardes", for: [.saves])
        let again = try await installed(game)
        let back = try dataFolder(of: again).appendingPathComponent("Documents/save/0000000000000001/progress.bin")
        XCTAssertTrue((try? Data(contentsOf: back)) == save, "the saves came back")
    }
}
