"""Checks that the screen of a game behind the console turns as the game
allows (launcher/Sources/CartoucheGameHost.swift), and that no launcher
source reads a game's Info.plist through LiveContainer's info().

info() is LiveContainer's own settings for the game, LCAppInfo.plist, not
the game's Info.plist (test_installed_build.py checks it at the pinned
LiveContainer). The host read the game's UISupportedInterfaceOrientations
there, never found them, and let a game made to be played sideways, as
nxnative's are on an iPhone, turn upright with the iPhone, whether it could
be played upright or not. It now reads them from the Info.plist in the
game's bundle (CartoucheGameOrientations, tested by launcher/Package.swift).

On an iPhone, the game's screen turns upright too for a game that lays
itself out upright, as its Info.plist says for an iPad (nxnative's since
4 November 2026), while its picture is on the iPhone: the screen turns as
CartoucheGameOrientations.behindTheConsole says, and the host tells it when
the picture moves to a TV and back.

Needs the LiveContainer submodule.

Run from the repository root: python3 -m unittest discover -s app/tests -v
"""

import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SOURCES = ROOT / "launcher" / "Sources"
HOST = SOURCES / "CartoucheGameHost.swift"
LC_APP_INFO = ROOT / "app" / "LiveContainer" / "LiveContainerSwiftUI" / "Models" / "LCAppInfo.m"

# As CartoucheGameHost.swift read the game's orientations up to 0.11.2.
OLD_HOST = '''
    private static func orientations(of app: LCAppModel) -> UIInterfaceOrientationMask {
        let info = app.appInfo.info()
        let isPad = UIDevice.current.userInterfaceIdiom == .pad
        let key = "UISupportedInterfaceOrientations"
        let names = info?[key + (isPad ? "~ipad" : "~iphone")] as? [String] ?? info?[key] as? [String] ?? []
'''


def read(path: Path) -> str:
    if not path.exists():
        raise AssertionError(f"{path.relative_to(ROOT)} is missing: run git submodule update --init --recursive")
    return path.read_text(encoding="utf-8")


def livecontainers_keys() -> set[str]:
    """The keys of LiveContainer's own settings for an app: those LCAppInfo.m
    keeps in _info, which info() returns."""
    return set(re.findall(r'_info\[@"(\w+)"\]', read(LC_APP_INFO)))


def read_from_info(text: str) -> list[str]:
    """What TEXT reads from LiveContainer's info(), straight from the call or
    from a value it named after it: each key, or the expression it reads by."""
    subscript = r"\??\[\s*([^\]]+?)\s*\]"
    found = re.findall(r"\.info\(\)" + subscript, text)
    for name in re.findall(r"\b(?:let|var)\s+(\w+)\s*(?::[^=\n]+)?=\s*[\w.]*\.info\(\)(?!\s*\??\[)", text):
        found += re.findall(r"\b" + re.escape(name) + subscript, text)
    return [key[1:-1] if len(key) > 1 and key[0] == key[-1] == '"' else key for key in found]


class GameOrientationTest(unittest.TestCase):
    def test_the_host_reads_the_info_plist_in_the_games_bundle(self):
        source = read(HOST)
        found = re.search(r"\n    private static func orientations\(of app: LCAppModel, isPad: Bool\).*?\n    \}\n",
                          source, re.S)
        self.assertIsNotNone(found, f"{HOST.name} has no orientations(of:)")
        self.assertIn("app.appInfo.bundlePath()", found.group(0))
        self.assertIn("CartoucheGameOrientations(bundle: ", found.group(0))
        self.assertNotIn(".info()", source)

    def test_the_games_screen_turns_upright_too_while_its_picture_is_on_the_iphone(self):
        source = read(HOST)
        screen = source[source.index("final class CartoucheGameScreen"):]
        for line, why in (
            ("override var supportedInterfaceOrientations: UIInterfaceOrientationMask { Self.mask(of: turns) }",
             "the screen turns as it may turn now"),
            ("allowed.behindTheConsole(isPad: isPad, laysOutUpright: laysOutUpright, pictureOnTV: pictureOnTV)",
             "upright too on an iPhone, for a game that lays itself out upright, while its picture is on it"),
            ("requestGeometryUpdate(.iOS(interfaceOrientations: Self.mask(of: turns)))",
             "the screen is turned as it may turn now"),
        ):
            with self.subTest(why):
                self.assertTrue(line in screen, f"CartoucheGameScreen: {why}: no {line!r}")
        self.assertTrue("laysOutUpright: Self.laysOutUpright(app)" in source,
                        f"{HOST.name} does not tell the game's screen whether the game lays itself out upright")
        laid_out = re.search(r"\n    private static func laysOutUpright\(_ app: LCAppModel\).*?\n    \}\n", source, re.S)
        self.assertIsNotNone(laid_out, f"{HOST.name} has no laysOutUpright(_:)")
        self.assertIn("app.appInfo.bundlePath()", laid_out.group(0))
        self.assertIn("CartoucheGameOrientations.laysOutUpright(bundle: ", laid_out.group(0))
        # The picture goes to the TV and comes back with the game's own scene there.
        for function, moved in (("openGameOnTV", "true"), ("closeGameOnTV", "false")):
            with self.subTest(function):
                body = re.search(r"\n    private func " + function + r"\(\).*?\n    \}\n", source, re.S)
                self.assertIsNotNone(body, f"{HOST.name} has no {function}()")
                self.assertIn(f"pictureMoved(toTV: {moved})", body.group(0))

    def test_no_source_reads_more_than_livecontainers_settings_from_info(self):
        own = livecontainers_keys()
        self.assertIn("LCOrignalBundleIdentifier", own)
        self.assertNotIn("UISupportedInterfaceOrientations", own)
        for path in sorted(SOURCES.glob("*.swift")):
            with self.subTest(path.name):
                others = sorted(set(read_from_info(read(path))) - own)
                self.assertEqual(others, [], f"{path.name} reads {others} from LiveContainer's info(), its own "
                                             "settings for the game: the game's Info.plist is in its bundle")

    def test_the_old_reading_is_caught(self):
        self.assertEqual(read_from_info(OLD_HOST), ['key + (isPad ? "~ipad" : "~iphone")', "key"])
        self.assertFalse(set(read_from_info(OLD_HOST)) <= livecontainers_keys())
        self.assertEqual(read_from_info('let original = app.appInfo.info()?["LCOrignalBundleIdentifier"] as? String'),
                         ["LCOrignalBundleIdentifier"])
        self.assertEqual(read_from_info('if let info = app.appInfo.info(), let id = info["LCDataUUID"] as? String {'),
                         ["LCDataUUID"])


if __name__ == "__main__":
    unittest.main()
