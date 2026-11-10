//
//  MacSetup.swift
//  Cartouche Builder
//
//  Readies this Mac for nxnative without a Terminal: what a build needs,
//  checked one by one, and fetched or installed by the app. macOS asks only
//  what it must: Xcode comes from the App Store, Homebrew from its signed
//  installer, and the player's password once, for Xcode's licence. The
//  rest runs out of sight: Xcode's iOS platform and Metal toolchain,
//  Homebrew's tools, nxnative and its Python environment (the engine's
//  `api setup`).
//

import AppKit
import Darwin
import Foundation

public enum SetupItem: String, CaseIterable, Identifiable, Sendable {
    case mac, xcode, xcodeReady, iosPlatform, metal, homebrew, tools, nxnative

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .mac: return tr("This Mac", "Ce Mac")
        case .xcode: return "Xcode"
        case .xcodeReady: return tr("Xcode’s first launch", "Premier lancement de Xcode")
        case .iosPlatform: return tr("Xcode’s iOS platform", "Plateforme iOS de Xcode")
        case .metal: return tr("Metal toolchain", "Metal toolchain")
        case .homebrew: return "Homebrew"
        case .tools: return tr("nxnative’s tools", "Outils de nxnative")
        case .nxnative: return "nxnative"
        }
    }

    public var explanation: String {
        switch self {
        case .mac: return tr("macOS 26.6 or later, on Apple silicon.", "macOS 26.6 ou ultérieur, puce Apple.")
        case .xcode: return tr("Apple’s free developer app, which builds iPhone apps.", "L’app gratuite d’Apple qui construit les apps d’iPhone.")
        case .xcodeReady: return tr("Its licence agreed and its parts installed: your Mac’s password, once.",
                                    "Sa licence acceptée et ses éléments installés : le mot de passe du Mac, une fois.")
        case .iosPlatform: return tr("What Xcode builds iPhone apps with, a few gigabytes.", "Ce avec quoi Xcode construit les apps d’iPhone, quelques gigaoctets.")
        case .metal: return tr("Compiles the games’ shaders for the iPhone.", "Compile les shaders des jeux pour l’iPhone.")
        case .homebrew: return tr("Installs the free tools below. macOS asks your password in its installer.",
                                  "Installe les outils gratuits ci-dessous. macOS demande votre mot de passe dans son installeur.")
        case .tools: return tr("Python, xcodegen, zstd and glslang, from Homebrew.", "Python, xcodegen, zstd et glslang, depuis Homebrew.")
        case .nxnative: return tr("The project that makes the games native, and its Python environment.",
                                  "Le projet qui rend les jeux natifs, et son environnement Python.")
        }
    }

    public var symbol: String {
        switch self {
        case .mac: return "laptopcomputer"
        case .xcode: return "hammer"
        case .xcodeReady: return "checkmark.seal"
        case .iosPlatform: return "iphone"
        case .metal: return "cube.transparent"
        case .homebrew: return "mug"
        case .tools: return "wrench.and.screwdriver"
        case .nxnative: return "shippingbox"
        }
    }
}

public enum SetupState: Equatable, Sendable {
    case checking
    /// What is there.
    case ready(String)
    /// What is missing, and what the button does.
    case missing(String)
    /// What runs now, and how far it is, when known.
    case working(String, Double?)
    /// What the player does now: in the App Store, in the installer.
    case waiting(String)
    case failed(String)
    /// Needs an item above first.
    case blocked

    public var isReady: Bool {
        if case .ready = self { return true }
        return false
    }

    public var isBusy: Bool {
        switch self {
        case .checking, .working, .waiting: return true
        default: return false
        }
    }
}

@MainActor
public final class MacSetup: ObservableObject {
    /// The Xcode nxnative's shaders are locked with.
    public nonisolated static let xcodeVersion = "27.2"
    public static let xcodeStore = URL(string: "macappstore://apps.apple.com/app/xcode/id497799835")!
    public static let softwareUpdate = URL(string: "x-apple.systempreferences:com.apple.Software-Update-Settings.extension")!
    static let brew = "/opt/homebrew/bin/brew"
    /// Homebrew's formula of each tool nxnative runs.
    nonisolated static let formulae = [("xcodegen", "xcodegen"), ("zstd", "zstd"), ("glslangValidator", "glslang")]

    @Published public private(set) var states: [SetupItem: SetupState] = [:]
    @Published public private(set) var log: [String] = []
    @Published public private(set) var running = false
    @Published public private(set) var python: URL?
    @Published public private(set) var xcode: String?
    /// The engine, once there is a Python to run it.
    public var makeEngine: (URL) -> Engine? = { _ in nil }
    /// Called when everything is ready.
    public var onReady: () -> Void = {}
    /// Called after each step the app took: the item, how it ended (ready,
    /// waiting, cancelled, failed, missing) and how long it took.
    public var onStep: ((SetupItem, String, TimeInterval) -> Void)?

    private var work: Task<Void, Never>?
    /// Shows sample states and checks nothing: the gallery's pictures.
    private var previewing = false

    public init() {
        for item in SetupItem.allCases { states[item] = .checking }
    }

    /// Shows STATES, as they would be, and checks nothing after: for the
    /// gallery's pictures.
    public func preview(_ states: [SetupItem: SetupState], xcode: String? = nil) {
        previewing = true
        for item in SetupItem.allCases { self.states[item] = states[item] ?? .ready("") }
        self.xcode = xcode
    }

    public func state(_ item: SetupItem) -> SetupState {
        states[item] ?? .checking
    }

    public var ready: Bool { SetupItem.allCases.allSatisfy { state($0).isReady } }
    public var missingCount: Int { SetupItem.allCases.filter { !state($0).isReady }.count }

    // MARK: Checks

    /// Checks every item, in order: one that needs another waits for it.
    public func refresh() async {
        guard !previewing else { return }
        let wasReady = ready
        var blocked = false
        for item in SetupItem.allCases {
            if blocked {
                states[item] = .blocked
                continue
            }
            if !state(item).isBusy || state(item) == .checking {
                states[item] = await check(item)
            }
            if !state(item).isReady && item.blocksTheRest { blocked = true }
        }
        if ready && !wasReady { onReady() }
    }

    func check(_ item: SetupItem) async -> SetupState {
        switch item {
        case .mac:
            let version = ProcessInfo.processInfo.operatingSystemVersion
            let text = "macOS \(version.majorVersion).\(version.minorVersion)" + (version.patchVersion > 0 ? ".\(version.patchVersion)" : "")
            guard MacSetup.sysctl("hw.optional.arm64") == 1 else {
                return .failed(tr("nxnative builds on a Mac with Apple silicon (M1 or later).", "nxnative construit sur un Mac à puce Apple (M1 ou plus récent)."))
            }
            guard version.majorVersion > 26 || (version.majorVersion == 26 && version.minorVersion >= 6) else {
                return .missing(tr("\(text): nxnative needs macOS 26.6 or later.", "\(text) : nxnative demande macOS 26.6 ou ultérieur."))
            }
            return .ready(text + tr(", Apple silicon", ", puce Apple"))
        case .xcode:
            guard let found = MacSetup.findXcode() else {
                xcode = nil
                return .missing(tr("Not installed yet.", "Pas encore installé."))
            }
            xcode = found.path
            return .ready("Xcode \(found.version)")
        case .xcodeReady:
            guard let xcode else { return .blocked }
            let selected = (try? await Run.program("/usr/bin/xcode-select", ["-p"], timeout: 30))?.text.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard selected.hasPrefix(xcode) else {
                return .missing(tr("Xcode is installed but not chosen for builds yet.", "Xcode est installé mais pas encore choisi pour construire."))
            }
            let launched = try? await Run.program("/usr/bin/xcodebuild", ["-checkFirstLaunchStatus"], timeout: 60)
            let licence = try? await Run.program("/usr/bin/xcodebuild", ["-license", "check"], timeout: 60)
            guard launched?.succeeded == true, licence?.succeeded == true else {
                return .missing(tr("Its licence is to agree to, once.", "Sa licence est à accepter, une fois."))
            }
            return .ready(tr("Licence agreed", "Licence acceptée"))
        case .iosPlatform:
            guard let result = try? await Run.program("/usr/bin/xcrun", ["--sdk", "iphoneos", "--show-sdk-version"], timeout: 120), result.succeeded,
                  let version = result.text.split(whereSeparator: \.isNewline).last.map(String.init), !version.isEmpty else {
                return .missing(tr("To download, a few gigabytes.", "À télécharger, quelques gigaoctets."))
            }
            return .ready("iOS \(version)")
        case .metal:
            guard let result = try? await Run.program("/usr/bin/xcrun", ["-sdk", "iphoneos", "metal", "--version"], timeout: 120), result.succeeded,
                  let first = result.text.split(whereSeparator: \.isNewline).first.map(String.init) else {
                return .missing(tr("To download.", "À télécharger."))
            }
            return .ready(MacSetup.shortMetal(first))
        case .homebrew:
            guard FileManager.default.isExecutableFile(atPath: MacSetup.brew) else {
                return .missing(tr("Not installed yet.", "Pas encore installé."))
            }
            return .ready(tr("Installed", "Installé"))
        case .tools:
            let missing = MacSetup.missingFormulae()
            python = await PythonFinder.find()
            var wanted = missing.map(\.1)
            if python == nil { wanted.insert("python@3.13", at: 0) }
            guard wanted.isEmpty else {
                return .missing(tr("To install: ", "À installer : ") + wanted.joined(separator: ", ") + ".")
            }
            var version = "3"
            if let python, let found = await PythonFinder.version(python.path) { version = found }
            return .ready("Python \(version), xcodegen, zstd, glslang")
        case .nxnative:
            guard let python, let engine = makeEngine(python) else { return .blocked }
            do {
                let doctor = try await engine.doctor()
                let venv = doctor.checks.first { $0.key == "venv" }
                guard doctor.engine == true, venv?.ok ?? false else {
                    return .missing(tr("To download, with its Python environment.", "À télécharger, avec son environnement Python."))
                }
                if let blocking = doctor.checks.first(where: { !$0.ok && $0.blocking }) {
                    return .failed("\(blocking.label) : \(blocking.fix)")
                }
                return .ready(tr("Downloaded, environment ready", "Téléchargé, environnement prêt"))
            } catch {
                return .failed(error.localizedDescription)
            }
        }
    }

    // MARK: Fixes

    /// Readies everything, item after item, waiting for the player where
    /// macOS needs them.
    public func fixAll() {
        guard work == nil else { return }
        work = Task { [weak self] in
            guard let self else { return }
            self.running = true
            defer {
                self.running = false
                self.work = nil
            }
            await self.refresh()
            for item in SetupItem.allCases {
                if Task.isCancelled { return }
                if self.state(item).isReady { continue }
                guard await self.step(item) else { return }
            }
            await self.refresh()
        }
    }

    public func fixOne(_ item: SetupItem) {
        guard work == nil else { return }
        work = Task { [weak self] in
            guard let self else { return }
            self.running = true
            defer {
                self.running = false
                self.work = nil
            }
            _ = await self.step(item)
            await self.refresh()
        }
    }

    /// Fixes ITEM, and says how it went.
    private func step(_ item: SetupItem) async -> Bool {
        let started = Date()
        let done = await fix(item)
        let outcome: String
        switch state(item) {
        case .ready: outcome = "ready"
        case .waiting: outcome = "waiting"
        case .failed: outcome = "failed"
        case .missing(let text): outcome = text.hasPrefix(tr("Cancelled", "Annulé")) ? "cancelled" : "missing"
        default: outcome = Task.isCancelled ? "cancelled" : "missing"
        }
        onStep?(item, outcome, Date().timeIntervalSince(started))
        return done
    }

    public func cancel() {
        work?.cancel()
    }

    /// Fixes ITEM; false when it is not ready after.
    func fix(_ item: SetupItem) async -> Bool {
        say("— \(item.title)")
        switch item {
        case .mac:
            NSWorkspace.shared.open(MacSetup.softwareUpdate)
            states[item] = .waiting(tr("Update macOS in System Settings, then come back here.", "Mettez macOS à jour dans Réglages Système, puis revenez ici."))
            return false
        case .xcode:
            NSWorkspace.shared.open(MacSetup.xcodeStore)
            states[item] = .waiting(tr("Install Xcode from the App Store: Cartouche Builder goes on by itself once it is there.",
                                       "Installez Xcode depuis l’App Store : Cartouche Builder continue tout seul une fois qu’il est là."))
            return await wait(for: item, every: 15)
        case .xcodeReady:
            guard let xcode else { return false }
            states[item] = .working(tr("macOS asks your password…", "macOS demande votre mot de passe…"), nil)
            let developer = "\(xcode)/Contents/Developer"
            let tool = "\(developer)/usr/bin/xcodebuild"
            let command = "/usr/bin/xcode-select -s \(MacSetup.quoted(developer)) && \(MacSetup.quoted(tool)) -license accept && \(MacSetup.quoted(tool)) -runFirstLaunch"
            let result = await administrator(command, prompt: tr("Cartouche Builder readies Xcode to build your games.", "Cartouche Builder prépare Xcode pour construire vos jeux."))
            return await finish(item, result)
        case .iosPlatform:
            return await runStep(item, "/usr/bin/xcodebuild", ["-downloadPlatform", "iOS"], working: tr("Downloading the iOS platform…", "Téléchargement de la plateforme iOS…"))
        case .metal:
            return await runStep(item, "/usr/bin/xcodebuild", ["-downloadComponent", "MetalToolchain"], working: tr("Downloading the Metal toolchain…", "Téléchargement de la Metal toolchain…"))
        case .homebrew:
            states[item] = .working(tr("Downloading Homebrew’s installer…", "Téléchargement de l’installeur de Homebrew…"), nil)
            do {
                let package = try await MacSetup.downloadHomebrew()
                say(package.lastPathComponent)
                NSWorkspace.shared.open(package)
                states[item] = .waiting(tr("Follow Homebrew’s installer: Cartouche Builder goes on by itself after.",
                                           "Suivez l’installeur de Homebrew : Cartouche Builder continue tout seul après."))
                return await wait(for: item, every: 5)
            } catch {
                states[item] = .failed(error.localizedDescription)
                say(error.localizedDescription)
                return false
            }
        case .tools:
            var formulae = MacSetup.missingFormulae().map(\.1)
            if await PythonFinder.find() == nil { formulae.insert("python@3.13", at: 0) }
            guard !formulae.isEmpty else { return true }
            return await runStep(item, MacSetup.brew, ["install"] + formulae,
                                 working: tr("Installing ", "Installation de ") + formulae.joined(separator: ", ") + "…")
        case .nxnative:
            guard let python = await PythonFinder.find(), let engine = makeEngine(python) else { return false }
            self.python = python
            states[item] = .working(tr("Downloading nxnative…", "Téléchargement de nxnative…"), nil)
            do {
                _ = try await engine.setup { [weak self] line in
                    Task { @MainActor in
                        self?.say(line)
                        self?.states[.nxnative] = .working(line, nil)
                    }
                }
                states[item] = await check(item)
                return state(item).isReady
            } catch {
                states[item] = .failed(error.localizedDescription)
                say(error.localizedDescription)
                return false
            }
        }
    }

    /// Runs a step's command, its progress from the percentages it writes.
    private func runStep(_ item: SetupItem, _ program: String, _ arguments: [String], working: String) async -> Bool {
        states[item] = .working(working, nil)
        let result = try? await Run.program(program, arguments, timeout: 4 * 3600) { [weak self] line in
            let fraction = MacSetup.percentage(in: line)
            Task { @MainActor in
                guard let self else { return }
                self.say(line)
                if let fraction { self.states[item] = .working(working, fraction) }
            }
        }
        if let result, !result.text.isEmpty {
            for line in result.text.split(whereSeparator: \.isNewline).suffix(20) { say(String(line)) }
        }
        return await finish(item, result)
    }

    private func finish(_ item: SetupItem, _ result: RunResult?) async -> Bool {
        let after = await check(item)
        states[item] = after
        if after.isReady { return true }
        if let result, !result.succeeded {
            let tail = result.tail(3)
            if tail.contains("-128") || tail.localizedCaseInsensitiveContains("User canceled") {
                states[item] = .missing(tr("Cancelled: the button starts again.", "Annulé : le bouton recommence."))
            } else {
                states[item] = .failed(tail.isEmpty ? tr("It did not work.", "Ça n’a pas marché.") : tail)
            }
        }
        return false
    }

    /// Checks ITEM every SECONDS until it is ready, or the work is cancelled.
    private func wait(for item: SetupItem, every seconds: Double) async -> Bool {
        let waiting = state(item)
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            let now = await check(item)
            if now.isReady {
                states[item] = now
                return true
            }
            states[item] = waiting
        }
        states[item] = await check(item)
        return false
    }

    /// Runs COMMAND as the Mac's administrator, macOS asking the password with PROMPT.
    private func administrator(_ command: String, prompt: String) async -> RunResult? {
        let script = "do shell script \"\(MacSetup.escaped(command))\" with prompt \"\(MacSetup.escaped(prompt))\" with administrator privileges"
        say("sudo: \(command)")
        return try? await Run.program("/usr/bin/osascript", ["-e", script], timeout: 3600)
    }

    func say(_ line: String) {
        log.append(line)
        if log.count > 800 { log.removeFirst(log.count - 800) }
    }

    // MARK: Helpers

    nonisolated static func sysctl(_ name: String) -> Int {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname(name, &value, &size, nil, 0) == 0 else { return 0 }
        return Int(value)
    }

    /// The Xcode to build with: the one chosen for the Mac, else the
    /// version nxnative wants, else the newest.
    nonisolated static func findXcode() -> (path: String, version: String)? {
        var found: [(path: String, version: String)] = []
        let applications = (try? FileManager.default.contentsOfDirectory(atPath: "/Applications")) ?? []
        for name in applications where name.hasPrefix("Xcode") && name.hasSuffix(".app") {
            let path = "/Applications/\(name)"
            guard let info = NSDictionary(contentsOfFile: path + "/Contents/Info.plist"),
                  let version = info["CFBundleShortVersionString"] as? String,
                  FileManager.default.fileExists(atPath: path + "/Contents/Developer") else { continue }
            found.append((path, version))
        }
        let link = (try? FileManager.default.destinationOfSymbolicLink(atPath: "/var/db/xcode_select_link")) ?? ""
        if let chosen = found.first(where: { !link.isEmpty && link.hasPrefix($0.path) }) { return chosen }
        if let wanted = found.first(where: { $0.version == xcodeVersion }) { return wanted }
        return found.max { $0.version.compare($1.version, options: .numeric) == .orderedAscending }
    }

    nonisolated static func missingFormulae() -> [(String, String)] {
        formulae.filter { tool, _ in Run.which(tool) == nil }
    }

    /// "Apple metal version 32023.404" → "metal 32023.404".
    nonisolated static func shortMetal(_ line: String) -> String {
        if let range = line.range(of: "version "), let number = line[range.upperBound...].split(separator: " ").first {
            return "Metal \(number)"
        }
        return line
    }

    /// "45.3%" in LINE, as 0.453.
    nonisolated static func percentage(in line: String) -> Double? {
        guard let match = line.range(of: #"(\d{1,3}(?:\.\d+)?)\s?%"#, options: .regularExpression) else { return nil }
        let number = line[match].filter { $0.isNumber || $0 == "." }
        guard let value = Double(number), value >= 0, value <= 100 else { return nil }
        return value / 100
    }

    nonisolated static func quoted(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    nonisolated static func escaped(_ text: String) -> String {
        text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }

    /// Homebrew's installer, the newest from its releases, checked by
    /// Gatekeeper before it is opened.
    nonisolated static func downloadHomebrew() async throws -> URL {
        struct Release: Decodable {
            struct Asset: Decodable {
                var name: String
                var browser_download_url: String
            }
            var assets: [Asset]
        }
        var request = URLRequest(url: URL(string: "https://api.github.com/repos/Homebrew/brew/releases/latest")!)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 30
        let (data, _) = try await URLSession.shared.data(for: request)
        let release = try JSONDecoder().decode(Release.self, from: data)
        guard let asset = release.assets.first(where: { $0.name.hasSuffix(".pkg") }), let url = URL(string: asset.browser_download_url),
              url.host == "github.com" || url.host?.hasSuffix(".githubusercontent.com") == true else {
            throw SetupError(tr("Homebrew’s installer was not found.", "L’installeur de Homebrew est introuvable."))
        }
        let (downloaded, _) = try await URLSession.shared.download(from: url)
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("Cartouche Builder", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let package = folder.appendingPathComponent(asset.name.replacingOccurrences(of: "/", with: "_"))
        try? FileManager.default.removeItem(at: package)
        try FileManager.default.moveItem(at: downloaded, to: package)
        let assessed = try await Run.program("/usr/sbin/spctl", ["--assess", "--type", "install", package.path], timeout: 120)
        guard assessed.succeeded else {
            throw SetupError(tr("macOS did not accept Homebrew’s installer: ", "macOS n’a pas accepté l’installeur de Homebrew : ") + assessed.tail(2))
        }
        return package
    }
}

public struct SetupError: LocalizedError {
    public var message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

extension SetupItem {
    /// Whether nothing after it can be checked until it is ready.
    var blocksTheRest: Bool {
        switch self {
        case .mac, .xcode, .xcodeReady, .homebrew: return true
        case .iosPlatform, .metal: return false
        case .tools: return true
        case .nxnative: return false
        }
    }
}
