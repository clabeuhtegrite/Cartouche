//
//  CartouchePython.swift
//  Cartouche
//
//  CPython for iOS inside Cartouche, for the lab (spike S2,
//  engine/spikes/s2). app/scripts/package.sh puts it in the app, and nothing
//  loads it until the lab runs a job. Python then runs on a thread of its own
//  until Cartouche quits: it starts once and never stops, since its extension
//  modules do not survive a restart of the interpreter. That thread is
//  Python's main thread, the only one where a script may set a signal
//  handler, as nxnative's rewriter does.
//

import Darwin
import Foundation

final class CartouchePython {
    static let shared = CartouchePython()

    enum Failure: LocalizedError {
        case notBundled
        case cannotLoad(String)

        var errorDescription: String? {
            switch self {
            case .notBundled: return CartoucheText.labNoPython
            case .cannotLoad(let reason): return CartoucheText.labPythonFailed(reason)
            }
        }
    }

    /// Python's standard library (lib) and the lab's code (app), in the app.
    static var home: URL { Bundle.main.bundleURL.appendingPathComponent("python", isDirectory: true) }
    static var frameworks: URL { Bundle.main.bundleURL.appendingPathComponent("Frameworks", isDirectory: true) }
    static var library: URL { frameworks.appendingPathComponent("Python.framework/Python") }

    /// Whether this build of Cartouche carries Python and the lab's code.
    static var isBundled: Bool {
        FileManager.default.fileExists(atPath: library.path)
            && FileManager.default.fileExists(atPath: home.appendingPathComponent("app/cartouche_s2/phone.py").path)
    }

    /// The versions of Python and of nxnative's rewriter this build carries.
    static var version: String? { Bundle.main.object(forInfoDictionaryKey: "CartouchePythonVersion") as? String }
    static var nxnativeCommit: String? { Bundle.main.object(forInfoDictionaryKey: "CartoucheNxnativeCommit") as? String }

    // PyRun_SimpleStringFlags(const char *command, PyCompilerFlags *flags)
    private typealias RunString = @convention(c) (UnsafePointer<CChar>, UnsafeMutableRawPointer?) -> Int32
    // Py_InitializeEx(int initsigs)
    private typealias InitializeEx = @convention(c) (Int32) -> Void

    private let condition = NSCondition()
    private var jobs: [() -> Void] = []
    private var thread: Thread?
    // Read and written on Python's thread only.
    private var runString: RunString?
    private var startFailure: Failure?

    /// Runs Python source on Python's thread, after starting Python the first
    /// time, and returns once it has run: PyRun_SimpleString's result, 0, or
    /// -1 when the source raised an exception.
    func run(_ source: String) async throws -> Int32 {
        try await withCheckedThrowingContinuation { continuation in
            enqueue {
                do {
                    let run = try self.started()
                    let result = source.withCString { run($0, nil) }
                    continuation.resume(returning: result)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private func enqueue(_ job: @escaping () -> Void) {
        condition.lock()
        jobs.append(job)
        if thread == nil {
            let thread = Thread { [unowned self] in self.serve() }
            thread.name = "Cartouche Python"
            // Python's C code recurses deeper than the 512 KB a secondary
            // thread gets by default.
            thread.stackSize = 16 << 20
            thread.qualityOfService = .userInitiated
            self.thread = thread
            thread.start()
        }
        condition.signal()
        condition.unlock()
    }

    private func serve() {
        while true {
            condition.lock()
            while jobs.isEmpty {
                condition.wait()
            }
            let job = jobs.removeFirst()
            condition.unlock()
            job()
        }
    }

    private func started() throws -> RunString {
        if let runString { return runString }
        if let startFailure { throw startFailure }
        do {
            let run = try start()
            runString = run
            return run
        } catch let failure as Failure {
            startFailure = failure
            throw failure
        }
    }

    /// Loads Python and starts it on this thread. Py_InitializeEx reads where
    /// Python is from the environment: PYTHONHOME for the standard library,
    /// PYTHONPATH for the lab's code, and PYTHONEXECUTABLE for sys.executable,
    /// beside which Python finds the frameworks of its extension modules.
    private func start() throws -> RunString {
        guard Self.isBundled else { throw Failure.notBundled }
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let environment = [
            "PYTHONHOME": Self.home.path,
            "PYTHONPATH": Self.home.appendingPathComponent("app", isDirectory: true).path,
            "PYTHONEXECUTABLE": Bundle.main.executablePath ?? Bundle.main.bundlePath,
            "PYTHONNOUSERSITE": "1",
            "PYTHONUTF8": "1",
            "PYTHONUNBUFFERED": "1",
            // The app's files cannot change: Python keeps what it compiles here.
            "PYTHONPYCACHEPREFIX": caches.appendingPathComponent("Python", isDirectory: true).path,
        ]
        for (name, value) in environment {
            setenv(name, value, 1)
        }
        guard let handle = dlopen(Self.library.path, RTLD_NOW | RTLD_GLOBAL) else {
            throw Failure.cannotLoad(dlerror().map { String(cString: $0) } ?? Self.library.path)
        }
        guard let initialize = dlsym(handle, "Py_InitializeEx"),
              let run = dlsym(handle, "PyRun_SimpleStringFlags") else {
            throw Failure.cannotLoad("Py_InitializeEx, PyRun_SimpleStringFlags")
        }
        // 0: Python installs no signal handlers; the app keeps its own.
        unsafeBitCast(initialize, to: InitializeEx.self)(0)
        return unsafeBitCast(run, to: RunString.self)
    }
}
