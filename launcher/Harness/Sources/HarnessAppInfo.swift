//
//  HarnessAppInfo.swift
//  CartoucheHarness
//
//  LiveContainer's LCAppInfo (LiveContainerSwiftUI/Models/LCAppInfo.m),
//  in Swift, as Swift sees the Objective-C one: what an app's Info.plist and
//  LCAppInfo.plist say, read and written as LiveContainer does, line for
//  line, and its signing (patchExecAndSignIfNeed), with the same steps and
//  the same messages: the executable is read as a Mach-O file
//  (LCParseMachO), and zsign and iOS's check of the signature are the
//  harness's (HarnessLC.sign, HarnessLC.signatureIsValid).
//

import Foundation
import UIKit

enum LCOrientationLock: Int {
    case disabled = 0
    case landscape = 1
    case portrait = 2
}

enum MultitaskSpecified: Int {
    case `default` = 0
    case no = 1
    case yes = 2
}

class LCAppInfo: NSObject {
    private var _info: NSMutableDictionary
    private var _infoPlist: NSMutableDictionary
    private var _bundlePath: String?

    var relativeBundlePath: String!
    var isShared = false
    var autoSaveDisabled = false
    var cachedIcon: UIImage!
    var cachedIconDark: UIImage!

    /// The keys an old LiveContainer kept in the Info.plist.
    private static let movedKeys = [
        "LCPatchRevision", "LCOrignalBundleIdentifier", "LCDataUUID", "LCTweakFolder", "LCJITLessSignID",
        "LCSelectedLanguage", "LCExpirationDate", "LCTeamId", "isJITNeeded", "isLocked", "isHidden", "doUseLCBundleId",
        "doSymlinkInbox", "bypassAssertBarrierOnQueue", "signer", "LCOrientationLock", "cachedColor", "LCContainers",
        "hideLiveContainer", "jitLaunchScriptJs",
    ]

    init!(bundlePath: String!) {
        _bundlePath = bundlePath
        let folder = bundlePath ?? "(null)"
        _infoPlist = NSMutableDictionary(contentsOfFile: folder + "/Info.plist") ?? NSMutableDictionary()
        _info = NSMutableDictionary(contentsOfFile: folder + "/LCAppInfo.plist") ?? NSMutableDictionary()
        super.init()
        isShared = false

        // migrate old appInfo
        if _infoPlist["LCPatchRevision"] != nil && _info.count == 0 {
            for key in Self.movedKeys {
                _info[key] = _infoPlist[key]
                _infoPlist.removeObject(forKey: key)
            }
            Self.writeBin(_infoPlist, to: folder + "/Info.plist")
            save()
        }

        // fix bundle id and execName if crash when signing
        if _infoPlist["LCBundleIdentifier"] != nil {
            _infoPlist["CFBundleExecutable"] = _infoPlist["LCBundleExecutable"]
            _infoPlist["CFBundleIdentifier"] = _infoPlist["LCBundleIdentifier"]
            _infoPlist.removeObject(forKey: "LCBundleExecutable")
            _infoPlist.removeObject(forKey: "LCBundleIdentifier")
            Self.writeBin(_infoPlist, to: folder + "/Info.plist")
        }
        autoSaveDisabled = false
    }

    /// -[NSDictionary writeBinToFile:atomically:] (utils.m).
    @discardableResult
    private static func writeBin(_ dictionary: NSDictionary, to path: String) -> Bool {
        guard let data = try? PropertyListSerialization.data(fromPropertyList: dictionary, format: .binary, options: 0) else {
            return false
        }
        return (data as NSData).write(toFile: path, atomically: true)
    }

    func setBundlePath(_ newBundlePath: String!) {
        _bundlePath = newBundlePath
    }

    func urlSchemes() -> NSMutableArray! {
        let urlSchemes = NSMutableArray()
        var nowSchemeCount = 0
        if let urlTypes = _infoPlist["CFBundleURLTypes"] as? NSArray {
            for case let nowUrlType as NSDictionary in urlTypes {
                guard let schemes = nowUrlType["CFBundleURLSchemes"] as? NSArray else { continue }
                for scheme in schemes {
                    urlSchemes.insert(scheme, at: nowSchemeCount)
                    nowSchemeCount += 1
                }
            }
        }
        return urlSchemes
    }

    func displayName() -> String! {
        if let name = _infoPlist["CFBundleDisplayName"] as? String {
            return name
        } else if let name = _infoPlist["CFBundleName"] as? String {
            return name
        } else if let name = _infoPlist["CFBundleExecutable"] as? String {
            return name
        } else {
            return "App Corrupted, Please Reinstall This App"
        }
    }

    func version() -> String! {
        (_infoPlist["CFBundleShortVersionString"] as? String) ?? (_infoPlist["CFBundleVersion"] as? String) ?? "Unknown"
    }

    func bundleIdentifier() -> String! {
        let ans: String?
        if doUseLCBundleId {
            ans = _info["LCOrignalBundleIdentifier"] as? String
        } else {
            ans = _infoPlist["CFBundleIdentifier"] as? String
        }
        return ans ?? "Unknown"
    }

    var dataUUID: String! {
        get { _info["LCDataUUID"] as? String }
        set {
            _info["LCDataUUID"] = newValue
            save()
        }
    }

    var tweakFolder: String! {
        get { _info["LCTweakFolder"] as? String }
        set {
            _info["LCTweakFolder"] = newValue
            save()
        }
    }

    var selectedLanguage: String! {
        get { _info["LCSelectedLanguage"] as? String }
        set {
            if newValue == "" {
                _info["LCSelectedLanguage"] = nil
            } else {
                _info["LCSelectedLanguage"] = newValue
            }
            save()
        }
    }

    func bundlePath() -> String! {
        _bundlePath
    }

    func info() -> NSMutableDictionary! {
        _info
    }

    /// The app's icon: in the harness, a plain square of its own colour,
    /// cached as LiveContainer caches the one it draws.
    func iconIsDarkIcon(_ isDarkIcon: Bool) -> UIImage! {
        if !isDarkIcon, let cachedIcon {
            return cachedIcon
        } else if isDarkIcon, let cachedIconDark {
            return cachedIconDark
        }
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let icon = UIGraphicsImageRenderer(size: CGSize(width: 60, height: 60), format: format).image { context in
            (isDarkIcon ? UIColor.darkGray : UIColor.lightGray).setFill()
            context.fill(CGRect(x: 0, y: 0, width: 60, height: 60))
        }
        if isDarkIcon {
            cachedIconDark = icon
        } else {
            cachedIcon = icon
        }
        return icon
    }

    func clearIconCache() {
        cachedColor = nil
        cachedColorDark = nil
        cachedIcon = nil
        cachedIconDark = nil
    }

    func save() {
        if !autoSaveDisabled {
            Self.writeBin(_info, to: "\(_bundlePath ?? "(null)")/LCAppInfo.plist")
        }
    }

    // MARK: Signing

    func patchExecAndSignIfNeed(completionHandler completetionHandler: ((Bool, String?) -> Void)!,
                                progressHandler: ((Progress?) -> Void)!, forceSign: Bool) {
        UserDefaults.standard.set(true, forKey: "SigningInProgress")
        let appPath = bundlePath() ?? "(null)"
        let info = _info
        let infoPlist = _infoPlist
        let fm = FileManager.default
        let executable = (_infoPlist["CFBundleExecutable"] as? String) ?? "(null)"
        let execPath = "\(appPath)/\(executable)"
        var forceSign = forceSign

        // Update patch
        let currentPatchRev = 7
        let needPatch = ((info["LCPatchRevision"] as? NSNumber)?.intValue ?? 0) < currentPatchRev
        if needPatch || forceSign {
            // copy-delete-move to avoid EXC_BAD_ACCESS (SIGKILL - CODESIGNING)
            let backupPath = "\(appPath)/\(executable)_LiveContainerPatchBackUp"
            try? fm.copyItem(atPath: execPath, toPath: backupPath)
            try? fm.removeItem(atPath: execPath)
            try? fm.moveItem(atPath: backupPath, toPath: execPath)
        }

        if needPatch {
            var has64bitSlice = false
            var isEncrypted = false
            var error = HarnessMachO.parse(execPath) { header in
                if header.cpuType == HarnessMachO.cpuTypeARM64 {
                    has64bitSlice = true
                }
                isEncrypted = isEncrypted || header.isEncrypted
            }
            let is32bit = !has64bitSlice
            if isEncrypted {
                error = "The app you tried to install is encrypted. Please provide decrypted app."
            }
            if let error {
                UserDefaults.standard.removeObject(forKey: "SigningInProgress")
                completetionHandler(false, error)
                return
            }
            self.is32bit = is32bit
            if is32bit {
                self.isJITNeeded = true
                self.classicMode = true
                self.spoofSDKVersion = true
            }
            info["LCPatchRevision"] = NSNumber(value: currentPatchRev)
            forceSign = true

            save()
        }

        if LCSharedUtils.certificatePassword() == nil || self.is32bit || self.dontSign {
            UserDefaults.standard.removeObject(forKey: "SigningInProgress")
            completetionHandler(true, nil)
            return
        }

        // check if iOS think this app's signature is valid, if so, we can skip any further signature check
        let executablePath = (appPath as NSString).appendingPathComponent((infoPlist["CFBundleExecutable"] as? String) ?? "")
        if !forceSign {
            if HarnessLC.signatureIsValid(executablePath) {
                UserDefaults.standard.removeObject(forKey: "SigningInProgress")
                completetionHandler(true, nil)
                return
            }
        }

        if LCUtils.certificateData() == nil {
            UserDefaults.standard.removeObject(forKey: "SigningInProgress")
            completetionHandler(false, "lc.signer.noCertificateFoundErr")
            return
        }

        let progress = HarnessLC.sign(bundle: appPath) { success, error in
            DispatchQueue.main.async {
                UserDefaults.standard.removeObject(forKey: "SigningInProgress")
                if !success {
                    completetionHandler(false, error?.localizedDescription)
                } else {
                    if HarnessLC.signatureIsValid(executablePath) {
                        completetionHandler(true, error?.localizedDescription)
                    } else {
                        completetionHandler(false, "lc.signer.latestCertificateInvalidErr")
                    }
                }
            }
        }
        progressHandler(progress)
    }

    // MARK: What LCAppInfo.plist says

    private func flag(_ key: String) -> Bool {
        (_info[key] as? NSNumber)?.boolValue ?? false
    }

    private func setFlag(_ key: String, _ value: Bool) {
        _info[key] = NSNumber(value: value)
        save()
    }

    var isJITNeeded: Bool {
        get { flag("isJITNeeded") }
        set { setFlag("isJITNeeded", newValue) }
    }

    var classicMode: Bool {
        get { flag("classicMode") }
        set {
            _info["classicMode"] = NSNumber(value: newValue)
            if newValue {
                _ = defaultClassicMode
            } else {
                _info["LCClassicModeCache"] = nil
                save()
            }
        }
    }

    /// The classic mode LiveContainer finds for the app; in the harness,
    /// the first one, for an app whose classic mode is on.
    var defaultClassicMode: UInt {
        if !classicMode {
            return 0
        }
        let systemMajorVersion = ProcessInfo.processInfo.operatingSystemVersion.majorVersion
        if let cache = _info["LCClassicModeCache"] as? NSDictionary,
           let cachedMode = cache["defaultClassicMode"] as? NSNumber,
           let cachedSystemMajorVersion = cache["systemMajorVersion"] as? NSNumber,
           cachedSystemMajorVersion.intValue == systemMajorVersion {
            return cachedMode.uintValue
        }
        let mode = NSNumber(value: 1)
        _info["LCClassicModeCache"] = ["defaultClassicMode": mode, "systemMajorVersion": NSNumber(value: systemMajorVersion)]
        save()
        return mode.uintValue
    }

    var isLocked: Bool {
        get { flag("isLocked") }
        set { setFlag("isLocked", newValue) }
    }

    var isHidden: Bool {
        get { flag("isHidden") }
        set { setFlag("isHidden", newValue) }
    }

    var doSymlinkInbox: Bool {
        get { flag("doSymlinkInbox") }
        set { setFlag("doSymlinkInbox", newValue) }
    }

    var hideLiveContainer: Bool {
        get { flag("hideLiveContainer") }
        set { setFlag("hideLiveContainer", newValue) }
    }

    var dontInjectTweakLoader: Bool {
        get { flag("dontInjectTweakLoader") }
        set {
            if flag("dontInjectTweakLoader") == newValue {
                return
            }
            _info["dontInjectTweakLoader"] = NSNumber(value: newValue)
            // we have to update patch to achieve this
            _info["LCPatchRevision"] = NSNumber(value: -1)
            save()
        }
    }

    var dontLoadTweakLoader: Bool {
        get { flag("dontLoadTweakLoader") }
        set { setFlag("dontLoadTweakLoader", newValue) }
    }

    var doUseLCBundleId: Bool {
        get { flag("doUseLCBundleId") }
        set {
            _info["doUseLCBundleId"] = NSNumber(value: newValue)
            let infoPath = "\(bundlePath() ?? "(null)")/Info.plist"
            if newValue {
                _info["LCOrignalBundleIdentifier"] = _infoPlist["CFBundleIdentifier"]
                _infoPlist["CFBundleIdentifier"] = Bundle.main.bundleIdentifier
            } else if _info["LCOrignalBundleIdentifier"] != nil {
                _infoPlist["CFBundleIdentifier"] = _info["LCOrignalBundleIdentifier"]
                _info.removeObject(forKey: "LCOrignalBundleIdentifier")
            }
            Self.writeBin(_infoPlist, to: infoPath)
            save()
        }
    }

    var fixFilePickerNew: Bool {
        get { flag("fixFilePickerNew") }
        set { setFlag("fixFilePickerNew", newValue) }
    }

    var fixLocalNotification: Bool {
        get { flag("fixLocalNotification") }
        set { setFlag("fixLocalNotification", newValue) }
    }

    var orientationLock: LCOrientationLock {
        get { LCOrientationLock(rawValue: (_info["LCOrientationLock"] as? NSNumber)?.intValue ?? 0) ?? .disabled }
        set {
            _info["LCOrientationLock"] = NSNumber(value: newValue.rawValue)
            save()
        }
    }

    var multitaskSpecified: MultitaskSpecified {
        get { MultitaskSpecified(rawValue: (_info["MultitaskSpecified"] as? NSNumber)?.intValue ?? 0) ?? .default }
        set {
            _info["MultitaskSpecified"] = NSNumber(value: newValue.rawValue)
            save()
        }
    }

    var cachedColor: UIColor! {
        get { color("cachedColor") }
        set { setColor(newValue, "cachedColor") }
    }

    var cachedColorDark: UIColor! {
        get { color("cachedColorDark") }
        set { setColor(newValue, "cachedColorDark") }
    }

    private func color(_ key: String) -> UIColor? {
        guard let data = _info[key] as? Data else { return nil }
        return try? NSKeyedUnarchiver.unarchivedObject(ofClass: UIColor.self, from: data)
    }

    private func setColor(_ color: UIColor?, _ key: String) {
        if let color {
            _info[key] = try? NSKeyedArchiver.archivedData(withRootObject: color, requiringSecureCoding: true)
        } else {
            _info[key] = nil
        }
        save()
    }

    var containerInfo: [[AnyHashable: Any]]! {
        get { _info["LCContainers"] as? [[AnyHashable: Any]] }
        set {
            _info["LCContainers"] = newValue
            save()
        }
    }

    var is32bit: Bool {
        get { flag("is32bit") }
        set { setFlag("is32bit", newValue) }
    }

    var is32bitEmulator: Bool {
        (_infoPlist["LC32BitTranslationLayer"] as? NSNumber)?.boolValue ?? false
    }

    var dontSign: Bool {
        get { flag("dontSign") }
        set { setFlag("dontSign", newValue) }
    }

    var jitLaunchScriptJs: String! {
        get {
            if is32bit && LCUtils.isTXMScriptRequired() {
                return LCUtils.base64EncodedUniversalJITScript()
            }
            return _info["jitLaunchScriptJs"] as? String
        }
        set {
            if let newValue, !newValue.isEmpty {
                _info["jitLaunchScriptJs"] = newValue
            } else {
                _info.removeObject(forKey: "jitLaunchScriptJs")
            }
            if !autoSaveDisabled { save() }
        }
    }

    var selected32BitEmulator: String! {
        get { _info["selected32BitEmulator"] as? String }
        set {
            if let newValue, !newValue.isEmpty {
                _info["selected32BitEmulator"] = newValue
            } else {
                _info.removeObject(forKey: "selected32BitEmulator")
            }
            if !autoSaveDisabled { save() }
        }
    }

    var spoofSDKVersion: Bool {
        get {
            guard let value = _info["spoofSDKVersion"] as? NSNumber else { return false }
            return value.uint32Value != 0
        }
        set {
            if !newValue {
                // LiveContainer sets it to 0, a nil object: the key goes.
                _info["spoofSDKVersion"] = nil
            } else {
                let execPath = "\(_bundlePath ?? "(null)")/\((_infoPlist["CFBundleExecutable"] as? String) ?? "(null)")"
                var sdkVersion: UInt32 = 0
                _ = HarnessMachO.parse(execPath) { header in
                    sdkVersion = header.sdkVersion
                }
                // Hardcode spoofed SDK to iOS 11 if lower, as lower causes `Error in compatibility flow` crashes
                let minSDK: UInt32 = is32bit ? 0x20000 : 0xb0000
                if (is32bit || sdkVersion != 0) && sdkVersion < minSDK {
                    sdkVersion = minSDK
                }
                _info["spoofSDKVersion"] = NSNumber(value: sdkVersion)
            }
            save()
        }
    }

    var lastLaunched: Date! {
        get { _info["lastLaunched"] as? Date }
        set {
            _info["lastLaunched"] = newValue
            save()
        }
    }

    var installationDate: Date! {
        get { _info["installationDate"] as? Date }
        set {
            _info["installationDate"] = newValue
            save()
        }
    }

    var remark: String! {
        get { _info["remark"] as? String }
        set {
            if newValue == "" {
                _info["remark"] = nil
            } else {
                _info["remark"] = newValue
            }
            save()
        }
    }
}

/// The built-in SideStore, which LiveContainer lists as an app of its own
/// (BuiltInSideStoreAppInfo.swift): none in the harness, which has no
/// SideStore, but LCContainer.swift tells it apart.
final class BuiltInSideStoreAppInfo: LCAppInfo {}

// MARK: Mach-O files

/// What LiveContainer reads of an app's executable before it signs it
/// (LCParseMachO, LCIsMachOEncrypted and dyld_get_sdk_version): the
/// executable of a test app is a small Mach-O file of its own
/// (HarnessIPA.swift).
enum HarnessMachO {
    static let cpuTypeARM64: Int32 = 0x0100_000C
    static let cpuTypeARM: Int32 = 12

    struct Header {
        var cpuType: Int32
        var isEncrypted: Bool
        /// The SDK it was built with, as dyld reads it: 0x001A0000 for 26.0.
        var sdkVersion: UInt32
    }

    /// Calls BODY with each header of the executable at PATH that
    /// LiveContainer looks at: the only one of a thin file, or the ARM
    /// slices of a fat one. Returns LiveContainer's message when it cannot
    /// read it.
    @discardableResult
    static func parse(_ path: String, _ body: (Header) -> Void) -> String? {
        guard let data = FileManager.default.contents(atPath: path) else {
            return "Failed to map \(path): \(String(cString: strerror(EBADF)))"
        }
        guard !data.isEmpty else {
            return "Failed to map \(path): \(String(cString: strerror(EINVAL)))"
        }
        let bytes = [UInt8](data)
        guard bytes.count >= 4 else { return "Not a Mach-O file" }
        let magic = littleEndian(bytes, 0)
        if magic == 0xBEBA_FECA {
            // FAT_CIGAM: a fat file, its fields big-endian.
            let count = bigEndian(bytes, 4)
            for index in 0..<Int(count) {
                let arch = 8 + index * 20
                guard arch + 20 <= bytes.count else { break }
                let cpuType = Int32(bitPattern: bigEndian(bytes, arch))
                let offset = Int(bigEndian(bytes, arch + 8))
                if cpuType == cpuTypeARM64 || cpuType == cpuTypeARM, let header = header(bytes, at: offset) {
                    body(header)
                }
            }
        } else if magic == 0xFEED_FACF || magic == 0xFEED_FACE {
            if let header = header(bytes, at: 0) {
                body(header)
            }
        } else {
            return "Not a Mach-O file"
        }
        return nil
    }

    private static func header(_ bytes: [UInt8], at offset: Int) -> Header? {
        guard offset + 28 <= bytes.count else { return nil }
        let is64 = littleEndian(bytes, offset) == 0xFEED_FACF
        let cpuType = Int32(bitPattern: littleEndian(bytes, offset + 4))
        let commands = Int(littleEndian(bytes, offset + 16))
        var command = offset + (is64 ? 32 : 28)
        var encrypted = false
        var sdk: UInt32 = 0
        for _ in 0..<commands {
            guard command + 8 <= bytes.count else { break }
            let kind = littleEndian(bytes, command)
            let size = Int(littleEndian(bytes, command + 4))
            switch kind {
            case 0x21, 0x2C:
                // LC_ENCRYPTION_INFO(_64): cryptid.
                if command + 20 <= bytes.count, littleEndian(bytes, command + 16) != 0 {
                    encrypted = true
                }
            case 0x32:
                // LC_BUILD_VERSION: platform, minos, sdk.
                if command + 20 <= bytes.count { sdk = littleEndian(bytes, command + 16) }
            case 0x25:
                // LC_VERSION_MIN_IPHONEOS: version, sdk.
                if command + 16 <= bytes.count, sdk == 0 { sdk = littleEndian(bytes, command + 12) }
            default:
                break
            }
            guard size >= 8 else { break }
            command += size
        }
        return Header(cpuType: cpuType, isEncrypted: encrypted, sdkVersion: sdk)
    }

    private static func littleEndian(_ bytes: [UInt8], _ at: Int) -> UInt32 {
        guard at + 4 <= bytes.count else { return 0 }
        var value: UInt32 = 0
        for index in 0..<4 {
            value |= UInt32(bytes[at + index]) << UInt32(8 * index)
        }
        return value
    }

    private static func bigEndian(_ bytes: [UInt8], _ at: Int) -> UInt32 {
        guard at + 4 <= bytes.count else { return 0 }
        var value: UInt32 = 0
        for index in 0..<4 {
            value = value << 8 | UInt32(bytes[at + index])
        }
        return value
    }
}
