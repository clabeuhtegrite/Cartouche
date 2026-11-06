//
//  CartoucheDevice.swift
//  Cartouche
//
//  What this iPhone gives a game: its model, iOS version, GPU, the memory
//  limit iOS sets for Cartouche (games run inside Cartouche and share it),
//  and how long Cartouche's signature lasts.
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
    /// consoles use.
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
        // That iPhone with Increased Memory Limit, as Cartouche's home finds it.
        return CartoucheMemoryReading(footprintBytes: 96 << 20, availableBytes: (6_143 - 96) << 20)
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

/// How a game fits this iPhone, from its sheet and what was measured here.
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

    static func of(_ sheet: CartoucheGameSheet, memory: CartoucheMemoryReading?) -> CartoucheFit {
        var blockers: [String] = []
        if !CartoucheDevice.runsAtLeast(sheet.requirements.minimumIOS) {
            blockers.append(CartoucheText.reasonIOS(sheet.requirements.minimumIOS))
        }
        if sheet.requirements.bcTextureCompression && !CartoucheDevice.supportsBCTextureCompression {
            blockers.append(CartoucheText.reasonGPU)
        }
        if !blockers.isEmpty { return .unsupported(blockers) }

        var warnings: [String] = []
        if sheet.requirements.increasedMemoryLimit && !CartoucheDevice.hasIncreasedMemoryLimit {
            warnings.append(CartoucheText.reasonIML)
        }
        if let peak = sheet.peakMemoryMiB, let memory, peak > memory.limitMiB {
            warnings.append(CartoucheText.reasonMemory(
                needed: CartoucheText.mebibytes(peak), limit: CartoucheText.mebibytes(memory.limitMiB)))
        }
        let here = sheet.results.filter { $0.device == CartoucheDevice.modelIdentifier }
        let latest = here.max { $0.date < $1.date }
        if latest?.status == "does-not-run" {
            warnings.append(CartoucheText.reasonDoesNotRun)
        }
        if !warnings.isEmpty { return .notRecommended(warnings) }
        if let latest, latest.status == "playable" || latest.status == "playable-with-issues" {
            return .recommended
        }
        return .untested
    }
}
