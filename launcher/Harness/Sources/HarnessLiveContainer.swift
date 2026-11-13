//
//  HarnessLiveContainer.swift
//  CartoucheHarness
//
//  LiveContainer as the harness stands it in under the launcher's own code
//  (launcher/Sources), and under the files of LiveContainer it builds as
//  they are, with Cartouche's patches: LCAppModel.swift, LCContainer.swift,
//  unarchive.m and the texts of Localizable.xcstrings (harness.sh copies
//  them from app/LiveContainer). What stands in here follows LiveContainer
//  line for line where the launcher reads or writes what it leaves: its
//  folders (Shared.swift), an app's Info.plist and LCAppInfo.plist
//  (LCAppInfo.m, in HarnessAppInfo.swift), its preferences, the app list it
//  reads as it starts (LiveContainerSwiftUIApp.swift) and where it keeps
//  its certificate (LCUtils.m, LCSharedUtils.m). What the Simulator cannot
//  do, the harness does its own way and records for the tests: signing
//  with zsign, the start of a game in Cartouche's place (which quits the
//  app), and the game's own process behind the console
//  (HarnessScenes.swift).
//

import Combine
import Foundation
import Security
import SwiftUI
import UIKit
import UniformTypeIdentifiers

// MARK: What the tests set and read

/// The harness's LiveContainer: what it does next, which the tests set, and
/// what it did, which they read. Reset before each test (HarnessCase).
enum HarnessLC {
    /// How zsign signs the next apps.
    enum Signing: Equatable {
        /// Signed, with the installed certificate.
        case signs
        /// zsign fails with this message.
        case fails(String)
        /// Signed, but zsign could not sign some files, which it names.
        case signsPartly(String)
    }

    /// A start of a game in Cartouche's place: LiveContainer quits Cartouche
    /// and opens the game (LCSharedUtils launchToGuestAppWithClassicMode:).
    struct Launch: Equatable {
        /// UserDefaults "selected": the app's folder in Applications.
        var bundle: String?
        /// UserDefaults "selectedContainer": its data folder.
        var container: String?
        var classicMode: UInt
    }

    /// How the next game behind the console fares (HarnessScenes.swift).
    enum GameStart: Equatable {
        /// Its process starts, and its scene shows.
        case starts
        /// LiveContainer's LiveProcess extension is not there.
        case noExtension
        /// The extension refuses the request.
        case refused
        /// The process crashes as it starts.
        case crashes
    }

    static var signing: Signing = .signs
    /// How long zsign takes.
    static var signingTime: TimeInterval = 0.05
    /// iOS no longer runs what the installed certificate signs: Apple
    /// revoked it.
    static var iOSRefusesCertificate = false
    /// Whether the iPhone's GPU reads BC-compressed textures, which nxnative
    /// needs: the A17 Pro's and later do (CartoucheDevice).
    static var readsBCTextures = true
    /// The bundles zsign signed, in order.
    static var signed: [String] = []
    static var launches: [Launch] = []
    /// The data folders whose keychain items LiveContainer removed.
    static var removedKeychains: [String] = []
    /// Whether LiveContainer runs games in its multitasking windows now.
    static var multitasking = false
    /// LiveContainer's own URL scheme, which brand.py makes Cartouche's:
    /// "cartouche" for the primary copy of the app, which manages the apps
    /// (SharedModel.multiLCStatus).
    static var appURLScheme = "cartouche"
    static var nextGameStart: GameStart = .starts
    /// Whether the game's process ends as Cartouche stops it, or only once
    /// it is killed three seconds later (AppSceneViewController terminate).
    static var gameEndsOnTerminate = true
    /// Whether LiveContainer's extension says when the game's process has
    /// ended, which ends its scene.
    static var extensionReportsExit = true
    /// Whether LiveContainer opens a scene of the game's process on a TV
    /// (app/patches/livecontainer/0012): not on an iOS without the scene
    /// it opens there.
    static var gamesHaveATVScene = true
    /// Whether a display shows a copy of the iPhone's screen: a TV, by
    /// cable or AirPlay, that iOS has not handed Cartouche
    /// (CartoucheGameHost.iPhoneIsMirrored).
    static var iPhoneMirrored = false
    /// The way the screen of a game behind the console is turned, and the
    /// way the screen would turn for the device as it is held, as a test
    /// sets them (CartoucheGameScreen.followTurns): the Simulator's own
    /// when nil, which a test cannot turn.
    static var screenTurned: CartoucheGameOrientations?
    static var deviceHeld: CartoucheGameOrientations?

    static let appGroupID = "group.io.github.clabeuhtegrite.cartouche.harness"

    /// The built-in SideStore's app group, which LiveContainer borrows: a
    /// folder of the harness's own, as the Simulator gives the harness no
    /// app group.
    static let appGroup: URL = {
        let library = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
        return library.appendingPathComponent("HarnessAppGroup", isDirectory: true)
    }()

    /// Sets up what LiveContainer sets up as it starts: LC_HOME_PATH, which
    /// its bootstrap sets to the app's home, and its folders, apps and data
    /// folders.
    static func start() {
        setenv("LC_HOME_PATH", NSHomeDirectory(), 0)
        try? FileManager.default.createDirectory(at: appGroup, withIntermediateDirectories: true)
        installLiveProcess()
        HarnessNetwork.install()
        loadApps()
    }

    /// LiveContainer's LiveProcess extension, where Cartouche looks for it
    /// (CartoucheGameKeeping.isAvailable): its Info.plist, in the app's
    /// PlugIns, which the Simulator lets the app write. The harness's
    /// AppSceneViewController stands in for what it runs.
    private static func installLiveProcess() {
        guard let plugins = Bundle.main.builtInPlugInsURL else { return }
        let appex = plugins.appendingPathComponent("LiveProcess.appex", isDirectory: true)
        let info = appex.appendingPathComponent("Info.plist")
        guard !FileManager.default.fileExists(atPath: info.path) else { return }
        try? FileManager.default.createDirectory(at: appex, withIntermediateDirectories: true)
        let plist: [String: Any] = [
            "CFBundleIdentifier": (Bundle.main.bundleIdentifier ?? "io.github.clabeuhtegrite.cartouche.harness") + ".LiveProcess",
            "CFBundleName": "LiveProcess",
            "CFBundlePackageType": "XPC!",
            "CFBundleExecutable": "LiveProcess",
        ]
        (plist as NSDictionary).write(to: info, atomically: true)
    }

    /// LiveContainer and the harness as on a new install: no app, no data
    /// folder, nothing in the app group, nothing signed or started, and the
    /// harness's defaults.
    static func reset() {
        let fileManager = FileManager.default
        for folder in [LCPath.docPath, fileManager.temporaryDirectory, appGroup] {
            for item in (try? fileManager.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [] {
                try? fileManager.removeItem(at: item)
            }
        }
        // Key by key as well: the preferences of the app group stay in
        // memory in each UserDefaults that reads them.
        for defaults in [LCUtils.appGroupUserDefault, UserDefaults.lcShared()] {
            for key in (defaults.persistentDomain(forName: appGroupID) ?? [:]).keys {
                defaults.removeObject(forKey: key)
            }
        }
        UserDefaults.standard.removePersistentDomain(forName: appGroupID)
        for key in ["selected", "selectedContainer", "launchAppUrlScheme", "SigningInProgress", "LCDontSignApp",
                    "LCLaunchInMultitaskMode", "LCCertificatePassword"] {
            UserDefaults.standard.removeObject(forKey: key)
        }
        signing = .signs
        signingTime = 0.05
        iOSRefusesCertificate = false
        readsBCTextures = true
        signed = []
        launches = []
        removedKeychains = []
        LCSharedUtils.setCartoucheSigningCandidate(nil)
        multitasking = false
        appURLScheme = "cartouche"
        nextGameStart = .starts
        gameEndsOnTerminate = true
        extensionReportsExit = true
        gamesHaveATVScene = true
        iPhoneMirrored = false
        screenTurned = nil
        deviceHeld = nil
        HarnessScenes.reset()
        HarnessNetwork.reset()
        let model = DataManager.shared.model
        model.updateMultiLCStatus()
        loadApps()
    }

    /// The certificate LiveContainer signs with, as "Import Certificate from
    /// SideStore" leaves it, or none.
    static func installCertificate(_ certificate: HarnessCertificate?) {
        let defaults = LCUtils.appGroupUserDefault
        if let certificate {
            defaults.set(certificate.data, forKey: "LCCertificateData")
            defaults.set(certificate.password, forKey: "LCCertificatePassword")
        } else {
            defaults.removeObject(forKey: "LCCertificateData")
            defaults.removeObject(forKey: "LCCertificatePassword")
        }
    }

    /// LiveContainer's list of apps and data folders, read from its folders
    /// as LiveContainerSwiftUIApp does as the app starts: what a player
    /// finds after Cartouche started again.
    static func loadApps() {
        let fm = FileManager()
        var tempAppDataFolderNames: [String] = []
        var tempTweakFolderNames: [String] = []

        var tempApps: [LCAppModel] = []
        var tempArm32EmuApps: [LCAppModel] = []
        var tempHiddenApps: [LCAppModel] = []
        var tempURLSchemes: Set<String>? = DataManager.shared.model.multiLCStatus != 2 ? Set() : nil

        do {
            try fm.createDirectory(at: LCPath.bundlePath, withIntermediateDirectories: true)
            let appDirs = try fm.contentsOfDirectory(atPath: LCPath.bundlePath.path)
            for appDir in appDirs where appDir.hasSuffix(".app") {
                let newApp = LCAppInfo(bundlePath: "\(LCPath.bundlePath.path)/\(appDir)")!
                newApp.relativeBundlePath = appDir
                newApp.isShared = false
                let model = LCAppModel(appInfo: newApp)
                if newApp.isHidden {
                    tempHiddenApps.append(model)
                } else {
                    tempApps.append(model)
                    tempURLSchemes?.formUnion(newApp.urlSchemes() as! [String])
                }
                if newApp.is32bitEmulator {
                    tempArm32EmuApps.append(model)
                }
            }
            if LCPath.lcGroupDocPath != LCPath.docPath {
                try fm.createDirectory(at: LCPath.lcGroupBundlePath, withIntermediateDirectories: true)
                let appDirsShared = try fm.contentsOfDirectory(atPath: LCPath.lcGroupBundlePath.path)
                for appDir in appDirsShared where appDir.hasSuffix(".app") {
                    let newApp = LCAppInfo(bundlePath: "\(LCPath.lcGroupBundlePath.path)/\(appDir)")!
                    newApp.relativeBundlePath = appDir
                    newApp.isShared = true
                    let model = LCAppModel(appInfo: newApp)
                    if newApp.isHidden {
                        tempHiddenApps.append(model)
                    } else {
                        tempApps.append(model)
                        tempURLSchemes?.formUnion(newApp.urlSchemes() as! [String])
                    }
                    if newApp.is32bitEmulator {
                        tempArm32EmuApps.append(model)
                    }
                }
            }
            try fm.createDirectory(at: LCPath.dataPath, withIntermediateDirectories: true)
            let dataDirs = try fm.contentsOfDirectory(atPath: LCPath.dataPath.path)
            for dataDir in dataDirs {
                let dataDirUrl = LCPath.dataPath.appendingPathComponent(dataDir)
                if !dataDirUrl.hasDirectoryPath {
                    continue
                }
                tempAppDataFolderNames.append(dataDir)
            }
            try fm.createDirectory(at: LCPath.tweakPath, withIntermediateDirectories: true)
            let tweakDirs = try fm.contentsOfDirectory(atPath: LCPath.tweakPath.path)
            for tweakDir in tweakDirs {
                let tweakDirUrl = LCPath.tweakPath.appendingPathComponent(tweakDir)
                if !tweakDirUrl.hasDirectoryPath {
                    continue
                }
                let folderName = tweakDir.hasSuffix(".disabled") ? String(tweakDir.dropLast(".disabled".count)) : tweakDir
                tempTweakFolderNames.append(folderName)
            }
        } catch {
            NSLog("[LC] error:\(error)")
        }

        DataManager.shared.model.apps = tempApps
        DataManager.shared.model.arm32EmuApps = tempArm32EmuApps
        DataManager.shared.model.hiddenApps = tempHiddenApps
        DataManager.shared.model.appDataFolderNames = tempAppDataFolderNames
        DataManager.shared.model.tweakFolderNames = tempTweakFolderNames
        if let tempURLSchemes {
            UserDefaults.lcShared().set(Array(tempURLSchemes), forKey: "LCGuestURLSchemes")
        }
    }

    // MARK: Signing

    /// What zsign does with BUNDLE: signs it with the installed certificate,
    /// as the signature and profile it writes, or fails, as SIGNING says,
    /// on a queue of its own. Returns its progress at once, as zsign does.
    static func sign(bundle: String, completion: @escaping (Bool, Error?) -> Void) -> Progress {
        let progress = Progress(totalUnitCount: 100)
        let plan = signing
        let time = signingTime
        let certificate = LCUtils.certificateData()
        DispatchQueue.main.async { HarnessLC.signed.append(bundle) }
        DispatchQueue.global(qos: .userInitiated).async {
            for step in 1...10 {
                Thread.sleep(forTimeInterval: time / 10)
                progress.completedUnitCount = Int64(step * 10)
            }
            switch plan {
            case .fails(let message):
                completion(false, NSError(domain: "zsign", code: 1, userInfo: [NSLocalizedDescriptionKey: message]))
            case .signs, .signsPartly:
                let folder = URL(fileURLWithPath: bundle, isDirectory: true)
                let signature = folder.appendingPathComponent("_CodeSignature", isDirectory: true)
                try? FileManager.default.createDirectory(at: signature, withIntermediateDirectories: true)
                let resources: [String: Any] = ["HarnessCertificate": HarnessLC.fingerprint(of: certificate) ?? ""]
                (resources as NSDictionary).write(to: signature.appendingPathComponent("CodeResources"), atomically: true)
                try? Data("harness provisioning profile".utf8).write(to: folder.appendingPathComponent("embedded.mobileprovision"))
                if case .signsPartly(let message) = plan {
                    completion(true, NSError(domain: "zsign", code: 2, userInfo: [NSLocalizedDescriptionKey: message]))
                } else {
                    completion(true, nil)
                }
            }
        }
        return progress
    }

    /// Whether iOS runs the executable at PATH, as LiveContainer's
    /// checkCodeSignature asks it: signed with the installed certificate,
    /// which iOS still accepts.
    static func signatureIsValid(_ path: String) -> Bool {
        let bundle = URL(fileURLWithPath: path).deletingLastPathComponent()
        guard FileManager.default.fileExists(atPath: path), !iOSRefusesCertificate,
              let installed = fingerprint(of: LCUtils.certificateData()),
              let resources = NSDictionary(contentsOf: bundle.appendingPathComponent("_CodeSignature/CodeResources")),
              resources["HarnessCertificate"] as? String == installed else { return false }
        return true
    }

    private static func fingerprint(of certificate: Data?) -> String? {
        guard let certificate else { return nil }
        return certificate.base64EncodedString()
    }
}

/// LiveContainer's unpacker (unarchive.m), for the tests, which do not see
/// the harness's bridging header: what Cartouche's install calls.
enum HarnessUnarchive {
    /// Unpacks the IPA at IPA into FOLDER as LiveContainer does, with its
    /// PROGRESS. 0 if it went well, as extract returns.
    static func unpack(_ ipa: String, into folder: String, progress: Progress) -> Int32 {
        extract(ipa, folder, progress)
    }
}

/// A signing certificate with its private key, as SideStore keeps one: in
/// the harness, a property list that names its team and the password that
/// opens it (LCUtils.getCertTeamId).
struct HarnessCertificate {
    let data: Data
    let password: String

    init(team: String, password: String, serial: Int = 1) {
        let plist: [String: Any] = ["HarnessTeam": team, "HarnessPassword": password, "HarnessSerial": serial]
        data = (try? PropertyListSerialization.data(fromPropertyList: plist, format: .binary, options: 0)) ?? Data()
        self.password = password
    }

    /// The team of the certificate in DATA, if PASSWORD opens it.
    static func team(of data: Data, password: String) -> String? {
        guard let plist = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any],
              plist["HarnessPassword"] as? String == password else { return nil }
        return plist["HarnessTeam"] as? String
    }
}

// MARK: LiveContainer's folders and model (Shared.swift, with patch 0003)

struct LCPath {
    public static let docPath = {
        let fm = FileManager()
        return fm.urls(for: .documentDirectory, in: .userDomainMask).last!
    }()
    public static let bundlePath = docPath.appendingPathComponent("Applications")
    public static let dataPath = docPath.appendingPathComponent("Data/Application")
    public static let appGroupPath = docPath.appendingPathComponent("Data/AppGroup")
    public static let tweakPath = docPath.appendingPathComponent("Tweaks")

    public static let lcGroupDocPath = {
        if let appGroupPathUrl = LCSharedUtils.appGroupPath() {
            return appGroupPathUrl.appendingPathComponent("LiveContainer")
        } else {
            return docPath
        }
    }()
    public static let lcGroupBundlePath = lcGroupDocPath.appendingPathComponent("Applications")
    public static let lcGroupDataPath = lcGroupDocPath.appendingPathComponent("Data/Application")
    public static let lcGroupAppGroupPath = lcGroupDocPath.appendingPathComponent("Data/AppGroup")
    public static let lcGroupTweakPath = lcGroupDocPath.appendingPathComponent("Tweaks")

    public static func ensureAppGroupPaths() throws {
        let fm = FileManager()
        if !fm.fileExists(atPath: LCPath.lcGroupBundlePath.path) {
            try fm.createDirectory(at: LCPath.lcGroupBundlePath, withIntermediateDirectories: true)
        }
        if !fm.fileExists(atPath: LCPath.lcGroupDataPath.path) {
            try fm.createDirectory(at: LCPath.lcGroupDataPath, withIntermediateDirectories: true)
        }
        if !fm.fileExists(atPath: LCPath.lcGroupTweakPath.path) {
            try fm.createDirectory(at: LCPath.lcGroupTweakPath, withIntermediateDirectories: true)
        }
    }
}

class SharedModel: ObservableObject {
    @Published var selectedTab: LCTabIdentifier = .initial
    @Published var deepLink: URL?

    @Published var isHiddenAppUnlocked = false
    @Published var developerMode = false
    // 0 = current liveContainer is the primary one,
    // 2 = current liveContainer is not the primary one
    @Published var multiLCStatus = 0
    @Published var isJITModalOpen = false

    @Published var enableMultipleWindow = false

    @Published var appDataFolderNames: [String] = []
    @Published var tweakFolderNames: [String] = []

    @Published var apps: [LCAppModel] = []
    @Published var arm32EmuApps: [LCAppModel] = []
    @Published var hiddenApps: [LCAppModel] = []

    @Published var pidCallback: ((NSNumber, Error?) -> Void)? = nil

    static let isPhone: Bool = {
        UIDevice.current.userInterfaceIdiom == .phone
    }()

    /// Off in the harness, which links no SDK check of LiveContainer's.
    static let isLiquidGlassEnabled = false

    var mainWindowOpened = false

    public static let keychainAccessGroupCount = 128

    func updateMultiLCStatus() {
        // "livecontainer" in LiveContainer, which brand.py renames.
        if LCUtils.appUrlScheme()?.lowercased() != "cartouche" {
            multiLCStatus = 2
        } else {
            multiLCStatus = 0
        }
    }

    init() {
        updateMultiLCStatus()
    }
}

class DataManager {
    static let shared = DataManager()
    let model = SharedModel()
}

public enum LCTabIdentifier: Hashable {
    case games
    case sources
    case apps
    case system
    case tweaks
    case settings

    /// Cartouche opens on its games, where iOS can show them.
    static var initial: LCTabIdentifier {
        if #available(iOS 17.0, *) {
            return .games
        }
        return .apps
    }
}

extension String: @retroactive Error {}
extension String: @retroactive LocalizedError {
    public var errorDescription: String? { return self }

    private static var enBundle: Bundle? = {
        // LiveContainer unwraps this path: the harness has its texts too
        // (Localizable.xcstrings), but says so rather than stopping.
        guard let path = Bundle.main.path(forResource: "en", ofType: "lproj") else { return nil }
        return Bundle(path: path)
    }()

    var loc: String {
        let message = NSLocalizedString(self, comment: "")
        if message != self {
            return message
        }

        if let forcedString = String.enBundle?.localizedString(forKey: self, value: nil, table: nil) {
            return forcedString
        } else {
            return self
        }
    }

    func localizeWithFormat(_ arguments: CVarArg...) -> String {
        String.localizedStringWithFormat(self.loc, arguments)
    }

    func sanitizeNonACSII() -> String {
        filter { $0.isASCII }
    }
}

extension UTType {
    static let ipa = UTType(filenameExtension: "ipa")!
    static let tipa = UTType(filenameExtension: "tipa")!
    static let p12 = UTType(filenameExtension: "p12")!
}

extension NSNotification {
    static let InstallAppNotification = Notification.Name.init("InstallAppNotification")
}

extension UserDefaults {
    /// +[NSUserDefaults lcSharedDefaults]: the app group's preferences.
    static func lcShared() -> UserDefaults {
        HarnessDefaults.shared
    }
}

private enum HarnessDefaults {
    static let shared = UserDefaults(suiteName: LCSharedUtils.appGroupID()) ?? .standard
}

// MARK: LiveContainer's utilities (LCUtils.m, LCUtilsExtensions.swift, LCSharedUtils.m)

enum LCUtils {
    public static let appGroupUserDefault = UserDefaults.init(suiteName: LCSharedUtils.appGroupID()) ?? UserDefaults.standard

    /// The certificate LiveContainer signs with, where LiveContainer keeps
    /// it: the app group's preferences.
    static func certificateData() -> Data! {
        if let candidate = LCSharedUtils.cartoucheSigningMaterial() { return candidate["certificate"] as? Data }
        let nud = UserDefaults(suiteName: LCSharedUtils.appGroupID()) ?? .standard
        return nud.object(forKey: "LCCertificateData") as? Data
    }

    static func getCertTeamId(withKeyData keyData: Data!, password: String!) -> String! {
        guard let keyData, let password else { return nil }
        return HarnessCertificate.team(of: keyData, password: password)
    }

    /// LiveContainer's test of its setup: it signs a small library with its
    /// certificate and asks iOS whether it runs it. On its queue, then on
    /// the main one.
    static func validateJITLessSetup(completionHandler: ((Bool, Error?) -> Void)!) {
        let works = certificateData() != nil && LCSharedUtils.certificatePassword() != nil && !HarnessLC.iOSRefusesCertificate
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 0.05) {
            DispatchQueue.main.async {
                completionHandler(works, works ? nil : NSError(domain: "LiveContainer", code: 1,
                                                               userInfo: [NSLocalizedDescriptionKey: "lc.signer.latestCertificateInvalidErr".loc]))
            }
        }
    }

    static func appUrlScheme() -> String! {
        HarnessLC.appURLScheme
    }

    static func isTXMScriptRequired() -> Bool {
        false
    }

    static func base64EncodedUniversalJITScript() -> String! {
        nil
    }

    public static func removeAppKeychain(dataUUID label: String) {
        HarnessLC.removedKeychains.append(label)
        [kSecClassGenericPassword, kSecClassInternetPassword, kSecClassCertificate, kSecClassKey, kSecClassIdentity].forEach {
            let status = SecItemDelete([
                kSecClass as String: $0,
                "alis": label,
            ] as CFDictionary)
            if status != errSecSuccess && status != errSecItemNotFound {
                NSLog("[LC] Failed to find keychain items: \(status)")
            }
        }
    }

    /// No other copy of LiveContainer on this iPhone.
    public static func forEachInstalledLC(isFree: Bool, block: (String, inout Bool) -> Void) {}

    /// Tweaks: games have none.
    public static func signTweaks(tweakFolderUrl: URL, force: Bool = false, progressHandler: ((Progress) -> Void)? = nil) async throws {}

    public static func authenticateUser() async throws -> Bool {
        true
    }

    /// LiveContainer's own multitasking windows, which Cartouche does not
    /// open: the harness records nothing and says the process started.
    @available(iOS 16.0, *)
    static func launchMultitaskGuestApp(_ displayName: String!, completionHandler: ((NSNumber?, Error?) -> Void)!) {
        DispatchQueue.main.async { completionHandler(NSNumber(value: 1), nil) }
    }

    @available(iOS 16.0, *)
    @discardableResult
    static func launchMultitaskGuestApp(_ displayName: String!) async throws -> NSNumber {
        NSNumber(value: 1)
    }
}

enum LCSharedUtils {
    static func teamIdentifier() -> String! {
        "HARNESS001"
    }

    static func appGroupID() -> String! {
        HarnessLC.appGroupID
    }

    static func appGroupPath() -> URL! {
        HarnessLC.appGroup
    }

    static func certificatePassword() -> String! {
        if let candidate = cartoucheSigningMaterial() { return candidate["password"] as? String }
        return UserDefaults.lcShared().object(forKey: "LCCertificatePassword") as? String
    }

    private static let candidateLock = NSLock()
    private static var candidate: [String: Any]?

    /// The certificate and password a player imports, which LiveContainer
    /// signs with while Cartouche checks them (patch livecontainer/0010):
    /// certificateData() and certificatePassword() give the candidate's
    /// while there is one. From any thread.
    static func setCartoucheSigningCandidate(_ material: [String: Any]?) {
        candidateLock.lock()
        defer { candidateLock.unlock() }
        candidate = material
    }

    /// The candidate, if any. The harness is no install signed with an
    /// imported certificate, whose material LiveContainer reads from the
    /// keychain.
    static func cartoucheSigningMaterial() -> [String: Any]? {
        candidateLock.lock()
        defer { candidateLock.unlock() }
        return candidate
    }

    /// LiveContainer quits Cartouche and opens the game: the harness
    /// records what it would open.
    @discardableResult
    static func launchToGuestApp(withClassicMode classicMode: UInt) -> Bool {
        let defaults = UserDefaults.standard
        HarnessLC.launches.append(HarnessLC.Launch(bundle: defaults.string(forKey: "selected"),
                                                   container: defaults.string(forKey: "selectedContainer"),
                                                   classicMode: classicMode))
        return true
    }

    /// No other copy of LiveContainer uses any data folder.
    static func getContainerUsingLCScheme(withFolderName folderName: String!) -> String! {
        nil
    }

    static func isLCScheme(inUse lc: String!) -> Bool {
        false
    }

    static func lcUrlSchemes() -> [String]! {
        ["cartouche"]
    }
}

// MARK: LiveContainer's multitasking, which Cartouche does not use

enum MultitaskManager {
    static func isMultitasking() -> Bool {
        HarnessLC.multitasking
    }
}

enum MultitaskWindowManager {
    @available(iOS 16.1, *)
    static func openExistingAppWindow(dataUUID: String) -> Bool {
        false
    }
}

final class MultitaskDockManager {
    static let shared = MultitaskDockManager()

    func bringMultitaskViewToFront(uuid: String, from center: CGPoint? = nil) -> Bool {
        false
    }
}
