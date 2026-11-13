//
//  ConsoleTestCase.swift
//  CartoucheGalleryUITests
//
//  What the launcher's UI tests share: the gallery opened on the whole
//  console, as Cartouche shows it (-GalleryScreen root), the launcher's words
//  they look for, taps that say what they could not find, the Files picker,
//  and the watch on the gallery's main thread (GalleryTesting.swift).
//
//  Each test ends back on the console, where the watch's readout is, and
//  fails should the main thread have taken two seconds or more, at any time
//  since the gallery opened, to answer: the screen frozen that long, even if
//  it came back afterwards. A test that fails keeps the screen and what the
//  accessibility tree held, in the test results and in the log.
//

import XCTest

/// The launcher's words the tests look for, in English, as the launch
/// arguments ask: each is the English of the key beside it in
/// launcher/Sources/CartoucheText*.swift, or its beginning, which
/// app/tests/test_launcher_ui_tests.py checks.
enum Words {
    static let allGames = "All games"                       // home.all
    static let importGame = "Import"                        // dock.import
    static let system = "System"                            // tab.system
    static let details = "Details"                          // action.details
    static let done = "Done"                                // action.done
    static let cancel = "Cancel"                            // action.cancel
    static let gameSettings = "Game settings"               // action.gameSettings
    static let importCopy = "Import my copy"                // action.import
    static let search = "Name or title ID"                  // library.search
    static let controls = "Controls"                        // setting.section.controls
    static let touchFeedback = "Touch feedback"             // setting.touchFeedback
    static let setup = "Setup"                              // setup.title
    static let storage = "Storage"                          // storage.title
    static let signIn = "Sign In"                           // setup.appleID.signIn
    static let signedIn = "Signed in: "                     // setup.appleID.done
    static let signInTitle = "Sign in with your Apple ID"   // signIn.title
    static let appleID = "Apple ID (email or phone number)" // signIn.appleID
    static let password = "Password"                        // signIn.password
    static let code = "6-digit code"                        // signIn.code.placeholder
    static let signInFailed = "The sign-in did not go through" // signIn.failed.title
    static let tooManyRequests = "Apple is refusing new sign-ins for now" // signIn.tooManyRequests
    static let tryAgainIn = "Try again in "                 // signIn.wait
    static let copyReport = "Copy the report"               // errorReport.copy
    static let reportCopied = "Report copied"               // errorReport.copied
    static let guide = "Your first game"                    // guide.title
    static let guideCard = "Step %1$lld of %2$lld: %3$@"    // guide.card.detail
    static let guideHide = "Hide the guide"                 // guide.hide
    static let stepDone = "%@, done"                        // guide.step.done
    static let stepSkipped = "%@, skipped"                  // guide.step.skipped
    static let vpnStep = "Connect LocalDevVPN"              // guide.vpn.title
    static let getVPN = "Get LocalDevVPN"                   // guide.vpn.get
    static let accountStep = "Sign in with your Apple ID"   // guide.account.title
    static let noPairingFile = "The pairing file is missing." // guide.account.noPairing
    static let openSetup = "Open the setup"                 // guide.openSetup
    static let buildStep = "Build your game on a Mac"       // guide.build.title
    static let noThanks = "No thanks"                       // guide.build.skip
    static let folderStep = "Choose your games folder"      // guide.folder.title
    static let chooseGamesFolder = "Choose the games folder" // guide.folder.choose
    static let importInstead = "Import an IPA instead"      // guide.folder.import
    static let playStep = "Install your game and play"      // guide.play.title
    static let telemetry = "Game measurements"              // telemetry.title
    static let sendMeasurements = "Send game measurements"  // telemetry.send
    static let report = "Report a problem"                  // report.title
    static let resetCartouche = "Reset Cartouche"           // reset.title
    static let eraseAndRestart = "Erase everything and restart" // reset.erase
    static let eraseEverything = "Erase everything"         // reset.confirm.erase
    static let erasing = "Erasing…"                         // reset.erasing
    static let renewEveryNight = "Renew every night"        // system.auto.daily
    static let openShortcuts = "Open Shortcuts"             // daily.openShortcuts
    static let storageIntro = "Your games and saves on your own storage" // storage.intro
    static let addFirst = "First add your Mac"              // storage.addFirst
    static let addMac = "Add your Mac (Cartouche Builder)"  // storage.mac.add
    static let addS3 = "Add S3 storage"                     // storage.addS3
    static let addFTP = "Add an FTP server"                 // storage.addFTP
    static let addFolder = "Add a folder in Files"          // storage.addFolder
    static let addDrive = "Add Google Drive"                // storage.drive.add
    static let driveSignedOut = "Google ended Cartouche’s sign-in to %@" // storage.drive.signedOut
    static let driveSignedOutShort = "%@: sign in again"    // storage.drive.signedOut.short
    static let driveSignInAgain = "Sign in to Google again" // storage.drive.signInAgain
    static let offline = "%@ does not answer on this network." // storage.offline
    static let offlineShort = "%@ offline"                  // storage.offline.short
    static let tryAgain = "Try again"                       // storage.tryAgain
    static let savesWaiting = "%lld games’ saves are waiting" // saves.waiting.many
    static let yourMac = "Your Mac"                         // storage.mac.title
    static let macsNearby = "Macs nearby"                   // storage.mac.nearby
    static let pairingWith = "Pairing with %@"              // storage.mac.pairing
    static let checkDigits = "Check that your Mac shows the same digits" // storage.mac.checkCode
    static let noLocalNetwork = "iOS does not let Cartouche look for your Mac" // storage.mac.localNetwork
    static let editInfo = "Edit the game’s info"            // gameInfo.edit
    static let gameInfo = "Game info"                       // gameInfo.title
    static let save = "Save"                                // gameInfo.save
    static let backToCartouchesInfo = "Back to Cartouche’s info" // gameInfo.reset
    static let resume = "Resume"                            // action.resume
    static let quit = "Quit"                                // action.quit
    static let quitQuestion = "Quit %@?"                    // running.quit.question
    static let quitGame = "Quit the game"                   // running.quit.confirm
    static let paused = "Paused behind Cartouche"           // running.paused
    static let installing = "Installing %@"                 // work.install.title
    static let unpacking = "Unpacking the IPA."             // work.install.unpacking
    static let canLeave = "You can leave Cartouche"         // work.canLeave
    static let installFailed = "The game was not installed" // work.install.failed
    static let updateOffer = "Cartouche %@ is available"    // updates.offer.title
    static let update = "Update"                            // updates.now
    static let later = "Later"                              // updates.later
    static let lastSync = "Last sync"                       // saves.lastSync
    static let noneYet = "None yet"                         // saves.noCopy
    static let syncNow = "Sync with %@ now"                 // saves.syncNow
    static let putBack = "Put back a copy"                  // saves.putBack
    static let putBackCopy = "Put back the copy of "        // saves.putBack.action
    static let putBackDone = "The copy of "                 // saves.putBack.done
}

/// The gallery's own words (GalleryTesting.swift).
enum GalleryWords {
    /// The IPA in the gallery's Documents, and the folder the Files picker
    /// shows them in: the gallery's name.
    static let ipa = "Test Game.ipa"
    static let folder = "Gallery"
    /// The stand-in install's alert.
    static let install = "Gallery install"
    /// The stand-in SideStore: a wrong code, and the Apple ID once signed in.
    static let wrongCode = "Incorrect verification code."
    static let signedInAs = "player@icloud.com"
    /// The folder in Files the saves are kept in (GallerySaves).
    static let savesFolder = "Gallery saves"
}

/// The player's games, as nxnative.json names them.
enum Games {
    static let owned = ["0400C3F00006E000", "040074A01BF12000", "01006BB00C6F0000"]
    static let names = ["Mario Kart World", "Donkey Kong Bananza", "The Legend of Zelda: Link's Awakening"]
    /// The game in focus as the console opens: the first by name, as the
    /// shelf orders the player's games, not the first of owned.
    static var inFocus: String { names.min { $0.localizedStandardCompare($1) == .orderedAscending }! }
    /// A game of the catalogue the player does not have.
    static let other = "13 Sentinels: Aegis Rim"
}

/// How the gallery opens (GalleryApp.swift).
struct Launch {
    /// The certificate, the pairing file and the Apple ID in place.
    var setupDone = true
    /// The pairing file alone, so that the Apple ID can be signed in.
    var pairingOnly = false
    /// The player's games, installed: none for a player new to Cartouche.
    var owned = Games.owned
    /// What goes on as the gallery opens (-GalleryWork, GalleryApp.swift):
    /// "update", a new version of Cartouche on offer; "paused", the first
    /// game paused behind the console; "installing" or "install-failed",
    /// the game of SHEET; "offline", the NAS out of reach; "mac", the
    /// player's Mac paired; "mac-nearby", "mac-code" or "mac-refused", what
    /// Add your Mac finds; "saves", the first game's saves and a folder in
    /// Files as the saves folder; "drive-signed-out", the player's Google
    /// Drive, whose sign-in Google ended, with two games' saves waiting.
    var work: String?
    /// The game being installed, or whose install failed.
    var sheet: String?
    /// The main thread held once, for that many seconds, which the watch
    /// must see.
    var holdMainThread: Double?
    /// A test that types: the keyboard shown once and put away as the
    /// gallery opens, before the watch counts, as its first showing in a
    /// process holds the main thread for seconds on a CI Mac
    /// (GalleryKeyboard, GalleryTesting.swift).
    var typing = false

    var arguments: [String] {
        var arguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US",
                         "-GalleryScreen", "root", "-GalleryTest", "1",
                         "-GallerySetup", setupDone ? "1" : "0"]
        if !owned.isEmpty { arguments += ["-GalleryOwned", owned.joined(separator: ",")] }
        if pairingOnly { arguments += ["-GalleryPairing", "1"] }
        if let work { arguments += ["-GalleryWork", work] }
        if let sheet { arguments += ["-GallerySheet", sheet] }
        if let holdMainThread { arguments += ["-GalleryHoldMainThread", String(holdMainThread)] }
        if typing { arguments += ["-GalleryKeyboard", "1"] }
        return arguments
    }
}

/// What the watch on the gallery's main thread says: "Main thread: longest
/// 120 ms, 1 stalls: 310 ms at 4.2 s".
struct MainThreadReading {
    let text: String
    /// The longest the main thread took to answer, in milliseconds.
    let longest: Int
    /// The waits of a quarter of a second or more.
    let stalls: Int
    /// Whether the watch has started counting, a second after the gallery
    /// became active.
    let counting: Bool

    init?(_ text: String) {
        guard let expression = try? NSRegularExpression(pattern: "longest ([0-9]+) ms, ([0-9]+) stalls"),
              let match = expression.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let longest = Range(match.range(at: 1), in: text).flatMap({ Int(text[$0]) }),
              let stalls = Range(match.range(at: 2), in: text).flatMap({ Int(text[$0]) }) else { return nil }
        self.text = text
        self.longest = longest
        self.stalls = stalls
        counting = !text.contains("not counting yet")
    }
}

class ConsoleTestCase: XCTestCase {
    /// The longest the main thread may take to answer, in milliseconds: far
    /// above what the console takes on a simulator of a CI Mac, a tenth of a
    /// second or two, and below a screen a player would call frozen.
    static let longestWait = 2_000

    // MARK: Opening the console

    /// Opens the gallery on the console and waits for its dock; for a test
    /// that types, also for the keyboard to have been shown and put away,
    /// once the watch counts.
    @MainActor
    func openConsole(_ launch: Launch = Launch()) -> XCUIApplication {
        let app = launchGallery(launch)
        expect(app.buttons[Words.system].waitForExistence(timeout: Self.firstLaunch), "The console did not come up", in: app)
        if launch.typing {
            expect(waitUntil(30) { mainThread(of: app)?.counting == true },
                   "The keyboard was not shown and put away as the gallery opened: \(mainThread(of: app)?.text ?? "no watch")",
                   in: app)
        }
        return app
    }

    /// How long the gallery may take to come up: its first launch after
    /// the install can take a while.
    static let firstLaunch: TimeInterval = 90

    /// Opens the gallery, without waiting for the console: for a test that
    /// waits for what shows over it, such as an alert, which hides the
    /// console from the accessibility tree.
    @MainActor
    func launchGallery(_ launch: Launch) -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        // The test's name, which the gallery writes down as it starts, with
        // its main thread's waits after it (uitests.sh).
        app.launchArguments = launch.arguments + ["-GalleryTestName", shortName]
        app.launch()
        return app
    }

    /// The test's name, "GameUITests.testAFailedInstallGivesItsReport":
    /// without the brackets of "-[GameUITests testAFailed…]", which a
    /// launch argument would take for an option of its own.
    private var shortName: String {
        name.trimmingCharacters(in: CharacterSet(charactersIn: "-[]")).replacingOccurrences(of: " ", with: ".")
    }

    // MARK: Looking and tapping

    /// Fails the test, keeping the screen and the accessibility tree,
    /// unless CONDITION holds.
    @MainActor
    func expect(_ condition: Bool, _ message: @autoclosure () -> String, in app: XCUIApplication,
                file: StaticString = #filePath, line: UInt = #line) {
        guard !condition else { return }
        let message = message()
        keepScreen(of: app, for: message)
        XCTFail(message, file: file, line: line)
    }

    @MainActor
    func keepScreen(of app: XCUIApplication, for message: String) {
        let tree = app.debugDescription
        print("== \(name): \(message). The accessibility tree:\n\(tree)")
        let text = XCTAttachment(string: tree)
        text.name = "Accessibility tree"
        text.lifetime = .keepAlways
        add(text)
        let screen = XCTAttachment(screenshot: app.screenshot())
        screen.name = "Screen"
        screen.lifetime = .keepAlways
        add(screen)
    }

    /// Waits for ELEMENT, then taps it: the first, should there be several.
    @MainActor
    func tap(_ element: XCUIElement, _ what: String, in app: XCUIApplication, timeout: TimeInterval = 15,
             file: StaticString = #filePath, line: UInt = #line) {
        let element = element.firstMatch
        expect(element.waitForExistence(timeout: timeout), "No \(what) to tap", in: app, file: file, line: line)
        expect(waitUntil(5) { element.isHittable }, "\(what) is there, but cannot be tapped", in: app,
               file: file, line: line)
        element.tap()
    }

    /// Taps FIELD, waits for it to take the keyboard, then types TEXT into
    /// it: the first keyboard of a simulator can take seconds to come, and
    /// a tap that came before the field could take it needs a second one.
    @MainActor
    func type(_ text: String, into field: XCUIElement, _ what: String, in app: XCUIApplication,
              timeout: TimeInterval = 15, file: StaticString = #filePath, line: UInt = #line) {
        let field = field.firstMatch
        tap(field, what, in: app, timeout: timeout, file: file, line: line)
        focus(field, what, in: app, again: { field.tap() }, file: file, line: line)
        field.typeText(text)
    }

    /// Puts TEXT in FIELD in place of what it holds: a tap at its end, where
    /// the cursor then is, and a delete for each character before it.
    @MainActor
    func replaceText(in field: XCUIElement, with text: String, _ what: String, in app: XCUIApplication,
                     file: StaticString = #filePath, line: UInt = #line) {
        let field = field.firstMatch
        expect(field.waitForExistence(timeout: 15), "No \(what)", in: app, file: file, line: line)
        let end = field.coordinate(withNormalizedOffset: CGVector(dx: 0.96, dy: 0.5))
        end.tap()
        focus(field, what, in: app, again: { end.tap() }, file: file, line: line)
        let held = (field.value as? String) ?? ""
        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: held.count + 2) + text)
    }

    /// Waits for FIELD, just tapped, to take the keyboard, tapping it AGAIN
    /// once should it not.
    @MainActor
    private func focus(_ field: XCUIElement, _ what: String, in app: XCUIApplication, again: () -> Void,
                       file: StaticString, line: UInt) {
        var focused = waitUntil(20) { hasKeyboardFocus(field, in: app) }
        if !focused, field.exists {
            again()
            focused = waitUntil(20) { hasKeyboardFocus(field, in: app) }
        }
        expect(focused, "\(what) did not take the keyboard", in: app, file: file, line: line)
    }

    /// Whether ELEMENT has the keyboard, which typeText needs: as XCTest
    /// tells it, else by a keyboard on the screen.
    @MainActor
    func hasKeyboardFocus(_ element: XCUIElement, in app: XCUIApplication) -> Bool {
        let key = "hasKeyboardFocus"
        guard element.exists else { return false }
        if element.responds(to: NSSelectorFromString(key)) {
            return (element.value(forKey: key) as? Bool) ?? false
        }
        return app.keyboards.firstMatch.exists
    }

    /// Whether CONDITION holds within TIMEOUT seconds, asked twice a second.
    @MainActor
    func waitUntil(_ timeout: TimeInterval, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline { return false }
            Thread.sleep(forTimeInterval: 0.5)
        }
        return true
    }

    /// Whether ELEMENT has gone within TIMEOUT seconds.
    @MainActor
    func waitForGone(_ element: XCUIElement, timeout: TimeInterval = 10) -> Bool {
        waitUntil(timeout) { !element.exists }
    }

    /// The first element of QUERY whose label begins with TEXT.
    @MainActor
    func element(in query: XCUIElementQuery, beginningWith text: String) -> XCUIElement {
        query.matching(NSPredicate(format: "label BEGINSWITH %@", text)).firstMatch
    }

    /// The first element of QUERY whose label holds TEXT.
    @MainActor
    func element(in query: XCUIElementQuery, containing text: String) -> XCUIElement {
        query.matching(NSPredicate(format: "label CONTAINS %@", text)).firstMatch
    }

    /// The first element of any kind whose label is TEXT.
    @MainActor
    func element(labelled text: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", text)).firstMatch
    }

    /// The first element of any kind whose label begins with TEXT.
    @MainActor
    func element(beginningWith text: String, in app: XCUIApplication) -> XCUIElement {
        element(in: app.descendants(matching: .any), beginningWith: text)
    }

    /// The first element of any kind whose label holds TEXT: for a view
    /// that reads as one element, whose label joins its lines, such as the
    /// install over the console.
    @MainActor
    func element(containing text: String, in app: XCUIApplication) -> XCUIElement {
        element(in: app.descendants(matching: .any), containing: text)
    }

    /// The button labelled LABEL that can be tapped, within TIMEOUT seconds;
    /// of several, the last: a sheet leaves the buttons of the page under it
    /// in the accessibility tree, such as the home's Resume under the sheet
    /// of the game paused, and comes after them.
    @MainActor
    func buttonOnTop(_ label: String, in app: XCUIApplication, timeout: TimeInterval = 15) -> XCUIElement? {
        let buttons = app.buttons.matching(NSPredicate(format: "label == %@", label))
        var found: XCUIElement?
        _ = waitUntil(timeout) {
            found = buttons.allElementsBoundByIndex.last { $0.exists && $0.isHittable }
            return found != nil
        }
        return found
    }

    /// Taps the button labelled LABEL on top (buttonOnTop).
    @MainActor
    func tapButtonOnTop(_ label: String, _ what: String, in app: XCUIApplication, timeout: TimeInterval = 15,
                        file: StaticString = #filePath, line: UInt = #line) {
        guard let button = buttonOnTop(label, in: app, timeout: timeout) else {
            expect(false, app.buttons[label].exists ? "\(what) is there, but cannot be tapped" : "No \(what) to tap",
                   in: app, file: file, line: line)
            return
        }
        button.tap()
    }

    /// Cancels the confirmation on the screen (a confirmationDialog) as a
    /// player does, then waits for it to go: by its Cancel, or, where iOS
    /// shows it in a popover, which has no Cancel, as on an iPhone from
    /// iOS 26, by a tap outside it, halfway between it and the edge of the
    /// screen with the most room.
    @MainActor
    func cancelConfirmation(_ what: String, in app: XCUIApplication,
                            file: StaticString = #filePath, line: UInt = #line) {
        let sheet = app.sheets.firstMatch
        expect(sheet.waitForExistence(timeout: 15), "No \(what)", in: app, file: file, line: line)
        let cancel = sheet.buttons[Words.cancel]
        let outside = app.otherElements["PopoverDismissRegion"]
        var cancels = false
        _ = waitUntil(5) {
            cancels = cancel.exists && cancel.isHittable
            return cancels || outside.exists
        }
        if cancels {
            cancel.tap()
        } else if outside.exists {
            let area = outside.frame
            let shown = sheet.frame
            let below = area.maxY - shown.maxY
            let above = shown.minY - area.minY
            let y = below >= above ? shown.maxY + below / 2 : area.minY + above / 2
            outside.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: (y - area.minY) / area.height)).tap()
        } else {
            expect(false, "\(what) has no Cancel, and nothing outside it to tap", in: app, file: file, line: line)
            return
        }
        expect(waitForGone(sheet), "\(what) stayed once cancelled", in: app, file: file, line: line)
    }

    /// Swipes the page up, slowly, until ELEMENT can be tapped: a list draws
    /// its rows only as they come on the screen.
    @MainActor
    func scrollTo(_ element: XCUIElement, _ what: String, in app: XCUIApplication, swipes: Int = 10,
                  file: StaticString = #filePath, line: UInt = #line) {
        let element = element.firstMatch
        for _ in 0..<swipes {
            if element.exists && element.isHittable { return }
            app.swipeUp(velocity: .slow)
        }
        expect(element.exists && element.isHittable, "No \(what), even after scrolling", in: app, file: file, line: line)
    }

    /// Scrolls to ELEMENT, then taps it once it stays where it can be: the
    /// rows of a list above it can grow as they are drawn and push it off
    /// the screen, as a game's sheet did to its Edit the game's info, at
    /// its bottom edge just after it could be tapped. Then it scrolls
    /// again.
    @MainActor
    func scrollAndTap(_ element: XCUIElement, _ what: String, in app: XCUIApplication,
                      file: StaticString = #filePath, line: UInt = #line) {
        let element = element.firstMatch
        for _ in 0..<3 {
            scrollTo(element, what, in: app, file: file, line: line)
            Thread.sleep(forTimeInterval: 0.5)
            if element.isHittable {
                element.tap()
                return
            }
        }
        expect(false, "\(what) is there, but cannot be tapped, even after scrolling to it three times", in: app,
               file: file, line: line)
    }

    /// Back from the page titled TITLE, by the first button of its
    /// navigation bar.
    @MainActor
    func back(from title: String, in app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        let bar = app.navigationBars[title]
        expect(bar.waitForExistence(timeout: 15), "No page \(title) to go back from", in: app, file: file, line: line)
        tap(bar.buttons.element(boundBy: 0), "Back from \(title)", in: app, file: file, line: line)
        expect(waitForGone(bar), "\(title) stayed once Back was tapped", in: app, file: file, line: line)
    }

    /// The gallery's install of IPA, the first since it opened, says so over
    /// the console; Done closes it, and no second one follows.
    @MainActor
    func expectInstall(of ipa: String, in app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        let alert = app.alerts[GalleryWords.install]
        expect(alert.waitForExistence(timeout: 20), "No install of the IPA picked", in: app, file: file, line: line)
        let message = "Install 1: \(ipa)"
        expect(alert.staticTexts[message].exists, "The install was not the first, of \(ipa): \(alert.debugDescription)",
               in: app, file: file, line: line)
        tap(alert.buttons[Words.done], "Done of the install", in: app, file: file, line: line)
        expect(waitForGone(alert), "The install's alert stayed", in: app, file: file, line: line)
        // The install happens once.
        Thread.sleep(forTimeInterval: 2)
        expect(!app.alerts[GalleryWords.install].exists, "A second install followed the first", in: app, file: file, line: line)
    }

    /// Whether the console is back, with nothing over it: its dock can be
    /// tapped.
    @MainActor
    func isOnConsole(_ app: XCUIApplication) -> Bool {
        let system = app.buttons[Words.system]
        return system.exists && system.isHittable
    }

    // MARK: A game's sheet

    /// From the home, the sheet of the game named NAME, as a player opens
    /// it: its cover tapped, unless it is in focus already, then Details,
    /// which opens the sheet of the game in focus. The cover in focus says
    /// so, as VoiceOver reads it: selected. A tap on the cover in focus
    /// opens its sheet too, should the cover not have said it was.
    @MainActor
    func openSheet(of name: String, in app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        let cover = app.buttons[name].firstMatch
        let done = app.buttons[Words.done]
        expect(cover.waitForExistence(timeout: 15), "No cover of \(name) on the home", in: app, file: file, line: line)
        if !cover.isSelected {
            tap(cover, "The cover of \(name)", in: app, file: file, line: line)
            expect(waitUntil(10) { cover.isSelected || done.exists },
                   "A tap on the cover of \(name) did not put it in focus", in: app, file: file, line: line)
        }
        if !done.exists {
            tap(app.buttons[Words.details], "Details of \(name)", in: app, file: file, line: line)
        }
        expect(done.waitForExistence(timeout: 15), "Details did not open the sheet of \(name)", in: app,
               file: file, line: line)
        expect(sheetShows(name, in: app), "The sheet open is not \(name)'s", in: app, file: file, line: line)
    }

    /// Whether the sheet open shows NAME, its game's, within TIMEOUT
    /// seconds: in its list, as the home under it, which stays in the
    /// accessibility tree with the same name on its shelf, has none.
    @MainActor
    func sheetShows(_ name: String, in app: XCUIApplication, timeout: TimeInterval = 10) -> Bool {
        app.collectionViews.staticTexts[name].waitForExistence(timeout: timeout)
    }

    /// Done of the sheet: the console.
    @MainActor
    func closeSheet(in app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        tap(app.buttons[Words.done], "Done of the sheet", in: app, file: file, line: line)
        expect(waitUntil(10) { isOnConsole(app) }, "Done did not bring the console back", in: app, file: file, line: line)
    }

    // MARK: The main thread

    /// What the watch says, read on the console.
    @MainActor
    func mainThread(of app: XCUIApplication) -> MainThreadReading? {
        let readout = app.descendants(matching: .any).matching(identifier: "gallery.watch").firstMatch
        guard readout.waitForExistence(timeout: 10) else { return nil }
        return MainThreadReading(readout.label)
    }

    /// Fails unless the main thread answered within longestWait every time
    /// it was asked, since a second after the gallery opened, but for the
    /// time it spent for the tests' accessibility, answering their queries
    /// or loading accessibility's code, which the readout gives apart.
    @MainActor
    func expectMainThreadAnswered(_ app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        guard let reading = mainThread(of: app) else {
            expect(false, "No readout of the main thread's watch: is the console back?", in: app, file: file, line: line)
            return
        }
        print("== \(name): \(reading.text)")
        expect(reading.counting, "The main thread's watch never started counting: \(reading.text)", in: app,
               file: file, line: line)
        expect(reading.longest < Self.longestWait,
               "The main thread took \(reading.longest) ms to answer, \(Self.longestWait) ms at most: \(reading.text)",
               in: app, file: file, line: line)
    }
}

/// The Files picker, which iOS shows in a process of its own, inside the
/// gallery's window, in English, as the simulator is. It is known by its
/// own elements, its browser and the tab bar under it, as the console has
/// buttons of the same names, such as the Cancel of its search. While it
/// is open, a query of the screen can take seconds, the gallery's main
/// thread answering it (GalleryWatch), hence the long waits.
@MainActor
struct FilesPicker {
    let app: XCUIApplication
    let test: ConsoleTestCase

    /// How long the picker may take to come, to go, or to show an item.
    static let patience: TimeInterval = 60

    /// Its browser, with its places, folders and files, and its tab bar:
    /// Recents, Shared, Browse.
    private var own: XCUIElementQuery {
        app.descendants(matching: .any).matching(NSPredicate(format: "identifier == %@ OR identifier ENDSWITH %@",
                                                             "DOC.browsingModeTabBar", "(Picker)"))
    }

    var isShown: Bool { own.firstMatch.exists }

    /// Its close button, by its names on iOS 18 and after, in its browser.
    var closeButton: XCUIElement {
        own.buttons.matching(NSPredicate(format: "label IN %@", ["Cancel", "Close"])).firstMatch
    }

    func waitForIt(_ timeout: TimeInterval = FilesPicker.patience) -> Bool {
        test.waitUntil(timeout) { isShown }
    }

    func waitForItToGo(_ timeout: TimeInterval = FilesPicker.patience) -> Bool {
        test.waitUntil(timeout) { !isShown }
    }

    func close() {
        test.tap(closeButton, "Cancel of the Files picker", in: app, timeout: Self.patience)
    }

    /// An item of the picker, a place, a folder or a file, whose name begins
    /// with NAME, among cells, buttons and texts, within TIMEOUT seconds.
    func item(_ name: String, among queries: [XCUIElementQuery]? = nil, timeout: TimeInterval) -> XCUIElement? {
        let queries = queries ?? [app.cells, app.buttons, app.staticTexts]
        var found: XCUIElement?
        _ = test.waitUntil(timeout) {
            found = queries.lazy
                .map { test.element(in: $0, beginningWith: name) }
                .first { $0.exists }
            return found != nil
        }
        return found
    }

    /// Taps ITEM where a player would: on its icon in the picker's icon
    /// view, whose name under the icon does not open it; else on the item.
    func open(_ item: XCUIElement) {
        let icon = item.images.firstMatch
        (icon.exists ? icon : item).tap()
    }

    /// Picks FILE, which the picker may show without its extension: where
    /// the picker opened, as after an earlier pick, else in On My iPhone,
    /// where uitests.sh puts it, from Browse, else in the gallery's own
    /// folder there, where the gallery writes it too.
    func pick(_ file: String) {
        let name = (file as NSString).deletingPathExtension
        if let item = item(name, timeout: 5) {
            choose(item, file)
            return
        }
        // Browse shows where it was last, and its places once tapped again.
        let browse = own.buttons["Browse"]
        var place: XCUIElement?
        for _ in 0..<2 where place == nil {
            if browse.exists { browse.tap() }
            place = item("On My iPhone", among: [app.cells, app.buttons], timeout: 20)
        }
        guard let place else {
            test.expect(false, "The Files picker shows no On My iPhone", in: app)
            return
        }
        open(place)
        if let item = item(name, timeout: 20) {
            choose(item, file)
            return
        }
        if let folder = item(GalleryWords.folder, among: [app.cells], timeout: 10) {
            open(folder)
            if let item = item(name, timeout: 20) {
                choose(item, file)
                return
            }
        }
        let empty = app.staticTexts["Folder is Empty"].exists ? ", the folder shown is empty" : ""
        test.expect(false, "The Files picker shows no \(file) in On My iPhone or its \(GalleryWords.folder) folder\(empty)",
                    in: app)
    }

    /// Picks ITEM, unless the picker shows it greyed out: of a type the
    /// import does not take.
    private func choose(_ item: XCUIElement, _ file: String) {
        test.expect(item.isEnabled, "The Files picker shows \(file) greyed out: \(item.debugDescription)", in: app)
        open(item)
    }
}
