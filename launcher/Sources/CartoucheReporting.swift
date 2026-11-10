//
//  CartoucheReporting.swift
//  Cartouche
//
//  The reports on what goes wrong (CartoucheReport.swift), in the app: made
//  where an error shows, with this iPhone's and this Cartouche's state, kept
//  with the last ten and with a journal of Cartouche's last steps, both in
//  Application Support/Cartouche, and copied by the Copy the report button
//  under each error, without a password, a user name, an Apple ID, a team's
//  name, nor a server's address, name or folder (CartoucheRedaction, from
//  the player's settings).
//

import SwiftUI
import UIKit
#if canImport(SMBClient)
import SMBClient
#endif

@MainActor
enum CartoucheReports {
    private static let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Cartouche", isDirectory: true)

    #if CARTOUCHE_GALLERY
    // The gallery's screens start from nothing.
    private static let journalFile: URL? = nil
    private static let archiveFile: URL? = nil
    #else
    private static let journalFile: URL? = folder.appendingPathComponent("Journal.txt")
    private static let archiveFile: URL? = folder.appendingPathComponent("Reports.json")
    #endif

    private static let journalLines = CartoucheJournal(file: journalFile)
    private static let archive = CartoucheReportArchive(file: archiveFile)
    /// The last steps a report takes along.
    static let journalShown = 40

    // MARK: Making a report

    /// Posted on the main thread for each report made, with the report,
    /// redacted, as its object. Its user info holds, under "origin", the
    /// report's origin as its raw value ("install"), under "error" the
    /// error behind it, if any, and under "background" whether it came of
    /// a check Cartouche made by itself.
    static let reported = Notification.Name("CartoucheErrorReported")

    /// A report on what just went wrong at ORIGIN, as the player reads it:
    /// TITLE and MESSAGE, the ERROR behind them, the STEP Cartouche was at
    /// and how far it had gone, and the FACTS of that step, such as its
    /// sizes. It is noted in the journal and posted as reported. Unless it
    /// came of a check Cartouche makes by itself, IN BACKGROUND, such as
    /// reading the games folder each time it comes back, which fails
    /// whenever the player is away from home, it is kept with the last ten.
    static func make(_ origin: CartoucheReport.Origin, _ title: String, message: String, error: Error? = nil,
                     step: String? = nil, fraction: Double? = nil, facts: [CartoucheReport.Fact] = [],
                     inBackground: Bool = false) -> CartoucheReport {
        note("Problem (" + origin.rawValue + "): " + title + ": " + message + (error.map { " [" + describe($0) + "]" } ?? ""))
        let report = CartoucheReport(origin: origin, title: title, message: message, step: step, fraction: fraction,
                                     error: error.map(describe), facts: facts, environment: environment(),
                                     journal: journal(last: journalShown))
        let redaction = redaction()
        if !inBackground {
            archive.add(report, redactedBy: redaction)
        }
        var info: [String: Any] = ["origin": origin.rawValue, "background": inBackground]
        if let error {
            info["error"] = error
        }
        NotificationCenter.default.post(name: reported, object: report.redacted(by: redaction), userInfo: info)
        return report
    }

    /// The report's text, redacted, to copy or to send.
    static func text(of report: CartoucheReport) -> String {
        report.text(redactedBy: redaction())
    }

    /// Puts the report's text on the pasteboard.
    static func copy(_ report: CartoucheReport) {
        UIPasteboard.general.string = text(of: report)
        note("Report copied: " + report.title)
    }

    /// The last reports, the newest first, redacted.
    static var recent: [CartoucheReport] { archive.reports }

    // MARK: The journal

    /// Notes a step in the journal, redacted.
    static func note(_ text: String) {
        journalLines.note(redaction().redact(text))
    }

    /// The journal's COUNT last lines, oldest first.
    static func journal(last count: Int) -> [String] {
        journalLines.last(count)
    }

    private static var startNoted = false

    /// Notes that Cartouche opened, once per launch.
    static func noteStart() {
        guard !startNoted else { return }
        startNoted = true
        let environment = environment()
        note("Cartouche \(environment.cartouche) started, iOS \(environment.system), \(environment.device)")
    }

    /// Notes what Cartouche does with a game (CartoucheGameActions.work):
    /// each step as the screen says it, every quarter of the way, and its
    /// end, unless it FAILED, which its report noted.
    static func noteWork(from old: CartoucheGameWork?, to new: CartoucheGameWork?, failed: Bool) {
        switch (old, new) {
        case (nil, let new?):
            note(new.title + ": " + new.step)
        case (let old?, let new?):
            if old.kind != new.kind || old.name != new.name || old.step != new.step {
                note(new.title + ": " + new.step)
            } else if let fraction = new.fraction, fraction < 1, Int(fraction * 4) > Int((old.fraction ?? 0) * 4) {
                note(new.title + ": " + CartoucheReport.percent(fraction))
            }
        case (let old?, nil):
            if !failed { note(old.title + ": done") }
        case (nil, nil):
            break
        }
    }

    // MARK: The player's storage

    /// A report on the connection to SERVER, as its form holds it, which
    /// failed with ERROR. What the player typed in the form is taken out of
    /// reports first: it is not in their settings yet.
    static func connectionFailed(to server: CartoucheStorageServer, error: Error) -> CartoucheReport {
        redactTyped(servers: [server.host], names: [server.name, server.share], accounts: [server.username])
        var facts: [CartoucheReport.Fact] = []
        if let port = server.port {
            facts.append(.init("Port", String(port)))
        }
        if server.kind == .s3 {
            let host = server.host.lowercased()
            facts.append(.init("S3 server", host.contains("amazonaws.com") ? "Amazon S3" : "the player's own"))
            facts.append(.init("Connection", host.hasPrefix("http://") ? "HTTP" : "HTTPS"))
            if let region = server.region {
                facts.append(.init("Region", region))
            }
        }
        return make(.storage, CartoucheText.storageConnectFailed, message: error.localizedDescription, error: error,
                    step: "Connecting to " + kindName(server.kind), facts: facts)
    }

    // MARK: What a report says of this iPhone

    /// This iPhone and this Cartouche, now.
    static func environment() -> CartoucheReport.Environment {
        let info = Bundle.main.infoDictionary ?? [:]
        var cartouche = info["CFBundleShortVersionString"] as? String ?? "?"
        if let build = info["LCVersionInfo"] as? String, !build.isEmpty {
            cartouche += " (" + build + ")"
        }
        let bases = [("LiveContainer", "CartoucheLiveContainerVersion"), ("SideStore", "CartoucheSideStoreVersion")]
            .compactMap { name, key in (info[key] as? String).map { name + " " + $0 } }
        var system = CartoucheDevice.iOSVersion
        if let build = systemBuild, !build.isEmpty {
            system += " (" + build + ")"
        }
        let model = CartoucheDevice.modelIdentifier.isEmpty ? "?" : CartoucheDevice.modelIdentifier
        let device: String
        if let profile = CartoucheCatalog.shared.device(CartoucheDevice.modelIdentifier) {
            device = "\(model) (\(profile.chip), \(profile.memoryGB) GB)"
        } else {
            device = "\(model) (\(ProcessInfo.processInfo.physicalMemory / 1_048_576) MiB)"
        }
        let language = (Bundle.main.preferredLocalizations.first ?? "?") + " (" + (Locale.preferredLanguages.first ?? "?") + ")"

        var facts: [CartoucheReport.Fact] = []
        let increased = "Increased Memory Limit " + (CartoucheDevice.hasIncreasedMemoryLimit ? "on" : "off")
        if let memory = CartoucheMemoryReading.now() {
            facts.append(.init("Memory", "limit \(memory.limitMiB) MiB, used \(memory.footprintMiB) MiB, \(increased)"))
        } else {
            facts.append(.init("Memory", "no limit from iOS, \(increased)"))
        }
        if let free = freeSpace {
            facts.append(.init("Free on this iPhone", CartoucheReport.bytes(free)))
        }
        let setup = CartoucheSetup.shared
        let certificate: String
        switch (setup.hasCertificate, setup.certificateWorks) {
        case (false, _): certificate = "none"
        case (true, true?): certificate = "works"
        case (true, false?): certificate = "refused by iOS"
        case (true, nil): certificate = "being checked"
        }
        facts.append(.init("Setup", "pairing file \(setup.hasPairingFile ? "yes" : "no"), Apple ID \(setup.appleID == nil ? "no" : "yes"), certificate \(certificate)"))
        if let days = CartoucheSignature.current().daysLeft {
            facts.append(.init("Signature", days < 0 ? "expired" : "\(days) days left"))
        }
        let settings = CartoucheStorageSettings.shared
        let places = CartoucheStorageRole.allCases.compactMap { role -> String? in
            guard let server = settings.location(role)?.server else { return nil }
            return "\(role.rawValue) on \(kindName(server.kind))" + (settings.isReadOnly(role) ? " (read-only)" : "")
        }
        facts.append(.init("Storage", places.isEmpty ? "none" : places.joined(separator: ", ")))
        return CartoucheReport.Environment(cartouche: cartouche, basedOn: bases.isEmpty ? nil : bases.joined(separator: ", "),
                                           system: system, device: device, language: language, facts: facts)
    }

    /// "SMB", as a report names a kind of storage.
    static func kindName(_ kind: CartoucheStorageServer.Kind) -> String {
        switch kind {
        case .smb: return "SMB"
        case .folder: return "a folder in Files"
        case .s3: return "S3"
        case .ftp: return "FTP"
        case .sftp: return "SFTP"
        }
    }

    /// "a games folder on SMB": where a step reads or writes, without a name.
    static func place(_ role: CartoucheStorageRole) -> String {
        guard let server = CartoucheStorageSettings.shared.location(role)?.server else { return "no \(role.rawValue) folder" }
        return "the \(role.rawValue) folder, on \(kindName(server.kind))"
    }

    /// iOS's build, "25B72".
    private static let systemBuild: String? = {
        var size = 0
        guard sysctlbyname("kern.osversion", nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var build = [CChar](repeating: 0, count: size)
        guard sysctlbyname("kern.osversion", &build, &size, nil, 0) == 0 else { return nil }
        return String(cString: build)
    }()

    private static var freeSpace: Int64? {
        let values = try? URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
            .resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage
    }

    // MARK: The error

    /// ERROR as its domains and codes, with what an error of SMB, S3, FTP or
    /// SFTP holds.
    static func describe(_ error: Error) -> String {
        CartoucheReport.describe(error) { error in
            #if canImport(SMBClient)
            if let response = error as? ErrorResponse {
                return String(format: "NTSTATUS 0x%08X", response.header.status)
            }
            #endif
            #if canImport(NIOSSH)
            if let failure = error as? SFTPFailure {
                return "SFTP status \(failure.code)"
            }
            #endif
            if let failure = error as? CartoucheS3Failure {
                return "HTTP \(failure.status) \(failure.code)"
            }
            if let failure = error as? FTPFailure {
                return "FTP \(failure.reply.code)"
            }
            return nil
        }
    }

    // MARK: What a report never holds

    /// The team's name, which is the player's own on a free account.
    private static let teamName = CartoucheSignature.current().teamName

    /// What the player typed since Cartouche opened that their settings do
    /// not hold yet: a server they are adding, the Apple ID of a first
    /// sign-in.
    private static var typed = CartoucheRedaction()

    /// Takes what the player just typed out of reports, as their own: the
    /// SERVERS, NAMES and ACCOUNTS of a form, before its connection works
    /// and its settings are kept. Called before trying them.
    static func redactTyped(servers: [String] = [], names: [String] = [], accounts: [String] = []) {
        typed.servers += servers.filter { !typed.servers.contains($0) }
        typed.names += names.filter { !typed.names.contains($0) }
        typed.accounts += accounts.filter { !typed.accounts.contains($0) }
    }

    /// What the player's settings name: their servers' addresses, the names
    /// of their places, their shared folders and buckets, the paths of their
    /// folders, their user names and access key IDs, their Apple ID and their
    /// team's name; and what they typed since Cartouche opened.
    static func redaction() -> CartoucheRedaction {
        let settings = CartoucheStorageSettings.shared
        var redaction = typed
        for server in settings.servers {
            redaction.servers.append(server.host)
            redaction.names.append(server.name)
            redaction.names.append(server.share)
            redaction.accounts.append(server.username)
        }
        redaction.paths = CartoucheStorageRole.allCases.compactMap { settings.place($0)?.path }
        if let appleID = CartoucheSetup.shared.appleID {
            redaction.accounts.append(appleID)
        }
        if let teamName {
            redaction.accounts.append(teamName)
        }
        return redaction
    }
}

// MARK: The button under an error

/// Copy the report, under an error: copies the report, which says so for a
/// moment.
@available(iOS 17.0, *)
struct CartoucheReportButton: View {
    let report: CartoucheReport
    @State private var copied = false

    var body: some View {
        Button {
            CartoucheReports.copy(report)
            copied = true
        } label: {
            Label(copied ? CartoucheText.reportCopied : CartoucheText.reportCopy,
                  systemImage: copied ? "checkmark.circle.fill" : "doc.on.doc")
                .contentTransition(.symbolEffect(.replace))
        }
        .accessibilityHint(CartoucheText.reportHint)
        .sensoryFeedback(.success, trigger: copied) { _, now in now }
        .task(id: copied) {
            guard copied else { return }
            try? await Task.sleep(for: .seconds(2))
            copied = false
        }
    }
}

/// Says over the console that the report is copied, once its alert has
/// gone.
@available(iOS 17.0, *)
struct CartoucheReportCopiedBanner: View {
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "checkmark.circle.fill")
                .font(.title3)
                .foregroundStyle(Color.green)
            VStack(alignment: .leading, spacing: 2) {
                Text(CartoucheText.reportCopied)
                    .font(.subheadline.weight(.semibold))
                Text(CartoucheText.reportCopiedDetail)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .background(.regularMaterial, in: Capsule())
        .shadow(color: .black.opacity(0.25), radius: 12, y: 4)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isStaticText)
    }
}
