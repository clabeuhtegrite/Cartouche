"""Checks that the storage tests (launcher/StorageTests) build what the app
builds:

- the package's sources are links to the launcher's own files, and every
  storage file of the launcher but its views is among them, so that a new
  kind of storage runs against a real server too;
- it pins swift-nio-ssh, swift-nio and the packages they bring as the app does
  (app/patches/livecontainer/0007), and builds the app's own SMBClient
  (app/SMBClient).

Run from the repository root: python3 -m unittest discover -s app/tests -v
"""

import json
import os
import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
LAUNCHER = ROOT / "launcher" / "Sources"
PACKAGE = ROOT / "launcher" / "StorageTests"
SOURCES = PACKAGE / "Sources" / "CartoucheStorage"
PATCH = ROOT / "app" / "patches" / "livecontainer" / "0007-link-the-swift-nio-ssh-package.patch"
STUBS = "CartoucheStorageTestsStubs.swift"


def added_file(suffix: str) -> str:
    """The file the patch adds or changes at a path ending with SUFFIX: its
    added lines."""
    lines = []
    inside = False
    for line in PATCH.read_text(encoding="utf-8").splitlines():
        if line.startswith("+++ "):
            inside = line.endswith(suffix)
        elif line.startswith("diff --git") or line == "-- ":
            inside = False
        elif inside and line.startswith("+"):
            lines.append(line[1:])
    if not lines:
        raise AssertionError(f"{PATCH.name} adds no {suffix}")
    return "\n".join(lines)


def pins(resolved: dict) -> dict:
    return {pin["identity"]: (pin["location"], pin["state"]["revision"], pin["state"].get("version"))
            for pin in resolved["pins"]}


class StorageTestsPackage(unittest.TestCase):
    def test_pins_the_packages_the_app_pins(self):
        app = pins(json.loads(added_file("Package.resolved")))
        tests = pins(json.loads((PACKAGE / "Package.resolved").read_text(encoding="utf-8")))
        self.assertEqual(tests, app)

    def test_asks_for_the_versions_the_app_asks_for(self):
        project = added_file("project.pbxproj")
        manifest = (PACKAGE / "Package.swift").read_text(encoding="utf-8")
        for name in ("swift-nio-ssh", "swift-nio"):
            url = re.escape(f"https://github.com/apple/{name}.git")
            app = re.search(url + r'";\s*requirement = \{\s*kind = exactVersion;\s*version = ([0-9.]+);', project)
            tests = re.search(r'\.package\(url: "' + url + r'", exact: "([0-9.]+)"\)', manifest)
            self.assertIsNotNone(app, f"the app does not pin {name} to a version")
            self.assertIsNotNone(tests, f"Package.swift does not pin {name} to a version")
            self.assertEqual(tests.group(1), app.group(1), name)

    def test_builds_the_apps_smbclient(self):
        manifest = (PACKAGE / "Package.swift").read_text(encoding="utf-8")
        self.assertIn('.package(path: "../../app/SMBClient")', manifest)

    def test_links_the_launchers_own_files(self):
        files = sorted(SOURCES.glob("*.swift"))
        self.assertEqual([path.name for path in files if not path.is_symlink()], [STUBS])
        for link in (path for path in files if path.is_symlink()):
            target = link.resolve()
            self.assertTrue(target.is_file(), f"{link.name} links to {os.readlink(link)}, which is not there")
            self.assertEqual((target.parent, target.name), (LAUNCHER, link.name), link.name)

    def test_links_every_storage_file_but_the_views(self):
        linked = {path.name for path in SOURCES.glob("*.swift") if path.is_symlink()}
        for path in sorted(LAUNCHER.glob("CartoucheStorage*.swift")):
            if re.search(r"^import (SwiftUI|UIKit)$", path.read_text(encoding="utf-8"), re.MULTILINE):
                continue
            self.assertIn(path.name, linked, f"{path.name} is not in the storage tests")


if __name__ == "__main__":
    unittest.main()
