//
//  CartoucheDrive.swift
//  Cartouche
//
//  What Cartouche needs to reach the player's Google Drive, without the
//  network: the player's own OAuth client, Google's sign-in with PKCE and
//  its answers, and those of the Drive API, version 3.
//  CartoucheStorageDrive.swift sends the requests, and
//  CartoucheStorageDriveView.swift opens Google's sign-in page.
//
//  Cartouche ships no Google client, ID or key: the player makes an OAuth
//  client of their own, of the iOS type, in a Google Cloud project of
//  theirs, and pastes its ID into Cartouche, which signs in with it. Only
//  the player's own My Drive, with their own account: never a link to
//  follow, a file someone shared, a shared drive or a public file.
//
//  Platform-independent: tested on its own by launcher/Package.swift.
//

import CryptoKit
import Foundation

// MARK: The player's client

/// The player's own OAuth client, of the iOS type, by its ID as Google
/// Cloud shows it: "1234567890-abc123.apps.googleusercontent.com".
struct CartoucheDriveClient: Hashable, Sendable {
    static let idSuffix = ".apps.googleusercontent.com"
    static let schemePrefix = "com.googleusercontent.apps."

    /// The ID without its suffix: "1234567890-abc123".
    let prefix: String

    /// TEXT as the player pasted it: the client ID, or the URL scheme Google
    /// Cloud shows beside it, which is the ID reversed; nil for what is
    /// neither.
    init?(_ text: String) {
        var rest = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if rest.hasPrefix(Self.schemePrefix) {
            rest.removeFirst(Self.schemePrefix.count)
            // The whole redirect: "com.googleusercontent.apps.123-abc:/oauth2redirect".
            if let colon = rest.firstIndex(of: ":") {
                rest = String(rest[..<colon])
            }
        } else if rest.hasSuffix(Self.idSuffix) {
            rest.removeLast(Self.idSuffix.count)
        } else {
            return nil
        }
        let parts = rest.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2, (1 ... 32).contains(parts[0].count), (1 ... 128).contains(parts[1].count),
              parts[0].allSatisfy({ $0.isASCII && $0.isNumber }),
              parts[1].allSatisfy({ $0.isASCII && ($0.isNumber || $0.isLetter) }) else {
            return nil
        }
        prefix = rest
    }

    /// The client ID in TEXT, wherever it is: alone, or in a line, a JSON
    /// file or a property list Google Cloud gave with it.
    static func find(in text: String) -> CartoucheDriveClient? {
        if let client = CartoucheDriveClient(text) { return client }
        let word = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-.")
        for candidate in text.components(separatedBy: word.inverted) where candidate.count > idSuffix.count {
            if let client = CartoucheDriveClient(candidate) { return client }
        }
        return nil
    }

    /// The ID, as the requests name it.
    var id: String { prefix + Self.idSuffix }

    /// The scheme of the address Google sends the sign-in back to: the ID
    /// reversed, which a client of the iOS type takes without a setting.
    var scheme: String { Self.schemePrefix + prefix }

    var redirectURI: String { scheme + ":/oauth2redirect" }
}

/// Where Google's servers are: Google's own, or the stand-in the storage
/// tests run (launcher/StorageTests/drive_server.py).
struct CartoucheDriveEndpoints: Hashable, Sendable {
    /// The page that signs the player in.
    var signIn: URL
    /// Where the tokens come from.
    var token: URL
    /// The Drive API, and where it takes the files sent to it.
    var api: URL
    var upload: URL

    static let google = CartoucheDriveEndpoints(
        signIn: URL(string: "https://accounts.google.com/o/oauth2/v2/auth")!,
        token: URL(string: "https://oauth2.googleapis.com/token")!,
        api: URL(string: "https://www.googleapis.com/drive/v3")!,
        upload: URL(string: "https://www.googleapis.com/upload/drive/v3")!
    )

    /// A stand-in at BASE, such as http://127.0.0.1:9100, with Google's
    /// paths.
    static func standIn(_ base: URL) -> CartoucheDriveEndpoints {
        CartoucheDriveEndpoints(signIn: base.appendingPathComponent("o/oauth2/v2/auth"),
                                token: base.appendingPathComponent("token"),
                                api: base.appendingPathComponent("drive/v3"),
                                upload: base.appendingPathComponent("upload/drive/v3"))
    }

    /// Whether URL is on the Drive API's servers, the only ones the access
    /// token goes to: an upload's own address too, which Google gives.
    func serves(_ url: URL) -> Bool {
        [api, upload].contains { endpoint in
            endpoint.scheme?.lowercased() == url.scheme?.lowercased()
                && endpoint.host?.lowercased() == url.host?.lowercased() && endpoint.port == url.port
        }
    }
}

// MARK: Signing in

/// PKCE (RFC 7636): a secret of one sign-in, which only its own request for
/// the tokens shows, so that a code caught on its way is worth nothing.
struct CartoucheDrivePKCE: Sendable {
    let verifier: String

    /// A new verifier: 32 random bytes, as 43 characters of base64url.
    init() {
        verifier = Self.randomText()
    }

    init(verifier: String) {
        self.verifier = verifier
    }

    /// The verifier's SHA-256, in base64url, as the sign-in sends it.
    var challenge: String {
        Self.base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
    }

    /// 32 random bytes in base64url: a verifier, or a sign-in's state.
    static func randomText() -> String {
        let key = SymmetricKey(size: .bits256)
        return base64URL(key.withUnsafeBytes { Data($0) })
    }

    static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

/// Why a sign-in on Google's page gave no code.
enum CartoucheDriveSignInFailure: LocalizedError, Equatable, Sendable {
    /// The player did not allow the access on Google's page.
    case refused
    /// Google said why, in a word of its own: "invalid_scope"…
    case google(String)
    /// An address that is not this sign-in's: another state, or no code.
    case notThisSignIn

    var errorDescription: String? {
        switch self {
        case .refused: return "access_denied"
        case let .google(word): return word
        case .notThisSignIn: return "not this sign-in"
        }
    }
}

/// Google's sign-in for the player's own client: the page that asks the
/// player, the address it sends them back to, and the requests for the
/// tokens.
enum CartoucheDriveSignIn {
    /// Every file of the player's Drive, to read, write and remove: the
    /// games they keep there, whatever put them there, and the copies of
    /// their saves. Google counts it among its restricted scopes.
    static let scope = "https://www.googleapis.com/auth/drive"

    /// Google's page that asks the player to sign in, with ACCOUNT, their
    /// address, when Cartouche knows it, and to let their client reach their
    /// Drive; with CONSENT, it asks them to allow it even if they did
    /// before, for Google to give a lasting sign-in again.
    static func page(_ client: CartoucheDriveClient, challenge: String, state: String, account: String? = nil,
                     consent: Bool = false, endpoints: CartoucheDriveEndpoints = .google) -> URL? {
        var pairs = [
            ("client_id", client.id),
            ("redirect_uri", client.redirectURI),
            ("response_type", "code"),
            ("scope", scope),
            ("code_challenge", challenge),
            ("code_challenge_method", "S256"),
            ("state", state),
        ]
        if let account, !account.isEmpty {
            pairs.append(("login_hint", account))
        }
        if consent {
            pairs.append(("prompt", "consent"))
        }
        return URL(string: endpoints.signIn.absoluteString + "?" + query(pairs))
    }

    /// The code the address Google sent the player back to holds, to
    /// exchange for the tokens. Throws when the player did not allow the
    /// access, when Google says why it gave none, and for an address that is
    /// not this sign-in's.
    static func code(in callback: URL, client: CartoucheDriveClient, state: String) throws -> String {
        guard callback.scheme?.lowercased() == client.scheme,
              let components = URLComponents(url: callback, resolvingAgainstBaseURL: false) else {
            throw CartoucheDriveSignInFailure.notThisSignIn
        }
        let items = components.queryItems ?? []
        func value(_ name: String) -> String? {
            items.first { $0.name == name }?.value
        }
        guard value("state") == state else { throw CartoucheDriveSignInFailure.notThisSignIn }
        if let error = value("error") {
            throw error == "access_denied" ? CartoucheDriveSignInFailure.refused : CartoucheDriveSignInFailure.google(error)
        }
        guard let code = value("code"), !code.isEmpty else { throw CartoucheDriveSignInFailure.notThisSignIn }
        return code
    }

    /// The form that exchanges a sign-in's CODE for the tokens, with its
    /// PKCE VERIFIER. A client of the iOS type has no secret.
    static func exchange(code: String, verifier: String, client: CartoucheDriveClient) -> [(String, String)] {
        [("code", code), ("client_id", client.id), ("redirect_uri", client.redirectURI),
         ("grant_type", "authorization_code"), ("code_verifier", verifier)]
    }

    /// The form that asks for a new access token with the refresh token.
    static func renewal(refreshToken: String, client: CartoucheDriveClient) -> [(String, String)] {
        [("client_id", client.id), ("refresh_token", refreshToken), ("grant_type", "refresh_token")]
    }

    /// PAIRS as a query or an application/x-www-form-urlencoded body: each
    /// name and value with every byte but A-Z, a-z, 0-9, "-", ".", "_" and
    /// "~" as %XX.
    static func query(_ pairs: [(String, String)]) -> String {
        pairs.map { encode($0.0) + "=" + encode($0.1) }.joined(separator: "&")
    }

    static func encode(_ text: String) -> String {
        text.addingPercentEncoding(withAllowedCharacters: unreserved) ?? text
    }

    private static let unreserved = CharacterSet(charactersIn:
        "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
}

/// Google's answer to a request for the tokens.
struct CartoucheDriveGrant: Equatable, Sendable {
    let accessToken: String
    /// How long the access token lasts, in seconds: an hour.
    let expiresIn: Int
    /// After a sign-in; a renewal gives none, the one kept stays good.
    let refreshToken: String?
    /// The scopes the player allowed, between spaces.
    let scope: String?

    private struct Answer: Decodable {
        let accessToken: String?
        let expiresIn: Int?
        let refreshToken: String?
        let scope: String?

        enum CodingKeys: String, CodingKey {
            case accessToken = "access_token"
            case expiresIn = "expires_in"
            case refreshToken = "refresh_token"
            case scope
        }
    }

    static func parse(_ data: Data) -> CartoucheDriveGrant? {
        guard let answer = try? JSONDecoder().decode(Answer.self, from: data),
              let token = answer.accessToken, !token.isEmpty else { return nil }
        let refresh = answer.refreshToken.flatMap { $0.isEmpty ? nil : $0 }
        return CartoucheDriveGrant(accessToken: token, expiresIn: answer.expiresIn ?? 3_600, refreshToken: refresh,
                                   scope: answer.scope)
    }

    /// Whether the player let Cartouche reach their whole Drive: Google's
    /// page lets them leave a scope unchecked.
    var allowsDrive: Bool {
        guard let scope else { return true }
        return scope.split(separator: " ").contains { $0 == CartoucheDriveSignIn.scope }
    }
}

/// What Google's token server said went wrong.
struct CartoucheDriveTokenFailure: LocalizedError, Hashable, Sendable {
    let status: Int
    /// "invalid_grant", "invalid_client", "unauthorized_client"…
    let code: String
    let message: String

    /// Google's code alone: its message may name the player's project.
    var errorDescription: String? {
        code.isEmpty ? "HTTP \(status)" : "HTTP \(status) \(code)"
    }

    /// The sign-in no longer works: seven days passed for a client of a
    /// project in testing, or the player took the access back.
    var needsSignIn: Bool { code == "invalid_grant" }

    /// Google knows no such client, or it is not of the iOS type.
    var isClientRefused: Bool {
        ["invalid_client", "unauthorized_client", "deleted_client"].contains(code)
    }

    private struct Answer: Decodable {
        let error: String?
        let errorDescription: String?

        enum CodingKeys: String, CodingKey {
            case error
            case errorDescription = "error_description"
        }
    }

    static func parse(_ data: Data, status: Int) -> CartoucheDriveTokenFailure {
        let answer = try? JSONDecoder().decode(Answer.self, from: data)
        return CartoucheDriveTokenFailure(status: status, code: answer?.error ?? "", message: answer?.errorDescription ?? "")
    }
}

// MARK: The Drive API's answers

/// A file or a folder of the player's Drive, as the API gives it.
struct CartoucheDriveFile: Hashable, Sendable {
    static let folderType = "application/vnd.google-apps.folder"
    /// What the types of Drive's own files start with: Docs, Sheets,
    /// shortcuts, folders, none with bytes to read.
    static let googleTypes = "application/vnd.google-apps."
    /// The fields Cartouche asks for, for each file.
    static let fields = "id,name,mimeType,size,modifiedTime"

    /// My Drive's root, as the API takes it.
    static let root = CartoucheDriveFile(id: "root", name: "", mimeType: folderType, size: nil, modified: nil)

    let id: String
    let name: String
    let mimeType: String
    /// Nil for a folder and for Drive's own files.
    let size: UInt64?
    let modified: Date?

    var isFolder: Bool { mimeType == Self.folderType }

    /// A file with bytes of its own to read: not a folder, a Google Doc or a
    /// shortcut.
    var isBinary: Bool { !mimeType.hasPrefix(Self.googleTypes) }

    struct Item: Decodable {
        let id: String?
        let name: String?
        let mimeType: String?
        /// In bytes, as text.
        let size: String?
        let modifiedTime: String?

        var file: CartoucheDriveFile? {
            guard let id, !id.isEmpty, let name else { return nil }
            return CartoucheDriveFile(id: id, name: name, mimeType: mimeType ?? "application/octet-stream",
                                      size: size.flatMap { UInt64($0) },
                                      modified: modifiedTime.flatMap(CartoucheDriveFile.date))
        }
    }

    /// The file a request's answer DATA describes.
    static func parse(_ data: Data) -> CartoucheDriveFile? {
        (try? JSONDecoder().decode(Item.self, from: data))?.file
    }

    /// "2026-11-12T09:06:36.123Z", as Drive gives times.
    static func date(_ text: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: text) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: text)
    }

    /// The newest first, whatever has no time last, then by ID, for the
    /// files of a name.
    static func newestFirst(_ first: CartoucheDriveFile, _ second: CartoucheDriveFile) -> Bool {
        let one = first.modified ?? .distantPast
        let other = second.modified ?? .distantPast
        if one != other { return one > other }
        return first.id < second.id
    }
}

/// One page of the files in a folder.
struct CartoucheDriveListing: Hashable, Sendable {
    /// The fields of a page.
    static let fields = "nextPageToken,files(\(CartoucheDriveFile.fields))"

    var files: [CartoucheDriveFile] = []
    /// The token of the next page, when there is one.
    var next: String?

    private struct Page: Decodable {
        let nextPageToken: String?
        let files: [CartoucheDriveFile.Item]?
    }

    static func parse(_ data: Data) -> CartoucheDriveListing? {
        guard let page = try? JSONDecoder().decode(Page.self, from: data) else { return nil }
        let next = page.nextPageToken.flatMap { $0.isEmpty ? nil : $0 }
        return CartoucheDriveListing(files: (page.files ?? []).compactMap(\.file), next: next)
    }
}

/// The player's account, and the room on their Drive.
struct CartoucheDriveAbout: Hashable, Sendable {
    static let fields = "user(emailAddress),storageQuota(limit,usage)"

    /// The address of the account signed in to.
    let account: String?
    /// The room in all, nil for a Drive without a limit, and the room used.
    let limit: UInt64?
    let usage: UInt64

    var freeSpace: UInt64? {
        limit.map { $0 > usage ? $0 - usage : 0 }
    }

    private struct Answer: Decodable {
        struct User: Decodable {
            let emailAddress: String?
        }

        struct Quota: Decodable {
            let limit: String?
            let usage: String?
        }

        let user: User?
        let storageQuota: Quota?
    }

    static func parse(_ data: Data) -> CartoucheDriveAbout? {
        guard let answer = try? JSONDecoder().decode(Answer.self, from: data) else { return nil }
        return CartoucheDriveAbout(account: answer.user?.emailAddress,
                                   limit: answer.storageQuota?.limit.flatMap { UInt64($0) },
                                   usage: answer.storageQuota?.usage.flatMap { UInt64($0) } ?? 0)
    }
}

/// What the Drive API said went wrong.
struct CartoucheDriveFailure: LocalizedError, Hashable, Sendable {
    let status: Int
    /// Google's reason: "notFound", "userRateLimitExceeded",
    /// "storageQuotaExceeded", "accessNotConfigured"…
    let reason: String
    let message: String
    /// Where the player turns the Drive API on in their project, when Google
    /// says it is off there.
    let activation: URL?

    /// Google's reason alone: its message may name the player's project
    /// or one of their files.
    var errorDescription: String? {
        reason.isEmpty ? "HTTP \(status)" : "HTTP \(status) \(reason)"
    }

    /// A path Cartouche looked for that is not on the Drive, as the API
    /// says of a file it does not know.
    static let notFound = CartoucheDriveFailure(status: 404, reason: "notFound", message: "", activation: nil)

    private struct Answer: Decodable {
        struct Body: Decodable {
            struct Reason: Decodable {
                let reason: String?
            }

            struct Detail: Decodable {
                let reason: String?
                let metadata: [String: String]?
            }

            let message: String?
            let status: String?
            let errors: [Reason]?
            let details: [Detail]?
        }

        let error: Body?
    }

    static func parse(_ data: Data, status: Int) -> CartoucheDriveFailure {
        let body = (try? JSONDecoder().decode(Answer.self, from: data))?.error
        let reason = body?.errors?.compactMap(\.reason).first
            ?? body?.details?.compactMap(\.reason).first
            ?? body?.status
            ?? ""
        let message = body?.message ?? ""
        let link = body?.details?.compactMap { $0.metadata?["activationUrl"] }.first ?? Self.consoleLink(in: message)
        return CartoucheDriveFailure(status: status, reason: reason, message: message,
                                     activation: link.flatMap(Self.consoleURL))
    }

    /// The first address of Google Cloud's console in TEXT.
    private static func consoleLink(in text: String) -> String? {
        text.split(whereSeparator: { $0 == " " || $0 == "\n" }).map(String.init).first { word in
            word.hasPrefix("https://console.developers.google.com/") || word.hasPrefix("https://console.cloud.google.com/")
        }
    }

    /// TEXT as an address of Google Cloud's console, the only one Cartouche
    /// opens from an answer.
    private static func consoleURL(_ text: String) -> URL? {
        guard let url = URL(string: text.trimmingCharacters(in: CharacterSet(charactersIn: " .,;)"))),
              url.scheme == "https",
              let host = url.host, ["console.developers.google.com", "console.cloud.google.com"].contains(host) else {
            return nil
        }
        return url
    }

    private static let rateReasons: Set<String> = ["userRateLimitExceeded", "rateLimitExceeded", "RATE_LIMIT_EXCEEDED"]

    var isNotFound: Bool { status == 404 }

    /// The access token ran out: it lasts an hour.
    var isExpiredToken: Bool { status == 401 }

    var isRateLimit: Bool {
        status == 429 || (status == 403 && Self.rateReasons.contains(reason))
    }

    /// What passes: too many requests at once, a server that failed for a
    /// moment. Worth trying again a little later.
    var isPassing: Bool {
        isRateLimit || status == 408 || status >= 500
    }

    /// The Drive API is not turned on in the player's project.
    var isDriveOff: Bool {
        ["accessNotConfigured", "SERVICE_DISABLED"].contains(reason)
    }

    /// The player did not let Cartouche reach their whole Drive.
    var isScopeMissing: Bool {
        ["insufficientPermissions", "ACCESS_TOKEN_SCOPE_INSUFFICIENT"].contains(reason)
    }

    /// The Drive is full.
    var isFull: Bool {
        reason == "storageQuotaExceeded"
    }

    /// The account may not do this here: a folder someone shared to read
    /// only.
    var isRefusal: Bool {
        status == 403 && !isRateLimit && !isDriveOff && !isScopeMissing && !isFull
    }
}

/// Whether the player's account can add a file to a folder, as Drive says:
/// not to a folder someone shared with them to read only.
enum CartoucheDriveCapabilities {
    static let fields = "capabilities(canAddChildren)"

    private struct Answer: Decodable {
        struct Capabilities: Decodable {
            let canAddChildren: Bool?
        }

        let capabilities: Capabilities?
    }

    /// Nil when the answer does not say.
    static func canAddChildren(_ data: Data) -> Bool? {
        (try? JSONDecoder().decode(Answer.self, from: data))?.capabilities?.canAddChildren
    }
}

/// What a request that makes a file or a folder says of it: its name, the
/// folder it goes in and, for a folder, its type.
struct CartoucheDriveMetadata: Encodable, Equatable {
    let name: String
    let parents: [String]
    var mimeType: String?

    static func folder(_ name: String, in parent: String) -> CartoucheDriveMetadata {
        CartoucheDriveMetadata(name: name, parents: [parent], mimeType: CartoucheDriveFile.folderType)
    }

    static func file(_ name: String, in parent: String) -> CartoucheDriveMetadata {
        CartoucheDriveMetadata(name: name, parents: [parent], mimeType: nil)
    }

    /// As the request's JSON body.
    var json: Data {
        (try? JSONEncoder().encode(self)) ?? Data("{}".utf8)
    }
}

/// Drive's search queries, for what Cartouche lists.
enum CartoucheDriveQuery {
    /// What the folder of ID holds, but what is in the bin.
    static func children(of folder: String) -> String {
        "'\(escape(folder))' in parents and trashed = false"
    }

    /// What the folder of ID holds under NAME, but what is in the bin.
    static func named(_ name: String, in folder: String) -> String {
        "name = '\(escape(name))' and " + children(of: folder)
    }

    /// TEXT between single quotes, as a query takes it: \ and ' escaped.
    static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "'", with: "\\'")
    }
}

// MARK: Sending a file

/// Google's resumable upload: the file sent in pieces, in order, each a
/// multiple of 256 KiB but the last, which tells the file's size. When a
/// piece fails on the way, the server says how much it holds, and the
/// upload goes on from there.
enum CartoucheDriveUpload {
    /// What every piece but the last is a multiple of.
    static let granule = 256 << 10

    /// The Content-Range of COUNT bytes at OFFSET, with TOTAL, the file's
    /// size, on the last piece only; "bytes */TOTAL" without bytes, to ask
    /// how much the server holds, or to end a file of that size.
    static func range(offset: UInt64, count: Int, total: UInt64?) -> String {
        let size = total.map { String($0) } ?? "*"
        guard count > 0 else { return "bytes */\(size)" }
        return "bytes \(offset)-\(offset + UInt64(count) - 1)/\(size)"
    }

    /// How many bytes the server holds, as its Range header says: "bytes=0-
    /// 1048575" for 1048576, none for nothing yet; nil for what Cartouche
    /// cannot read.
    static func received(_ header: String?) -> UInt64? {
        guard let header = header?.trimmingCharacters(in: .whitespaces), !header.isEmpty else { return 0 }
        guard header.hasPrefix("bytes="), let dash = header.lastIndex(of: "-"),
              let first = UInt64(header[header.index(header.startIndex, offsetBy: 6) ..< dash]), first == 0,
              let last = UInt64(header[header.index(after: dash)...]) else {
            return nil
        }
        return last + 1
    }

    /// The Range of COUNT bytes at OFFSET, to read.
    static func readRange(offset: UInt64, count: Int) -> String {
        "bytes=\(offset)-\(offset + UInt64(max(count, 1)) - 1)"
    }
}
