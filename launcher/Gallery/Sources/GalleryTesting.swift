//
//  GalleryTesting.swift
//  CartoucheGallery
//
//  What the launcher's UI tests (launcher/Gallery/UITests) need of the
//  gallery, which they open on the whole console as Cartouche shows it
//  (-GalleryScreen root) and drive with taps:
//
//  - a clean start (-GalleryTest 1): what an earlier test left in the
//    gallery's defaults goes, such as a wait Apple asked for;
//  - a watch on the main thread (GalleryWatch), asked ten times a second
//    from another thread how long it takes to answer, read out by an
//    element of the accessibility tree that the tests read
//    (gallery.watch): a test fails when the main thread was held, even if
//    the screen came back afterwards, but for the time it spent answering
//    the tests' own accessibility queries, which the watch tells by where
//    the main thread is (GalleryMainThread.c);
//  - the main thread held on purpose, once, two seconds after the gallery
//    became active (-GalleryHoldMainThread 1.5, in seconds), which the
//    watch must see: a watch that saw nothing would let every test pass;
//  - an IPA to pick, Test Game.ipa in the gallery's Documents, which the
//    Files picker shows under On My iPhone › Gallery, as uitests.sh puts
//    one in On My iPhone: the stand-in install says over the console which
//    file it was given (GalleryStubs.swift);
//  - the pairing file in place without the rest of the setup
//    (-GalleryPairing 1), so that the Apple ID can be signed in;
//  - the built-in SideStore's sign-in, stood in for (GallerySideStore
//    below).
//

import SwiftUI
import UIKit
import UniformTypeIdentifiers

enum GalleryTest {
    private static var defaults: UserDefaults { .standard }

    /// Whether the UI tests opened the gallery.
    static var isOn: Bool { defaults.bool(forKey: "GalleryTest") }

    /// The IPA the tests pick in the Files picker.
    static let ipaName = "Test Game.ipa"

    /// First thing as the gallery starts, before any part of the launcher
    /// reads its defaults.
    static func start() {
        guard isOn else { return }
        if let bundleIdentifier = Bundle.main.bundleIdentifier {
            defaults.removePersistentDomain(forName: bundleIdentifier)
        }
        let hold = defaults.double(forKey: "GalleryHoldMainThread")
        GalleryWatch.shared.start(holding: hold > 0 ? hold : nil)
    }

    /// Once the scenario has put its files in place (GalleryScenario.prepare).
    @MainActor
    static func prepared() {
        guard isOn else { return }
        if defaults.bool(forKey: "GalleryPairing") {
            // Where the scenario puts it once the setup is done.
            let folder = CartouchePairing.storeDocuments
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try? Data("gallery".utf8).write(to: folder.appendingPathComponent(CartouchePairing.importName))
            CartoucheSetup.shared.refresh()
        }
        // Whether iOS knows the IPA's type, or makes one up from its
        // extension, which the Files picker may then not take.
        NSLog("[Gallery] the type of an IPA: %@", UTType(filenameExtension: "ipa")?.identifier ?? "none")
        // An empty ZIP archive: the stand-in install reads none of it.
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let empty = Data([0x50, 0x4B, 0x05, 0x06] + [UInt8](repeating: 0, count: 18))
        do {
            try empty.write(to: documents.appendingPathComponent(ipaName), options: .atomic)
        } catch {
            NSLog("[Gallery] cannot write %@: %@", ipaName, String(describing: error))
        }
    }

    /// How many installs the gallery was asked for since it started.
    @MainActor private static var installs = 0

    /// What the stand-in install does with an IPA the player picked or
    /// opened Cartouche with: says which, and how many installs so far, over
    /// the console, a second later, once the picker and the sheet it showed
    /// over have gone. The tests read it as an alert.
    @MainActor
    static func install(_ url: URL, with actions: CartoucheGameActions) {
        guard isOn else { return }
        installs += 1
        let message = "Install \(installs): \(url.lastPathComponent)"
        NSLog("[Gallery] %@", message)
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1))
            actions.notice = CartoucheGameNotice(title: installTitle, message: message)
        }
    }

    /// The title of the alert the stand-in install shows.
    static let installTitle = "Gallery install"
}

// MARK: The main thread's watch

/// Cartouche's main thread, which takes every touch, draws every frame and
/// answers the Files picker, asked from another thread ten times a second
/// how long it takes to answer, from a second after the gallery became
/// active: waits before, as the gallery opens, do not count, nor waits while
/// it is in the background, where iOS may suspend it.
///
/// From a fifth of a second into a wait, the watch also looks at where the
/// main thread is, ten times a second (GalleryMainStack). The time it finds
/// the main thread answering the tests' own questions, the accessibility
/// queries through which XCUITest reads the screen and waits for the
/// gallery, does not count, each look standing for the time until the next
/// one: no player asks them, and while the Files picker is open, one of
/// them can hold the main thread for seconds. The readout says how long
/// they held it, apart, and gallery-main-thread.txt, in the gallery's tmp
/// folder, where the main thread was during each wait of a second or more,
/// which uitests.sh shows.
final class GalleryWatch: @unchecked Sendable {
    static let shared = GalleryWatch()

    /// A wait from which the watch notes a stall, with when it began.
    static let stall: TimeInterval = 0.25
    /// From how long a wait the watch looks at where the main thread is, as
    /// it asks.
    private static let lookFrom: TimeInterval = 0.2
    /// From how long a wait where the main thread was is written down.
    private static let writeFrom: TimeInterval = 1
    private static let interval: DispatchTimeInterval = .milliseconds(100)
    private static var now: TimeInterval { ProcessInfo.processInfo.systemUptime }

    private let lock = NSLock()
    private let queue = DispatchQueue(label: "Gallery main thread watch", qos: .userInteractive)
    private var timer: DispatchSourceTimer?
    private let started = GalleryWatch.now
    /// When the question still unanswered was asked.
    private var asked: TimeInterval?
    /// Where the main thread was seen meanwhile.
    private var looks: [GalleryLook] = []
    private var countsFrom: TimeInterval?
    private var inBackground = false
    private var longest: TimeInterval = 0
    private var stalls: [(at: TimeInterval, wait: TimeInterval)] = []
    /// The time spent answering the tests' questions: the most in one wait,
    /// and how many waits it held the main thread a quarter of a second or
    /// more.
    private var testsLongest: TimeInterval = 0
    private var testsStalls = 0
    private var observers: [NSObjectProtocol] = []
    /// How long to hold the main thread, once, on purpose.
    private var hold: TimeInterval?

    /// Starts asking, on the main thread; with HOLDING, holds the main
    /// thread once for that many seconds, a second after the watch starts
    /// counting.
    func start(holding: TimeInterval? = nil) {
        GalleryMainStack.noteMainThread()
        GalleryMainStack.writeDown("== The gallery started, with " + ProcessInfo.processInfo.arguments.dropFirst().joined(separator: " "))
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + Self.interval, repeating: Self.interval, leeway: .milliseconds(10))
        timer.setEventHandler { [weak self] in self?.ask() }
        let center = NotificationCenter.default
        let observers = [
            center.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: nil) { [weak self] _ in
                self?.becameActive()
            },
            center.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: nil) { [weak self] _ in
                self?.wentToBackground(true)
            },
            center.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: nil) { [weak self] _ in
                self?.wentToBackground(false)
            },
        ]
        lock.withLock {
            self.timer = timer
            self.observers = observers
            hold = holding
        }
        timer.resume()
    }

    /// What the tests read: the longest wait in milliseconds, and the
    /// stalls, each with when it began, in seconds from the start; then the
    /// time spent answering the tests' questions, apart.
    var readout: String {
        lock.withLock {
            var longest = self.longest
            // A wait still going on, as the tests read this.
            if let asked, let countsFrom, asked >= countsFrom {
                longest = max(longest, Self.ownPart(of: Self.now - asked, looks).own)
            }
            var text = "longest \(Self.milliseconds(longest)) ms, \(stalls.count) stalls"
            if !stalls.isEmpty {
                text += ": " + stalls.map { "\(Self.milliseconds($0.wait)) ms at \(String(format: "%.1f", $0.at)) s" }
                    .joined(separator: ", ")
            }
            if testsStalls > 0 {
                text += "; answering the tests' queries: longest \(Self.milliseconds(testsLongest)) ms, \(testsStalls) times"
            }
            if countsFrom == nil { text += ", not counting yet" }
            return text
        }
    }

    fileprivate static func milliseconds(_ seconds: TimeInterval) -> Int { Int((seconds * 1000).rounded()) }

    /// Of a wait of WAIT seconds during which the watch saw the main thread
    /// where LOOKS say: the part that counts, and the part spent answering
    /// the tests' questions.
    private static func ownPart(of wait: TimeInterval, _ looks: [GalleryLook])
        -> (own: TimeInterval, tests: TimeInterval) {
        var tests: TimeInterval = 0
        for (index, look) in looks.enumerated() where look.stack.answersTheTests {
            tests += GalleryLook.span(of: index, in: looks, upTo: wait)
        }
        tests = min(tests, wait)
        return (wait - tests, tests)
    }

    /// On the main thread, as the gallery becomes active.
    private func becameActive() {
        let hold: TimeInterval? = lock.withLock {
            guard countsFrom == nil else { return nil }
            countsFrom = Self.now + 1
            defer { self.hold = nil }
            return self.hold
        }
        guard let hold else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            NSLog("[Gallery] holding the main thread for %.1f s, as asked", hold)
            Thread.sleep(forTimeInterval: hold)
        }
    }

    private func wentToBackground(_ background: Bool) {
        lock.withLock {
            inBackground = background
            asked = nil
            looks = []
        }
    }

    /// On the watch's queue: asks the main thread, unless it has yet to
    /// answer the last question; then looks at where it is, from a fifth of
    /// a second into the wait.
    private func ask() {
        let now = Self.now
        let looking: TimeInterval? = lock.withLock {
            guard !inBackground else { return nil }
            guard let pending = asked else {
                asked = now
                looks = []
                DispatchQueue.main.async { [weak self] in self?.answer() }
                return nil
            }
            return now - pending >= Self.lookFrom ? pending : nil
        }
        guard let looking else { return }
        // Without the lock, which the main thread may be waiting for, or
        // hold: stopped, it cannot let go of it.
        guard let stack = GalleryMainStack.take() else { return }
        lock.withLock {
            if asked == looking { looks.append(GalleryLook(at: now - looking, stack: stack)) }
        }
    }

    /// On the main thread: the answer to the last question.
    private func answer() {
        let now = Self.now
        let record: (wait: TimeInterval, at: TimeInterval, looks: [GalleryLook])? = lock.withLock {
            guard let asked else { return nil }
            self.asked = nil
            let looks = self.looks
            self.looks = []
            guard let countsFrom, asked >= countsFrom else { return nil }
            let wait = now - asked
            let part = Self.ownPart(of: wait, looks)
            longest = max(longest, part.own)
            if part.own >= Self.stall {
                stalls.append((at: asked - started, wait: part.own))
                if stalls.count > 12 { stalls.removeFirst() }
            }
            testsLongest = max(testsLongest, part.tests)
            if part.tests >= Self.stall { testsStalls += 1 }
            return wait >= Self.stall ? (wait: wait, at: asked - started, looks: looks) : nil
        }
        guard let record else { return }
        let part = Self.ownPart(of: record.wait, record.looks)
        NSLog("[Gallery] the main thread took %ld ms to answer, %ld ms of them answering the tests' queries",
              Self.milliseconds(record.wait), Self.milliseconds(part.tests))
        guard record.wait >= Self.writeFrom, !record.looks.isEmpty else { return }
        // Written down from the watch's queue, not to hold the main thread.
        queue.async {
            var text = String(format: "%@ the main thread took %ld ms to answer, from %.1f s: %ld ms counted, %ld ms answering the tests' queries; where it was:",
                              GalleryMainStack.clock(), Self.milliseconds(record.wait), record.at,
                              Self.milliseconds(part.own), Self.milliseconds(part.tests))
            text += GalleryLook.describe(record.looks, upTo: record.wait)
            GalleryMainStack.writeDown(text)
        }
    }
}

/// Where the watch saw the main thread, AT seconds into a wait.
struct GalleryLook {
    let at: TimeInterval
    let stack: GalleryMainStack

    /// How long the look at INDEX of a wait of WAIT seconds stands for:
    /// from it to the next one, or to the answer; the first, from the
    /// question.
    static func span(of index: Int, in looks: [GalleryLook], upTo wait: TimeInterval) -> TimeInterval {
        let from = index == 0 ? 0 : min(looks[index].at, wait)
        let to = index + 1 < looks.count ? min(looks[index + 1].at, wait) : wait
        return max(0, to - from)
    }

    /// LOOKS of a wait of WAIT seconds, those in a row that saw the same
    /// told once, from when, with how long they stand for: of the places
    /// that count, eight at most, spread over the wait, with their frames;
    /// of those answering the tests' queries, the longest, more briefly.
    static func describe(_ looks: [GalleryLook], upTo wait: TimeInterval) -> String {
        var places: [(stack: GalleryMainStack, from: TimeInterval, looks: Int, seconds: TimeInterval)] = []
        for (index, look) in looks.enumerated() {
            let seconds = span(of: index, in: looks, upTo: wait)
            if let last = places.last, last.stack == look.stack {
                places[places.count - 1].looks += 1
                places[places.count - 1].seconds += seconds
            } else {
                places.append((stack: look.stack, from: look.at, looks: 1, seconds: seconds))
            }
        }
        let counted = places.filter { !$0.stack.answersTheTests }
        let answering = places.filter { $0.stack.answersTheTests }
        let most = 8
        let shown = counted.count <= most ? Array(counted.indices)
            : (0..<most).map { $0 * (counted.count - 1) / (most - 1) }
        var text = ""
        for index in shown {
            let place = counted[index]
            let times = place.looks == 1 ? "1 look" : "\(place.looks) looks"
            text += "\n  counted, from \(seconds(place.from)) s, \(GalleryWatch.milliseconds(place.seconds)) ms, \(times):"
            for line in place.stack.summary(most: 64) { text += "\n    " + line }
        }
        if counted.count > shown.count {
            text += "\n  and \(counted.count - shown.count) places more that count, among those above"
        }
        if let longest = answering.max(by: { $0.seconds < $1.seconds }) {
            let all = answering.reduce(TimeInterval(0)) { $0 + $1.seconds }
            let count = answering.count == 1 ? "1 place" : "\(answering.count) places"
            text += "\n  answering the tests' queries, \(GalleryWatch.milliseconds(all)) ms in \(count); the longest, "
                + "from \(seconds(longest.from)) s, \(GalleryWatch.milliseconds(longest.seconds)) ms:"
            for line in longest.stack.summary(most: 16) { text += "\n    " + line }
        }
        return text
    }

    /// "1.2", for seconds.
    private static func seconds(_ value: TimeInterval) -> String { String(format: "%.1f", value) }
}

/// Where the main thread was when the watch looked: an address in the code
/// of each frame of its call stack, the innermost first.
struct GalleryMainStack: Equatable {
    let addresses: [UInt]
    /// The outermost frame in iOS's accessibility or XCTest's, if any.
    let entry: Int?
    /// Whether the main thread was answering the tests' questions alone:
    /// in iOS's accessibility or XCTest's, called by the run loop or a
    /// queue, with none of the gallery's own code above them. iOS's
    /// accessibility also stands in for some of UIKit's methods, as the
    /// tests turn it on: there UIKit calls it, and the wait counts.
    let answersTheTests: Bool

    private static let capacity = 256
    /// Read into from the watch's queue alone.
    private static let buffer = UnsafeMutablePointer<UInt>.allocate(capacity: capacity)
    private static let galleryPath = Bundle.main.bundlePath + "/"

    /// On the main thread, before any look.
    static func noteMainThread() {
        if Thread.isMainThread {
            GalleryMainThreadNote()
        } else {
            DispatchQueue.main.async { GalleryMainThreadNote() }
        }
    }

    /// From the watch's queue: where the main thread is now, and whether
    /// it is answering the tests, from the images its frames are in.
    static func take() -> GalleryMainStack? {
        let count = Int(GalleryMainThreadStack(buffer, Int32(capacity)))
        guard count > 0 else { return nil }
        let addresses = Array(UnsafeBufferPointer(start: buffer, count: count))
        let images = addresses.indices.map { (index: Int) -> String in
            let address = inCall(addresses, index)
            if let path = GalleryImagePath(address) { return String(cString: path) }
            // Code outside every image's __TEXT, should there be any: dyld
            // knows, more slowly.
            var info = Dl_info()
            guard dladdr(UnsafeRawPointer(bitPattern: address), &info) != 0, let file = info.dli_fname else { return "" }
            return String(cString: file)
        }
        let entry = images.lastIndex(where: isAccessibility)
        var answers = false
        if let entry, entry + 1 < images.count {
            let caller = (images[entry + 1] as NSString).lastPathComponent
            let gallery = images[..<entry].contains { $0.hasPrefix(galleryPath) }
            answers = ["CoreFoundation", "Foundation", "libdispatch.dylib", "libxpc.dylib"].contains(caller) && !gallery
        }
        return GalleryMainStack(addresses: addresses, entry: entry, answersTheTests: answers)
    }

    /// The address of the call frame INDEX is in: where a caller goes on
    /// is just after its call, which may be the last instruction of its
    /// function.
    private static func inCall(_ addresses: [UInt], _ index: Int) -> UInt {
        index == 0 ? addresses[index] : addresses[index] &- 1
    }

    /// iOS's accessibility, which answers the tests' queries, and XCTest's
    /// part in the gallery, which waits for it to settle.
    private static func isAccessibility(_ image: String) -> Bool {
        let name = (image as NSString).lastPathComponent
        return image.contains("Accessibility") || image.contains(".axbundle/")
            || ["AX", "libAX", "XCT", "libXCT", "XCUI"].contains { name.hasPrefix($0) }
    }

    /// Each frame as "image symbol + offset", from dyld's symbols, and
    /// whether it is in the gallery's own code: slower, for what is written
    /// down.
    private var frames: [(text: String, gallery: Bool)] {
        addresses.indices.map { (index: Int) -> (text: String, gallery: Bool) in
            let address = Self.inCall(addresses, index)
            var info = Dl_info()
            guard dladdr(UnsafeRawPointer(bitPattern: address), &info) != 0, let file = info.dli_fname else {
                return (text: String(format: "0x%lx", addresses[index]), gallery: false)
            }
            let path = String(cString: file)
            let name = (path as NSString).lastPathComponent
            var text = "\(name) + \(address &- UInt(bitPattern: info.dli_fbase))"
            if let symbol = info.dli_sname, let start = info.dli_saddr {
                text = "\(name) \(String(cString: symbol)) + \(address &- UInt(bitPattern: start))"
            }
            return (text: text, gallery: path.hasPrefix(Self.galleryPath))
        }
    }

    /// What is written down of it, in MOST lines or about: every frame, or
    /// its innermost ones, those of the gallery's own code with their
    /// neighbours, those around the outermost in iOS's accessibility or
    /// XCTest's, and the outermost.
    func summary(most: Int) -> [String] {
        let frames = self.frames
        guard frames.count > most else { return frames.map { $0.text } }
        let last = frames.count - 1
        var kept = Set(0..<(most / 3))
        for (index, frame) in frames.enumerated() where frame.gallery {
            kept.formUnion(max(0, index - 1)...min(last, index + 1))
        }
        if let entry { kept.formUnion(max(0, entry - 2)...min(last, entry + 3)) }
        kept.formUnion(max(0, last - 2)...last)
        var lines: [String] = []
        var previous = -1
        for index in kept.sorted() {
            if lines.count >= most {
                lines.append("… and \(last - previous) frames more")
                break
            }
            if index > previous + 1 { lines.append("… \(index - previous - 1) frames …") }
            lines.append(frames[index].text)
            previous = index
        }
        return lines
    }

    /// "2026-11-12 10:46:09.461Z", in UTC, as xcodebuild's log on the CI
    /// has it.
    static func clock() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS'Z'"
        return formatter.string(from: Date())
    }

    /// Where the gallery writes down where its main thread was: its tmp
    /// folder, which the Files picker does not show.
    static let file = FileManager.default.temporaryDirectory.appendingPathComponent("gallery-main-thread.txt")

    /// Adds TEXT to the file, as a paragraph of its own.
    static func writeDown(_ text: String) {
        let data = Data((text + "\n\n").utf8)
        guard let handle = try? FileHandle(forWritingTo: file) else {
            try? data.write(to: file)
            return
        }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: data)
    }
}

/// The watch's readout in the accessibility tree, as an element of two
/// points by two that draws nothing and takes no touch: its label is read
/// as the tests ask for it.
struct GalleryWatchReadout: UIViewRepresentable {
    final class Element: UIView {
        override init(frame: CGRect) {
            super.init(frame: frame)
            isAccessibilityElement = true
            accessibilityIdentifier = "gallery.watch"
            accessibilityTraits = .staticText
            isUserInteractionEnabled = false
            backgroundColor = .clear
        }

        required init?(coder: NSCoder) {
            fatalError("init(coder:) is not used")
        }

        override var accessibilityLabel: String? {
            get { "Main thread: " + GalleryWatch.shared.readout }
            set {}
        }
    }

    func makeUIView(context: Context) -> Element { Element(frame: .zero) }
    func updateUIView(_ view: Element, context: Context) {}
}

// MARK: The built-in SideStore's sign-in

/// The built-in SideStore's sign-in, as CartoucheAccount finds it by its
/// Objective-C name and calls it (launcher/SideStoreSupport/CartoucheSignIn.swift),
/// stood in for: it reads the Apple ID and password Cartouche left in their
/// shared keychain, as SideStore's Sign In to Cartouche action does, and
/// answers by the Apple ID:
///
/// - with "code" in it, Apple asks for a verification code sent by text
///   message (CartoucheSignInMessage): 123456 signs the player in, another
///   code gets a new request that says it was wrong, and Cancel ends the
///   sign-in;
/// - with "limit" in it, Apple refuses more sign-ins for now, with its page
///   of HTTP 429, Too Many Requests, as SideStore passed it on before
///   app/patches/sidestore/0016;
/// - any other signs the player in.
///
/// Once signed in, the gallery has the Apple ID and the certificate, as the
/// built-in SideStore leaves them for Cartouche.
@objc(CartoucheSignIn)
final class GallerySideStore: NSObject {
    static let code = "123456"

    /// `completion` runs on the main queue, with nil or the error's text, as
    /// SideStore's does.
    @objc(signInWithProgress:completion:)
    static func signIn(progress: Progress, completion: @escaping (String?) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let message = GallerySideStore.signIn(progress)
            DispatchQueue.main.async { completion(message) }
        }
    }

    private static func signIn(_ progress: Progress) -> String? {
        guard let data = CartoucheStoreKeychain.data(CartoucheSignInMessage.credentialsAccount),
              let fields = try? JSONSerialization.jsonObject(with: data) as? [String: String],
              let appleID = fields["appleID"], !(fields["password"] ?? "").isEmpty else {
            return "Cartouche left no Apple ID and password in the keychain."
        }
        // SideStore reads them once.
        CartoucheStoreKeychain.remove(CartoucheSignInMessage.credentialsAccount)
        progress.completedUnitCount = 20
        Thread.sleep(forTimeInterval: 0.6)
        if appleID.contains("limit") {
            return "<html><head><title>429 Too Many Requests</title></head>"
                + "<body><h1>429 Too Many Requests</h1></body></html>"
        }
        if appleID.contains("code") {
            var error: String?
            while true {
                let id = UUID().uuidString
                let request: [String: Any] = ["id": id, "mode": "sms", "phone": "+33 •• •• •• •• 78",
                                              "canTextMessage": false, "error": error ?? ""]
                guard let written = try? JSONSerialization.data(withJSONObject: request),
                      CartoucheStoreKeychain.set(written, for: CartoucheSignInMessage.requestAccount) else {
                    return "The verification code could not be asked for."
                }
                let answer = waitForAnswer(to: id)
                CartoucheStoreKeychain.remove(CartoucheSignInMessage.requestAccount)
                CartoucheStoreKeychain.remove(CartoucheSignInMessage.responseAccount)
                guard let answer else { return "No verification code came in time." }
                if answer["action"] == "cancel" { return "The sign-in was cancelled." }
                if answer["code"] == code { break }
                error = "Incorrect verification code."
            }
        }
        progress.completedUnitCount = 80
        Thread.sleep(forTimeInterval: 0.6)
        DispatchQueue.main.sync { GalleryState.setupDone = true }
        progress.completedUnitCount = 100
        return nil
    }

    /// The player's answer to the request ID, as Cartouche leaves it.
    private static func waitForAnswer(to id: String) -> [String: String]? {
        let deadline = Date().addingTimeInterval(120)
        while Date() < deadline {
            if let data = CartoucheStoreKeychain.data(CartoucheSignInMessage.responseAccount),
               let answer = try? JSONSerialization.jsonObject(with: data) as? [String: String], answer["id"] == id {
                return answer
            }
            Thread.sleep(forTimeInterval: 0.2)
        }
        return nil
    }
}
