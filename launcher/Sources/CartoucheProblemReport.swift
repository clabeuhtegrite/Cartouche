//
//  CartoucheProblemReport.swift
//  Cartouche
//
//  What a player sends from System › Report a problem: what they say
//  happened; the report Cartouche writes of itself and this iPhone, its
//  last steps and its last errors, cleaned of anything personal by
//  CartoucheRedaction (CartoucheReport.swift); and this iPhone's memory
//  limit as an entry of catalog/devices.json, so that testers' iPhones join
//  that list (catalog/tools/add_device.py). It leaves the iPhone only when
//  the player sends it themselves: with the share sheet, by copying it, or
//  as a GitHub issue on the bug report form, .github/ISSUE_TEMPLATE/
//  bug_report.yml, which issueURL fills in for them to check and post.
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
    /// What the player wrote, as they wrote it: they see it before sending.
    var what: String
    /// Cartouche's report of itself and this iPhone, with its last steps,
    /// already cleaned.
    var report: String
    /// The last errors' reports, already cleaned, newest first.
    var errors: [String] = []
    var measurement: CartoucheDeviceMeasurement?
    /// The bug report form's fields: Cartouche's version, the model
    /// identifier and iOS's version.
    var version: String
    var model: String
    var iOS: String

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
            return repository
        }
        let parts = url.pathComponents.filter { $0 != "/" }
        guard parts.count >= 2 else { return repository }
        return parts[0] + "/" + parts[1]
    }

    /// The title of the share sheet's message, and of the issue: the first
    /// line the player wrote.
    var title: String {
        let firstLine = what.split(whereSeparator: \.isNewline).first.map {
            $0.trimmingCharacters(in: .whitespaces)
        } ?? ""
        if firstLine.isEmpty {
            return "Cartouche \(version) on \(model), iOS \(iOS)"
        }
        return firstLine.count > 72 ? String(firstLine.prefix(71)) + "…" : firstLine
    }

    /// Everything but what the player wrote, for the form's Logs: the
    /// report, the measurement, then the errors, so that the oldest go first
    /// when issueURL has to shorten it.
    var details: String {
        detailLines.joined(separator: "\n")
    }

    /// The whole of it, for the share sheet and the pasteboard.
    var text: String {
        let what = self.what.trimmingCharacters(in: .whitespacesAndNewlines)
        return "What happened\n" + (what.isEmpty ? "(nothing written)" : what) + "\n\n" + details
    }

    private var detailLines: [String] {
        var lines = report.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: .newlines)
        if let measurement {
            lines += ["", "For catalog/devices.json:", measurement.json]
        }
        if !errors.isEmpty {
            lines += ["", "Last errors, newest first:"]
            for (index, error) in errors.enumerated() {
                if index > 0 { lines.append("") }
                lines += error.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: .newlines)
            }
        }
        return lines
    }

    /// GitHub's page for a new issue in REPOSITORY ("owner/name"), on the
    /// bug report form with its fields filled in, for the player to check
    /// and post: nothing is sent before they do. The details lose their
    /// last lines, the oldest errors first, when the address would be too
    /// long for GitHub; the share sheet always sends them whole.
    func issueURL(repository: String = Self.repository, limit: Int = Self.issueURLLimit) -> URL? {
        let what = self.what.trimmingCharacters(in: .whitespacesAndNewlines)
        var lines = detailLines
        var shortened = false
        func address(what: String) -> String {
            var logs = lines.joined(separator: "\n")
            if shortened {
                logs += "\n[Shortened for GitHub: send the report from Cartouche for all of it.]"
            }
            return CartoucheIssueForm.address(repository: repository, template: "bug_report.yml", fields: [
                (name: "title", value: title),
                (name: "what", value: what),
                (name: "device", value: model),
                (name: "ios", value: iOS),
                (name: "version", value: version),
                (name: "logs", value: logs),
            ])
        }
        var text = address(what: what)
        while text.utf8.count > limit, !lines.isEmpty {
            lines.removeLast()
            shortened = true
            text = address(what: what)
        }
        // What the player wrote, if too long by itself, loses its end.
        var kept = what.count
        while text.utf8.count > limit, kept > 0 {
            kept -= max(1, kept / 8)
            text = address(what: kept > 0 ? String(what.prefix(kept)) + "…" : "")
        }
        guard text.utf8.count <= limit else { return nil }
        return URL(string: text)
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
