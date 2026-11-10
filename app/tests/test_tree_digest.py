"""Checks app/scripts/tree_digest.py, whose digest of the prepared SideStore
sources names the built-in SideStore that CI keeps between builds
(app/scripts/build.sh, .github/workflows/app.yml): the same sources give the
same digest however and whenever they were copied, and any change that could
change the build gives another one.

Run from the repository root: python3 -m unittest discover -s app/tests -v
"""

import importlib.util
import os
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "app" / "scripts" / "tree_digest.py"
BUILD = ROOT / "app" / "scripts" / "build.sh"

spec = importlib.util.spec_from_file_location("tree_digest", SCRIPT)
tree_digest = importlib.util.module_from_spec(spec)
spec.loader.exec_module(tree_digest)


def make_tree(root: Path) -> None:
    (root / "AltStore" / "Resources").mkdir(parents=True)
    (root / "AltStore" / "Resources" / "Info.plist").write_text("<plist/>\n")
    (root / "Makefile").write_text("build:\n\txcodebuild archive\n")
    (root / "scripts").mkdir()
    (root / "scripts" / "run.sh").write_text("#!/bin/sh\necho run\n")
    (root / "scripts" / "run.sh").chmod(0o755)
    (root / "empty").mkdir()
    os.symlink("AltStore/Resources", root / "Resources")


class TreeDigest(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, self.tmp)
        self.tree = self.tmp / "tree"
        self.tree.mkdir()
        make_tree(self.tree)
        self.digest = tree_digest.digest(self.tree)

    def copy(self) -> Path:
        copy = self.tmp / "copy"
        shutil.copytree(self.tree, copy, symlinks=True)
        return copy

    def test_a_copy_elsewhere_and_later_gives_the_same_digest(self):
        copy = self.copy()
        for path in copy.rglob("*"):
            os.utime(path, (0, 0), follow_symlinks=False)
        (copy / "Makefile").chmod(0o600)
        self.assertEqual(tree_digest.digest(copy), self.digest)

    def test_the_same_files_written_in_another_order_give_the_same_digest(self):
        other = self.tmp / "other"
        other.mkdir()
        os.symlink("AltStore/Resources", other / "Resources")
        (other / "empty").mkdir()
        (other / "scripts").mkdir()
        (other / "scripts" / "run.sh").write_text("#!/bin/sh\necho run\n")
        (other / "scripts" / "run.sh").chmod(0o700)
        (other / "Makefile").write_text("build:\n\txcodebuild archive\n")
        (other / "AltStore" / "Resources").mkdir(parents=True)
        (other / "AltStore" / "Resources" / "Info.plist").write_text("<plist/>\n")
        self.assertEqual(tree_digest.digest(other), self.digest)

    def test_a_changed_file_changes_it(self):
        copy = self.copy()
        (copy / "AltStore" / "Resources" / "Info.plist").write_text("<plist></plist>\n")
        self.assertNotEqual(tree_digest.digest(copy), self.digest)

    def test_a_renamed_file_changes_it(self):
        copy = self.copy()
        (copy / "Makefile").rename(copy / "GNUmakefile")
        self.assertNotEqual(tree_digest.digest(copy), self.digest)

    def test_a_file_that_becomes_a_program_changes_it(self):
        copy = self.copy()
        (copy / "Makefile").chmod(0o755)
        self.assertNotEqual(tree_digest.digest(copy), self.digest)

    def test_a_link_that_points_elsewhere_changes_it(self):
        copy = self.copy()
        (copy / "Resources").unlink()
        os.symlink("AltStore", copy / "Resources")
        self.assertNotEqual(tree_digest.digest(copy), self.digest)

    def test_a_new_empty_folder_changes_it(self):
        copy = self.copy()
        (copy / "AltStore" / "Icons.xcassets").mkdir()
        self.assertNotEqual(tree_digest.digest(copy), self.digest)

    def test_names_cannot_run_into_each_other(self):
        first = self.tmp / "first"
        (first / "a").mkdir(parents=True)
        (first / "a" / "b").write_text("c")
        second = self.tmp / "second"
        second.mkdir()
        (second / "a b").write_text("c")
        self.assertNotEqual(tree_digest.digest(first), tree_digest.digest(second))

    def test_prints_the_digest(self):
        said = subprocess.run([sys.executable, str(SCRIPT), str(self.tree)], capture_output=True, text=True, check=True)
        self.assertEqual(said.stdout.strip(), self.digest)


class SideStoreKey(unittest.TestCase):
    def test_build_names_the_built_in_sidestore_after_its_prepared_sources(self):
        script = BUILD.read_text(encoding="utf-8")
        self.assertIn('tree_digest.py" "$WORK/src/SideStore"', script)
        # The recipe, Xcode and ldid build it too.
        for part in ('shasum -a 256 < "$HERE/build.sh"', "xcodebuild -version", 'shasum -a 256 < "$(command -v ldid)"'):
            self.assertIn(part, script)


if __name__ == "__main__":
    unittest.main()
