// Research only (the TV mode's thread): registers a TV scene accessory as
// Cartouche does (CartoucheGameHost.askForTheTV) or as nxnative does
// (front_ios.m DmRootVC), in the iOS Simulator with an external display,
// and logs what iOS does: the scenes it connects, the screens UIKit lists,
// the capture state, the audio route. The phone's screen is blue, the TV
// scene red, so that a screenshot of the external display says which one it
// shows. Never part of Cartouche; removed before the pull request.

import AVFAudio
import UIKit

let started = Date()
let variant = ProcessInfo.processInfo.arguments.dropFirst().first(where: { !$0.hasPrefix("-") }) ?? "baseline"

func log(_ line: String) {
    let text = String(format: "PROBE %5.1f ", Date().timeIntervalSince(started)) + line + "\n"
    FileHandle.standardOutput.write(text.data(using: .utf8)!)
}

@MainActor
enum Probe {
    // UISceneAccessoryRegistration, iOS 27 only.
    static var registrations: [(name: String, controller: UIViewController, registration: AnyObject)] = []
    static var tvConnections = 0
    static weak var root: UIViewController?
    static var last = ""

    static func state() -> String {
        let screens = UIScreen.screens.map { screen -> String in
            var line = String(format: "%.0fx%.0f@%.0f", screen.bounds.width, screen.bounds.height, screen.scale)
            if screen === UIScreen.main { line += " main" }
            if screen.mirrored != nil { line += " mirrored" }
            if screen.isCaptured { line += " captured" }
            return line
        }
        let scenes = UIApplication.shared.connectedScenes.map { scene -> String in
            let state = ["unattached", "foregroundActive", "foregroundInactive", "background"][max(0, min(3, scene.activationState.rawValue + 1))]
            var line = "\(scene.session.role.rawValue.replacingOccurrences(of: "UIWindowSceneSessionRole", with: ""))/\(state)"
            if let scene = scene as? UIWindowScene {
                line += String(format: " %.0fx%.0f", scene.screen.bounds.width, scene.screen.bounds.height)
                line += " capture=\(scene.traitCollection.sceneCaptureState.rawValue)"
                line += " delegate=\(scene.delegate.map { String(describing: type(of: $0)) } ?? "nil")"
                line += " config=\(scene.session.configuration.name ?? "nil")/\(scene.session.configuration.delegateClass.map { String(describing: $0) } ?? "nil")"
            }
            return line
        }
        let accessories = registrations.map { entry -> String in
            guard #available(iOS 27.0, *), let registration = entry.registration as? UISceneAccessoryRegistration else { return entry.name }
            return "\(entry.name): enabled=\(registration.isEnabled) available=\(registration.isAvailable)"
        }
        let route = AVAudioSession.sharedInstance().currentRoute.outputs.map { "\($0.portType.rawValue)" }
        let main = "main.mirrored=\(UIScreen.main.mirrored != nil) main.captured=\(UIScreen.main.isCaptured)"
        return "screens=\(screens) \(main) scenes=\(scenes) accessories=\(accessories) route=\(route) tvConnections=\(tvConnections)"
    }

    static func watch(until end: TimeInterval) async {
        while Date().timeIntervalSince(started) < end {
            let now = state()
            if now != last {
                log("state " + now)
                last = now
            }
            try? await Task.sleep(for: .milliseconds(250))
        }
    }

    static func register(_ name: String, on controller: UIViewController, configurationName: String?, enable: Bool?) {
        guard #available(iOS 27.0, *) else { log("no iOS 27"); return }
        let configuration = UISceneConfiguration(name: configurationName, sessionRole: .windowExternalDisplayNonInteractive)
        configuration.delegateClass = TVSceneDelegate.self
        let registration = controller.registerSceneAccessory(.externalNonInteractive(sceneConfiguration: configuration))
        log("registered \(name) on \(type(of: controller)): enabled by default=\(registration.isEnabled) available=\(registration.isAvailable)")
        if let enable {
            registration.isEnabled = enable
            log("\(name).isEnabled = \(enable)")
        }
        registrations.append((name, controller, registration as AnyObject))
    }

    static func setEnabled(_ enabled: Bool) {
        guard #available(iOS 27.0, *) else { return }
        for entry in registrations {
            (entry.registration as? UISceneAccessoryRegistration)?.isEnabled = enabled
        }
    }

    static func unregisterAll() {
        guard #available(iOS 27.0, *) else { return }
        for (name, controller, registration) in registrations {
            if let registration = registration as? UISceneAccessoryRegistration {
                controller.unregisterSceneAccessory(registration)
                log("unregistered \(name)")
            }
        }
        registrations = []
    }

    static func run(in root: RootViewController) async {
        log("variant \(variant), iOS \(UIDevice.current.systemVersion), \(UIDevice.current.model)")
        log("state " + state())
        // What a capture of the screen says, as it comes and goes: to the
        // window scene and to the view controller on screen.
        let windowScene = root.view.window!.windowScene!
        windowScene.registerForTraitChanges([UITraitSceneCaptureState.self]) { (scene: UIWindowScene, previous: UITraitCollection) in
            log("scene capture changed: \(previous.sceneCaptureState.rawValue) -> \(scene.traitCollection.sceneCaptureState.rawValue)")
        }
        root.registerForTraitChanges([UITraitSceneCaptureState.self]) { (controller: RootViewController, previous: UITraitCollection) in
            log("root capture changed: \(previous.sceneCaptureState.rawValue) -> \(controller.traitCollection.sceneCaptureState.rawValue)")
        }
        switch variant {
        case "baseline":
            if registrations.isEmpty {
                register("root", on: root, configurationName: nil, enable: nil)
            }
            await watch(until: 3)
            // Can a test say that the screen is captured, as iOS would?
            let child = UIViewController()
            root.addChild(child)
            root.view.addSubview(child.view)
            child.didMove(toParent: root)
            log("child capture before override=\(child.traitCollection.sceneCaptureState.rawValue)")
            child.traitOverrides.sceneCaptureState = .active
            child.view.setNeedsLayout()
            child.view.layoutIfNeeded()
            log("child capture after override=\(child.traitCollection.sceneCaptureState.rawValue) window scene=\(root.view.window?.windowScene?.traitCollection.sceneCaptureState.rawValue ?? -9)")
            var changes = 0
            child.registerForTraitChanges([UITraitSceneCaptureState.self]) { (_: UIViewController, _: UITraitCollection) in changes += 1 }
            child.traitOverrides.sceneCaptureState = .inactive
            child.view.setNeedsLayout()
            child.view.layoutIfNeeded()
            try? await Task.sleep(for: .milliseconds(300))
            log("child capture after second override=\(child.traitCollection.sceneCaptureState.rawValue) changes seen=\(changes)")
            // And on the window scene, as a harness test would say that iOS
            // captures it.
            windowScene.traitOverrides.sceneCaptureState = .active
            try? await Task.sleep(for: .milliseconds(400))
            log("scene override: scene=\(windowScene.traitCollection.sceneCaptureState.rawValue) root=\(root.traitCollection.sceneCaptureState.rawValue) child=\(child.traitCollection.sceneCaptureState.rawValue)")
            windowScene.traitOverrides.remove(UITraitSceneCaptureState.self)
            try? await Task.sleep(for: .milliseconds(400))
            log("scene override removed: scene=\(windowScene.traitCollection.sceneCaptureState.rawValue) root=\(root.traitCollection.sceneCaptureState.rawValue)")
            // A hidden window's view controller, as the paused game's.
            let hidden = UIWindow(windowScene: windowScene)
            let hiddenRoot = UIViewController()
            hidden.rootViewController = hiddenRoot
            hidden.isHidden = false
            hidden.isHidden = true
            windowScene.traitOverrides.sceneCaptureState = .active
            try? await Task.sleep(for: .milliseconds(400))
            log("hidden window under scene override: hidden root=\(hiddenRoot.traitCollection.sceneCaptureState.rawValue)")
            windowScene.traitOverrides.remove(UITraitSceneCaptureState.self)
            await watch(until: 6)
        case "cartouche":
            await watch(until: 2)
            // Cartouche: from the console's view controller and from the game's
            // screen, a window over it, each enabled.
            register("console", on: root, configurationName: nil, enable: true)
            let window = UIWindow(windowScene: root.view.window!.windowScene!)
            window.windowLevel = UIWindow.Level(rawValue: UIWindow.Level.normal.rawValue + 1)
            let game = ColorViewController(color: .systemGreen, label: "GAME")
            window.rootViewController = game
            window.makeKeyAndVisible()
            root.overlay = window
            register("game", on: game, configurationName: nil, enable: true)
            await watch(until: 10)
            log("step: the game's window hides (the console over the game)")
            window.isHidden = true
            await watch(until: 15)
            log("step: the game's window shows again")
            window.isHidden = false
            window.makeKey()
            await watch(until: 20)
            log("step: both accessories disabled")
            setEnabled(false)
            await watch(until: 25)
            log("step: both enabled again")
            setEnabled(true)
            await watch(until: 30)
            log("step: both unregistered (the game ends)")
            unregisterAll()
            await watch(until: 35)
        case "none":
            // No accessory at all: iOS mirrors the iPhone, if it does.
            await watch(until: 10)
        case "nxnative":
            // Registered in viewDidLoad, by name, never enabled (front_ios.m).
            await watch(until: 12)
        case "late":
            // The display comes after the registration (the workflow plugs it
            // in a few seconds after the launch).
            register("console", on: root, configurationName: nil, enable: true)
            await watch(until: 25)
        default:
            log("unknown variant")
        }
        log("state " + state())
        log("done")
        exit(0)
    }
}

final class ColorViewController: UIViewController {
    let color: UIColor
    let label: String
    init(color: UIColor, label: String) {
        self.color = color
        self.label = label
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { nil }
    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = color
        let text = UILabel()
        text.text = label
        text.font = .systemFont(ofSize: 80, weight: .black)
        text.textColor = .white
        text.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(text)
        NSLayoutConstraint.activate([text.centerXAnchor.constraint(equalTo: view.centerXAnchor),
                                     text.centerYAnchor.constraint(equalTo: view.centerYAnchor)])
    }
}

final class RootViewController: UIViewController {
    var overlay: UIWindow?
    private var ran = false
    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBlue
        if variant == "nxnative" {
            Probe.register("nxnative", on: self, configurationName: "TV", enable: nil)
        }
    }
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        log("root viewDidAppear")
        guard !ran else { return }
        ran = true
        Probe.root = self
        Task { await Probe.run(in: self) }
    }
}

final class SceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?
    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options: UIScene.ConnectionOptions) {
        log("main scene connects, role \(session.role.rawValue)")
        guard let scene = scene as? UIWindowScene else { return }
        let window = UIWindow(windowScene: scene)
        window.rootViewController = RootViewController()
        window.makeKeyAndVisible()
        self.window = window
    }
}

final class TVSceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?
    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options: UIScene.ConnectionOptions) {
        guard let scene = scene as? UIWindowScene else { return }
        MainActor.assumeIsolated {
            Probe.tvConnections += 1
            log(String(format: "TV scene connects: role %@, screen %.0fx%.0f", session.role.rawValue,
                       scene.screen.bounds.width, scene.screen.bounds.height))
        }
        let window = UIWindow(windowScene: scene)
        window.rootViewController = ColorViewController(color: .systemRed, label: "TV")
        window.isHidden = false
        self.window = window
    }
    func sceneDidDisconnect(_ scene: UIScene) {
        log("TV scene disconnects")
    }
}

@main
final class AppDelegate: UIResponder, UIApplicationDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        log("launched")
        return true
    }
    func application(_ application: UIApplication, configurationForConnecting session: UISceneSession,
                     options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        log("configurationForConnecting role \(session.role.rawValue), configuration \(session.configuration.name ?? "nil")/\(session.configuration.delegateClass.map { String(describing: $0) } ?? "nil")")
        let configuration = UISceneConfiguration(name: nil, sessionRole: session.role)
        if #available(iOS 27.0, *), session.role == .windowExternalDisplayNonInteractive {
            configuration.delegateClass = TVSceneDelegate.self
        } else {
            configuration.delegateClass = SceneDelegate.self
        }
        return configuration
    }
}
