//
//  CartoucheGameLogShareTests.swift
//  CartoucheCoreTests
//
//  A game's log as the player shares it (Sources/CartoucheGameLogShare.swift):
//  what the cleaning takes out of what Send to Cartouche sends, rule by
//  rule, and what it leaves; the digest of a log, its start, its end and
//  its problems; the summary, as the zip has it, the logs as the game wrote
//  them, and as Send to Cartouche sends it, cleaned; what Send to Cartouche
//  sends, within the server's limits; and the zip's name. The lines are
//  written as nxnative's format strings write them (main.m, CloudSaves.m,
//  crash.c, hle_thread.c, hle_account.c, hle_nvn.c).
//

import Foundation
import XCTest
@testable import CartoucheCore

final class CartoucheGameLogShareTests: XCTestCase {
    private let cleaning = CartoucheLogCleaning()

    /// Cartouche's app folder, and the game's data folder in it, as
    /// LiveContainer names them.
    private let container = "/private/var/mobile/Containers/Data/Application/0F1E2D3C-4B5A-6978-8796-A5B4C3D2E1F0"
    private let dataFolder = "5A3C1B2D-0E4F-4A6B-8C7D-9E0F1A2B3C4D"

    // MARK: What the cleaning takes out

    func testTheDevicesAppFoldersGoAndWhatIsInThemStays() {
        XCTAssertEqual(
            cleaning.clean("boot: game files \(container)/Documents/Data/Application/\(dataFolder)/Documents/romfs.img"),
            "boot: game files <container>/Documents/Data/Application/<id>/Documents/romfs.img")
        XCTAssertEqual(cleaning.clean("[RED] boot: invalid RomFS image \(container)/tmp/romfs.img (errno=2); trying the folders"),
                       "[RED] boot: invalid RomFS image <container>/tmp/romfs.img (errno=2); trying the folders")
    }

    func testAnyOtherPathGoesWhole() {
        // The folder the player picked in Files for the game's cloud saves.
        XCTAssertEqual(cleaning.clean("boot: cloud saves through /private/var/mobile/Library/Mobile Documents/com~apple~CloudDocs/Saves d'Élodie"),
                       "boot: cloud saves through <path>")
        // Google Drive's folder in Files holds the player's e-mail address.
        XCTAssertEqual(
            cleaning.clean("[RED] could not bookmark /private/var/mobile/Library/CloudStorage/GoogleDrive-lou@example.com/My Drive/Switch: The file couldn’t be opened."),
            "[RED] could not bookmark <path>: The file couldn’t be opened.")
        XCTAssertEqual(cleaning.clean("launcher: cloud-save folder set to /var/mobile/Library/Mobile Documents/x (bookmark)"),
                       "launcher: cloud-save folder set to <path> (bookmark)")
        XCTAssertEqual(cleaning.clean("[dm] could not open '/private/var/mobile/Library/Mobile Documents/Ma sauvegarde' (errno 2)"),
                       "[dm] could not open '<path>' (errno 2)")
        XCTAssertEqual(cleaning.clean("[dm] dyld: loaded /Users/lou/nx-work/build/dmhost"), "[dm] dyld: loaded <path>")
    }

    func testTheSystemsOwnFoldersStay() {
        let line = "[dm] Metal: /System/Library/Extensions/AGXMetalG17P.bundle/AGXMetalG17P loaded"
        XCTAssertEqual(cleaning.clean(line), line)
        XCTAssertEqual(cleaning.clean("[dm] save file run/platform/temp/variables.bin"), "[dm] save file run/platform/temp/variables.bin")
    }

    func testIdentifiersGo() {
        XCTAssertEqual(cleaning.clean("[dm] data folder \(dataFolder) ready"), "[dm] data folder <id> ready")
        XCTAssertEqual(cleaning.clean("[dm] install 9f1c2b9e4d3a4c8e9b712a5d8e0f3c47 kept"), "[dm] install <key> kept")
    }

    func testAnythingShapedLikeAKeyGoes() {
        XCTAssertEqual(cleaning.clean("header_key = 0x5a3c1b2d0e4f4a6b8c7d9e0f1a2b3c4d5a3c1b2d0e4f4a6b8c7d9e0f1a2b3c4d"),
                       "header_key = <key>")
        XCTAssertEqual(cleaning.clean("token eyJhbGciOiJIUzI1NiJ9xQ7kLm3pR8sT2vW9yZ1bC4dF6gH0jK5nP accepted"),
                       "token <key> accepted")
        XCTAssertEqual(cleaning.clean("key AKIAIOSFODNN7EXAMPLEwJalrXUtnFEMIK7MDENGbPxRfiCYEXAMPLEKEY+/= set"),
                       "key <key> set")
    }

    func testWhatLooksLikeAKeyButNamesCodeStays() {
        // nxnative names functions by their C++ symbols, builds by their
        // commit and shader chain, games by their title ID.
        let symbol = "[RED] unimplemented _ZN2nn7account11GetNicknameEPNS0_8NicknameERKNS0_3UidE called"
        XCTAssertEqual(cleaning.clean(symbol), symbol)
        let build = "[dm] build: commit 6c3aeb3d70a1, shader chain 844bf1a5ea8f, profile mkw, title 0400C3F00006E000"
        XCTAssertEqual(cleaning.clean(build), build)
        let words = "[dm] kIOGPUCommandBufferCallbackErrorOutOfMemoryWhileSubmitting: retry"
        XCTAssertEqual(cleaning.clean(words), words)
    }

    func testTheNicknameGoes() {
        XCTAssertEqual(cleaning.clean("boot: env DM_NICK=Lou B. (env.txt)"), "boot: env DM_NICK=<name> (env.txt)")
        XCTAssertEqual(cleaning.clean("boot: env DM_NICK=Lou"), "boot: env DM_NICK=<name>")
    }

    func testThePlayersOwnNamesAndAnyAddressGo() {
        let player = CartoucheLogCleaning(redaction: CartoucheRedaction(servers: ["nas.local"], names: ["NAS d'Élodie"],
                                                                        accounts: ["player@icloud.com"]))
        XCTAssertEqual(player.clean("[dm] save sync: smb://nas.local/Saves failed; NAS d'Élodie offline"),
                       "[dm] save sync: <address> failed; <name> offline")
        XCTAssertEqual(player.clean("[dm] net: 192.168.1.2:445 and fe80::1c2b:3a4d%en0 refused"),
                       "[dm] net: <address>:445 and <address> refused")
        XCTAssertEqual(player.clean("[guest] user player@icloud.com"), "[guest] user <e-mail>")
    }

    func testTheMemoryACrashWritesOutGoesAndWhereItCrashedStays() {
        let crash = """
        [dm] CRASH sig=11 addr=0x10 pc=main+0x1a2b3c lr=main+0x1a2b00 sp=0x16fdff000
        x0=0x0 x1=0x16fdff120 x2=0x2 x3=0x3 x4=0x4 x5=0x5
        [dm] *x1: 0x16fdff200 main+0x40 0 0x6c6c6548206f6c6c 0x1 0x16fdff300
        [dm] bt: main+0x1a2b00 main+0x1a0000 0x1a2b3c4d5e nnSdk+0x1234
        [dm] fp=0x16fdff100  0x100 bytes below sp:
        [dm]   16fdff200 0 6c6c6548206f6c6c 1
        [dm]   0 0 0 0
        [dm] stack scan sp=0x16fdff000: [+8]main+0x1a2b00 [+24]nnSdk+0x1234
        [dm]   0x10a registers pc=main+0x2000 x19=0x16fdff400 x20=0x1
        [dm]   0x10a x19 → 128 bytes from 0x16fdff400 (first 8 bytes = main+0x10): 6c6c6548 206f6c6c 00000000 00000001
        [dm]   0x10a stack sp+0x000: 0000000000000000 000000016fdff200 6c6c6548206f6c6c 0000000000000001 0000000000000000 0000000000000000 0000000000000000 0000000000000000
        [dm]   0x10a backtrace: main+0x2000 main+0x1000
        """
        let cleaned = crash.split(separator: "\n").map { cleaning.clean(String($0)) }
        XCTAssertEqual(cleaned, [
            "[dm] CRASH sig=11 addr=0x10 pc=main+0x1a2b3c lr=main+0x1a2b00 sp=0x16fdff000",
            "x0=0x0 x1=0x16fdff120 x2=0x2 x3=0x3 x4=0x4 x5=0x5",
            "[dm] *x1: <memory> main+0x40 0 <memory> 0x1 <memory>",
            "[dm] bt: main+0x1a2b00 main+0x1a0000 0x1a2b3c4d5e nnSdk+0x1234",
            "[dm] fp=0x16fdff100  0x100 bytes below sp:",
            "[dm]   <memory> 0 <memory> 1",
            "[dm]   0 0 0 0",
            "[dm] stack scan sp=0x16fdff000: [+8]main+0x1a2b00 [+24]nnSdk+0x1234",
            "[dm]   0x10a registers pc=main+0x2000 x19=0x16fdff400 x20=0x1",
            "[dm]   0x10a x19 → 128 bytes from 0x16fdff400 (first 8 bytes = main+0x10): <memory>",
            "[dm]   0x10a stack sp+0x000: <memory>",
            "[dm]   0x10a backtrace: main+0x2000 main+0x1000",
        ])
    }

    func testWhatSaysHowTheGameRanStays() {
        // Each of these feeds the game's measures (CartoucheGameLog.swift):
        // the cleaning leaves them as they are.
        let lines = [
            "[dm] [nvn] timing up to frame 300: frame time p50 16.67 / p95 18.90 / max 61.00 ms (300 frames); GPU p50 9.80 / p95 14.20 / max 20.00 ms (292 frames);",
            "[dm] [nvn] frame interval up to frame 300: >16.7ms 6 / 300 frames, p99 33.40 ms",
            "[dm] [nvn] on-screen up to frame 300: 300 frames, dropped 5 (discarded 1), p99 33.30 ms; footprint 4100 MiB; brightness 0.50; thermal 0",
            "[dm] [nvn] power up to frame 600: CPU energy 4.10 W, 136.7 mJ per frame (30.0 fps); CPU 230% (100 = one core), 85% of it on performance cores; wakeups 1200/s (out of platform idle 300); GPU 610.0 ms/s; thermal 1; top yielders: none",
            "[dm] [longframe] frame 412 (21.80 s) whole frame 61.0 ms, submit+present 45.2 ms, GPU 12.0 ms; new pipelines 3 + shader libraries 1, 40.1 ms in all; texture uploads 0 first + 0 re-uploads, 0.0 MB / 0.0 ms",
            "[dm] [nvn-mtl] memory up to frame 600: resident 4700 MB, GPU allocated 2910 MB, deferred-release queue 0, residency set 12, serial objects 3; headroom to the system memory limit 1330 MB",
            "[dm] front end: thermal state → 2 (30 s after launch)",
            "[dm] audio #1 device callbacks 4000: 512–512 frames each, 2.5 blocks queued on average at callback; in these 2000, 1 underruns, 10.7 ms zero-padded",
            "[dm] front end: layout split, hinge 0, divisions (), picture {{0, 0}, {393, 221}}, controls {{0, 221}, {393, 631}}",
            "boot: env DM_LAUNCHER=0 (env.txt)",
        ]
        for line in lines {
            XCTAssertEqual(cleaning.clean(line), line)
        }
    }

    func testAVeryLongLineLosesItsEnd() {
        let line = "[dm] " + String(repeating: "é", count: 20_000)
        let cleaned = cleaning.clean(line)
        XCTAssertTrue(cleaned.hasSuffix(" bytes cut]"), String(cleaned.suffix(40)))
        XCTAssertLessThan(cleaned.utf8.count, CartoucheLogCleaning.longestLine + 40)
        XCTAssertFalse(cleaned.contains("\u{FFFD}"))
    }

    // MARK: A log

    /// A session of COUNT lines, a [RED] line at the start and a crash at
    /// its end, its paths those of the device.
    private func session(lines count: Int) -> String {
        var lines = ["boot: game files \(container)/Documents/Data/Application/\(dataFolder)/Documents/romfs.img",
                     "[RED] boot: Documents/romfs.img is not the image this build needs (verdict 2); not used"]
        for frame in stride(from: 300, through: (count - 4) * 300, by: 300) {
            lines.append("[dm] [nvn] frame interval up to frame \(frame): >16.7ms 6 / 300 frames, p99 33.40 ms")
        }
        lines.append("[dm] CRASH sig=11 addr=0x10 pc=main+0x1a2b3c lr=main+0x1a2b00 sp=0x16fdff000")
        lines.append("[dm] *x1: 0x16fdff200 main+0x40 0 0x6c6c6548206f6c6c 0x1 0x16fdff300")
        return lines.joined(separator: "\n") + "\n"
    }

    func testADigestKeepsTheStartTheEndAndTheProblems() {
        let digest = CartoucheGameLogDigest.of(text: session(lines: 2_000), name: "log.txt")
        XCTAssertEqual(digest.lines, 2_000)
        XCTAssertEqual(digest.head.count, CartoucheGameLogDigest.headKept)
        XCTAssertEqual(digest.lastLines.count, CartoucheGameLogDigest.tailKept)
        XCTAssertEqual(digest.firstOfLast, 2_000 - CartoucheGameLogDigest.tailKept + 1)
        // As the game wrote them.
        XCTAssertEqual(digest.head.first, "boot: game files \(container)/Documents/Data/Application/\(dataFolder)/Documents/romfs.img")
        XCTAssertEqual(digest.lastLines.last, "[dm] *x1: 0x16fdff200 main+0x40 0 0x6c6c6548206f6c6c 0x1 0x16fdff300")
        XCTAssertEqual(digest.crash, "[dm] CRASH sig=11 addr=0x10 pc=main+0x1a2b3c lr=main+0x1a2b00 sp=0x16fdff000")
        XCTAssertEqual(digest.notable, ["[RED] boot: Documents/romfs.img is not the image this build needs (verdict 2); not used",
                                        "[dm] CRASH sig=11 addr=0x10 pc=main+0x1a2b3c lr=main+0x1a2b00 sp=0x16fdff000"])
        // Cleaned, the lines it keeps.
        let cleaned = digest.cleaned(by: cleaning.cleaner())
        XCTAssertEqual(cleaned.lines, 2_000)
        XCTAssertEqual(cleaned.head.first, "boot: game files <container>/Documents/Data/Application/<id>/Documents/romfs.img")
        XCTAssertEqual(cleaned.lastLines.count, CartoucheGameLogDigest.tailKept)
        XCTAssertEqual(cleaned.lastLines.last, "[dm] *x1: <memory> main+0x40 0 <memory> 0x1 <memory>")
        XCTAssertEqual(cleaned.crash, digest.crash)
        XCTAssertEqual(cleaned.notable, digest.notable)
    }

    func testAShortLogIsAllHeadAndTail() {
        let digest = CartoucheGameLogDigest.of(text: "a\nb\nc", name: "log.prev.txt")
        XCTAssertEqual(digest.lines, 3)
        XCTAssertEqual(digest.head + digest.lastLines, ["a", "b", "c"])
        XCTAssertEqual(digest.bytes, 5)
        XCTAssertEqual(CartoucheGameLogDigest.of(text: "", name: "log.txt").lines, 0)
        XCTAssertEqual(CartoucheGameLogDigest.of(text: "a\n\nb\n", name: "log.txt").head, ["a", "", "b"])
    }

    func testReadingALogFile() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let log = folder.appendingPathComponent("log.txt")
        let text = session(lines: 1_500)
        try Data(text.utf8).write(to: log)
        let digest = try XCTUnwrap(CartoucheGameLogDigest.read(log, name: "log.txt"))
        XCTAssertNotNil(digest.modified)
        XCTAssertFalse(digest.isCut)
        var read = digest
        read.created = nil
        read.modified = nil
        XCTAssertEqual(read, CartoucheGameLogDigest.of(text: text, name: "log.txt"))
        XCTAssertNil(CartoucheGameLogDigest.read(folder.appendingPathComponent("none.txt"), name: "log.txt"))
        // The game's folder, and the logs it holds, the last session's first.
        let games = CartoucheGameLogFolder(game: "Mario Kart World", documents: folder)
        XCTAssertEqual(games.files.map(\.lastPathComponent), ["log.txt"])
        try Data("x\n".utf8).write(to: folder.appendingPathComponent("log.prev.txt"))
        XCTAssertEqual(games.files.map(\.lastPathComponent), ["log.txt", "log.prev.txt"])
    }

    // MARK: What the player shares

    private let environment = CartoucheReport.Environment(
        cartouche: "0.12.1 (5ee6a80)", basedOn: "LiveContainer 3.8.11, SideStore 0.7.0", system: "27.1 (25B72)",
        device: "iPhone19,4 (A19 Pro, 12 GB)", language: "fr (fr-FR)",
        facts: [.init("Memory", "limit 8192 MiB, used 210 MiB, Increased Memory Limit on"),
                .init("Storage", "games on SMB, saves on SMB")])

    private func share(lines: [Int], what: String = "") -> CartoucheGameLogShare {
        let logs = lines.enumerated().map { index, count in
            CartoucheGameLogDigest.of(text: session(lines: count), name: CartoucheGameLogShare.names[index],
                                      created: Date(timeIntervalSince1970: 1_794_600_000 + Double(index) * -3_600),
                                      modified: Date(timeIntervalSince1970: 1_794_601_200 + Double(index) * -3_600))
        }
        return CartoucheGameLogShare(game: "Mario Kart World", titleId: "0400C3F00006E000",
                                     build: CartoucheGameBuild(version: "1.0.0", commit: "7bddb8c1e2f3", chain: "adec7d81d970"),
                                     what: what, environment: environment, logs: logs,
                                     date: Date(timeIntervalSince1970: 1_794_601_500))
    }

    func testTheSummarySaysWhatTheLogsHold() {
        let share = share(lines: [120, 40], what: "  Freezes at the second race  \n")
        let summary = share.summary
        XCTAssertTrue(summary.hasPrefix("Cartouche game log, " + CartoucheReport.timestamp(share.date)), summary)
        XCTAssertTrue(summary.contains("Game: Mario Kart World (0400C3F00006E000)"), summary)
        XCTAssertTrue(summary.contains("Build: 1.0.0, nxnative 7bddb8c1e2f3, shader chain adec7d81d970"), summary)
        XCTAssertTrue(summary.contains("What happened: Freezes at the second race\n"), summary)
        XCTAssertTrue(summary.contains("Cartouche: 0.12.1 (5ee6a80), LiveContainer 3.8.11, SideStore 0.7.0"), summary)
        XCTAssertTrue(summary.contains("Device: iPhone19,4 (A19 Pro, 12 GB)"), summary)
        XCTAssertTrue(summary.contains("Storage: games on SMB, saves on SMB"), summary)
        XCTAssertTrue(summary.contains("log.txt: the last session, " + CartoucheReport.timestamp(Date(timeIntervalSince1970: 1_794_600_000))),
                      summary)
        XCTAssertTrue(summary.contains("log.prev.txt: the session before"), summary)
        XCTAssertTrue(summary.contains(", 120 lines, "), summary)
        XCTAssertTrue(summary.contains("    Crash: [dm] CRASH sig=11 addr=0x10 pc=main+0x1a2b3c"), summary)
        XCTAssertTrue(summary.contains("    log.prev.txt: [RED] boot: Documents/romfs.img is not the image"), summary)
        // The zip's: the logs beside it are as the game wrote them.
        XCTAssertTrue(summary.hasSuffix("\n\n" + CartoucheGameLogShare.rawNote), summary)
    }

    func testWhatSendToCartoucheSendsIsCleaned() {
        let share = share(lines: [50, 30], what: "Freezes, my NAS is at 192.168.1.2\nsaves in /private/var/mobile/Library/Mobile Documents/Lou")
        // The zip's summary says what the player wrote as they wrote it.
        XCTAssertTrue(share.summary.contains("my NAS is at 192.168.1.2"), share.summary)
        let cleaned = share.cleaned()
        XCTAssertEqual(cleaned.words, "Freezes, my NAS is at <address>\nsaves in <path>")
        XCTAssertTrue(cleaned.summary.hasSuffix("\n\n" + CartoucheGameLogShare.cleanedNote), cleaned.summary)
        XCTAssertEqual(cleaned.cleaned().words, cleaned.words, "cleaned once")
        for text in [share.excerpt(limit: 50_000), cleaned.summary] {
            XCTAssertFalse(text.contains("192.168"), text)
            XCTAssertFalse(text.contains("/private/var"), text)
            XCTAssertFalse(text.contains(dataFolder), text)
            XCTAssertFalse(text.contains("6c6c6548206f6c6c"), text)
            XCTAssertTrue(text.contains("[dm] CRASH sig=11 addr=0x10 pc=main+0x1a2b3c"), text)
        }
        XCTAssertTrue(share.excerpt(limit: 50_000).contains("boot: game files <container>/Documents/Data/Application/<id>/"))
        // Facts are cleaned too, though a report's have nothing to take out.
        var withPath = share
        withPath.environment.facts.append(.init("Saves", "/private/var/mobile/Library/Mobile Documents/Lou"))
        XCTAssertTrue(withPath.cleaned().summary.contains("Saves: <path>"), withPath.cleaned().summary)
    }

    func testASummaryWithoutLog() {
        let share = CartoucheGameLogShare(game: "Pixel Quest", environment: environment, logs: [])
        XCTAssertTrue(share.summary.contains("Game: Pixel Quest\n"), share.summary)
        XCTAssertTrue(share.summary.hasSuffix("No log: the game has not written one yet."), share.summary)
        XCTAssertFalse(share.summary.contains("Build:"), share.summary)
    }

    func testShortLogsGoWhole() {
        let share = share(lines: [30, 20])
        let excerpt = share.excerpt(limit: 50_000)
        XCTAssertTrue(excerpt.hasPrefix(share.cleaned().summary), excerpt)
        XCTAssertTrue(excerpt.contains("--- log.txt, the last session"), excerpt)
        XCTAssertTrue(excerpt.contains("--- log.prev.txt, the session before"), excerpt)
        XCTAssertFalse(excerpt.contains("left out here"), excerpt)
        XCTAssertEqual(excerpt.components(separatedBy: "[dm] [nvn] frame interval up to frame").count - 1, 26 + 16)
    }

    func testLongLogsKeepTheirStartAndTheirEndWithinTheLimit() {
        let share = share(lines: [5_000, 3_000])
        for limit in [12_000, 30_000, 56_000] {
            let excerpt = share.excerpt(limit: limit)
            XCTAssertLessThanOrEqual(excerpt.utf8.count, limit)
            let parts = excerpt.components(separatedBy: "--- log.")
            XCTAssertEqual(parts.count, 3, "two logs, each with its heading")
            for part in parts.dropFirst() {
                // The start, how many lines went, and the end with the crash.
                XCTAssertTrue(part.contains("boot: game files <container>/"), String(part.prefix(400)))
                XCTAssertTrue(part.contains(" lines left out here. " + CartoucheGameLogShare.leftOutNote), String(part.prefix(400)))
                XCTAssertTrue(part.trimmingCharacters(in: .whitespacesAndNewlines)
                                .hasSuffix("[dm] *x1: <memory> main+0x40 0 <memory> 0x1 <memory>"), String(part.suffix(200)))
            }
            // The last session gets more of its lines.
            XCTAssertGreaterThan(parts[1].count, parts[2].count)
        }
    }

    func testOneLogTakesTheRoomTheOtherDoesNotNeed() {
        let share = share(lines: [5_000, 10])
        let excerpt = share.excerpt(limit: 40_000)
        XCTAssertLessThanOrEqual(excerpt.utf8.count, 40_000)
        XCTAssertGreaterThan(excerpt.utf8.count, 36_000)
        XCTAssertEqual(excerpt.components(separatedBy: "left out here").count - 1, 1)
    }

    func testWhatSendToCartoucheSendsFitsTheServer() throws {
        // Lines of quotes and accents, which JSON writes longer.
        var long = share(lines: [20_000, 20_000], what: String(repeating: "« Ça gèle » ", count: 2_000))
        long.logs[0].tail = long.logs[0].tail.map { $0 + " \"é\" \\ \t" }
        let submission = try XCTUnwrap(long.submission(id: "0f1e2d3c-4b5a-6978-8796-a5b4c3d2e1f0"))
        let json = try submission.json()
        XCTAssertLessThanOrEqual(json.count, CartoucheProblemReport.submissionLimit)
        XCTAssertGreaterThan(json.count, CartoucheProblemReport.submissionLimit * 8 / 10, "most of the room is used")
        XCTAssertLessThanOrEqual(submission.logs.utf16.count, 60_000)
        XCTAssertLessThanOrEqual(submission.what.utf16.count, CartoucheProblemReport.submissionWhatLimit)
        XCTAssertLessThanOrEqual(submission.title.utf16.count, 256)
        XCTAssertTrue(submission.logs.hasPrefix("Cartouche game log, "), String(submission.logs.prefix(80)))
        XCTAssertTrue(submission.logs.contains("[dm] CRASH sig=11"))
        XCTAssertFalse(submission.logs.contains("/private/var"))
        XCTAssertEqual(submission.device, "iPhone19,4 (A19 Pro, 12 GB)")
        XCTAssertEqual(submission.ios, "27.1 (25B72)")
        XCTAssertEqual(submission.version, "0.12.1 (5ee6a80)")
        // The server's own check of the fields (telemetry/worker.js).
        let fields = try XCTUnwrap(JSONSerialization.jsonObject(with: json) as? [String: Any])
        XCTAssertEqual(Set(fields.keys), ["schema", "id", "title", "what", "device", "ios", "version", "logs"])
    }

    func testTheIssuesTitle() {
        XCTAssertEqual(share(lines: [10]).title, "Mario Kart World log, Cartouche 0.12.1 on iPhone19,4, iOS 27.1")
        XCTAssertEqual(share(lines: [10], what: "\nFreezes at 192.168.1.2\nthen quits").title,
                       "Mario Kart World log: Freezes at <address>")
        let long = share(lines: [10], what: String(repeating: "🏎️", count: 200)).title
        XCTAssertTrue(long.hasSuffix("…"))
        XCTAssertLessThanOrEqual(long.utf16.count, 120)
    }

    func testTheZipsName() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let date = calendar.date(from: DateComponents(year: 2026, month: 11, day: 13, hour: 21, minute: 5))!
        XCTAssertEqual(CartoucheGameLogShare.fileName(game: "Mario Kart World", date: date),
                       "Mario Kart World log 2026-11-13 2105.zip")
        XCTAssertEqual(CartoucheGameLogShare.fileName(game: "Zelda: TotK / v1.2", date: date, word: "journal"),
                       "Zelda TotK v1.2 journal 2026-11-13 2105.zip")
        XCTAssertEqual(CartoucheGameLogShare.fileName(game: "..", date: date), "Game.. log 2026-11-13 2105.zip")
    }
}
