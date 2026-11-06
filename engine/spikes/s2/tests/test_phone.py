"""Checks cartouche_s2.phone, the rewrite that Cartouche runs on the iPhone:
the Mac's list of files, the comparison with it, and, with nxnative and
Capstone, finding the game by its main module and a whole job on the
synthetic modules of make_test_nso.py.

The last tests need NXNATIVE, nxnative at the pinned commit
(fetch_nxnative.sh), and the capstone and lz4 packages; they are skipped
without them. Run from the repository root:
NXNATIVE=build/nxnative python3 -m unittest discover -s engine/spikes/s2/tests -v
"""

import hashlib
import importlib.util
import json
import os
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

HERE = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(HERE))
from cartouche_s2 import phone  # noqa: E402

NXNATIVE = Path(os.environ["NXNATIVE"]) if os.environ.get("NXNATIVE") else None
HAVE_PACKAGES = all(importlib.util.find_spec(name) for name in ("capstone", "lz4"))


def make_modules(folder):
    spec = importlib.util.spec_from_file_location("make_test_nso", HERE / "make_test_nso.py")
    maker = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(maker)
    maker.main(["make_test_nso.py", str(folder)])
    return maker


class ReferenceTest(unittest.TestCase):
    def test_lists_of_shasum_and_sha256sum_count_each_file_by_its_name(self):
        folder = Path(tempfile.mkdtemp(prefix="s2-phone-test-"))
        listing = folder / "mac.sha256"
        a, b, c = "a" * 64, "B" * 64, "c" * 64
        listing.write_text(f"{a}  main.patched.bin\n{b} *patched_v0/sdk.fixups.tsv\n"
                           f"not a line\n{c}  build_src.sha256\n")
        self.assertEqual(phone.read_reference(listing),
                         {"main.patched.bin": a, "sdk.fixups.tsv": "b" * 64, "build_src.sha256": c})

    def test_each_file_is_the_same_different_or_absent_on_the_mac(self):
        files = [("a.bin", "1" * 64, 3), ("b.tsv", "2" * 64, 4), ("c.tsv", "3" * 64, 5)]
        reference = {"a.bin": "1" * 64, "b.tsv": "f" * 64, "d.tsv": "4" * 64, "mac.sha256": "5" * 64}
        rows, only = phone.compare(files, reference)
        self.assertEqual([row["mac"] for row in rows], ["same", "different", "absent"])
        self.assertEqual(only, ["d.tsv"])

    def test_without_a_list_nothing_is_compared(self):
        rows, only = phone.compare([("a.bin", "1" * 64, 3)], None)
        self.assertEqual((rows[0]["mac"], only), (None, []))


@unittest.skipUnless(NXNATIVE and HAVE_PACKAGES, "needs NXNATIVE, capstone and lz4")
class JobTest(unittest.TestCase):
    def setUp(self):
        self.folder = Path(tempfile.mkdtemp(prefix="s2-phone-test-"))
        self.modules = self.folder / "modules"
        self.maker = make_modules(self.modules)
        self.tools = NXNATIVE / "dm" / "tools"

    def build_id(self, name):
        return hashlib.sha256(f"Cartouche spike S2 {name}".encode()).hexdigest()[:32]

    def test_modules_are_named_as_in_exefs_or_with_nso(self):
        (self.modules / "main.nso").rename(self.modules / "main")
        (self.modules / "notes.txt").write_text("not a module")
        self.assertEqual(sorted(phone.module_files(self.modules)), ["main", "sdk", "subsdk0"])
        self.assertEqual(phone.build_id(self.modules / "main"), self.build_id("main"))

    def test_a_game_without_a_profile_has_every_module_rewritten_in_load_order(self):
        profile, modules = phone.identify(self.tools, self.modules)
        self.assertIsNone(profile)
        self.assertEqual([name for name, _ in modules], ["main", "subsdk0", "sdk"])

    def test_the_profile_that_registers_the_main_build_names_the_modules(self):
        games = self.folder / "games" / "0100000000005200"
        games.mkdir(parents=True)
        (games / "game.tsv").write_text(
            "title_id\t0100000000005200\nname\tSpike S2\n"
            f"build\tv0\tv0\tmain={self.build_id('main')}\tsdk={self.build_id('sdk')}\n"
            "modules\tmain sdk\n")
        with mock.patch.dict(os.environ, {"DM_GAMES_DIR": str(games.parent)}):
            profile, modules = phone.identify(self.tools, self.modules)
        self.assertEqual((profile.id, profile.get("name")), ("0100000000005200", "Spike S2"))
        self.assertEqual([name for name, _ in modules], ["main", "sdk"])

    def test_a_job_rewrites_every_module_and_compares_with_the_mac(self):
        mac = self.folder / "mac.sha256"
        first = phone.run_job({"tools": str(self.tools), "modules": str(self.modules), "reference": None})
        self.assertEqual(first["state"], "done", first.get("error"))
        listing = [f"{row['sha256']}  patched_v0/{row['name']}" for row in first["files"]]
        listing[0] = "0" * 64 + listing[0][64:]            # one file differs
        listing.append("1" * 64 + "  nro.tsv")              # one only the Mac wrote
        mac.write_text("\n".join(listing[1:-2] + listing[:1] + listing[-1:]) + "\n")   # and one is missing

        before_env, before_streams = dict(os.environ), (sys.stdout, sys.stderr)
        work = self.folder / "work"
        status = phone.run_job({"tools": str(self.tools), "modules": str(self.modules), "reference": str(mac),
                                "work": str(work), "env": {"S2_JOB": "1"}})
        self.assertEqual(status["state"], "done", status.get("error"))
        self.assertEqual(dict(os.environ), before_env)
        self.assertEqual((sys.stdout, sys.stderr), before_streams)
        self.assertEqual([module["state"] for module in status["modules"]], ["done"] * 3)
        self.assertEqual(status["summary"], {"files": len(first["files"]), "same": len(first["files"]) - 2,
                                             "different": 1, "absent": 1, "only_on_mac": 1})
        self.assertEqual(status["only_on_mac"], ["nro.tsv"])
        self.assertEqual([row["sha256"] for row in status["files"]], [row["sha256"] for row in first["files"]])
        self.assertEqual(json.loads((work / "status.json").read_text())["state"], "done")
        self.assertEqual(json.loads((work / "result.json").read_text())["summary"], status["summary"])
        own = (work / "iphone.sha256").read_text().splitlines()
        self.assertEqual(own, [f"{row['sha256']}  {row['name']}" for row in status["files"]])
        self.assertIn("== sdk: patch_nso.py sdk.nso", (work / "rewrite.log").read_text())

    def test_a_job_file_as_cartouche_writes_it(self):
        # CartoucheLab.swift: no reference without the Mac's list, and no out.
        work = self.folder / "run"
        work.mkdir()
        job = work / "job.json"
        job.write_text(json.dumps({"env": {"S2_JOB": "1"}, "modules": str(self.modules),
                                   "tools": str(self.tools), "work": str(work)}, indent=2, sort_keys=True))
        status = phone.run_job(str(job))
        self.assertEqual(status["state"], "done", status.get("error"))
        self.assertEqual(status["out"], str(work / "out"))
        self.assertEqual(status["summary"], {"files": len(status["files"])})
        self.assertEqual({row["mac"] for row in status["files"]}, {None})
        self.assertNotIn("S2_JOB", os.environ)

    def test_a_failed_job_says_why_and_keeps_the_log(self):
        status = phone.run_job({"tools": str(self.tools), "modules": str(self.folder), "reference": None})
        self.assertEqual(status["state"], "failed")
        self.assertIn("no main module", status["error"])
        self.assertIn("ValueError", (Path(status["work"]) / "rewrite.log").read_text())


if __name__ == "__main__":
    unittest.main()
