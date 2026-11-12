import XCTest
@testable import CartoucheCore

final class CartoucheSignInMessageTests: XCTestCase {
    func testCredentialsAreWhatSideStoreReads() throws {
        let data = CartoucheSignInMessage.credentials(appleID: "  player@example.com\n", password: " secret ")
        let fields = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: String])
        XCTAssertEqual(fields, ["appleID": "player@example.com", "password": " secret "])
    }

    func testARequestFromSideStore() throws {
        let data = Data(#"{"id":"A","mode":"sms","phone":"+33 •• •• •• •• 12","canTextMessage":false,"error":"Incorrect code"}"#.utf8)
        let request = try XCTUnwrap(CartoucheSignInMessage.request(from: data))
        XCTAssertEqual(request, .init(id: "A", mode: .sms, phone: "+33 •• •• •• •• 12", canTextMessage: false, error: "Incorrect code"))
    }

    func testATrustedDeviceRequestWithoutPhoneOrError() throws {
        let data = Data(#"{"id":"B","mode":"trustedDevice","canTextMessage":true,"error":""}"#.utf8)
        let request = try XCTUnwrap(CartoucheSignInMessage.request(from: data))
        XCTAssertEqual(request, .init(id: "B", mode: .trustedDevice, phone: nil, canTextMessage: true, error: nil))
    }

    func testWhatIsNotARequest() {
        XCTAssertNil(CartoucheSignInMessage.request(from: Data("{}".utf8)))
        XCTAssertNil(CartoucheSignInMessage.request(from: Data(#"{"id":"C","mode":"pigeon"}"#.utf8)))
        XCTAssertNil(CartoucheSignInMessage.request(from: Data(#"{"id":"","mode":"sms"}"#.utf8)))
        XCTAssertNil(CartoucheSignInMessage.request(from: Data("not json".utf8)))
    }

    func testResponses() throws {
        func fields(_ answer: CartoucheSignInMessage.Answer) throws -> [String: String] {
            try XCTUnwrap(JSONSerialization.jsonObject(with: CartoucheSignInMessage.response(to: "A", answer)) as? [String: String])
        }
        XCTAssertEqual(try fields(.code("123456")), ["id": "A", "code": "123456"])
        XCTAssertEqual(try fields(.textMessage), ["id": "A", "action": "sms"])
        XCTAssertEqual(try fields(.trustedDevice), ["id": "A", "action": "trustedDevice"])
        XCTAssertEqual(try fields(.cancel), ["id": "A", "action": "cancel"])
    }

    func testCodes() {
        XCTAssertEqual(CartoucheSignInMessage.code(from: "123456"), "123456")
        XCTAssertEqual(CartoucheSignInMessage.code(from: "123 456"), "123456")
        XCTAssertNil(CartoucheSignInMessage.code(from: "12345"))
        XCTAssertNil(CartoucheSignInMessage.code(from: "1234567"))
        XCTAssertNil(CartoucheSignInMessage.code(from: "١٢٣٤٥٦"))
    }

    func testWhatCanBeSent() {
        XCTAssertTrue(CartoucheSignInMessage.canSignIn(appleID: "player@example.com", password: "x"))
        XCTAssertTrue(CartoucheSignInMessage.canSignIn(appleID: "+33 6 12 34 56 78".replacingOccurrences(of: " ", with: ""), password: "x"))
        XCTAssertFalse(CartoucheSignInMessage.canSignIn(appleID: "player@example.com", password: ""))
        XCTAssertFalse(CartoucheSignInMessage.canSignIn(appleID: "player", password: "x"))
        XCTAssertFalse(CartoucheSignInMessage.canSignIn(appleID: "pla yer@example.com", password: "x"))
    }

    func testTheLinkInAnError() {
        let message = "Apple asks you to review your account.\n\nhttps://appleid.apple.com/account/manage"
        XCTAssertEqual(CartoucheSignInMessage.link(in: message), URL(string: "https://appleid.apple.com/account/manage"))
        XCTAssertNil(CartoucheSignInMessage.link(in: "The password is incorrect."))
    }

    func testTheIntentErrorNameGoes() {
        XCTAssertEqual(CartoucheSignInMessage.readable("LNPerformActionErrorCodeLocalizedStringResource: This Apple account already has a certificate."),
                       "This Apple account already has a certificate.")
        XCTAssertEqual(CartoucheSignInMessage.readable("The password is incorrect: try again."), "The password is incorrect: try again.")
        XCTAssertEqual(CartoucheSignInMessage.readable("LNPerform Action: no"), "LNPerform Action: no")
    }

    // MARK: Apple's pages and limits

    private let page = "Invalid server response: unparseable format\n<html>\n<head><title>429 Too Many Requests</title></head>\n"
        + "<body>\n<center><h1>429 Too Many Requests</h1></center>\n<hr><center>Apple</center>\n</body>\n</html>"

    func testApplesPageAndItsStatus() {
        XCTAssertTrue(CartoucheSignInMessage.hasPage(page))
        XCTAssertEqual(CartoucheSignInMessage.pageStatus(in: page), 429)
        XCTAssertEqual(CartoucheSignInMessage.pageStatus(in: "<!DOCTYPE html><html><head><TITLE>503 Service Unavailable</TITLE>"), 503)
        XCTAssertEqual(CartoucheSignInMessage.pageStatus(in: "<html><body><h1 class=\"x\">502 Bad Gateway</h1></body></html>"), 502)
        XCTAssertNil(CartoucheSignInMessage.pageStatus(in: "<html><head><title>Apple</title></head></html>"))
        XCTAssertNil(CartoucheSignInMessage.pageStatus(in: "<html><head><title>4290 things</title></head></html>"))
        XCTAssertNil(CartoucheSignInMessage.pageStatus(in: "Error 429: too many requests"))
        XCTAssertFalse(CartoucheSignInMessage.hasPage("Your Apple ID or password is incorrect."))
    }

    func testTheTroubleCartoucheTellsInItsOwnWords() {
        let none = CartoucheFailure(.appleServer, details: ["kind": .text("underlyingError")])
        XCTAssertEqual(CartoucheSignInMessage.trouble(in: page, failure: none), .tooManyRequests)
        XCTAssertEqual(CartoucheSignInMessage.trouble(in: "Too many codes", failure: CartoucheFailure(.tooManyAttempts)), .tooManyRequests)
        XCTAssertEqual(CartoucheSignInMessage.trouble(in: "Apple refuses more requests for now (HTTP 429).",
                                                      failure: CartoucheFailure(.appleServer, details: ["http": .number(429)])),
                       .tooManyRequests)
        let unavailable = CartoucheFailure(.appleServer, details: ["kind": .text("httpStatus"), "http": .number(503)])
        XCTAssertEqual(CartoucheSignInMessage.trouble(in: "Apple Developer Portal is temporarily unavailable (HTTP 503)",
                                                      failure: unavailable), .unreadable(status: 503))
        XCTAssertEqual(CartoucheSignInMessage.trouble(in: page.replacingOccurrences(of: "429 Too Many Requests", with: "403 Forbidden"),
                                                      failure: none), .unreadable(status: 403))
        XCTAssertEqual(CartoucheSignInMessage.trouble(in: "Invalid server response: unparseable format\n3c3f786d6c",
                                                      failure: CartoucheFailure(.appleServer, details: ["kind": .text("invalidResponseFormat")])),
                       .unreadable(status: nil))
        XCTAssertNil(CartoucheSignInMessage.trouble(in: "Your Apple ID or password is incorrect.",
                                                    failure: CartoucheFailure(.appleCredentials, details: ["kind": .text("incorrectCredentials")])))
    }

    func testThePauseAfterApplesLimit() throws {
        let now = Date(timeIntervalSince1970: 1_794_000_000)
        let first = CartoucheSignInPause.after(nil, at: now, retryAfter: nil)
        XCTAssertEqual(first, CartoucheSignInPause(until: now.addingTimeInterval(900), inARow: 1, last: now))
        XCTAssertEqual(first.seconds, 900)
        XCTAssertTrue(first.holds(at: now.addingTimeInterval(899)))
        XCTAssertFalse(first.holds(at: now.addingTimeInterval(900)))

        // Each limit in a row waits longer, up to two hours.
        var pause = first
        var waits: [Int] = []
        for step in 1...5 {
            pause = CartoucheSignInPause.after(pause, at: now.addingTimeInterval(Double(step) * 3_600), retryAfter: nil)
            waits.append(pause.seconds)
        }
        XCTAssertEqual(waits, [1_800, 3_600, 7_200, 7_200, 7_200])
        XCTAssertEqual(pause.inARow, 6)

        // A day after the last one, it starts again from the first step.
        XCTAssertEqual(CartoucheSignInPause.after(pause, at: pause.last.addingTimeInterval(86_400), retryAfter: nil).seconds, 900)

        // What Apple asks for, a minute to a day.
        XCTAssertEqual(CartoucheSignInPause.after(nil, at: now, retryAfter: 3_600).seconds, 3_600)
        XCTAssertEqual(CartoucheSignInPause.after(nil, at: now, retryAfter: 0).seconds, 60)
        XCTAssertEqual(CartoucheSignInPause.after(first, at: now, retryAfter: 604_800).seconds, 86_400)

        // Kept across launches as JSON.
        let kept = try JSONDecoder().decode(CartoucheSignInPause.self, from: JSONEncoder().encode(first))
        XCTAssertEqual(kept, first)
    }
}
