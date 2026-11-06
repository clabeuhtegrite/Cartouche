"""Checks that the launcher's renewal still lines up with the pinned
LiveContainer and SideStore:

- the System tab finds CartoucheRefresh (launcher/SideStoreSupport) by the
  Objective-C names it declares;
- CartoucheRefresh runs the refresh exactly as LiveContainer's Refresh All
  Apps action does;
- Cartouche's warnings before expiry use SideStore's identifiers, so that each
  replaces the other instead of showing twice.

Needs the LiveContainer and SideStore submodules.
Run from the repository root: python3 -m unittest discover -s app/tests -v
"""

import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
LAUNCHER = ROOT / "launcher" / "Sources" / "CartoucheRenewal.swift"
BRIDGE = ROOT / "launcher" / "SideStoreSupport" / "CartoucheRefresh.swift"
LC_INTENTS = ROOT / "app" / "LiveContainer" / "SideStoreSupport" / "SideStore.swift"
SS_APP_MANAGER = ROOT / "app" / "SideStore" / "AltStore" / "Managing Apps" / "AppManager.swift"
SS_WARNINGS = (ROOT / "app" / "SideStore" / "SideStore" / "Core" / "Operations"
               / "StandaloneOperations" / "ScheduleExpirationWarningNotificationOperation.swift")


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


if __name__ == "__main__":
    unittest.main()
