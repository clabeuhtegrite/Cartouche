//
//  CartoucheDevice.swift
//  Cartouche
//
//  What this iPhone gives a game: its model, iOS version, GPU, the memory
//  limit iOS sets for Cartouche (games started in its place share it; one
//  behind the console has the limit of its own process, in
//  CartoucheRunningGame.swift), and how long Cartouche's signature lasts.
//

import Foundation
import Metal
import os

enum CartoucheDevice {
    /// The model identifier, such as "iPhone18,2".
    static let modelIdentifier: String = {
        #if CARTOUCHE_GALLERY
        // The gallery draws the screens as the iPhone of catalog/devices.json shows them.
        return "iPhone19,4"
        #else
        if let simulated = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] {
            return simulated
        }
        var size = 0
        sysctlbyname("hw.machine", nil, &size, nil, 0)
        guard size > 0 else { return "" }
        var machine = [CChar](repeating: 0, count: size)
        sysctlbyname("hw.machine", &machine, &size, nil, 0)
        return String(cString: machine)
        #endif
    }()

    static var iOSVersion: String {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        var text = "\(version.majorVersion).\(version.minorVersion)"
        if version.patchVersion > 0 { text += ".\(version.patchVersion)" }
        return text
    }

    /// Whether this iOS is at least `minimum`, such as "26.0".
    static func runsAtLeast(_ minimum: String) -> Bool {
        let parts = minimum.split(separator: ".").map { Int($0) ?? 0 }
        return ProcessInfo.processInfo.isOperatingSystemAtLeast(OperatingSystemVersion(
            majorVersion: parts.count > 0 ? parts[0] : 0,
            minorVersion: parts.count > 1 ? parts[1] : 0,
            patchVersion: parts.count > 2 ? parts[2] : 0))
    }

    /// Whether the GPU samples BC-compressed textures, which games from
    /// consoles use. nxnative refuses a GPU without them, the A16's and
    /// older, for every game: the game says so on its screen, or, built by
    /// an older nxnative, stops at its first texture (dm/ios/Sources/main.m,
    /// dm/gfx/nvn/nvn_mtl.m).
    static let supportsBCTextureCompression: Bool = {
        #if CARTOUCHE_GALLERY
        return true
        #else
        guard let device = MTLCreateSystemDefaultDevice() else { return false }
        if #available(iOS 16.4, *) {
            return device.supportsBCTextureCompression
        }
        return false
        #endif
    }()

    /// Whether Cartouche's signature carries Increased Memory Limit. iOS
    /// installs an app only with the entitlements its profile allows, so the
    /// signature having it means the App ID has the capability.
    static let hasIncreasedMemoryLimit: Bool = {
        let task = SecTaskCreateFromSelf(nil)
        guard let value = SecTaskCopyValueForEntitlement(task, "com.apple.developer.kernel.increased-memory-limit" as CFString, nil) else {
            return false
        }
        return (value.takeRetainedValue() as? NSNumber)?.boolValue ?? false
    }()
}

/// The memory iOS lets Cartouche use, measured the way the device profiles
/// in catalog/devices.json are: footprint plus os_proc_available_memory().
struct CartoucheMemoryReading {
    let footprintBytes: UInt64
    let availableBytes: UInt64

    var limitBytes: UInt64 { footprintBytes + availableBytes }
    var limitMiB: Int { Int(limitBytes / 1_048_576) }
    var footprintMiB: Int { Int(footprintBytes / 1_048_576) }
    var availableMiB: Int { Int(availableBytes / 1_048_576) }

    static func now() -> CartoucheMemoryReading? {
        #if CARTOUCHE_GALLERY
        // That iPhone with Increased Memory Limit and Game Mode, as
        // Cartouche's home finds it.
        return CartoucheMemoryReading(footprintBytes: 96 << 20, availableBytes: (8_192 - 96) << 20)
        #else
        let available = os_proc_available_memory()
        guard available > 0 else { return nil }

        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        return CartoucheMemoryReading(footprintBytes: info.phys_footprint, availableBytes: UInt64(available))
        #endif
    }
}

/// When Cartouche's signature expires, and for which team.
///
/// SideStore renews an app by installing a new provisioning profile, and
/// leaves the embedded.mobileprovision of the app as its last install wrote
/// it. The built-in SideStore records every renewal for its widget, in
/// widget_data.json in the app group, so the later of the two dates counts.
struct CartoucheSignature {
    let expirationDate: Date?
    let renewalDate: Date?
    let teamName: String?

    /// Whole days left, 0 on the last day, negative once expired.
    var daysLeft: Int? {
        guard let expirationDate else { return nil }
        return Int(floor(expirationDate.timeIntervalSinceNow / 86_400))
    }

    /// Whether Cartouche was renewed since BEFORE was read: SideStore records
    /// the new expiry once it has renewed it, and a profile made later
    /// expires later. Its renewal date alone could also be the installed
    /// profile's, which SideStore takes again when it starts.
    func isRenewal(of before: CartoucheSignature) -> Bool {
        guard let expirationDate else { return false }
        return before.expirationDate.map { expirationDate > $0 } ?? true
    }

    static func current() -> CartoucheSignature {
        let profile = embeddedProfile()
        let renewal = lastRenewal()
        var expirationDate = profile.expirationDate
        if let renewed = renewal?.expirationDate, expirationDate.map({ renewed > $0 }) ?? true {
            expirationDate = renewed
        }
        return CartoucheSignature(expirationDate: expirationDate, renewalDate: renewal?.refreshedDate, teamName: profile.teamName)
    }

    private static func embeddedProfile() -> (expirationDate: Date?, teamName: String?) {
        let url = Bundle.main.bundleURL.appendingPathComponent("embedded.mobileprovision")
        guard let data = try? Data(contentsOf: url),
              let start = data.range(of: Data("<?xml".utf8)),
              let end = data.range(of: Data("</plist>".utf8), in: start.lowerBound..<data.endIndex),
              let plist = try? PropertyListSerialization.propertyList(
                from: data.subdata(in: start.lowerBound..<end.upperBound), format: nil) as? [String: Any] else {
            return (nil, nil)
        }
        return (plist["ExpirationDate"] as? Date, plist["TeamName"] as? String)
    }

    /// SideStore's record of Cartouche, as its widget reads it.
    private struct WidgetData: Decodable {
        struct App: Decodable {
            let bundleIdentifier: String
            let expirationDate: Date
            let refreshedDate: Date
        }
        let allApps: [App]
    }

    private static func lastRenewal() -> WidgetData.App? {
        guard let group = LCSharedUtils.appGroupPath(),
              let ownIdentifier = Bundle.main.bundleIdentifier,
              let data = try? Data(contentsOf: group.appendingPathComponent("widget_data.json")),
              let widget = try? JSONDecoder().decode(WidgetData.self, from: data) else {
            return nil
        }
        // SideStore records Cartouche under the identifier it was built with,
        // without the team identifier that signing adds at the end.
        return widget.allApps
            .filter { ownIdentifier == $0.bundleIdentifier || ownIdentifier.hasPrefix($0.bundleIdentifier + ".") }
            .max { $0.bundleIdentifier.count < $1.bundleIdentifier.count }
    }
}

/// How a game fits this iPhone, from its sheet and what was measured here,
/// in words (CartoucheGameFit holds the rule).
enum CartoucheFit: Hashable {
    /// Testers ran it on this model, and nothing here stands in the way.
    case recommended
    /// Nothing stands in the way, but nobody has tried this model yet.
    case untested
    /// It may start, but the reasons say why it should not be expected to.
    case notRecommended([String])
    /// iOS or the GPU cannot run it.
    case unsupported([String])

    var reasons: [String] {
        switch self {
        case .recommended, .untested: return []
        case .notRecommended(let reasons), .unsupported(let reasons): return reasons
        }
    }

    var title: String {
        switch self {
        case .recommended: return CartoucheText.fitRecommended
        case .untested: return CartoucheText.fitUntested
        case .notRecommended: return CartoucheText.fitNotRecommended
        case .unsupported: return CartoucheText.fitUnsupported
        }
    }

    var isPlayable: Bool {
        switch self {
        case .recommended, .untested: return true
        case .notRecommended, .unsupported: return false
        }
    }

    /// LIMITMIB is the memory the game has here, where Play starts it
    /// (CartoucheGameKeeping.gameLimitMiB).
    static func of(_ sheet: CartoucheGameSheet, limitMiB: Int?) -> CartoucheFit {
        let latest = sheet.results.filter { $0.device == CartoucheDevice.modelIdentifier }.max { $0.date < $1.date }
        return CartoucheFit(CartoucheGameFit.verdict(
            minimumIOS: sheet.requirements.minimumIOS,
            runsMinimumIOS: CartoucheDevice.runsAtLeast(sheet.requirements.minimumIOS),
            readsBCTextures: CartoucheDevice.supportsBCTextureCompression,
            needsIML: sheet.requirements.increasedMemoryLimit, hasIML: CartoucheDevice.hasIncreasedMemoryLimit,
            peakMiB: sheet.peakMemoryMiB, limitMiB: limitMiB, latestHere: latest?.status))
    }

    /// How a game without a sheet fits: nil, unless this iPhone's GPU is
    /// one nxnative refuses for every game.
    static func withoutSheet() -> CartoucheFit? {
        CartoucheGameFit.verdictWithoutSheet(readsBCTextures: CartoucheDevice.supportsBCTextureCompression)
            .map { CartoucheFit($0) }
    }

    private init(_ verdict: CartoucheGameFit.Verdict) {
        switch verdict {
        case .recommended: self = .recommended
        case .untested: self = .untested
        case .notRecommended(let reasons): self = .notRecommended(reasons.map(Self.text))
        case .unsupported(let reasons): self = .unsupported(reasons.map(Self.text))
        }
    }

    private static func text(_ reason: CartoucheGameFit.Reason) -> String {
        switch reason {
        case .iOS(let minimum): return CartoucheText.reasonIOS(minimum)
        case .gpu: return CartoucheText.reasonGPU
        case .increasedMemoryLimit: return CartoucheText.reasonIML
        case .memory(let needed, let limit):
            return CartoucheText.reasonMemory(needed: CartoucheText.mebibytes(needed), limit: CartoucheText.mebibytes(limit))
        case .doesNotRun: return CartoucheText.reasonDoesNotRun
        }
    }
}
