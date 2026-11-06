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
//  Each scenario is an activity of its own in the result bundle, so that a
//  failure names the scenario it happened in. On a named simulator, the
//  notes file (<device>-notes.txt) is written before the first scenario and
//  after each one: a scenario that stops the test leaves those of the
//  scenarios before it.
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

        // What this Xcode offers to put a foldable simulator in a pose, for
        // the scenarios to come, then how each scenario's screen came out.
        var notes = ["XCUIDevice selectors about poses:"]
        notes += Self.selectors(of: XCUIDevice.self, matching: ["pose", "fold", "postur", "hinge", "display", "lid", "angle"])
        notes.append("")
        let notesFile: URL?
        if !device.isEmpty, let output {
            let name = device.lowercased().replacingOccurrences(of: " ", with: "-")
            notesFile = output.appendingPathComponent("\(name)-notes.txt")
        } else {
            notesFile = nil
        }
        func writeNotes() throws {
            if let notesFile {
                try Data(notes.joined(separator: "\n").utf8).write(to: notesFile)
            }
        }
        try writeNotes()

        for scenario in scenarios {
            let note = try XCTContext.runActivity(named: "Scenario \(scenario.name)") { _ in
                try capture(scenario, language: document.language, output: output)
            }
            if let note {
                notes.append(note)
                try writeNotes()
            }
        }
        if XCUIDevice.shared.orientation != .portrait {
            XCUIDevice.shared.orientation = .portrait
        }
    }

    /// Opens the gallery on the scenario's screen and saves it. Returns, for
    /// a scenario that takes the whole screen, how its window and its
    /// screenshot came out.
    private func capture(_ scenario: Document.Scenario, language: String, output: URL?) throws -> String? {
        let wholeScreen = scenario.device != nil
        let landscape = scenario.orientation == "landscape"
        let orientation: UIDeviceOrientation = landscape ? .landscapeLeft : .portrait
        // Turning the simulator only when it has to: each turn goes through
        // Xcode, and a scenario upright after another one stays as it is.
        if XCUIDevice.shared.orientation != orientation {
            XCUIDevice.shared.orientation = orientation
        }

        let app = XCUIApplication()
        app.launchArguments = [
            "-AppleLanguages", "(\(language))",
            "-AppleLocale", language == "fr" ? "fr_FR" : "en_US",
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
        let window = app.frame.size
        if !wholeScreen, let width = scenario.width, let height = scenario.height,
           let image = screenshot.image.cgImage, window.width > 0 {
            let scale = CGFloat(image.width) / window.width
            let rect = CGRect(x: 0, y: 0, width: width * scale, height: height * scale)
            if let cropped = image.cropping(to: rect), let data = UIImage(cgImage: cropped).pngData() {
                png = data
            }
        }
        let attachment = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
        attachment.name = scenario.name
        attachment.lifetime = .keepAlways
        add(attachment)
        if let output {
            try png.write(to: output.appendingPathComponent(scenario.name + ".png"))
        }
        app.terminate()

        guard wholeScreen else { return nil }
        let size = screenshot.image.size
        // A sideways scenario whose screen came out upright shows nothing
        // that the upright one does not.
        if landscape, size.width < size.height {
            XCTFail("\(scenario.name): the simulator stayed upright, the screenshot is \(size)")
        }
        return "\(scenario.name): window \(window), screenshot \(size) at scale \(screenshot.image.scale), "
            + "device orientation \(XCUIDevice.shared.orientation.rawValue)"
    }

    private static func selectors(of type: AnyClass, matching words: [String]) -> [String] {
        var found: [String] = []
        let targets: [(AnyClass?, String)] = [(type, "-"), (object_getClass(type), "+")]
        for (target, prefix) in targets {
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
