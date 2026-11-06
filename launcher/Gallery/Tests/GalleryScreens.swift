//
//  GalleryScreens.swift
//  CartoucheGalleryScreens
//
//  Opens the gallery once for each scenario of scenarios.json meant for this
//  simulator and saves the screen as <scenario>.png into the folder
//  GALLERY_OUT names (TEST_RUNNER_GALLERY_OUT for xcodebuild), and as an
//  attachment of the test. GALLERY_DEVICE (TEST_RUNNER_GALLERY_DEVICE) names
//  the simulator, such as "iPhone Duo": its scenarios take the whole screen.
//  Without it, the scenarios that give a size are drawn at that size, in
//  the top left corner of an iPad's screen, and cut out of it.
//

import ObjectiveC
import UIKit
import XCTest

final class GalleryScreens: XCTestCase {
    struct Document: Decodable {
        struct Scenario: Decodable {
            let name: String
            let screen: String
            let device: String?
            let orientation: String?
            let width: Double?
            let height: Double?
            let insets: [Double]?
            let owned: [String]
            let setup: Bool
            let controller: Bool
            let sheet: String?
            let work: String?
        }

        let language: String
        let scenarios: [Scenario]
    }

    override func setUp() {
        continueAfterFailure = true
    }

    func testScreens() throws {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "scenarios", withExtension: "json"))
        let document = try JSONDecoder().decode(Document.self, from: Data(contentsOf: url))
        let environment = ProcessInfo.processInfo.environment
        let device = environment["GALLERY_DEVICE"] ?? ""
        let output = environment["GALLERY_OUT"].map { URL(fileURLWithPath: $0, isDirectory: true) }
        if let output {
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        }

        let scenarios = document.scenarios.filter { ($0.device ?? "") == device }
        XCTAssertFalse(scenarios.isEmpty, "no scenario for the simulator \(device)")
        var notes: [String] = []

        for scenario in scenarios {
            let wholeScreen = scenario.device != nil
            XCUIDevice.shared.orientation = scenario.orientation == "landscape" ? .landscapeLeft : .portrait

            let app = XCUIApplication()
            app.launchArguments = [
                "-AppleLanguages", "(\(document.language))",
                "-AppleLocale", document.language == "fr" ? "fr_FR" : "en_US",
                "-GalleryScreen", scenario.screen,
                "-GalleryOwned", scenario.owned.joined(separator: ","),
                "-GallerySetup", scenario.setup ? "1" : "0",
                "-GalleryController", scenario.controller ? "1" : "0",
            ]
            if !wholeScreen, let width = scenario.width, let height = scenario.height {
                app.launchArguments += [
                    "-GalleryWidth", String(width),
                    "-GalleryHeight", String(height),
                    "-GalleryInsets", (scenario.insets ?? [0, 0, 0, 0]).map { String($0) }.joined(separator: ","),
                ]
            }
            if let sheet = scenario.sheet {
                app.launchArguments += ["-GallerySheet", sheet]
            }
            if let work = scenario.work {
                app.launchArguments += ["-GalleryWork", work]
            }
            app.launch()
            // The layout, the stage's colours and the cartridges settle.
            Thread.sleep(forTimeInterval: 3)

            let screenshot = XCUIScreen.main.screenshot()
            var png = screenshot.pngRepresentation
            let pointsWide = app.frame.width
            if !wholeScreen, let width = scenario.width, let height = scenario.height,
               let image = screenshot.image.cgImage, pointsWide > 0 {
                let scale = CGFloat(image.width) / pointsWide
                let rect = CGRect(x: 0, y: 0, width: width * scale, height: height * scale)
                if let cropped = image.cropping(to: rect), let data = UIImage(cgImage: cropped).pngData() {
                    png = data
                }
            }
            if wholeScreen {
                notes.append("\(scenario.name): window \(app.frame.size), screenshot \(screenshot.image.size) at scale \(screenshot.image.scale)")
            }
            let attachment = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
            attachment.name = scenario.name
            attachment.lifetime = .keepAlways
            add(attachment)
            if let output {
                try png.write(to: output.appendingPathComponent(scenario.name + ".png"))
            }
            app.terminate()
        }
        XCUIDevice.shared.orientation = .portrait

        // What this Xcode offers to put a foldable simulator in a pose, for
        // the scenarios to come.
        if !device.isEmpty, let output {
            notes += ["", "XCUIDevice selectors about poses:"]
            notes += Self.selectors(of: XCUIDevice.self, matching: ["pose", "fold", "postur", "hinge", "display", "lid", "angle"])
            let name = device.lowercased().replacingOccurrences(of: " ", with: "-")
            try Data(notes.joined(separator: "\n").utf8).write(to: output.appendingPathComponent("\(name)-notes.txt"))
        }
    }

    private static func selectors(of type: AnyClass, matching words: [String]) -> [String] {
        var found: [String] = []
        for (target, prefix) in [(type as AnyClass?, "-"), (object_getClass(type), "+")] {
            var count: UInt32 = 0
            guard let target, let methods = class_copyMethodList(target, &count) else { continue }
            for index in 0..<Int(count) {
                let name = NSStringFromSelector(method_getName(methods[index]))
                if words.contains(where: { name.localizedCaseInsensitiveContains($0) }) {
                    found.append(prefix + name)
                }
            }
            free(methods)
        }
        return found.sorted()
    }
}
