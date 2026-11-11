//
//  StorageServerTests.swift
//  CartoucheStorageTests
//
//  What Cartouche does with the player's storage, against real servers:
//  each case (SMBTests, S3Tests, FTPTests, FTPListTests, SFTPTests) runs
//  these tests on its own server, through the CartoucheRemote the app signs
//  in to, and adds what only its protocol has. The steps are the app's: the
//  library lists the games folder and reads each IPA's Info.plist where it
//  sits, Install from unpacks an IPA in one pass from the server, Copy to
//  writes the installed game back as an IPA, the saves of two iPhones are
//  kept in step through the saves folder (CartoucheSavesFolder), and
//  Cartouche asks where the account can write. The IPAs are made-up apps
//  (make_ipas.py), one past 4 GiB, as games are.
//

import Darwin
import Foundation
import XCTest
@testable import CartoucheStorage

class StorageServerTests: XCTestCase {
    // MARK: What each case gives

    /// The server, as the tests name it; nil for this base, whose tests are
    /// skipped.
    class var serverName: String? { nil }

    /// Signs in with the player's account.
    func connect() async throws -> CartoucheRemote {
        throw XCTSkip("the base of the server cases")
    }

    /// Signs in with a wrong password, or wrong keys, which must fail.
    func connectWithAWrongPassword() async throws -> CartoucheRemote {
        throw XCTSkip("the base of the server cases")
    }

    /// A place where the player's account can only read, signed in to, and
    /// its folder, which holds the small IPA.
    func readOnlyPlace() async throws -> (CartoucheRemote, String) {
        throw XCTSkip("the base of the server cases")
    }

    /// The account's root on this Mac, to look for what Cartouche must have
    /// removed; nil when the test cannot look there.
    var rootPath: String? { nil }

    /// Whether the server's listings give each file's time, as all but
    /// FTP's LIST do.
    var listsTimes: Bool { true }

    /// Whether signing out cuts the connection a file is read on, as a
    /// dropped Wi-Fi would: not with FTP, which reads each file on a control
    /// connection of its own, nor with S3, whose requests stand alone.
    var signingOutCutsReads: Bool { true }

    // MARK: Setting up

    var servers: StorageServers!
    var fixtures: StorageFixtures!
    private var remotes: [CartoucheRemote] = []
    private var scratch: [String] = []
    private var localFolders: [URL] = []

    override func setUp() async throws {
        guard Self.serverName != nil else { throw XCTSkip("the base of the server cases") }
        guard let servers = StorageServers.shared else {
            throw XCTSkip("no servers: CARTOUCHE_STORAGE_SERVERS names none (servers.sh writes it)")
        }
        self.servers = servers
        fixtures = try StorageFixtures.load(servers)
    }

    override func tearDown() async throws {
        guard Self.serverName != nil, servers != nil else { return }
        // Signed out first: SMB does not remove a file a reader still holds
        // open, and signing out closes what the test left open.
        for remote in remotes {
            await remote.disconnect()
        }
        remotes = []
        if !scratch.isEmpty, let remote = try? await connect() {
            for folder in scratch.reversed() {
                await removeAll(folder, in: remote)
            }
            await remote.disconnect()
        }
        for folder in localFolders {
            try? FileManager.default.removeItem(at: folder)
        }
    }

    /// Signs in, and signs out after the test.
    func signIn() async throws -> CartoucheRemote {
        track(try await connect())
    }

    @discardableResult
    func track(_ remote: CartoucheRemote) -> CartoucheRemote {
        remotes.append(remote)
        return remote
    }

    /// A new folder on the server, removed after the test.
    func scratchFolder(_ remote: CartoucheRemote) async throws -> String {
        let folder = CartoucheStoragePath.join("Essais", UUID().uuidString)
        try await remote.makeFolders(folder)
        scratch.append(folder)
        return folder
    }

    /// A new folder on this Mac, removed after the test.
    func localFolder() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("CartoucheStorageTests-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        localFolders.append(url)
        return url
    }

    /// Preferences of their own, for what Cartouche keeps of the places.
    func settings() -> CartoucheStorageSettings {
        let suite = "CartoucheStorageTests-" + UUID().uuidString
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: suite) }
        return CartoucheStorageSettings(defaults: UserDefaults(suiteName: suite) ?? .standard)
    }

    /// Removes PATH and what is in it, a file at a time.
    func removeAll(_ path: String, in remote: CartoucheRemote) async {
        if let items = try? await remote.list(path) {
            for item in items {
                let inside = CartoucheStoragePath.join(path, item.name)
                if item.isFolder {
                    await removeAll(inside, in: remote)
                } else {
                    try? await remote.delete(inside)
                }
            }
        }
        try? await remote.delete(path)
    }

    /// The server, as the tests print it (XCTestCase has a name of its own).
    var label: String { Self.serverName ?? "?" }

    // MARK: Checking

    /// Whether ROOT holds the app FIXTURE was packed from, as it was.
    func checkInstalled(_ root: URL, _ fixture: StorageFixtures.Fixture,
                        file: StaticString = #filePath, line: UInt = #line) throws {
        let app = root.appendingPathComponent(fixture.bundle)
        let manager = FileManager.default
        for (path, expected) in fixture.files.sorted(by: { $0.key < $1.key }) {
            let url = app.appendingPathComponent(path)
            if let target = expected.link {
                XCTAssertEqual(try manager.destinationOfSymbolicLink(atPath: url.path), target, path, file: file, line: line)
            } else if expected.folder == true {
                var isFolder: ObjCBool = false
                XCTAssertTrue(manager.fileExists(atPath: url.path, isDirectory: &isFolder) && isFolder.boolValue,
                              "\(path) is not a folder", file: file, line: line)
            } else {
                let attributes = try manager.attributesOfItem(atPath: url.path)
                XCTAssertEqual((attributes[.size] as? NSNumber)?.uint64Value, expected.size, path, file: file, line: line)
                if let digest = expected.sha256 {
                    XCTAssertEqual(try sha256(file: url), digest, "\(path) is not as it was", file: file, line: line)
                }
                if let mode = expected.mode {
                    let found = (attributes[.posixPermissions] as? NSNumber)?.uint32Value ?? 0
                    XCTAssertEqual(found & 0o111 != 0, mode & 0o111 != 0, "\(path): executable or not", file: file, line: line)
                }
            }
        }
        let found = Set(manager.subpaths(atPath: app.path) ?? [])
        XCTAssertEqual(found, Set(fixture.files.keys), "what the app holds", file: file, line: line)
    }

    /// Writes the app at APP to UPLOAD as an IPA, under TOP, as Copy to
    /// writes an installed game (CartoucheGameActions.export): its folders,
    /// links and files in the order of their names. Gives the IPA's size.
    func writeIPA(from app: URL, as top: String, to upload: CartoucheRemoteUpload) async throws -> UInt64 {
        let manager = FileManager.default
        var items: [(name: String, url: URL)] = [(top + "/", app)]
        let walker = try XCTUnwrap(manager.enumerator(atPath: app.path))
        while let relative = walker.nextObject() as? String {
            items.append((top + "/" + relative, app.appendingPathComponent(relative)))
        }
        let writer = CartoucheZipWriter(sink: upload)
        for item in items.sorted(by: { $0.name < $1.name }) {
            var info = stat()
            guard lstat(item.url.path, &info) == 0 else { throw CartoucheStorageError("cannot read \(item.url.path)") }
            let mode = UInt32(info.st_mode & 0o7777)
            switch info.st_mode & S_IFMT {
            case S_IFDIR:
                try await writer.addFolder(item.name.hasSuffix("/") ? item.name : item.name + "/", mode: mode)
            case S_IFLNK:
                try await writer.addSymlink(item.name, target: try manager.destinationOfSymbolicLink(atPath: item.url.path))
            case S_IFREG:
                try await writer.addFile(item.name, from: item.url, mode: mode)
            default:
                continue
            }
        }
        try await writer.finish()
        return writer.written
    }

    /// The IPA at PATH, opened as Install from opens it
    /// (CartoucheGameActions), but with no second try: a read that fails
    /// here fails the test.
    func openAsInstallDoes(_ path: String, from remote: CartoucheRemote) async throws -> CartoucheResumingSource {
        try await CartoucheResumingSource.open(pauses: []) {
            CartoucheResumingSource.Opened(source: try await remote.open(path), close: {})
        }
    }

    /// Unpacks the IPA at PATH, as Install from does, and gives the folder.
    func install(_ path: String, from remote: CartoucheRemote) async throws -> URL {
        let source = try await openAsInstallDoes(path, from: remote)
        let entries = try await CartoucheZip.entries(of: source)
        let into = try localFolder()
        let progress = Progress()
        try await CartoucheZip.extract(source, entries: entries, into: into, progress: progress)
        XCTAssertEqual(progress.completedUnitCount, progress.totalUnitCount)
        return into
    }

    // MARK: Signing in

    func testSignsIn() async throws {
        let remote = try await signIn()
        XCTAssertFalse(remote.isReadOnly)
        let items = try await remote.list("")
        XCTAssertTrue(items.contains { $0.name == servers.games && $0.isFolder }, "\(items.map(\.name))")
    }

    func testRefusesAWrongPassword() async {
        let started = Date()
        let error = await thrownError {
            let remote = try await self.connectWithAWrongPassword()
            await remote.disconnect()
        }
        let waited = Date().timeIntervalSince(started)
        XCTAssertNotNil(error, "signed in with a wrong password")
        if let error {
            print("\(label), a wrong password: \(error.localizedDescription), in \(String(format: "%.1f", waited)) s")
        }
        // The player waits on it: as soon as the server says no, not when
        // it gives up on the connection.
        XCTAssertLessThan(waited, 20, "a wrong password took \(Int(waited)) s to fail")
    }

    // MARK: The games folder, as the library reads it

    func testListsTheGamesFolder() async throws {
        let remote = try await signIn()
        let items = try await remote.list(servers.games)
        let byName = Dictionary(items.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
        let small = try XCTUnwrap(byName[servers.smallName], "\(items.map(\.name))")
        XCTAssertFalse(small.isFolder)
        XCTAssertEqual(small.size, fixtures.small.size)
        if listsTimes {
            XCTAssertNotNil(small.modified)
        }
        if let bigName = servers.bigName, let big = fixtures.big {
            XCTAssertEqual(byName[bigName]?.size, big.size)
        }
        XCTAssertEqual(byName[servers.olderFolder]?.isFolder, true)
        XCTAssertFalse(items.contains { $0.name.hasPrefix(".") }, "a hidden file is listed: \(items.map(\.name))")
        // One level down, as the library reads it too.
        let older = try await remote.list(CartoucheStoragePath.join(servers.games, servers.olderFolder))
        XCTAssertEqual(older.map(\.name), [servers.smallName])
        XCTAssertEqual(older.first?.size, fixtures.small.size)
    }

    func testReadsAGamesInfoPlistWhereItSits() async throws {
        let remote = try await signIn()
        let source = try await remote.open(CartoucheStoragePath.join(servers.games, servers.smallName))
        XCTAssertEqual(source.size, fixtures.small.size)
        let entries = try await CartoucheZip.entries(of: source)
        XCTAssertEqual(entries.map(\.name), fixtures.small.entries.map(\.name))
        XCTAssertEqual(entries.map(\.localHeaderOffset), fixtures.small.entries.map(\.offset))
        // Which game, and which build of it, the IPA is (CartoucheStoredGames).
        let entry = try XCTUnwrap(entries.first { $0.name == fixtures.small.bundle + "/Info.plist" })
        let data = try await CartoucheZip.data(of: entry, in: source, limit: 4 << 20)
        let info = try XCTUnwrap(try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        XCTAssertEqual(info["CFBundleIdentifier"] as? String, fixtures.small.info["CFBundleIdentifier"])
        let build = CartoucheGameBuild(info: info, builtAt: entry.modified)
        XCTAssertEqual(build.version, fixtures.small.info["CFBundleShortVersionString"])
        XCTAssertEqual(build.commit, fixtures.small.info["DMCommit"])
        XCTAssertNotNil(build.builtAt)
    }

    // MARK: Install from, and Copy to

    func testInstallsAGameFromTheFolder() async throws {
        let remote = try await signIn()
        let started = Date()
        let installed = try await install(CartoucheStoragePath.join(servers.games, servers.smallName), from: remote)
        print("\(label): installed \(megabytes(Int64(fixtures.small.size))) in \(String(format: "%.2f", Date().timeIntervalSince(started))) s")
        try checkInstalled(installed, fixtures.small)
    }

    /// The Wi-Fi drops, or the NAS restarts, while a game comes over:
    /// Install from connects again and reads on from where it stopped
    /// (CartoucheResumingSource).
    func testInstallReadsOnAfterTheConnectionIsLost() async throws {
        guard signingOutCutsReads else { throw XCTSkip("\(label): signing out cuts no read under way") }
        let path = CartoucheStoragePath.join(servers.games, servers.smallName)
        let connections = Connections()
        let third = fixtures.small.size / 3
        let source = try await CartoucheResumingSource.open(pauses: [100_000_000, 500_000_000, 2_000_000_000]) {
            let remote = try await self.connect()
            connections.made.append(remote)
            let file = try await remote.open(path)
            // The first connection goes once a third of the IPA came over it.
            var read: CartoucheByteSource = file
            if connections.made.count == 1 {
                read = CuttingSource(file, after: third, cut: { await remote.disconnect() })
            }
            return CartoucheResumingSource.Opened(source: read, close: { await remote.disconnect() })
        }
        let entries = try await CartoucheZip.entries(of: source)
        let into = try localFolder()
        try await CartoucheZip.extract(source, entries: entries, into: into)
        await source.close()
        XCTAssertEqual(source.reopened, 1, "the file was opened again \(source.reopened) times")
        XCTAssertEqual(connections.made.count, 2)
        try checkInstalled(into, fixtures.small)
    }

    func testCopiesAGameThereAndInstallsItAgain() async throws {
        let remote = try await signIn()
        let installed = try await install(CartoucheStoragePath.join(servers.games, servers.smallName), from: remote)
        let folder = try await scratchFolder(remote)
        let canWrite = try await remote.canWrite(folder)
        XCTAssertTrue(canWrite)
        let path = CartoucheStoragePath.join(folder, servers.smallName)
        let upload = try await remote.create(path, size: nil)
        let written: UInt64
        do {
            written = try await writeIPA(from: installed.appendingPathComponent(fixtures.small.bundle),
                                         as: fixtures.small.bundle, to: upload)
            try await upload.finish()
        } catch {
            await upload.cancel()
            throw error
        }
        let listed = try await remote.list(folder)
        XCTAssertEqual(listed.map(\.name), [servers.smallName])
        XCTAssertEqual(listed.first?.size, written)
        let again = try await install(path, from: remote)
        try checkInstalled(again, fixtures.small)
    }

    func testReplacesAFileOnlyOnceTheNewOneIsFinished() async throws {
        let remote = try await signIn()
        let folder = try await scratchFolder(remote)
        let path = CartoucheStoragePath.join(folder, "Sauvegarde.zip")
        let first = noise(300_000, seed: 1)
        try await remote.write(first, to: path)
        let second = noise(5 << 20, seed: 2)
        let upload = try await remote.create(path, size: UInt64(second.count))
        try await upload.write(second.prefix(1 << 20))
        // Meanwhile, another connection still reads the file there.
        let reader = try await signIn()
        let during = try await reader.read(path)
        XCTAssertEqual(during, first)
        try await upload.write(second.dropFirst(1 << 20))
        try await upload.finish()
        let after = try await remote.read(path)
        XCTAssertEqual(after, second)
        let names = try await remote.list(folder).map(\.name)
        XCTAssertEqual(names, ["Sauvegarde.zip"])
    }

    func testLeavesNothingOfACopyItGaveUp() async throws {
        let remote = try await signIn()
        let folder = try await scratchFolder(remote)
        let upload = try await remote.create(CartoucheStoragePath.join(folder, servers.smallName), size: nil)
        // More than a part of S3: a multipart upload, which must go too.
        try await upload.write(noise(20 << 20, seed: 3))
        await upload.cancel()
        let names = try await remote.list(folder).map(\.name)
        XCTAssertEqual(names, [])
    }

    func testMakesAndRemovesFolders() async throws {
        let remote = try await signIn()
        let folder = try await scratchFolder(remote)
        let deep = CartoucheStoragePath.join(folder, "Sauvegardes", "Essai de stockage", "2026")
        try await remote.makeFolders(deep)
        // Again: all of it is there.
        try await remote.makeFolders(deep)
        try await remote.write(Data("partie".utf8), to: CartoucheStoragePath.join(deep, "partie.txt"))
        let top = try await remote.list(folder)
        XCTAssertEqual(top.map(\.name), ["Sauvegardes"])
        XCTAssertEqual(top.first?.isFolder, true)
        let inside = try await remote.list(deep)
        XCTAssertEqual(inside.map(\.name), ["partie.txt"])
        try await remote.delete(CartoucheStoragePath.join(deep, "partie.txt"))
        let emptied = try await remote.list(deep)
        XCTAssertEqual(emptied.map(\.name), [])
    }

    // MARK: Saves

    /// A game's Documents on one of the test's iPhones, its saves
    /// written at WRITTEN, save0.bin holding PARTY.
    private func play(_ party: String, written: Date, in place: URL? = nil) throws -> URL {
        let documents = try place ?? localFolder()
        let saves = documents.appendingPathComponent("save", isDirectory: true)
        try FileManager.default.createDirectory(at: saves.appendingPathComponent("Profils"), withIntermediateDirectories: true)
        try (Data(party.utf8) + noise(200_000, seed: 4)).write(to: saves.appendingPathComponent("save0.bin"))
        try Data("Joueur 1".utf8).write(to: saves.appendingPathComponent("Profils/joueur é.txt"))
        for file in ["save0.bin", "Profils/joueur é.txt"] {
            try FileManager.default.setAttributes([.modificationDate: written], ofItemAtPath: saves.appendingPathComponent(file).path)
        }
        return documents
    }

    /// What save0.bin holds in DOCUMENTS, before the noise.
    private func party(in documents: URL) throws -> String {
        let data = try Data(contentsOf: documents.appendingPathComponent("save/save0.bin"))
        XCTAssertEqual(data.suffix(200_000), noise(200_000, seed: 4))
        return String(decoding: data.dropLast(200_000), as: UTF8.self)
    }

    func testKeepsSavesInStepAcrossIPhones() async throws {
        let remote = try await signIn()
        let folder = try await scratchFolder(remote)
        let scratchHere = try localFolder()
        // A round of syncs, as Cartouche makes one each time.
        func round() -> CartoucheSavesFolder {
            CartoucheSavesFolder(remote: remote, path: folder, place: "test|" + folder, scratch: scratchHere)
        }
        let gameFolder = CartoucheStoragePath.join(folder, "Essai de stockage [0100CA27C0DE0000]")
        func copies() async throws -> [String] {
            try await remote.list(gameFolder).map(\.name).filter { !$0.hasSuffix(".partial") }.sorted()
        }
        let morning = Date(timeIntervalSince1970: 1_794_292_800)

        // An iPhone plays: its saves go, named by when they were written.
        let first = CartoucheSaveTarget(key: "first", name: "Essai de stockage", titleId: "0100ca27c0de0000",
                                        documents: try play("partie 1", written: morning))
        let sent = try await round().sync(first, base: nil, fetching: false)
        XCTAssertEqual(sent.step, .send)
        XCTAssertEqual(sent.sent, CartoucheSaveSync.fileName(morning))
        var firstBase = try XCTUnwrap(sent.base)
        let afterFirst = try await copies()
        XCTAssertEqual(afterFirst, [CartoucheSaveSync.fileName(morning)])
        let unchanged = try await round().sync(first, base: firstBase, fetching: true)
        XCTAssertEqual(unchanged.step, .none)

        // Cartouche installed again, or another iPhone: no saves there, and
        // the newest copy comes, whole.
        let second = CartoucheSaveTarget(key: "second", name: "Essai de stockage", titleId: "0100CA27C0DE0000",
                                         documents: try localFolder())
        let waits = try await round().sync(second, base: nil, fetching: false)
        XCTAssertEqual(waits.step, .none)
        let fetched = try await round().sync(second, base: nil, fetching: true)
        XCTAssertEqual(fetched.step, .fetch)
        XCTAssertEqual(fetched.fetched, CartoucheSaveSync.fileName(morning))
        XCTAssertEqual(try party(in: second.documents), "partie 1")
        XCTAssertEqual(try String(contentsOf: second.documents.appendingPathComponent("save/Profils/joueur é.txt"),
                                  encoding: .utf8), "Joueur 1")
        var secondBase = try XCTUnwrap(fetched.base)
        XCTAssertEqual(secondBase.content, firstBase.content)

        // The second plays; the first takes its saves when the game starts,
        // after reading what the newest copy holds from its end alone.
        _ = try play("partie 2", written: morning + 600, in: second.documents)
        let secondSent = try await round().sync(second, base: secondBase, fetching: false)
        XCTAssertEqual(secondSent.step, .send)
        secondBase = try XCTUnwrap(secondSent.base)
        let firstFetched = try await round().sync(first, base: firstBase, fetching: true)
        XCTAssertEqual(firstFetched.step, .fetch)
        XCTAssertEqual(firstFetched.fetched, CartoucheSaveSync.fileName(morning + 600))
        XCTAssertEqual(try party(in: first.documents), "partie 2")
        firstBase = try XCTUnwrap(firstFetched.base)

        // Both play without the server; the second's, written last, win.
        _ = try play("partie 3a", written: morning + 1_200, in: first.documents)
        _ = try play("partie 3b", written: morning + 1_800, in: second.documents)
        let secondWins = try await round().sync(second, base: secondBase, fetching: false)
        XCTAssertEqual(secondWins.step, .send)
        secondBase = try XCTUnwrap(secondWins.base)
        // After the game, the first's are kept as a copy of their own date;
        // the newer ones come at its next start.
        let firstKept = try await round().sync(first, base: firstBase, fetching: false)
        XCTAssertEqual(firstKept.step, .keep)
        XCTAssertEqual(firstKept.kept, CartoucheSaveSync.fileName(morning + 1_200))
        XCTAssertEqual(try party(in: first.documents), "partie 3a")
        firstBase = try XCTUnwrap(firstKept.base)
        let firstStarts = try await round().sync(first, base: firstBase, fetching: true)
        XCTAssertEqual(firstStarts.step, .fetch)
        XCTAssertEqual(try party(in: first.documents), "partie 3b")
        firstBase = try XCTUnwrap(firstStarts.base)
        let afterConflict = try await copies()
        XCTAssertEqual(afterConflict, [morning, morning + 600, morning + 1_200, morning + 1_800].map(CartoucheSaveSync.fileName))

        // The first puts back its own: it becomes the newest copy, which
        // the second takes at its next start.
        let putBack = try await round().putBack(CartoucheSaveSync.fileName(morning + 1_200), of: first, base: firstBase)
        XCTAssertEqual(try party(in: first.documents), "partie 3a")
        XCTAssertNil(putBack.kept, "the saves it replaced were in the folder already")
        let newest = try XCTUnwrap(putBack.sent)
        let afterPutBack = try await copies()
        XCTAssertEqual(afterPutBack.last, newest)
        firstBase = try XCTUnwrap(putBack.base)
        XCTAssertEqual(firstBase.copy, newest)
        let secondTakes = try await round().sync(second, base: secondBase, fetching: true)
        XCTAssertEqual(secondTakes.step, .fetch)
        XCTAssertEqual(try party(in: second.documents), "partie 3a")
        secondBase = try XCTUnwrap(secondTakes.base)

        // The ten newest copies stay, the one just made among them.
        for game in 0 ..< 8 {
            _ = try play("partie \(4 + game)", written: Date().addingTimeInterval(-3_600 + Double(game)), in: second.documents)
            let more = try await round().sync(second, base: secondBase, fetching: false)
            XCTAssertEqual(more.step, .send)
            secondBase = try XCTUnwrap(more.base)
        }
        let kept = try await copies()
        XCTAssertEqual(kept.count, CartoucheSaveSync.kept)
        XCTAssertEqual(kept.last, secondBase.copy)
        XCTAssertFalse(kept.contains(CartoucheSaveSync.fileName(morning)))
        let listedCopies = try await round().copies(of: second)
        XCTAssertEqual(listedCopies.map { CartoucheStoragePath.name($0.path) }, Array(kept.reversed()))
        XCTAssertEqual(try party(in: second.documents), "partie 11")
    }

    // MARK: Where the account can write

    func testKnowsWhereItCanWrite() async throws {
        let remote = try await signIn()
        let canWrite = try await remote.canWrite(servers.games)
        XCTAssertTrue(canWrite)
        if let root = rootPath {
            let left = try FileManager.default.contentsOfDirectory(atPath: (root as NSString).appendingPathComponent(servers.games))
                .filter { $0.hasPrefix(".cartouche-write-check") }
            XCTAssertEqual(left, [], "what Cartouche wrote to ask is still there")
        }
        let settings = settings()
        let server = UUID()
        let noted = await settings.checkAccess(remote, server: server, path: servers.games)
        XCTAssertEqual(noted, true)
        XCTAssertFalse(settings.isReadOnly(server, path: servers.games))
    }

    func testKnowsWhereItCannotWriteAndInstallsFromThere() async throws {
        let (remote, path) = try await readOnlyPlace()
        track(remote)
        let canWrite = try await remote.canWrite(path)
        XCTAssertFalse(canWrite)
        let settings = settings()
        let server = UUID()
        _ = await settings.checkAccess(remote, server: server, path: path)
        XCTAssertTrue(settings.isReadOnly(server, path: path))
        let installed = try await install(CartoucheStoragePath.join(path, servers.smallName), from: remote)
        try checkInstalled(installed, fixtures.small)
    }

    // MARK: A game past 4 GiB

    /// The room left on the disk of URL, as statfs says: without what macOS
    /// could purge, which it may not purge in time.
    private func room(at url: URL) -> UInt64 {
        statfsFreeSpace(url.path) ?? 0
    }

    func testInstallsAndCopiesAGameLargerThan4GiB() async throws {
        guard let big = fixtures.big, let bigName = servers.bigName else {
            throw XCTSkip("no IPA past 4 GiB: servers.sh ran without --big-mib")
        }
        let remote = try await signIn()
        let source = try await openAsInstallDoes(CartoucheStoragePath.join(servers.games, bigName), from: remote)
        XCTAssertEqual(source.size, big.size)
        let entries = try await CartoucheZip.entries(of: source)
        XCTAssertEqual(entries.map(\.name), big.entries.map(\.name))
        let last = try XCTUnwrap(entries.first { $0.name == big.bundle + "/suite/fin.bin" })
        XCTAssertGreaterThan(last.localHeaderOffset, UInt64(1) << 32)
        let lastData = try await CartoucheZip.data(of: last, in: source)
        XCTAssertEqual(sha256(lastData), big.files["suite/fin.bin"]?.sha256)

        // Install from: in one pass, in the memory it started with.
        let installed = try localFolder()
        guard room(at: installed) > big.size + (2 << 30) else {
            throw XCTSkip("not enough room on this Mac to install \(megabytes(Int64(big.size)))")
        }
        var watch = FootprintWatch()
        var started = Date()
        try await CartoucheZip.extract(source, entries: entries, into: installed)
        var grew = watch.stop()
        print("\(label): installed \(megabytes(Int64(big.size))) in \(Int(Date().timeIntervalSince(started))) s, the footprint \(megabytes(grew)) above its start")
        XCTAssertLessThan(grew, 256 << 20, "the install took more and more memory")
        try checkInstalled(installed, big)

        // Copy to, of the game installed.
        guard room(at: installed) > big.size + (2 << 30) else {
            print("\(label): not enough room on this Mac to copy \(megabytes(Int64(big.size))) back")
            return
        }
        let folder = try await scratchFolder(remote)
        let path = CartoucheStoragePath.join(folder, bigName)
        let upload = try await remote.create(path, size: nil)
        watch = FootprintWatch()
        started = Date()
        let written: UInt64
        do {
            written = try await writeIPA(from: installed.appendingPathComponent(big.bundle), as: big.bundle, to: upload)
            try await upload.finish()
        } catch {
            await upload.cancel()
            throw error
        }
        grew = watch.stop()
        print("\(label): copied \(megabytes(Int64(written))) in \(Int(Date().timeIntervalSince(started))) s, the footprint \(megabytes(grew)) above its start")
        XCTAssertLessThan(grew, 256 << 20, "the copy took more and more memory")
        try? FileManager.default.removeItem(at: installed)
        // Read on a connection of its own, which goes once it has read, as
        // an install's does: SMB does not remove a file a reader still holds
        // open.
        let reading = try await connect()
        do {
            let copy = try await reading.open(path)
            XCTAssertEqual(copy.size, written)
            let copied = try await CartoucheZip.entries(of: copy)
            let copiedLast = try XCTUnwrap(copied.first { $0.name == big.bundle + "/suite/fin.bin" })
            XCTAssertGreaterThan(copiedLast.localHeaderOffset, UInt64(1) << 32)
            let copiedData = try await CartoucheZip.data(of: copiedLast, in: copy)
            XCTAssertEqual(sha256(copiedData), big.files["suite/fin.bin"]?.sha256)
        } catch {
            await reading.disconnect()
            throw error
        }
        await reading.disconnect()
        try await remote.delete(path)
    }
}

/// The connections a test made.
private final class Connections {
    var made: [CartoucheRemote] = []
}

/// A file read through it until AFTER bytes came, when CUT takes its
/// connection away, before the next read.
private final class CuttingSource: CartoucheByteSource {
    let size: UInt64
    private let file: CartoucheByteSource
    private let after: UInt64
    private let cut: () async -> Void
    private var came: UInt64 = 0
    private var done = false

    init(_ file: CartoucheByteSource, after: UInt64, cut: @escaping () async -> Void) {
        self.file = file
        size = file.size
        self.after = after
        self.cut = cut
    }

    func read(at offset: UInt64, count: Int) async throws -> Data {
        if !done, came >= after {
            done = true
            await cut()
        }
        let data = try await file.read(at: offset, count: count)
        came += UInt64(data.count)
        return data
    }
}
