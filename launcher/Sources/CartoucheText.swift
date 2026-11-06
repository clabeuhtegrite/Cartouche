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
    static var needsNewerIOS: String { s("app.needsIOS17", "Cartouche needs iOS 17 or later.") }

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
    static var statusIPhoneLong: String { s("status.iphone.long", "nxnative plays it on the iPhone and the Mac.") }
    static var statusMacLong: String { s("status.mac.long", "nxnative plays it on the Mac; nobody has reported it on an iPhone yet.") }
    static var statusBringupLong: String { s("status.bringup.long", "nxnative is still bringing it up: it may not start yet.") }
    static var statusUnknownLong: String { s("status.unknown.long", "nxnative’s profile does not say where it plays yet.") }
    static var statusStoredShort: String { s("status.stored.short", "In storage") }
    static var statusStoredLong: String { s("status.stored.long", "Its IPA is in your games folder: install it to play it on this iPhone.") }

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
    static var setupPairingHow: String { s("setup.pairing.how", "Only a computer can make it. The Cartouche Installer puts it in Cartouche when it installs it, from a Mac or a Windows PC: this step then ticks itself. A pairing file dropped on Cartouche in Apple Devices, iTunes or the Finder (Files), or opened with Cartouche, ticks it too. You can also choose it here.") }
    static var setupPairingDone: String { s("setup.pairing.done", "Received. The built-in SideStore uses it to install and renew apps on this iPhone.") }
    static var setupPairingChoose: String { s("setup.pairing.choose", "Choose the file") }
    static var setupPairingReplace: String { s("setup.pairing.replace", "Choose another file") }
    static var setupPairingInvalid: String { s("setup.pairing.invalid", "This file is not a pairing file. The Cartouche Installer puts the right one in Cartouche: Put the pairing file in Cartouche again.") }
    static var setupAppleIDTitle: String { s("setup.appleID.title", "Apple ID") }
    static var setupAppleIDHow: String { s("setup.appleID.how", "Sign in once with your Apple ID, here in Cartouche: the built-in SideStore then takes the certificate the Cartouche Installer left for it, and renews Cartouche every week, without showing itself. Connect LocalDevVPN first.") }
    static func setupAppleIDDone(_ appleID: String) -> String { f("setup.appleID.done", "Signed in: %@", appleID) }
    static var setupSignIn: String { s("setup.appleID.signIn", "Sign In") }
    static var setupCertificateTitle: String { s("setup.certificate.title", "Certificate") }
    static var setupCertificateHow: String { s("setup.certificate.how", "Comes by itself once you have signed in. If it does not, install Cartouche again with the Cartouche Installer, over this copy: it gives Cartouche its certificate.") }
    static var setupCertificateDone: String { s("setup.certificate.done", "Cartouche signs your games with it.") }
    static var setupCertificateChecking: String { s("setup.certificate.checking", "Cartouche checks that iOS accepts it.") }
    static var setupCertificateRefused: String { s("setup.certificate.refused", "iOS no longer accepts it: an install from another computer may have revoked it. Sign in again with your Apple ID, and the built-in SideStore takes the certificate that signs Cartouche.") }
    static var setupCertificateRenewing: String { s("setup.certificate.renewing", "iOS no longer accepts it. Cartouche signs in again with your Apple ID to take the certificate that signs Cartouche…") }
    static var setupCheckAgain: String { s("setup.checkAgain", "Check again") }
    static var setupVPNTitle: String { s("setup.vpn.title", "LocalDevVPN, for renewals") }
    static var setupVPNHow: String { s("setup.vpn.how", "SideStore renews Cartouche every 7\u{00A0}days through this free VPN from the App Store, which never leaves this iPhone. Turn it on before a renewal.") }
    static var setupVPNOpen: String { s("setup.vpn.open", "Open LocalDevVPN") }
    static var setupBannerTitle: String { s("setup.banner.title", "Set up Cartouche") }
    static var setupBannerDetail: String { s("setup.banner.detail", "Once, before your first game") }
    static var setupBannerRenewal: String { s("setup.banner.renewal", "Renewal to set up") }
    static var setupBannerRenewalDetail: String { s("setup.banner.renewal.detail", "Add your pairing file") }
    static var setupBannerSignInDetail: String { s("setup.banner.renewal.signIn", "Sign in with your Apple ID") }
    static var setupBannerCertificate: String { s("setup.banner.certificate", "The certificate no longer works") }
    static var setupBannerCertificateDetail: String { s("setup.banner.certificate.detail", "Sign in again to play") }
    static var setupBannerCertificateRenewing: String { s("setup.banner.certificate.renewing", "Cartouche signs in again…") }
    static var setupStatusDone: String { s("setup.status.done", "Done") }
    static var setupStatusToDo: String { s("setup.status.todo", "To do") }

    // MARK: The Apple ID sign-in

    static var signInTitle: String { s("signIn.title", "Sign in with your Apple ID") }
    static var signInIntro: String { s("signIn.intro", "Once on this iPhone. The SideStore built into Cartouche signs in with it without showing itself: it registers this iPhone with your account, takes the certificate the Cartouche Installer left for it, and renews Cartouche every week.") }
    static var signInAppleID: String { s("signIn.appleID", "Apple ID (email or phone number)") }
    static var signInPassword: String { s("signIn.password", "Password") }
    static var signInFreeAccount: String { s("signIn.freeAccount", "A free Apple ID will do. Your password goes to Apple only, and stays in this iPhone’s keychain for the renewals.") }
    static var signInButton: String { s("signIn.button", "Sign In") }
    static var signInAgain: String { s("signIn.again", "Sign in again") }
    static var signInWorking: String { s("signIn.working", "Signing in, registering this iPhone and fetching the certificate…") }
    static var signInCodeTitle: String { s("signIn.code.title", "Verification code") }
    static var signInCodeTrustedDevice: String { s("signIn.code.trustedDevice", "Apple sent a code to your other Apple devices. Allow the sign-in there, then type the code here.") }
    static func signInCodeSMS(_ phone: String) -> String { f("signIn.code.sms", "Apple sent a code by text message to %@.", phone) }
    static var signInCodeSMSAnyNumber: String { s("signIn.code.sms.any", "Apple sent a code by text message to your phone number.") }
    static func signInCodeVoice(_ phone: String) -> String { f("signIn.code.voice", "Apple is calling %@ with a code.", phone) }
    static var signInCodeVoiceAnyNumber: String { s("signIn.code.voice.any", "Apple is calling your phone number with a code.") }
    static var signInCodePlaceholder: String { s("signIn.code.placeholder", "6-digit code") }
    static var signInCodeContinue: String { s("signIn.code.continue", "Continue") }
    static var signInCodeBySMS: String { s("signIn.code.bySMS", "Get a text message instead") }
    static var signInCodeByDevice: String { s("signIn.code.byDevice", "Send it to my Apple devices") }
    static var signInFailedTitle: String { s("signIn.failed.title", "The sign-in did not go through") }
    static var signInOpenPage: String { s("signIn.openPage", "Open the page") }
    static var signInVPNTitle: String { s("signIn.vpn.title", "Connect LocalDevVPN first") }
    static var signInVPNHow: String { s("signIn.vpn.how", "SideStore reaches this iPhone through it to register it with your account, as it does for each renewal.") }
    static var signInUnavailable: String { s("signIn.unavailable", "The built-in SideStore did not load. Close Cartouche, open it again, then sign in.") }
    static var signInKeychainFailed: String { s("signIn.keychainFailed", "Cartouche could not hand your Apple ID to the built-in SideStore. Try again.") }

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
    static var signatureFooter: String { s("system.signature.footer", "The built-in SideStore renews Cartouche, with LocalDevVPN on. Renew it before it expires: an expired Cartouche no longer opens, and has to be installed again from a computer with the Cartouche Installer.") }
    static var renewNow: String { s("system.signature.renew", "Renew now") }
    static var renewing: String { s("system.signature.renewing", "Renewing…") }
    static var renewUnavailable: String { s("system.signature.renew.unavailable", "The built-in SideStore did not load. Close Cartouche, open it again, then renew.") }
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
    static var coversCredit: String { s("system.covers.credit", "Covers and artworks of the games: IGDB.com.") }

    // MARK: Cartouche's updates

    static var updatesTitle: String { s("system.updates", "Updates") }
    static var updatesFooter: String { s("system.updates.footer", "The built-in SideStore installs Cartouche’s new versions without a computer, with LocalDevVPN connected, as it renews Cartouche. Cartouche then closes for iOS to install it: open it again. Your games and their saves stay.") }
    static var updateAvailable: String { s("system.updates.available", "New version") }
    static func updateTo(_ version: String) -> String { f("system.updates.install", "Install Cartouche %@", version) }
    static var updateNeedsSetup: String { s("system.updates.needsSetup", "Finish setting up Cartouche first: the built-in SideStore needs your Apple ID, its certificate and the pairing file.") }
    static var updateNotes: String { s("system.updates.notes", "What’s new") }
    static func updateUpToDate(_ version: String) -> String { f("system.updates.upToDate", "Cartouche %@ is the latest version.", version) }
    static var updateNotChecked: String { s("system.updates.notChecked", "Cartouche has not looked for an update yet.") }
    static var updateCheck: String { s("system.updates.check", "Check for an update") }
    static func updateCheckFailed(_ reason: String) -> String { f("updates.check.failed", "Cartouche could not look for an update: %@", reason) }
    static func updateSourceStatus(_ status: Int) -> String { f("updates.source.status", "its source answered with error %lld.", status) }
    static var updateUnavailable: String { s("updates.unavailable", "The built-in SideStore did not load. Close Cartouche, open it again, then update.") }
    static func updateOfferTitle(_ version: String) -> String { f("updates.offer.title", "Cartouche %@ is available", version) }
    static func updateOfferMessage(_ running: String) -> String { f("updates.offer.message", "You have version %@. The built-in SideStore installs the new one without a computer, with LocalDevVPN connected. Cartouche then closes for iOS to install it: open it again. Your games and their saves stay.", running) }
    static func updateSize(_ size: String) -> String { f("updates.offer.size", "Download: %@", size) }
    static var updateNow: String { s("updates.now", "Update") }
    static var updateLater: String { s("updates.later", "Later") }
    static func updatePreparingTitle(_ version: String) -> String { f("updates.preparing.title", "Updating to Cartouche %@", version) }
    static var updatePreparingMessage: String { s("updates.preparing.message", "The built-in SideStore downloads the new version, checks it and signs it. Keep Cartouche open.") }
    static func updateInstallingTitle(_ version: String) -> String { f("updates.installing.title", "Installing Cartouche %@", version) }
    static var updateInstallingMessage: String { s("updates.installing.message", "Cartouche goes to the home screen for iOS to install the new version. Open it again in a few seconds.") }
    static var updateLeaveNow: String { s("updates.leave", "Go to the home screen") }
    static func updateInstalledTitle(_ version: String) -> String { f("updates.installed.title", "Cartouche %@ is installed", version) }
    static var updateInstalledMessage: String { s("updates.installed.message", "Close Cartouche and open it again to use the new version.") }
    static var updateFailedTitle: String { s("updates.failed.title", "The update did not go through") }
    static func updateFailed(_ reason: String) -> String { f("updates.failed.message", "Check that LocalDevVPN is connected, then try again from the System page. SideStore says: %@", reason) }
    static var updateUnfinishedTitle: String { s("updates.unfinished.title", "The update did not finish") }
    static func updateUnfinished(_ version: String) -> String { f("updates.unfinished.message", "Cartouche closed before version %@ was installed. Try again from the System page, with LocalDevVPN connected.", version) }
    static var updatedMessage: String { s("updates.done.message", "Your games, their saves and Cartouche’s settings are all still here.") }

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
    static var dailyStepCheck: String { s("daily.step5", "Each renewal shows on the System page as the last renewal, and gives Cartouche seven more days.") }
    static var openShortcuts: String { s("daily.openShortcuts", "Open Shortcuts") }

    // MARK: Installing, starting and uninstalling a game

    static func installTitle(_ name: String) -> String { f("work.install.title", "Installing %@", name) }
    static var installUnpacking: String { s("work.install.unpacking", "Unpacking the IPA. Keep Cartouche open: a large game takes a few minutes.") }
    static var installSigning: String { s("work.signing", "Signing it for this iPhone") }
    static var installFailed: String { s("work.install.failed", "The game was not installed") }
    static var installSignWarning: String { s("work.install.signWarning", "Installed, but not signed") }
    static var installDone: String { s("work.install.done", "Installed") }
    static func installNotAGame(_ name: String) -> String { f("work.install.notAGame", "%@ is not an nxnative game: you will find it in Apps.", name) }
    static func installNoSpace(needed: String, free: String) -> String {
        f("work.install.noSpace", "Installing this game takes about %1$@ of free space, and this iPhone has %2$@. Free some space, then import it again.", needed, free)
    }
    static func startTitle(_ name: String) -> String { f("work.start.title", "Starting %@", name) }
    static var startSoon: String { s("work.start.soon", "The game opens in a moment.") }
    static var startSettings: String { s("work.start.settings", "The game opens on its settings: its Play button starts it and keeps your choices.") }
    static var startFailed: String { s("work.start.failed", "The game did not start") }
    static var startCertificateRefused: String { s("work.start.certificateRefused", "iOS no longer accepts the certificate the game was signed with. Cartouche signs in again with your Apple ID to take the new one: try again in a moment.") }
    static func uninstallTitle(_ name: String) -> String { f("work.uninstall.title", "Uninstalling %@", name) }
    static var uninstallStep: String { s("work.uninstall.step", "Removing it from this iPhone") }
    static var uninstallFailed: String { s("work.uninstall.failed", "The game was not uninstalled") }
    static func installFromStorageStep(_ server: String) -> String { f("work.install.stored", "Unpacking it from %@ as it arrives. Keep Cartouche open: a large game takes several minutes.", server) }
    static func installFromStorageNoSpace(needed: String, free: String) -> String {
        f("work.install.stored.noSpace", "Installing this game takes about %1$@ of free space, and this iPhone has %2$@. Free some space, then install it again.", needed, free)
    }
    static func exportTitle(_ name: String) -> String { f("work.export.title", "Copying %@", name) }
    static func exportStep(_ server: String) -> String { f("work.export.step", "Copying it to %@. Keep Cartouche open: a large game takes several minutes.", server) }
    static var exportFailed: String { s("work.export.failed", "The game was not copied") }
    static func exportNoSpace(needed: String, server: String, free: String) -> String {
        f("work.export.noSpace", "The copy takes about %1$@, and %2$@ has %3$@ free. Free some space there, then copy the game again.", needed, server, free)
    }
    static var exportUnreadable: String { s("work.export.unreadable", "Cartouche could not read the installed game.") }
    static var savesFinishing: String { s("work.start.saves", "Cartouche first finishes copying your saves.") }

    static var gameSettings: String { s("action.gameSettings", "Game settings") }
    static var uninstall: String { s("action.uninstall", "Uninstall") }
    static var cancel: String { s("action.cancel", "Cancel") }
    static func uninstallQuestion(_ name: String) -> String { f("uninstall.question", "Uninstall %@?", name) }
    static var uninstallMessage: String { s("uninstall.message", "Your saves can stay on this iPhone: the game finds them again the next time you import it.") }
    static var uninstallKeepSaves: String { s("uninstall.keep", "Uninstall, keep my saves") }
    static var uninstallEraseSaves: String { s("uninstall.erase", "Uninstall and erase my saves") }
    static func uninstallCopyFirst(_ server: String) -> String { f("uninstall.copyFirst", "Copy to %@, then uninstall", server) }
    static func uninstallMessageStored(_ server: String) -> String { f("uninstall.message.stored", "The game stays in %@, ready to install again. Your saves can stay on this iPhone: the game finds them again.", server) }
    static func installFrom(_ server: String) -> String { f("action.installFrom", "Install from %@", server) }
    static var importOtherCopy: String { s("action.importOther", "Import another copy") }
    static func exportTo(_ server: String) -> String { f("action.exportTo", "Copy to %@", server) }
    static func storedIn(_ server: String, _ file: String) -> String { f("sheet.storedIn", "A copy is in %1$@: %2$@", server, file) }

    // MARK: The player's storage

    static var storageTitle: String { s("storage.title", "Storage") }
    static var storageIntro: String { s("storage.intro", "Keep your games and your saves on your own storage: a shared folder of your Mac, PC or NAS, or a folder in Files. The games there show in your library, ready to install again.") }
    static var storageNotSet: String { s("storage.notSet", "Not set up") }
    static var storageGamesFolder: String { s("storage.games", "Games folder") }
    static var storageSavesFolder: String { s("storage.saves", "Saves folder") }
    static var storageGamesFound: String { s("storage.games.found", "Games found") }
    static var storageReadAgain: String { s("storage.readAgain", "Read the folder again") }
    static var storageChangeFolder: String { s("storage.changeFolder", "Change folder") }
    static var storageStopUsing: String { s("storage.stopUsing", "Stop using this folder") }
    static var storageAddFirst: String { s("storage.addFirst", "First add a shared folder or a folder in Files, below.") }
    static var storageChooseFolder: String { s("storage.chooseFolder", "Choose a folder") }
    static var storageGamesFooter: String { s("storage.games.footer", "Your library lists the IPAs in this folder, and Cartouche installs them from there. Copy a game here before you uninstall it to keep it a tap away.") }
    static var storageServers: String { s("storage.servers", "Places") }
    static var storageServersFooter: String { s("storage.servers.footer", "Only storage of your own, with your own account: Cartouche keeps the password in this iPhone’s keychain.") }
    static var storageAddSMB: String { s("storage.addSMB", "Add a shared folder (SMB)") }
    static var storageAddFolder: String { s("storage.addFolder", "Add a folder in Files") }
    static var storageRemove: String { s("storage.remove", "Remove") }
    static var storageGuest: String { s("storage.guest", "guest") }
    static var storageFilesFolder: String { s("storage.filesFolder", "Folder in Files") }
    static var storageNearby: String { s("storage.nearby", "On this network") }
    static var storageAccount: String { s("storage.account", "Account") }
    static var storageHost: String { s("storage.host", "Address (name or IP)") }
    static var storageUser: String { s("storage.user", "User name") }
    static var storagePassword: String { s("storage.password", "Password") }
    static var storagePasswordKept: String { s("storage.password.kept", "Password (leave empty to keep it)") }
    static var storageAccountFooter: String { s("storage.account.footer", "The account of your Mac, PC or NAS. Leave the user name empty to sign in as a guest.") }
    static var storageConnect: String { s("storage.connect", "Sign in and list the shared folders") }
    static var storageNoShares: String { s("storage.noShares", "This account sees no shared folder there.") }
    static var storageShare: String { s("storage.share", "Shared folder") }
    static var storageShareFooter: String { s("storage.share.footer", "On a Mac: System Settings › General › Sharing › File Sharing. On a PC: the folder’s Properties › Sharing.") }
    static var storageNameTitle: String { s("storage.name.title", "Name in Cartouche") }
    static var storageName: String { s("storage.name", "Name") }
    static var storageSave: String { s("storage.save", "Save") }
    static var storageUseThisFolder: String { s("storage.useThisFolder", "Use this folder") }
    static var storageNoFolders: String { s("storage.noFolders", "No folder here.") }
    static var storageNewFolder: String { s("storage.newFolder", "New folder") }
    static var storageCreate: String { s("storage.create", "Create") }
    static var storageFolderGone: String { s("storage.folderGone", "Cartouche can no longer open this folder. Remove it, then add it again.") }
    static var storageNotAnApp: String { s("storage.notAnApp", "This file is not an app’s IPA.") }
    static var storageReadOnlyGames: String { s("storage.readOnly.games", "Read-only for your account: Cartouche installs the games in this folder, but cannot copy any there.") }
    static var storageReadOnlySaves: String { s("storage.readOnly.saves", "Read-only for your account: Cartouche cannot copy your saves here. Choose a folder you can write to.") }
    static func storageReadOnlyServer(_ name: String) -> String { f("storage.readOnly.server", "%@ (read-only)", name) }
    static func exportReadOnly(_ server: String) -> String { f("work.export.readOnly", "Your account on %@ can only read the games folder: Cartouche cannot copy the game there.", server) }
    static func storageSavesFooter(_ kept: Int) -> String { f("storage.saves.footer", "After each game, Cartouche copies the game’s saves here, in a folder per game, and keeps the %lld newest copies.", kept) }
    static func storageSignInFailed(_ host: String, _ reason: String) -> String { f("storage.signInFailed", "Cartouche could not sign in to %1$@: %2$@", host, reason) }
    static func storageTooLarge(_ name: String) -> String { f("storage.tooLarge", "%@ is larger than Cartouche expects.", name) }

    // MARK: A game's saves

    static var savesTitle: String { s("saves.title", "Saves") }
    static var savesLastCopy: String { s("saves.lastCopy", "Last copy") }
    static var savesNoCopy: String { s("saves.noCopy", "None yet") }
    static var savesPutBack: String { s("saves.putBack", "Put back a copy") }
    static var savesNoFolder: String { s("saves.noFolder", "Choose a saves folder in System › Storage: Cartouche will copy this game’s saves there after each game.") }
    static var savesPutBackFooter: String { s("saves.putBack.footer", "Putting back a copy replaces this game’s saves on this iPhone. Cartouche copies the current ones first.") }
    static var savesPutBackQuestion: String { s("saves.putBack.question", "Put back this copy?") }
    static var savesPutBackMessage: String { s("saves.putBack.message", "It replaces the game’s saves on this iPhone. Cartouche copies them first, so you can come back to them.") }
    static var savesCopyUnreadable: String { s("saves.unreadable", "This copy cannot be read: it is incomplete, or holds more than a game’s saves.") }
    static var savesReadOnly: String { s("saves.readOnly", "Your saves folder is read-only for your account: choose another one in System › Storage.") }
    static func savesCopyNow(_ server: String) -> String { f("saves.copyNow", "Copy to %@ now", server) }
    static func savesFooter(_ kept: Int) -> String { f("saves.footer", "After each game, Cartouche copies these saves to your saves folder and keeps the %lld newest copies.", kept) }
    static func savesPutBackAction(_ date: String) -> String { f("saves.putBack.action", "Put back the copy of %@", date) }
    static func savesPutBackDone(_ date: String) -> String { f("saves.putBack.done", "The copy of %@ is back in place.", date) }

    // MARK: A game's settings

    static var settingsIntro: String { s("settings.intro", "The settings nxnative’s screen shows before this game. Play starts the game with them, and its in-game menu changes the same ones.") }
    static var settingsNone: String { s("settings.none", "This game has no settings to choose.") }
    static var settingsUnreachable: String { s("settings.unreachable", "Cartouche cannot open this game’s settings. Start it on nxnative’s screen to choose them.") }
    static var settingsReset: String { s("settings.reset", "Reset to tested defaults") }
    static var settingsResetFooter: String { s("settings.reset.footer", "Brings back all the settings this game was tested with.") }
    static var settingsNxnativeScreen: String { s("settings.nxnativeScreen", "Start on nxnative’s screen") }
    static var settingsNxnativeScreenFooter: String { s("settings.nxnativeScreen.footer", "Starts the game on nxnative’s own settings screen, in English, with these choices: its Play button starts the game.") }
    static var settingFixed: String { s("settings.fixed", "Set by an env.txt file") }
    static var cloudTitle: String { s("settings.cloud", "Cloud saves") }
    /// The cloud saves' category, a word on a button.
    static var settingsSaves: String { s("settings.category.saves", "Saves") }
    static var cloudOff: String { s("settings.cloud.off", "Off") }
    static var cloudChoose: String { s("settings.cloud.choose", "Choose a folder in iCloud Drive…") }
    static var cloudChange: String { s("settings.cloud.change", "Choose a different folder…") }
    static var cloudTurnOff: String { s("settings.cloud.turnOff", "Turn off cloud saves") }
    static var cloudFooter: String { s("settings.cloud.footer", "Choose a folder in iCloud Drive, and the same one in the Mac app’s Cloud saves. The save comes in when the game starts and goes out after each save; a save that is replaced is kept in save-backups.") }
    static var cloudSaved: String { s("settings.cloud.saved", "Saved. The game uses this folder when you press Play.") }
    static var cloudStale: String { s("settings.cloud.stale", "The folder you chose before can no longer be read: the app was signed differently. Choose it again.") }
    static var cloudFailed: String { s("settings.cloud.failed", "That folder could not be remembered: try a different one.") }

    /// A text of nxnative's settings list (a game's dm/launcher.json, from
    /// nxnative's settings.tsv) in the reader's language: a section, a
    /// setting's name or note, or an option. A text Cartouche does not know
    /// shows as nxnative wrote it.
    static func gameSettingText(_ text: String) -> String {
        switch text {
        case "Game": return s("setting.section.game", "Game")
        case "Controls": return s("setting.section.controls", "Controls")
        case "Performance": return s("setting.section.performance", "Performance")

        case "Frame rate": return s("setting.frameRate", "Frame rate")
        case "Dynamic resolution": return s("setting.dynamicResolution", "Dynamic resolution")
        case "Render scale": return s("setting.renderScale", "Render scale")
        case "Console mode": return s("setting.consoleMode", "Console mode")
        case "Upscaling": return s("setting.upscaling", "Upscaling")
        case "Game's upscaler": return s("setting.gameUpscaler", "Game’s upscaler")
        case "Game language": return s("setting.language", "Game language")
        case "Picture": return s("setting.picture", "Picture")
        case "Frame-rate counter": return s("setting.fpsCounter", "Frame-rate counter")
        case "Touch feedback": return s("setting.touchFeedback", "Touch feedback")
        case "Game rumble": return s("setting.rumble", "Game rumble")
        case "Rumble strength": return s("setting.rumbleStrength", "Rumble strength")
        case "Rumble cutoff": return s("setting.rumbleCutoff", "Rumble cutoff")
        case "Picture shape": return s("setting.pictureShape", "Picture shape")
        case "Frame buffering": return s("setting.frameBuffering", "Frame buffering")
        case "Metal 4 pipelines": return s("setting.metal4", "Metal 4 pipelines")
        case "Pipeline prebuild": return s("setting.prebuild", "Pipeline prebuild")
        case "Encode thread": return s("setting.encodeThread", "Encode thread")
        case "Hold frames when late": return s("setting.holdFrames", "Hold frames when late")
        case "Performance HUD": return s("setting.hud", "Performance HUD")

        case "Docked": return modeName("docked")
        case "Handheld": return modeName("handheld")
        case "Standard": return s("setting.option.standard", "Standard")
        case "Game's own": return s("setting.option.gameOwn", "Game’s own")
        case "Fit": return s("setting.option.fit", "Fit")
        case "Fill": return s("setting.option.fill", "Fill")
        case "iPhone Duo screen (1.43:1)": return s("setting.option.duoScreen", "iPhone Duo screen (1.43:1)")

        case "Adjusts resolution between 70% and 100% under load. Turn off to keep full resolution for the selected console mode.":
            let low = percent(0.7), high = percent(1)
            return f("setting.note.dynamicResolution", "Adjusts resolution between %1$@ and %2$@ under load. Turn off to keep full resolution for the selected console mode.", low, high)
        case "Uses more GPU time and can increase heat.":
            return s("setting.note.upscaling", "Uses more GPU time and can increase heat.")
        case "Fill crops the game's 16:9 picture to cover the screen. Health bars, subtitles or maps near the edges can be cut off. A full-screen picture without cropping needs a patch for each game.":
            return s("setting.note.picture", "Fill crops the game’s 16:9 picture to cover the screen. Health bars, subtitles or maps near the edges can be cut off. A full-screen picture without cropping needs a patch for each game.")
        case "Renders about a quarter more pixels: a little slower and warmer.":
            return s("setting.note.pictureShape", "Renders about a quarter more pixels: a little slower and warmer.")
        case "Up to one frame more display latency.":
            return s("setting.note.frameBuffering", "Up to one frame more display latency.")
        case "Keeps a pipeline archive; uses more memory.":
            return s("setting.note.metal4", "Keeps a pipeline archive; uses more memory.")
        case "The first start waits a few minutes for it, once.":
            return s("setting.note.prebuild", "The first start waits a few minutes for it, once.")
        case "This game's files do not list its languages, so some of these may not be in the game. It may then show another one.":
            return s("setting.note.languages", "This game’s files do not list its languages, so some of these may not be in the game. It may then show another one.")

        default:
            // "60 fps"
            if text.hasSuffix(" fps"), let rate = Int(text.dropLast(4)) {
                let frames = String(rate)
                return f("setting.option.fps", "%@ fps", frames)
            }
            return text
        }
    }

    /// One of the game's languages, by its code (nxnative's nacp.py), in the
    /// reader's language; nxnative's English name when iOS has none.
    static func languageName(_ code: String, english: String) -> String {
        let locale = Locale.current
        guard let name = locale.localizedString(forIdentifier: code), !name.isEmpty else { return gameSettingText(english) }
        return name.prefix(1).uppercased(with: locale) + name.dropFirst()
    }

    private static func percent(_ value: Double) -> String {
        value.formatted(.percent.precision(.fractionLength(0)))
    }

    // MARK: Warnings before expiry

    static var warning24hTitle: String { s("warning.24h.title", "Cartouche expires in 24 hours") }
    static var warning6hTitle: String { s("warning.6h.title", "Cartouche expires in 6 hours") }
    static var warningBody: String { s("warning.body", "Renew it on the System page, with LocalDevVPN connected.") }
    static var warningExpiredTitle: String { s("warning.0h.title", "Cartouche has expired") }
    static var warningExpiredBody: String { s("warning.0h.body", "Install it again from a computer with the Cartouche Installer, over this copy: your games stay.") }

    // MARK: Units

    static func mebibytes(_ value: Int) -> String {
        f("unit.mib", "%@\u{00A0}MiB", grouped(value))
    }

    static func gigabytes(_ value: Int) -> String {
        gigabytes(text: grouped(value))
    }

    private static func gigabytes(text: String) -> String {
        f("unit.gb", "%@\u{00A0}GB", text)
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

    /// "23.4 GB", in decimal gigabytes as iOS counts storage.
    static func storageAmount(bytes: Int64) -> String {
        let formatter = NumberFormatter()
        formatter.locale = Locale.current
        formatter.minimumFractionDigits = 1
        formatter.maximumFractionDigits = 1
        let value = Double(bytes) / 1_000_000_000
        return gigabytes(text: formatter.string(from: NSNumber(value: value)) ?? String(format: "%.1f", value))
    }

    private static func grouped(_ value: Int) -> String {
        let formatter = NumberFormatter()
        formatter.locale = Locale.current
        formatter.numberStyle = .decimal
        return formatter.string(from: NSNumber(value: value)) ?? String(value)
    }
}
