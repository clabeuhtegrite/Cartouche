"""Checks where the launcher reads the build of an installed game, its
version and the nxnative commit and chain it was built from
(CFBundleShortVersionString, DMCommit, DMChain):

- LiveContainer's info() of an app, at the pinned LiveContainer, is its own
  settings for the app, LCAppInfo.plist, never the Info.plist of the app's
  bundle, which holds the build;
- no launcher source reads those keys from info(): Cartouche 0.9.0 to 0.11.2
  did (CartoucheStoredGames.swift), and no install, session nor game sheet
  ever knew which build a game was;
- the launcher reads them from the Info.plist in the game's bundle.

Needs the LiveContainer submodule.
Run from the repository root: python3 -m unittest discover -s app/tests -v
"""

import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SOURCES = ROOT / "launcher" / "Sources"
STORED_GAMES = SOURCES / "CartoucheStoredGames.swift"
LC_APP_INFO = ROOT / "app" / "LiveContainer" / "LiveContainerSwiftUI" / "Models" / "LCAppInfo.m"
BUILD_KEYS = ("CFBundleShortVersionString", "DMCommit", "DMChain")


def read(path: Path) -> str:
    if not path.exists():
        raise AssertionError(f"{path.relative_to(ROOT)} is missing: run git submodule update --init --recursive")
    return path.read_text(encoding="utf-8")


def reads_from_info(text: str) -> list[str]:
    """The keys TEXT reads from LiveContainer's info(): straight from the
    call, or from a value it named after it."""
    found = re.findall(r'\.info\(\)\??\[\s*"([^"]+)"', text)
    for name in re.findall(r"\b(?:let|var)\s+(\w+)\s*=\s*[\w.]*\.info\(\)", text):
        found += re.findall(r"\b" + re.escape(name) + r'\??\[\s*"([^"]+)"', text)
    return found


class InstalledBuildTests(unittest.TestCase):
    def test_liveContainers_info_is_its_own_settings(self):
        text = read(LC_APP_INFO)
        self.assertRegex(text, r'_info = \[NSMutableDictionary dictionaryWithContentsOfFile:'
                               r'\[NSString stringWithFormat:@"%@/LCAppInfo\.plist", bundlePath\]\];')
        self.assertRegex(text, r'_infoPlist = \[NSMutableDictionary dictionaryWithContentsOfFile:'
                               r'\[NSString stringWithFormat:@"%@/Info\.plist", bundlePath\]\];')
        info = re.search(r"- \(NSMutableDictionary\*\)info \{(.*?)\n\}", text, re.S)
        self.assertIsNotNone(info, "LCAppInfo.m has no info method")
        self.assertEqual(info.group(1).strip(), "return _info;")

    def test_no_source_reads_the_build_from_info(self):
        for path in sorted(SOURCES.glob("*.swift")):
            with self.subTest(path.name):
                keys = set(reads_from_info(read(path))) & set(BUILD_KEYS)
                self.assertEqual(keys, set(), f"{path.name} reads {sorted(keys)} from LiveContainer's info(), "
                                              "its settings for the game, not the game's Info.plist")

    def test_the_build_is_read_from_the_games_bundle(self):
        text = read(STORED_GAMES)
        body = re.search(r"static func installedBuild\(of app: LCAppModel\) -> CartoucheGameBuild \{(.*?)\n    \}",
                         text, re.S)
        self.assertIsNotNone(body, "CartoucheStoredGames.swift has no installedBuild(of:)")
        self.assertIn("app.appInfo.bundlePath()", body.group(1))
        self.assertIn("CartoucheGameBuild.installed(atBundle:", body.group(1))
        self.assertNotIn(".info()", body.group(1))

    def test_the_old_reading_is_caught(self):
        # As CartoucheStoredGames.swift read the build up to 0.11.2.
        old = '''let info = app.appInfo.info()
        return CartoucheGameBuild(version: info?["CFBundleShortVersionString"] as? String, commit: info?["DMCommit"] as? String,
                                  chain: info?["DMChain"] as? String)'''
        self.assertEqual(reads_from_info(old), list(BUILD_KEYS))
        self.assertEqual(reads_from_info('let original = app.appInfo.info()?["LCOrignalBundleIdentifier"] as? String'),
                         ["LCOrignalBundleIdentifier"])


if __name__ == "__main__":
    unittest.main()
