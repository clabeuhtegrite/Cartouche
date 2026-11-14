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

In Cartouche's place, the game is the app, and iOS turns it as the game's
own Info.plist allows on an iPhone, sideways only for nxnative's: Cartouche's
code in the game's process (launcher/Guest/CartoucheUprightGame.m) tells
UIKit the game allows upright too, by the same rule, read from the same
Info.plist, never in LiveProcess, on an iPad, for a game the player locked
one way, or while a TV has the game's picture, and starts before iOS gives
the game its first scene, without linking UIKit, which LiveContainerShared
loads before.

Needs the LiveContainer submodule.

Run from the repository root: python3 -m unittest discover -s app/tests -v
"""

import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SOURCES = ROOT / "launcher" / "Sources"
HOST = SOURCES / "CartoucheGameHost.swift"
ORIENTATION = SOURCES / "CartoucheGameOrientation.swift"
GUEST = ROOT / "launcher" / "Guest" / "CartoucheUprightGame.m"
LC_GUEST_HOOKS = ROOT / "app" / "LiveContainer" / "TweakLoader" / "UIKit+GuestHooks.m"
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


def c_function(source: str, name: str) -> str:
    """The text of the C function NAME of SOURCE, from its first line to its
    closing brace at the start of a line."""
    found = re.search(r"\n(?:static |__attribute__\(\(constructor\)\)\nstatic )[^\n]*\b" + re.escape(name)
                      + r"\(.*?\n\}\n", source, re.S)
    if found is None:
        raise AssertionError(f"no function {name}")
    return found.group(0)


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


class GameInCartouchesPlaceTest(unittest.TestCase):
    """A game started in Cartouche's place turns upright too on an iPhone, by
    the same rule as behind the console (launcher/Guest/CartoucheUprightGame.m)."""

    @classmethod
    def setUpClass(cls):
        cls.guest = read(GUEST)

    def test_it_reads_the_games_own_info_plist_as_the_launcher_does(self):
        laid_out = c_function(self.guest, "CartoucheUprightLaysOutUpright")
        self.assertIn('[NSDictionary dictionaryWithContentsOfFile:[bundle stringByAppendingPathComponent:@"Info.plist"]]',
                      laid_out)
        # The iPad's list first, then the one for every device, as
        # CartoucheGameOrientations.laysOutUpright(bundle:) reads them: as on an iPad.
        self.assertIn('@[@"UISupportedInterfaceOrientations~ipad", @"UISupportedInterfaceOrientations"]', laid_out)
        self.assertIn('[names containsObject:@"UIInterfaceOrientationPortrait"]', laid_out)
        swift = read(ORIENTATION)
        self.assertIn("CartoucheGameOrientations(bundle: bundle, isPad: true).contains(.portrait)", swift)
        self.assertIn('info[key + (isPad ? "~ipad" : "~iphone")] as? [String] ?? info[key] as? [String]', swift)
        # nxnative's games only, as the play time counter knows them.
        self.assertIn('[bundle stringByAppendingPathComponent:@"dm"]', laid_out)
        self.assertIn('info[@"DMLanguage"]', laid_out)
        # The game's own bundle, in its own process, never the Info.plist
        # NSBundle has read for this device, which leaves the iPad's list out.
        self.assertIn("CartoucheUprightLaysOutUpright(NSBundle.mainBundle.bundlePath)",
                      c_function(self.guest, "CartoucheUprightStart"))
        self.assertNotIn("infoDictionary", self.guest)

    def test_only_a_game_in_cartouches_place_on_an_iphone_not_locked_one_way(self):
        start = c_function(self.guest, "CartoucheUprightStart")
        for check, why in (
            ("if (!NSUserDefaults.lcGuestAppId || NSUserDefaults.isLiveProcess || NSUserDefaults.isSideStore) return;",
             "a game, in Cartouche's own process: behind the console, Cartouche turns the game's screen itself"),
            ("userInterfaceIdiom] != CartoucheUprightPhone) return;", "on an iPhone only"),
            ('if ([NSUserDefaults.guestAppInfo[@"LCOrientationLock"] integerValue] != 0) return;',
             "never for a game the player locked one way in LiveContainer's settings"),
        ):
            with self.subTest(why):
                self.assertIn(check, start)
        self.assertIn("static const NSInteger CartoucheUprightPhone = 0;", self.guest)
        # LiveContainer's own lock reads the same key, and replaces the same
        # call of UIKit, in Cartouche's place only.
        hooks = read(LC_GUEST_HOOKS)
        self.assertIn('NSUserDefaults.guestAppInfo[@"LCOrientationLock"]', hooks)
        self.assertRegex(hooks, r"if\(!NSUserDefaults\.isLiveProcess && LCOrientationLock != UIInterfaceOrientationUnknown\) \{"
                                r"(?:\n[^\n]*){1,3}\n\s*swizzle\(UIViewController\.class, @selector\(__supportedInterfaceOrientations\)")

    def test_upright_only_never_upside_down(self):
        self.assertIn("static const NSUInteger CartoucheUprightMask = 1 << 1;   // UIInterfaceOrientationMaskPortrait",
                      self.guest)
        self.assertEqual(re.findall(r"ways \|= (\w+);", self.guest), ["CartoucheUprightMask", "CartoucheUprightMask"])
        self.assertNotRegex(self.guest, r"1 << [02-9]|UpsideDown\b(?!\")")
        # Upright for a view controller that allows it itself, as nxnative's do.
        self.assertIn("if (CartoucheUprightNow() && ([self supportedInterfaceOrientations] & CartoucheUprightMask)) {",
                      c_function(self.guest, "CartoucheUprightViewControllerWays"))

    def test_uikit_hears_it_from_the_view_controller_and_the_app_and_each_still_answers(self):
        start = c_function(self.guest, "CartoucheUprightStart")
        for selector, hook in (("__supportedInterfaceOrientations", "CartoucheUprightViewControllerWays"),
                               ("supportedInterfaceOrientationsForWindow:", "CartoucheUprightApplicationWays")):
            with self.subTest(selector):
                self.assertIn(f'NSSelectorFromString(@"{selector}")', start)
                self.assertIn(f"(IMP){hook})", start)
        self.assertIn("NSUInteger ways = viewControllerWays(self, _cmd);",
                      c_function(self.guest, "CartoucheUprightViewControllerWays"))
        self.assertIn("NSUInteger ways = applicationWays(self, _cmd, window);",
                      c_function(self.guest, "CartoucheUprightApplicationWays"))

    def test_not_while_a_tv_has_the_games_picture(self):
        self.assertIn("return turnsUpright && !CartoucheUprightPictureOnTV();", c_function(self.guest, "CartoucheUprightNow"))
        self.assertIn("if ([[[scene session] role] isEqualToString:tvRole]) return YES;",
                      c_function(self.guest, "CartoucheUprightPictureOnTV"))
        start = c_function(self.guest, "CartoucheUprightStart")
        self.assertIn('tvRole = CartoucheUprightUIKitName("UIWindowSceneSessionRoleExternalDisplayNonInteractive");', start)
        # The TV's scene nxnative takes, by cable or AirPlay.
        self.assertIn("UIWindowSceneSessionRoleExternalDisplayNonInteractive", read(HOST.parent / "CartoucheTV.swift")
                      + read(ROOT / "app" / "patches" / "livecontainer"
                             / "0012-give-a-game-behind-the-console-its-own-scene-on-a-tv.patch").replace(
                                 ".windowExternalDisplayNonInteractive", "UIWindowSceneSessionRoleExternalDisplayNonInteractive"))
        # As the TV comes and goes, UIKit asks again, once iOS is done with its scene.
        for name in ("UISceneWillConnectNotification", "UISceneDidDisconnectNotification"):
            self.assertIn(f'CartoucheUprightUIKitName("{name}")', start)
        self.assertIn("CartoucheUprightAskAgain();", start)
        self.assertIn("[root setNeedsUpdateOfSupportedInterfaceOrientations];",
                      c_function(self.guest, "CartoucheUprightAskAgain"))

    def test_it_starts_before_the_game_has_its_first_scene(self):
        init = c_function(self.guest, "CartoucheUprightInit")
        self.assertIn('addObserverForName:@"UIApplicationDidFinishLaunchingNotification"', init)
        # Without a queue, the call comes as UIKit says it, not after.
        self.assertRegex(init, r"queue:nil\s")
        self.assertIn("CartoucheUprightStart();", init)

    def test_it_does_not_link_uikit(self):
        code = re.sub(r"//[^\n]*", "", self.guest)
        self.assertIsNone(re.search(r"@import UIKit|#(?:import|include) <UIKit", code))
        # UIKit's classes are found at run time, never referenced at link time.
        self.assertIsNone(re.search(r"\[(?:UIApplication|UIDevice|UIViewController|UIScene|UIWindow\w*) ", code))
        self.assertIsNone(re.search(r"\bUI\w+\.class\b", code))
        self.assertIn('NSClassFromString(@"UIViewController")', code)


if __name__ == "__main__":
    unittest.main()
