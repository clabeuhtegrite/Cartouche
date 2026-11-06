"""Checks that Cartouche's own updates line up with the built-in SideStore's
patch (app/patches/sidestore/0010) and with the packaging:

- the launcher finds CartoucheUpdate (launcher/SideStoreSupport) by the
  Objective-C names it declares;
- CartoucheUpdate runs the action that the patch adds, by its type's mangled
  name in SideStore's module, and Shortcuts does not list that action;
- the launcher listens for the Darwin notification that the patch posts;
- app/scripts/package.sh writes the source address the launcher reads, and
  app/scripts/build.sh passes the one in app/config.env.

Run from the repository root: python3 -m unittest discover -s app/tests -v
"""

import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
UPDATES = ROOT / "launcher" / "Sources" / "CartoucheUpdates.swift"
BRIDGE = ROOT / "launcher" / "SideStoreSupport" / "CartoucheUpdate.swift"
PATCHES = ROOT / "app" / "patches" / "sidestore"
PACKAGE = ROOT / "app" / "scripts" / "package.sh"
BUILD = ROOT / "app" / "scripts" / "build.sh"
# SideStore's app target, the module its intents' mangled names start with,
# as in the names LiveContainer passes for Refresh All Apps.
MODULE = "SideStore"


def added_by_patch() -> str:
    """The lines patch 0010 adds to SideStore."""
    patches = sorted(PATCHES.glob("*-let-cartouche-update-itself-through-the-built-in-sidestore.patch"))
    if len(patches) != 1:
        raise AssertionError(f"expected one update patch in {PATCHES.relative_to(ROOT)}, found {len(patches)}")
    lines = patches[0].read_text(encoding="utf-8").splitlines()
    return "\n".join(line[1:] for line in lines if line.startswith("+") and not line.startswith("+++"))


def found(pattern: str, text: str, what: str, flags: int = 0) -> re.Match:
    match = re.search(pattern, text, flags)
    if not match:
        raise AssertionError(f"{what} not found")
    return match


class UpdateTest(unittest.TestCase):
    def test_the_launcher_finds_the_bridge_by_its_objective_c_names(self):
        launcher = UPDATES.read_text(encoding="utf-8")
        bridge = BRIDGE.read_text(encoding="utf-8")
        class_name = found(r'NSClassFromString\("([^"]+)"\)', launcher, "the bridge's class").group(1)
        selector = found(r'NSSelectorFromString\("(update[^"]+)"\)', launcher, "the bridge's selector").group(1)
        self.assertIn(f"@objc({class_name})\npublic final class", bridge)
        self.assertIn(f"@objc({selector})\n    public static func", bridge)

    def test_the_bridge_runs_the_action_the_patch_adds(self):
        added = added_by_patch()
        name = found(r"^struct (\w+): AppIntent\b", added, "the AppIntent the patch adds", re.M).group(1)
        identifier, mangled = found(
            r'performIntentRefresh\(\s*identifier:\s*"([^"]+)",\s*mangledTypeName:\s*"([^"]+)"',
            BRIDGE.read_text(encoding="utf-8"), "the bridge's performIntentRefresh call").groups()
        self.assertEqual(identifier, name)
        self.assertEqual(mangled, f"{len(MODULE)}{MODULE}{len(name)}{name}V")
        self.assertIn("static var isDiscoverable: Bool { false }", added)

    def test_the_launcher_listens_for_the_notification_the_patch_posts(self):
        posted = found(r'CFNotificationName\("\\\(Bundle\.Info\.appbundleIdentifier\)(\.\w+)"',
                       added_by_patch(), "the notification the patch posts").group(1)
        heard = found(r'"\\\(bundleIdentifier\)(\.\w+)" as CFString',
                      UPDATES.read_text(encoding="utf-8"), "the notification the launcher observes").group(1)
        self.assertEqual(posted, heard)

    def test_the_app_carries_the_source_address(self):
        key = found(r'forInfoDictionaryKey: "(CartoucheSource\w*)"',
                    UPDATES.read_text(encoding="utf-8"), "the source's Info.plist key").group(1)
        self.assertIn(f'Add :{key} string $SOURCE_URL', PACKAGE.read_text(encoding="utf-8"))
        self.assertIn('--source-url "$CARTOUCHE_SIDESTORE_SOURCE_URL"', BUILD.read_text(encoding="utf-8"))


if __name__ == "__main__":
    unittest.main()
