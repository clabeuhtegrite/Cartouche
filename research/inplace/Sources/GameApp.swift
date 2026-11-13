//
//  GameApp.swift
//  InPlaceGame (research)
//
//  A game as nxnative builds it, for what its screen does on an iPhone:
//  scenes, one window, a view controller that allows every way (front_ios.m
//  DmRootVC), no app delegate call for the orientations, so that the
//  Info.plist's say which ways the app allows. Its view draws where
//  nxnative puts the picture and the controls (NxnativeStandIn.swift).
//  Three seconds after its window shows, it writes which way its screen is
//  turned and its size to Documents/status.json, for run.sh.
//

import UIKit

@main
final class GameAppDelegate: UIResponder, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        true
    }
}

final class GameSceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options: UIScene.ConnectionOptions) {
        guard let scene = scene as? UIWindowScene else { return }
        let window = UIWindow(windowScene: scene)
        window.rootViewController = GameViewController()
        window.makeKeyAndVisible()
        self.window = window
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            GameStatus.write(window)
        }
    }
}

final class GameViewController: UIViewController {
    override func loadView() {
        view = NxnativeStandIn(frame: UIScreen.main.bounds)
    }

    override var supportedInterfaceOrientations: UIInterfaceOrientationMask { .all }
    override var prefersStatusBarHidden: Bool { true }
    override var prefersHomeIndicatorAutoHidden: Bool { true }
}

enum GameStatus {
    static func write(_ window: UIWindow) {
        let orientation: String
        switch window.windowScene?.effectiveGeometry.interfaceOrientation ?? .unknown {
        case .portrait: orientation = "portrait"
        case .portraitUpsideDown: orientation = "portraitUpsideDown"
        case .landscapeLeft: orientation = "landscapeLeft"
        case .landscapeRight: orientation = "landscapeRight"
        default: orientation = "unknown"
        }
        let size = window.bounds.size
        let root = window.rootViewController
        let status: [String: Any] = [
            "orientation": orientation,
            "width": size.width,
            "height": size.height,
            "viewControllerWays": root?.supportedInterfaceOrientations.rawValue ?? 0,
            // The view controller's ways met with the app's, as UIKit turns the screen to them.
            "metWays": root?.responds(to: NSSelectorFromString("__supportedInterfaceOrientations")) == true
                ? (root?.value(forKey: "__supportedInterfaceOrientations") as? UInt) ?? 0 : 0,
            "applicationWays": UIApplication.shared.supportedInterfaceOrientations(for: window).rawValue,
            "control": UserDefaults.standard.bool(forKey: "CartoucheControl"),
        ]
        NSLog("[InPlaceGame] status %@", status as NSDictionary)
        guard let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first,
              let data = try? JSONSerialization.data(withJSONObject: status, options: [.prettyPrinted, .sortedKeys]) else { return }
        try? FileManager.default.createDirectory(at: documents, withIntermediateDirectories: true)
        try? data.write(to: documents.appendingPathComponent("status.json"))
    }
}
