//
//  CartoucheSignInMessage.swift
//  Cartouche
//
//  What Cartouche and the built-in SideStore tell each other while the player
//  signs in with their Apple ID (CartoucheAccount). SideStore signs in from
//  LiveProcess, in its Sign In to Cartouche action
//  (app/patches/sidestore/0011), and the two processes share SideStore's
//  keychain: Cartouche leaves the credentials there, SideStore leaves a
//  request when Apple asks for a verification code, and Cartouche answers it.
//  Foundation only, so that swift test checks it on a Mac
//  (launcher/Package.swift).
//

import Foundation

enum CartoucheSignInMessage {
    /// The keychain items, under the service SideStore names after
    /// Cartouche's bundle identifier.
    static let credentialsAccount = "cartoucheSignIn.credentials"
    static let requestAccount = "cartoucheSignIn.request"
    static let responseAccount = "cartoucheSignIn.response"

    /// Where Apple sent the verification code.
    enum Mode: String, Equatable {
        case trustedDevice
        case sms
        case voice
    }

    /// Apple asks for a verification code.
    struct CodeRequest: Equatable {
        let id: String
        let mode: Mode
        /// The trusted number the code went to, as Apple masks it.
        let phone: String?
        /// Whether the code can come by text message instead.
        let canTextMessage: Bool
        /// Why Apple refused the last code.
        let error: String?
    }

    /// What the player does with a request.
    enum Answer: Equatable {
        case code(String)
        case textMessage
        case trustedDevice
        case cancel
    }

    /// The Apple ID and password, for SideStore to read once.
    static func credentials(appleID: String, password: String) -> Data {
        let fields = ["appleID": appleID.trimmingCharacters(in: .whitespacesAndNewlines), "password": password]
        return (try? JSONSerialization.data(withJSONObject: fields)) ?? Data()
    }

    /// The request SideStore left, or nil when it reads as none.
    static func request(from data: Data) -> CodeRequest? {
        guard let fields = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = fields["id"] as? String, !id.isEmpty,
              let mode = (fields["mode"] as? String).flatMap(Mode.init(rawValue:)) else { return nil }
        let phone = (fields["phone"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let error = (fields["error"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        return CodeRequest(id: id, mode: mode, phone: phone,
                           canTextMessage: fields["canTextMessage"] as? Bool ?? false, error: error)
    }

    /// The answer to the request ID.
    static func response(to id: String, _ answer: Answer) -> Data {
        var fields = ["id": id]
        switch answer {
        case .code(let code): fields["code"] = code
        case .textMessage: fields["action"] = "sms"
        case .trustedDevice: fields["action"] = "trustedDevice"
        case .cancel: fields["action"] = "cancel"
        }
        return (try? JSONSerialization.data(withJSONObject: fields)) ?? Data()
    }

    /// The code as Apple takes it: its six digits, whatever the player typed
    /// around them. Nil until there are six.
    static func code(from text: String) -> String? {
        let digits = text.filter { $0.isASCII && $0.isNumber }
        return digits.count == 6 ? String(digits) : nil
    }

    /// Whether the Apple ID and password can be sent: an Apple ID is an email
    /// address, or a phone number.
    static func canSignIn(appleID: String, password: String) -> Bool {
        let id = appleID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !password.isEmpty, id.count >= 3, !id.contains(where: \.isWhitespace) else { return false }
        return id.contains("@") || id.filter(\.isNumber).count >= 6
    }

    /// SideStore's message without the name of the App Intents error that
    /// carried it, such as "LNPerformActionErrorCodeLocalizedStringResource: ".
    static func readable(_ message: String) -> String {
        guard let colon = message.range(of: ": "),
              message.hasPrefix("LN"),
              message[..<colon.lowerBound].allSatisfy({ $0.isLetter || $0.isNumber }) else { return message }
        return String(message[colon.upperBound...])
    }

    /// The address of the page an error asks the player to open, such as the
    /// one where Apple asks to review the account.
    static func link(in message: String) -> URL? {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { return nil }
        let range = NSRange(message.startIndex..., in: message)
        return detector.matches(in: message, range: range)
            .compactMap(\.url)
            .first { $0.scheme == "https" }
    }
}
