//
//  CartoucheGameHost.swift
//  Cartouche
//
//  A game that runs behind the console instead of in Cartouche's place
//  (docs/decisions.md, 38). LiveContainer starts it in its LiveProcess
//  extension, a process of its own, and shows the game's scene in a view
//  controller of Cartouche's, AppSceneViewController, as its multitasking
//  windows do. Cartouche shows it full screen, in a window of its own over
//  the console, so that the console stays open under the game:
//
//  - the Home button at the bottom of the screen, and the Home button of a
//    controller, show the console and pause the game: its scene goes to the
//    background, as when the player leaves an app, where nxnative pauses
//    the game, its sound and its GPU work (front_ios.m); the controller's
//    Home button again, or Resume on the console, brings it back;
//  - Quit, on the console, stops the game's process;
//  - a game that iOS stops comes back to the console, which says why when
//    it can tell (CartoucheGameActions.gameDidEnd).
//
//  The game's own process measures its memory, and posts the presses of a
//  controller's Home button while the game has the controller
//  (launcher/LiveProcessSupport/CartoucheGuest.m).
//

import Combine
import GameController
import UIKit

@available(iOS 18.0, *)
@MainActor
final class CartoucheGameHost {
    static let shared = CartoucheGameHost()

    private(set) var app: LCAppModel?
    /// On screen, rather than paused behind the console.
    private(set) var isInFront = false
    private var scene: AppSceneViewController?
    private var window: UIWindow?
    private weak var consoleWindow: UIWindow?
    private var screen: CartoucheGameScreen?
    private var starting: CheckedContinuation<Void, Error>?
    private var quitting = false
    private var lastHome = Date.distantPast
    private var listensToHome = false
    private var homePresses: AnyCancellable?
    private var activation: NSObjectProtocol?
    private let calls = CartoucheGameSceneCalls()

    private init() {}

    // MARK: Start

    /// Starts APP, from its bundle folder BUNDLE with its data folder
    /// DATAFOLDER, on screen over the console. Returns once its process
    /// runs, or throws, and then nothing of it is left.
    func start(_ app: LCAppModel, bundle: String, dataFolder: String) async throws {
        guard self.app == nil, let host = Self.hostScene() else { throw CartoucheGameHostError() }
        self.app = app
        quitting = false
        consoleWindow = host.keyWindow

        let screen = CartoucheGameScreen(orientations: Self.orientations(of: app)) { [weak self] in
            self?.showConsole()
        }
        let window = UIWindow(windowScene: host)
        window.windowLevel = UIWindow.Level(rawValue: UIWindow.Level.normal.rawValue + 1)
        window.backgroundColor = .black
        window.rootViewController = screen
        window.alpha = 0
        window.makeKeyAndVisible()
        self.window = window
        self.screen = screen
        isInFront = true
        UIView.animate(withDuration: 0.25) { window.alpha = 1 }
        screen.rotate()
        // The player may play with a controller alone: the iPhone must not
        // lock meanwhile. iOS asks Cartouche, which is on screen.
        UIApplication.shared.isIdleTimerDisabled = true
        listenToHome(dataFolder: dataFolder)

        do {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                starting = continuation
                // As LiveContainer opens a window for a game
                // (LCUtils.launchMultitaskGuestApp): it starts the process.
                let made: AppSceneViewController? = AppSceneViewController(bundleId: bundle, dataUUID: dataFolder, delegate: calls)
                guard let made else {
                    // LiveContainer has said why, or says it in a moment.
                    Task { [weak self] in self?.failStart(CartoucheGameHostError()) }
                    return
                }
                scene = made
                screen.embed(made)
            }
        } catch {
            if let scene, scene.isAppRunning {
                scene.terminate()
            }
            tearDown()
            throw error
        }
        if GCController.controllers().contains(where: { $0.extendedGamepad?.buttonHome != nil }) {
            screen.showHint(CartoucheText.homeButtonHint)
        }
    }

    fileprivate func failStart(_ error: Error) {
        guard let starting else { return }
        self.starting = nil
        starting.resume(throwing: error)
    }

    fileprivate func didInitialize(_ error: Error?) {
        if let error {
            failStart(error)
        } else if let starting {
            self.starting = nil
            starting.resume()
        }
    }

    /// The game's scene is about to show: it fills the screen, and follows
    /// it as it turns or as the iPhone Duo folds.
    fileprivate func sceneWillShow(_ vc: AppSceneViewController) {
        if let content = vc.contentView {
            content.frame = vc.view.bounds
            content.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        }
        screen?.gameShows()
        if !isInFront {
            setGameForeground(false)
        }
        guard let app else { return }
        let pid = Int(vc.pid)
        // The game's process writes its first reading as it starts: then
        // the limit iOS set for it is known, before the game is under way.
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard let self, self.app === app, let reading = CartoucheGameMemoryReading.last(pid: pid) else { return }
            CartoucheGameActions.shared.gameMeasured(app, reading: reading)
        }
    }

    // MARK: The console and the game

    /// The console over the game, which pauses.
    func showConsole() {
        guard app != nil, isInFront, let window else { return }
        isInFront = false
        setGameForeground(false)
        CartoucheGamepad.shared.gameInFront = false
        UIView.animate(withDuration: 0.2) { window.alpha = 0 }
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(220))
            guard let self, !self.isInFront, self.window === window else { return }
            window.isHidden = true
            // The console turns as the iPhone is held, now that the game's
            // window, which turns as the game allows, has gone.
            self.consoleWindow?.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
        }
        backToConsole()
        CartoucheGameActions.shared.gameDidMove(inFront: false)
    }

    /// The game again, where the player left it.
    func showGame() {
        guard app != nil, !isInFront, let window, let screen,
              // Cartouche's own work, the start of this game or an install,
              // shows on the console until it ends.
              CartoucheGameActions.shared.work == nil else { return }
        isInFront = true
        window.isHidden = false
        window.makeKey()
        UIView.animate(withDuration: 0.2) { window.alpha = 1 }
        screen.rotate()
        setGameForeground(true)
        CartoucheGamepad.shared.gameInFront = true
        UIApplication.shared.isIdleTimerDisabled = true
        CartoucheGameActions.shared.gameDidMove(inFront: true)
    }

    /// A press of a controller's Home button, from Cartouche's controller or
    /// from the game's process: the console over the game, or the game
    /// again. Both may see the same press.
    func homePressed() {
        guard app != nil, Date().timeIntervalSince(lastHome) > 0.6 else { return }
        lastHome = Date()
        if isInFront {
            showConsole()
        } else {
            showGame()
        }
    }

    /// Stops the game's process. LiveContainer says when it has gone; if it
    /// does not, Cartouche cleans up after six seconds.
    func quit() {
        guard let scene, !quitting else { return }
        quitting = true
        if scene.isAppRunning {
            scene.terminate()
        } else {
            scene.appTerminationCleanUp()
        }
        Task { [weak self, weak scene] in
            try? await Task.sleep(for: .seconds(6))
            guard let self, let scene, self.scene === scene else { return }
            scene.appTerminationCleanUp()
        }
    }

    /// Paused behind the console, the game's scene is in the background, as
    /// an app the player left: LiveContainer's own way to set it
    /// (AppSceneViewController setBackgroundNotificationEnabled:).
    private func setGameForeground(_ foreground: Bool) {
        scene?.presenter?.scene?.updateSettings { settings in
            guard let settings else { return }
            settings.setValue(foreground, forKey: "foreground")
            if foreground {
                settings.deactivationReasons = 0
            }
        }
    }

    /// iOS may bring the game's scene back with Cartouche's when Cartouche
    /// comes back to the screen: a paused game stays in the background.
    private func keepPaused() {
        guard app != nil, !isInFront else { return }
        setGameForeground(false)
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard let self, self.app != nil, !self.isInFront else { return }
            self.setGameForeground(false)
        }
    }

    private func listenToHome(dataFolder: String) {
        CFNotificationCenterAddObserver(
            CFNotificationCenterGetDarwinNotifyCenter(),
            Unmanaged.passUnretained(self).toOpaque(),
            { _, _, _, _, _ in
                Task { @MainActor in CartoucheGameHost.shared.homePressed() }
            },
            "CartoucheGameHome.\(dataFolder)" as CFString,
            nil,
            .deliverImmediately)
        listensToHome = true
        let gamepad = CartoucheGamepad.shared
        gamepad.holdsHome = true
        gamepad.gameInFront = true
        homePresses = gamepad.homePresses.sink { [weak self] in
            self?.homePressed()
        }
        activation = NotificationCenter.default.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil,
                                                            queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.keepPaused() }
        }
    }

    private func stopListeningToHome() {
        if listensToHome {
            CFNotificationCenterRemoveEveryObserver(CFNotificationCenterGetDarwinNotifyCenter(),
                                                    Unmanaged.passUnretained(self).toOpaque())
            listensToHome = false
        }
        homePresses = nil
        if let activation {
            NotificationCenter.default.removeObserver(activation)
        }
        activation = nil
        let gamepad = CartoucheGamepad.shared
        gamepad.holdsHome = false
        gamepad.gameInFront = false
    }

    fileprivate func sceneSettingsChanged(_ vc: AppSceneViewController, settings: UIMutableApplicationSceneSettings,
                                          context: Any?) {
        guard vc === scene else { return }
        settings.interruptionPolicy = 0
        if !isInFront {
            settings.setValue(false, forKey: "foreground")
        }
        vc.presenter?.scene?.updateSettings(settings, withTransitionContext: context, completion: nil)
    }

    // MARK: The end

    fileprivate func sceneDidExit(_ vc: AppSceneViewController) {
        guard vc === scene, let app else { return }
        if starting != nil {
            failStart(CartoucheGameHostError())
            return
        }
        let reading = CartoucheGameMemoryReading.last(pid: Int(vc.pid))
        let quit = quitting
        let wasInFront = isInFront
        tearDown()
        CartoucheGameActions.shared.gameDidEnd(app, quit: quit, wasInFront: wasInFront, reading: reading)
    }

    private func tearDown() {
        if let scene {
            scene.delegate = nil
            scene.willMove(toParent: nil)
            scene.view.removeFromSuperview()
            scene.removeFromParent()
        }
        scene = nil
        window?.isHidden = true
        window?.rootViewController = nil
        window = nil
        screen = nil
        stopListeningToHome()
        app = nil
        isInFront = false
        quitting = false
        backToConsole()
    }

    /// The console's window has the screen again, upright or sideways as
    /// the iPhone is held.
    private func backToConsole() {
        consoleWindow?.makeKey()
        consoleWindow?.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
        consoleWindow?.rootViewController?.setNeedsStatusBarAppearanceUpdate()
        if CartoucheGameActions.shared.work == nil {
            UIApplication.shared.isIdleTimerDisabled = false
        }
    }

    // MARK: Where the game shows

    private static func hostScene() -> UIWindowScene? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        return scenes.first { $0.activationState == .foregroundActive && $0.keyWindow != nil }
            ?? scenes.first { $0.activationState == .foregroundActive }
            ?? scenes.first
    }

    /// The orientations the game's Info.plist allows, among those
    /// Cartouche's allows.
    private static func orientations(of app: LCAppModel) -> UIInterfaceOrientationMask {
        let info = app.appInfo.info()
        let isPad = UIDevice.current.userInterfaceIdiom == .pad
        let key = "UISupportedInterfaceOrientations"
        let names = info?[key + (isPad ? "~ipad" : "~iphone")] as? [String] ?? info?[key] as? [String] ?? []
        var mask: UIInterfaceOrientationMask = []
        for name in names {
            switch name {
            case "UIInterfaceOrientationPortrait": mask.insert(.portrait)
            case "UIInterfaceOrientationPortraitUpsideDown": mask.insert(.portraitUpsideDown)
            case "UIInterfaceOrientationLandscapeLeft": mask.insert(.landscapeLeft)
            case "UIInterfaceOrientationLandscapeRight": mask.insert(.landscapeRight)
            default: break
            }
        }
        if !isPad {
            mask.remove(.portraitUpsideDown)
        }
        if mask.isEmpty {
            return isPad ? UIInterfaceOrientationMask.all : UIInterfaceOrientationMask.allButUpsideDown
        }
        return mask
    }
}

// MARK: LiveContainer's calls

/// LiveContainer's calls about the game's scene, on to the host, on the
/// main thread: LiveContainer makes them there, but for the start of the
/// process, which may come on another.
@available(iOS 18.0, *)
private final class CartoucheGameSceneCalls: NSObject, AppSceneViewControllerDelegate {
    private func onMain(_ work: @escaping @MainActor () -> Void) {
        if Thread.isMainThread {
            MainActor.assumeIsolated(work)
        } else {
            Task { @MainActor in work() }
        }
    }

    func appSceneVC(_ vc: AppSceneViewController!, didInitializeWithError error: (any Error)!) {
        let failure: Error? = error
        onMain { CartoucheGameHost.shared.didInitialize(failure) }
    }

    func appSceneVCWillActivateScene(_ vc: AppSceneViewController!) {
        guard let vc else { return }
        onMain { CartoucheGameHost.shared.sceneWillShow(vc) }
    }

    /// Cartouche's scene changed: the game's takes its settings, as in a
    /// window of LiveContainer's own (MultitaskAppWindow.swift), but stays
    /// in the background while it is paused.
    func appSceneVC(_ vc: AppSceneViewController!, didUpdateFrom settings: UIMutableApplicationSceneSettings!,
                    transitionContext context: Any!, lifecycleActionType actionType: UInt32) {
        guard let vc, let settings else { return }
        onMain { CartoucheGameHost.shared.sceneSettingsChanged(vc, settings: settings, context: context) }
    }

    func appSceneVCAppDidExit(_ vc: AppSceneViewController!) {
        guard let vc else { return }
        onMain { CartoucheGameHost.shared.sceneDidExit(vc) }
    }
}

/// The game did not start behind the console: Play starts it in Cartouche's
/// place instead.
struct CartoucheGameHostError: Error {}

// MARK: The game's screen

/// The screen of a game running behind the console: the game's scene, full
/// screen, and the Home button that shows the console, at the bottom in the
/// middle, where nxnative's controls on screen leave room. Upright or
/// sideways as the game allows, without the status bar, with the home
/// indicator out of the way, and the edges of the screen to the game first.
@available(iOS 18.0, *)
final class CartoucheGameScreen: UIViewController {
    private let orientations: UIInterfaceOrientationMask
    private let onHome: () -> Void
    private let spinner = UIActivityIndicatorView(style: .large)
    private let homeButton = UIButton(type: .custom)

    init(orientations: UIInterfaceOrientationMask, onHome: @escaping () -> Void) {
        self.orientations = orientations
        self.onHome = onHome
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        return nil
    }

    override var supportedInterfaceOrientations: UIInterfaceOrientationMask { orientations }
    override var prefersStatusBarHidden: Bool { true }
    override var prefersHomeIndicatorAutoHidden: Bool { true }
    override var preferredScreenEdgesDeferringSystemGestures: UIRectEdge { .all }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black

        spinner.color = .white
        spinner.translatesAutoresizingMaskIntoConstraints = false
        spinner.startAnimating()
        view.addSubview(spinner)

        var configuration = UIButton.Configuration.plain()
        configuration.image = UIImage(systemName: "house.fill",
                                      withConfiguration: UIImage.SymbolConfiguration(pointSize: 13, weight: .bold))
        configuration.baseForegroundColor = .white
        configuration.background.backgroundColor = UIColor.black.withAlphaComponent(0.4)
        configuration.background.strokeColor = UIColor.white.withAlphaComponent(0.3)
        configuration.background.strokeWidth = 1
        configuration.cornerStyle = .capsule
        configuration.contentInsets = NSDirectionalEdgeInsets(top: 6, leading: 18, bottom: 6, trailing: 18)
        homeButton.configuration = configuration
        homeButton.alpha = 0.75
        homeButton.accessibilityLabel = CartoucheText.backToCartouche
        homeButton.translatesAutoresizingMaskIntoConstraints = false
        homeButton.addAction(UIAction { [weak self] _ in self?.onHome() }, for: .primaryActionTriggered)
        view.addSubview(homeButton)

        NSLayoutConstraint.activate([
            spinner.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            homeButton.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            homeButton.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -2),
            homeButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 30),
        ])
    }

    /// The game's scene, under the Home button.
    func embed(_ child: UIViewController) {
        addChild(child)
        child.view.frame = view.bounds
        child.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.insertSubview(child.view, at: 0)
        child.didMove(toParent: self)
    }

    func gameShows() {
        spinner.stopAnimating()
        spinner.isHidden = true
    }

    /// Turns the screen as the game allows, and hides the status bar.
    func rotate() {
        setNeedsUpdateOfSupportedInterfaceOrientations()
        setNeedsStatusBarAppearanceUpdate()
        setNeedsUpdateOfHomeIndicatorAutoHidden()
        setNeedsUpdateOfScreenEdgesDeferringSystemGestures()
        view.window?.windowScene?.requestGeometryUpdate(.iOS(interfaceOrientations: orientations)) { _ in }
    }

    /// A line over the Home button for a few seconds.
    func showHint(_ text: String) {
        let hint = UIView()
        hint.backgroundColor = UIColor.black.withAlphaComponent(0.65)
        hint.layer.cornerRadius = 14
        hint.layer.cornerCurve = .continuous
        hint.isUserInteractionEnabled = false
        hint.translatesAutoresizingMaskIntoConstraints = false
        let label = UILabel()
        label.text = text
        label.font = .preferredFont(forTextStyle: .subheadline)
        label.textColor = .white
        label.numberOfLines = 2
        label.textAlignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        hint.addSubview(label)
        view.addSubview(hint)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: hint.leadingAnchor, constant: 14),
            label.trailingAnchor.constraint(equalTo: hint.trailingAnchor, constant: -14),
            label.topAnchor.constraint(equalTo: hint.topAnchor, constant: 8),
            label.bottomAnchor.constraint(equalTo: hint.bottomAnchor, constant: -8),
            hint.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            hint.bottomAnchor.constraint(equalTo: homeButton.topAnchor, constant: -10),
            hint.widthAnchor.constraint(lessThanOrEqualTo: view.widthAnchor, constant: -40),
        ])
        Task { [weak hint] in
            try? await Task.sleep(for: .seconds(4))
            UIView.animate(withDuration: 0.4) { hint?.alpha = 0 }
            try? await Task.sleep(for: .milliseconds(450))
            hint?.removeFromSuperview()
        }
    }
}
