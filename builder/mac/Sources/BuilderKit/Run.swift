//
//  Run.swift
//  Cartouche Builder
//
//  Runs a program and collects what it writes, out of sight: the engine's
//  commands, Xcode's, Homebrew's. The lines of its error output can be
//  followed as they come, for the progress the app shows.
//

import Foundation

public struct RunResult: Sendable {
    public var status: Int32
    public var output: Data
    public var errors: Data
    public var timedOut: Bool

    public init(status: Int32, output: Data = Data(), errors: Data = Data(), timedOut: Bool = false) {
        self.status = status
        self.output = output
        self.errors = errors
        self.timedOut = timedOut
    }

    public var succeeded: Bool { status == 0 && !timedOut }
    public var text: String { String(decoding: output, as: UTF8.self) }
    public var errorText: String { String(decoding: errors, as: UTF8.self) }

    /// The last lines it wrote, error output first, for a message.
    public func tail(_ count: Int = 6) -> String {
        let source = errorText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? text : errorText
        let lines = source.split(whereSeparator: \.isNewline).map(String.init).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        return lines.suffix(count).joined(separator: "\n")
    }
}

public enum Run {
    /// Where programs are looked for: Homebrew's folders and the system's,
    /// since an app opened from the Finder has almost no PATH.
    public static let searchPath = ["/opt/homebrew/bin", "/opt/homebrew/sbin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"]

    /// This process's environment, with the PATH above, and EXTRA.
    public static func environment(_ extra: [String: String] = [:]) -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        var path = searchPath
        for part in (environment["PATH"] ?? "").split(separator: ":").map(String.init) where !part.isEmpty && !path.contains(part) {
            path.append(part)
        }
        environment["PATH"] = path.joined(separator: ":")
        environment["HOMEBREW_NO_ENV_HINTS"] = "1"
        for (key, value) in extra {
            environment[key] = value
        }
        return environment
    }

    /// The first of NAMES found in the PATH above, or nil.
    public static func which(_ names: String...) -> String? {
        for name in names {
            for folder in environment()["PATH", default: ""].split(separator: ":") {
                let path = "\(folder)/\(name)"
                if FileManager.default.isExecutableFile(atPath: path) { return path }
            }
        }
        return nil
    }

    /// Runs EXECUTABLE with ARGUMENTS and waits for it; LINE gets each line
    /// of its error output as it comes. It is stopped after TIMEOUT, or when
    /// the task is cancelled.
    public static func program(_ executable: String, _ arguments: [String] = [], environment: [String: String]? = nil,
                               directory: URL? = nil, timeout: TimeInterval? = nil,
                               line: (@Sendable (String) -> Void)? = nil) async throws -> RunResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = environment ?? Run.environment()
        if let directory { process.currentDirectoryURL = directory }
        let output = Pipe()
        let errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        process.standardInput = FileHandle.nullDevice
        let collected = Collected()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<RunResult, Error>) in
                let group = DispatchGroup()
                group.enter()
                DispatchQueue.global(qos: .utility).async {
                    collected.setOutput(output.fileHandleForReading.readDataToEndOfFile())
                    group.leave()
                }
                group.enter()
                DispatchQueue.global(qos: .utility).async {
                    let handle = errors.fileHandleForReading
                    var pending = Data()
                    while true {
                        let chunk = handle.availableData
                        if chunk.isEmpty { break }
                        collected.appendErrors(chunk)
                        guard let line else { continue }
                        pending.append(chunk)
                        while let end = pending.firstIndex(where: { $0 == 10 || $0 == 13 }) {
                            let text = String(decoding: pending[pending.startIndex..<end], as: UTF8.self)
                            pending.removeSubrange(pending.startIndex...end)
                            if !text.trimmingCharacters(in: .whitespaces).isEmpty { line(text) }
                        }
                    }
                    if let line, !pending.isEmpty { line(String(decoding: pending, as: UTF8.self)) }
                    group.leave()
                }
                do {
                    try process.run()
                } catch {
                    try? output.fileHandleForWriting.close()
                    try? errors.fileHandleForWriting.close()
                    continuation.resume(throwing: error)
                    return
                }
                collected.started(process)
                if let timeout {
                    DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                        collected.stop(timedOut: true)
                    }
                }
                group.notify(queue: .global(qos: .utility)) {
                    process.waitUntilExit()
                    continuation.resume(returning: collected.result(status: process.terminationStatus))
                }
            }
        } onCancel: {
            collected.stop(timedOut: false)
        }
    }
}

/// What a running program wrote, from the threads reading it.
private final class Collected: @unchecked Sendable {
    private let lock = NSLock()
    private var output = Data()
    private var errors = Data()
    private var process: Process?
    private var timedOut = false
    private var stopAsked = false

    func setOutput(_ data: Data) {
        lock.lock()
        output = data
        lock.unlock()
    }

    func appendErrors(_ data: Data) {
        lock.lock()
        errors.append(data)
        lock.unlock()
    }

    func started(_ process: Process) {
        lock.lock()
        self.process = process
        let stop = stopAsked
        lock.unlock()
        if stop, process.isRunning { process.terminate() }
    }

    func stop(timedOut: Bool) {
        lock.lock()
        stopAsked = true
        let process = self.process
        if timedOut, process?.isRunning == true { self.timedOut = true }
        lock.unlock()
        if let process, process.isRunning { process.terminate() }
    }

    func result(status: Int32) -> RunResult {
        lock.lock()
        defer { lock.unlock() }
        return RunResult(status: status, output: output, errors: errors, timedOut: timedOut)
    }
}
