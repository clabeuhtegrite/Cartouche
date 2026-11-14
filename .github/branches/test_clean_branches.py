"""Tests of clean_branches.py and of the workflow that runs it."""

from __future__ import annotations

import io
import json
import sys
import tempfile
import unittest
from contextlib import redirect_stderr, redirect_stdout
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import clean_branches  # noqa: E402
from clean_branches import Pull, plan  # noqa: E402

ROOT = Path(__file__).resolve().parents[2]


def sha(n: int) -> str:
    return f"{n:040x}"


def verdicts(branches: dict[str, str], pulls: list[Pull], versions=((0, 9, 0),), default: str = "main") -> dict:
    return {verdict.branch: verdict for verdict in plan(branches, pulls, list(versions), default)}


class PlanTests(unittest.TestCase):
    def test_keeps_the_default_branch_and_the_branches_something_reads(self):
        found = verdicts({"main": sha(1), "gh-pages": sha(2), "live-covers": sha(3), "nxnative-measurements": sha(4)},
                         [Pull(1, False, True, "main", sha(1)),
                          # A pull request someone opened from the page's branch, and closed.
                          Pull(2, False, False, "nxnative-measurements", sha(4))])
        self.assertEqual({branch: verdict.delete for branch, verdict in found.items()},
                         {"main": False, "gh-pages": False, "live-covers": False, "nxnative-measurements": False})
        self.assertEqual(found["main"].reason, "the default branch")
        self.assertIn("covers", found["live-covers"].reason)
        self.assertIn("nxnative", found["nxnative-measurements"].reason)

    def test_deletes_the_head_of_a_merged_pull_request_still_at_its_commit(self):
        found = verdicts({"feature": sha(5)}, [Pull(12, False, True, "feature", sha(5))])
        self.assertTrue(found["feature"].delete)
        self.assertEqual(found["feature"].reason, "merged in #12")

    def test_deletes_the_head_of_a_pull_request_closed_without_being_merged(self):
        found = verdicts({"idea": sha(5)}, [Pull(13, False, False, "idea", sha(5))])
        self.assertTrue(found["idea"].delete)
        self.assertEqual(found["idea"].reason, "#13, closed without being merged")

    def test_keeps_a_branch_pushed_to_since_its_pull_request_ended(self):
        found = verdicts({"thread": sha(6)}, [Pull(12, False, True, "thread", sha(5))])
        self.assertFalse(found["thread"].delete)
        self.assertEqual(found["thread"].reason, "commits since #12 ended")

    def test_keeps_the_head_of_an_open_pull_request(self):
        # A thread's branch, merged once and opened again from the same name.
        found = verdicts({"thread": sha(5)},
                         [Pull(12, False, True, "thread", sha(5)), Pull(20, True, False, "thread", sha(5))])
        self.assertFalse(found["thread"].delete)
        self.assertEqual(found["thread"].reason, "the head of #20, open")

    def test_names_the_last_pull_request_of_a_branch_used_again(self):
        found = verdicts({"thread": sha(7)},
                         [Pull(3, False, True, "thread", sha(5)), Pull(9, False, True, "thread", sha(7))])
        self.assertEqual(found["thread"].reason, "merged in #9")

    def test_keeps_a_branch_no_pull_request_has(self):
        found = verdicts({"draft": sha(8)}, [])
        self.assertFalse(found["draft"].delete)
        self.assertEqual(found["draft"].reason, "commits that no pull request has")

    def test_deletes_a_release_branch_once_main_lists_its_version_or_a_later_one(self):
        found = verdicts({"release/v0.5.0": sha(1), "release/v0.9.0": sha(2), "release/v0.10.0": sha(3)}, [],
                         versions=[(0, 9, 0), (0, 5, 1)])
        self.assertTrue(found["release/v0.5.0"].delete)
        self.assertTrue(found["release/v0.9.0"].delete)
        self.assertEqual(found["release/v0.9.0"].reason, "main's SideStore source lists 0.9.0")
        # As numbers: 0.10.0 comes after 0.9.0, and main does not list it yet.
        self.assertFalse(found["release/v0.10.0"].delete)

    def test_keeps_every_release_branch_when_main_lists_no_version(self):
        found = verdicts({"release/v0.1.0": sha(1)}, [], versions=[])
        self.assertFalse(found["release/v0.1.0"].delete)

    def test_a_branch_made_for_another_follows_it(self):
        branches = {
            "main": sha(1),
            "merged": sha(2),
            "open": sha(3),
            "launcher-screens/merged": sha(4),
            "launcher-screens/open": sha(5),
            "builder-screens/gone": sha(6),
            "catalog-covers/main": sha(7),
            "installer-captures/merged": sha(8),
        }
        pulls = [Pull(1, False, True, "merged", sha(2)), Pull(2, True, False, "open", sha(3))]
        found = verdicts(branches, pulls)
        self.assertEqual(found["launcher-screens/merged"].reason, "made for merged, which goes")
        self.assertTrue(found["launcher-screens/merged"].delete)
        self.assertEqual(found["launcher-screens/open"].reason, "made for open, which stays")
        self.assertFalse(found["launcher-screens/open"].delete)
        self.assertEqual(found["builder-screens/gone"].reason, "made for gone, which is gone")
        self.assertTrue(found["builder-screens/gone"].delete)
        self.assertFalse(found["catalog-covers/main"].delete)
        self.assertEqual(found["installer-captures/merged"].reason, "made for merged, which goes")
        self.assertTrue(found["installer-captures/merged"].delete)

    def test_a_pull_request_of_a_screens_branch_is_not_its_own(self):
        # A branch made for another goes or stays with it, whatever its own pull requests.
        found = verdicts({"launcher-screens/feature": sha(4), "feature": sha(2)},
                         [Pull(1, True, False, "feature", sha(2)), Pull(2, False, True, "launcher-screens/feature", sha(4))])
        self.assertFalse(found["launcher-screens/feature"].delete)

    def test_lists_the_branches_by_name(self):
        found = plan({"b": sha(1), "a": sha(2), "launcher-screens/b": sha(3)}, [], [], "main")
        self.assertEqual([verdict.branch for verdict in found], ["a", "b", "launcher-screens/b"])


class FileTests(unittest.TestCase):
    def setUp(self):
        self.folder = Path(tempfile.mkdtemp())

    def write(self, name: str, text: str) -> Path:
        path = self.folder / name
        path.write_text(text)
        return path

    def test_leaves_out_the_pull_requests_of_forks(self):
        pulls = self.write("pulls.jsonl", "\n".join(json.dumps(entry) for entry in [
            {"number": 1, "state": "closed", "merged": True, "ref": "a", "sha": sha(1), "repository": "Owner/Repo"},
            {"number": 2, "state": "open", "merged": False, "ref": "a", "sha": sha(1), "repository": "someone/Repo"},
            {"number": 3, "state": "closed", "merged": False, "ref": "b", "sha": sha(2), "repository": ""},
        ]) + "\n\n")
        self.assertEqual(clean_branches.read_pulls(pulls, "owner/repo"), [Pull(1, False, True, "a", sha(1))])

    def test_reads_the_versions_of_the_source(self):
        source = self.write("source.json", json.dumps({"apps": [
            {"versions": [{"version": "0.9.0"}, {"version": "0.10.0"}, {"version": "1.0"}, {}]},
        ]}))
        self.assertEqual(clean_branches.read_versions(source), [(0, 9, 0), (0, 10, 0)])

    def test_prints_the_branches_to_delete_and_writes_the_summary(self):
        branches = self.write("branches.jsonl", "\n".join(json.dumps(entry) for entry in [
            {"name": "main", "sha": sha(1)},
            {"name": "done", "sha": sha(2)},
            {"name": "release/v0.1.0", "sha": sha(3)},
            {"name": "launcher-screens/done", "sha": sha(4)},
            {"name": "wip|draft", "sha": sha(5)},
        ]))
        pulls = self.write("pulls.jsonl", json.dumps(
            {"number": 4, "state": "closed", "merged": True, "ref": "done", "sha": sha(2), "repository": "o/r"}))
        source = self.write("source.json", json.dumps({"apps": [{"versions": [{"version": "0.2.0"}]}]}))
        summary = self.write("summary.md", "")
        out, err = io.StringIO(), io.StringIO()
        with redirect_stdout(out), redirect_stderr(err):
            code = clean_branches.main(["clean_branches.py", str(branches), str(pulls), str(source),
                                        "--default", "main", "--repository", "o/r", "--summary", str(summary)])
        self.assertEqual(code, 0)
        self.assertEqual(out.getvalue().splitlines(),
                         [f"{sha(2)} done", f"{sha(4)} launcher-screens/done", f"{sha(3)} release/v0.1.0"])
        text = summary.read_text()
        self.assertIn("5 branches: 3 to delete if they are still at the commit below, 2 kept.", text)
        self.assertIn("| done | 0000000 | merged in #4 |", text)
        self.assertIn("| wip\\|draft | 0000000 | commits that no pull request has |", text)
        self.assertIn("keep   main: the default branch", err.getvalue())


class WorkflowTests(unittest.TestCase):
    def setUp(self):
        try:
            import yaml
        except ImportError:
            self.skipTest("PyYAML is not installed (the Workflow audit installs it)")
        self.workflow = yaml.safe_load((ROOT / ".github/workflows/branches.yml").read_text())

    def test_only_the_job_that_runs_nothing_from_the_repository_can_write(self):
        jobs = self.workflow["jobs"]
        self.assertEqual(self.workflow["permissions"], {"contents": "read"})
        writers = [name for name, job in jobs.items() if "write" in (job.get("permissions") or {}).values()]
        self.assertEqual(writers, ["delete"])
        steps = jobs["delete"]["steps"]
        self.assertFalse([step for step in steps if "uses" in step], "the delete job checks nothing out")
        self.assertIn("--force-with-lease=", steps[-1]["run"])

    def test_deletes_only_on_main(self):
        condition = self.workflow["jobs"]["delete"]["if"]
        self.assertIn("github.ref == 'refs/heads/main'", condition)
        self.assertIn("!inputs.dry-run", condition)

    def test_runs_this_script(self):
        steps = self.workflow["jobs"]["plan"]["steps"]
        self.assertTrue(any(".github/branches/clean_branches.py" in step.get("run", "") for step in steps))


if __name__ == "__main__":
    unittest.main()
