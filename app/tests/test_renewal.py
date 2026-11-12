"""Checks that the launcher's renewal still lines up with the pinned
LiveContainer and SideStore:

- the System tab finds CartoucheRefresh (launcher/SideStoreSupport) by the
  Objective-C names it declares;
- CartoucheRefresh runs the refresh exactly as LiveContainer's Refresh All
  Apps action does;
- Cartouche's warnings before expiry use SideStore's identifiers, so that each
  replaces the other instead of showing twice;
- the built-in SideStore renews Cartouche alone (app/patches/sidestore/0017),
  and Refresh All Apps still takes its apps where the patch changes them.

Needs the LiveContainer and SideStore submodules, and patch(1).
Run from the repository root: python3 -m unittest discover -s app/tests -v
"""

import re
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
LAUNCHER = ROOT / "launcher" / "Sources" / "CartoucheRenewal.swift"
BRIDGE = ROOT / "launcher" / "SideStoreSupport" / "CartoucheRefresh.swift"
LC_INTENTS = ROOT / "app" / "LiveContainer" / "SideStoreSupport" / "SideStore.swift"
SS_APP_MANAGER = ROOT / "app" / "SideStore" / "AltStore" / "Managing Apps" / "AppManager.swift"
SS_WARNINGS = (ROOT / "app" / "SideStore" / "SideStore" / "Core" / "Operations"
               / "StandaloneOperations" / "ScheduleExpirationWarningNotificationOperation.swift")
SS_INSTALLED_APP_PATH = "AltStore/Core/Model/InstalledApp.swift"
SS_INSTALLED_APP = ROOT / "app" / "SideStore" / SS_INSTALLED_APP_PATH
SS_REFRESH_ALL = ROOT / "app" / "SideStore" / "AltStore" / "Intents" / "App Intents" / "RefreshAllAppsIntent.swift"
SS_APP_DELEGATE = ROOT / "app" / "SideStore" / "AltStore" / "AppDelegate.swift"
SS_PATCHES = ROOT / "app" / "patches" / "sidestore"


def read(path: Path) -> str:
    if not path.exists():
        raise AssertionError(f"{path.relative_to(ROOT)} is missing: run git submodule update --init --recursive")
    return path.read_text(encoding="utf-8")


def refresh_call(text: str) -> tuple[str, str]:
    """The identifier and mangled type name passed to performIntentRefresh."""
    match = re.search(
        r'performIntentRefresh\(\s*identifier:\s*"([^"]+)",\s*mangledTypeName:\s*"([^"]+)"', text)
    if not match:
        raise AssertionError("no performIntentRefresh call found")
    return match.group(1), match.group(2)


def renew_alone_patch() -> Path:
    patches = sorted(SS_PATCHES.glob("*-renew-cartouche-alone.patch"))
    if len(patches) != 1:
        raise AssertionError(f"expected one renew-alone patch in {SS_PATCHES.relative_to(ROOT)}, found {len(patches)}")
    return patches[0]


def function_body(text: str, name: str) -> str:
    """The body of SideStore's `class func NAME(`, braces included."""
    start = text.find(f"class func {name}(")
    if start < 0:
        raise AssertionError(f"{name} not found")
    first = text.index("{", start)
    depth = 0
    for index in range(first, len(text)):
        if text[index] == "{":
            depth += 1
        elif text[index] == "}":
            depth -= 1
            if depth == 0:
                return text[first:index + 1]
    raise AssertionError(f"{name} does not end")


class RenewalTest(unittest.TestCase):
    def test_the_launcher_finds_the_bridge_by_its_objective_c_names(self):
        launcher, bridge = read(LAUNCHER), read(BRIDGE)
        class_name = re.search(r'NSClassFromString\("([^"]+)"\)', launcher).group(1)
        selector = re.search(r'NSSelectorFromString\("([^"]+)"\)', launcher).group(1)
        self.assertIn(f"@objc({class_name})\npublic final class", bridge)
        self.assertIn(f"@objc({selector})\n    public static func", bridge)

    def test_the_bridge_refreshes_like_the_refresh_all_apps_action(self):
        lc = read(LC_INTENTS)
        action = re.search(r"struct RefreshAllAppsIntent\b.*?\n}\n", lc, re.S)
        self.assertIsNotNone(action, "RefreshAllAppsIntent is gone from SideStore.swift")
        self.assertEqual(refresh_call(read(BRIDGE)), refresh_call(action.group(0)))

    def test_the_warnings_share_sidestores_identifiers(self):
        prefix = re.search(r'expirationWarningNotificationID = "([^"]+)"', read(SS_APP_MANAGER)).group(1)
        milestones = re.findall(r'^\s*\("(\w+)",\s*[\d *]+,', read(SS_WARNINGS), re.M)
        self.assertTrue(milestones, "no milestone found in SideStore's warnings")
        expected = sorted(f"{prefix}.{milestone}" for milestone in milestones)
        found = sorted(re.findall(r'\("(sidestore-expiration-warning\.\w+)",', read(LAUNCHER)))
        self.assertEqual(found, expected)

    def test_the_built_in_sidestore_renews_cartouche_alone(self):
        # SideStore's database is in the app group of every SideStore of the
        # same Apple ID, whose apps it holds too: Cartouche renews none of them.
        patch = renew_alone_patch()
        others = [other.name for other in sorted(SS_PATCHES.glob("*.patch"))
                  if other != patch and f"+++ b/{SS_INSTALLED_APP_PATH}" in other.read_text(encoding="utf-8")]
        self.assertEqual(others, [], "another patch changes InstalledApp.swift: apply it here too")
        with tempfile.TemporaryDirectory() as directory:
            copy = Path(directory) / SS_INSTALLED_APP_PATH
            copy.parent.mkdir(parents=True)
            copy.write_text(read(SS_INSTALLED_APP), encoding="utf-8")
            subprocess.run(["patch", "-s", "-N", "-t", "-p1", "-d", directory, "-i", str(patch)], check=True)
            patched = copy.read_text(encoding="utf-8")
        for name in ("fetchAppsForRefreshingAll", "fetchAppsForBackgroundRefresh"):
            body = function_body(patched, name)
            self.assertIn("InstalledApp.fetchAltStore(in: context)", body, name)
            self.assertNotIn("InstalledApp.all(", body, name)
            self.assertNotIn("NSPredicate", body, name)

    def test_refresh_all_apps_takes_its_apps_where_the_patch_changes_them(self):
        intent = read(SS_REFRESH_ALL)
        refresh = re.search(r"\n    func refreshAllApps\(\).*?\n    }\n", intent, re.S)
        self.assertIsNotNone(refresh, "RefreshAllAppsIntent.refreshAllApps is gone")
        self.assertIn("InstalledApp.fetchAppsForRefreshingAll(in: context)", refresh.group(0))
        self.assertIn("InstalledApp.fetchAppsForBackgroundRefresh(in: context)", read(SS_APP_DELEGATE))


if __name__ == "__main__":
    unittest.main()
