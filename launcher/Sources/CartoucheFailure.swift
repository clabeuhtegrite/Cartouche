//
//  CartoucheFailure.swift
//  Cartouche
//
//  Why something failed, as Cartouche's measurements send it with each error
//  (telemetry/README.md) and its reports say it (CartoucheReport.swift): a
//  cause from a fixed list, the step that was running, how far it had got,
//  how long it took, and the error's names and numbers. Never the error's
//  words, which can hold a path, an address, an Apple ID or the name of the
//  iPhone: only keys chosen here, names a programmer gave, and numbers.
//
//  The built-in SideStore, whose errors come back to Cartouche as their text
//  alone, leaves Cartouche how its last action ended in the keychain they
//  share (app/patches/sidestore/0014): CartoucheSideStoreOutcome reads it and
//  checks each value before any is kept.
//
//  Platform-independent: tested on its own by launcher/Package.swift.
//

import Foundation

struct CartoucheFailure: Codable, Equatable, Sendable {
    /// What broke, as a key that stays the same in every language and every
    /// version.
    enum Cause: String, Codable, CaseIterable, Sendable {
        // The Apple account.
        /// Apple refused the Apple ID or the password.
        case appleCredentials
        /// Apple asks for an app-specific password.
        case appSpecificPassword
        /// Apple refused the verification code.
        case verificationCode
        /// No verification code came in time.
        case verificationTimeout
        /// Apple limits the attempts or the codes sent, for now.
        case tooManyAttempts
        /// Apple asks the player to review the account on its site.
        case accountRepair
        /// The account belongs to no development team.
        case noTeam
        /// Apple refused the sign-in otherwise.
        case appleRefused
        /// Apple's servers answered with an error, or an answer that could
        /// not be read.
        case appleServer
        /// The anisette server, which signs the requests to Apple, failed.
        case anisette

        // Signing.
        /// The account has a certificate the built-in SideStore does not
        /// hold, which it never revokes.
        case certificateRefused
        case tooManyCertificates
        /// A certificate missing, expired or revoked.
        case certificate
        case appID
        case appGroup
        case profile
        /// The portal refused to register this iPhone.
        case deviceRegistration
        /// The built-in SideStore is not signed in.
        case notSignedIn
        /// The app to sign is not in a shape SideStore can sign.
        case appBundle

        // The iPhone's connection to itself.
        /// LocalDevVPN is off, or not the one SideStore needs.
        case vpn
        /// The pairing file is missing or refused.
        case pairing
        /// The iPhone could not be reached through LocalDevVPN.
        case device

        // The built-in SideStore and Cartouche's bridge to it.
        /// It quit before it answered: it crashed, or iOS ended it.
        case sideStoreQuit
        /// Another of its actions was under way.
        case sideStoreBusy
        /// It did not start in time.
        case sideStoreSlowStart
        /// LiveProcess, where it runs, is not in the app.
        case liveProcessMissing
        /// LiveProcess did not start.
        case liveProcessFailed
        /// It has no such action: a SideStore older than Cartouche.
        case intentMissing
        /// It ended without saying how.
        case noOutcome
        /// This Cartouche carries no bridge to it.
        case bridgeMissing
        /// The keychain they share could not be written.
        case keychain
        /// It found no Apple ID from Cartouche.
        case credentialsMissing
        /// Its database did not open.
        case database
        /// No newer version to install.
        case noUpdate
        case noApps
        case timedOut

        // The network.
        /// The iPhone is offline.
        case offline
        /// A server could not be reached or the connection broke.
        case network
        /// A server answered with an HTTP error.
        case serverStatus

        // The player's storage.
        /// Their server did not answer from here.
        case storageOffline
        /// It refused the user name, the password or the keys.
        case storageCredentials
        /// It refused access.
        case storagePermission
        /// The shared folder, the folder, the bucket or the file is not there.
        case storageNotFound
        /// Its disk is full.
        case storageFull
        /// The place is read-only.
        case storageReadOnly
        /// The address is not one Cartouche can use.
        case storageAddress
        /// The server's key changed since the player trusted it.
        case storageHostKey
        /// Its answer could not be read.
        case storageAnswer
        /// It failed otherwise.
        case storageServer
        /// The place is not set up: no folder, no key, no account.
        case storageSetup

        // This iPhone.
        /// Not enough space left on the iPhone.
        case noSpace
        /// A file Cartouche needs is not there.
        case fileMissing
        /// A file could not be read.
        case fileUnreadable
        /// The file holds no app Cartouche can install.
        case notAnApp
        /// The game could not be signed.
        case notSigned
        /// This copy of LiveContainer is not the one that installs games.
        case notPrimary
        /// The game is running: the player quits it first.
        case gameRunning
        case cancelled
        case other
    }

    /// What broke.
    var cause: Cause
    /// The step that was running, as a key: "device", "ResignApp", "signing".
    var stage: String?
    /// How far it had got, from 0 to 100.
    var percent: Int?
    /// How long it ran, in seconds.
    var seconds: Int?
    /// The error's domains and codes, when Cartouche's own error does not
    /// hold them: "SideSign.DeveloperPortalError 2".
    var codes: String?
    /// The rest, names and numbers only: the error's kind, Apple's code, the
    /// HTTP status, whether LocalDevVPN was on...
    var details: [String: CartoucheTelemetryValue]

    init(_ cause: Cause, stage: String? = nil, fraction: Double? = nil, seconds: Double? = nil, codes: String? = nil,
         details: [String: CartoucheTelemetryValue] = [:]) {
        self.cause = cause
        self.stage = stage.flatMap(Self.name)
        self.percent = fraction.map(Self.percent)
        self.seconds = seconds.map { max(0, Int($0.rounded())) }
        self.codes = codes.flatMap(Self.checkedCodes)
        self.details = details.filter { Self.isKept($0.key, $0.value) }
    }

    /// What it adds to the error's event, beside its origin.
    var fields: [String: CartoucheTelemetryValue] {
        var fields = details
        fields["cause"] = .text(cause.rawValue)
        if let stage { fields["stage"] = .text(stage) }
        if let percent { fields["percent"] = .number(Double(percent)) }
        if let seconds { fields["seconds"] = .number(Double(seconds)) }
        return fields
    }

    /// The report's line: "vpn, at device, 50 %, 12 s; kind noVPN, vpn off".
    var summary: String {
        var head = [cause.rawValue]
        if let stage { head.append("at " + stage) }
        if let percent { head.append("\(percent) %") }
        if let seconds { head.append("\(seconds) s") }
        let rest = details.keys.sorted().map { key -> String in
            switch details[key]! {
            case .text(let text): return key + " " + text
            case .number(let number): return key + " " + (number == number.rounded() ? String(Int(number)) : String(number))
            case .flag(let flag): return key + " " + (flag ? "yes" : "no")
            }
        }
        return head.joined(separator: ", ") + (rest.isEmpty ? "" : "; " + rest.joined(separator: ", "))
    }

    // MARK: What is kept

    /// NAME when it is a name a programmer gave: a letter, then letters,
    /// digits and underscores, 48 at most; "A>B" for a trail of them.
    static func name(_ name: String) -> String? {
        let parts = name.split(separator: ">", omittingEmptySubsequences: false)
        guard (1...6).contains(parts.count), parts.allSatisfy({ isName(String($0)) }) else { return nil }
        return name
    }

    private static func isName(_ text: String) -> Bool {
        guard (1...48).contains(text.count), let first = text.unicodeScalars.first,
              first.isASCII, CharacterSet.letters.contains(first) else { return false }
        return text.unicodeScalars.allSatisfy { $0.isASCII && (CharacterSet.alphanumerics.contains($0) || $0 == "_") }
    }

    /// "NSURLErrorDomain -1001 < NSPOSIXErrorDomain 60", four at most, or nil.
    static func checkedCodes(_ codes: String) -> String? {
        let parts = codes.components(separatedBy: " < ")
        guard (1...4).contains(parts.count) else { return nil }
        for part in parts {
            let words = part.split(separator: " ", omittingEmptySubsequences: false)
            guard words.count == 2, isDomain(String(words[0])), let code = Int(words[1]), abs(code) < 1 << 53 else { return nil }
        }
        return codes
    }

    static func isDomain(_ text: String) -> Bool {
        (1...64).contains(text.count)
            && text.unicodeScalars.allSatisfy { $0.isASCII && (CharacterSet.alphanumerics.contains($0) || "._-".unicodeScalars.contains($0)) }
    }

    /// The details a failure keeps, under a key of letters and digits, as
    /// the telemetry server takes them: names, numbers and flags.
    static func isKept(_ key: String, _ value: CartoucheTelemetryValue) -> Bool {
        guard isName(key), key.count <= 32, !key.contains("_") else { return false }
        switch value {
        case .text(let text): return name(text) != nil
        case .number(let number): return number.isFinite && abs(number) < 1e15
        case .flag: return true
        }
    }

    static func percent(_ fraction: Double) -> Int {
        guard fraction.isFinite else { return 0 }
        return Int((min(max(fraction, 0), 1) * 100).rounded(.down))
    }
}

// MARK: Errors that say what they are

/// An error of Cartouche's that names its kind, a key that stays the same in
/// every language, the cause it stands for, and the error behind it.
protocol CartoucheDescribedError: Error {
    var failureKind: String { get }
    var failureCause: CartoucheFailure.Cause { get }
    var underlyingError: Error? { get }
}

/// An error that knows why it happened better than its type says: one of the
/// built-in SideStore, whose words alone came back.
protocol CartoucheExplainedError: Error {
    var failure: CartoucheFailure? { get }
}

extension CartoucheFailure {
    /// The status a server's protocol answered with, which only the app can
    /// read off the error of its library: an SMB NTSTATUS, an S3 or HTTP
    /// status, an FTP reply, an SFTP status.
    struct ProtocolStatus: Equatable, Sendable {
        enum Kind: String, Sendable {
            case smb, s3, ftp, sftp
        }

        var kind: Kind
        var status: Int
        /// S3's code: "SignatureDoesNotMatch", "NoSuchBucket".
        var code: String?

        var cause: Cause {
            switch kind {
            case .smb:
                switch UInt32(truncatingIfNeeded: status) {
                case 0xC000_006D, 0xC000_0064, 0xC000_006A, 0xC000_006E, 0xC000_006F, 0xC000_0070,
                     0xC000_0071, 0xC000_0072, 0xC000_0193, 0xC000_0224, 0xC000_0234:
                    return .storageCredentials
                case 0xC000_0022:
                    return .storagePermission
                case 0xC000_00CC, 0xC000_0034, 0xC000_003A, 0xC000_000F, 0xC000_00BE:
                    return .storageNotFound
                case 0xC000_007F, 0xC000_0044:
                    return .storageFull
                case 0xC000_00A2:
                    return .storageReadOnly
                default:
                    return .storageServer
                }
            case .s3:
                switch (status, code ?? "") {
                case (_, "InvalidAccessKeyId"), (_, "SignatureDoesNotMatch"), (_, "InvalidToken"), (_, "ExpiredToken"),
                     (_, "TokenRefreshRequired"), (_, "InvalidSecurity"):
                    return .storageCredentials
                case (_, "PermanentRedirect"), (_, "AuthorizationHeaderMalformed"), (_, "IllegalLocationConstraintException"),
                     (_, "InvalidBucketName"), (301, _), (307, _):
                    return .storageAddress
                case (_, "NoSuchBucket"), (_, "NoSuchKey"), (404, _):
                    return .storageNotFound
                case (401, _):
                    return .storageCredentials
                case (403, _):
                    return .storagePermission
                case (_, "QuotaExceeded"), (_, "EntityTooLarge"), (507, _):
                    return .storageFull
                default:
                    return .storageServer
                }
            case .ftp:
                switch status {
                case 530, 332: return .storageCredentials
                case 550, 450: return .storageNotFound
                case 553, 532: return .storagePermission
                case 552, 452: return .storageFull
                default: return .storageServer
                }
            case .sftp:
                switch status {
                case 2: return .storageNotFound
                case 3: return .storagePermission
                case 5: return .storageAnswer
                default: return .storageServer
                }
            }
        }
    }

    /// The failure behind ERROR, which happened at STAGE: the cause of the
    /// deepest error under it that tells one, from what Cartouche's own
    /// errors say they are (CartoucheDescribedError), the status of the
    /// storage's protocol that STATUS reads off an error, and the domains
    /// and codes of iOS's.
    static func of(_ error: Error, stage: String? = nil, fraction: Double? = nil, seconds: Double? = nil,
                   status: (Error) -> ProtocolStatus? = { _ in nil }) -> CartoucheFailure {
        if let explained = error as? CartoucheExplainedError, var failure = explained.failure {
            if failure.stage == nil { failure.stage = stage.flatMap(name) }
            if failure.percent == nil { failure.percent = fraction.map(percent) }
            if failure.seconds == nil { failure.seconds = seconds.map { max(0, Int($0.rounded())) } }
            return failure
        }

        var cause = Cause.other
        var details: [String: CartoucheTelemetryValue] = [:]
        var current: Error? = error
        var depth = 0
        while let found = current, depth < 6 {
            depth += 1
            if let described = found as? CartoucheDescribedError {
                if details["kind"] == nil, name(described.failureKind) != nil {
                    details["kind"] = .text(described.failureKind)
                }
                cause = described.failureCause
                current = described.underlyingError ?? ((found as NSError).userInfo[NSUnderlyingErrorKey] as? Error)
                continue
            }
            if let reply = status(found) {
                cause = reply.cause
                details["protocol"] = .text(reply.kind.rawValue)
                details["status"] = .number(Double(reply.status))
                if let code = reply.code.flatMap(name) {
                    details["statusCode"] = .text(code)
                }
            } else if let known = Self.cause(ofSystemError: found) {
                cause = known
            }
            current = (found as NSError).userInfo[NSUnderlyingErrorKey] as? Error
        }
        return CartoucheFailure(cause, stage: stage, fraction: fraction, seconds: seconds, details: details)
    }

    /// What an error of iOS says by its domain and code, when it says one of
    /// the causes Cartouche tells apart.
    static func cause(ofSystemError error: Error) -> Cause? {
        if error is CancellationError { return .cancelled }
        let bridged = error as NSError
        switch (bridged.domain, bridged.code) {
        case (NSURLErrorDomain, NSURLErrorCancelled):
            return .cancelled
        case (NSURLErrorDomain, NSURLErrorNotConnectedToInternet), (NSURLErrorDomain, NSURLErrorInternationalRoamingOff),
             (NSURLErrorDomain, NSURLErrorDataNotAllowed):
            return .offline
        case (NSURLErrorDomain, _):
            return .network
        case (NSCocoaErrorDomain, NSFileWriteOutOfSpaceError), (NSPOSIXErrorDomain, 28), (NSPOSIXErrorDomain, 69):
            return .noSpace
        case (NSCocoaErrorDomain, NSFileWriteVolumeReadOnlyError), (NSPOSIXErrorDomain, 30):
            return .storageReadOnly
        case (NSCocoaErrorDomain, NSFileNoSuchFileError), (NSCocoaErrorDomain, NSFileReadNoSuchFileError), (NSPOSIXErrorDomain, 2):
            return .fileMissing
        case (NSCocoaErrorDomain, NSFileReadNoPermissionError), (NSCocoaErrorDomain, NSFileWriteNoPermissionError),
             (NSCocoaErrorDomain, NSFileReadCorruptFileError), (NSPOSIXErrorDomain, 1), (NSPOSIXErrorDomain, 13):
            return .fileUnreadable
        case (NSCocoaErrorDomain, NSUserCancelledError), (NSPOSIXErrorDomain, 89):
            return .cancelled
        case (NSPOSIXErrorDomain, 32), (NSPOSIXErrorDomain, 50), (NSPOSIXErrorDomain, 51), (NSPOSIXErrorDomain, 54),
             (NSPOSIXErrorDomain, 57), (NSPOSIXErrorDomain, 60), (NSPOSIXErrorDomain, 61), (NSPOSIXErrorDomain, 64),
             (NSPOSIXErrorDomain, 65):
            return .network
        default:
            return nil
        }
    }
}

// MARK: The built-in SideStore

/// How the built-in SideStore's last action for Cartouche ended, as it left
/// it in their shared keychain (app/patches/sidestore/0014), every value
/// checked: names and numbers in the ranges they can take, nothing else.
struct CartoucheSideStoreOutcome: Equatable, Sendable {
    /// The keychain item, under the service SideStore names after
    /// Cartouche's bundle identifier.
    static let account = "cartouche.outcome"

    enum Action: String, Sendable {
        case signIn
        case refresh
        case update
    }

    var action: Action
    var ok: Bool
    var date: Date
    var seconds: Int?
    var percent: Int?
    /// The step reached: the sign-in's own ("account", "device"...), or the
    /// last operation started ("ResignApp").
    var stage: String?
    /// The operations it ran, the last ones: "FetchProvisioningProfiles>ResignApp".
    var trail: String?
    /// Whose error it is ("portal", "anisette", "minimuxer"...), and its case.
    var family: String?
    var kind: String?
    var codes: String?
    /// Apple's code, the HTTP status, the URL error's code, and what the
    /// server it could not reach is ("apple", "anisette", "sideStore", "device").
    var apple: Int?
    var http: Int?
    var network: Int?
    var host: String?
    /// What the action noted on its way: whether Apple asked for a code and
    /// how, the account's certificates and teams.
    var facts: [String: CartoucheTelemetryValue]

    /// What SideStore wrote, each value of the type it must have or none.
    private struct Written: Decodable {
        enum Key: String, CodingKey {
            case version, action, ok, date, seconds, percent, stage, trail, family, kind, codes, apple, http, network, host
            case codeAsked, bundledCertificate, activeCertificate, certificates, teams, codeMode, teamType
        }

        var version: Int
        var action: String
        var ok: Bool
        var date: Int
        var ints: [Key: Int] = [:]
        var texts: [Key: String] = [:]
        var flags: [Key: Bool] = [:]

        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: Key.self)
            version = try values.decode(Int.self, forKey: .version)
            action = try values.decode(String.self, forKey: .action)
            ok = try values.decode(Bool.self, forKey: .ok)
            date = try values.decode(Int.self, forKey: .date)
            for key in [Key.seconds, .percent, .apple, .http, .network, .certificates, .teams] {
                if let value = try? values.decodeIfPresent(Int.self, forKey: key) { ints[key] = value }
            }
            for key in [Key.stage, .trail, .family, .kind, .codes, .host, .codeMode, .teamType] {
                if let value = try? values.decodeIfPresent(String.self, forKey: key) { texts[key] = value }
            }
            for key in [Key.codeAsked, .bundledCertificate, .activeCertificate] {
                if let value = try? values.decodeIfPresent(Bool.self, forKey: key) { flags[key] = value }
            }
        }

        func int(_ key: Key, in range: ClosedRange<Int>) -> Int? {
            ints[key].flatMap { range.contains($0) ? $0 : nil }
        }

        func name(_ key: Key) -> String? {
            texts[key].flatMap(CartoucheFailure.name)
        }
    }

    /// Nil unless DATA is how ACTION ended, left less than MAXIMUM AGE ago.
    init?(data: Data, expecting action: Action, now: Date = Date(), maximumAge: TimeInterval = 3_600) {
        guard let written = try? JSONDecoder().decode(Written.self, from: data),
              (1...99).contains(written.version), written.action == action.rawValue,
              (0...(1 << 40)).contains(written.date) else { return nil }
        let date = Date(timeIntervalSince1970: TimeInterval(written.date))
        guard date <= now.addingTimeInterval(300), now.timeIntervalSince(date) <= maximumAge else { return nil }

        self.action = action
        ok = written.ok
        self.date = date
        seconds = written.int(.seconds, in: 0...86_400)
        percent = written.int(.percent, in: 0...100)
        stage = written.name(.stage)
        trail = written.name(.trail)
        family = written.name(.family)
        kind = written.name(.kind)
        codes = written.texts[.codes].flatMap(CartoucheFailure.checkedCodes)
        apple = written.int(.apple, in: -9_999_999...9_999_999)
        http = written.int(.http, in: 100...599)
        network = written.int(.network, in: -99_999...99_999)
        host = written.name(.host)

        var facts: [String: CartoucheTelemetryValue] = [:]
        for (key, flag) in written.flags {
            facts[key.rawValue] = .flag(flag)
        }
        for key in [Written.Key.certificates, .teams] {
            if let count = written.int(key, in: 0...10_000) { facts[key.rawValue] = .number(Double(count)) }
        }
        for key in [Written.Key.codeMode, .teamType] {
            if let name = written.name(key) { facts[key.rawValue] = .text(name) }
        }
        self.facts = facts
    }

    /// The cause its error stands for.
    var cause: CartoucheFailure.Cause {
        if ok { return .other }
        if stage == "database" { return .database }
        switch family {
        case "cartouche":
            switch kind {
            case "noCredentials": return .credentialsMissing
            case "codeTimeout": return .verificationTimeout
            case "accountRepair": return .accountRepair
            default: return .other
            }
        case "portal":
            switch kind {
            case "incorrectCredentials": return .appleCredentials
            case "appSpecificPasswordRequired": return .appSpecificPassword
            case "incorrectVerificationCode", "invalid2FAResponse", "requiresTwoFactorAuthentication": return .verificationCode
            case "tooManyAttempts": return .tooManyAttempts
            case "accountRepairRequired": return .accountRepair
            case "noTeams": return .noTeam
            case "userCancelled": return .cancelled
            case "invalidAnisetteData": return .anisette
            case "tooManyCertificates": return .tooManyCertificates
            case "certificateDoesNotExist", "invalidCertificateRequest": return .certificate
            case "invalidDeviceID", "deviceAlreadyRegistered": return .deviceRegistration
            case "maximumAppIDLimitReached", "appIDDoesNotExist", "invalidAppIDName", "invalidBundleIdentifier",
                 "bundleIdentifierUnavailable": return .appID
            case "invalidAppGroup", "appGroupDoesNotExist": return .appGroup
            case "invalidProvisioningProfileIdentifier", "provisioningProfileDoesNotExist": return .profile
            default: return .appleRefused
            }
        case "server", "decoding":
            return .appleServer
        case "anisette":
            return .anisette
        case "operation", "minimuxer":
            switch kind {
            case "noVPN", "invalidVPN": return .vpn
            case "pairingNotComplete", "invalidPairingFile", "unknownUDID", "pairingNotLoaded", "invalidPairing": return .pairing
            case "noDevice", "notReachable", "noConnection", "minimuxerNotStarted", "notStarted",
                 "connectionModeNotConfigured": return .device
            case "forbidden": return stage == "certificate" ? .certificateRefused : .other
            case "notAuthenticated": return .notSignedIn
            case "timedOut": return .timedOut
            case "missingUpdate": return .noUpdate
            case "noInstalledApps": return .noApps
            case "certificateExpired", "certificateRevoked", "customCertificateExpired", "customCertificateRevoked":
                return .certificate
            case "invalidApp", "missingAppBundle", "missingInfoPlist": return .appBundle
            case "missingProvisioningProfile": return .profile
            case "missingAppGroup": return .appGroup
            case "invalidResponse": return .appleServer
            default: return family == "minimuxer" ? .device : .other
            }
        case "pairing":
            return .pairing
        case "emProxy":
            return .vpn
        case "signer":
            switch kind {
            case "missingProvisioningProfile": return .profile
            default: return .appBundle
            }
        case "certificate", "ocsp":
            return .certificate
        case "database":
            return .database
        case "cancelled":
            return .cancelled
        case "network":
            // An iPhone without a connection cannot reach any server, the
            // anisette ones first.
            if let network, [-1009, -1018, -1020].contains(network) { return .offline }
            if host == "anisette" || host == "sideStore" { return .anisette }
            return .network
        default:
            return .other
        }
    }

    /// Its names and numbers, as an error's details. Its family is in its
    /// codes' first domain.
    var details: [String: CartoucheTelemetryValue] {
        var details = facts
        if let trail { details["trail"] = .text(trail) }
        if let kind { details["kind"] = .text(kind) }
        if let apple { details["apple"] = .number(Double(apple)) }
        if let http { details["http"] = .number(Double(http)) }
        if let network { details["network"] = .number(Double(network)) }
        if let host { details["host"] = .text(host) }
        return details
    }
}

extension CartoucheFailure {
    /// The sentences of LiveContainer's bridge to the built-in SideStore
    /// (its SideStoreSupport), which say why SideStore did not answer. They
    /// are matched on the iPhone, and only the cause leaves it.
    static let bridgeSentences: [(prefix: String, cause: Cause)] = [
        ("Built-in SideStore quit unexpectedly", .sideStoreQuit),
        ("Another refresh task is in progress", .sideStoreBusy),
        ("Built-in SideStore failed to start in reasonable time", .sideStoreSlowStart),
        ("Unable to locate LiveProcess bundle", .liveProcessMissing),
        ("Failed to start extension", .liveProcessFailed),
        ("SideStore refresh intent type was not found", .intentMissing),
        ("SideStore type is not an AppIntent", .intentMissing),
    ]

    /// Why an action of the built-in SideStore failed: from the OUTCOME it
    /// left, when it left one, otherwise from the bridge's MESSAGE, matched
    /// against its own sentences. VPN and PAIRING say whether LocalDevVPN was
    /// connected and a pairing file in place, which most actions need.
    static func sideStore(outcome: CartoucheSideStoreOutcome?, message: String?, fraction: Double?, seconds: Double?,
                          vpn: Bool?, pairing: Bool?) -> CartoucheFailure {
        var details: [String: CartoucheTelemetryValue] = [:]
        if let vpn { details["vpn"] = .flag(vpn) }
        if let pairing { details["pairing"] = .flag(pairing) }

        if let outcome, !outcome.ok {
            details.merge(outcome.details) { _, new in new }
            return CartoucheFailure(outcome.cause, stage: outcome.stage,
                                    fraction: outcome.percent.map { Double($0) / 100 } ?? fraction,
                                    seconds: outcome.seconds.map { Double($0) } ?? seconds, codes: outcome.codes, details: details)
        }
        let text = message.map(CartoucheSignInMessage.readable) ?? ""
        let said = bridgeSentences.first { text.hasPrefix($0.prefix) }?.cause
        guard let outcome else {
            return CartoucheFailure(said ?? .noOutcome, fraction: fraction, seconds: seconds, details: details)
        }
        // SideStore's action went well, yet what ran it failed on the way back.
        details["outcomeOK"] = .flag(true)
        return CartoucheFailure(said ?? .other, stage: outcome.stage, fraction: fraction, seconds: seconds, details: details)
    }

    /// What a successful action of the built-in SideStore says, for its
    /// event: how long it took, and what it noted on its way.
    static func sideStoreSuccess(outcome: CartoucheSideStoreOutcome?, seconds: Double?) -> [String: CartoucheTelemetryValue] {
        var fields = outcome?.facts ?? [:]
        if let taken = outcome?.seconds.map({ Double($0) }) ?? seconds {
            fields["seconds"] = .number(max(0, taken.rounded()))
        }
        if outcome == nil {
            fields["outcome"] = .flag(false)
        }
        return fields
    }
}
