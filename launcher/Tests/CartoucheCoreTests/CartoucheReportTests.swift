import XCTest
@testable import CartoucheCore

final class CartoucheReportTests: XCTestCase {
    /// The player's settings, as CartoucheReports reads them.
    private let player = CartoucheRedaction(
        servers: ["192.168.1.2", "nas.local:8445", "http://minio.local:9000", "s3.eu-west-3.amazonaws.com", "[fe80::1]"],
        names: ["NAS d'Ad", "Jeux", "cartouche-ad-saves"],
        accounts: ["ad", "AKIAIOSFODNN7EXAMPLE", "+33612345678", "Ad Example"],
        paths: ["Games/Jeux", "/Sauvegardes/"])

    private let environment = CartoucheReport.Environment(
        cartouche: "0.9.0 (50e8079)", basedOn: "LiveContainer 3.8.11, SideStore 0.7.0", system: "27.1 (25B72)",
        device: "iPhone18,4 (A20 Pro, 12 GB)", language: "fr (fr-FR)",
        facts: [.init("Free on this iPhone", "41.20 GB (41,200,000,000 bytes)"), .init("Storage", "games on SMB, saves on S3")])

    // MARK: What a report never holds

    func testThePlayersServersGo() {
        XCTAssertEqual(player.redact("Cartouche n’a pas pu se connecter à 192.168.1.2 : Access Denied"),
                       "Cartouche n’a pas pu se connecter à <server> : Access Denied")
        XCTAssertEqual(player.redact("Cartouche could not sign in to NAS.local: Connection refused"),
                       "Cartouche could not sign in to <server>: Connection refused")
        XCTAssertEqual(player.redact("minio.local answered 403"), "<server> answered 403")
        XCTAssertEqual(player.redact("s3.eu-west-3.amazonaws.com did not answer"), "<server> did not answer")
        XCTAssertEqual(player.redact("fe80::1 refused"), "<server> refused")
    }

    func testTheirNamesAccountsAndPathsGo() {
        XCTAssertEqual(player.redact("Unpacking it from NAS d'Ad as it arrives."), "Unpacking it from <name> as it arrives.")
        XCTAssertEqual(player.redact("331 Password required for ad."), "331 Password required for <account>.")
        XCTAssertEqual(player.redact("The access key AKIAIOSFODNN7EXAMPLE does not exist"), "The access key <account> does not exist")
        XCTAssertEqual(player.redact("550 /Games/Jeux/Zelda.ipa: No such file"), "550 /<path>/Zelda.ipa: No such file")
        XCTAssertEqual(player.redact("Cannot write to Sauvegardes"), "Cannot write to <path>")
        XCTAssertEqual(player.redact("Bucket cartouche-ad-saves is in eu-west-3"), "Bucket <name> is in eu-west-3")
        XCTAssertEqual(player.redact("Signed in as +33612345678, team Ad Example"), "Signed in as <account>, team <account>")
    }

    func testOnlyWholeWordsGo() {
        // "ad" is the player's user name, "Jeux" a place's name.
        XCTAssertEqual(player.redact("Cartouche could not download the update."), "Cartouche could not download the update.")
        XCTAssertEqual(player.redact("Le dossier de jeux est en lecture seule."), "Le dossier de jeux est en lecture seule.")
        XCTAssertEqual(player.redact("Jeux: 3 IPA"), "<name>: 3 IPA")
    }

    func testAnyAddressGoes() {
        let shapes = CartoucheRedaction.shapes
        XCTAssertEqual(shapes.redact("Could not reach smb://10.0.0.7/Games/x.ipa."), "Could not reach <address>.")
        XCTAssertEqual(shapes.redact("GET https://bucket.s3.amazonaws.com/a?b=c failed"), "GET <address> failed")
        XCTAssertEqual(shapes.redact("Connection to 10.0.0.7:445 timed out"), "Connection to <address>:445 timed out")
        XCTAssertEqual(shapes.redact("Server macbook-air.local closed"), "Server <server> closed")
        XCTAssertEqual(shapes.redact("No route to 2a01:e0a:1b2:3c40::1"), "No route to <address>")
        XCTAssertEqual(shapes.redact("No route to fe80::1c2b:3a4d%en0"), "No route to <address>")
        XCTAssertEqual(shapes.redact("No route to 2001:0db8:85a3:0000:0000:8a2e:0370:7334"), "No route to <address>")
        XCTAssertEqual(shapes.redact("Your Apple ID player@icloud.com is locked."), "Your Apple ID <e-mail> is locked.")
    }

    func testThisIPhonesFoldersGo() {
        let path = "/private/var/mobile/Containers/Data/Application/0F1E2D3C-4B5A-6978-8796-A5B4C3D2E1F0/tmp/CartoucheInstall/Payload"
        XCTAssertEqual(CartoucheRedaction.shapes.redact("Cannot write “romfs.img” in \(path)"),
                       "Cannot write “romfs.img” in <container>/tmp/CartoucheInstall/Payload")
        let group = "/var/mobile/Containers/Shared/AppGroup/0F1E2D3C-4B5A-6978-8796-A5B4C3D2E1F0/SideStore"
        XCTAssertEqual(CartoucheRedaction.shapes.redact(group), "<container>/SideStore")
    }

    func testWhatIsNotAnAddressStays() {
        let shapes = CartoucheRedaction.shapes
        for text in ["11-10 07:12:03 Installing Mario Kart World", "Cartouche 0.9.0, iOS 27.1, SideStore 0.7.0",
                     "8.41 GB (8,412,345,678 bytes)", "NSPOSIXErrorDomain 28", "SMB 3.1.1", "2026-11-10 07:12:03 +0100",
                     "Mario Kart World [0400C3F00006E000].ipa", "550 Requested action not taken."] {
            XCTAssertEqual(shapes.redact(text), text)
        }
    }

    func testTheReportsTextIsRedactedThroughout() {
        var report = sample
        report.message = "Cartouche could not sign in to 192.168.1.2: the server refused ad."
        report.step = "Installing Zelda: unpacking it from NAS d'Ad as it arrives."
        report.facts.append(.init("Place", "smb://nas.local/Games/Jeux"))
        report.journal = ["11-10 07:02:11 Reading the games folder on 192.168.1.2"]
        let text = report.text(redactedBy: player)
        for secret in ["192.168.1.2", "NAS d'Ad", "nas.local", "Games/Jeux", " ad."] {
            XCTAssertFalse(text.contains(secret), secret)
        }
        XCTAssertTrue(text.contains("Message: Cartouche could not sign in to <server>: the server refused <account>."))
        XCTAssertTrue(text.contains("11-10 07:02:11 Reading the games folder on <server>"))
    }

    // MARK: The text

    private var sample: CartoucheReport {
        CartoucheReport(
            origin: .install, title: "Le jeu n’a pas été installé", message: "La connexion réseau a été perdue.\nRéessayez.",
            step: "Installing Mario Kart World: unpacking it as it arrives", fraction: 0.375,
            error: "NSPOSIXErrorDomain 57", facts: [.init("IPA", "Mario Kart World [0400C3F00006E000].ipa")],
            date: Date(timeIntervalSince1970: 1_794_294_723), environment: environment,
            journal: ["11-10 07:02:11 Installing Mario Kart World", "11-10 07:12:03 Failed at 37 %"])
    }

    func testTheText() {
        let lines = sample.text(redactedBy: .shapes).components(separatedBy: "\n")
        XCTAssertTrue(lines[0].hasPrefix("Cartouche report, 2026-11-"))
        XCTAssertEqual(Array(lines[1...13]), [
            "Problem: Le jeu n’a pas été installé",
            "Origin: install",
            "Message: La connexion réseau a été perdue.",
            "    Réessayez.",
            "Error: NSPOSIXErrorDomain 57",
            "Step: Installing Mario Kart World: unpacking it as it arrives (37 %)",
            "IPA: Mario Kart World [0400C3F00006E000].ipa",
            "Cartouche: 0.9.0 (50e8079), LiveContainer 3.8.11, SideStore 0.7.0",
            "iOS: 27.1 (25B72)",
            "Device: iPhone18,4 (A20 Pro, 12 GB)",
            "Language: fr (fr-FR)",
            "Free on this iPhone: 41.20 GB (41,200,000,000 bytes)",
            "Storage: games on SMB, saves on S3",
        ])
        XCTAssertEqual(Array(lines[14...]), ["", "Last steps:", "11-10 07:02:11 Installing Mario Kart World", "11-10 07:12:03 Failed at 37 %"])
    }

    func testWhyItFailedFollowsTheError() throws {
        var report = sample
        report.failure = CartoucheFailure(.network, stage: "unpacking", fraction: 0.375, seconds: 312.4,
                                          codes: "NSPOSIXErrorDomain 57", details: ["vpn": .flag(false)])
        var lines = report.text(redactedBy: .shapes).components(separatedBy: "\n")
        XCTAssertEqual(Array(lines[5...7]), [
            "Error: NSPOSIXErrorDomain 57",
            "Cause: network, at unpacking, 37 %, 312 s; vpn no",
            "Step: Installing Mario Kart World: unpacking it as it arrives (37 %)",
        ])
        // The codes the cause comes from, when they are not the error's.
        report.failure?.codes = "SideStore 1 < NSURLErrorDomain -1001"
        lines = report.text(redactedBy: .shapes).components(separatedBy: "\n")
        XCTAssertEqual(lines[7], "Codes: SideStore 1 < NSURLErrorDomain -1001")
        XCTAssertEqual(try JSONDecoder().decode(CartoucheReport.self, from: JSONEncoder().encode(report)), report)
    }

    func testAReportWithoutStepErrorOrJournal() {
        let report = CartoucheReport(title: "Problem", message: "Nothing starts", environment: environment)
        let text = report.text(redactedBy: .shapes)
        XCTAssertFalse(text.contains("Origin:"))
        XCTAssertFalse(text.contains("Step:"))
        XCTAssertFalse(text.contains("Error:"))
        XCTAssertFalse(text.contains("Last steps:"))
    }

    func testSizesAndProgress() {
        XCTAssertEqual(CartoucheReport.bytes(8_412_345_678), "8.41 GB (8,412,345,678 bytes)")
        XCTAssertEqual(CartoucheReport.bytes(536_870_912), "536.9 MB (536,870,912 bytes)")
        XCTAssertEqual(CartoucheReport.bytes(0), "0.0 MB (0 bytes)")
        XCTAssertEqual(CartoucheReport.percent(0.375), "37 %")
        XCTAssertEqual(CartoucheReport.percent(1.2), "100 %")
        XCTAssertEqual(CartoucheReport.percent(-1), "0 %")
    }

    func testAReportKeepsWhatItSaysWhenSaved() throws {
        let data = try JSONEncoder().encode(sample)
        XCTAssertEqual(try JSONDecoder().decode(CartoucheReport.self, from: data), sample)
    }

    func testAReportSavedWithoutOriginStillReads() throws {
        var older = sample
        older.origin = nil
        let data = try JSONEncoder().encode(older)
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("origin"))
        XCTAssertEqual(try JSONDecoder().decode(CartoucheReport.self, from: data), older)
    }

    // MARK: The error

    private enum Dropped: Error {
        case disconnected
    }

    private struct Refused: Error {}

    func testAnErrorAndTheOnesUnderIt() {
        let posix = NSError(domain: NSPOSIXErrorDomain, code: 28)
        let cocoa = NSError(domain: NSCocoaErrorDomain, code: 640, userInfo: [NSUnderlyingErrorKey: posix])
        XCTAssertEqual(CartoucheReport.describe(cocoa), "NSCocoaErrorDomain 640 < NSPOSIXErrorDomain 28")
    }

    func testASwiftError() {
        let enumError = CartoucheReport.describe(Dropped.disconnected)
        XCTAssertTrue(enumError.hasSuffix(" 0 (disconnected)"), enumError)
        XCTAssertTrue(enumError.contains("Dropped"), enumError)
        let structError = CartoucheReport.describe(Refused(), detail: { $0 is Refused ? "NTSTATUS 0xC0000022" : nil })
        XCTAssertTrue(structError.hasSuffix(" 1 (NTSTATUS 0xC0000022)"), structError)
    }

    func testAChainStopsAtFive() {
        var error = NSError(domain: "Last", code: 0)
        for level in 1 ... 8 {
            error = NSError(domain: "Level", code: level, userInfo: [NSUnderlyingErrorKey: error])
        }
        XCTAssertEqual(CartoucheReport.describe(error).components(separatedBy: " < ").count, 5)
    }

    // MARK: The journal

    private func temporaryFile(_ name: String) -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        return folder.appendingPathComponent("Cartouche/" + name)
    }

    func testTheJournalKeepsItsLastLinesFromOneRunToTheNext() {
        let file = temporaryFile("Journal.txt")
        let journal = CartoucheJournal(file: file)
        let date = Date(timeIntervalSince1970: 1_794_294_723)
        for index in 1 ... CartoucheJournal.kept + 5 {
            journal.note("Step \(index)\nsecond line", at: date)
        }
        journal.flush()
        let last = journal.last(2)
        XCTAssertEqual(last.map { String($0.dropFirst(15)) }, ["Step \(CartoucheJournal.kept + 4) second line", "Step \(CartoucheJournal.kept + 5) second line"])
        XCTAssertEqual(last[0].prefix(15), Substring(CartoucheJournal.stamp(date) + " "))

        let again = CartoucheJournal(file: file)
        XCTAssertEqual(again.last(1000).count, CartoucheJournal.kept)
        XCTAssertEqual(again.last(2), last)
    }

    func testAJournalWithoutFile() {
        let journal = CartoucheJournal(file: nil)
        journal.note("Cartouche started")
        XCTAssertEqual(journal.last(5).count, 1)
    }

    // MARK: The last reports

    func testTheArchiveKeepsTheTenLastReportsRedacted() {
        let file = temporaryFile("Reports.json")
        let archive = CartoucheReportArchive(file: file)
        for index in 1 ... 12 {
            var report = sample
            report.message = "Attempt \(index) on 192.168.1.2"
            archive.add(report, redactedBy: player)
        }
        archive.flush()
        XCTAssertEqual(archive.reports.count, CartoucheReportArchive.kept)
        XCTAssertEqual(archive.reports.first?.message, "Attempt 12 on <server>")
        XCTAssertEqual(archive.reports.last?.message, "Attempt 3 on <server>")

        let again = CartoucheReportArchive(file: file)
        XCTAssertEqual(again.reports, archive.reports)
    }
}
