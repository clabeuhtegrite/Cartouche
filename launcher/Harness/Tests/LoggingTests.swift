//
//  LoggingTests.swift
//  CartoucheHarnessTests
//
//  What Cartouche writes to its standard error, NSLog and os_log as Xcode
//  runs it, never waits there for someone to read it, as on an iPhone,
//  where an app the player starts writes it to /dev/null: the watchdog
//  then watches Cartouche, not Xcode.
//

import Foundation
import XCTest
@testable import CartoucheHarness

final class LoggingTests: HarnessCase {
    /// On 13 November, Xcode read nothing of the app's standard error for
    /// some 25 s at the start of two runs of the harness, and the line the
    /// launcher logs as a start behind the console fails held the main
    /// thread 19.8 s and 2.5 s, the test failing on Xcode, not on Cartouche.
    func testWhatCartoucheLogsNeverWaitsForXcodeToReadIt() throws {
        var info = stat()
        XCTAssertEqual(fstat(STDERR_FILENO, &info), 0, "standard error is open")
        let kind = info.st_mode & S_IFMT
        XCTAssertEqual(kind, S_IFREG, "standard error is a file, not \(Self.name(of: kind)), which waits until Xcode reads it")
        XCTAssertTrue(HarnessStandardError.isTheFile(STDERR_FILENO), "standard error is the harness's own file")
        // What is written there is kept, for harness.sh's console.txt.
        let line = "harness: a line on standard error, \(UUID().uuidString)"
        fputs(line + "\n", stderr)
        let written = try String(contentsOf: HarnessStandardError.file, encoding: .utf8)
        XCTAssertTrue(written.contains(line), "the line is in \(HarnessStandardError.file.lastPathComponent)")
    }

    private static func name(of kind: mode_t) -> String {
        switch kind {
        case S_IFIFO: return "a pipe"
        case S_IFCHR: return "a terminal"
        case S_IFSOCK: return "a socket"
        default: return "a file of kind 0o" + String(kind, radix: 8)
        }
    }
}
