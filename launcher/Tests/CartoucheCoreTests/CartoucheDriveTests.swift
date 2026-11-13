import XCTest
@testable import CartoucheCore

/// Google Drive without the network (CartoucheDrive.swift): the player's
/// own client, Google's sign-in with PKCE, and the Drive API's answers, as
/// Google's documentation shows them. The storage tests run the requests
/// against a stand-in for Google's servers (launcher/StorageTests).
final class CartoucheDriveTests: XCTestCase {
    private let id = "1234567890-abc123def456.apps.googleusercontent.com"

    private var client: CartoucheDriveClient {
        CartoucheDriveClient(id)!
    }

    // MARK: The player's client

    func testTakesTheClientIDAsGoogleCloudShowsIt() throws {
        for text in [id, "  \(id)\n", id.uppercased(), "com.googleusercontent.apps.1234567890-abc123def456",
                     "com.googleusercontent.apps.1234567890-abc123def456:/oauth2redirect"] {
            let found = try XCTUnwrap(CartoucheDriveClient(text), text)
            XCTAssertEqual(found.id, id, text)
        }
        XCTAssertEqual(client.prefix, "1234567890-abc123def456")
        XCTAssertEqual(client.scheme, "com.googleusercontent.apps.1234567890-abc123def456")
        XCTAssertEqual(client.redirectURI, "com.googleusercontent.apps.1234567890-abc123def456:/oauth2redirect")
    }

    func testRefusesWhatIsNotAClientID() {
        for text in ["", "Cartouche", ".apps.googleusercontent.com", "-abc.apps.googleusercontent.com",
                     "123.apps.googleusercontent.com", "abc-def.apps.googleusercontent.com",
                     "123-abc def.apps.googleusercontent.com", "123-abc.apps.googleusercontent.com.example.com",
                     "123-ab_c.apps.googleusercontent.com", "GOCSPX-AbCdEf", "com.googleusercontent.apps."] {
            XCTAssertNil(CartoucheDriveClient(text), text)
        }
    }

    func testFindsTheClientIDInWhatGoogleCloudGives() {
        let json = """
        {"installed":{"client_id":"\(id)","project_id":"cartouche-123456","auth_uri":"https://accounts.google.com/o/oauth2/auth"}}
        """
        let plist = """
        <key>CLIENT_ID</key>
        <string>\(id)</string>
        <key>REVERSED_CLIENT_ID</key>
        <string>com.googleusercontent.apps.1234567890-abc123def456</string>
        """
        for text in [json, plist, "Client ID: \(id) (copied)"] {
            XCTAssertEqual(CartoucheDriveClient.find(in: text)?.id, id, text)
        }
        XCTAssertNil(CartoucheDriveClient.find(in: "nothing here but https://accounts.google.com/o/oauth2/auth"))
    }

    // MARK: Where Google is

    func testSendsTheAccessTokenToTheDriveAPIAlone() throws {
        let google = CartoucheDriveEndpoints.google
        for address in ["https://www.googleapis.com/drive/v3/files?q=x", "https://www.googleapis.com/upload/drive/v3/files?upload_id=a"] {
            XCTAssertTrue(google.serves(try XCTUnwrap(URL(string: address))), address)
        }
        for address in ["http://www.googleapis.com/drive/v3/files", "https://www.googleapis.com.example.com/drive/v3/files",
                        "https://oauth2.googleapis.com/token", "https://www.googleapis.com:8443/drive/v3",
                        "https://accounts.google.com/o/oauth2/v2/auth"] {
            XCTAssertFalse(google.serves(try XCTUnwrap(URL(string: address))), address)
        }
        let standIn = CartoucheDriveEndpoints.standIn(try XCTUnwrap(URL(string: "http://127.0.0.1:9100")))
        XCTAssertEqual(standIn.signIn.absoluteString, "http://127.0.0.1:9100/o/oauth2/v2/auth")
        XCTAssertEqual(standIn.token.absoluteString, "http://127.0.0.1:9100/token")
        XCTAssertEqual(standIn.api.absoluteString, "http://127.0.0.1:9100/drive/v3")
        XCTAssertEqual(standIn.upload.absoluteString, "http://127.0.0.1:9100/upload/drive/v3")
        XCTAssertTrue(standIn.serves(try XCTUnwrap(URL(string: "http://127.0.0.1:9100/upload/drive/v3/files?upload_id=1"))))
        XCTAssertFalse(standIn.serves(try XCTUnwrap(URL(string: "http://127.0.0.1:9101/drive/v3/files"))))
    }

    // MARK: Signing in

    /// RFC 7636's example, in its appendix B.
    func testPKCEAsItsRFCShowsIt() {
        let pkce = CartoucheDrivePKCE(verifier: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk")
        XCTAssertEqual(pkce.challenge, "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
        let fresh = CartoucheDrivePKCE()
        XCTAssertEqual(fresh.verifier.count, 43)
        XCTAssertNotEqual(fresh.verifier, CartoucheDrivePKCE().verifier)
        XCTAssertTrue(fresh.verifier.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") },
                      fresh.verifier)
    }

    func testGooglesPageAsksForTheDriveWithPKCE() throws {
        let page = try XCTUnwrap(CartoucheDriveSignIn.page(client, challenge: "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM",
                                                           state: "s+t/a=te", account: "joueur@example.com", consent: true))
        let components = try XCTUnwrap(URLComponents(url: page, resolvingAgainstBaseURL: false))
        XCTAssertEqual(components.scheme, "https")
        XCTAssertEqual(components.host, "accounts.google.com")
        XCTAssertEqual(components.path, "/o/oauth2/v2/auth")
        let items = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        XCTAssertEqual(items, [
            "client_id": id,
            "redirect_uri": "com.googleusercontent.apps.1234567890-abc123def456:/oauth2redirect",
            "response_type": "code",
            "scope": "https://www.googleapis.com/auth/drive",
            "code_challenge": "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM",
            "code_challenge_method": "S256",
            "state": "s+t/a=te",
            "login_hint": "joueur@example.com",
            "prompt": "consent",
        ])
        // Every byte but the unreserved ones escaped: a "+" stays one.
        XCTAssertTrue(page.absoluteString.contains("state=s%2Bt%2Fa%3Dte"), page.absoluteString)
        let plain = try XCTUnwrap(CartoucheDriveSignIn.page(client, challenge: "c", state: "s", account: ""))
        XCTAssertFalse(plain.absoluteString.contains("login_hint"), plain.absoluteString)
        XCTAssertFalse(plain.absoluteString.contains("prompt"), plain.absoluteString)
    }

    func testReadsTheCodeGoogleSendsBack() throws {
        func back(_ query: String) throws -> URL {
            try XCTUnwrap(URL(string: "com.googleusercontent.apps.1234567890-abc123def456:/oauth2redirect?" + query))
        }
        XCTAssertEqual(try CartoucheDriveSignIn.code(in: back("state=abc&code=4%2F0AeanS0&scope=x"), client: client, state: "abc"),
                       "4/0AeanS0")
        XCTAssertThrowsError(try CartoucheDriveSignIn.code(in: back("state=abc&error=access_denied"), client: client, state: "abc")) {
            XCTAssertEqual($0 as? CartoucheDriveSignInFailure, .refused)
        }
        XCTAssertThrowsError(try CartoucheDriveSignIn.code(in: back("state=abc&error=invalid_scope"), client: client, state: "abc")) {
            XCTAssertEqual($0 as? CartoucheDriveSignInFailure, .google("invalid_scope"))
        }
        // Another sign-in's, without a code, or another app's.
        let others = try [back("state=other&code=4%2F0A"), back("code=4%2F0A"), back("state=abc"), back("state=abc&code="),
                          XCTUnwrap(URL(string: "com.googleusercontent.apps.999-other:/oauth2redirect?state=abc&code=x"))]
        for url in others {
            XCTAssertThrowsError(try CartoucheDriveSignIn.code(in: url, client: client, state: "abc"), url.absoluteString) {
                XCTAssertEqual($0 as? CartoucheDriveSignInFailure, .notThisSignIn, url.absoluteString)
            }
        }
    }

    func testAsksForTheTokensWithoutASecret() {
        let exchange = CartoucheDriveSignIn.query(CartoucheDriveSignIn.exchange(code: "4/0Ae", verifier: "v-_~", client: client))
        XCTAssertEqual(exchange, "code=4%2F0Ae&client_id=\(id)"
            + "&redirect_uri=com.googleusercontent.apps.1234567890-abc123def456%3A%2Foauth2redirect"
            + "&grant_type=authorization_code&code_verifier=v-_~")
        XCTAssertFalse(exchange.contains("secret"))
        let renewal = CartoucheDriveSignIn.query(CartoucheDriveSignIn.renewal(refreshToken: "1//0g+x", client: client))
        XCTAssertEqual(renewal, "client_id=\(id)&refresh_token=1%2F%2F0g%2Bx&grant_type=refresh_token")
    }

    func testReadsWhatGoogleGrants() throws {
        let signIn = Data("""
        {"access_token": "ya29.a0Af", "expires_in": 3599, "refresh_token": "1//0g", "scope": "https://www.googleapis.com/auth/drive",
         "token_type": "Bearer", "refresh_token_expires_in": 604799}
        """.utf8)
        let grant = try XCTUnwrap(CartoucheDriveGrant.parse(signIn))
        XCTAssertEqual(grant, CartoucheDriveGrant(accessToken: "ya29.a0Af", expiresIn: 3599, refreshToken: "1//0g",
                                                  scope: "https://www.googleapis.com/auth/drive"))
        XCTAssertTrue(grant.allowsDrive)
        let renewal = try XCTUnwrap(CartoucheDriveGrant.parse(Data(#"{"access_token": "ya29.b", "expires_in": 3599, "scope": "openid https://www.googleapis.com/auth/drive"}"#.utf8)))
        XCTAssertNil(renewal.refreshToken)
        XCTAssertTrue(renewal.allowsDrive)
        // The player left the Drive unchecked on Google's page.
        let narrow = try XCTUnwrap(CartoucheDriveGrant.parse(Data(#"{"access_token": "ya29.c", "scope": "https://www.googleapis.com/auth/drive.file", "refresh_token": ""}"#.utf8)))
        XCTAssertFalse(narrow.allowsDrive)
        XCTAssertNil(narrow.refreshToken)
        XCTAssertEqual(narrow.expiresIn, 3_600)
        XCTAssertNil(CartoucheDriveGrant.parse(Data(#"{"error": "invalid_grant"}"#.utf8)))
        XCTAssertNil(CartoucheDriveGrant.parse(Data("<html>".utf8)))
    }

    func testReadsWhyTheTokenServerSaidNo() {
        let ended = CartoucheDriveTokenFailure.parse(Data(#"{"error": "invalid_grant", "error_description": "Token has been expired or revoked."}"#.utf8),
                                                     status: 400)
        XCTAssertTrue(ended.needsSignIn)
        XCTAssertFalse(ended.isClientRefused)
        XCTAssertEqual(ended.localizedDescription, "HTTP 400 invalid_grant")
        let unknown = CartoucheDriveTokenFailure.parse(Data(#"{"error": "invalid_client", "error_description": "The OAuth client was not found."}"#.utf8),
                                                       status: 401)
        XCTAssertTrue(unknown.isClientRefused)
        XCTAssertFalse(unknown.needsSignIn)
        XCTAssertEqual(unknown.localizedDescription, "HTTP 401 invalid_client")
        let page = CartoucheDriveTokenFailure.parse(Data("<html>Bad gateway</html>".utf8), status: 502)
        XCTAssertEqual(page.localizedDescription, "HTTP 502")
    }

    // MARK: The Drive API's answers

    func testReadsTheFilesOfAListing() throws {
        let data = Data("""
        {"nextPageToken": "~!!~AI9", "files": [
          {"id": "1Abc", "name": "Jeux", "mimeType": "application/vnd.google-apps.folder", "modifiedTime": "2026-11-12T09:06:36.123Z"},
          {"id": "1Def", "name": "Essai [0100CA27C0DE0000].ipa", "mimeType": "application/octet-stream", "size": "36700160",
           "modifiedTime": "2026-11-12T09:06:36Z"},
          {"id": "1Ghi", "name": "Notes", "mimeType": "application/vnd.google-apps.document"},
          {"name": "without an ID"}
        ]}
        """.utf8)
        let page = try XCTUnwrap(CartoucheDriveListing.parse(data))
        XCTAssertEqual(page.next, "~!!~AI9")
        XCTAssertEqual(page.files.map(\.id), ["1Abc", "1Def", "1Ghi"])
        let folder = page.files[0]
        let ipa = page.files[1]
        let doc = page.files[2]
        XCTAssertTrue(folder.isFolder)
        XCTAssertFalse(folder.isBinary)
        XCTAssertNil(folder.size)
        XCTAssertEqual(folder.modified?.timeIntervalSince1970 ?? 0, 1_794_474_396.123, accuracy: 0.001)
        XCTAssertTrue(ipa.isBinary)
        XCTAssertFalse(ipa.isFolder)
        XCTAssertEqual(ipa.size, 36_700_160)
        XCTAssertEqual(ipa.modified?.timeIntervalSince1970, 1_794_474_396)
        XCTAssertFalse(doc.isBinary)
        XCTAssertFalse(doc.isFolder)
        XCTAssertNil(CartoucheDriveListing.parse(Data("{]".utf8)))
        XCTAssertNil(CartoucheDriveListing.parse(Data(#"{"files": [], "nextPageToken": ""}"#.utf8))?.next)
        let made = try XCTUnwrap(CartoucheDriveFile.parse(Data(#"{"id": "1Jkl", "name": "Sauvegarde.zip", "mimeType": "application/zip", "size": "12"}"#.utf8)))
        XCTAssertEqual(made.size, 12)
    }

    func testTheNewestOfANameFirst() {
        func file(_ id: String, _ time: TimeInterval?) -> CartoucheDriveFile {
            CartoucheDriveFile(id: id, name: "Essai.ipa", mimeType: "application/octet-stream", size: 1,
                               modified: time.map { Date(timeIntervalSince1970: $0) })
        }
        let files = [file("1B", 1), file("1A", nil), file("1D", 2), file("1C", 2)]
        XCTAssertEqual(files.sorted(by: CartoucheDriveFile.newestFirst).map(\.id), ["1C", "1D", "1B", "1A"])
    }

    func testReadsTheAccountAndTheRoomLeft() throws {
        let about = try XCTUnwrap(CartoucheDriveAbout.parse(Data(#"{"user": {"emailAddress": "joueur@example.com"}, "storageQuota": {"limit": "16106127360", "usage": "6106127360"}}"#.utf8)))
        XCTAssertEqual(about.account, "joueur@example.com")
        XCTAssertEqual(about.freeSpace, 10_000_000_000)
        let unlimited = try XCTUnwrap(CartoucheDriveAbout.parse(Data(#"{"storageQuota": {"usage": "5"}}"#.utf8)))
        XCTAssertNil(unlimited.freeSpace)
        let over = try XCTUnwrap(CartoucheDriveAbout.parse(Data(#"{"storageQuota": {"limit": "5", "usage": "9"}}"#.utf8)))
        XCTAssertEqual(over.freeSpace, 0)
    }

    /// The Drive API off in the player's project, as Google says it: the
    /// address to turn it on, and nothing of the message in a report.
    func testReadsThatTheDriveAPIIsOff() {
        let address = "https://console.developers.google.com/apis/api/drive.googleapis.com/overview?project=123456789012"
        let off = CartoucheDriveFailure.parse(Data("""
        {"error": {"code": 403,
          "message": "Google Drive API has not been used in project 123456789012 before or it is disabled. Enable it by visiting \(address) then retry.",
          "errors": [{"message": "Google Drive API has not been used…", "domain": "usageLimits", "reason": "accessNotConfigured",
                      "extendedHelp": "https://console.developers.google.com"}],
          "status": "PERMISSION_DENIED",
          "details": [{"@type": "type.googleapis.com/google.rpc.ErrorInfo", "reason": "SERVICE_DISABLED", "domain": "googleapis.com",
                       "metadata": {"service": "drive.googleapis.com", "consumer": "projects/123456789012", "activationUrl": "\(address)"}},
                      {"@type": "type.googleapis.com/google.rpc.Help", "links": [{"description": "activation", "url": "\(address)"}]}]}}
        """.utf8), status: 403)
        XCTAssertEqual(off.reason, "accessNotConfigured")
        XCTAssertTrue(off.isDriveOff)
        XCTAssertFalse(off.isRefusal)
        XCTAssertFalse(off.isPassing)
        XCTAssertEqual(off.activation?.absoluteString, address)
        XCTAssertEqual(off.localizedDescription, "HTTP 403 accessNotConfigured")

        // Older answers have the address in the message alone.
        let inTheMessage = CartoucheDriveFailure.parse(Data(#"{"error": {"code": 403, "message": "Access Not Configured. Enable it by visiting https://console.developers.google.com/apis/api/drive.googleapis.com/overview?project=1 then retry.", "errors": [{"reason": "accessNotConfigured"}]}}"#.utf8), status: 403)
        XCTAssertEqual(inTheMessage.activation?.host, "console.developers.google.com")
        // Google Cloud's console alone, in HTTPS, is opened from an answer.
        for elsewhere in ["https://example.com/console", "http://console.cloud.google.com/apis", "javascript:alert(1)"] {
            let failure = CartoucheDriveFailure.parse(Data(#"{"error": {"code": 403, "errors": [{"reason": "accessNotConfigured"}], "details": [{"reason": "SERVICE_DISABLED", "metadata": {"activationUrl": "\#(elsewhere)"}}]}}"#.utf8), status: 403)
            XCTAssertTrue(failure.isDriveOff, elsewhere)
            XCTAssertNil(failure.activation, elsewhere)
        }
    }

    func testTellsWhatPassesFromWhatDoesNot() {
        func failure(_ status: Int, _ reason: String) -> CartoucheDriveFailure {
            CartoucheDriveFailure.parse(Data(#"{"error": {"code": \#(status), "message": "Project 123 file 1Abc", "errors": [{"reason": "\#(reason)"}]}}"#.utf8),
                                        status: status)
        }
        XCTAssertTrue(failure(403, "userRateLimitExceeded").isRateLimit)
        XCTAssertTrue(failure(403, "userRateLimitExceeded").isPassing)
        XCTAssertFalse(failure(403, "userRateLimitExceeded").isRefusal)
        XCTAssertTrue(failure(429, "rateLimitExceeded").isPassing)
        XCTAssertTrue(failure(503, "backendError").isPassing)
        XCTAssertTrue(failure(500, "internalError").isPassing)
        XCTAssertTrue(failure(408, "timeout").isPassing)
        XCTAssertFalse(failure(404, "notFound").isPassing)
        XCTAssertTrue(failure(404, "notFound").isNotFound)
        XCTAssertTrue(failure(401, "authError").isExpiredToken)
        XCTAssertFalse(failure(401, "authError").isPassing)
        XCTAssertTrue(failure(403, "storageQuotaExceeded").isFull)
        XCTAssertFalse(failure(403, "storageQuotaExceeded").isRefusal)
        XCTAssertTrue(failure(403, "insufficientPermissions").isScopeMissing)
        XCTAssertTrue(failure(403, "insufficientFilePermissions").isRefusal)
        XCTAssertFalse(failure(302, "").isPassing)
        // The message, which names the player's project and files, stays out.
        XCTAssertEqual(failure(403, "insufficientFilePermissions").localizedDescription, "HTTP 403 insufficientFilePermissions")
        // An answer that is not the API's: its status alone.
        let page = CartoucheDriveFailure.parse(Data("<html>502</html>".utf8), status: 502)
        XCTAssertEqual(page.reason, "")
        XCTAssertEqual(page.localizedDescription, "HTTP 502")
        XCTAssertTrue(page.isPassing)
        // A newer answer, with the status's name alone.
        let newer = CartoucheDriveFailure.parse(Data(#"{"error": {"code": 403, "status": "PERMISSION_DENIED", "message": "m"}}"#.utf8),
                                                status: 403)
        XCTAssertEqual(newer.reason, "PERMISSION_DENIED")
        XCTAssertTrue(newer.isRefusal)
        XCTAssertTrue(CartoucheDriveFailure.notFound.isNotFound)
    }

    func testReadsWhetherTheAccountCanAddToAFolder() {
        XCTAssertEqual(CartoucheDriveCapabilities.canAddChildren(Data(#"{"capabilities": {"canAddChildren": false}}"#.utf8)), false)
        XCTAssertEqual(CartoucheDriveCapabilities.canAddChildren(Data(#"{"capabilities": {"canAddChildren": true}}"#.utf8)), true)
        XCTAssertNil(CartoucheDriveCapabilities.canAddChildren(Data(#"{"id": "1Abc"}"#.utf8)))
    }

    // MARK: What Cartouche asks

    func testSaysWhatAFileOrAFolderIs() throws {
        let folder = try XCTUnwrap(try JSONSerialization.jsonObject(with: CartoucheDriveMetadata.folder("Sauvegardes", in: "1Abc").json)
            as? [String: Any])
        XCTAssertEqual(folder["name"] as? String, "Sauvegardes")
        XCTAssertEqual(folder["parents"] as? [String], ["1Abc"])
        XCTAssertEqual(folder["mimeType"] as? String, "application/vnd.google-apps.folder")
        let file = try XCTUnwrap(try JSONSerialization.jsonObject(with: CartoucheDriveMetadata.file("Essai \"é\".ipa", in: "root").json)
            as? [String: Any])
        XCTAssertEqual(file["name"] as? String, "Essai \"é\".ipa")
        XCTAssertEqual(file["parents"] as? [String], ["root"])
        XCTAssertNil(file["mimeType"])
    }

    func testQueriesAFoldersFilesByName() {
        XCTAssertEqual(CartoucheDriveQuery.children(of: "root"), "'root' in parents and trashed = false")
        XCTAssertEqual(CartoucheDriveQuery.named("L'été \\ 2026", in: "1Abc"),
                       #"name = 'L\'été \\ 2026' and '1Abc' in parents and trashed = false"#)
        XCTAssertEqual(CartoucheDriveListing.fields, "nextPageToken,files(id,name,mimeType,size,modifiedTime)")
    }

    /// A name with an accent has two spellings, which Swift's == takes for
    /// one: Cartouche asks Drive for both, the composed one first.
    func testSpellsANameAsAMacMayHave() {
        let spellings = CartoucheDriveQuery.spellings("Partie enregistre\u{301}e")
        XCTAssertEqual(spellings.map { Array($0.unicodeScalars) },
                       [Array("Partie enregistr\u{E9}e".unicodeScalars), Array("Partie enregistre\u{301}e".unicodeScalars)])
        XCTAssertEqual(CartoucheDriveQuery.spellings("Jeux").map { Array($0.unicodeScalars) }, [Array("Jeux".unicodeScalars)])
    }

    func testTheRangesOfTheResumableUpload() {
        XCTAssertEqual(CartoucheDriveUpload.granule, 262_144)
        XCTAssertEqual(CartoucheDriveUpload.range(offset: 0, count: 8 << 20, total: nil), "bytes 0-8388607/*")
        XCTAssertEqual(CartoucheDriveUpload.range(offset: 8 << 20, count: 100, total: (8 << 20) + 100), "bytes 8388608-8388707/8388708")
        XCTAssertEqual(CartoucheDriveUpload.range(offset: 300, count: 0, total: 300), "bytes */300")
        XCTAssertEqual(CartoucheDriveUpload.range(offset: 0, count: 0, total: nil), "bytes */*")
        XCTAssertEqual(CartoucheDriveUpload.received("bytes=0-1048575"), 1_048_576)
        XCTAssertEqual(CartoucheDriveUpload.received(nil), 0)
        XCTAssertEqual(CartoucheDriveUpload.received(" "), 0)
        XCTAssertNil(CartoucheDriveUpload.received("bytes=5-10"))
        XCTAssertNil(CartoucheDriveUpload.received("bytes 0-10"))
        XCTAssertNil(CartoucheDriveUpload.received("bytes=0-"))
        XCTAssertEqual(CartoucheDriveUpload.readRange(offset: 100, count: 4 << 20), "bytes=100-4194403")
    }
}
