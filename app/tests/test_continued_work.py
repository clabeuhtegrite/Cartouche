"""Checks that the installs and copies iOS goes on with once the player
leaves Cartouche (launcher/Sources/CartoucheContinuedWork.swift) can run:
iOS runs such a step only when the app's Info.plist lists its identifier
under the bundle identifier the app runs as, which signing changes.

- app/scripts/package.sh lists "<bundle identifier>.<context>.*" under
  BGTaskSchedulerPermittedIdentifiers, with the context the launcher names
  its steps with, and the launcher looks for that very entry;
- the built-in SideStore moves the entries of that list under the bundle
  identifier it signs Cartouche with (ResignAppOperation), and the
  Cartouche Installer builds with the isideload whose own move was read;
- LiveContainer's unpacking of an IPA stops once its progress is cancelled
  (app/patches/livecontainer/0009), and the launcher cancels it when the
  player stops the install from outside Cartouche.

Needs the SideStore submodule.

Run from the repository root: python3 -m unittest discover -s app/tests -v
"""

import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SOURCES = ROOT / "launcher" / "Sources"
CONTINUED = SOURCES / "CartoucheContinuedWork.swift"
ACTIONS = SOURCES / "CartoucheGameActions.swift"
PACKAGE = ROOT / "app" / "scripts" / "package.sh"
RESIGN = ROOT / "app" / "SideStore" / "SideStore" / "Core" / "Operations" / "PipelineOperations" / "ResignAppOperation.swift"
CARGO = ROOT / "installer" / "src-tauri" / "Cargo.toml"
PATCHES = ROOT / "app" / "patches" / "livecontainer"
KEY = "BGTaskSchedulerPermittedIdentifiers"
# The isideload whose set_bundle_identifier (src/sideload/bundle.rs) was read:
# it moves the entries of BGTaskSchedulerPermittedIdentifiers under the
# bundle identifier it signs the app with, as it moves the app's own.
CHECKED_ISIDELOAD = "0.5.2"


class ContinuedWorkTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.swift = CONTINUED.read_text(encoding="utf-8")
        context = re.search(r'static let context = "([^"]+)"', cls.swift)
        if not context:
            raise AssertionError(f"{CONTINUED.name} names no context for its identifiers")
        cls.context = context.group(1)

    def test_the_info_plist_lists_the_launchers_identifiers(self):
        script = PACKAGE.read_text(encoding="utf-8")
        self.assertIn(f'$PB -c "Add :{KEY} array" "$APP/Info.plist"', script)
        added = re.findall(r'\$PB -c "Add :' + KEY + r': string ([^"]+)" "\$APP/Info.plist"', script)
        self.assertEqual(added, [f"$BUNDLE_ID.{self.context}.*"])
        # The launcher asks for a step only under that entry, moved under the
        # bundle identifier it runs as: iOS would take the request, and never
        # run it, for an identifier the list does not cover.
        self.assertIn(r'permitted.contains("\(bundleID).\(context).*") ? "\(bundleID).\(context)." : nil', self.swift)

    def test_the_built_in_sidestore_moves_them_under_the_signed_identifier(self):
        source = RESIGN.read_text(encoding="utf-8")
        self.assertIn(f'infoDictionary["{KEY}"] = taskIDs', source)
        rewrite = re.search(r"func rewrittenTaskSchedulerIdentifiers\(.*?\n    \}\n", source, re.S)
        self.assertIsNotNone(rewrite, "ResignAppOperation no longer moves the identifiers")
        self.assertIn('taskID.hasPrefix(originalBundleID + ".")', rewrite.group(0))
        self.assertIn("newBundleID + taskID.dropFirst(originalBundleID.count)", rewrite.group(0))

    def test_the_installer_builds_with_the_isideload_that_was_read(self):
        cargo = re.search(r'^isideload\s*=\s*\{[^}]*version\s*=\s*"([^"]+)"', CARGO.read_text(encoding="utf-8"), re.M)
        self.assertIsNotNone(cargo, f"{CARGO.relative_to(ROOT)} no longer names isideload")
        self.assertEqual(cargo.group(1), CHECKED_ISIDELOAD,
                         "the Installer builds with another isideload: check that it still moves "
                         f"{KEY} under the bundle identifier it signs with, then name it here")

    def test_unpacking_stops_once_its_install_is_cancelled(self):
        patches = sorted(PATCHES.glob("*-stop-unpacking-an-ipa-once-its-install-is-cancelled.patch"))
        self.assertEqual(len(patches), 1, f"expected one unpacking patch in {PATCHES.relative_to(ROOT)}")
        text = patches[0].read_text(encoding="utf-8")
        self.assertIn("+++ b/LiveContainerSwiftUI/Utilities/unarchive.m", text)
        added = [line[1:] for line in text.splitlines() if line.startswith("+") and not line.startswith("+++")]
        # Between two blocks, between two files, and as it returns.
        self.assertEqual(sum("progress.cancelled" in line for line in added), 3)
        actions = ACTIONS.read_text(encoding="utf-8")
        self.assertRegex(actions, r"withTaskCancellationHandler \{\s*await Self\.unpack\(url\.path, into: folder\.path, progress\)"
                                  r"\s*\} onCancel: \{\s*progress\.cancel\(\)\s*\}")


if __name__ == "__main__":
    unittest.main()
