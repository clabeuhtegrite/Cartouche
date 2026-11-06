"""Checks Cartouche's version, which the built-in SideStore compares with its
source to offer an update:

- app/config.env gives it as major.minor.patch, the form SideStore compares;
- it is never lower than a version the source already lists, or SideStore
  would offer that release over the build;
- the build writes it into the app in place of LiveContainer's version.

Run from the repository root: python3 -m unittest discover -s app/tests -v
"""

import json
import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
CONFIG = ROOT / "app" / "config.env"
SOURCE = ROOT / "app" / "sidestore-source.json"
BUILD = ROOT / "app" / "scripts" / "build.sh"
PACKAGE = ROOT / "app" / "scripts" / "package.sh"

VERSION = re.compile(r"(\d+)\.(\d+)\.(\d+)")


def setting(key: str) -> str:
    for line in CONFIG.read_text(encoding="utf-8").splitlines():
        name, _, value = line.partition("=")
        if name.strip() == key and not line.lstrip().startswith("#"):
            return value.strip()
    raise AssertionError(f"{key} is missing from app/config.env")


def parse(version: str) -> tuple[int, int, int]:
    match = VERSION.fullmatch(version)
    if not match:
        raise AssertionError(f"not major.minor.patch: {version!r}")
    return tuple(int(part) for part in match.groups())


class VersionTest(unittest.TestCase):
    def test_the_version_is_major_minor_patch(self):
        parse(setting("CARTOUCHE_VERSION"))

    def test_the_version_is_not_lower_than_a_release_in_the_source(self):
        version = parse(setting("CARTOUCHE_VERSION"))
        source = json.loads(SOURCE.read_text(encoding="utf-8"))
        for app in source["apps"]:
            for release in app.get("versions", []):
                with self.subTest(release=release["version"]):
                    self.assertGreaterEqual(version, parse(release["version"]))

    def test_the_build_writes_the_version_into_the_app(self):
        self.assertIn('--version "$CARTOUCHE_VERSION"', BUILD.read_text(encoding="utf-8"))
        package = PACKAGE.read_text(encoding="utf-8")
        self.assertIn('Set :CFBundleShortVersionString $VERSION', package)
        self.assertIn('Set :CFBundleVersion $VERSION', package)


if __name__ == "__main__":
    unittest.main()
