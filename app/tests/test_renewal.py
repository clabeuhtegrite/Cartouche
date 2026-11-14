"""Checks that the launcher's renewal still lines up with the pinned
LiveContainer and SideStore:

- the System tab finds CartoucheRefresh (launcher/SideStoreSupport) by the
  Objective-C names it declares;
- CartoucheRefresh runs the refresh exactly as LiveContainer's Refresh All
  Apps action does;
- Cartouche's warnings before expiry use SideStore's identifiers, so that each
  replaces the other instead of showing twice;
- the built-in SideStore renews Cartouche alone (app/patches/sidestore/0017),
  and Refresh All Apps still takes its apps where the patch changes them;
- Refresh All Apps waits for LocalDevVPN's tunnel, which the automation of
  Shortcuts connects just before it (app/patches/livecontainer/0015), and
  reads it as the launcher does.

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
LC_PATCHES = ROOT / "app" / "patches" / "livecontainer"
LC_INTENTS_PATH = "SideStoreSupport/SideStore.swift"
TUNNEL_WAIT = ROOT / "launcher" / "SideStoreSupport" / "CartoucheTunnelWait.swift"
LAUNCHER_VPN = ROOT / "launcher" / "Sources" / "CartoucheVPN.swift"


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


def file_part(patch: str, path: str) -> str:
    """The part of a git patch that changes PATH, or ""."""
    parts = re.split(r"(?m)^(?=diff --git )", patch)
    found = [part for part in parts if part.startswith(f"diff --git a/{path} b/{path}\n")]
    return found[0] if found else ""


def patched_lc_intents() -> str:
    """LiveContainer's SideStore.swift with Cartouche's patches applied, in
    their order, as app/scripts/prepare.sh applies them."""
    with tempfile.TemporaryDirectory() as directory:
        copy = Path(directory) / LC_INTENTS_PATH
        copy.parent.mkdir(parents=True)
        copy.write_text(read(LC_INTENTS), encoding="utf-8")
        for patch in sorted(LC_PATCHES.glob("*.patch")):
            part = file_part(patch.read_text(encoding="utf-8"), LC_INTENTS_PATH)
            if part:
                subprocess.run(["patch", "-s", "-N", "-t", "-p1", "-d", directory], input=part.encode("utf-8"),
                               check=True)
        return copy.read_text(encoding="utf-8")


def braced(text: str, start: int) -> str:
    """From the first brace at or after START to the one that closes it."""
    first = text.index("{", start)
    depth = 0
    for index in range(first, len(text)):
        if text[index] == "{":
            depth += 1
        elif text[index] == "}":
            depth -= 1
            if depth == 0:
                return text[first:index + 1]
    raise AssertionError("unbalanced braces")


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

    def test_refresh_all_apps_waits_for_localdevvpns_tunnel(self):
        # The automation of Shortcuts runs Enable LocalDevVPN just before
        # Refresh All Apps: that action returns before the tunnel is up, and
        # SideStore reaches the iPhone through it as it starts. Up to 0.12.1,
        # the player had to leave LocalDevVPN connected all day.
        lc = patched_lc_intents()
        action = lc.find("struct RefreshAllAppsIntent")
        self.assertGreaterEqual(action, 0, "RefreshAllAppsIntent is gone from SideStore.swift")
        perform = braced(lc, lc.index("func perform()", action))
        wait = perform.find("await CartoucheTunnelWait.waitForLocalDevVPN()")
        self.assertGreaterEqual(wait, 0, "Refresh All Apps does not wait for LocalDevVPN")
        self.assertLess(wait, perform.index("performIntentRefresh("), "it waits before SideStore starts")
        # Renew now goes through performIntentRefresh too (CartoucheRefresh),
        # once the launcher has had LocalDevVPN connect: it waits no more.
        shared = braced(lc, lc.index("func performIntentRefresh("))
        self.assertNotIn("CartoucheTunnelWait", shared)
        self.assertNotIn("CartoucheTunnelWait", read(BRIDGE))

    def test_refresh_all_apps_reads_the_tunnel_as_the_launcher_does(self):
        # SideStoreSupport cannot import the launcher: CartoucheTunnelWait
        # reads utun<n> in 10.7.0.0/16 on its own, as CartoucheVPN does.
        rule = re.compile(r'\$0\.name\.lowercased\(\)\.hasPrefix\("utun"\) && \$0\.address\.hasPrefix\("([^"]+)"\)')
        launcher = rule.search(read(LAUNCHER_VPN))
        self.assertIsNotNone(launcher, "CartoucheVPN.hasTunnel changed: change CartoucheTunnelWait with it")
        wait = re.search(r'name\.lowercased\(\)\.hasPrefix\("utun"\) && text\.hasPrefix\("([^"]+)"\)', read(TUNNEL_WAIT))
        self.assertIsNotNone(wait, "CartoucheTunnelWait no longer reads utun<n>")
        self.assertEqual(wait.group(1), launcher.group(1))
        for check in ("IFF_UP", "AF_INET", "NI_NUMERICHOST"):
            self.assertIn(check, read(TUNNEL_WAIT))


if __name__ == "__main__":
    unittest.main()
