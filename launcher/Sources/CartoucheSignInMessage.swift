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

    // MARK: Apple's pages and limits

    /// What Cartouche says instead of the built-in SideStore's words, when
    /// they are not for the player.
    enum Trouble: Equatable {
        /// Apple refuses more requests for now, after too many in a short
        /// time: its HTTP 429, Too Many Requests, or its own codes for too
        /// many attempts or codes asked for.
        case tooManyRequests
        /// Apple's servers answered with an error and nothing Cartouche can
        /// read, such as a page: of that HTTP status, when it is known.
        case unreadable(status: Int?)
    }

    /// Whether MESSAGE holds a page of HTML, as Apple's servers send one for
    /// an HTTP error, and as the built-in SideStore passed it on as its
    /// error's words before app/patches/sidestore/0016.
    static func hasPage(_ message: String) -> Bool {
        let lowered = message.lowercased()
        return lowered.contains("<html") || lowered.contains("<!doctype html") || lowered.contains("<body")
    }

    /// The HTTP status a page in MESSAGE gives in its title or its heading:
    /// 429 for "<title>429 Too Many Requests</title>".
    static func pageStatus(in message: String) -> Int? {
        guard hasPage(message),
              let expression = try? NSRegularExpression(pattern: "<(?:title|h1)\\b[^>]*>\\s*([1-5][0-9][0-9])(?![0-9])",
                                                        options: [.caseInsensitive]),
              let match = expression.firstMatch(in: message, range: NSRange(message.startIndex..., in: message)),
              let range = Range(match.range(at: 1), in: message) else { return nil }
        return Int(message[range])
    }

    /// The trouble behind the built-in SideStore's MESSAGE, which Cartouche
    /// tells the player in its own words: from FAILURE, what Cartouche told
    /// of how SideStore's action ended, and from a page in MESSAGE. Nil when
    /// its words say it well enough.
    static func trouble(in message: String, failure: CartoucheFailure) -> Trouble? {
        if failure.cause == .tooManyAttempts { return .tooManyRequests }
        var http: Int?
        if case .number(let number)? = failure.details["http"] { http = Int(number) }
        var kind: String?
        if case .text(let text)? = failure.details["kind"] { kind = text }
        let status = pageStatus(in: message) ?? http
        if status == 429 { return .tooManyRequests }
        if hasPage(message) || kind == "httpStatus" || kind == "invalidResponseFormat" {
            return .unreadable(status: status)
        }
        return nil
    }
}

// MARK: This iPhone, through LocalDevVPN

extension CartoucheSignInMessage {
    /// What keeps the built-in SideStore from reaching this iPhone, as it
    /// does through LocalDevVPN to register it with the account. Cartouche
    /// tells the player in its own words, which say what to do, rather than
    /// SideStore's, which point to its own settings.
    enum DeviceTrouble: Equatable {
        /// LocalDevVPN is off, or does not carry this iPhone's traffic.
        case vpn
        /// The iPhone is not on Wi-Fi, which LocalDevVPN needs.
        case wifi
        /// The pairing file is missing, or the iPhone refuses it.
        case pairing
        /// The iPhone did not answer through LocalDevVPN.
        case noAnswer
    }

    /// The trouble FAILURE tells, when it is one of this iPhone's connection
    /// to itself.
    static func deviceTrouble(in failure: CartoucheFailure) -> DeviceTrouble? {
        switch failure.cause {
        case .vpn: return .vpn
        case .pairing: return .pairing
        case .device:
            if case .text("noConnection")? = failure.details["kind"] { return .wifi }
            return .noAnswer
        default: return nil
        }
    }

    /// When SideStore did not reach this iPhone, in a sign-in that ended
    /// with FAILURE.
    enum DeviceMoment: Equatable {
        /// Before anything went to Apple (app/patches/sidestore/0017).
        case beforeApple
        /// Once Apple had accepted the account, at the step that registers
        /// this iPhone, which is then left alone.
        case afterApple
        /// At another step.
        case elsewhere
    }

    static func deviceMoment(of failure: CartoucheFailure) -> DeviceMoment {
        switch failure.stage {
        case "deviceCheck"?: return .beforeApple
        case "device"?: return .afterApple
        default: return .elsewhere
        }
    }

    /// Whether a sign-in that ended with FAILURE leaves only the step that
    /// registers this iPhone: Apple accepted the account, SideStore kept it
    /// with its team and the certificate, and stopped at that step, which
    /// Register Cartouche's iPhone takes alone (app/patches/sidestore/0017).
    static func leavesDeviceStep(_ failure: CartoucheFailure) -> Bool {
        failure.stage == "device"
    }

    /// Whether that step, taken alone, ended with FAILURE for want of the
    /// account a sign-in leaves: the whole sign-in is left then.
    static func needsSignIn(afterDeviceStep failure: CartoucheFailure) -> Bool {
        failure.stage == "account" || failure.cause == .notSignedIn
    }

    /// The steps of the sign-in before anything goes to Apple: Cartouche's
    /// own, then SideStore's (app/patches/sidestore/0011, 0017).
    static let stagesBeforeApple: Set<String> = ["start", "database", "credentials", "deviceCheck"]

    /// Whether the password the player typed can stay on the sign-in's
    /// screen after a sign-in that ended with FAILURE: when it never left
    /// this iPhone, for the player to sign in again without typing it again.
    static func keepsPassword(after failure: CartoucheFailure?) -> Bool {
        guard let stage = failure?.stage else { return false }
        return stagesBeforeApple.contains(stage)
    }
}

/// How long Cartouche keeps the player from signing in again once Apple has
/// refused more sign-ins for now, so that no burst of attempts, by the
/// player or by Cartouche itself, makes Apple's limit last longer: what
/// Apple asked for when it said (Retry-After), a minute to a day; otherwise
/// 15 minutes, then 30, 60 and 120 for each limit in a row, a day apart at
/// most.
struct CartoucheSignInPause: Codable, Equatable {
    /// When the player can sign in again.
    var until: Date
    /// How many sign-ins in a row Apple limited, and when it last did.
    var inARow: Int
    var last: Date

    static let steps: [TimeInterval] = [15 * 60, 30 * 60, 60 * 60, 120 * 60]

    /// The pause after Apple limited a sign-in at NOW, asking to wait RETRY
    /// AFTER seconds when it did, PREVIOUS being the pause before, if any.
    static func after(_ previous: CartoucheSignInPause?, at now: Date, retryAfter: Int?) -> CartoucheSignInPause {
        var inARow = 1
        if let previous, now.timeIntervalSince(previous.last) < 86_400 {
            inARow = previous.inARow + 1
        }
        var wait = steps[min(inARow, steps.count) - 1]
        if let retryAfter {
            wait = min(max(TimeInterval(retryAfter), 60), 86_400)
        }
        return CartoucheSignInPause(until: now.addingTimeInterval(wait), inARow: inARow, last: now)
    }

    /// How long it lasts, in seconds.
    var seconds: Int { max(0, Int(until.timeIntervalSince(last).rounded())) }

    /// Whether it still keeps the player from signing in at NOW.
    func holds(at now: Date) -> Bool { now < until }
}

/// Where Cartouche's sign-in stands (CartoucheAccount), which its screens
/// show (CartoucheSignInView).
enum CartoucheSignInPhase: Equatable {
    /// Cartouche waits for LocalDevVPN before it hands SideStore the
    /// sign-in, or the step that registers this iPhone alone: nothing has
    /// gone to Apple yet.
    case waitingForVPN(deviceStep: Bool)
    /// SideStore signs in, registers this iPhone and fetches the
    /// certificate.
    case signingIn
    /// Apple asks for a verification code.
    case code(CartoucheSignInMessage.CodeRequest)
    /// SideStore registers this iPhone alone, with the account it kept.
    case registeringDevice

    var needsCode: Bool {
        if case .code = self { return true }
        return false
    }

    var isWaitingForVPN: Bool {
        if case .waitingForVPN = self { return true }
        return false
    }

    /// Whether the built-in SideStore is at work, which nothing interrupts.
    var sideStoreRuns: Bool { self == .signingIn || self == .registeringDevice }

    /// Whether the sign-in's screen offers the step that registers this
    /// iPhone alone, rather than the Apple ID and its password: while that
    /// step runs or waits for LocalDevVPN and, in between, while it is LEFT,
    /// unless the player chose to sign in again.
    static func showsDeviceStep(_ phase: CartoucheSignInPhase?, left: Bool, signingInAgain: Bool) -> Bool {
        switch phase {
        case .registeringDevice?, .waitingForVPN(deviceStep: true)?: return true
        case .signingIn?, .code?, .waitingForVPN(deviceStep: false)?: return false
        case nil: return left && !signingInAgain
        }
    }

    /// Whether going from OLD to NEW ends a sign-in that SideStore ran: the
    /// end of the step alone, or of a wait for LocalDevVPN, ends none.
    static func endsSignIn(from old: CartoucheSignInPhase?, to new: CartoucheSignInPhase?) -> Bool {
        guard new == nil, let old else { return false }
        return old == .signingIn || old.needsCode
    }
}

/// The wait for LocalDevVPN, which the built-in SideStore needs to register
/// this iPhone, before a sign-in or before that step alone: what waits goes
/// on as soon as LocalDevVPN is connected, and the wait stops after ten
/// minutes, for the player to try again when they are ready.
struct CartoucheVPNWait: Equatable {
    static let timeout: TimeInterval = 600

    enum Next: Equatable {
        /// LocalDevVPN is connected: what waited goes on.
        case goOn
        case keepWaiting
        /// Ten minutes went by: nothing goes on.
        case stop
    }

    let started: Date

    /// What comes next, LocalDevVPN being CONNECTED or not at NOW.
    func next(connected: Bool, at now: Date) -> Next {
        if connected { return .goOn }
        return now.timeIntervalSince(started) > Self.timeout ? .stop : .keepWaiting
    }

    /// How long it lasted at NOW, in whole seconds, for the measurements.
    func seconds(at now: Date) -> Double { max(0, now.timeIntervalSince(started).rounded()) }
}

/// When Cartouche takes by itself the step that registers this iPhone,
/// which a sign-in that Apple accepted left: each time LocalDevVPN connects
/// while that step is left and Cartouche runs nothing else of the sign-in,
/// three times at most while it is open. LocalDevVPN staying connected
/// after a try, or after a sign-in, starts none: the player can, and
/// Cartouche tries again once LocalDevVPN connects again.
struct CartoucheDeviceStepWatch: Equatable {
    static let triesAtMost = 3

    /// How many times Cartouche took the step by itself.
    private(set) var tries = 0
    /// Whether LocalDevVPN was connected when Cartouche last looked.
    private(set) var connected = false

    /// Cartouche looks whether LocalDevVPN is CONNECTED, the step being
    /// LEFT or not, and Cartouche IDLE or not: whether it takes the step
    /// by itself now.
    mutating func look(connected: Bool, left: Bool, idle: Bool) -> Bool {
        defer { self.connected = connected }
        guard connected, !self.connected, left, idle, tries < Self.triesAtMost else { return false }
        tries += 1
        return true
    }

    /// A sign-in, or the step, ended, LocalDevVPN being CONNECTED or not:
    /// a step left then is taken once LocalDevVPN connects again.
    mutating func ended(connected: Bool) {
        self.connected = connected
    }
}
