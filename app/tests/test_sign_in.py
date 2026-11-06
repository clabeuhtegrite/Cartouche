"""Checks that Cartouche's Apple ID sign-in lines up with the built-in
SideStore's patch (app/patches/sidestore/0011):

- the launcher finds CartoucheSignIn (launcher/SideStoreSupport) by the
  Objective-C names it declares;
- CartoucheSignIn runs the action that the patch adds, by its type's mangled
  name in SideStore's module, and Shortcuts does not list that action;
- both sides name the same keychain items, and read the fields the other
  writes.

Run from the repository root: python3 -m unittest discover -s app/tests -v
"""

import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
ACCOUNT = ROOT / "launcher" / "Sources" / "CartoucheAccount.swift"
MESSAGE = ROOT / "launcher" / "Sources" / "CartoucheSignInMessage.swift"
BRIDGE = ROOT / "launcher" / "SideStoreSupport" / "CartoucheSignIn.swift"
PATCHES = ROOT / "app" / "patches" / "sidestore"
MODULE = "SideStore"


def added_by_patch() -> str:
    """The lines patch 0011 adds to SideStore."""
    patches = sorted(PATCHES.glob("*-let-cartouche-sign-the-built-in-sidestore-in.patch"))
    if len(patches) != 1:
        raise AssertionError(f"expected one sign-in patch in {PATCHES.relative_to(ROOT)}, found {len(patches)}")
    lines = patches[0].read_text(encoding="utf-8").splitlines()
    return "\n".join(line[1:] for line in lines if line.startswith("+") and not line.startswith("+++"))


def found(pattern: str, text: str, what: str, flags: int = 0) -> re.Match:
    match = re.search(pattern, text, flags)
    if not match:
        raise AssertionError(f"{what} not found")
    return match


def accounts(text: str) -> dict:
    return dict(re.findall(r'static let (\w+Account) = "([^"]+)"', text))


class SignInTest(unittest.TestCase):
    def test_the_launcher_finds_the_bridge_by_its_objective_c_names(self):
        launcher = ACCOUNT.read_text(encoding="utf-8")
        bridge = BRIDGE.read_text(encoding="utf-8")
        class_name = found(r'NSClassFromString\("([^"]+)"\)', launcher, "the bridge's class").group(1)
        selector = found(r'NSSelectorFromString\("(signIn[^"]+)"\)', launcher, "the bridge's selector").group(1)
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

    def test_both_sides_name_the_same_keychain_items(self):
        ours = accounts(MESSAGE.read_text(encoding="utf-8"))
        theirs = accounts(added_by_patch())
        self.assertEqual(set(ours), {"credentialsAccount", "requestAccount", "responseAccount"})
        self.assertEqual(ours, theirs)
        # SideStore's keychain service is Cartouche's bundle identifier, as
        # for the items Cartouche already reads.
        self.assertIn("Bundle.Info.appbundleIdentifier", added_by_patch())

    def test_both_sides_read_what_the_other_writes(self):
        added = added_by_patch()
        message = MESSAGE.read_text(encoding="utf-8")
        # The credentials: Cartouche writes them, SideStore decodes them.
        for field in ("appleID", "password"):
            self.assertIn(f'"{field}":', message)
            self.assertRegex(added, rf"var {field}: String")
        # The request: SideStore writes it, Cartouche reads it.
        for field in ("id", "mode", "phone", "canTextMessage", "error"):
            self.assertRegex(added, rf'message\["{field}"\]|"{field}":')
            self.assertIn(f'fields["{field}"]', message)
        for mode in ("trustedDevice", "sms", "voice"):
            self.assertIn(f"case {mode}", message)
        # The response: Cartouche writes it, SideStore reads it.
        for field in ("id", "code", "action"):
            self.assertIn(f'response["{field}"]', added)
        for action in ("sms", "trustedDevice", "cancel"):
            self.assertIn(f'fields["action"] = "{action}"', message)
        for action in ("sms", "trustedDevice"):
            self.assertIn(f'case "{action}":', added)


if __name__ == "__main__":
    unittest.main()
