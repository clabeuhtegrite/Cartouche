//
//  HarnessStandardError.swift
//  CartoucheHarness
//
//  Where the harness's app writes its standard error: a file of its own,
//  never a pipe someone must read, as an app the player starts on an
//  iPhone writes it to /dev/null. As Xcode runs the app, os_log mirrors
//  every line, NSLog's included, to standard error, which Xcode reads; when
//  Xcode reads nothing of it for a while, as at the start of a run on a
//  busy Mac of the CI, the next line waits until it does. Logged from the
//  main thread, a line held it 19.8 s on 13 November, which a player's
//  iPhone never does, and the watchdog failed the test on Xcode, not on
//  Cartouche. harness.sh copies the file into its results (console.txt).
//

import Foundation

enum HarnessStandardError {
    /// The file standard error goes to, in the app's Library.
    static let file = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Logs", isDirectory: true)
        .appendingPathComponent("console.txt")

    private static var descriptor: Int32 = -1
    /// What Xcode gave the app as standard error, kept open, unwritten, so
    /// that Xcode never sees it closed.
    private static var xcodes: Int32 = -1

    /// Points standard error at the file, emptied, as the app starts for a
    /// run of the tests, before the launcher logs anything.
    static func start() {
        guard descriptor < 0 else { return }
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        descriptor = open(file.path, O_WRONLY | O_CREAT | O_TRUNC | O_APPEND, 0o644)
        guard descriptor >= 0 else { return }
        xcodes = dup(STDERR_FILENO)
        keep()
    }

    /// Points standard error at the file again, should anything have
    /// pointed it elsewhere since: before each test (HarnessCase).
    static func keep() {
        guard descriptor >= 0, !isTheFile(STDERR_FILENO) else { return }
        fflush(stderr)
        dup2(descriptor, STDERR_FILENO)
    }

    /// Whether OTHER, a file descriptor, is open on the file.
    static func isTheFile(_ other: Int32) -> Bool {
        var mine = stat()
        var theirs = stat()
        return descriptor >= 0 && fstat(descriptor, &mine) == 0 && fstat(other, &theirs) == 0
            && mine.st_dev == theirs.st_dev && mine.st_ino == theirs.st_ino
    }
}
