//
//  CartoucheImportPicker.swift
//  Cartouche
//
//  The Files picker a game's IPA is imported with, from the home, a game's
//  sheet or the guide: one picker, which UIKit shows over whatever is on
//  screen, as LiveContainer's own app shows its pickers (betterFileImporter
//  in ViewExtensions.swift), rather than a SwiftUI file importer on each
//  screen, each shown from a state of its own. It opens the IPA where it
//  is, as the importers did: a game's IPA is too large to copy first.
//
//  The picker runs in a process of iOS's, inside Cartouche's window. When it
//  leaves the screen without a word to Cartouche, or never comes, as when
//  that process ends, Cartouche sees it within a second: the console takes
//  the controller again, and the next Import shows a new picker. The
//  controller cannot move in the picker, but its B closes it, as it closes
//  the console's sheets, which leave it the button meanwhile.
//
//  Each picker is measured (CartouchePickerMeasures): when it came on
//  screen, how and when it closed, and how long Cartouche's main thread,
//  which passes the picker every touch, took to answer meanwhile, asked
//  four times a second from another thread. The measures go into the
//  journal and the game measurements, and are written down every second
//  while the picker is open: one still open when Cartouche ended is told at
//  the next start (noteLeftOpen).
//

import Combine
import UIKit
import UniformTypeIdentifiers

@available(iOS 17.0, *)
@MainActor
final class CartoucheImportPicker: ObservableObject {
    /// Where the player asked for the picker.
    enum Place: String {
        case home, sheet, guide
    }

    static let shared = CartoucheImportPicker()

    /// Whether a picker is open: the console and its sheets leave the
    /// controller to it.
    @Published private(set) var isShowing = false

    private var picker: UIDocumentPickerViewController?
    private var onPick: ((URL) -> Void)?
    /// The last picker taken for gone, should it answer after all.
    private weak var lostPicker: UIDocumentPickerViewController?
    private var lostOnPick: ((URL) -> Void)?
    /// Whether the picker was handed to UIKit to show.
    private var presented = false
    private var watch: CartouchePickerWatch?
    private var presence: Task<Void, Never>?
    private var observers: [AnyCancellable] = []
    /// The picker's answers; it keeps them weakly.
    private let calls = CartoucheImportPickerCalls()

    /// How long a sheet coming or going may keep the picker from showing.
    private static let showingWait: TimeInterval = 5

    /// Shows the picker over what is on screen, from PLACE: ONPICK installs
    /// the IPA picked, once the picker has gone. A picker already open
    /// stays; one that went without a word gives way to a new one.
    func pick(from place: Place, _ onPick: @escaping (URL) -> Void) {
        if let open = self.picker {
            guard !Self.isOnScreen(open) else { return }
            close(.lost)
        }
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.ipa], asCopy: false)
        picker.delegate = calls
        picker.allowsMultipleSelection = false
        picker.shouldShowFileExtensions = true
        self.picker = picker
        self.onPick = onPick
        presented = false
        let measures = CartouchePickerMeasures(place: place.rawValue, opened: Date(),
                                               controller: CartoucheGamepad.shared.isConnected)
        let watch = CartouchePickerWatch(measures)
        self.watch = watch
        isShowing = true
        CartoucheReports.note("Files picker opening, from " + CartouchePickerMeasures.placeName(place.rawValue))
        listen()
        watch.start()
        show(picker, attempt: 0)
        watchPresence(of: picker, opened: measures.opened)
    }

    private static var leftOpenNoted = false

    /// A picker was open when Cartouche last ended, as when the player quit
    /// it from the App Switcher: told once, as Cartouche starts.
    static func noteLeftOpen() {
        guard !leftOpenNoted else { return }
        leftOpenNoted = true
        guard let measures = CartouchePickerMark.standard.take() else { return }
        report(measures, .quit, at: measures.lastSeen)
    }

    // MARK: The picker's answers

    fileprivate func answered(_ url: URL?, by controller: UIDocumentPickerViewController) {
        let install: ((URL) -> Void)?
        if controller === self.picker {
            install = self.onPick
            close(url == nil ? .cancelled : .picked)
        } else if controller === lostPicker, self.picker == nil {
            // Taken for gone, it answered after all: the player's pick
            // stands.
            install = lostOnPick
            lostPicker = nil
            lostOnPick = nil
            CartoucheReports.note("Files picker: " + (url == nil ? "cancelled" : "picked") + " after all")
        } else {
            return
        }
        guard let url, let onPick = install else { return }
        // Once the picker has gone: the install that follows closes the
        // sheet it showed over.
        if controller.isBeingDismissed, let coordinator = controller.transitionCoordinator {
            _ = coordinator.animate(alongsideTransition: nil) { _ in onPick(url) }
        } else {
            onPick(url)
        }
    }

    // MARK: Showing

    /// Hands PICKER to UIKit over the view controller at the top of
    /// Cartouche's window, once a sheet coming or going there is in place.
    private func show(_ picker: UIDocumentPickerViewController, attempt: Int) {
        guard self.picker === picker else { return }
        guard let top = Self.topController() else {
            CartoucheReports.note("Files picker: no window to show it in")
            close(.lost)
            return
        }
        if attempt < 3, let coordinator = top.transitionCoordinator {
            _ = coordinator.animate(alongsideTransition: nil) { [weak self] _ in
                self?.show(picker, attempt: attempt + 1)
            }
            return
        }
        presented = true
        top.present(picker, animated: true) { [weak self] in
            guard let self, self.picker === picker else { return }
            self.watch?.update { $0.shown = Date() }
        }
    }

    /// The view controller at the top of Cartouche's window in front: the
    /// console, or the sheet over it, or the one over that.
    private static func topController() -> UIViewController? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let scene = scenes.first { $0.activationState == .foregroundActive && $0.keyWindow != nil }
            ?? scenes.first { $0.keyWindow != nil }
        guard var top = scene?.keyWindow?.rootViewController else { return nil }
        while let presented = top.presentedViewController, !presented.isBeingDismissed {
            top = presented
        }
        return top
    }

    /// Whether PICKER is on screen, or on its way there or away.
    private static func isOnScreen(_ picker: UIViewController) -> Bool {
        picker.presentingViewController != nil || picker.isBeingPresented || picker.isBeingDismissed
            || picker.viewIfLoaded?.window != nil
    }

    /// Every second while PICKER is open: whether it is still on screen. A
    /// picker gone without a word closes, so that the console takes the
    /// controller again; one still waiting to show, after a few seconds.
    private func watchPresence(of picker: UIDocumentPickerViewController, opened: Date) {
        presence = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard let self, self.picker === picker, !Task.isCancelled else { return }
                if Self.isOnScreen(picker) { continue }
                if !self.presented, Date().timeIntervalSince(opened) < Self.showingWait { continue }
                self.close(.lost)
                return
            }
        }
    }

    // MARK: Closing

    /// What the picker meets while it is open: the controller's B closes
    /// it, once every view has had the button, so that the sheet under it
    /// does not take it too; and Cartouche in the background is no wait of
    /// its main thread.
    private func listen() {
        observers = [
            CartoucheGamepad.shared.inputs
                .filter { $0 == .b }
                .sink { [weak self] _ in self?.closeWithControllerSoon() },
            NotificationCenter.default.publisher(for: UIApplication.didEnterBackgroundNotification)
                .sink { [weak self] _ in self?.watch?.pause() },
            NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)
                .sink { [weak self] _ in self?.watch?.resume() },
        ]
    }

    private func closeWithControllerSoon() {
        Task { @MainActor in
            guard let picker = self.picker else { return }
            self.close(.closed)
            picker.dismiss(animated: true)
        }
    }

    /// The picker is over, with OUTCOME: its measures go into the journal
    /// and the measurements, and the console takes the controller again.
    private func close(_ outcome: CartouchePickerMeasures.Outcome) {
        guard picker != nil else { return }
        presence?.cancel()
        presence = nil
        observers = []
        let measures = watch?.stop()
        watch = nil
        lostPicker = outcome == .lost ? picker : nil
        lostOnPick = outcome == .lost ? onPick : nil
        picker = nil
        onPick = nil
        presented = false
        isShowing = false
        if let measures { Self.report(measures, outcome, at: outcome == .quit ? measures.lastSeen : Date()) }
    }

    private static func report(_ measures: CartouchePickerMeasures, _ outcome: CartouchePickerMeasures.Outcome, at date: Date) {
        CartoucheReports.note(measures.line(outcome, at: date))
        CartoucheTelemetry.shared.event("import.picker", fields: measures.fields(outcome, at: date))
    }
}

/// The picker's answers, on to CartoucheImportPicker. UIKit gives them on
/// the main thread.
@available(iOS 17.0, *)
private final class CartoucheImportPickerCalls: NSObject, UIDocumentPickerDelegate {
    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        MainActor.assumeIsolated { CartoucheImportPicker.shared.answered(urls.first, by: controller) }
    }

    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
        MainActor.assumeIsolated { CartoucheImportPicker.shared.answered(nil, by: controller) }
    }
}

/// Cartouche's main thread, asked from another thread four times a second
/// while a picker is open how long it takes to answer: the measures, written
/// down every second, so that a wait that never ends is on disk too.
final class CartouchePickerWatch: @unchecked Sendable {
    private static let interval: DispatchTimeInterval = .milliseconds(250)

    private let lock = NSLock()
    private let queue = DispatchQueue(label: "Cartouche picker watch")
    private var timer: DispatchSourceTimer?
    private var measures: CartouchePickerMeasures
    /// When the question still unanswered was asked.
    private var asked: Date?
    private var written = Date.distantPast
    private var paused = false
    private var stopped = false

    init(_ measures: CartouchePickerMeasures) {
        self.measures = measures
    }

    func start() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + Self.interval, repeating: Self.interval, leeway: .milliseconds(25))
        timer.setEventHandler { [weak self] in self?.ask() }
        lock.lock()
        self.timer = timer
        lock.unlock()
        timer.resume()
    }

    /// Changes the measures, as the picker comes on screen.
    func update(_ change: (inout CartouchePickerMeasures) -> Void) {
        lock.lock()
        defer { lock.unlock() }
        change(&measures)
    }

    /// Cartouche went to the background, where iOS may suspend it: no wait
    /// of its main thread until it is back.
    func pause() {
        lock.lock()
        paused = true
        asked = nil
        measures.wentToBackground = true
        let measures = stopped ? nil : self.measures
        lock.unlock()
        if let measures { CartouchePickerMark.standard.write(measures) }
    }

    func resume() {
        lock.lock()
        defer { lock.unlock() }
        paused = false
        asked = nil
    }

    /// Stops asking and wipes what was written down: the measures, as they
    /// ended.
    func stop() -> CartouchePickerMeasures {
        lock.lock()
        stopped = true
        let timer = self.timer
        self.timer = nil
        lock.unlock()
        timer?.cancel()
        // An answer being written down as it stopped is written first.
        queue.sync {}
        CartouchePickerMark.standard.clear()
        lock.lock()
        defer { lock.unlock() }
        return measures
    }

    /// On the watch's queue: asks the main thread, unless it has yet to
    /// answer the last question, which then counts as a wait so far.
    private func ask() {
        let now = Date()
        lock.lock()
        guard !stopped, !paused else {
            lock.unlock()
            return
        }
        if let asked {
            measures.stillWaiting(for: now.timeIntervalSince(asked), at: now)
        } else {
            asked = now
            DispatchQueue.main.async { [weak self] in self?.answer() }
        }
        var toWrite: CartouchePickerMeasures?
        if now.timeIntervalSince(written) >= 1 {
            written = now
            toWrite = measures
        }
        lock.unlock()
        if let toWrite { CartouchePickerMark.standard.write(toWrite) }
    }

    /// On the main thread: the answer to the last question.
    private func answer() {
        let now = Date()
        lock.lock()
        defer { lock.unlock() }
        guard let asked, !stopped, !paused else { return }
        measures.answered(after: now.timeIntervalSince(asked), at: now)
        self.asked = nil
    }
}
