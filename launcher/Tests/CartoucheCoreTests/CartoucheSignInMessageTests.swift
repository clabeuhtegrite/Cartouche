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
}
