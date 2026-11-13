//
//  CartoucheTV.swift
//  Cartouche
//
//  A TV, by cable or AirPlay, while a game runs behind the console
//  (docs/decisions.md, 85): the game's picture alone on the TV, as a Switch
//  on its dock, and the game's controls and the console on the iPhone. The
//  TV never shows the iPhone's screen while a game runs behind the console,
//  so never the game with its controls.
//
//  iOS 27 mirrors the iPhone's screen on a TV unless the app asks for the
//  TV as a scene of its own, with a scene accessory
//  (UIViewController.registerSceneAccessory). nxnative asks for one
//  (front_ios.m), but from the game's own process, whose scenes Cartouche
//  hosts: iOS never hears of it. So Cartouche asks, while a game runs
//  behind the console (CartoucheGameHost), and iOS hands Cartouche the TV
//  (CartoucheTVSceneDelegate). There Cartouche shows:
//
//  - the game's own TV scene: a second scene of the game's process, which
//    LiveContainer opens on the TV (AppSceneViewController,
//    app/patches/livecontainer/0012), and where nxnative moves its picture
//    and plays docked, the iPhone keeping the controls (front_ios.m
//    DmTVSceneDelegate);
//  - under it, Cartouche's card for the game, its cover and its name, which
//    shows while the game starts, while it is paused behind the console,
//    and for a game that leaves its TV scene empty.
//
//  With no game behind the console, iOS mirrors the console as before. A
//  game that starts in Cartouche's place is the app on screen: it asks iOS
//  for the TV itself.
//

import SwiftUI
import UIKit

/// The TV, while iOS hands it to Cartouche, and the card it shows.
@available(iOS 18.0, *)
@MainActor
final class CartoucheTV {
    static let shared = CartoucheTV()

    /// What the card says of the game.
    let card = CartoucheTVCardModel()
    /// The TV's window, from the TV's scene delegate.
    private(set) var window: UIWindow?
    /// Told when the TV comes and goes: the game host opens the game's TV
    /// scene there, and closes it.
    weak var host: CartoucheTVHost?

    /// What the TV shows, while Cartouche has it.
    var screen: CartoucheTVScreen? { window?.rootViewController as? CartoucheTVScreen }

    private init() {}

    /// iOS hands Cartouche the TV, in WINDOW.
    func connect(_ window: UIWindow) {
        if let old = self.window, old !== window {
            disconnect(old)
        }
        self.window = window
        Self.note(String(format: "TV connected (%.0fx%.0f points)", window.bounds.width, window.bounds.height))
        host?.tvDidConnect(self)
    }

    /// iOS takes the TV back: it was unplugged, or Cartouche no longer
    /// asks for it.
    func disconnect(_ window: UIWindow) {
        guard self.window === window else { return }
        host?.tvWillDisconnect(self)
        self.window = nil
        Self.note("TV disconnected")
    }

    /// A step of the TV, in the console's log as "[Cartouche] TV …" and in
    /// the journal a report takes along (System › Report a problem): a
    /// player's report says what the TV did, without a Mac to read the log.
    static func note(_ step: String) {
        NSLog("[Cartouche] %@", step)
        CartoucheReports.note(step)
    }
}

/// The one who fills the TV: the game host, while a game runs behind the
/// console.
@available(iOS 18.0, *)
@MainActor
protocol CartoucheTVHost: AnyObject {
    func tvDidConnect(_ tv: CartoucheTV)
    func tvWillDisconnect(_ tv: CartoucheTV)
}

// MARK: The TV's scene

/// The TV's scene, which iOS hands Cartouche for its scene accessory
/// (CartoucheGameHost), and which LiveContainer's app delegate gives this
/// delegate (app/patches/livecontainer/0012): Cartouche's TV screen, in a
/// window that is not key, so that the iPhone keeps the keyboard and the
/// controllers' focus. Its Objective-C name is the one the patch names.
@objc(CartoucheTVSceneDelegate)
final class CartoucheTVSceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
        guard #available(iOS 18.0, *), let scene = scene as? UIWindowScene else { return }
        MainActor.assumeIsolated {
            let window = UIWindow(windowScene: scene)
            window.rootViewController = CartoucheTVScreen(card: CartoucheTV.shared.card)
            // Without a window shown, iOS goes on mirroring the iPhone.
            window.isHidden = false
            self.window = window
            CartoucheTV.shared.connect(window)
        }
    }

    func sceneDidDisconnect(_ scene: UIScene) {
        guard #available(iOS 18.0, *) else { return }
        MainActor.assumeIsolated {
            if let window {
                CartoucheTV.shared.disconnect(window)
            }
            window = nil
        }
    }
}

// MARK: What the TV shows

/// The TV's screen: the game's TV scene, over Cartouche's card for the
/// game. The card shows where the game's scene shows nothing, and alone
/// while the game is paused.
@available(iOS 18.0, *)
final class CartoucheTVScreen: UIViewController {
    private let card: UIHostingController<CartoucheTVCard>
    /// Where the game's TV scene goes, over the card.
    private let gameArea = UIView()
    private(set) var game: UIViewController?

    init(card model: CartoucheTVCardModel) {
        card = UIHostingController(rootView: CartoucheTVCard(model: model))
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        return nil
    }

    override var prefersStatusBarHidden: Bool { true }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black

        addChild(card)
        card.view.frame = view.bounds
        card.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        card.view.backgroundColor = .clear
        card.view.accessibilityIdentifier = "tv.card"
        view.addSubview(card.view)
        card.didMove(toParent: self)

        gameArea.frame = view.bounds
        gameArea.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        gameArea.backgroundColor = .clear
        gameArea.isUserInteractionEnabled = false
        gameArea.accessibilityIdentifier = "tv.game"
        view.addSubview(gameArea)
    }

    /// The game's TV scene, over the card, in place of any other.
    func showGame(_ child: UIViewController) {
        guard child !== game else { return }
        removeGame()
        loadViewIfNeeded()
        addChild(child)
        child.view.frame = gameArea.bounds
        child.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        child.view.backgroundColor = .clear
        gameArea.addSubview(child.view)
        child.didMove(toParent: self)
        game = child
    }

    func removeGame() {
        guard let game else { return }
        game.willMove(toParent: nil)
        game.view.removeFromSuperview()
        game.removeFromParent()
        self.game = nil
    }

    /// Whether the game's TV scene shows, or the card alone: the card while
    /// the game is paused behind the console.
    var showsGame: Bool {
        get { loadViewIfNeeded(); return !gameArea.isHidden }
        set { loadViewIfNeeded(); gameArea.isHidden = !newValue }
    }
}

/// What the TV's card says of the game.
@available(iOS 18.0, *)
@MainActor
final class CartoucheTVCardModel: ObservableObject {
    enum Status: Equatable {
        /// The game's process starts.
        case starting
        /// The game is on screen: its own TV scene covers the card, unless
        /// it leaves it empty, as an nxnative from before its TV mode does.
        case playing
        /// The console is over the game, which waits behind it.
        case paused
    }

    @Published var name = ""
    @Published var cover: CartoucheArt?
    @Published var backdrop: CartoucheArt?
    /// The game's colours, as the console's (CartoucheEntry.tileKey).
    @Published var colorKey = ""
    @Published var status = Status.starting

    /// The card of a game, as its sheet shows it, starting.
    func show(_ app: LCAppModel) {
        let entry = CartoucheCatalog.shared.entries(for: [app]).owned.first
        show(name: entry?.name ?? app.displayName, cover: entry?.coverArt, backdrop: entry?.backdrop,
             colorKey: entry?.tileKey ?? app.appInfo.bundleIdentifier() ?? app.displayName)
    }

    func show(name: String, cover: CartoucheArt?, backdrop: CartoucheArt?, colorKey: String) {
        self.name = name
        self.cover = cover
        self.backdrop = backdrop
        self.colorKey = colorKey
        status = .starting
    }

    /// No game: Cartouche's name alone, while iOS takes the TV back once
    /// the game has ended.
    func clear() {
        show(name: "", cover: nil, backdrop: nil, colorKey: "")
    }

    var statusLine: String {
        switch status {
        case .starting: return CartoucheText.tvStarting
        case .playing: return CartoucheText.tvOnIPhone
        case .paused: return CartoucheText.tvPaused
        }
    }
}

/// The TV's card: the game's cover and name on the console's stage, lit by
/// the game's colours, sized to the TV. Nothing on it moves but the
/// spinner of a start, and nothing is touched.
@available(iOS 18.0, *)
struct CartoucheTVCard: View {
    @ObservedObject var model: CartoucheTVCardModel

    /// The height the console's stage is drawn at, then scaled to the TV's.
    private static let stageHeight: CGFloat = 540

    var body: some View {
        GeometryReader { frame in
            let height = max(frame.size.height, 1)
            let scale = height / Self.stageHeight
            ZStack {
                CartoucheStage(key: model.colorKey.isEmpty ? nil : model.colorKey, art: model.backdrop)
                    .frame(width: frame.size.width / scale, height: Self.stageHeight)
                    .scaleEffect(scale)
                if !model.name.isEmpty {
                    game(height: height, width: frame.size.width, colors: CartoucheTheme.colors(for: model.colorKey))
                }
                VStack {
                    Spacer()
                    CartoucheWordmark(size: height * 0.04)
                        .padding(.bottom, height * 0.05)
                }
            }
            .frame(width: frame.size.width, height: frame.size.height)
        }
        .ignoresSafeArea()
        .accessibilityElement(children: .combine)
    }

    /// The game's cover, its name and what it does.
    private func game(height: CGFloat, width: CGFloat, colors: (light: Color, dark: Color)) -> some View {
        HStack(spacing: height * 0.07) {
            CartoucheCoverImage(art: model.cover, whole: true) {
                ZStack {
                    LinearGradient(colors: [colors.light, colors.dark], startPoint: .topLeading,
                                   endPoint: .bottomTrailing)
                    Image(systemName: "gamecontroller.fill")
                        .font(.system(size: height * 0.09, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.85))
                }
            }
            .frame(width: height * 0.56 * CartoucheTheme.labelAspect, height: height * 0.56)
            .clipShape(RoundedRectangle(cornerRadius: height * 0.022, style: .continuous))
            .shadow(color: .black.opacity(0.5), radius: height * 0.03, y: height * 0.012)
            VStack(alignment: .leading, spacing: height * 0.025) {
                Text(model.name)
                    .font(.system(size: height * 0.062, weight: .bold))
                    .foregroundStyle(.white)
                    .lineLimit(3)
                    .minimumScaleFactor(0.6)
                HStack(spacing: height * 0.018) {
                    if model.status == .starting {
                        ProgressView()
                            .tint(.white)
                    } else if model.status == .paused {
                        Image(systemName: "pause.fill")
                    }
                    Text(model.statusLine)
                }
                .font(.system(size: height * 0.034, weight: .medium))
                .foregroundStyle(CartoucheTheme.secondaryText)
                .accessibilityIdentifier("tv.status")
            }
            .frame(maxWidth: width * 0.46, alignment: .leading)
        }
        .padding(.horizontal, width * 0.08)
    }
}
