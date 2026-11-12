//
//  CartoucheStorageDrive.swift
//  Cartouche
//
//  The player's Google Drive, signed in to with their own OAuth client and
//  their own Google account (CartoucheDrive.swift): the folders and files
//  of their My Drive, by their names from its root, as the other storage
//  is reached by paths. Google gives an access token for an hour, and
//  another for the refresh token, which the keychain keeps as the server's
//  secret. When Google no longer takes it, as seven days after the sign-in
//  for a project in testing, the Drive is out of reach as a server away
//  from home is: the games installed play, the games folder keeps its last
//  list and the saves wait, without a report, until the player signs in
//  again (CartoucheDriveSessions, CartoucheStorageDriveView.swift).
//
//  A file is read in pieces, with Range, so that installing a game reads
//  it in one pass, and written with Google's resumable upload: a piece that
//  fails on the way goes again from where Google holds the file, and the
//  file takes the place of the one there, if any, only once it is whole.
//  The access token goes to the Drive API alone: no redirection is
//  followed.
//

import Foundation

// MARK: Sign-ins Google ended

/// The Drives whose sign-in Google no longer takes, by server ID, for as
/// long as Cartouche runs: Cartouche asks Google nothing more for them
/// until the player signs in again, and they show as out of reach, with a
/// way to sign in again (CartoucheStorageOffline).
final class CartoucheDriveSessions: @unchecked Sendable {
    static let shared = CartoucheDriveSessions()

    private let lock = NSLock()
    private var ended: Set<UUID> = []

    func hasEnded(_ server: UUID) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return ended.contains(server)
    }

    /// Google refused SERVER's refresh token.
    func end(_ server: UUID) {
        lock.lock()
        ended.insert(server)
        lock.unlock()
    }

    /// The player signed in to SERVER again.
    func renew(_ server: UUID) {
        lock.lock()
        ended.remove(server)
        lock.unlock()
    }
}

// MARK: The Drive

final class CartoucheDrive: CartoucheRemote {
    private let server: CartoucheStorageServer
    private let client: CartoucheDriveClient
    private let refreshToken: String
    private let endpoints: CartoucheDriveEndpoints
    private let session: URLSession
    private let state = CartoucheDriveState()

    /// The pauses before a request that failed for a moment goes again, in
    /// nanoseconds, longer each time, as Google asks: 15 s in all.
    static let pauses: [UInt64] = ([1, 2, 4, 8, 16] as [UInt64]).map { $0 * 500_000_000 }

    private init(server: CartoucheStorageServer, client: CartoucheDriveClient, refreshToken: String,
                 endpoints: CartoucheDriveEndpoints) {
        self.server = server
        self.client = client
        self.refreshToken = refreshToken
        self.endpoints = endpoints
        session = Self.makeSession()
    }

    deinit {
        session.finishTasksAndInvalidate()
    }

    /// A session of its own: no cookie, no cache, no redirection.
    private static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        configuration.timeoutIntervalForRequest = 60
        return URLSession(configuration: configuration, delegate: CartoucheDriveNoRedirection(), delegateQueue: nil)
    }

    /// Signs in to the player's Drive with SERVER's client, whose ID is in
    /// username, and the refresh token the keychain keeps: Google gives an
    /// access token for it. GRANT, right after a sign-in, holds one already.
    /// ENDPOINTS: Google's, or the storage tests' stand-in.
    static func connect(_ server: CartoucheStorageServer, refreshToken: String, grant: CartoucheDriveGrant? = nil,
                        endpoints: CartoucheDriveEndpoints = .google) async throws -> CartoucheDrive {
        guard let client = CartoucheDriveClient(server.username) else {
            throw CartoucheStorageError(.badClient, CartoucheText.storageDriveBadClient)
        }
        // Only with the player's own sign-in.
        guard !refreshToken.isEmpty else {
            throw CartoucheStorageError(.accountNeeded, CartoucheText.storageDriveSignInNeeded)
        }
        // A network Google cannot be reached from, or a sign-in Google
        // ended: said within the reach patience, without asking Google.
        guard await reaches(server, endpoints: endpoints) else {
            throw CartoucheStorageOffline(server)
        }
        let remote = CartoucheDrive(server: server, client: client, refreshToken: refreshToken, endpoints: endpoints)
        if let grant {
            remote.state.keep(token: grant.accessToken, until: Date().addingTimeInterval(TimeInterval(grant.expiresIn)))
        } else {
            _ = try await remote.accessToken()
        }
        return remote
    }

    /// After Google's sign-in page: the CODE it gave exchanged for the
    /// tokens, with the sign-in's PKCE VERIFIER, for the client of SERVER.
    /// Gives the Drive, connected, the refresh token to keep, and the
    /// account's address, once the Drive API answered for it: it may be off
    /// in the player's project.
    static func signIn(code: String, verifier: String, server: CartoucheStorageServer,
                       endpoints: CartoucheDriveEndpoints = .google) async throws
        -> (remote: CartoucheDrive, refreshToken: String, account: String?) {
        guard let client = CartoucheDriveClient(server.username) else {
            throw CartoucheStorageError(.badClient, CartoucheText.storageDriveBadClient)
        }
        let exchange = makeSession()
        defer { exchange.finishTasksAndInvalidate() }
        let grant = try await requestToken(CartoucheDriveSignIn.exchange(code: code, verifier: verifier, client: client),
                                           renewing: false, server: server, endpoints: endpoints, session: exchange)
        // Google's page lets the player leave the Drive unchecked.
        guard grant.allowsDrive else {
            throw CartoucheStorageError(.driveScope, CartoucheText.storageDriveScope)
        }
        guard let refreshToken = grant.refreshToken else {
            throw CartoucheStorageError(.noLastingSignIn, CartoucheText.storageDriveNoRefreshToken)
        }
        let remote = CartoucheDrive(server: server, client: client, refreshToken: refreshToken, endpoints: endpoints)
        remote.state.keep(token: grant.accessToken, until: Date().addingTimeInterval(TimeInterval(grant.expiresIn)))
        let about = try await remote.about()
        return (remote, refreshToken, about?.account)
    }

    /// Whether Google answers from here for SERVER: its API, or the stand-in
    /// of ENDPOINTS, on this Mac.
    private static func reaches(_ server: CartoucheStorageServer, endpoints: CartoucheDriveEndpoints) async -> Bool {
        guard endpoints != .google else { return await CartoucheStorageReach.answers(server) }
        guard !CartoucheDriveSessions.shared.hasEnded(server.id), let host = endpoints.token.host else { return false }
        let port = endpoints.token.port ?? (endpoints.token.scheme == "http" ? 80 : 443)
        return await CartoucheStorageReach.knock(host: host, port: port)
    }

    /// What URLSession says when it finds no way to Google: no network, no
    /// address for its name, no connection.
    private static let offlineCodes: Set<URLError.Code> = [
        .notConnectedToInternet, .cannotFindHost, .dnsLookupFailed, .cannotConnectToHost,
        .internationalRoamingOff, .dataNotAllowed,
    ]

    // MARK: Tokens

    /// The access token: the one kept, while it lasts another minute, or a
    /// new one, as when FORCE says the API no longer takes it.
    private func accessToken(force: Bool = false) async throws -> String {
        if !force, let token = state.token(validAt: Date().addingTimeInterval(60)) {
            return token
        }
        let grant = try await Self.requestToken(CartoucheDriveSignIn.renewal(refreshToken: refreshToken, client: client),
                                                renewing: true, server: server, endpoints: endpoints, session: session)
        state.keep(token: grant.accessToken, until: Date().addingTimeInterval(TimeInterval(grant.expiresIn)))
        return grant.accessToken
    }

    /// Sends FORM to Google's token server, again after a pause when it
    /// failed for a moment, and gives what Google granted. RENEWING: FORM
    /// asks for an access token with the refresh token, whose refusal ends
    /// the Drive's sign-in.
    private static func requestToken(_ form: [(String, String)], renewing: Bool, server: CartoucheStorageServer,
                                     endpoints: CartoucheDriveEndpoints, session: URLSession) async throws -> CartoucheDriveGrant {
        var request = URLRequest(url: endpoints.token, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let body = Data(CartoucheDriveSignIn.query(form).utf8)
        var attempt = 0
        while true {
            let (data, response) = try await transfer(request, body: body, server: server, session: session)
            if response.statusCode == 200 {
                guard let grant = CartoucheDriveGrant.parse(data) else {
                    throw CartoucheStorageError(.badAnswer, CartoucheText.storageDriveBadAnswer)
                }
                return grant
            }
            if response.statusCode == 429 || response.statusCode >= 500, attempt < pauses.count {
                try await Task.sleep(nanoseconds: pauses[attempt])
                attempt += 1
                continue
            }
            let failure = CartoucheDriveTokenFailure.parse(data, status: response.statusCode)
            if renewing, failure.needsSignIn {
                // Seven days after the sign-in, for a project in testing, or
                // the player took the access back: they sign in again, and
                // meanwhile the Drive is out of reach, without a report.
                CartoucheDriveSessions.shared.end(server.id)
                await MainActor.run {
                    CartoucheReports.note("Storage: Google ended the sign-in to " + server.name)
                    CartoucheStorageReach.shared.noteOffline(server)
                }
                throw CartoucheStorageOffline(server)
            }
            if failure.isClientRefused {
                throw CartoucheStorageError(.clientRefused, CartoucheText.storageDriveClientRefused, underlying: failure)
            }
            throw CartoucheStorageError(.signInFailed, CartoucheText.storageDriveSignInFailed(failure.localizedDescription),
                                        underlying: failure)
        }
    }

    /// Sends REQUEST, with BODY, and gives the answer: a network Google
    /// cannot be reached from says the Drive is offline from here.
    private static func transfer(_ request: URLRequest, body: Data?, server: CartoucheStorageServer,
                                 session: URLSession) async throws -> (Data, HTTPURLResponse) {
        let data: Data
        let response: URLResponse
        do {
            if let body {
                (data, response) = try await session.upload(for: request, from: body)
            } else {
                (data, response) = try await session.data(for: request)
            }
        } catch let failure as URLError where offlineCodes.contains(failure.code) {
            throw CartoucheStorageOffline(server)
        }
        guard let http = response as? HTTPURLResponse else {
            throw CartoucheStorageError(.badAnswer, CartoucheText.storageDriveBadAnswer)
        }
        return (data, http)
    }

    // MARK: Requests

    /// When a request to the Drive API goes again after it failed for a
    /// moment.
    private enum Again {
        /// Whatever failed: a request that changes nothing, or that would
        /// change it the same way again.
        case always
        /// Only when Google said it took too many requests, and so did
        /// nothing: a request that makes something.
        case afterRateLimit
        /// Never: the upload's pieces, which go on from where Google holds
        /// the file.
        case never
    }

    /// Sends a request to the Drive API with the access token: once more
    /// with a new one when the API no longer takes it, and again after a
    /// pause when it failed for a moment, as AGAIN says. Throws what the
    /// API said went wrong, as CartoucheDriveFailure, for a status that is
    /// neither 2xx nor one of ACCEPTING.
    private func api(_ method: String, _ url: URL, headers: [String: String] = [:], body: Data? = nil,
                     accepting: Set<Int> = [], again: Again = .always) async throws -> (Data, HTTPURLResponse) {
        // The token goes to Google's API alone.
        guard endpoints.serves(url) else {
            throw CartoucheStorageError(.badAnswer, CartoucheText.storageDriveBadAnswer)
        }
        var token = try await accessToken()
        var renewed = false
        var attempt = 0
        while true {
            var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData)
            request.httpMethod = method
            for (name, value) in headers {
                request.setValue(value, forHTTPHeaderField: name)
            }
            request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
            let (data, response) = try await Self.transfer(request, body: body, server: server, session: session)
            let status = response.statusCode
            if (200 ..< 300).contains(status) || accepting.contains(status) {
                return (data, response)
            }
            let failure = CartoucheDriveFailure.parse(data, status: status)
            if failure.isExpiredToken, !renewed {
                renewed = true
                token = try await accessToken(force: true)
                continue
            }
            let goesAgain: Bool
            switch again {
            case .always: goesAgain = failure.isPassing
            case .afterRateLimit: goesAgain = failure.isRateLimit
            case .never: goesAgain = false
            }
            if goesAgain, attempt < Self.pauses.count {
                try await Task.sleep(nanoseconds: Self.pauses[attempt])
                attempt += 1
                continue
            }
            throw failure
        }
    }

    /// ENDPOINT, then PARTS, each a component of the path, then QUERY.
    private func url(_ endpoint: URL, _ parts: [String], query: [(String, String)] = []) throws -> URL {
        var text = endpoint.absoluteString
        while text.hasSuffix("/") {
            text.removeLast()
        }
        for part in parts {
            text += "/" + CartoucheDriveSignIn.encode(part)
        }
        if !query.isEmpty {
            text += "?" + CartoucheDriveSignIn.query(query)
        }
        guard let url = URL(string: text) else {
            throw CartoucheStorageError(.badAnswer, CartoucheText.storageDriveBadAnswer)
        }
        return url
    }

    /// BODY, with what the Drive API said went wrong as the player reads it.
    fileprivate func translating<T>(_ body: () async throws -> T) async throws -> T {
        do {
            return try await body()
        } catch let failure as CartoucheDriveFailure {
            throw Self.explained(failure)
        }
    }

    /// FAILURE as the player reads it, with the API's own error under it,
    /// whose status and reason reports and measurements take.
    static func explained(_ failure: CartoucheDriveFailure) -> CartoucheStorageError {
        if failure.isDriveOff {
            return CartoucheStorageError(.driveOff, CartoucheText.storageDriveOff, underlying: failure)
        }
        if failure.isScopeMissing {
            return CartoucheStorageError(.driveScope, CartoucheText.storageDriveScope, underlying: failure)
        }
        if failure.isFull {
            return CartoucheStorageError(.noSpaceThere, CartoucheText.storageDriveFull, underlying: failure)
        }
        if failure.isNotFound {
            return CartoucheStorageError(.notThere, CartoucheText.storageDriveNotThere, underlying: failure)
        }
        if failure.reason == "insufficientFilePermissions" {
            return CartoucheStorageError(.readOnly, CartoucheText.storageDriveReadOnly, underlying: failure)
        }
        return CartoucheStorageError(.driveFailed, CartoucheText.storageDriveFailed(failure.localizedDescription),
                                     underlying: failure)
    }

    // MARK: Paths

    /// PATH's names, composed, as Cartouche finds files by.
    private static func parts(_ path: String) -> [String] {
        path.split(separator: "/").map { String($0).precomposedStringWithCanonicalMapping }
    }

    private static func key(_ path: String) -> String {
        parts(path).joined(separator: "/")
    }

    /// Whether FILE is a folder when FOLDER says so, a file with bytes when
    /// it says not, and either without it.
    private static func fits(_ file: CartoucheDriveFile, _ folder: Bool?) -> Bool {
        guard let folder else { return file.isFolder || file.isBinary }
        return folder ? file.isFolder : file.isBinary
    }

    /// What is at PATH from My Drive's root, the newest of what has its
    /// name, that fits FOLDER; nil when something on the way is not there.
    private func find(_ path: String, folder wanted: Bool? = nil) async throws -> CartoucheDriveFile? {
        let parts = Self.parts(path)
        guard !parts.isEmpty else { return wanted == false ? nil : .root }
        var current = CartoucheDriveFile.root
        var walked: [String] = []
        for (index, part) in parts.enumerated() {
            walked.append(part)
            let key = walked.joined(separator: "/")
            let kind: Bool? = index == parts.count - 1 ? wanted : true
            if let known = state.file(at: key), Self.fits(known, kind) {
                current = known
                continue
            }
            guard let found = try await child(part, in: current.id, folder: kind) else { return nil }
            state.keep(found, at: key)
            current = found
        }
        return current
    }

    /// The newest of what the folder of ID PARENT holds under NAME that
    /// fits FOLDER: by its name as Cartouche has it, composed, or
    /// decomposed, as a Mac may have named it.
    private func child(_ name: String, in parent: String, folder wanted: Bool?) async throws -> CartoucheDriveFile? {
        for candidate in CartoucheDriveQuery.spellings(name) {
            let found = try await listAll(CartoucheDriveQuery.named(candidate, in: parent))
                .filter { Self.fits($0, wanted) }
                .sorted(by: CartoucheDriveFile.newestFirst)
            if let newest = found.first {
                return newest
            }
        }
        return nil
    }

    /// Every file the query Q finds, page after page.
    private func listAll(_ q: String) async throws -> [CartoucheDriveFile] {
        var files: [CartoucheDriveFile] = []
        var token: String?
        var pages = 0
        repeat {
            var query = [("q", q), ("fields", CartoucheDriveListing.fields), ("pageSize", "1000"), ("spaces", "drive")]
            if let token {
                query.append(("pageToken", token))
            }
            let (data, _) = try await api("GET", url(endpoints.api, ["files"], query: query))
            guard let page = CartoucheDriveListing.parse(data) else {
                throw CartoucheStorageError(.badAnswer, CartoucheText.storageDriveBadAnswer)
            }
            files += page.files
            token = page.next
            pages += 1
            if token != nil, pages >= 100 {
                throw CartoucheStorageError(.listingTooLong, CartoucheText.storageFTPTooLong)
            }
        } while token != nil
        return files
    }

    /// The account's address, and the room on the Drive.
    func about() async throws -> CartoucheDriveAbout? {
        try await translating {
            let (data, _) = try await api("GET", url(endpoints.api, ["about"], query: [("fields", CartoucheDriveAbout.fields)]))
            return CartoucheDriveAbout.parse(data)
        }
    }

    // MARK: CartoucheRemote

    /// Drive says what an account may do in a folder only when asked
    /// (canWrite).
    var isReadOnly: Bool { false }

    func list(_ path: String) async throws -> [CartoucheRemoteItem] {
        try await translating {
            guard let folder = try await find(path, folder: true) else { throw CartoucheDriveFailure.notFound }
            let files = try await listAll(CartoucheDriveQuery.children(of: folder.id))
            // Neither Drive's own files nor a hidden name, nor one with "/",
            // which a path would cut; of the folders or of the files of a
            // name, the newest, which a path names.
            var shown: [String: CartoucheDriveFile] = [:]
            for file in files where Self.fits(file, nil) {
                let name = file.name.precomposedStringWithCanonicalMapping
                guard !name.isEmpty, !name.hasPrefix("."), !name.contains("/") else { continue }
                let key = (file.isFolder ? "folder|" : "file|") + name
                if let kept = shown[key], CartoucheDriveFile.newestFirst(kept, file) { continue }
                shown[key] = file
            }
            let base = Self.key(path)
            var items: [CartoucheRemoteItem] = []
            for file in shown.values.sorted(by: { $0.name < $1.name }) {
                let name = file.name.precomposedStringWithCanonicalMapping
                state.keep(file, at: base.isEmpty ? name : base + "/" + name)
                items.append(CartoucheRemoteItem(name: file.name, isFolder: file.isFolder, size: file.size ?? 0,
                                                 modified: file.modified))
            }
            return items
        }
    }

    func open(_ path: String) async throws -> CartoucheByteSource {
        try await translating {
            guard let file = try await find(path, folder: false) else { throw CartoucheDriveFailure.notFound }
            let media = try url(endpoints.api, ["files", file.id], query: [("alt", "media")])
            let source: CartoucheByteSource = CartoucheReadAhead(size: file.size ?? 0) { [self] offset, count in
                try await translating {
                    let (data, response) = try await api("GET", media, headers: [
                        "Range": CartoucheDriveUpload.readRange(offset: offset, count: count),
                        // The bytes as they are kept, for the ranges to fall right.
                        "Accept-Encoding": "identity",
                    ])
                    // The whole file, from a server that took no range.
                    if response.statusCode == 200 {
                        let start = Int(offset)
                        guard start < data.count else { return Data() }
                        return data.subdata(in: start ..< min(data.count, start + count))
                    }
                    return data
                }
            }
            return source
        }
    }

    func create(_ path: String, size: UInt64?) async throws -> CartoucheRemoteUpload {
        try await translating {
            let name = CartoucheStoragePath.name(path).precomposedStringWithCanonicalMapping
            guard !name.isEmpty, let parent = try await find(CartoucheStoragePath.parent(path), folder: true) else {
                throw CartoucheDriveFailure.notFound
            }
            let upload: CartoucheRemoteUpload = CartoucheDriveFileUpload(remote: self, path: path, name: name,
                                                                         parent: parent.id, size: size)
            return upload
        }
    }

    func makeFolder(_ path: String) async throws {
        try await translating {
            let name = CartoucheStoragePath.name(path).precomposedStringWithCanonicalMapping
            guard !name.isEmpty, let parent = try await find(CartoucheStoragePath.parent(path), folder: true) else {
                throw CartoucheDriveFailure.notFound
            }
            // Drive takes any number of folders of a name in a folder: the
            // one there is the one asked for.
            if let folder = try await child(name, in: parent.id, folder: true) {
                state.keep(folder, at: Self.key(path))
                return
            }
            let (data, _) = try await api("POST", url(endpoints.api, ["files"], query: [("fields", CartoucheDriveFile.fields)]),
                                          headers: ["Content-Type": "application/json; charset=UTF-8"],
                                          body: CartoucheDriveMetadata.folder(name, in: parent.id).json,
                                          again: .afterRateLimit)
            guard let folder = CartoucheDriveFile.parse(data) else {
                throw CartoucheStorageError(.badAnswer, CartoucheText.storageDriveBadAnswer)
            }
            state.keep(folder, at: Self.key(path))
        }
    }

    func delete(_ path: String) async throws {
        try await translating {
            guard !Self.parts(path).isEmpty, let file = try await find(path) else { return }
            try await remove(file.id)
            state.forget(Self.key(path))
        }
    }

    /// Removes the file or the folder of ID for good, with what the folder
    /// holds: the bin would keep it, and the room it takes, for 30 days.
    private func remove(_ id: String) async throws {
        do {
            _ = try await api("DELETE", url(endpoints.api, ["files", id]))
        } catch let failure as CartoucheDriveFailure where failure.isNotFound {
            // Gone already.
        }
    }

    func freeSpace() async throws -> UInt64? {
        try await about()?.freeSpace
    }

    func canWrite(_ path: String) async throws -> Bool {
        try await translating {
            guard let folder = try await find(path, folder: true) else { throw CartoucheDriveFailure.notFound }
            let (data, _) = try await api("GET", url(endpoints.api, ["files", folder.id],
                                                     query: [("fields", CartoucheDriveCapabilities.fields)]))
            return CartoucheDriveCapabilities.canAddChildren(data) ?? true
        }
    }

    func disconnect() async {
        session.finishTasksAndInvalidate()
    }

    // MARK: Writing a file

    /// What Google said of a piece of a file sent to it.
    enum Received {
        /// It holds this many bytes of the file, from its start.
        case holds(UInt64)
        /// It holds the whole file, now in its folder.
        case whole(CartoucheDriveFile)
    }

    /// Starts the upload of a file named NAME to the folder of ID PARENT:
    /// gives the address its pieces go to.
    fileprivate func startUpload(_ name: String, in parent: String, size: UInt64?) async throws -> URL {
        var headers = ["Content-Type": "application/json; charset=UTF-8",
                       "X-Upload-Content-Type": "application/octet-stream"]
        if let size {
            headers["X-Upload-Content-Length"] = String(size)
        }
        let address = try url(endpoints.upload, ["files"],
                              query: [("uploadType", "resumable"), ("fields", CartoucheDriveFile.fields)])
        let (_, response) = try await api("POST", address, headers: headers,
                                          body: CartoucheDriveMetadata.file(name, in: parent).json, again: .afterRateLimit)
        guard let location = response.value(forHTTPHeaderField: "Location"), let upload = URL(string: location),
              endpoints.serves(upload) else {
            throw CartoucheStorageError(.badAnswer, CartoucheText.storageDriveBadAnswer)
        }
        return upload
    }

    /// Sends DATA, the file's bytes at OFFSET, to UPLOAD, with TOTAL, the
    /// file's size, once the piece is its last; without DATA, asks how much
    /// Google holds.
    fileprivate func send(_ data: Data, at offset: UInt64, total: UInt64?, to upload: URL) async throws -> Received {
        let range = CartoucheDriveUpload.range(offset: offset, count: data.count, total: total)
        let (body, response) = try await api("PUT", upload, headers: ["Content-Range": range], body: data,
                                             accepting: [308], again: .never)
        if response.statusCode == 308 {
            guard let held = CartoucheDriveUpload.received(response.value(forHTTPHeaderField: "Range")) else {
                throw CartoucheStorageError(.badAnswer, CartoucheText.storageDriveBadAnswer)
            }
            return .holds(held)
        }
        guard let file = CartoucheDriveFile.parse(body) else {
            throw CartoucheStorageError(.badAnswer, CartoucheText.storageDriveBadAnswer)
        }
        return .whole(file)
    }

    /// Gives UPLOAD up: Google drops what it holds of the file.
    fileprivate func cancelUpload(_ upload: URL) async {
        _ = try? await api("DELETE", upload, accepting: [499], again: .never)
    }

    /// FILE, just written at PATH to the folder of ID PARENT, in place: the
    /// other files of its name there go, however a Mac spelled it, as a
    /// file written over another. Never a folder, a Google Doc or a
    /// shortcut, which Cartouche did not write.
    fileprivate func place(_ file: CartoucheDriveFile, at path: String, in parent: String) async {
        state.forget(Self.key(path))
        state.keep(file, at: Self.key(path))
        var others: [CartoucheDriveFile] = []
        for spelling in CartoucheDriveQuery.spellings(file.name) {
            guard let found = try? await listAll(CartoucheDriveQuery.named(spelling, in: parent)) else { return }
            others += found
        }
        for other in others where other.id != file.id && other.isBinary {
            do {
                try await remove(other.id)
            } catch {
                NSLog("[Cartouche] the older %@ stays on Google Drive: %@", file.name, error.localizedDescription)
            }
        }
    }

    /// Whether ERROR passes: the network, or Google, failing for a moment.
    fileprivate static func isPassing(_ error: Error) -> Bool {
        if let failure = error as? CartoucheDriveFailure { return failure.isPassing }
        if let offline = error as? CartoucheStorageOffline { return !offline.isSignedOut }
        return error is URLError
    }
}

/// What a connection to the Drive keeps between its requests: the access
/// token, and the files and folders found, by their paths. Behind a lock:
/// an install reads ahead while it reads.
private final class CartoucheDriveState: @unchecked Sendable {
    private let lock = NSLock()
    private var access: (token: String, until: Date)?
    private var files: [String: CartoucheDriveFile] = [:]

    /// The access token, if it lasts until DATE.
    func token(validAt date: Date) -> String? {
        lock.lock()
        defer { lock.unlock() }
        guard let access, access.until > date else { return nil }
        return access.token
    }

    func keep(token: String, until: Date) {
        lock.lock()
        access = (token, until)
        lock.unlock()
    }

    func file(at path: String) -> CartoucheDriveFile? {
        lock.lock()
        defer { lock.unlock() }
        return files[path]
    }

    func keep(_ file: CartoucheDriveFile, at path: String) {
        lock.lock()
        files[path] = file
        lock.unlock()
    }

    /// Forgets PATH, and what was found under it.
    func forget(_ path: String) {
        lock.lock()
        files = files.filter { $0.key != path && !$0.key.hasPrefix(path + "/") }
        lock.unlock()
    }
}

/// Follows no redirection: the access token goes to the Drive API alone,
/// and the 308 of a resumable upload is Google's answer, not a redirection.
private final class CartoucheDriveNoRedirection: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest) async -> URLRequest? {
        nil
    }
}

/// A file being written to the player's Drive with Google's resumable
/// upload, in pieces of 8 MiB: a piece that fails on the way goes again
/// from where Google holds the file. Google makes the file only once it is
/// whole, so that the one there, if any, stays until then.
private final class CartoucheDriveFileUpload: CartoucheRemoteUpload {
    /// Every piece but the last: a multiple of Google's 256 KiB.
    static let piece = 32 * CartoucheDriveUpload.granule

    private let remote: CartoucheDrive
    private let path: String
    private let name: String
    private let parent: String
    private let size: UInt64?
    private var upload: URL?
    /// How much of the file Google holds, and the bytes after them.
    private var held: UInt64 = 0
    private var buffer = Data()
    /// The pieces in a row that failed, or that Google took none of.
    private var stalls = 0

    init(remote: CartoucheDrive, path: String, name: String, parent: String, size: UInt64?) {
        self.remote = remote
        self.path = path
        self.name = name
        self.parent = parent
        self.size = size
    }

    func write(_ data: Data) async throws {
        buffer.append(data)
        try await remote.translating {
            while self.buffer.count >= Self.piece {
                _ = try await self.push(Self.piece, last: false)
            }
        }
    }

    func finish() async throws {
        let file = try await remote.translating { () async throws -> CartoucheDriveFile in
            while true {
                if let file = try await self.push(self.buffer.count, last: true) {
                    return file
                }
            }
        }
        await remote.place(file, at: path, in: parent)
    }

    func cancel() async {
        buffer = Data()
        guard let upload else { return }
        self.upload = nil
        await remote.cancelUpload(upload)
    }

    private func started() async throws -> URL {
        if let upload { return upload }
        let made = try await remote.startUpload(name, in: parent, size: size)
        upload = made
        return made
    }

    /// Sends the buffer's first COUNT bytes, the file's last ones when LAST
    /// says so, and drops from the buffer what Google then holds: what it
    /// does not hold goes with the next piece. Gives the file once Google
    /// holds it whole.
    private func push(_ count: Int, last: Bool) async throws -> CartoucheDriveFile? {
        let upload = try await started()
        let total: UInt64? = last ? held + UInt64(buffer.count) : nil
        let before = held
        let received: CartoucheDrive.Received
        do {
            received = try await remote.send(Data(buffer.prefix(count)), at: held, total: total, to: upload)
        } catch {
            received = try await askAfter(error, upload: upload, total: total)
        }
        switch received {
        case let .whole(file):
            held += UInt64(buffer.count)
            buffer = Data()
            stalls = 0
            return file
        case let .holds(bytes):
            guard bytes >= held, bytes - held <= UInt64(buffer.count) else {
                throw CartoucheStorageError(.badAnswer, CartoucheText.storageDriveBadAnswer)
            }
            buffer = Data(buffer.dropFirst(Int(bytes - held)))
            held = bytes
            if held > before {
                stalls = 0
            } else {
                stalls += 1
                guard stalls <= CartoucheDrive.pauses.count else {
                    throw CartoucheStorageError(.badAnswer, CartoucheText.storageDriveBadAnswer)
                }
            }
            return nil
        }
    }

    /// After ERROR, which failed for a moment: how much of the file Google
    /// holds, asked after a pause, and again after a longer one while that
    /// fails too.
    private func askAfter(_ error: Error, upload: URL, total: UInt64?) async throws -> CartoucheDrive.Received {
        var failure = error
        while CartoucheDrive.isPassing(failure), stalls < CartoucheDrive.pauses.count {
            try await Task.sleep(nanoseconds: CartoucheDrive.pauses[stalls])
            stalls += 1
            do {
                return try await remote.send(Data(), at: held, total: total, to: upload)
            } catch {
                failure = error
            }
        }
        throw failure
    }
}
