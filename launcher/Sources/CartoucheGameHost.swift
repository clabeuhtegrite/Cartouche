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

import AVFAudio
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
    /// Cartouche's scene accessories, which ask iOS for the TV while the
    /// game runs (CartoucheTV.swift), with the view controllers they are
    /// on.
    private(set) var tvAccessories: [(controller: UIViewController, registration: AnyObject)] = []
    /// The game's own scene on the TV, which LiveContainer opened in the
    /// game's process.
    private(set) var gameOnTV: UIViewController?
    private var screenWatch: [NSObjectProtocol] = []
    /// The scene's capture state, watched while the game runs
    /// (watchScreens).
    private var captureWatch: (scene: UIWindowScene, registration: any UITraitChangeRegistration)?

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

        let isPad = UIDevice.current.userInterfaceIdiom == .pad
        let screen = CartoucheGameScreen(allowed: Self.orientations(of: app, isPad: isPad),
                                         laysOutUpright: Self.laysOutUpright(app), isPad: isPad) { [weak self] in
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
        // A TV shows the game alone from now on, never the iPhone's screen.
        CartoucheTV.shared.card.show(app)
        CartoucheTV.shared.host = self
        askForTheTV(from: [consoleWindow?.rootViewController, screen])
        watchScreens(in: host)
        guardTheTV()
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
        CartoucheTV.shared.card.status = isInFront ? .playing : .paused
        openGameOnTV()
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
        // The console turns as the iPad is held: the game's screen lets go
        // of the way it was turned.
        screen?.isInFront = false
        setGameForeground(false)
        showOnTV(inFront: false)
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
        // Before the game shows again: hidden from a TV that mirrors the
        // iPhone, until iOS hands Cartouche that TV again.
        guardTheTV()
        window.isHidden = false
        window.makeKey()
        UIView.animate(withDuration: 0.2) { window.alpha = 1 }
        screen.isInFront = true
        screen.rotate()
        setGameForeground(true)
        showOnTV(inFront: true)
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
        let cartoucheInForeground = (settings.value(forKey: "foreground") as? Bool) ?? true
        settings.interruptionPolicy = 0
        if !isInFront {
            settings.setValue(false, forKey: "foreground")
        }
        vc.presenter?.scene?.updateSettings(settings, withTransitionContext: context, completion: nil)
        // The game's scene on the TV follows Cartouche into the background
        // and back, as its own scene does.
        if gameOnTV != nil {
            vc.setExternalDisplaySceneForeground(isInFront && cartoucheInForeground)
        }
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
        // The TV goes back to iOS, which mirrors the console on it again.
        closeGameOnTV()
        stopAskingForTheTV()
        if CartoucheTV.shared.host === self {
            CartoucheTV.shared.host = nil
            CartoucheTV.shared.card.clear()
        }
        for observer in screenWatch {
            NotificationCenter.default.removeObserver(observer)
        }
        screenWatch = []
        if let captureWatch {
            captureWatch.scene.unregisterForTraitChanges(captureWatch.registration)
        }
        captureWatch = nil
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
        // The iPhone may lock again, unless an install or a copy keeps it
        // awake: a start that did not go through here, which goes on in
        // Cartouche's place or stops, leaves it as before.
        if !CartoucheGameActions.shared.isTransferring {
            UIApplication.shared.isIdleTimerDisabled = false
        }
    }

    // MARK: The TV (CartoucheTV.swift)

    /// Asks iOS for the TV, from CONTROLLERS, while the game runs: iOS 27
    /// mirrors the iPhone on a TV unless the app on screen registers a scene
    /// accessory for it. The console's view controller stays on screen
    /// under the game, paused or not, and the game's screen is on top while
    /// the game is: whichever iOS finds the more relevant, it hands
    /// Cartouche the TV, never a copy of the game with its controls.
    private func askForTheTV(from controllers: [UIViewController?]) {
        guard #available(iOS 27.0, *) else { return }
        let configuration = UISceneConfiguration(name: nil, sessionRole: .windowExternalDisplayNonInteractive)
        configuration.delegateClass = CartoucheTVSceneDelegate.self
        for case let controller? in controllers {
            let registration = controller.registerSceneAccessory(.externalNonInteractive(sceneConfiguration: configuration))
            registration.isEnabled = true
            tvAccessories.append((controller: controller, registration: registration as AnyObject))
        }
    }

    private func stopAskingForTheTV() {
        if #available(iOS 27.0, *) {
            for (controller, registration) in tvAccessories {
                if let registration = registration as? UISceneAccessoryRegistration {
                    controller.unregisterSceneAccessory(registration)
                }
            }
        }
        tvAccessories = []
    }

    /// The game's own scene on the TV, once its process runs and iOS has
    /// handed Cartouche the TV: the game fills it, nxnative with its
    /// picture, docked. Without it the TV shows the game's card.
    private func openGameOnTV() {
        let tv = CartoucheTV.shared
        guard gameOnTV == nil, let tvScreen = tv.screen, let display = tv.window?.windowScene?.screen,
              let scene, scene.isAppRunning else { return }
        guard let made = scene.openExternalDisplayScene(on: display) else {
            CartoucheTV.note("TV: the game has no scene of its own on the TV, which shows its card")
            return
        }
        gameOnTV = made
        tvScreen.showGame(made)
        tvScreen.showsGame = isInFront
        scene.setExternalDisplaySceneForeground(isInFront)
        pictureMoved(toTV: true)
        CartoucheTV.note(String(format: "TV: the game's own scene is on the TV (%.0fx%.0f points)",
                                display.bounds.width, display.bounds.height))
    }

    private func closeGameOnTV() {
        guard let gameOnTV else { return }
        self.gameOnTV = nil
        if let tvScreen = CartoucheTV.shared.screen, tvScreen.game === gameOnTV {
            tvScreen.removeGame()
        }
        scene?.closeExternalDisplayScene()
        pictureMoved(toTV: false)
    }

    /// nxnative moves the game's picture to the game's own scene on the TV,
    /// and leaves the iPhone its controls alone, laid out to be held
    /// sideways: the game's screen turns sideways only meanwhile, and as
    /// the iPhone is held again once the picture is back on it
    /// (CartoucheGameOrientations.behindTheConsole). Paused, the game's
    /// screen turns as it shows again (showGame).
    private func pictureMoved(toTV onTV: Bool) {
        guard let screen, screen.pictureOnTV != onTV else { return }
        screen.pictureOnTV = onTV
        if isInFront {
            screen.rotate()
        }
    }

    /// What the TV shows as the game comes and goes: the game's own scene
    /// while the game is on screen, its card, paused, while the console is
    /// over it. The game's scene on the TV follows its own into the
    /// background, where nxnative pauses.
    private func showOnTV(inFront: Bool) {
        let tv = CartoucheTV.shared
        if tv.card.status != .starting {
            tv.card.status = inFront ? .playing : .paused
        }
        tv.screen?.showsGame = inFront
        if gameOnTV != nil {
            scene?.setExternalDisplaySceneForeground(inFront)
        }
        guardTheTV()
    }

    /// Never the game with its controls on a TV, even for a moment: while
    /// the game is on screen and a copy of the iPhone's screen goes
    /// elsewhere, as it goes to a TV before iOS hands Cartouche that TV, or
    /// if it never does, the game's screen hides the game, unless the
    /// player shows it anyway.
    func guardTheTV() {
        guard let screen else { return }
        let copy = isInFront && CartoucheTV.shared.window == nil ? copyOfTheIPhone() : nil
        let hid = screen.hidesGameForTV
        screen.hidesGameFrom = copy
        // Noted as it changes: shown anyway, the game stays so.
        guard screen.hidesGameForTV != hid else { return }
        switch screen.hidesGameFrom {
        case .tv?: CartoucheTV.note("TV: a display mirrors the iPhone, the game hides from it")
        case .elsewhere?: CartoucheTV.note("TV: the iPhone's screen is recorded or copied, the game hides from it")
        case nil: CartoucheTV.note("TV: the game shows again")
        }
    }

    /// Where a copy of the iPhone's screen goes, if one does. iOS 27 copies
    /// it to a TV that it has not handed Cartouche, by cable or AirPlay,
    /// with no screen for that TV among UIScreen.screens, but it tells the
    /// scene that its screen is captured, as it does while the screen is
    /// recorded or shown in a Mac's iPhone Mirroring. Before iOS 27, that
    /// TV is a screen that mirrors the iPhone's. The sound tells a TV from
    /// the rest, as far as it can: it goes to the TV, unless headphones
    /// have it.
    private func copyOfTheIPhone() -> CartoucheScreenCopy? {
        let captured = window?.windowScene?.traitCollection.sceneCaptureState == .active
        let mirrored = UIScreen.screens.contains { $0.mirrored != nil }
        guard captured || mirrored else { return nil }
        return mirrored || Self.soundGoesToADisplay() ? .tv : .elsewhere
    }

    /// Whether the iPhone's sound goes to a display, by cable or AirPlay.
    static func soundGoesToADisplay() -> Bool {
        #if CARTOUCHE_HARNESS
        // In the launcher's harness (launcher/Harness), as a test sets it:
        // the Simulator's sound goes to the Mac.
        if let sound = HarnessLC.soundGoesToADisplay {
            return sound
        }
        #endif
        let displays: [AVAudioSession.Port] = [.HDMI, .airPlay, .displayPort]
        return AVAudioSession.sharedInstance().currentRoute.outputs.contains { displays.contains($0.portType) }
    }

    /// A copy of the iPhone's screen may start or stop as iOS captures the
    /// screen of SCENE, where the game's window is, or stops; as a display
    /// comes or goes, before iOS 27; and as the sound moves to a TV or back.
    private func watchScreens(in scene: UIWindowScene) {
        let center = NotificationCenter.default
        for name in [UIScreen.didConnectNotification, UIScreen.didDisconnectNotification, UIScreen.modeDidChangeNotification,
                     AVAudioSession.routeChangeNotification] {
            screenWatch.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.guardTheTV() }
            })
        }
        let registration = scene.registerForTraitChanges([UITraitSceneCaptureState.self]) { [weak self] (_: UIWindowScene, _: UITraitCollection) in
            MainActor.assumeIsolated { self?.guardTheTV() }
        }
        captureWatch = (scene, registration)
    }

    // MARK: Where the game shows

    private static func hostScene() -> UIWindowScene? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        return scenes.first { $0.activationState == .foregroundActive && $0.keyWindow != nil }
            ?? scenes.first { $0.activationState == .foregroundActive }
            ?? scenes.first
    }

    /// The orientations the Info.plist in the game's bundle allows, among
    /// those Cartouche's allows (CartoucheGameOrientations): sideways only
    /// for nxnative's games on an iPhone. Not LiveContainer's info(), its
    /// own settings for the game, which name none.
    private static func orientations(of app: LCAppModel, isPad: Bool) -> CartoucheGameOrientations {
        let bundle = app.appInfo.bundlePath().map { URL(fileURLWithPath: $0, isDirectory: true) }
        return bundle.map { CartoucheGameOrientations(bundle: $0, isPad: isPad) } ?? .ofCartouche(isPad: isPad)
    }

    /// Whether the game lays itself out upright, as the Info.plist in its
    /// bundle says by the ways it allows on an iPad: nxnative's games since
    /// 4 November 2026 (CartoucheGameOrientations.laysOutUpright).
    private static func laysOutUpright(_ app: LCAppModel) -> Bool {
        guard let path = app.appInfo.bundlePath() else { return false }
        return CartoucheGameOrientations.laysOutUpright(bundle: URL(fileURLWithPath: path, isDirectory: true))
    }
}

// MARK: The TV's comings and goings

@available(iOS 18.0, *)
extension CartoucheGameHost: CartoucheTVHost {
    /// iOS handed Cartouche the TV: the game's own scene goes there, once
    /// its process runs.
    func tvDidConnect(_ tv: CartoucheTV) {
        openGameOnTV()
        guardTheTV()
    }

    /// iOS takes the TV back, unplugged or no longer asked for: the game's
    /// scene there closes, and nxnative puts its picture back on the
    /// iPhone.
    func tvWillDisconnect(_ tv: CartoucheTV) {
        closeGameOnTV()
        Task { @MainActor [weak self] in self?.guardTheTV() }
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

/// Where a copy of the iPhone's screen goes, which the game hides from
/// (CartoucheGameHost.guardTheTV).
enum CartoucheScreenCopy: Equatable {
    /// A TV, by cable or AirPlay, that iOS has not handed Cartouche.
    case tv
    /// A recording of the screen, a Mac's iPhone Mirroring, or a TV whose
    /// sound goes to headphones: Cartouche cannot tell them apart.
    case elsewhere
}

// MARK: The game's screen

/// The screen of a game running behind the console: the game's scene, full
/// screen, and the Home button that shows the console, at the bottom in the
/// middle, where nxnative's controls on screen leave room, sideways or
/// upright. Upright or sideways as the game allows, and on an iPhone upright
/// too for a game that lays itself out upright, while its picture is on the
/// iPhone (CartoucheGameOrientations.behindTheConsole); without the status
/// bar, with the home indicator out of the way, and the edges of the screen
/// to the game first.
/// An iPad turns it as it is held, whatever the game allows: there it keeps
/// the way it is turned once the game allows it, and asks the player to
/// turn an iPad held upright sideways (CartoucheGameOrientations).
@available(iOS 18.0, *)
final class CartoucheGameScreen: UIViewController {
    /// The ways the game allows the screen to turn, by its Info.plist.
    private let allowed: CartoucheGameOrientations
    /// The game lays itself out upright, its picture above its controls.
    private let laysOutUpright: Bool
    private let isPad: Bool
    /// The game's picture is on a TV, and the game's controls alone on the
    /// iPhone (CartoucheGameHost.pictureMoved).
    var pictureOnTV = false
    private let onHome: () -> Void
    private let spinner = UIActivityIndicatorView(style: .large)
    private let homeButton = UIButton(type: .custom)
    /// Over the game while a copy of the iPhone's screen goes elsewhere
    /// (hidesGameFrom), with what it says and the way to show the game
    /// anyway.
    private var tvCover: UIView?
    private weak var tvCoverText: UILabel?
    private weak var tvCoverAnyway: UIButton?
    /// The cover has been up long enough for iOS to hand Cartouche a TV.
    private var tvCoverWaited = false
    private var tvCopy: CartoucheScreenCopy?
    /// The player chose to show the game on the iPhone anyway, which a TV
    /// that mirrors it shows too.
    private var showsGameDespiteTV = false
    /// Whether the screen asks iPadOS to keep the way it is turned
    /// (prefersInterfaceOrientationLocked): on an iPad, while the game is
    /// on screen, turned a way it allows (keeps(_:held:isPad:)).
    private(set) var keepsTurn = false
    /// The game on screen, rather than paused under the console, which
    /// turns as the iPad is held.
    var isInFront = true {
        didSet {
            if isInFront != oldValue { followTurns() }
        }
    }
    /// The iPad's turns, followed while the screen shows.
    private var deviceTurns: NSObjectProtocol?
    /// The player was asked to turn the iPad sideways, and has not yet.
    private var askedToTurn = false

    init(allowed: CartoucheGameOrientations, laysOutUpright: Bool, isPad: Bool, onHome: @escaping () -> Void) {
        self.allowed = allowed
        self.laysOutUpright = laysOutUpright
        self.isPad = isPad
        self.onHome = onHome
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        return nil
    }

    /// The ways the screen turns now.
    var turns: CartoucheGameOrientations {
        allowed.behindTheConsole(isPad: isPad, laysOutUpright: laysOutUpright, pictureOnTV: pictureOnTV)
    }

    override var supportedInterfaceOrientations: UIInterfaceOrientationMask { Self.mask(of: turns) }
    @available(iOS 26.0, *)
    override var prefersInterfaceOrientationLocked: Bool { keepsTurn }
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

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard isPad, deviceTurns == nil else { return }
        UIDevice.current.beginGeneratingDeviceOrientationNotifications()
        deviceTurns = NotificationCenter.default.addObserver(forName: UIDevice.orientationDidChangeNotification, object: nil,
                                                             queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.followTurns() }
        }
        followTurns()
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        guard let deviceTurns else { return }
        NotificationCenter.default.removeObserver(deviceTurns)
        self.deviceTurns = nil
        UIDevice.current.endGeneratingDeviceOrientationNotifications()
    }

    override func viewWillTransition(to size: CGSize, with coordinator: UIViewControllerTransitionCoordinator) {
        super.viewWillTransition(to: size, with: coordinator)
        coordinator.animate(alongsideTransition: nil) { [weak self] _ in
            self?.followTurns()
        }
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

    /// Where a copy of the iPhone's screen goes that the game hides from
    /// (CartoucheGameHost.guardTheTV), or nil while the game shows: black
    /// over the game, under the Home button. For a TV, while iOS hands
    /// Cartouche the TV, then after a few seconds what the player can do,
    /// and a way to show the game anyway; for the rest, both at once.
    var hidesGameFrom: CartoucheScreenCopy? {
        get { tvCopy }
        set {
            let copy = showsGameDespiteTV ? nil : newValue
            guard copy != tvCopy else { return }
            tvCopy = copy
            guard copy != nil else {
                tvCover?.removeFromSuperview()
                tvCover = nil
                return
            }
            if tvCover == nil {
                coverTheGame()
            }
            explainTheCover()
        }
    }

    /// Whether the game hides from a copy of the iPhone's screen.
    var hidesGameForTV: Bool { tvCopy != nil }

    /// How long the cover waits for iOS to hand Cartouche a TV before it
    /// says why the game hides.
    static let tvWait: Duration = .seconds(4)

    private func coverTheGame() {
        loadViewIfNeeded()
        let cover = UIView(frame: view.bounds)
        cover.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        cover.backgroundColor = .black
        cover.accessibilityIdentifier = "game.tvCover"
        let label = UILabel()
        label.font = .preferredFont(forTextStyle: .headline)
        label.textColor = .white
        label.numberOfLines = 0
        label.textAlignment = .center
        label.accessibilityIdentifier = "game.tvCover.text"
        label.translatesAutoresizingMaskIntoConstraints = false
        var configuration = UIButton.Configuration.bordered()
        configuration.title = CartoucheText.tvShowAnyway
        configuration.baseForegroundColor = .white
        configuration.cornerStyle = .capsule
        let anyway = UIButton(configuration: configuration)
        anyway.isHidden = true
        anyway.accessibilityIdentifier = "game.tvCover.anyway"
        anyway.addAction(UIAction { [weak self] _ in
            CartoucheTV.note("TV: the player shows the game anyway, on the iPhone and on the display that mirrors it")
            self?.showsGameDespiteTV = true
            self?.hidesGameFrom = nil
        }, for: .primaryActionTriggered)
        let stack = UIStackView(arrangedSubviews: [label, anyway])
        stack.axis = .vertical
        stack.alignment = .center
        stack.spacing = 16
        stack.translatesAutoresizingMaskIntoConstraints = false
        cover.addSubview(stack)
        view.insertSubview(cover, belowSubview: homeButton)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: cover.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: cover.centerYAnchor),
            stack.widthAnchor.constraint(lessThanOrEqualTo: cover.widthAnchor, constant: -64),
        ])
        tvCover = cover
        tvCoverText = label
        tvCoverAnyway = anyway
        tvCoverWaited = false
        Task { [weak self, weak cover] in
            try? await Task.sleep(for: CartoucheGameScreen.tvWait)
            guard let self, let cover, self.tvCover === cover else { return }
            self.tvCoverWaited = true
            self.explainTheCover()
        }
    }

    /// What the cover says, as the copy goes on: once shown, the way to
    /// show the game anyway stays.
    private func explainTheCover() {
        guard let copy = tvCopy else { return }
        switch copy {
        case .tv where !tvCoverWaited:
            tvCoverText?.text = CartoucheText.tvMoving
        case .tv:
            tvCoverText?.text = CartoucheText.tvMirrored
            tvCoverAnyway?.isHidden = false
        case .elsewhere:
            tvCoverText?.text = CartoucheText.tvCaptured
            tvCoverAnyway?.isHidden = false
        }
    }

    /// Turns the screen as it may turn now (turns), and hides the status
    /// bar.
    func rotate() {
        setNeedsUpdateOfSupportedInterfaceOrientations()
        setNeedsStatusBarAppearanceUpdate()
        setNeedsUpdateOfHomeIndicatorAutoHidden()
        setNeedsUpdateOfScreenEdgesDeferringSystemGestures()
        view.window?.windowScene?.requestGeometryUpdate(.iOS(interfaceOrientations: Self.mask(of: turns))) { _ in }
        followTurns()
    }

    /// On an iPad, as the screen or the iPad turns, or the game comes and
    /// goes: asks iPadOS to keep the way the screen is turned, or lets go,
    /// as keeps(_:held:isPad:) says; and asks the player to turn an iPad
    /// that shows a game made to be played sideways upright. iPadOS may not
    /// keep it, in a window of Stage Manager for one: the player turns the
    /// iPad, and the game with it.
    func followTurns() {
        guard isPad else { return }
        let turned = Self.turned(viewIfLoaded?.window?.windowScene)
        let keeps = isInFront && turns.keeps(turned, held: Self.held(), isPad: true)
        if keeps != keepsTurn {
            keepsTurn = keeps
            if #available(iOS 26.0, *) {
                setNeedsUpdateOfPrefersInterfaceOrientationLocked()
            }
            NSLog("[Cartouche] %@", keeps ? "the game's screen keeps the way it is turned" : "the game's screen turns with the iPad")
        }
        let asks = isInFront && turns.asksToTurnSideways(turned, isPad: true)
        if asks, !askedToTurn {
            CartoucheReports.note("The game shows upright on the iPad: the player is asked to turn it sideways")
            showHint(CartoucheText.turnIPadSideways)
        }
        askedToTurn = asks
    }

    /// The way the screen is turned now: none when iOS cannot tell.
    private static func turned(_ scene: UIWindowScene?) -> CartoucheGameOrientations {
        #if CARTOUCHE_HARNESS
        // In the launcher's harness (launcher/Harness), as a test sets it.
        if let turned = HarnessLC.screenTurned { return turned }
        #endif
        guard let scene else { return [] }
        switch scene.effectiveGeometry.interfaceOrientation {
        case .portrait: return .portrait
        case .portraitUpsideDown: return .portraitUpsideDown
        case .landscapeLeft: return .landscapeLeft
        case .landscapeRight: return .landscapeRight
        default: return []
        }
    }

    /// The way the screen would turn for the device as it is held: none
    /// while it lies flat, or when iOS cannot tell.
    private static func held() -> CartoucheGameOrientations {
        #if CARTOUCHE_HARNESS
        if let held = HarnessLC.deviceHeld { return held }
        #endif
        switch UIDevice.current.orientation {
        case .portrait: return .portrait
        case .portraitUpsideDown: return .portraitUpsideDown
        // UIKit names the two sides the other way round for the device and
        // for its screen.
        case .landscapeLeft: return .landscapeRight
        case .landscapeRight: return .landscapeLeft
        default: return []
        }
    }

    private static func mask(of orientations: CartoucheGameOrientations) -> UIInterfaceOrientationMask {
        var mask: UIInterfaceOrientationMask = []
        if orientations.contains(.portrait) { mask.insert(.portrait) }
        if orientations.contains(.portraitUpsideDown) { mask.insert(.portraitUpsideDown) }
        if orientations.contains(.landscapeLeft) { mask.insert(.landscapeLeft) }
        if orientations.contains(.landscapeRight) { mask.insert(.landscapeRight) }
        return mask
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
