//
//  DriveTests.swift
//  CartoucheStorageTests
//
//  Google Drive, through a stand-in for Google's servers (drive_server.py),
//  which answers as they do: the sign-in of the player's own OAuth client,
//  with PKCE, on Google's page; the access token, which lasts an hour,
//  renewed with the refresh token; the sign-in Google ends after seven days
//  for a project in testing; and the Drive API's files and folders, found
//  by their names from My Drive's root, read by ranges and written with the
//  resumable upload, a piece at a time.
//

import Foundation
import XCTest
@testable import CartoucheStorage

final class DriveTests: StorageServerTests {
    override class var serverName: String? { "Google Drive, stand-in" }

    private var drive: StorageServers.Drive { servers.drive }

    private var endpoints: CartoucheDriveEndpoints {
        .standIn(URL(string: drive.address)!)
    }

    private var client: CartoucheDriveClient {
        CartoucheDriveClient(drive.clientID)!
    }

    /// The Drive as the player adds it in Cartouche: their client's ID, and
    /// the address of their account. A new one each time: Google ends a
    /// sign-in for its server alone.
    private func newServer(client: String? = nil) -> CartoucheStorageServer {
        CartoucheStorageServer(kind: .drive, name: "Google Drive", host: drive.account, username: client ?? drive.clientID)
    }

    override func connect() async throws -> CartoucheRemote {
        try await CartoucheDrive.connect(newServer(), refreshToken: drive.refreshToken, endpoints: endpoints)
    }

    /// A refresh token Google does not know, as one it ended.
    override func connectWithAWrongPassword() async throws -> CartoucheRemote {
        try await CartoucheDrive.connect(newServer(), refreshToken: "not-" + drive.refreshToken, endpoints: endpoints)
    }

    /// A folder whose capabilities say the account cannot add to it, as
    /// Drive says of a folder shared with it to read only.
    override func readOnlyPlace() async throws -> (CartoucheRemote, String) {
        (try await connect(), servers.readOnlyFolder)
    }

    // Each read is a request of its own, as with S3.
    override var signingOutCutsReads: Bool { false }

    override func tearDown() async throws {
        // Before the folders the test made are removed.
        if servers != nil {
            try? await hook("reset")
        }
        try await super.tearDown()
    }

    // MARK: The stand-in

    /// Asks the stand-in what only a test asks (drive_server.py).
    private func hook(_ name: String, _ query: [String: String] = [:]) async throws {
        var components = try XCTUnwrap(URLComponents(string: drive.address + "/test/" + name))
        if !query.isEmpty {
            components.queryItems = query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        }
        var request = URLRequest(url: try XCTUnwrap(components.url))
        request.httpMethod = "POST"
        let (_, response) = try await URLSession.shared.data(for: request)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 204, "the stand-in took no \(name)")
    }

    /// The requests the stand-in logged since MARK.
    private func requests(since mark: UInt64) throws -> String {
        try logged(in: drive.log, since: mark)
    }

    /// Google's page, as the player goes through it: the address it sends
    /// them back to, which ASWebAuthenticationSession gives Cartouche.
    private func signInPage(_ pkce: CartoucheDrivePKCE, state: String, consent: Bool = false) async throws -> URL {
        let page = try XCTUnwrap(CartoucheDriveSignIn.page(client, challenge: pkce.challenge, state: state,
                                                           account: drive.account, consent: consent, endpoints: endpoints))
        let stay = StaysOnThePage()
        let session = URLSession(configuration: .ephemeral, delegate: stay, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        do {
            let (_, response) = try await session.data(from: page)
            let answer = try XCTUnwrap(response as? HTTPURLResponse)
            XCTAssertEqual(answer.statusCode, 302)
            if let location = answer.value(forHTTPHeaderField: "Location") {
                return try XCTUnwrap(URL(string: location))
            }
            return try XCTUnwrap(stay.address, "Google's page sent the player nowhere")
        } catch let error as URLError where error.code == .unsupportedURL {
            // URLSession went for the app's address itself, which it cannot
            // open.
            return try XCTUnwrap(stay.address ?? error.failingURL, "\(error)")
        }
    }

    /// Signs in to SERVER on Google's page, as the player does, and gives
    /// what Cartouche then keeps.
    private func signInOnThePage(_ server: CartoucheStorageServer, consent: Bool = false) async throws
        -> (remote: CartoucheDrive, refreshToken: String, account: String?) {
        let pkce = CartoucheDrivePKCE()
        let state = CartoucheDrivePKCE.randomText()
        let back = try await signInPage(pkce, state: state, consent: consent)
        let code = try CartoucheDriveSignIn.code(in: back, client: client, state: state)
        return try await CartoucheDrive.signIn(code: code, verifier: pkce.verifier, server: server, endpoints: endpoints)
    }

    // MARK: Signing in

    /// The player signs in on Google's page with their own client: the code
    /// it sends back is worth something only with the sign-in's PKCE
    /// verifier, and Google gives the refresh token, which Cartouche keeps,
    /// and the account's address.
    func testSignsInOnGooglesPageWithPKCE() async throws {
        let server = newServer()
        let pkce = CartoucheDrivePKCE()
        let state = CartoucheDrivePKCE.randomText()
        let back = try await signInPage(pkce, state: state)
        XCTAssertEqual(back.scheme, client.scheme)
        // Another sign-in's address is not this one's.
        XCTAssertThrowsError(try CartoucheDriveSignIn.code(in: back, client: client, state: CartoucheDrivePKCE.randomText()))
        let code = try CartoucheDriveSignIn.code(in: back, client: client, state: state)
        // A code caught on its way, without the verifier, is worth nothing.
        let stolen = await thrownError {
            _ = try await CartoucheDrive.signIn(code: code, verifier: CartoucheDrivePKCE().verifier, server: server,
                                                endpoints: self.endpoints)
        }
        XCTAssertEqual((stolen as? CartoucheStorageError)?.kind, .signInFailed, "\(String(describing: stolen))")
        XCTAssertFalse(CartoucheDriveSessions.shared.hasEnded(server.id))

        // Google takes a code once: the player signs in again.
        let signedIn = try await signInOnThePage(server)
        track(signedIn.remote)
        XCTAssertFalse(signedIn.refreshToken.isEmpty)
        XCTAssertEqual(signedIn.account, drive.account)
        let items = try await signedIn.remote.list(servers.games)
        XCTAssertTrue(items.contains { $0.name == servers.smallName }, "\(items.map(\.name))")
        // As Cartouche signs in to it from then on, with the refresh token.
        let again = track(try await CartoucheDrive.connect(server, refreshToken: signedIn.refreshToken, endpoints: endpoints))
        let top = try await again.list("")
        XCTAssertTrue(top.contains { $0.name == servers.games && $0.isFolder }, "\(top.map(\.name))")
    }

    /// Google gave no refresh token, as it may for a client the player
    /// allowed before: Cartouche asks for the access again, which gives one.
    func testAsksAgainWhenGoogleGivesNoLastingSignIn() async throws {
        let server = newServer()
        try await hook("next-sign-in", ["lasting": "0"])
        let without = await thrownError { _ = try await self.signInOnThePage(server) }
        XCTAssertEqual((without as? CartoucheStorageError)?.kind, .noLastingSignIn, "\(String(describing: without))")
        try await hook("next-sign-in", ["lasting": "0"])
        let signedIn = try await signInOnThePage(server, consent: true)
        track(signedIn.remote)
        XCTAssertFalse(signedIn.refreshToken.isEmpty)
    }

    /// Google's page lets the player leave the Drive unchecked: Cartouche
    /// says what to allow.
    func testSaysWhenThePlayerLeftTheDriveUnchecked() async throws {
        try await hook("next-sign-in", ["scope": "openid email"])
        let error = await thrownError { _ = try await self.signInOnThePage(self.newServer()) }
        XCTAssertEqual((error as? CartoucheStorageError)?.kind, .driveScope, "\(String(describing: error))")
        XCTAssertEqual(error?.localizedDescription, CartoucheText.storageDriveScope)
    }

    func testKnowsWhenThePlayerDidNotAllowTheAccess() async throws {
        try await hook("next-sign-in", ["refuse": "1"])
        let state = CartoucheDrivePKCE.randomText()
        let back = try await signInPage(CartoucheDrivePKCE(), state: state)
        XCTAssertThrowsError(try CartoucheDriveSignIn.code(in: back, client: client, state: state)) { error in
            XCTAssertEqual(error as? CartoucheDriveSignInFailure, .refused)
        }
    }

    func testRefusesAClientGoogleDoesNotKnow() async {
        let error = await thrownError {
            let remote = try await CartoucheDrive.connect(self.newServer(client: "999999999999-autre.apps.googleusercontent.com"),
                                                          refreshToken: self.drive.refreshToken, endpoints: self.endpoints)
            await remote.disconnect()
        }
        XCTAssertEqual((error as? CartoucheStorageError)?.kind, .clientRefused, "\(String(describing: error))")
        XCTAssertEqual(error?.localizedDescription, CartoucheText.storageDriveClientRefused)
    }

    func testNeedsTheClientAndASignIn() async {
        let notAClient = await thrownError {
            let remote = try await CartoucheDrive.connect(self.newServer(client: "Cartouche"), refreshToken: self.drive.refreshToken,
                                                          endpoints: self.endpoints)
            await remote.disconnect()
        }
        XCTAssertEqual((notAClient as? CartoucheStorageError)?.kind, .badClient)
        let notSignedIn = await thrownError {
            let remote = try await CartoucheDrive.connect(self.newServer(), refreshToken: "", endpoints: self.endpoints)
            await remote.disconnect()
        }
        XCTAssertEqual((notSignedIn as? CartoucheStorageError)?.kind, .accountNeeded)
    }

    // MARK: Tokens

    /// An access token lasts an hour: when the API no longer takes it,
    /// Cartouche asks for another with the refresh token, and goes on.
    func testRenewsTheAccessTokenWhenItRunsOut() async throws {
        let remote = try await signIn()
        _ = try await remote.list(servers.games)
        let mark = fileSize(drive.log)
        try await hook("expire")
        let items = try await remote.list(servers.games)
        XCTAssertTrue(items.contains { $0.name == servers.smallName }, "\(items.map(\.name))")
        let log = try requests(since: mark)
        XCTAssertTrue(log.contains("-> 401 authError"), log)
        XCTAssertTrue(log.contains("-> 200 refresh_token"), log)
    }

    /// Seven days after the sign-in, for a project in testing, Google takes
    /// the refresh token no more: the Drive is out of reach, as a server
    /// away from home, without a report, and Google is not asked again
    /// until the player signs in again, which brings it back.
    func testAnEndedSignInWaitsForThePlayerToSignInAgain() async throws {
        let server = newServer()
        let first = try await signInOnThePage(server)
        let remote = track(first.remote)
        _ = try await remote.list(servers.games)
        try await hook("revoke", ["refresh_token": first.refreshToken])
        let ended = await thrownError {
            _ = try await remote.list(CartoucheStoragePath.join(self.servers.games, self.servers.olderFolder))
        }
        let offline = try XCTUnwrap(ended as? CartoucheStorageOffline, "\(String(describing: ended))")
        XCTAssertTrue(offline.isSignedOut)
        XCTAssertEqual(offline.localizedDescription, CartoucheText.storageDriveSignedOut(server.name))
        XCTAssertTrue(CartoucheDriveSessions.shared.hasEnded(server.id))

        // Out of reach, without a word to Google.
        let mark = fileSize(drive.log)
        let answers = await CartoucheStorageReach.answers(server)
        XCTAssertFalse(answers)
        let again = await thrownError {
            let remote = try await CartoucheDrive.connect(server, refreshToken: first.refreshToken, endpoints: self.endpoints)
            await remote.disconnect()
        }
        XCTAssertEqual((again as? CartoucheStorageOffline)?.isSignedOut, true, "\(String(describing: again))")
        XCTAssertEqual(try requests(since: mark), "", "Google was asked again")

        // The player signs in again, as Cartouche's sign-in does.
        let second = try await signInOnThePage(server)
        track(second.remote)
        CartoucheDriveSessions.shared.renew(server.id)
        let back = track(try await CartoucheDrive.connect(server, refreshToken: second.refreshToken, endpoints: endpoints))
        let items = try await back.list(servers.games)
        XCTAssertTrue(items.contains { $0.name == servers.smallName }, "\(items.map(\.name))")
    }

    // MARK: What Drive holds

    /// Drive's own files, a file in the bin and a name a path cannot hold
    /// are neither listed nor read; of two files of a name, the newest is
    /// the one there.
    func testListsOnlyFilesAndFoldersTheNewestOfEachName() async throws {
        let remote = try await signIn()
        let names = try await remote.list(servers.games).map(\.name)
        var expected = [servers.smallName, servers.olderFolder]
        if let big = servers.bigName {
            expected.append(big)
        }
        XCTAssertEqual(names.sorted(), expected.sorted())
        let small = try await remote.open(CartoucheStoragePath.join(servers.games, servers.smallName))
        XCTAssertEqual(small.size, fixtures.small.size)
    }

    /// A folder and a file named on a Mac, decomposed, found by the names
    /// Cartouche has, composed.
    func testFindsNamesAMacDecomposed() async throws {
        let remote = try await signIn()
        let folder = "Partie enregistrée".precomposedStringWithCanonicalMapping
        let file = "écran.txt".precomposedStringWithCanonicalMapping
        let items = try await remote.list(folder)
        XCTAssertEqual(items.map(\.name), [file])
        let text = try await remote.read(CartoucheStoragePath.join(folder, file))
        XCTAssertEqual(String(decoding: text, as: UTF8.self), "Écran titre\n")
    }

    func testTellsTheRoomLeft() async throws {
        let remote = try await signIn()
        let room = try await remote.freeSpace()
        let left = try XCTUnwrap(room)
        XCTAssertGreaterThan(left, 0)
        XCTAssertLessThan(left, UInt64(15) << 30)
    }

    // MARK: When Google says no, or fails

    /// Google fails for a moment, or takes too many requests: Cartouche
    /// waits a little and asks again, longer each time; what makes a folder
    /// goes again only when Google said it did nothing.
    func testAsksAgainWhenGoogleFailsForAMoment() async throws {
        let remote = try await signIn()
        try await hook("fail", ["path": "/drive/v3/files", "status": "503", "count": "2"])
        let items = try await remote.list(servers.games)
        XCTAssertTrue(items.contains { $0.name == servers.smallName }, "\(items.map(\.name))")
        try await hook("fail", ["path": "/drive/v3/files", "status": "403", "reason": "userRateLimitExceeded"])
        let folder = try await scratchFolder(remote)
        try await hook("fail", ["path": "/drive/v3/files", "method": "POST", "status": "429"])
        try await remote.makeFolder(CartoucheStoragePath.join(folder, "Après une pause"))
        try await hook("fail", ["path": "/drive/v3/files", "method": "POST", "status": "503"])
        let failed = await thrownError { try await remote.makeFolder(CartoucheStoragePath.join(folder, "Pas deux fois")) }
        XCTAssertEqual((failed as? CartoucheStorageError)?.kind, .driveFailed, "\(String(describing: failed))")
        let made = try await remote.list(folder)
        XCTAssertEqual(made.map(\.name), ["Après une pause"])
        // Made again: the folder there.
        try await remote.makeFolder(CartoucheStoragePath.join(folder, "Après une pause"))
        let again = try await remote.list(folder)
        XCTAssertEqual(again.map(\.name), ["Après une pause"])
    }

    /// A piece of a file fails on its way, or the connection drops: Google
    /// holds what came, Cartouche asks how much, and sends the rest from
    /// there, the file whole in the end.
    func testAnUploadGoesOnFromWhereGoogleHoldsIt() async throws {
        let remote = try await signIn()
        let folder = try await scratchFolder(remote)
        for mode in ["503", "close"] {
            let path = CartoucheStoragePath.join(folder, "Coupé \(mode).bin")
            let data = noise(20 << 20, seed: 7)
            let mark = fileSize(drive.log)
            try await hook("cut-next-upload", ["mode": mode])
            try await remote.write(data, to: path)
            let read = try await remote.read(path, limit: 32 << 20)
            XCTAssertEqual(read.count, data.count, mode)
            XCTAssertEqual(sha256(read), sha256(data), mode)
            let log = try requests(since: mark)
            XCTAssertTrue(log.contains("cut, holds") || log.contains("-> 503 backendError"), log)
        }
        let names = try await remote.list(folder).map(\.name)
        XCTAssertEqual(names, ["Coupé 503.bin", "Coupé close.bin"])
    }

    /// The Drive API is not turned on in the player's project: Cartouche
    /// says so, with the address Google gives to turn it on, of Google
    /// Cloud's console, and a report would take Google's reason alone.
    func testSaysWhenTheDriveAPIIsOff() async throws {
        let remote = try await signIn()
        try await hook("drive-off", ["on": "1"])
        let error = await thrownError { _ = try await remote.list(self.servers.games) }
        let storage = try XCTUnwrap(error as? CartoucheStorageError, "\(String(describing: error))")
        XCTAssertEqual(storage.kind, .driveOff)
        XCTAssertEqual(storage.message, CartoucheText.storageDriveOff)
        let failure = try XCTUnwrap(storage.underlyingError as? CartoucheDriveFailure)
        XCTAssertEqual(failure.activation?.host, "console.developers.google.com")
        XCTAssertEqual(failure.localizedDescription, "HTTP 403 accessNotConfigured")
        try await hook("drive-off", ["on": "0"])
        let items = try await remote.list(servers.games)
        XCTAssertFalse(items.isEmpty)
    }

    func testSaysWhenTheDriveIsFull() async throws {
        let remote = try await signIn()
        let folder = try await scratchFolder(remote)
        try await hook("full", ["on": "1"])
        let error = await thrownError { try await remote.write(Data("partie".utf8), to: CartoucheStoragePath.join(folder, "partie.txt")) }
        XCTAssertEqual((error as? CartoucheStorageError)?.kind, .noSpaceThere, "\(String(describing: error))")
        XCTAssertEqual(error?.localizedDescription, CartoucheText.storageDriveFull)
        try await hook("full", ["on": "0"])
        let names = try await remote.list(folder).map(\.name)
        XCTAssertEqual(names, [])
    }

    /// The API answers with a redirection: Cartouche follows none, and the
    /// access token goes nowhere else.
    func testFollowsNoRedirection() async throws {
        let remote = try await signIn()
        _ = try await remote.list("")
        let mark = fileSize(drive.log)
        try await hook("redirect-next", ["path": "/drive/v3/files"])
        let error = await thrownError { _ = try await remote.list(self.servers.games) }
        XCTAssertEqual((error as? CartoucheStorageError)?.kind, .driveFailed, "\(String(describing: error))")
        let log = try requests(since: mark)
        XCTAssertTrue(log.contains("-> 302"), log)
        XCTAssertFalse(log.contains("/elsewhere"), log)
    }
}

/// Stays on Google's page: the address it sends the player back to is the
/// app's, which only the test reads.
private final class StaysOnThePage: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var sentTo: URL?

    /// Where the page sent the player.
    var address: URL? {
        lock.lock()
        defer { lock.unlock() }
        return sentTo
    }

    private func keep(_ url: URL?) {
        lock.lock()
        sentTo = url
        lock.unlock()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest) async -> URLRequest? {
        keep(request.url)
        return nil
    }
}
