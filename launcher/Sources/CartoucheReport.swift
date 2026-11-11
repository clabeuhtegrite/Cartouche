//
//  CartoucheReport.swift
//  Cartouche
//
//  The report a player copies from an error, for whoever helps them: what
//  failed and why, the error's domains and codes, what Cartouche was doing
//  and how far it had gone, the sizes at stake, Cartouche's and iOS's
//  versions, this iPhone, and Cartouche's last steps (CartoucheJournal).
//  Its text never holds a password, a key, a user name, an Apple ID, a
//  team's name, nor a server's address or name, nor the path of a folder of
//  the player's: CartoucheRedaction takes out those the player's settings
//  name, and anything shaped like an address. The app makes reports, keeps
//  the last ones and copies them (CartoucheReporting.swift). Foundation
//  only, so that swift test checks it on a Mac (launcher/Package.swift).
//

import Foundation

/// A report on what went wrong, made when it happened.
struct CartoucheReport: Codable, Equatable, Sendable {
    /// One fact of the report, such as the size of an IPA.
    struct Fact: Codable, Equatable, Sendable {
        let name: String
        let value: String

        init(_ name: String, _ value: String) {
            self.name = name
            self.value = value
        }
    }

    /// This iPhone and this Cartouche, when the report was made.
    struct Environment: Codable, Equatable, Sendable {
        /// "0.9.0 (50e8079)": the version and the commit it was built from.
        var cartouche: String
        /// "LiveContainer 3.8.11, SideStore 0.7.0".
        var basedOn: String?
        /// iOS: "27.1 (25B72)".
        var system: String
        /// "iPhone18,4 (A20 Pro, 12 GB)".
        var device: String
        /// The language Cartouche speaks, then the iPhone's: "fr (fr-FR)".
        var language: String
        /// Memory, free space, setup, signature, storage.
        var facts: [Fact]
    }

    /// Where in Cartouche something went wrong, as a key that stays the
    /// same in every language and every version, for whatever counts
    /// problems.
    enum Origin: String, Codable, CaseIterable, Sendable {
        /// Installing a game, from a file or from the games folder.
        case install
        /// Sending a game to the games folder.
        case export
        /// Starting a game.
        case start
        /// Removing a game.
        case uninstall
        /// Looking for a new Cartouche, or installing it.
        case update
        /// Renewing Cartouche's signature.
        case renewal
        /// Making the pairing file.
        case pairing
        /// Signing in with an Apple ID.
        case signIn
        /// Adding a place to keep games and saves, or reading it.
        case storage
        /// Keeping copies of the saves, or putting one back.
        case saves
        /// A game's saves on the player's storage.
        case cloud
    }

    /// Where it went wrong.
    var origin: Origin?
    /// What went wrong, as the player read it: "The game was not installed".
    var title: String
    /// Why, as the player read it.
    var message: String
    /// What Cartouche was doing, as its screen said it.
    var step: String?
    /// How far it had gone, from 0 to 1.
    var fraction: Double?
    /// The error behind the message, as its domain and code, then those of
    /// the errors under it (describe(_:)).
    var error: String?
    /// Why it failed, as the measurements say it (CartoucheFailure.swift): a
    /// cause, the step, and the error's names and numbers.
    var failure: CartoucheFailure?
    /// The sizes and other facts of the step.
    var facts: [Fact]
    var date: Date
    var environment: Environment
    /// Cartouche's last steps, oldest first, as its journal wrote them.
    var journal: [String]

    init(origin: Origin? = nil, title: String, message: String, step: String? = nil, fraction: Double? = nil,
         error: String? = nil, failure: CartoucheFailure? = nil, facts: [Fact] = [], date: Date = Date(),
         environment: Environment, journal: [String] = []) {
        self.origin = origin
        self.title = title
        self.message = message
        self.step = step
        self.fraction = fraction
        self.error = error
        self.failure = failure
        self.facts = facts
        self.date = date
        self.environment = environment
        self.journal = journal
    }
}

// MARK: The text

extension CartoucheReport {
    /// The report as the player copies it: labels in English, as in a log,
    /// so that whoever reads it finds the same ones; what Cartouche said to
    /// the player stays in the player's language. REDACTION takes out of it
    /// what a report must not hold.
    func text(redactedBy redaction: CartoucheRedaction) -> String {
        let report = redacted(by: redaction)
        var lines = ["Cartouche report, " + Self.timestamp(report.date)]
        lines.append(Self.line("Problem", report.title))
        if let origin = report.origin {
            lines.append(Self.line("Origin", origin.rawValue))
        }
        lines.append(Self.line("Message", report.message))
        if let error = report.error {
            lines.append(Self.line("Error", error))
        }
        if let failure = report.failure {
            lines.append(Self.line("Cause", failure.summary))
            if let codes = failure.codes, codes != report.error {
                lines.append(Self.line("Codes", codes))
            }
        }
        if let step = report.step {
            let reached = report.fraction.map { " (" + Self.percent($0) + ")" } ?? ""
            lines.append(Self.line("Step", step + reached))
        }
        lines += report.facts.map { Self.line($0.name, $0.value) }
        let environment = report.environment
        lines.append(Self.line("Cartouche", [environment.cartouche, environment.basedOn].compactMap { $0 }.joined(separator: ", ")))
        lines.append(Self.line("iOS", environment.system))
        lines.append(Self.line("Device", environment.device))
        lines.append(Self.line("Language", environment.language))
        lines += environment.facts.map { Self.line($0.name, $0.value) }
        if !report.journal.isEmpty {
            lines.append("")
            lines.append("Last steps:")
            lines += report.journal
        }
        return lines.joined(separator: "\n")
    }

    /// The report with REDACTION applied to every text it holds, as it is
    /// kept and copied.
    func redacted(by redaction: CartoucheRedaction) -> CartoucheReport {
        let redact = redaction.redactor()
        var report = self
        report.title = redact(title)
        report.message = redact(message)
        report.step = step.map(redact)
        report.error = error.map(redact)
        report.facts = facts.map { Fact($0.name, redact($0.value)) }
        report.environment.facts = environment.facts.map { Fact($0.name, redact($0.value)) }
        report.journal = journal.map(redact)
        return report
    }

    /// "Name: value", a value of several lines indented under it.
    private static func line(_ name: String, _ value: String) -> String {
        let lines = value.split(separator: "\n", omittingEmptySubsequences: true)
        return name + ": " + lines.joined(separator: "\n    ")
    }

    /// "2026-11-10 07:12:03 +0100".
    static func timestamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss Z"
        return formatter.string(from: date)
    }

    /// "37 %".
    static func percent(_ fraction: Double) -> String {
        "\(Int((min(max(fraction, 0), 1) * 100).rounded(.down))) %"
    }

    /// "8.41 GB (8,412,345,678 bytes)", the same in every language.
    static func bytes(_ count: Int64) -> String {
        let grouped = NumberFormatter()
        grouped.locale = Locale(identifier: "en_US_POSIX")
        grouped.numberStyle = .decimal
        grouped.groupingSeparator = ","
        grouped.usesGroupingSeparator = true
        let exact = grouped.string(from: NSNumber(value: count)) ?? String(count)
        let gigabytes = Double(count) / 1_000_000_000
        let megabytes = Double(count) / 1_000_000
        let short = gigabytes >= 1 ? String(format: "%.2f GB", gigabytes) : String(format: "%.1f MB", megabytes)
        return "\(short) (\(exact) bytes)"
    }
}

// MARK: The error

extension CartoucheReport {
    /// ERROR as its domain and code, then those of the errors under it,
    /// "NSCocoaErrorDomain 640 < NSPOSIXErrorDomain 28"; a Swift enum adds
    /// its case, "SMBClient.ConnectionError 0 (disconnected)". DETAIL adds
    /// what an error of a library holds, such as an SMB status.
    static func describe(_ error: Error, detail: (Error) -> String? = { _ in nil }) -> String {
        var parts: [String] = []
        var current: Error? = error
        while let error = current, parts.count < 5 {
            let bridged = error as NSError
            var part = "\(bridged.domain) \(bridged.code)"
            var said: [String] = []
            if Mirror(reflecting: error).displayStyle == .enum {
                said.append(String(describing: error))
            }
            if let detail = detail(error) {
                said.append(detail)
            }
            let shown = said.filter { !$0.isEmpty }.joined(separator: ", ")
            if !shown.isEmpty {
                part += " (" + (shown.count > 200 ? String(shown.prefix(200)) + "…" : shown) + ")"
            }
            parts.append(part)
            current = bridged.userInfo[NSUnderlyingErrorKey] as? Error
        }
        return parts.joined(separator: " < ")
    }
}

// MARK: What a report never holds

/// Takes out of a text what a report must never hold: the player's own
/// names, from their settings (their servers' addresses, the names they
/// gave their places, their buckets, the paths of their folders, their user
/// names, access key IDs, Apple ID and team's name), and anything shaped
/// like an address, an e-mail address or a folder of this iPhone's apps.
/// Cartouche never puts a password or a secret key in a message.
struct CartoucheRedaction: Equatable, Sendable {
    /// The addresses of the player's servers, as they typed them: names or
    /// IP addresses, with or without a port, an S3 address with its http://.
    var servers: [String] = []
    /// The names the player gave their places, their shared folders and
    /// buckets.
    var names: [String] = []
    /// User names, access key IDs, the Apple ID, the team's name.
    var accounts: [String] = []
    /// The paths of the player's folders on their servers.
    var paths: [String] = []

    /// What stands in for what is taken out.
    static let server = "<server>"
    static let address = "<address>"
    static let name = "<name>"
    static let account = "<account>"
    static let email = "<e-mail>"
    static let path = "<path>"
    static let container = "<container>"

    /// Nothing of the player's: only the shapes.
    static let shapes = CartoucheRedaction()

    func redact(_ text: String) -> String {
        redactor()(text)
    }

    /// redact(_:) for many texts, the player's names made into expressions
    /// once.
    func redactor() -> (String) -> String {
        let own = ownExpressions()
        return { text in
            guard !text.isEmpty else { return text }
            var text = text
            // Whole addresses first, so that what is inside them goes with
            // them.
            text = Self.replace(Self.url, in: text, with: Self.address)
            text = Self.replace(Self.mail, in: text, with: Self.email)
            text = Self.replace(Self.appContainer, in: text, with: Self.container)
            for (expression, mark) in own {
                text = Self.replace(expression, in: text, with: mark)
            }
            // Any other address.
            text = Self.replace(Self.localHost, in: text, with: Self.server)
            text = Self.replace(Self.ipv4, in: text, with: Self.address)
            return Self.replaceIPv6(in: text)
        }
    }

    /// One expression for each kind of the player's names, servers first:
    /// each name a whole word, so that "nas" stays in "canasta", and the
    /// longest first, so that "nas.local" goes before "nas".
    private func ownExpressions() -> [(NSRegularExpression, String)] {
        let kinds: [(values: [String], mark: String, ignoringCase: Bool)] = [
            (servers.flatMap(Self.forms(ofServer:)), Self.server, true),
            (paths.flatMap(Self.forms(ofPath:)), Self.path, false),
            (names, Self.name, false),
            (accounts, Self.account, true),
        ]
        return kinds.compactMap { kind in
            // Shorter would take letters out of every word.
            let values = Set(kind.values.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { $0.count >= 2 })
            guard !values.isEmpty else { return nil }
            let alternatives = values.sorted { $0.count != $1.count ? $0.count > $1.count : $0 < $1 }
                .map(NSRegularExpression.escapedPattern(for:))
            let pattern = #"(?<![\p{L}\p{N}_])(?:"# + alternatives.joined(separator: "|") + #")(?![\p{L}\p{N}_])"#
            guard let expression = try? NSRegularExpression(pattern: pattern, options: kind.ignoringCase ? [.caseInsensitive] : []) else {
                return nil
            }
            return (expression, kind.mark)
        }
    }

    // MARK: Shapes

    /// "smb://nas.local/Games", "https://s3.eu-west-3.amazonaws.com/…".
    /// Its last character is not a sentence's: "Could not reach smb://x."
    private static let url = regex(#"[A-Za-z][A-Za-z0-9+.\-]*://[^\s"'<>()\[\]]*[^\s"'<>()\[\].,;:!?]"#)
    private static let mail = regex(#"[A-Za-z0-9._%+\-]+@[A-Za-z0-9\-]+(?:\.[A-Za-z0-9\-]+)*\.[A-Za-z]{2,}"#)
    /// The folders iOS gives an app, named by a UUID that is this iPhone's.
    private static let appContainer = regex(
        #"(?:/private)?/var/(?:mobile/Containers|containers)/(?:Data|Shared|Bundle)/(?:Application|AppGroup)/[0-9A-Fa-f\-]{36}"#)
    /// A Bonjour name: "nas.local", "MacBook-Air.local".
    private static let localHost = regex(#"(?<![A-Za-z0-9\-.])[A-Za-z0-9\-]+(?:\.[A-Za-z0-9\-]+)*\.local(?![A-Za-z0-9\-])"#)
    private static let ipv4 = regex(#"(?<![0-9.])(?:[0-9]{1,3}\.){3}[0-9]{1,3}(?![0-9]|\.[0-9])"#)
    /// Groups of hexadecimal digits between colons, as an IPv6 address
    /// writes them: kept only with "::" or seven colons, so that a time of
    /// day, "07:12:03", stays.
    private static let ipv6 = regex(#"(?<![0-9A-Za-z:])(?:[0-9A-Fa-f]{0,4}:){2,7}[0-9A-Fa-f]{0,4}(?:%[0-9A-Za-z]+)?(?![0-9A-Za-z:])"#)

    private static func regex(_ pattern: String, ignoringCase: Bool = false) -> NSRegularExpression {
        // The patterns above are fixed: one that does not compile is a bug
        // that the tests show.
        try! NSRegularExpression(pattern: pattern, options: ignoringCase ? [.caseInsensitive] : [])
    }

    private static func replace(_ expression: NSRegularExpression, in text: String, with mark: String) -> String {
        let range = NSRange(text.startIndex..., in: text)
        return expression.stringByReplacingMatches(in: text, range: range, withTemplate: NSRegularExpression.escapedTemplate(for: mark))
    }

    private static func replaceIPv6(in text: String) -> String {
        var text = text
        let range = NSRange(text.startIndex..., in: text)
        for match in ipv6.matches(in: text, range: range).reversed() {
            guard let found = Range(match.range, in: text) else { continue }
            let candidate = text[found]
            let colons = candidate.filter { $0 == ":" }.count
            guard candidate.contains("::") || colons >= 7,
                  candidate.contains(where: { $0.isHexDigit }) else { continue }
            text.replaceSubrange(found, with: address)
        }
        return text
    }

    // MARK: The player's own

    /// A server's address as it may show in a message: as typed, without
    /// its http:// or https://, and without its port.
    private static func forms(ofServer typed: String) -> [String] {
        var host = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        var forms = [host]
        for scheme in ["https://", "http://"] where host.lowercased().hasPrefix(scheme) {
            host.removeFirst(scheme.count)
            forms.append(host)
        }
        if let slash = host.firstIndex(of: "/") {
            host = String(host[..<slash])
            forms.append(host)
        }
        // "nas.local:8445", but not an IPv6 address's colons.
        if host.filter({ $0 == ":" }).count == 1, let colon = host.lastIndex(of: ":") {
            forms.append(String(host[..<colon]))
        }
        if host.hasPrefix("["), let end = host.firstIndex(of: "]") {
            forms.append(String(host[host.index(after: host.startIndex)..<end]))
        }
        return forms
    }

    /// A folder's path as a server may write it: with or without "/" around.
    private static func forms(ofPath path: String) -> [String] {
        let trimmed = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return trimmed.isEmpty ? [] : [trimmed]
    }
}

// MARK: The journal

/// Cartouche's last steps, one line each, the newest last, for its reports:
/// kept in a file, so that a report made after Cartouche closed, or was
/// closed by iOS, still has them. The app redacts each line before it comes
/// here (CartoucheReports.note).
final class CartoucheJournal: @unchecked Sendable {
    /// The lines kept.
    static let kept = 200

    private let file: URL?
    private let lock = NSLock()
    private var lines: [String]
    private let writing = DispatchQueue(label: "io.github.clabeuhtegrite.cartouche.journal")

    /// FILE holds the lines from one run to the next; nil keeps them in
    /// memory.
    init(file: URL?) {
        self.file = file
        let text = file.flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? ""
        lines = Array(text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init).suffix(Self.kept))
    }

    /// Adds a line, stamped with DATE.
    func note(_ text: String, at date: Date = Date()) {
        let flat = text.split(whereSeparator: \.isNewline).joined(separator: " ")
        let line = Self.stamp(date) + " " + flat
        lock.lock()
        lines.append(line)
        if lines.count > Self.kept {
            lines.removeFirst(lines.count - Self.kept)
        }
        let all = lines
        lock.unlock()
        guard let file else { return }
        writing.async {
            try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? (all.joined(separator: "\n") + "\n").write(to: file, atomically: true, encoding: .utf8)
        }
    }

    /// The COUNT last lines, oldest first.
    func last(_ count: Int) -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return Array(lines.suffix(count))
    }

    /// Waits for the lines written so far to be in the file.
    func flush() {
        writing.sync {}
    }

    /// "11-10 07:12:03", in this iPhone's time zone.
    static func stamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "MM-dd HH:mm:ss"
        return formatter.string(from: date)
    }
}

// MARK: The last reports

/// The last reports Cartouche made, the newest first, kept in a file as
/// their text would show them, redacted: a report on a problem made later
/// can take them along.
final class CartoucheReportArchive: @unchecked Sendable {
    /// The reports kept.
    static let kept = 10

    private let file: URL?
    private let lock = NSLock()
    private var saved: [CartoucheReport]
    private let writing = DispatchQueue(label: "io.github.clabeuhtegrite.cartouche.reports")

    init(file: URL?) {
        self.file = file
        let data = file.flatMap { try? Data(contentsOf: $0) }
        saved = data.flatMap { try? JSONDecoder().decode([CartoucheReport].self, from: $0) } ?? []
    }

    /// The reports, the newest first.
    var reports: [CartoucheReport] {
        lock.lock()
        defer { lock.unlock() }
        return saved
    }

    /// Keeps REPORT, redacted by REDACTION, with the others.
    func add(_ report: CartoucheReport, redactedBy redaction: CartoucheRedaction) {
        lock.lock()
        saved.insert(report.redacted(by: redaction), at: 0)
        if saved.count > Self.kept {
            saved.removeLast(saved.count - Self.kept)
        }
        let all = saved
        lock.unlock()
        guard let file else { return }
        writing.async {
            guard let data = try? JSONEncoder().encode(all) else { return }
            try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: file, options: .atomic)
        }
    }

    /// Waits for the reports kept so far to be in the file.
    func flush() {
        writing.sync {}
    }
}
