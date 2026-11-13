//
//  HarnessScenes.swift
//  CartoucheHarness
//
//  A game behind the console, as LiveContainer runs one: its
//  AppSceneViewController (MultitaskSupport/AppSceneViewController.m)
//  starts the game in a process of LiveContainer's LiveProcess extension
//  and shows its scene, which FrontBoard keeps the settings of. The
//  harness has no such process: its stand-in goes through the same steps,
//  on the same threads, and calls Cartouche back as LiveContainer does,
//  in the same order. The tests play the game's part, and iOS's: the game
//  writes its memory where Cartouche reads it and posts the presses of a
//  controller's Home button (launcher/LiveProcessSupport/CartoucheGuest.m),
//  and iOS may kill it. On a TV, LiveContainer opens a second scene of the
//  game's process (app/patches/livecontainer/0012), which the game fills
//  with its picture: the harness's stands in with a view of its own.
//

import Foundation
import UIKit

/// FrontBoard's settings of the game's scene: whether it is in the
/// foreground, and why it is not active.
final class UIMutableApplicationSceneSettings: NSObject {
    @objc var foreground = true
    var deactivationReasons: UInt = 0
    var interruptionPolicy: Int = 0

    func copySettings() -> UIMutableApplicationSceneSettings {
        let copy = UIMutableApplicationSceneSettings()
        copy.foreground = foreground
        copy.deactivationReasons = deactivationReasons
        copy.interruptionPolicy = interruptionPolicy
        return copy
    }
}

/// The game's scene, as FrontBoard holds it: its settings, as the last
/// update left them, and whether each update left it in the foreground.
final class FBScene: NSObject {
    private(set) var settings = UIMutableApplicationSceneSettings()
    private(set) var foregroundUpdates: [Bool] = []

    func updateSettings(_ block: (UIMutableApplicationSceneSettings?) -> Void) {
        block(settings)
        foregroundUpdates.append(settings.foreground)
    }

    func updateSettings(_ settings: UIMutableApplicationSceneSettings!, withTransitionContext context: Any!, completion: Any!) {
        if let settings {
            self.settings = settings
        }
        foregroundUpdates.append(self.settings.foreground)
    }
}

final class _UIScenePresenter: NSObject {
    let scene: FBScene!

    init(scene: FBScene) {
        self.scene = scene
    }
}

@objc protocol AppSceneViewControllerDelegate: NSObjectProtocol {
    func appSceneVCAppDidExit(_ vc: AppSceneViewController!)
    func appSceneVC(_ vc: AppSceneViewController!, didInitializeWithError error: Error!)
    @objc optional func appSceneVC(_ vc: AppSceneViewController!, didUpdateFrom settings: UIMutableApplicationSceneSettings!,
                                   transitionContext context: Any!, lifecycleActionType actionType: UInt32)
    @objc optional func appSceneVCWillActivateScene(_ vc: AppSceneViewController!)
}

class AppSceneViewController: UIViewController {
    var bundleId: String!
    var dataUUID: String!
    var pid: Int32 = 0
    var delegate: AppSceneViewControllerDelegate!
    var shouldIgnoreSceneUpdates = false
    var shouldSkipDebounceOnce = false
    var scaleRatio: CGFloat = 1
    var contentView: UIView!
    var presenter: _UIScenePresenter!

    /// Whether the game's process runs: LiveContainer asks the kernel
    /// (getpgid of its pid).
    private var processRuns = false
    private var cleanedUp = false
    /// When Cartouche stopped the game, if it did.
    private(set) var terminatedAt: Date?

    var isAppRunning: Bool {
        pid > 0 && processRuns
    }

    init!(bundleId: String!, dataUUID: String!, delegate: AppSceneViewControllerDelegate!) {
        super.init(nibName: nil, bundle: nil)
        self.delegate = delegate
        self.dataUUID = dataUUID
        self.bundleId = bundleId

        let start = HarnessLC.nextGameStart
        if start == .noExtension {
            let error = NSError(domain: NSCocoaErrorDomain, code: 4,
                                userInfo: [NSLocalizedDescriptionKey: "The LiveProcess extension could not be found."])
            delegate?.appSceneVC(self, didInitializeWithError: error)
            return nil
        }
        HarnessScenes.made(self)

        // NSExtension beginExtensionRequestWithInputItems: answers on a
        // queue of its own.
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 0.05) {
            switch start {
            case .starts, .crashes:
                self.pid = HarnessScenes.newPID()
                self.processRuns = true
                self.delegate?.appSceneVC(self, didInitializeWithError: nil)
                DispatchQueue.main.async {
                    self.setUpAppPresenter()
                }
                if start == .crashes {
                    DispatchQueue.global().asyncAfter(deadline: .now() + 0.4) {
                        self.processEnded()
                    }
                }
            case .refused:
                let error = NSError(domain: "LiveProcess", code: 2,
                                    userInfo: [NSLocalizedDescriptionKey: "Failed to start app. Child process has unexpectedly crashed"])
                self.delegate?.appSceneVC(self, didInitializeWithError: error)
            case .noExtension:
                break
            }
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    /// The scene of the game's process, shown in this view controller's
    /// view, once Cartouche has had its say on how it shows.
    private func setUpAppPresenter() {
        guard processRuns else { return }
        presenter = _UIScenePresenter(scene: FBScene())
        let content = UIView()
        content.backgroundColor = .systemIndigo
        content.accessibilityIdentifier = "harness.game." + (dataUUID ?? "")
        contentView = content
        delegate?.appSceneVCWillActivateScene?(self)
        view.addSubview(content)
        HarnessScenes.shown(self)
    }

    func setBackgroundNotificationEnabled(_ enabled: Bool) {}

    func updateSettings(with block: (UIMutableApplicationSceneSettings?) -> Void) {
        presenter?.scene?.updateSettings(block)
    }

    func openURLScheme(_ urlString: String!) {}

    func usesHostingControllerAPI() -> Bool {
        true
    }

    /// SIGTERM, and SIGKILL three seconds later.
    func terminate() {
        guard isAppRunning else { return }
        terminatedAt = Date()
        let atOnce = HarnessLC.gameEndsOnTerminate
        DispatchQueue.global().asyncAfter(deadline: .now() + (atOnce ? 0.05 : 3)) {
            self.processEnded()
        }
    }

    /// The game's process has ended: LiveContainer's extension says so
    /// (its request's interruption block), and the scene goes.
    private func processEnded() {
        guard processRuns else { return }
        processRuns = false
        if HarnessLC.extensionReportsExit {
            appTerminationCleanUp()
        }
    }

    func appTerminationCleanUp() {
        if cleanedUp {
            return
        }
        cleanedUp = true
        DispatchQueue.main.async {
            self.closeExternalDisplayScene()
            self.presenter = nil
            self.delegate?.appSceneVCAppDidExit(self)
            HarnessScenes.ended(self)
        }
    }

    // MARK: The game's scene on a TV

    /// The game's second scene, on a TV, while it is open: what the game
    /// shows there, nxnative its picture.
    private(set) var tvScene: UIViewController?
    /// The screens LiveContainer opened it on, the newest last.
    private(set) var tvOpenings: [UIScreen] = []
    /// Whether each change Cartouche made left it in the foreground.
    private(set) var tvForegroundUpdates: [Bool] = []
    private(set) var tvClosings = 0

    /// A second scene of the game's process on SCREEN, as LiveContainer
    /// opens one (app/patches/livecontainer/0012): nil when the game does
    /// not run, or when this iOS has no such scene.
    func openExternalDisplayScene(on screen: UIScreen!) -> UIViewController! {
        closeExternalDisplayScene()
        guard HarnessLC.gamesHaveATVScene, let screen, isAppRunning else { return nil }
        let made = UIViewController()
        made.view.backgroundColor = .systemTeal
        made.view.accessibilityIdentifier = "harness.tv." + (dataUUID ?? "")
        tvScene = made
        tvOpenings.append(screen)
        return made
    }

    func setExternalDisplaySceneForeground(_ foreground: Bool) {
        guard tvScene != nil else { return }
        tvForegroundUpdates.append(foreground)
    }

    func closeExternalDisplayScene() {
        guard tvScene != nil else { return }
        tvScene = nil
        tvClosings += 1
    }

    // MARK: What the game and iOS do, for the tests

    /// iOS kills the game, for its memory or as it crashes.
    func kill() {
        DispatchQueue.global().async {
            self.processEnded()
        }
    }

    /// A press of the Home button of a controller the game has, which the
    /// game's process posts.
    func pressControllerHome() {
        let name = "CartoucheGameHome." + (dataUUID ?? "")
        CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(), CFNotificationName(name as CFString),
                                             nil, nil, true)
    }

    /// Cartouche's own scene changed, as when the player comes back to it,
    /// or leaves it for another app (FOREGROUND false): LiveContainer hands
    /// the change on, for the game's scene to take.
    func hostSceneChanged(foreground: Bool = true) {
        if !isAppRunning {
            appTerminationCleanUp()
            return
        }
        guard let presenter, let scene = presenter.scene else { return }
        let settings = scene.settings.copySettings()
        settings.foreground = foreground
        settings.interruptionPolicy = 2
        delegate?.appSceneVC?(self, didUpdateFrom: settings, transitionContext: nil, lifecycleActionType: 0)
    }

    /// The game's memory, as its process writes it every two seconds in
    /// the app group (CartoucheGuest.m): FOOTPRINT now, at most PEAK, and
    /// AVAILABLE more before iOS's limit; and whether the process has
    /// Increased Memory Limit, as its signature gives it, nil when it could
    /// not tell.
    func writeMemory(footprintMiB: UInt64, availableMiB: UInt64, peakMiB: UInt64? = nil, started: Date = Date(),
                     increasedMemoryLimit: Bool? = true) {
        guard let file = CartoucheGameMemoryReading.file else { return }
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let footprint = footprintMiB << 20
        let available = availableMiB << 20
        var reading: [String: Any] = [
            "bundle": bundleId ?? "",
            "container": dataUUID ?? "",
            "pid": NSNumber(value: pid),
            "started": started,
            "updated": Date(),
            "footprint": NSNumber(value: footprint),
            "peak": NSNumber(value: max(peakMiB.map { $0 << 20 } ?? footprint, footprint)),
            "available": NSNumber(value: available),
            "limit": NSNumber(value: footprint + available),
            "sizes": [[String: Any]](),
        ]
        if let increasedMemoryLimit {
            reading["increasedMemoryLimit"] = NSNumber(value: increasedMemoryLimit)
        }
        (reading as NSDictionary).write(to: file, atomically: true)
    }
}

/// The games behind the console that LiveContainer started, for the tests.
enum HarnessScenes {
    private static var lastPID: Int32 = 70_000
    /// Every scene made, the newest last.
    private(set) static var all: [AppSceneViewController] = []
    /// The scenes whose game showed.
    private(set) static var shownCount = 0
    /// The scenes whose game ended, and LiveContainer said so.
    private(set) static var endedCount = 0

    /// The newest scene, if its game still runs.
    static var running: AppSceneViewController? {
        guard let last = all.last, last.isAppRunning else { return nil }
        return last
    }

    static func reset() {
        all = []
        shownCount = 0
        endedCount = 0
    }

    static func newPID() -> Int32 {
        objc_sync_enter(HarnessScenesLock.shared)
        defer { objc_sync_exit(HarnessScenesLock.shared) }
        lastPID += 1
        return lastPID
    }

    static func made(_ scene: AppSceneViewController) {
        all.append(scene)
    }

    static func shown(_ scene: AppSceneViewController) {
        shownCount += 1
    }

    static func ended(_ scene: AppSceneViewController) {
        endedCount += 1
    }
}

private final class HarnessScenesLock {
    static let shared = HarnessScenesLock()
}
