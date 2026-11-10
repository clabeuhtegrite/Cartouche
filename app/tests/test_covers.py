"""Checks that the covers Cartouche reads every day line up:

- app/scripts/package.sh writes the address the launcher reads
  (launcher/Sources/CartoucheCoverList.swift), and app/scripts/build.sh
  passes the one in app/config.env;
- that address is the file the Live covers workflow pushes, on the branch it
  pushes it to, in this repository.

Run from the repository root: python3 -m unittest discover -s app/tests -v
"""

import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
COVERS = ROOT / "launcher" / "Sources" / "CartoucheCoverList.swift"
PACKAGE = ROOT / "app" / "scripts" / "package.sh"
BUILD = ROOT / "app" / "scripts" / "build.sh"
CONFIG = ROOT / "app" / "config.env"
WORKFLOW = ROOT / ".github" / "workflows" / "live-covers.yml"


def setting(key: str) -> str:
    for line in CONFIG.read_text(encoding="utf-8").splitlines():
        if line.startswith(key + "="):
            return line.split("=", 1)[1].strip()
    raise AssertionError(f"{key} is missing from app/config.env")


def found(pattern: str, text: str, what: str) -> re.Match:
    match = re.search(pattern, text)
    if not match:
        raise AssertionError(f"{what} not found")
    return match


class CoversTest(unittest.TestCase):
    def test_the_app_carries_the_covers_address(self):
        key = found(r'forInfoDictionaryKey: "(CartoucheCovers\w*)"',
                    COVERS.read_text(encoding="utf-8"), "the covers' Info.plist key").group(1)
        self.assertIn(f"Add :{key} string $COVERS_URL", PACKAGE.read_text(encoding="utf-8"))
        self.assertIn('--covers-url "$CARTOUCHE_COVERS_URL"', BUILD.read_text(encoding="utf-8"))

    def test_the_address_is_the_file_the_workflow_keeps(self):
        workflow = WORKFLOW.read_text(encoding="utf-8")
        branch = found(r'"HEAD:refs/heads/([\w.-]+)"', workflow, "the branch the workflow pushes").group(1)
        self.assertIn("git add covers.json", workflow)
        # This repository, as the source the built-in SideStore reads names it.
        repository = found(r"^https://raw\.githubusercontent\.com/([\w.-]+/[\w.-]+)/",
                           setting("CARTOUCHE_SIDESTORE_SOURCE_URL"), "the repository of the source").group(1)
        self.assertEqual(setting("CARTOUCHE_COVERS_URL"),
                         f"https://raw.githubusercontent.com/{repository}/refs/heads/{branch}/covers.json")

    def test_only_mains_workflow_publishes(self):
        workflow = WORKFLOW.read_text(encoding="utf-8")
        self.assertIn("if: ${{ github.ref == 'refs/heads/main' }}", workflow)
        self.assertNotIn("pull_request", workflow)


if __name__ == "__main__":
    unittest.main()
