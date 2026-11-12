"""Checks that the screen of a game behind the console turns as the game
allows (launcher/Sources/CartoucheGameHost.swift): by the Info.plist in the
game's bundle (CartoucheGameOrientations, tested by launcher/Package.swift),
never by LiveContainer's info(). That one is LiveContainer's own settings
for the game, LCAppInfo.plist, which name no orientation: read there, a game
made to be played sideways, as nxnative's are, turned upright with the
iPhone.

Needs the LiveContainer submodule.

Run from the repository root: python3 -m unittest discover -s app/tests -v
"""

import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
HOST = ROOT / "launcher" / "Sources" / "CartoucheGameHost.swift"
APP_INFO = ROOT / "app" / "LiveContainer" / "LiveContainerSwiftUI" / "Models" / "LCAppInfo.m"


class GameOrientationTest(unittest.TestCase):
    def test_livecontainers_info_is_its_own_settings_for_the_game(self):
        source = APP_INFO.read_text(encoding="utf-8")
        self.assertIn('_info = [NSMutableDictionary dictionaryWithContentsOfFile:'
                      '[NSString stringWithFormat:@"%@/LCAppInfo.plist", bundlePath]];', source)
        self.assertIn('_infoPlist = [NSMutableDictionary dictionaryWithContentsOfFile:'
                      '[NSString stringWithFormat:@"%@/Info.plist", bundlePath]];', source)
        self.assertRegex(source, r"- \(NSMutableDictionary\*\)info \{\s*return _info;\s*\}")

    def test_the_host_reads_the_info_plist_in_the_games_bundle(self):
        source = HOST.read_text(encoding="utf-8")
        found = re.search(r"\n    private static func orientations\(of app: LCAppModel\).*?\n    \}\n", source, re.S)
        self.assertIsNotNone(found, f"{HOST.name} has no orientations(of:)")
        self.assertIn("app.appInfo.bundlePath()", found.group(0))
        self.assertIn("CartoucheGameOrientations(bundle: ", found.group(0))
        self.assertNotIn(".info()", source)


if __name__ == "__main__":
    unittest.main()
