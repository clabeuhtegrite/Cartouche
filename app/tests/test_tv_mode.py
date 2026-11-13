"""Checks the pieces of the TV mode that meet across the launcher, the
LiveContainer patch and the harness, so that a rename fails here, on Linux,
rather than on an iPhone plugged into a TV
(launcher/Sources/CartoucheTV.swift, docs/decisions.md, 85):

- LiveContainer's app delegate gives the TV's scene Cartouche's TV scene
  delegate, by the class the launcher declares, never LiveContainer's own
  scene delegate (app/patches/livecontainer/0012);
- AppSceneViewController declares the calls the game host makes to open,
  pause and close the game's scene on the TV, under the Swift names it
  calls them by, and the harness's stand-in has the same;
- it opens that scene with the specification iOS used for an external
  screen, and opens none when this iOS has no such class;
- the game host asks iOS for the TV while a game runs behind the console,
  with Cartouche's TV scene delegate, and stops asking when it ends;
- every step of the TV goes in the journal a player's report takes along,
  so that a report from an iPhone plugged into a TV says what the TV did.

Run from the repository root: python3 -m unittest discover -s app/tests -v
"""

import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SOURCES = ROOT / "launcher" / "Sources"
TV = SOURCES / "CartoucheTV.swift"
HOST = SOURCES / "CartoucheGameHost.swift"
HARNESS_SCENES = ROOT / "launcher" / "Harness" / "Sources" / "HarnessScenes.swift"
PATCHES = ROOT / "app" / "patches" / "livecontainer"
PATCHES_README = ROOT / "app" / "patches" / "README.md"

# The Swift names of AppSceneViewController's calls for the TV, as the
# header names them, and as the game host and the harness use them.
CALLS = {
    "openExternalDisplaySceneOnScreen:": "openExternalDisplayScene(on:",
    "setExternalDisplaySceneForeground:": "setExternalDisplaySceneForeground(",
    "closeExternalDisplayScene": "closeExternalDisplayScene(",
}


def added_lines(patch: str, path: str) -> list[str]:
    """The lines PATCH adds to the file at PATH."""
    hunks = re.split(r"^diff --git ", patch, flags=re.M)
    for hunk in hunks:
        if hunk.startswith(f"a/{path} b/{path}"):
            return [line[1:] for line in hunk.splitlines() if line.startswith("+") and not line.startswith("+++")]
    return []


class TVModeTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        patches = sorted(PATCHES.glob("*-give-a-game-behind-the-console-its-own-scene-on-a-tv.patch"))
        if len(patches) != 1:
            raise AssertionError(f"expected one TV patch in {PATCHES.relative_to(ROOT)}, found {len(patches)}")
        cls.patch_path = patches[0]
        cls.patch = patches[0].read_text(encoding="utf-8")
        cls.tv = TV.read_text(encoding="utf-8")
        cls.host = HOST.read_text(encoding="utf-8")
        cls.harness = HARNESS_SCENES.read_text(encoding="utf-8")

    def test_the_app_delegate_gives_the_tv_cartouches_scene_delegate(self):
        delegate = "\n".join(added_lines(self.patch, "LiveContainerSwiftUI/App/AppDelegate.swift"))
        self.assertIn("if #available(iOS 27.0, *), connectingSceneSession.role == .windowExternalDisplayNonInteractive {",
                      delegate)
        self.assertEqual(re.findall(r"delegateClass = (\w+)\.self", delegate), ["CartoucheTVSceneDelegate"],
                         "the TV never gets LiveContainer's own scene delegate")
        # The class the patch names, under the Objective-C name UIKit looks
        # up when it restores the TV's scene.
        self.assertRegex(self.tv, r"@objc\(CartoucheTVSceneDelegate\)\s+final class CartoucheTVSceneDelegate: "
                                  r"UIResponder, UIWindowSceneDelegate")

    def test_the_tvs_scene_shows_a_window_that_is_not_key(self):
        connect = re.search(r"func scene\(_ scene: UIScene, willConnectTo session: UISceneSession.*?\n    \}\n", self.tv, re.S)
        self.assertIsNotNone(connect, "CartoucheTVSceneDelegate no longer takes the TV's scene")
        body = connect.group(0)
        # Without a window shown, iOS goes on mirroring the iPhone; a key
        # window there would take the keyboard and the controllers' focus.
        self.assertIn("window.isHidden = false", body)
        self.assertNotIn("makeKey", body)
        self.assertIn("CartoucheTVScreen(card: CartoucheTV.shared.card)", body)

    def test_the_header_declares_the_calls_the_launcher_makes(self):
        header = "\n".join(added_lines(self.patch, "MultitaskSupport/AppSceneViewController.h"))
        implementation = "\n".join(added_lines(self.patch, "MultitaskSupport/AppSceneViewController.m"))
        self.assertIn("- (UIViewController *)openExternalDisplaySceneOnScreen:(UIScreen *)screen API_AVAILABLE(ios(18.0)) "
                      "NS_SWIFT_NAME(openExternalDisplayScene(on:));", header)
        self.assertIn("- (void)setExternalDisplaySceneForeground:(BOOL)foreground;", header)
        self.assertIn("- (void)closeExternalDisplayScene;", header)
        for selector, swift in CALLS.items():
            with self.subTest(selector=selector):
                self.assertIn(selector.rstrip(":"), implementation, "declared, never implemented")
                self.assertIn(swift, self.host, "the game host no longer calls it")
                self.assertRegex(self.harness, r"func " + re.escape(swift.split("(")[0]) + r"\(",
                                 "the harness's stand-in lacks it")

    def test_the_game_closes_its_tv_scene_as_its_process_ends(self):
        implementation = added_lines(self.patch, "MultitaskSupport/AppSceneViewController.m")
        self.assertIn("        [self closeExternalDisplayScene];", implementation,
                      "appTerminationCleanUp closes the game's scene on the TV")
        cleanup = re.search(r"func appTerminationCleanUp\(\) \{.*?\n    \}\n", self.harness, re.S)
        self.assertIsNotNone(cleanup)
        self.assertIn("self.closeExternalDisplayScene()", cleanup.group(0), "and the harness's stand-in does too")

    def test_the_scene_is_opened_with_the_external_screens_specification_or_not_at_all(self):
        implementation = "\n".join(added_lines(self.patch, "MultitaskSupport/AppSceneViewController.m"))
        self.assertIn('NSClassFromString(@"UIApplicationExternalScreenSceneSpecification")', implementation)
        # A class of another kind, or none, as on an iOS that renamed it:
        # no scene, and the TV shows the game's card.
        self.assertIn("![specificationClass isSubclassOfClass:UIApplicationSceneSpecification.class]", implementation)
        self.assertIn("config.sceneSpecification = [specificationClass specification];", implementation)
        self.assertIn("settings.displayConfiguration = screen.displayConfiguration;", implementation)

    def test_the_host_asks_ios_for_the_tv_while_a_game_runs_and_stops_after(self):
        ask = re.search(r"private func askForTheTV\(.*?\n    \}\n", self.host, re.S)
        self.assertIsNotNone(ask, "the game host no longer asks iOS for the TV")
        body = ask.group(0)
        self.assertIn("UISceneConfiguration(name: nil, sessionRole: .windowExternalDisplayNonInteractive)", body)
        self.assertIn("configuration.delegateClass = CartoucheTVSceneDelegate.self", body)
        self.assertIn(".registerSceneAccessory(.externalNonInteractive(sceneConfiguration: configuration))", body)
        start = re.search(r"func start\(_ app: LCAppModel.*?\n    \}\n", self.host, re.S)
        self.assertIsNotNone(start)
        self.assertIn("askForTheTV(from: [consoleWindow?.rootViewController, screen])", start.group(0))
        self.assertIn("guardTheTV()", start.group(0), "the game hides from a mirrored TV from its start")
        tear_down = re.search(r"private func tearDown\(\) \{.*?\n    \}\n", self.host, re.S)
        self.assertIsNotNone(tear_down)
        self.assertIn("stopAskingForTheTV()", tear_down.group(0))
        self.assertIn("closeGameOnTV()", tear_down.group(0))
        show = re.search(r"func showGame\(\) \{.*?\n    \}\n", self.host, re.S)
        self.assertIsNotNone(show)
        # Hidden from a mirrored TV before the game's window shows again.
        self.assertLess(show.group(0).index("guardTheTV()"), show.group(0).index("window.isHidden = false"))

    def test_every_step_of_the_tv_goes_in_the_reports_journal(self):
        note = re.search(r"static func note\(_ step: String\) \{.*?\n    \}\n", self.tv, re.S)
        self.assertIsNotNone(note, "CartoucheTV.note is gone")
        self.assertIn("CartoucheReports.note(step)", note.group(0))
        for name, source in (("CartoucheTV.swift", self.tv), ("CartoucheGameHost.swift", self.host)):
            with self.subTest(source=name):
                self.assertNotRegex(source, r'NSLog\("\[Cartouche\] TV',
                                    "a step of the TV logged, never in a report: CartoucheTV.note does both")
        anyway = re.search(r"anyway\.addAction\(UIAction \{.*?\}, for: \.primaryActionTriggered\)", self.host, re.S)
        self.assertIsNotNone(anyway)
        self.assertIn("CartoucheTV.note(", anyway.group(0), "the player showing the game anyway is noted")

    def test_the_patch_is_listed(self):
        listed = PATCHES_README.read_text(encoding="utf-8")
        self.assertIn(f"(livecontainer/{self.patch_path.name})", listed)


if __name__ == "__main__":
    unittest.main()
