//
//  UprightCaptures.swift
//  CartoucheHarnessTests
//
//  Research for the pull request's thread only, removed before the merge:
//  captures of the screen of a game behind the console on an iPhone held
//  upright, for the player to see the change before it goes. The
//  harness's stand-in game draws its picture and its touch controls where
//  nxnative's front end puts them (dm/ios/Sources/DmLayout.h and
//  DmGamepad.m, since e2fadf2 of 4 November 2026). The captures go next
//  to this file and in the app's Library/Logs/UprightCaptures, turned as
//  the player sees them with the iPhone held upright; the research
//  workflow (.github/workflows/upright-captures.yml) keeps them.
//

import UIKit
import XCTest
@testable import CartoucheHarness

@available(iOS 18.0, *)
final class UprightCaptures: HarnessCase {
    private var tvWindow: UIWindow?

    override func setUp() async throws {
        try await super.setUp()
        // Drawing and writing a capture of the whole screen.
        mainThreadLimit = 5
    }

    override func tearDown() async throws {
        if let window = tvWindow {
            tvWindow = nil
            CartoucheTV.shared.disconnect(window)
            window.isHidden = true
        }
        try await super.tearDown()
    }

    /// 0.12.1, with any game: sideways only. Today, a game nxnative built
    /// before 4 November.
    func test1Before() async throws {
        let (_, scene) = try await started(.plain())
        let screen = try await shown(scene, upright: false)
        try capture("1-avant", of: screen)
    }

    /// A game that lays itself out upright, the iPhone held upright.
    func test2After() async throws {
        let (_, scene) = try await started(.laidOutUpright())
        let screen = try await shown(scene, upright: true)
        try capture("2-apres", of: screen)
    }

    /// The same game, its picture on a TV: the controls alone, sideways.
    func test3AfterWithATV() async throws {
        let (_, scene) = try await started(.laidOutUpright())
        let screen = try await shown(scene, upright: true)
        let sceneOfCartouche = try XCTUnwrap(UIApplication.shared.connectedScenes.lazy.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: sceneOfCartouche)
        window.windowLevel = UIWindow.Level(rawValue: UIWindow.Level.normal.rawValue - 1)
        window.rootViewController = CartoucheTVScreen(card: CartoucheTV.shared.card)
        window.isHidden = false
        tvWindow = window
        CartoucheTV.shared.connect(window)
        try await waitUntil("the picture moves to the TV") { scene.tvScene != nil && screen.pictureOnTV }
        try await turned(screen, upright: false)
        standIn(of: scene)?.setNeedsDisplay()
        try await pause(1)
        try capture("3-apres-tele", of: screen)
    }

    // MARK: Helpers

    /// The game's screen once its stand-in draws nxnative's picture and
    /// controls, and the screen has turned.
    private func shown(_ scene: AppSceneViewController, upright: Bool) async throws -> CartoucheGameScreen {
        let screen = try XCTUnwrap(scene.parent as? CartoucheGameScreen)
        let content = try XCTUnwrap(scene.contentView)
        let standIn = NxnativeStandIn(frame: content.bounds)
        standIn.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        standIn.scene = scene
        content.addSubview(standIn)
        if upright, let windowScene = screen.view.window?.windowScene {
            // The player holds the iPhone upright, as the Simulator does,
            // but a test before left the screen sideways, and the
            // Simulator's iPhone does not turn to say it again.
            windowScene.requestGeometryUpdate(.iOS(interfaceOrientations: .portrait)) { error in
                NSLog("[Harness] upright: %@", "\(error)")
            }
        }
        try await turned(screen, upright: upright)
        try await pause(1)
        return screen
    }

    private func turned(_ screen: CartoucheGameScreen, upright: Bool) async throws {
        try await waitUntil(upright ? "the screen is upright" : "the screen is sideways", timeout: 10) {
            guard let orientation = screen.view.window?.windowScene?.effectiveGeometry.interfaceOrientation else { return false }
            let tall = screen.view.bounds.height > screen.view.bounds.width
            return orientation.isPortrait == upright && tall == upright
        }
    }

    private func standIn(of scene: AppSceneViewController) -> NxnativeStandIn? {
        scene.contentView?.subviews.lazy.compactMap { $0 as? NxnativeStandIn }.first
    }

    /// The game's window as the player sees it, the iPhone held upright: a
    /// sideways screen turns with the iPhone.
    private func capture(_ name: String, of screen: CartoucheGameScreen) throws {
        let window = try XCTUnwrap(screen.view.window)
        let format = UIGraphicsImageRendererFormat()
        format.scale = window.traitCollection.displayScale
        format.opaque = true
        let shot = UIGraphicsImageRenderer(size: window.bounds.size, format: format).image { _ in
            _ = window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        let orientation = window.windowScene?.effectiveGeometry.interfaceOrientation ?? .portrait
        let seen: UIImage
        switch orientation {
        case .landscapeRight: seen = Self.turn(shot, clockwise: true)
        case .landscapeLeft: seen = Self.turn(shot, clockwise: false)
        default: seen = shot
        }
        let png = try XCTUnwrap(seen.pngData())
        var written: [String] = []
        for folder in Self.folders {
            do {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                try png.write(to: folder.appendingPathComponent(name + ".png"))
                written.append(folder.path)
            } catch {
                NSLog("[Harness] capture %@: not written in %@: %@", name, folder.path, "\(error)")
            }
        }
        XCTAssertFalse(written.isEmpty, "the capture is written somewhere")
        NSLog("[Harness] capture %@: interface %ld, window %.0fx%.0f, %.0fx%.0f pixels, in %@", name, orientation.rawValue,
              window.bounds.width, window.bounds.height, seen.size.width * seen.scale, seen.size.height * seen.scale,
              written.joined(separator: ", "))
    }

    private static let folders: [URL] = [
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("UprightCaptures", isDirectory: true),
        URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Logs/UprightCaptures", isDirectory: true),
    ]

    private static func turn(_ image: UIImage, clockwise: Bool) -> UIImage {
        let size = CGSize(width: image.size.height, height: image.size.width)
        let format = UIGraphicsImageRendererFormat()
        format.scale = image.scale
        format.opaque = true
        return UIGraphicsImageRenderer(size: size, format: format).image { context in
            let cg = context.cgContext
            cg.translateBy(x: size.width / 2, y: size.height / 2)
            cg.rotate(by: clockwise ? .pi / 2 : -.pi / 2)
            image.draw(in: CGRect(x: -image.size.width / 2, y: -image.size.height / 2,
                                  width: image.size.width, height: image.size.height))
        }
    }
}

/// The stand-in game's picture and touch controls, where nxnative's front
/// end puts them (DmLayout.h dm_layout, DmGamepad.m): upright, the picture
/// fitted above the middle of the screen and the controls below it;
/// sideways, the picture over the whole screen and the controls in its
/// corners; while the picture is on a TV, the controls alone, as sideways
/// (dm_layout_pad_only).
final class NxnativeStandIn: UIView {
    weak var scene: AppSceneViewController?

    private let idle = UIColor(white: 1, alpha: 0.14)
    private let line = UIColor(white: 1, alpha: 0.38)
    private let ringFill = UIColor(white: 1, alpha: 0.06)
    private let text = UIColor(white: 1, alpha: 0.6)

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        contentMode = .redraw
        isUserInteractionEnabled = false
    }

    required init?(coder: NSCoder) {
        return nil
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        setNeedsDisplay()
    }

    override func safeAreaInsetsDidChange() {
        super.safeAreaInsetsDidChange()
        setNeedsDisplay()
    }

    override func draw(_ rect: CGRect) {
        let b = bounds
        let insets = safeAreaInsets
        var picture = CGRect.zero
        var controls = b
        var separated = false
        if scene?.tvScene == nil {
            picture = Self.fit(b)
            if b.height > b.width {
                let safe = b.inset(by: insets)
                let upper = CGRect(x: safe.minX, y: safe.minY, width: safe.width, height: b.midY - safe.minY)
                picture = Self.fit(upper)
                controls = CGRect(x: b.minX, y: b.midY, width: b.width, height: b.maxY - b.midY)
                separated = true
            }
        }
        drawPicture(in: picture)
        drawControls(in: controls, bounds: b, insets: insets, separated: separated)
    }

    /// The largest centered 16:9 rectangle in R.
    private static func fit(_ r: CGRect) -> CGRect {
        var w = r.width, h = r.height
        guard w > 0, h > 0 else { return .zero }
        let aspect: CGFloat = 16 / 9
        if w / h > aspect { w = h * aspect } else { h = w / aspect }
        return CGRect(x: floor(r.midX - w / 2), y: floor(r.midY - h / 2), width: w, height: h)
    }

    private func drawPicture(in r: CGRect) {
        guard r.width > 0, let context = UIGraphicsGetCurrentContext() else { return }
        context.saveGState()
        context.clip(to: r)
        let sky = [UIColor(red: 0.30, green: 0.55, blue: 0.93, alpha: 1).cgColor,
                   UIColor(red: 0.66, green: 0.84, blue: 1.00, alpha: 1).cgColor] as CFArray
        if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: sky, locations: [0, 1]) {
            context.drawLinearGradient(gradient, start: CGPoint(x: r.midX, y: r.minY), end: CGPoint(x: r.midX, y: r.maxY), options: [])
        }
        UIColor(red: 1.00, green: 0.86, blue: 0.35, alpha: 1).setFill()
        UIBezierPath(ovalIn: CGRect(x: r.minX + r.width * 0.78, y: r.minY + r.height * 0.12,
                                    width: r.height * 0.16, height: r.height * 0.16)).fill()
        let hills = UIBezierPath()
        hills.move(to: CGPoint(x: r.minX, y: r.maxY))
        hills.addLine(to: CGPoint(x: r.minX, y: r.minY + r.height * 0.72))
        hills.addQuadCurve(to: CGPoint(x: r.minX + r.width * 0.45, y: r.minY + r.height * 0.70),
                           controlPoint: CGPoint(x: r.minX + r.width * 0.22, y: r.minY + r.height * 0.55))
        hills.addQuadCurve(to: CGPoint(x: r.maxX, y: r.minY + r.height * 0.66),
                           controlPoint: CGPoint(x: r.minX + r.width * 0.75, y: r.minY + r.height * 0.82))
        hills.addLine(to: CGPoint(x: r.maxX, y: r.maxY))
        hills.close()
        UIColor(red: 0.30, green: 0.62, blue: 0.30, alpha: 1).setFill()
        hills.fill()
        context.restoreGState()
        let label = "Image du jeu" as NSString
        let attributes: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: max(13, r.height * 0.085), weight: .semibold),
            .foregroundColor: UIColor.white,
        ]
        let size = label.size(withAttributes: attributes)
        label.draw(at: CGPoint(x: r.midX - size.width / 2, y: r.minY + r.height * 0.38 - size.height / 2), withAttributes: attributes)
    }

    /// DmGamepad.m's arrangement, in its units: u = 1 for 430 points of
    /// height, sideways; below the picture, as the controls' area allows.
    private func drawControls(in controls: CGRect, bounds b: CGRect, insets: UIEdgeInsets, separated: Bool) {
        let safe = controls.intersection(b.inset(by: insets))
        guard !safe.isNull, safe.width > 0, safe.height > 0 else { return }
        var cornerInsets = insets
        cornerInsets.left *= 0.5
        cornerInsets.right *= 0.5
        let corner = separated ? safe : b.inset(by: cornerInsets)
        let u = separated ? min(min(safe.height / 430, safe.width / 700), 1.3) : min(b.height / 430, 1.3)
        let upright = separated && b.height > b.width
        func side(_ s: CGRect, _ right: Bool, _ dx: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: right ? s.maxX - dx : s.minX + dx, y: y)
        }
        func thumb(_ right: Bool) -> CGPoint {
            CGPoint(x: safe.minX + safe.width * (right ? 0.72 : 0.28), y: safe.minY + safe.height * 0.58)
        }
        let faceGap = 50 * u, faceR = 27 * u
        let edge = separated ? faceGap + max(faceR * 1.25, 22) : 0
        let face = upright ? thumb(true) : side(corner, true, max(81 * u, edge), corner.maxY - max(82 * u, edge))
        let stick = upright ? thumb(false) : side(corner, false, 81 * u, corner.maxY - 82 * u)
        circle(stick, 77 * u, fill: ringFill)
        circle(stick, 30 * u, fill: idle)
        let diamond: [(String, CGFloat, CGFloat)] = [("A", faceGap, 0), ("B", 0, faceGap), ("X", 0, -faceGap), ("Y", -faceGap, 0)]
        for (name, dx, dy) in diamond {
            key(CGPoint(x: face.x + dx, y: face.y + dy), faceR, name)
        }
        let dropEdge: CGFloat = separated ? 22 : 0
        let drops: [(String, Bool, Bool)] = [("ZL", false, true), ("L", false, false), ("ZR", true, true), ("R", true, false)]
        for (name, right, z) in drops {
            let center = side(safe, right, max(44 * u, dropEdge), safe.minY + max((z ? 40 : 108) * u, dropEdge))
            key(center, (z ? 26 : 24) * u, name)
        }
        let pillY = safe.minY + max(22 * u, separated ? 14 : 0)
        let pills: [(String, CGFloat)] = [("−", -52 * u), ("+", 52 * u)]
        for (name, dx) in pills {
            let pill = CGRect(x: safe.midX + dx - 25 * u, y: pillY - 14 * u, width: 50 * u, height: 28 * u)
            shape(UIBezierPath(roundedRect: pill, cornerRadius: pill.height / 2), fill: idle)
            label(name, at: CGPoint(x: pill.midX, y: pill.midY), size: 16 * u)
        }
        let menuR = 15 * u
        circle(CGPoint(x: safe.midX, y: pillY), menuR, fill: idle)
        if let gear = UIImage(systemName: "gearshape.fill",
                              withConfiguration: UIImage.SymbolConfiguration(pointSize: 13 * u, weight: .semibold))?
            .withTintColor(text, renderingMode: .alwaysOriginal) {
            gear.draw(at: CGPoint(x: safe.midX - gear.size.width / 2, y: pillY - gear.size.height / 2))
        }
    }

    private func circle(_ center: CGPoint, _ radius: CGFloat, fill: UIColor) {
        shape(UIBezierPath(ovalIn: CGRect(x: center.x - radius, y: center.y - radius, width: 2 * radius, height: 2 * radius)), fill: fill)
    }

    private func key(_ center: CGPoint, _ radius: CGFloat, _ name: String) {
        circle(center, radius, fill: idle)
        label(name, at: center, size: radius * 0.8)
    }

    private func shape(_ path: UIBezierPath, fill: UIColor) {
        fill.setFill()
        path.fill()
        line.setStroke()
        path.lineWidth = 1.5
        path.stroke()
    }

    private func label(_ name: String, at center: CGPoint, size: CGFloat) {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: size, weight: .semibold),
            .foregroundColor: text,
        ]
        let measured = (name as NSString).size(withAttributes: attributes)
        (name as NSString).draw(at: CGPoint(x: center.x - measured.width / 2, y: center.y - measured.height / 2), withAttributes: attributes)
    }
}
