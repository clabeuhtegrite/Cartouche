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
}

/// The player's games, as nxnative.json names them.
enum Games {
    static let owned = ["0400C3F00006E000", "040074A01BF12000", "01006BB00C6F0000"]
    static let names = ["Mario Kart World", "Donkey Kong Bananza", "The Legend of Zelda: Link's Awakening"]
    /// A game of the catalogue the player does not have.
    static let other = "13 Sentinels: Aegis Rim"
}

/// How the gallery opens (GalleryApp.swift).
struct Launch {
    /// The certificate, the pairing file and the Apple ID in place.
    var setupDone = true
    /// The pairing file alone, so that the Apple ID can be signed in.
    var pairingOnly = false
    /// The main thread held once, for that many seconds, which the watch
    /// must see.
    var holdMainThread: Double?

    var arguments: [String] {
        var arguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US",
                         "-GalleryScreen", "root", "-GalleryTest", "1",
                         "-GallerySetup", setupDone ? "1" : "0",
                         "-GalleryOwned", Games.owned.joined(separator: ",")]
        if pairingOnly { arguments += ["-GalleryPairing", "1"] }
        if let holdMainThread { arguments += ["-GalleryHoldMainThread", String(holdMainThread)] }
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

    /// Opens the gallery on the console and waits for its dock.
    @MainActor
    func openConsole(_ launch: Launch = Launch()) -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = launch.arguments
        app.launch()
        // The first launch after the install can take a while.
        expect(app.buttons[Words.system].waitForExistence(timeout: 90), "The console did not come up", in: app)
        return app
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

    /// Whether the console is back, with nothing over it: its dock can be
    /// tapped.
    @MainActor
    func isOnConsole(_ app: XCUIApplication) -> Bool {
        let system = app.buttons[Words.system]
        return system.exists && system.isHittable
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
    /// it was asked, since a second after the gallery opened.
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
/// gallery's window, in English, as the simulator is.
@MainActor
struct FilesPicker {
    let app: XCUIApplication
    let test: ConsoleTestCase

    /// Its close button, by its names on iOS 18 and after.
    var closeButton: XCUIElement {
        app.buttons.matching(NSPredicate(format: "label IN %@", ["Cancel", "Close"])).firstMatch
    }

    /// Its tabs.
    var tab: XCUIElement {
        app.buttons.matching(NSPredicate(format: "label IN %@", ["Browse", "Recents"])).firstMatch
    }

    var isShown: Bool { closeButton.exists || tab.exists }

    func waitForIt(_ timeout: TimeInterval = 30) -> Bool {
        test.waitUntil(timeout) { isShown }
    }

    func waitForItToGo(_ timeout: TimeInterval = 15) -> Bool {
        test.waitUntil(timeout) { !isShown }
    }

    func close() {
        test.tap(closeButton, "Cancel of the Files picker", in: app)
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
        if let item = item(name, timeout: 3) {
            choose(item, file)
            return
        }
        // Browse shows where it was last, and its places once tapped again.
        let browse = app.buttons["Browse"]
        var place: XCUIElement?
        for _ in 0..<2 where place == nil {
            if browse.exists { browse.tap() }
            place = item("On My iPhone", among: [app.cells, app.buttons], timeout: 8)
        }
        guard let place else {
            test.expect(false, "The Files picker shows no On My iPhone", in: app)
            return
        }
        open(place)
        if let item = item(name, timeout: 10) {
            choose(item, file)
            return
        }
        if let folder = item(GalleryWords.folder, among: [app.cells], timeout: 5) {
            open(folder)
            if let item = item(name, timeout: 15) {
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
