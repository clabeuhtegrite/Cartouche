//
//  CartoucheText.swift
//  Cartouche
//
//  The launcher's words, in Cartouche.xcstrings (English and French). Each
//  call also carries the English text, which shows if a translation is missing.
//

import Foundation

enum CartoucheText {
    static let bundle = Bundle(for: CartoucheCatalog.self)

    static func s(_ key: String, _ english: String) -> String {
        NSLocalizedString(key, tableName: "Cartouche", bundle: bundle, value: english, comment: "")
    }

    static func f(_ key: String, _ english: String, _ arguments: CVarArg...) -> String {
        String(format: s(key, english), locale: Locale.current, arguments: arguments)
    }

    // MARK: Tabs and titles

    static var gamesTab: String { s("tab.games", "Games") }
    static var systemTab: String { s("tab.system", "System") }

    // MARK: Catalogue

    static var emptyMessage: String { s("games.empty.message", "Import the IPA of a supported game that you built on your Mac from your own copy.") }
    static var noSheet: String { s("games.noSheet", "No sheet yet") }
    static var importCopy: String { s("action.import", "Import my copy") }
    static var play: String { s("action.play", "Play") }
    static var done: String { s("action.done", "Done") }

    // MARK: Console

    static var homeLibrary: String { s("home.library", "My library") }
    static var homeIPhone: String { s("home.iphone", "Plays on iPhone") }
    static var importTile: String { s("home.import", "Import a game") }
    static var allGames: String { s("home.all", "All games") }
    static func allGamesDetail(_ count: Int) -> String { f("home.all.detail", "%lld games have a profile in nxnative. Cartouche plays each one from your own copy.", count) }
    static var controllerConnected: String { s("home.controller", "Controller connected") }
    static func daysLeftShort(_ days: Int) -> String { f("home.daysLeft", "%lld\u{00A0}d", days) }
    static var details: String { s("action.details", "Details") }
    static var dockImport: String { s("dock.import", "Import") }
    static var dockApps: String { s("dock.apps", "Apps") }
    static var dockSettings: String { s("dock.settings", "Settings") }
    static var hintOpen: String { s("hint.open", "Open") }
    static var hintFilter: String { s("hint.filter", "Filter") }
    static var hintBack: String { s("hint.back", "Back") }
    static var filterAll: String { s("library.filter.all", "All") }
    static var searchPrompt: String { s("library.search", "Name or title ID") }

    // MARK: Where a game plays

    static var statusReadyShort: String { ready }
    static var statusIPhoneShort: String { s("status.iphone.short", "On iPhone") }
    static var statusMacShort: String { s("status.mac.short", "On Mac") }
    static var statusBringupShort: String { s("status.bringup.short", "In bring-up") }
    static var statusUnknownShort: String { s("status.unknown.short", "Not tried") }
    static var statusIPhoneLong: String { s("status.iphone.long", "nxnative plays it on the iPhone.") }
    static var statusMacLong: String { s("status.mac.long", "nxnative plays it on the Mac; nobody has reported it on an iPhone yet.") }
    static var statusBringupLong: String { s("status.bringup.long", "nxnative is still bringing it up: it may not start yet.") }
    static var statusUnknownLong: String { s("status.unknown.long", "nxnative’s profile does not say where it plays yet.") }

    /// A genre of nxnative.json, or nil for "other".
    static func genre(_ genre: String) -> String? {
        switch genre {
        case "action": return s("genre.action", "Action")
        case "adventure": return s("genre.adventure", "Adventure")
        case "rpg": return s("genre.rpg", "Role-playing")
        case "puzzle": return s("genre.puzzle", "Puzzle")
        case "strategy": return s("genre.strategy", "Strategy")
        case "simulation": return s("genre.simulation", "Simulation")
        case "racing": return s("genre.racing", "Racing")
        case "sports": return s("genre.sports", "Sports")
        case "board": return s("genre.board", "Board game")
        case "card": return s("genre.card", "Card game")
        case "family": return s("genre.family", "Family")
        case "music": return s("genre.music", "Music")
        default: return nil
        }
    }

    // MARK: Fit on this iPhone

    static var ready: String { s("status.ready", "Ready") }
    static var fitRecommended: String { s("status.recommended", "Runs on this iPhone") }
    static var fitUntested: String { s("status.untested", "Not tried on this iPhone yet") }
    static var fitNotRecommended: String { s("status.notRecommended", "Not recommended on this iPhone") }
    static var fitUnsupported: String { s("status.unsupported", "Not supported on this iPhone") }

    static func reasonIOS(_ version: String) -> String { f("reason.ios", "Needs iOS %@ or later.", version) }
    static var reasonGPU: String { s("reason.gpu", "Needs a GPU that reads BC-compressed textures.") }
    static var reasonIML: String { s("reason.iml", "Needs Increased Memory Limit, which is not active for Cartouche yet.") }
    static func reasonMemory(needed: String, limit: String) -> String {
        f("reason.memory", "Needs about %1$@; Cartouche may use %2$@ on this iPhone.", needed, limit)
    }
    static var reasonDoesNotRun: String { s("reason.doesNotRun", "Testers could not run it on this iPhone model.") }

    static func resultStatus(_ status: String) -> String {
        switch status {
        case "playable": return s("result.playable", "Playable")
        case "playable-with-issues": return s("result.playableWithIssues", "Playable with issues")
        case "boots": return s("result.boots", "Starts")
        case "does-not-run": return s("result.doesNotRun", "Does not run")
        default: return status
        }
    }

    static func platform(_ platform: String) -> String {
        switch platform {
        case "switch2": return s("platform.switch2", "Switch 2")
        case "switch": return s("platform.switch", "Switch")
        default: return platform
        }
    }

    // MARK: Game sheet

    static var onThisIPhone: String { s("sheet.onThisIPhone", "On this iPhone") }
    static func iosRequirement(_ version: String) -> String { f("sheet.ios", "iOS %@ or later", version) }
    static func iosCurrent(_ version: String) -> String { f("sheet.ios.current", "This iPhone: iOS %@", version) }
    static var imlRequirement: String { s("sheet.memory.iml", "Increased Memory Limit") }
    static func imlActive(_ limit: String) -> String { f("sheet.memory.iml.active", "Active: %@ for Cartouche", limit) }
    static func imlInactive(_ limit: String) -> String { f("sheet.memory.iml.inactive", "Not active: %@ for Cartouche", limit) }
    static var memoryRequirement: String { s("sheet.memory", "Memory") }
    static func memoryNeeded(_ amount: String) -> String { f("sheet.memory.peak", "Needs about %@", amount) }
    static var bcRequirement: String { s("sheet.gpu.bc", "BC texture compression") }
    static var gpuSupported: String { s("sheet.gpu.supported", "Supported by this GPU") }
    static var gpuUnsupported: String { s("sheet.gpu.unsupported", "Not supported by this GPU") }
    static var recommendedSettings: String { s("sheet.recommended", "Recommended settings") }
    static var resolution: String { s("sheet.resolution", "Resolution") }
    static var mode: String { s("sheet.mode", "Mode") }
    static func modeName(_ mode: String) -> String {
        switch mode {
        case "handheld": return s("sheet.mode.handheld", "Handheld")
        case "docked": return s("sheet.mode.docked", "Docked")
        default: return mode
        }
    }
    static var results: String { s("sheet.results", "Testers’ results") }
    static var noResults: String { s("sheet.results.none", "No result yet.") }
    static var thisModel: String { s("sheet.result.thisModel", "This iPhone model") }
    static func peak(_ amount: String) -> String { f("sheet.result.peak", "Memory peak: %@", amount) }
    static var noSheetMessage: String { s("sheet.noSheet.message", "Cartouche has no sheet for this game yet: it can still start it, without checking what the game needs.") }
    static var sheetNxnative: String { s("sheet.nxnative", "In nxnative") }
    static var sheetEngine: String { s("sheet.engine", "Engine") }
    static var sheetBuild: String { s("sheet.build", "Game version") }
    static var sheetSDK: String { s("sheet.sdk", "SDK") }
    static var sheetTitleID: String { s("sheet.titleID", "Title ID") }
    static func region(_ region: String) -> String {
        switch region {
        case "asia": return s("region.asia", "Asian release")
        case "japan": return s("region.japan", "Japanese release")
        case "korea": return s("region.korea", "Korean release")
        case "china": return s("region.china", "Chinese release")
        default: return region
        }
    }

    // MARK: Setup

    static var setupTitle: String { s("setup.title", "Setup") }
    static var setupIntroTitle: String { s("setup.intro.title", "Before your first game") }
    static var setupIntro: String { s("setup.intro", "Three steps, once on this iPhone. Then Cartouche looks after its certificate and its renewal by itself.") }
    static var setupAllDone: String { s("setup.done.title", "All set") }
    static var setupAllDoneDetail: String { s("setup.done.detail", "Cartouche signs your games and renews itself. There is nothing more to do here.") }
    static func setupStepDone(_ step: String) -> String { f("setup.step.done", "%@, done", step) }
    static var setupPairingTitle: String { s("setup.pairing.title", "Pairing file") }
    static var setupPairingHow: String { s("setup.pairing.how", "Only a computer can make it. In iloader: Manage Pairing File › Export. Drop the file on Cartouche in Apple Devices, iTunes or the Finder (Files), or open it with Cartouche: this step ticks itself. You can also choose it here.") }
    static var setupPairingDone: String { s("setup.pairing.done", "Received. The built-in SideStore uses it to install and renew apps on this iPhone.") }
    static var setupPairingChoose: String { s("setup.pairing.choose", "Choose the file") }
    static var setupPairingReplace: String { s("setup.pairing.replace", "Choose another file") }
    static var setupPairingInvalid: String { s("setup.pairing.invalid", "This file is not a pairing file. Export it again from iloader: Manage Pairing File › Export.") }
    static var setupAppleIDTitle: String { s("setup.appleID.title", "Apple ID") }
    static var setupAppleIDHow: String { s("setup.appleID.how", "Sign in once in the SideStore built into Cartouche: it takes the certificate iloader left for it, and renews Cartouche every week. SideStore has you connect LocalDevVPN, asks for your Apple ID, then brings you back here by itself.") }
    static func setupAppleIDDone(_ appleID: String) -> String { f("setup.appleID.done", "Signed in: %@", appleID) }
    static var setupOpenSideStore: String { s("setup.appleID.open", "Sign in with SideStore") }
    static var setupCertificateTitle: String { s("setup.certificate.title", "Certificate") }
    static var setupCertificateHow: String { s("setup.certificate.how", "Comes by itself once you have signed in. If it does not, install Cartouche again with iloader, over this copy: iloader gives it its certificate.") }
    static var setupCertificateDone: String { s("setup.certificate.done", "Cartouche signs your games with it.") }
    static var setupCheckAgain: String { s("setup.checkAgain", "Check again") }
    static var setupVPNTitle: String { s("setup.vpn.title", "LocalDevVPN, for renewals") }
    static var setupVPNHow: String { s("setup.vpn.how", "SideStore renews Cartouche every 7\u{00A0}days through this free VPN from the App Store, which never leaves this iPhone. Turn it on before a renewal.") }
    static var setupVPNOpen: String { s("setup.vpn.open", "Open LocalDevVPN") }
    static var setupBannerTitle: String { s("setup.banner.title", "Set up Cartouche") }
    static var setupBannerDetail: String { s("setup.banner.detail", "Once, before your first game") }
    static var setupBannerRenewal: String { s("setup.banner.renewal", "Renewal to set up") }
    static var setupBannerRenewalDetail: String { s("setup.banner.renewal.detail", "Add your pairing file") }
    static var setupStatusDone: String { s("setup.status.done", "Done") }
    static var setupStatusToDo: String { s("setup.status.todo", "To do") }

    // MARK: System

    static var memory: String { s("system.memory", "Memory") }
    static var memoryLimit: String { s("system.memory.limit", "Limit for Cartouche") }
    static var memoryUsed: String { s("system.memory.used", "Used now") }
    static var memoryAvailable: String { s("system.memory.available", "Available now") }
    static var imlOn: String { s("system.memory.iml.on", "Active") }
    static var imlOff: String { s("system.memory.iml.off", "Not active") }
    static var measureAgain: String { s("system.memory.measure", "Measure again") }
    static var memoryUnavailable: String { s("system.memory.unavailable", "iOS gives no memory limit here.") }
    static var memoryFooter: String { s("system.memory.footer", "Games run inside Cartouche and share this limit. With Increased Memory Limit, an iPhone with 12 GB of memory allows about 6 GiB.") }
    static func memoryKnown(_ limit: String) -> String { f("system.memory.known", "Testers measured %@ on this model with Increased Memory Limit.", limit) }
    static var signature: String { s("system.signature", "Signature") }
    static var expires: String { s("system.signature.expires", "Expires") }
    static var daysLeft: String { s("system.signature.daysLeft", "Days left") }
    static var expired: String { s("system.signature.expired", "Expired") }
    static var renewed: String { s("system.signature.renewed", "Last renewed") }
    static var team: String { s("system.signature.team", "Apple account team") }
    static var profileUnknown: String { s("system.signature.unknown", "Cartouche could not read its provisioning profile.") }
    static var signatureFooter: String { s("system.signature.footer", "The built-in SideStore renews Cartouche, with LocalDevVPN on. Renew it before it expires: an expired Cartouche no longer opens, and has to be installed again from a computer with iloader.") }
    static var openSideStore: String { s("system.signature.openSideStore", "Open SideStore") }
    static var renewNow: String { s("system.signature.renew", "Renew now") }
    static var renewing: String { s("system.signature.renewing", "Renewing…") }
    static var renewUnavailable: String { s("system.signature.renew.unavailable", "The built-in SideStore is not loaded. Open it to renew Cartouche.") }
    static var automaticRenewal: String { s("system.auto", "Automatic renewal") }
    static var renewEveryNight: String { s("system.auto.daily", "Renew every night") }
    static var alerts: String { s("system.auto.alerts", "Expiry alerts") }
    static var alertsOn: String { s("system.auto.alerts.on", "On") }
    static var alertsTurnOn: String { s("system.auto.alerts.turnOn", "Turn on") }
    static var alertsInSettings: String { s("system.auto.alerts.settings", "Turn on in Settings") }
    static var automaticRenewalFooter: String { s("system.auto.footer", "With alerts on, Cartouche warns you 24 hours and 6 hours before it expires.") }
    static var thisIPhone: String { s("system.device", "This iPhone") }
    static var model: String { s("system.device.model", "Model") }
    static var chip: String { s("system.device.chip", "Chip") }
    static var ram: String { s("system.device.ram", "Memory") }
    static var version: String { s("system.cartouche.version", "Version") }
    static var basedOn: String { s("system.cartouche.basedOn", "Based on") }
    static var sheets: String { s("system.cartouche.sheets", "Game sheets") }

    // MARK: Lab (spike S2)

    static var labTitle: String { s("lab.title", "Lab") }
    static var labFooter: String { s("lab.footer", "Tests for building games on the iPhone later, from your own copy.") }
    static var labRewrite: String { s("lab.rewrite", "Rewrite a game’s modules") }
    static var labIntro: String { s("lab.intro", "Cartouche rewrites the code of your own game on this iPhone with nxnative’s rewriter, as your Mac does when it builds the game’s IPA, then compares each file with the one your Mac wrote. It also measures the time and the memory this takes.") }
    static var labFolderTitle: String { s("lab.folder.title", "Your game’s files") }
    static var labFolder: String { s("lab.folder", "Folder") }
    static var labModules: String { s("lab.modules", "Modules") }
    static var labReference: String { s("lab.reference", "Mac’s list") }
    static var labReferenceNone: String { s("lab.reference.none", "None: nothing to compare with") }
    static var labNoModules: String { s("lab.noModules", "No main module in this folder or in its ExeFS folder.") }
    static var labChoose: String { s("lab.choose", "Choose the folder") }
    static var labFolderFooter: String { s("lab.folder.footer", "Choose a folder that holds your game’s ExeFS folder, or its modules (main, subsdk0, sdk…), with mac.sha256, the list of the files your Mac’s build wrote. Cartouche copies the modules, then writes into this folder its report, its own list, iphone.sha256, and the rewriter’s log.") }
    static var labRun: String { s("lab.run", "Rewrite") }
    static var labRunFooter: String { s("lab.run.footer", "Keep Cartouche open with the screen on until the end: iOS pauses an app in the background. A large game can take several minutes.") }
    static var labCopying: String { s("lab.copying", "Copying the modules…") }
    static var labStarting: String { s("lab.starting", "Starting Python…") }
    static func labRewriting(_ module: String) -> String { f("lab.rewriting", "Rewriting %@", module) }
    static var labElapsed: String { s("lab.elapsed", "Time") }
    static var labMemoryNow: String { s("lab.memory.now", "Memory used") }
    static var labPeakMemory: String { s("lab.memory.peak", "Memory peak") }
    static func labMemoryOf(_ used: String, _ limit: String) -> String { f("lab.memory.of", "%1$@ of %2$@", used, limit) }
    static var labInterrupted: String { s("lab.interrupted", "The last rewrite did not finish: iOS closed Cartouche, perhaps for lack of memory. Its report, in the folder, gives the last memory reading.") }
    static var labStopped: String { s("lab.stopped", "The rewrite stopped.") }
    static var labNoPython: String { s("lab.noPython", "This build of Cartouche does not carry Python.") }
    static func labPythonFailed(_ reason: String) -> String { f("lab.python.failed", "Python did not start: %@", reason) }
    static func labPythonError(_ reason: String) -> String { f("lab.python.error", "Python stopped: %@", reason) }
    static func labCopyFailed(_ name: String, _ reason: String) -> String { f("lab.copy.failed", "Could not copy %1$@: %2$@", name, reason) }
    static var labResult: String { s("lab.result", "Result") }
    static var labGame: String { s("lab.game", "Game") }
    static var labGameUnknown: String { s("lab.game.unknown", "No nxnative profile: every module rewritten") }
    static func labSame(_ same: Int, _ files: Int) -> String { f("lab.same", "%1$lld of %2$lld files identical to the Mac’s", same, files) }
    static var labWritten: String { s("lab.written", "Files written") }
    static var labDifferent: String { s("lab.different", "Different from the Mac’s") }
    static var labAbsent: String { s("lab.absent", "Not on the Mac’s list") }
    static var labOnlyOnMac: String { s("lab.onlyOnMac", "Written by the Mac only") }
    static var labFileSame: String { s("lab.file.same", "Identical to the Mac’s") }
    static var labWaiting: String { s("lab.waiting", "Waiting") }
    static var labTotal: String { s("lab.total", "Total") }
    static func labReportExported(_ name: String) -> String { f("lab.report.exported", "Report written into the folder: %@", name) }
    static var labReportKept: String { s("lab.report.kept", "Cartouche could not write into the folder: the report stays in Cartouche’s files, under Cartouche/Lab/S2.") }
    static var labFiles: String { s("lab.files", "Files") }
    static var labRuntime: String { s("lab.runtime", "In this build") }

    // MARK: Renewing every night

    static var dailyIntro: String { s("daily.intro", "An automation in Shortcuts can renew Cartouche every night, with no computer. It runs Cartouche’s Refresh All Apps action, which does what Renew now does.") }
    static var dailyStepVPN: String { s("daily.step1", "Leave LocalDevVPN connected. Its traffic stays on the iPhone, so it can stay on all day.") }
    static var dailyStepAutomation: String { s("daily.step2", "In Shortcuts, open Automation, then tap +.") }
    static var dailyStepTime: String { s("daily.step3", "Choose Time of Day: a time when the iPhone charges and is online, such as 4 AM, every day. Then choose Run Immediately.") }
    static var dailyStepAction: String { s("daily.step4", "Tap Next, choose New Blank Automation, and add the Refresh All Apps action of Cartouche, not LiveContainer’s.") }
    static var dailyStepCheck: String { s("daily.step5", "Each renewal shows in the System tab as the last renewal, and gives Cartouche seven more days.") }
    static var openShortcuts: String { s("daily.openShortcuts", "Open Shortcuts") }

    // MARK: Warnings before expiry

    static var warning24hTitle: String { s("warning.24h.title", "Cartouche expires in 24 hours") }
    static var warning6hTitle: String { s("warning.6h.title", "Cartouche expires in 6 hours") }
    static var warningBody: String { s("warning.body", "Renew it in the System tab, with LocalDevVPN connected.") }
    static var warningExpiredTitle: String { s("warning.0h.title", "Cartouche has expired") }
    static var warningExpiredBody: String { s("warning.0h.body", "Install it again from a computer with iloader, over this copy: your games stay.") }

    // MARK: Units

    static func mebibytes(_ value: Int) -> String {
        f("unit.mib", "%@\u{00A0}MiB", grouped(value))
    }

    static func gigabytes(_ value: Int) -> String {
        f("unit.gb", "%@\u{00A0}GB", grouped(value))
    }

    /// "6,143 MiB (6.0 GiB)", with the reader's separators.
    static func memoryAmount(mebibytes value: Int) -> String {
        let gibibytes = Double(value) / 1024
        let formatter = NumberFormatter()
        formatter.locale = Locale.current
        formatter.minimumFractionDigits = 1
        formatter.maximumFractionDigits = 1
        let gib = formatter.string(from: NSNumber(value: gibibytes)) ?? String(format: "%.1f", gibibytes)
        return mebibytes(value) + " (" + f("unit.gib", "%@\u{00A0}GiB", gib) + ")"
    }

    private static func grouped(_ value: Int) -> String {
        let formatter = NumberFormatter()
        formatter.locale = Locale.current
        formatter.numberStyle = .decimal
        return formatter.string(from: NSNumber(value: value)) ?? String(value)
    }
}
