//
//  CartoucheProblemReport.swift
//  Cartouche
//
//  What a player sends from System › Report a problem: the report Cartouche
//  writes of an error (CartoucheReport.swift), with what they say happened
//  as its message; the last errors' reports; and this iPhone's memory limit
//  as an entry of catalog/devices.json, so that testers' iPhones join that
//  list (catalog/tools/add_device.py). CartoucheRedaction takes out of it
//  all, what the player wrote included, anything personal. It leaves the
//  iPhone only when the player sends it themselves: with the share sheet,
//  by copying it, or as a GitHub issue on the bug report form,
//  .github/ISSUE_TEMPLATE/bug_report.yml, which issueURL fills in for them
//  to check and post.
//
//  Platform-independent: tested on its own by launcher/Package.swift.
//

import Foundation

/// This iPhone's memory limit, as an entry of catalog/devices.json. It holds
/// nothing personal: the model, iOS's version and what was measured.
struct CartoucheDeviceMeasurement: Equatable {
    /// The model identifier, such as "iPhone18,1".
    var identifier: String
    /// The chip, when the catalog knows the model: iOS does not say it.
    var chip: String?
    var memoryGB: Int
    /// The day of the measurement, as devices.json writes it: 2026-11-10.
    var date: String
    var iOS: String
    var increasedMemoryLimit: Bool
    /// Footprint plus os_proc_available_memory(), as devices.json measures
    /// it (CartoucheMemoryReading).
    var appMemoryLimitMiB: Int

    /// The entry on one line, with devices.json's keys in its order.
    var json: String {
        var fields = ["\"identifier\": " + Self.quoted(identifier)]
        if let chip { fields.append("\"chip\": " + Self.quoted(chip)) }
        fields.append("\"memoryGB\": \(memoryGB)")
        let measurement = [
            "\"date\": " + Self.quoted(date),
            "\"iOS\": " + Self.quoted(iOS),
            "\"increasedMemoryLimit\": \(increasedMemoryLimit)",
            "\"appMemoryLimitMiB\": \(appMemoryLimitMiB)",
        ]
        fields.append("\"measurements\": [{" + measurement.joined(separator: ", ") + "}]")
        return "{" + fields.joined(separator: ", ") + "}"
    }

    /// Whether IDENTIFIER names an iPhone or an iPad as devices.json does:
    /// a simulator, or a Mac running the app, names none.
    static func isModelIdentifier(_ identifier: String) -> Bool {
        identifier.range(of: #"^(iPhone|iPad)[0-9]+,[0-9]+$"#, options: .regularExpression) != nil
    }

    /// The memory of the iPhone in GB, as Apple counts it, from what iOS
    /// reports, which can be a little less.
    static func memoryGB(physicalMemory: UInt64) -> Int {
        max(1, Int((Double(physicalMemory) / 1_073_741_824).rounded(.up)))
    }

    /// The day of DATE in UTC, as devices.json dates its measurements.
    static func day(_ date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04ld-%02ld-%02ld", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    /// TEXT as a JSON string, escaped as JSONEncoder escapes it.
    private static func quoted(_ text: String) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .withoutEscapingSlashes
        guard let data = try? encoder.encode([text]), let array = String(data: data, encoding: .utf8) else {
            return "\"\""
        }
        return String(array.dropFirst().dropLast())
    }
}

struct CartoucheProblemReport {
    /// What the player wrote, as they wrote it.
    var what: String
    /// Cartouche and this iPhone when the page opened
    /// (CartoucheReports.environment()).
    var environment: CartoucheReport.Environment
    /// Cartouche's last steps then, oldest first.
    var journal: [String] = []
    var date = Date()
    /// The last errors' reports, newest first, as their text, already
    /// redacted (CartoucheReports.text(of:)).
    var errors: [String] = []
    var measurement: CartoucheDeviceMeasurement?
    /// What takes out of the report, and out of what the player wrote, what
    /// a report must never hold: the names their settings hold, and anything
    /// shaped like an address (CartoucheRedaction).
    var redaction = CartoucheRedaction.shapes

    /// The report's problem, which no error names: the player's own.
    static let problem = "Reported by the player"
    static let nothingWritten = "(nothing written)"
    /// The line before the measurement, which catalog/tools/add_device.py
    /// looks for.
    static let measurementLine = "For catalog/devices.json:"
    static let errorsLine = "Last errors, newest first:"
    /// The report's message in the form's Logs: the form has its own field
    /// for what the player wrote.
    static let seeWhatHappened = "(see What happened)"
    static let shortenedNote = "[Shortened for GitHub: send the report from Cartouche for all of it.]"

    /// The repository whose bug report form a report goes to, when Cartouche
    /// does not say its own.
    static let repository = "clabeuhtegrite/Cartouche"
    /// The longest address issueURL makes: GitHub answers 414 URI Too Long
    /// past its server's limit, about 8 KB for the whole request line.
    static let issueURLLimit = 7_000

    /// The repository Cartouche's own source is in, from its address on
    /// raw.githubusercontent.com (CartoucheSourceURL, app/config.env), so
    /// that a fork's reports go to the fork; else `repository`.
    static func repository(sourceURL: String?) -> String {
        guard let sourceURL, let url = URL(string: sourceURL), url.host == "raw.githubusercontent.com" else {
            return Self.repository
        }
        let path = url.pathComponents.filter { $0 != "/" }
        guard path.count >= 2 else { return Self.repository }
        return path[0] + "/" + path[1]
    }

    /// What the player wrote, without the blank around it.
    private var words: String {
        what.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The report Cartouche writes of itself, as of an error: what the
    /// player wrote is its message, which its text redacts as the rest.
    var report: CartoucheReport {
        CartoucheReport(title: Self.problem, message: words.isEmpty ? Self.nothingWritten : words,
                        date: date, environment: environment, journal: journal)
    }

    /// The report as the page shows it: Cartouche's report, with what the
    /// player wrote, this iPhone's entry for devices.json, then the last
    /// errors.
    var parts: [String] {
        texts(of: report)
    }

    /// The whole of it, for the share sheet and the pasteboard.
    var text: String {
        parts.joined(separator: "\n\n")
    }

    private func texts(of report: CartoucheReport) -> [String] {
        var texts = [report.text(redactedBy: redaction)]
        if let measurement {
            texts.append(Self.measurementLine + "\n" + measurement.json)
        }
        if !errors.isEmpty {
            let errors = self.errors.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            texts.append(Self.errorsLine + "\n\n" + errors.joined(separator: "\n\n"))
        }
        return texts
    }

    /// The title of the share sheet's message, and of the issue: the first
    /// line the player wrote, redacted; else Cartouche, the model and iOS.
    var title: String {
        makeTitle(redaction.redact(words))
    }

    private func makeTitle(_ words: String) -> String {
        let firstLine = words.split(whereSeparator: \.isNewline).first.map {
            $0.trimmingCharacters(in: .whitespaces)
        } ?? ""
        if firstLine.isEmpty {
            return "Cartouche \(Self.short(environment.cartouche)) on \(Self.short(environment.device)), "
                + "iOS \(Self.short(environment.system))"
        }
        return firstLine.count > 72 ? String(firstLine.prefix(71)) + "…" : firstLine
    }

    /// "0.9.0" of "0.9.0 (50e8079)".
    private static func short(_ text: String) -> String {
        text.components(separatedBy: " (").first ?? text
    }

    /// GitHub's page for a new issue in REPOSITORY ("owner/name"), on the
    /// bug report form with its fields filled in, for the player to check
    /// and post: nothing is sent before they do. The form's Logs lose their
    /// last lines, the oldest errors first, when the address would be too
    /// long for GitHub, then what the player wrote loses its end; the share
    /// sheet always sends it all.
    func issueURL(repository: String = Self.repository, limit: Int = Self.issueURLLimit) -> URL? {
        let words = redaction.redact(self.words)
        let issueTitle = makeTitle(words)
        var shown = report
        shown.message = Self.seeWhatHappened
        let lines = texts(of: shown).joined(separator: "\n\n").components(separatedBy: "\n")

        func address(lines kept: Int, words: String) -> String {
            var logs = lines.prefix(kept).joined(separator: "\n")
            if kept < lines.count {
                logs += (kept > 0 ? "\n" : "") + Self.shortenedNote
            }
            return CartoucheIssueForm.address(repository: repository, template: "bug_report.yml", fields: [
                (name: "title", value: issueTitle),
                (name: "what", value: words),
                (name: "device", value: environment.device),
                (name: "ios", value: environment.system),
                (name: "version", value: environment.cartouche),
                (name: "logs", value: logs),
            ])
        }
        func fits(_ address: String) -> Bool {
            address.utf8.count <= limit
        }

        let whole = address(lines: lines.count, words: words)
        if fits(whole) {
            return URL(string: whole)
        }
        // As many lines as fit, with the note that says some are missing.
        if let kept = Self.largest(upTo: lines.count - 1, where: { fits(address(lines: $0, words: words)) }) {
            return URL(string: address(lines: kept, words: words))
        }
        // None does: what the player wrote, too long by itself, loses its
        // end.
        func shortened(_ count: Int) -> String {
            count > 0 ? String(words.prefix(count)) + "…" : ""
        }
        guard let kept = Self.largest(upTo: words.count - 1, where: { fits(address(lines: 0, words: shortened($0))) }) else {
            return nil
        }
        return URL(string: address(lines: 0, words: shortened(kept)))
    }

    /// The largest count from 0 to MOST that FITS, found by halves: FITS
    /// holds for the smaller counts, up to a point.
    private static func largest(upTo most: Int, where fits: (Int) -> Bool) -> Int? {
        guard most >= 0, fits(0) else { return nil }
        var low = 0, high = most
        while low < high {
            let middle = (low + high + 1) / 2
            if fits(middle) {
                low = middle
            } else {
                high = middle - 1
            }
        }
        return low
    }
}

/// GitHub's page for a new issue on one of a repository's issue forms, its
/// fields filled in by their IDs, as GitHub reads them from the address.
enum CartoucheIssueForm {
    static func address(repository: String, template: String, fields: [(name: String, value: String)]) -> String {
        let query = ([(name: "template", value: template)] + fields)
            .filter { !$0.value.isEmpty }
            .map { encode($0.name) + "=" + encode($0.value) }
            .joined(separator: "&")
        return "https://github.com/" + repository + "/issues/new?" + query
    }

    /// Every character but RFC 3986's unreserved ones percent-encoded, "+"
    /// and "&" included, which a query would otherwise read as a space and
    /// the next field.
    static func encode(_ text: String) -> String {
        var allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")
        allowed.insert(charactersIn: "-._~")
        return text.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
    }
}
