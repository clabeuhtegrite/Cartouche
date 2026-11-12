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
//    the screen came back afterwards;
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
final class GalleryWatch: @unchecked Sendable {
    static let shared = GalleryWatch()

    /// A wait from which the watch notes a stall, with when it began.
    static let stall: TimeInterval = 0.25
    private static let interval: DispatchTimeInterval = .milliseconds(100)
    private static var now: TimeInterval { ProcessInfo.processInfo.systemUptime }

    private let lock = NSLock()
    private let queue = DispatchQueue(label: "Gallery main thread watch", qos: .userInteractive)
    private var timer: DispatchSourceTimer?
    private let started = GalleryWatch.now
    /// When the question still unanswered was asked.
    private var asked: TimeInterval?
    private var countsFrom: TimeInterval?
    private var inBackground = false
    private var longest: TimeInterval = 0
    private var stalls: [(at: TimeInterval, wait: TimeInterval)] = []
    private var observers: [NSObjectProtocol] = []
    /// How long to hold the main thread, once, on purpose.
    private var hold: TimeInterval?

    /// Starts asking; with HOLDING, holds the main thread once for that many
    /// seconds, a second after the watch starts counting.
    func start(holding: TimeInterval? = nil) {
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
    /// stalls, each with when it began, in seconds from the start.
    var readout: String {
        lock.withLock {
            var text = "longest \(Self.milliseconds(longest)) ms, \(stalls.count) stalls"
            if !stalls.isEmpty {
                text += ": " + stalls.map { "\(Self.milliseconds($0.wait)) ms at \(String(format: "%.1f", $0.at)) s" }
                    .joined(separator: ", ")
            }
            if countsFrom == nil { text += ", not counting yet" }
            return text
        }
    }

    private static func milliseconds(_ seconds: TimeInterval) -> Int { Int((seconds * 1000).rounded()) }

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
        }
    }

    /// On the watch's queue: asks the main thread, unless it has yet to
    /// answer the last question, which then counts as a wait so far.
    private func ask() {
        let now = Self.now
        lock.lock()
        defer { lock.unlock() }
        guard !inBackground else { return }
        if let asked {
            note(now - asked, askedAt: asked, answered: false)
        } else {
            asked = now
            DispatchQueue.main.async { [weak self] in self?.answer() }
        }
    }

    /// On the main thread: the answer to the last question.
    private func answer() {
        let now = Self.now
        lock.lock()
        defer { lock.unlock() }
        guard let asked else { return }
        self.asked = nil
        note(now - asked, askedAt: asked, answered: true)
    }

    /// Under the lock.
    private func note(_ wait: TimeInterval, askedAt: TimeInterval, answered: Bool) {
        guard let countsFrom, askedAt >= countsFrom else { return }
        longest = max(longest, wait)
        guard answered, wait >= Self.stall else { return }
        stalls.append((at: askedAt - started, wait: wait))
        if stalls.count > 12 { stalls.removeFirst() }
        NSLog("[Gallery] the main thread took %ld ms to answer", Self.milliseconds(wait))
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
