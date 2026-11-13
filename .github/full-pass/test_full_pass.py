"""Tests of the Full test pass: its wiring, its verdict, and how releases wait for it."""

from __future__ import annotations

import copy
import io
import sys
import tempfile
import unittest
from contextlib import redirect_stdout
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import wait_for_pass  # noqa: E402
from wait_for_pass import Run, wait  # noqa: E402

ROOT = Path(__file__).resolve().parents[2]

try:
    import yaml
except ImportError:  # The Workflow audit installs it.
    yaml = None

needs_yaml = unittest.skipIf(yaml is None, "PyYAML is not installed (the Workflow audit installs it)")

FULL = {"full": {"description": "Run every job", "type": "boolean", "default": False}}


def callable_workflow(jobs: dict, **triggers) -> dict:
    on = {"pull_request": None, **triggers, "workflow_call": {"inputs": copy.deepcopy(FULL)}}
    return {"name": "W", "on": on, "permissions": {"contents": "read"}, "jobs": jobs}


def repository() -> dict[str, dict]:
    """A small repository whose pass is wired right."""
    return {
        "full-pass.yml": {
            "name": "Full test pass",
            "on": {"workflow_dispatch": None},
            "permissions": {"contents": "read"},
            "jobs": {
                "app": {"name": "App", "uses": "./.github/workflows/app.yml", "with": {"full": True}},
                "site": {"name": "Showcase site", "uses": "./.github/workflows/site.yml",
                         "permissions": {"contents": "write"}, "with": {"full": True}},
                "verdict": {"name": "Every test passed", "needs": ["app", "site"], "if": "${{ always() }}",
                            "runs-on": "ubuntu-latest",
                            "steps": [{"run": "python3 .github/full-pass/verdict.py --run-id 1"}]},
            },
        },
        "app.yml": callable_workflow({
            "changes": {"name": "Files", "runs-on": "ubuntu-latest", "steps": [{"run": "true"}]},
            "build": {"name": "Build Cartouche.ipa", "needs": "changes", "runs-on": "xcode-27",
                      "steps": [{"run": "build.sh"},
                                {"uses": "actions/upload-artifact@x", "with": {"name": "ipa"}}]},
        }),
        "site.yml": {
            "name": "Showcase site",
            "on": {"push": {"branches": ["main"]}, "workflow_call": {"inputs": copy.deepcopy(FULL)}},
            "permissions": {"contents": "read"},
            "jobs": {
                "page": {"name": "Check the page", "runs-on": "ubuntu-latest", "steps": [{"run": "tests"}]},
                "publish": {"name": "Publish it", "needs": "page", "if": "${{ !inputs.full }}",
                            "permissions": {"contents": "write"}, "runs-on": "ubuntu-latest",
                            "steps": [{"run": "git push"}]},
            },
        },
        # Runs on pull requests, tests nothing: not called.
        "covers.yml": {"name": "Covers", "on": {"pull_request": None}, "jobs": {"covers": {"steps": [{"run": "x"}]}}},
        "release.yml": {
            "name": "Release",
            "on": {"workflow_dispatch": None},
            "jobs": {
                "build": {"steps": [{"run": "build.sh"}]},
                "tests": {"steps": [{"run": "python3 .github/full-pass/wait_for_pass.py --sha x --ref y --start"}]},
                "guard": {"needs": "build", "steps": [{"run": "guard"}]},
                "publish": {"needs": ["guard", "tests"], "steps": [{"run": "gh release create v1"}]},
            },
        },
    }


@needs_yaml
class WiringTests(unittest.TestCase):
    def problems(self, workflows: dict[str, dict]) -> list[str]:
        import wiring

        with tempfile.TemporaryDirectory() as tmp:
            folder = Path(tmp, ".github/workflows")
            folder.mkdir(parents=True)
            for name, workflow in workflows.items():
                (folder / name).write_text(yaml.safe_dump(workflow, sort_keys=False))
            return wiring.check(Path(tmp))

    def assertProblem(self, workflows: dict[str, dict], text: str):
        problems = self.problems(workflows)
        self.assertTrue(any(text in problem for problem in problems), f"{text!r} not in {problems}")

    def test_the_repository_is_wired_right(self):
        import wiring

        self.assertEqual(wiring.check(ROOT), [])

    def test_the_example_is_wired_right(self):
        self.assertEqual(self.problems(repository()), [])

    def test_a_workflow_of_pull_requests_left_out_of_the_pass(self):
        workflows = repository()
        workflows["storage.yml"] = callable_workflow({"storage": {"name": "Storage", "steps": [{"run": "swift test"}]}})
        self.assertProblem(workflows, "does not call storage.yml, which tests a part of the project")

    def test_a_workflow_that_tests_without_running_on_pull_requests(self):
        workflows = repository()
        del workflows["full-pass.yml"]["jobs"]["site"]
        workflows["full-pass.yml"]["jobs"]["verdict"]["needs"] = ["app"]
        self.assertProblem(workflows, "does not call site.yml")

    def test_a_workflow_that_tests_nothing_is_not_called(self):
        workflows = repository()
        workflows["full-pass.yml"]["jobs"]["covers"] = {"name": "Covers", "uses": "./.github/workflows/covers.yml",
                                                        "with": {"full": True}}
        self.assertProblem(workflows, "calls covers.yml, which tests nothing")

    def test_a_call_without_full(self):
        workflows = repository()
        del workflows["full-pass.yml"]["jobs"]["app"]["with"]
        self.assertProblem(workflows, "calls app.yml without `full: true`")

    def test_a_workflow_that_does_not_take_full(self):
        workflows = repository()
        workflows["app.yml"]["on"]["workflow_call"] = None
        problems = self.problems(workflows)
        self.assertTrue(any("app.yml does not take the boolean input `full`" in problem for problem in problems), problems)
        self.assertTrue(any("gives app.yml the input `full`" in problem for problem in problems), problems)

    def test_full_is_false_unless_given(self):
        workflows = repository()
        workflows["app.yml"]["on"]["workflow_call"]["inputs"]["full"]["default"] = True
        self.assertProblem(workflows, "app.yml does not take the boolean input `full`")

    def test_an_input_the_pass_does_not_give_would_skip_a_step(self):
        # A step taken only when the Actions tab asks for it reads as skipped in the pass.
        workflows = repository()
        workflows["app.yml"]["on"]["workflow_dispatch"] = {"inputs": {"screenshots": {"type": "boolean"}}}
        workflows["app.yml"]["jobs"]["build"]["steps"].append(
            {"name": "Screenshots", "if": "${{ github.event_name != 'workflow_dispatch' || inputs.screenshots }}",
             "run": "capture.sh"})
        self.assertProblem(workflows, "app.yml reads `inputs.screenshots`, which its workflow_call does not take")
        workflows["app.yml"]["on"]["workflow_call"]["inputs"]["screenshots"] = {"type": "boolean", "default": True}
        self.assertEqual(self.problems(workflows), [])

    def test_the_inputs_of_jobs_the_pass_skips_are_theirs(self):
        workflows = repository()
        workflows["site.yml"]["jobs"]["publish"]["if"] = "${{ inputs.publish && !inputs.full }}"
        self.assertEqual(self.problems(workflows), [])

    def test_a_secret_the_pass_does_not_pass(self):
        workflows = repository()
        workflows["app.yml"]["jobs"]["build"]["steps"].append(
            {"name": "Sign", "env": {"KEY": "${{ secrets.SIGNING_KEY }}", "TOKEN": "${{ secrets.GITHUB_TOKEN }}"},
             "run": "sign.sh"})
        self.assertEqual(self.problems(workflows),
                         ["app.yml reads `secrets.SIGNING_KEY`, which full-pass.yml does not pass it: in the pass it is empty"])
        workflows["full-pass.yml"]["jobs"]["app"]["secrets"] = {"SIGNING_KEY": "${{ secrets.SIGNING_KEY }}"}
        self.assertEqual(self.problems(workflows), [])
        workflows["full-pass.yml"]["jobs"]["app"]["secrets"] = "inherit"
        self.assertEqual(self.problems(workflows), [])

    def test_a_secret_the_pass_does_not_need(self):
        # The token that finds Ad's Mac: the pass's Mac jobs run on GitHub's.
        workflows = repository()
        workflows["app.yml"]["jobs"]["route"] = {"name": "Ad's Mac or GitHub", "runs-on": "ubuntu-latest",
                                                 "steps": [{"env": {"RUNNERS_TOKEN": "${{ secrets.MAC_RUNNER_TOKEN }}"},
                                                            "run": "python3 .github/mac/route.py"}]}
        self.assertEqual(self.problems(workflows), [])

    def test_the_secrets_of_jobs_the_pass_skips_are_theirs(self):
        workflows = repository()
        workflows["site.yml"]["jobs"]["publish"]["env"] = {"TOKEN": "${{ secrets.DEPLOY_TOKEN }}"}
        self.assertEqual(self.problems(workflows), [])

    def test_a_job_that_writes_runs_in_the_pass(self):
        workflows = repository()
        workflows["site.yml"]["jobs"]["publish"]["if"] = "${{ github.ref == 'refs/heads/main' }}"
        self.assertProblem(workflows, "site.yml: the job publish can write or deploy, and its condition lacks `!inputs.full`")

    def test_a_job_that_deploys_runs_in_the_pass(self):
        workflows = repository()
        workflows["app.yml"]["jobs"]["deploy"] = {"name": "Deploy", "needs": "build", "environment": "cloudflare",
                                                  "steps": [{"run": "deploy.sh"}]}
        self.assertProblem(workflows, "app.yml: the job deploy can write or deploy")

    def test_a_call_granted_less_than_its_jobs_ask_for(self):
        workflows = repository()
        del workflows["full-pass.yml"]["jobs"]["site"]["permissions"]
        self.assertProblem(workflows, "grants site.yml less than `contents: write`")

    def test_a_call_granted_less_than_a_job_reads(self):
        workflows = repository()
        workflows["app.yml"]["jobs"]["build"]["permissions"] = {"contents": "read", "actions": "read"}
        self.assertProblem(workflows, "grants app.yml less than `actions: read`")

    def test_two_workflows_keep_an_artifact_of_the_same_name(self):
        workflows = repository()
        workflows["site.yml"]["jobs"]["page"]["steps"].append({"uses": "actions/upload-artifact@x", "with": {"name": "ipa"}})
        self.assertProblem(workflows, "app.yml and site.yml both keep an artifact named 'ipa'")

    def test_the_verdict_waits_for_every_call(self):
        workflows = repository()
        workflows["full-pass.yml"]["jobs"]["verdict"]["needs"] = ["app"]
        self.assertProblem(workflows, "the verdict of full-pass.yml does not wait for site")

    def test_the_verdict_runs_whatever_the_calls_ended_with(self):
        workflows = repository()
        del workflows["full-pass.yml"]["jobs"]["verdict"]["if"]
        self.assertProblem(workflows, "its condition needs `always()`")

    def test_the_pass_has_one_verdict(self):
        workflows = repository()
        del workflows["full-pass.yml"]["jobs"]["verdict"]
        self.assertProblem(workflows, "has 0 jobs that run verdict.py, not one")

    def test_the_pass_does_not_run_on_pull_requests(self):
        workflows = repository()
        workflows["full-pass.yml"]["on"]["pull_request"] = None
        self.assertProblem(workflows, "full-pass.yml runs on pull requests")

    def test_a_release_published_without_the_pass(self):
        workflows = repository()
        workflows["release.yml"]["jobs"]["publish"]["needs"] = ["guard"]
        self.assertProblem(workflows, "release.yml: the job publish publishes a release without waiting for the full test pass")

    def test_a_release_waits_for_the_pass_through_the_jobs_it_needs(self):
        workflows = repository()
        jobs = workflows["release.yml"]["jobs"]
        jobs["guard"]["needs"] = ["build", "tests"]
        jobs["publish"]["needs"] = ["guard"]
        self.assertEqual(self.problems(workflows), [])


@needs_yaml
class RepositoryTests(unittest.TestCase):
    """What the pass and the releases promise, in this repository's workflows."""

    def setUp(self):
        import wiring

        self.workflows = wiring.workflows(ROOT)

    def test_the_pull_request_of_a_version_starts_the_pass(self):
        import wiring

        push = wiring.triggers(self.workflows["full-pass.yml"])["push"]
        self.assertEqual(push["branches"], ["main"])
        for path in ("app/config.env", "builder/pyproject.toml", "installer/src-tauri/tauri.conf.json"):
            self.assertIn(path, push["paths"])
        self.assertIn("workflow_dispatch", wiring.triggers(self.workflows["full-pass.yml"]))

    def test_a_second_pass_waits_for_the_first(self):
        concurrency = self.workflows["full-pass.yml"]["concurrency"]
        self.assertIs(concurrency["cancel-in-progress"], False)

    def test_every_publishing_job_waits_for_the_pass_of_its_commit(self):
        for name, publisher in (("release.yml", "publish"), ("builder.yml", "publish"), ("installer.yml", "publish")):
            jobs = self.workflows[name]["jobs"]
            self.assertIn("tests", jobs[publisher]["needs"], name)
            tests = jobs["tests"]
            self.assertEqual(tests["name"], "Full test pass on this commit")
            self.assertEqual(tests["permissions"], {"contents": "read", "actions": "write"})
            run = tests["steps"][-1]["run"]
            self.assertIn('.github/full-pass/wait_for_pass.py --sha "$GITHUB_SHA" --ref "$GITHUB_REF" --start', run)
            self.assertEqual(tests["steps"][0]["with"]["fetch-depth"], 0)

    def test_the_pass_builds_and_tests_the_app_and_the_storage_whatever_the_paths(self):
        for name in ("app.yml", "storage.yml"):
            step = self.workflows[name]["jobs"]["changes"]["steps"][-1]
            self.assertEqual(step["env"]["FULL"], "${{ inputs.full }}", name)
            self.assertIn('[ "$FULL" = "true" ]', step["run"], name)

    def test_the_pass_is_cancelled_by_nothing_else(self):
        for call in ("app.yml", "storage.yml", "screens.yml", "builder.yml", "installer.yml", "telemetry.yml", "site.yml"):
            group = self.workflows[call]["concurrency"]["group"]
            self.assertTrue(group.startswith("${{ inputs.full && format('"), call)
            self.assertIn("-full-{0}', github.run_id)", group, call)


class Api:
    """GitHub, as wait_for_pass.py asks it, from a script of answers."""

    def __init__(self, runs=(), passed_on_main=(), heads=None, reruns=True):
        # Each call to runs_of takes the next list; the last one stays.
        self.runs = [list(answer) for answer in runs] or [[]]
        self.main = list(passed_on_main)
        self.heads = heads or {}
        self.started: list[str] = []
        self.reran: list[int] = []
        # Whether GitHub runs a run again when asked: not one that another
        # job has run again already.
        self.reruns = reruns
        self.calls = 0

    def runs_of(self, sha):
        self.calls += 1
        answer = self.runs[0] if len(self.runs) == 1 else self.runs.pop(0)
        return [run for run in answer if run.sha == sha]

    def passed_on_main(self):
        return self.main

    def commit_of(self, ref):
        return self.heads[ref]

    def start(self, ref):
        self.started.append(ref)

    def rerun(self, run_id):
        self.reran.append(run_id)
        return self.reruns


class Git:
    def __init__(self, history: dict[str, str] | None = None, changes: dict[tuple[str, str], set[str]] | None = None):
        # history: commit -> its parent.
        self.history = history or {}
        self.changes = changes or {}

    def is_ancestor(self, ancestor, sha):
        while sha:
            if sha == ancestor:
                return True
            sha = self.history.get(sha)
        return False

    def changed(self, since, sha):
        return self.changes[(since, sha)]


class Clock:
    def __init__(self):
        self.time = 0.0
        self.slept: list[float] = []

    def now(self):
        return self.time

    def sleep(self, seconds):
        self.slept.append(seconds)
        self.time += seconds


SHA = "a" * 40
EARLIER = "b" * 40


def run(id, status="completed", conclusion="success", sha=SHA, attempt=1):
    return Run(id, sha, status, conclusion, f"https://github.com/o/r/actions/runs/{id}", attempt=attempt)


class WaitTests(unittest.TestCase):
    def wait(self, api, git=None, start=True, minutes=60, ref="refs/heads/main"):
        self.clock = Clock()
        self.said: list[str] = []
        return wait(api, git or Git(), SHA, ref, start, minutes, sleep=self.clock.sleep, now=self.clock.now,
                    say=self.said.append)

    def test_a_pass_of_this_commit_that_passed(self):
        outcome = self.wait(Api(runs=[[run(1, conclusion="failure"), run(2)]]))
        self.assertTrue(outcome.passed)
        self.assertEqual(outcome.url, "https://github.com/o/r/actions/runs/2")
        self.assertEqual(self.clock.slept, [])

    def test_waits_for_the_pass_that_runs(self):
        api = Api(runs=[[run(3, "queued", None)], [run(3, "in_progress", None)], [run(3)]])
        outcome = self.wait(api)
        self.assertTrue(outcome.passed)
        self.assertEqual(self.clock.slept, [wait_for_pass.POLL, wait_for_pass.POLL])
        self.assertEqual(self.said, ["Waiting for the full test pass of aaaaaaaaaaaa: https://github.com/o/r/actions/runs/3"])
        self.assertEqual(api.started, [])

    def test_a_pass_run_again_after_it_failed(self):
        # Re-run its failed jobs: the same run, running again, then passed.
        api = Api(runs=[[run(4, "in_progress", None)], [run(4)]])
        self.assertTrue(self.wait(api).passed)

    def test_stops_waiting_after_the_minutes_given(self):
        outcome = self.wait(Api(runs=[[run(3, "in_progress", None)]]), minutes=10)
        self.assertFalse(outcome.passed)
        self.assertIn("has not ended after 10 minutes", outcome.message)
        self.assertEqual(outcome.url, "https://github.com/o/r/actions/runs/3")

    def test_a_pass_that_failed_blocks_without_starting_another(self):
        api = Api(runs=[[run(5, conclusion="failure"), run(6, conclusion="cancelled")]], heads={"main": SHA})
        outcome = self.wait(api)
        self.assertFalse(outcome.passed)
        self.assertIn("failed: fix main, or re-run its failed jobs", outcome.message)
        self.assertEqual(outcome.url, "https://github.com/o/r/actions/runs/5")
        self.assertEqual(api.started, [])

    def test_a_pass_that_could_not_start_failed(self):
        self.assertFalse(self.wait(Api(runs=[[run(5, conclusion="startup_failure")]])).passed)

    def test_no_pass_and_nothing_to_start_it(self):
        outcome = self.wait(Api(), start=False)
        self.assertFalse(outcome.passed)
        self.assertIn("No full test pass has run on aaaaaaaaaaaa: run Actions › Full test pass on it", outcome.message)

    def test_starts_a_pass_when_none_has_run(self):
        # Nothing shows for three minutes: no push started one.
        api = Api(runs=[[]] * 13 + [[run(7, "queued", None)], [run(7)]], heads={"main": SHA})
        outcome = self.wait(api)
        self.assertTrue(outcome.passed)
        self.assertEqual(api.started, ["main"])
        self.assertIn("No full test pass has run on aaaaaaaaaaaa: starting one on main", self.said)
        self.assertGreaterEqual(sum(self.clock.slept[:12]), wait_for_pass.SHOWS_WITHIN)

    def test_the_pass_the_push_of_a_version_starts_shows_late(self):
        api = Api(runs=[[], [], [run(8, "queued", None)], [run(8)]], heads={"main": SHA})
        self.assertTrue(self.wait(api).passed)
        self.assertEqual(api.started, [])

    def test_does_not_start_a_pass_on_a_branch_that_moved(self):
        api = Api(heads={"main": "c" * 40})
        outcome = self.wait(api)
        self.assertFalse(outcome.passed)
        self.assertIn("main is at cccccccccccc now", outcome.message)
        self.assertEqual(api.started, [])

    def test_starts_on_the_tag_of_a_pushed_release(self):
        api = Api(runs=[[]] * 13 + [[run(9, "queued", None)], [run(9)]], heads={"v0.12.0": SHA})
        self.assertTrue(self.wait(api, ref="refs/tags/v0.12.0").passed)
        self.assertEqual(api.started, ["v0.12.0"])

    def test_runs_a_cancelled_pass_again_rather_than_start_another(self):
        # 13 November, 18:20Z: the pass of 0.12.1 was cancelled while Release,
        # Builder and Installer waited for it, and each would have started one
        # of its own, when the same one, run again, does for all of them.
        api = Api(runs=[[run(10, conclusion="cancelled")], [run(10, "queued", None, attempt=2)], [run(10, attempt=2)]],
                  heads={"main": SHA})
        outcome = self.wait(api)
        self.assertTrue(outcome.passed)
        self.assertEqual(api.reran, [10])
        self.assertEqual(api.started, [])
        self.assertIn("The full test pass of aaaaaaaaaaaa was cancelled: running it again, once: "
                      "https://github.com/o/r/actions/runs/10", self.said)
        # No wait for a push: a pass of this commit ran already.
        self.assertEqual(self.clock.slept[0], 15)

    def test_waits_for_the_pass_another_job_ran_again(self):
        api = Api(runs=[[run(10, conclusion="cancelled")], [run(10, conclusion="cancelled")],
                        [run(10, "in_progress", None, attempt=2)], [run(10, attempt=2)]], heads={"main": SHA}, reruns=False)
        self.assertTrue(self.wait(api).passed)
        self.assertEqual(api.reran, [10])
        self.assertEqual(api.started, [])

    def test_a_pass_cancelled_again_once_run_again_blocks(self):
        api = Api(runs=[[run(10, conclusion="cancelled")], [run(10, "queued", None, attempt=2)],
                        [run(10, conclusion="cancelled", attempt=2)]], heads={"main": SHA})
        outcome = self.wait(api)
        self.assertFalse(outcome.passed)
        self.assertIn("The full test pass of aaaaaaaaaaaa was cancelled again once run again", outcome.message)
        self.assertEqual(outcome.url, "https://github.com/o/r/actions/runs/10")
        self.assertEqual((api.reran, api.started), ([10], []))
        # Run again by another job, or from the Actions tab, then cancelled.
        api = Api(runs=[[run(10, conclusion="cancelled", attempt=2)]], heads={"main": SHA})
        self.assertIn("was cancelled again once run again", self.wait(api).message)
        self.assertEqual((api.reran, api.started), ([], []))

    def test_a_cancelled_pass_that_does_not_run_again(self):
        api = Api(runs=[[run(10, conclusion="cancelled")]], heads={"main": SHA})
        outcome = self.wait(api)
        self.assertFalse(outcome.passed)
        self.assertIn("was cancelled, and does not run again", outcome.message)
        self.assertEqual((api.reran, api.started), ([10], []))
        self.assertGreaterEqual(self.clock.time, wait_for_pass.STARTED_SHOWS_WITHIN)

    def test_the_pass_started_was_cancelled(self):
        api = Api(runs=[[]] * 13 + [[run(12, conclusion="cancelled")], [run(12, "queued", None, attempt=2)],
                                    [run(12, attempt=2)]], heads={"main": SHA})
        self.assertTrue(self.wait(api).passed)
        self.assertEqual((api.started, api.reran), (["main"], [12]))

    def test_the_pass_started_ended_otherwise(self):
        api = Api(runs=[[]] * 13 + [[run(12, conclusion="skipped")]], heads={"main": SHA})
        outcome = self.wait(api)
        self.assertFalse(outcome.passed)
        self.assertIn("The full test pass started on main was skipped", outcome.message)
        self.assertEqual(api.started, ["main"])

    def test_the_pass_started_does_not_show(self):
        api = Api(heads={"main": SHA})
        outcome = self.wait(api)
        self.assertFalse(outcome.passed)
        self.assertEqual(outcome.message, "The full test pass started on main does not show")
        self.assertEqual(api.started, ["main"])

    def test_an_earlier_pass_holds_when_only_the_source_changed_since(self):
        # The pull request "Source: Cartouche X", merged after the release.
        git = Git(history={SHA: EARLIER}, changes={(EARLIER, SHA): {"app/sidestore-source.json"}})
        api = Api(passed_on_main=[run(13, sha=EARLIER)])
        outcome = self.wait(api, git, start=False)
        self.assertTrue(outcome.passed)
        self.assertIn("The full test pass of bbbbbbbbbbbb passed, and the commits since change only", outcome.message)

    def test_an_earlier_pass_does_not_hold_when_anything_else_changed(self):
        git = Git(history={SHA: EARLIER},
                  changes={(EARLIER, SHA): {"app/sidestore-source.json", "launcher/Sources/CartoucheHome.swift"}})
        outcome = self.wait(Api(passed_on_main=[run(13, sha=EARLIER)]), git, start=False)
        self.assertFalse(outcome.passed)

    def test_a_pass_of_another_branch_of_history_does_not_hold(self):
        git = Git(history={SHA: "d" * 40}, changes={(EARLIER, SHA): set()})
        outcome = self.wait(Api(passed_on_main=[run(13, sha=EARLIER)]), git, start=False)
        self.assertFalse(outcome.passed)

    def test_the_pass_of_this_commit_comes_before_an_earlier_one(self):
        git = Git(history={SHA: EARLIER}, changes={(EARLIER, SHA): {"app/sidestore-source.json"}})
        api = Api(runs=[[run(14, conclusion="failure")]], passed_on_main=[run(13, sha=EARLIER)])
        self.assertFalse(self.wait(api, git).passed)

    def test_names_the_branch_and_tag_as_github_does(self):
        self.assertEqual(wait_for_pass.short("refs/heads/main"), "main")
        self.assertEqual(wait_for_pass.short("refs/tags/v0.12.0"), "v0.12.0")

    def test_reads_the_runs_of_the_api(self):
        found = Run.of({"id": 1, "head_sha": SHA, "status": "completed", "conclusion": "success",
                        "html_url": "https://github.com/o/r/actions/runs/1", "created_at": "2026-11-12T12:00:00Z"})
        self.assertTrue(found.passed)
        self.assertFalse(found.running)
        self.assertTrue(Run.of({"id": 2, "head_sha": SHA, "status": "waiting", "html_url": "u"}).running)
        again = Run.of({"id": 3, "head_sha": SHA, "status": "completed", "conclusion": "cancelled",
                        "html_url": "u", "run_attempt": 2})
        self.assertEqual((again.attempt, again.cancelled, again.failed), (2, True, False))

    def test_prints_the_outcome_for_the_run(self):
        with tempfile.TemporaryDirectory() as tmp:
            summary = Path(tmp, "summary.md")
            outcome = wait_for_pass.Outcome(False, "The full test pass of aaaaaaaaaaaa failed", "https://u")
            original = wait_for_pass.wait
            wait_for_pass.wait = lambda *args, **kwargs: outcome
            try:
                out = io.StringIO()
                with redirect_stdout(out):
                    code = wait_for_pass.main(["wait_for_pass.py", "--sha", SHA, "--ref", "refs/heads/main",
                                               "--repository", "o/r", "--summary", str(summary)])
            finally:
                wait_for_pass.wait = original
            self.assertEqual(code, 1)
            self.assertEqual(out.getvalue(), "::error::The full test pass of aaaaaaaaaaaa failed: https://u\n")
            self.assertIn("The full test pass of aaaaaaaaaaaa failed ([the run](https://u)).", summary.read_text())


@needs_yaml
class VerdictTests(unittest.TestCase):
    def setUp(self):
        import verdict

        self.verdict = verdict
        self.expected = [
            verdict.Expected("App", "Files the app is built from", False),
            verdict.Expected("App", "Build Cartouche.ipa", False),
            verdict.Expected("Installer", "Build for ${{ matrix.name }}", False),
            verdict.Expected("Installer", "Publish the installer", True),
        ]
        self.calls = {"app": "App", "installer": "Installer"}
        self.needs = {"app": {"result": "success"}, "installer": {"result": "success"}}

    def jobs(self, **changes):
        jobs = {
            "App / Files the app is built from": "success",
            "App / Build Cartouche.ipa": "success",
            "Installer / Build for macOS": "success",
            "Installer / Build for Windows": "success",
            "Installer / Publish the installer": "skipped",
            "Every test passed": None,
        }
        jobs.update(changes)
        return [{"name": name, "status": "in_progress" if conclusion is None else "completed", "conclusion": conclusion}
                for name, conclusion in jobs.items()]

    def judge(self, jobs, needs=None):
        return self.verdict.judge(self.expected, self.calls, needs or self.needs, jobs, "Every test passed")

    def test_every_test_job_ran_and_passed(self):
        found = self.judge(self.jobs())
        self.assertTrue(found.passed, found.problems)
        self.assertEqual(found.parts, [("App", "success"), ("Installer", "success")])

    def test_a_part_that_failed(self):
        found = self.judge(self.jobs(**{"App / Build Cartouche.ipa": "failure"}),
                           {"app": {"result": "failure"}, "installer": {"result": "success"}})
        self.assertFalse(found.passed)
        self.assertIn("App: failure", found.problems)
        self.assertIn("App / Build Cartouche.ipa: failure", found.problems)

    def test_a_test_job_skipped_in_a_part_that_succeeded(self):
        found = self.judge(self.jobs(**{"App / Build Cartouche.ipa": "skipped"}))
        self.assertEqual(found.problems, ["App / Build Cartouche.ipa was skipped: in the full test pass every test job runs"])

    def test_a_job_that_publishes_is_skipped(self):
        self.assertTrue(self.judge(self.jobs()).passed)

    def test_a_job_of_a_matrix_skipped(self):
        found = self.judge(self.jobs(**{"Installer / Build for Windows": "skipped"}))
        self.assertFalse(found.passed)

    def test_a_job_the_workflows_do_not_have_skipped(self):
        found = self.judge(self.jobs(**{"App / Something new": "skipped"}))
        self.assertEqual(found.problems, ["App / Something new was skipped: in the full test pass every test job runs"])

    def test_a_test_job_not_in_the_run(self):
        jobs = [job for job in self.jobs() if job["name"] != "App / Build Cartouche.ipa"]
        self.assertEqual(self.judge(jobs).problems, ["App / Build Cartouche.ipa is not in the run"])

    def test_a_job_that_has_not_ended(self):
        jobs = self.jobs()
        jobs[0]["status"], jobs[0]["conclusion"] = "in_progress", None
        self.assertIn("App / Files the app is built from has not ended (in_progress)", self.judge(jobs).problems)

    def test_names_a_job_with_or_without_its_call(self):
        build = self.verdict.Expected("Installer", "Build for ${{ matrix.name }}", False)
        self.assertTrue(build.matches("Installer / Build for macOS"))
        self.assertTrue(build.matches("Build for Windows"))
        self.assertFalse(build.matches("App / Build for macOS"))
        self.assertFalse(build.matches("Installer / Build"))
        self.assertTrue(self.verdict.Expected("CI", "Showcase site", False).matches("CI / Showcase site"))
        self.assertFalse(self.verdict.Expected("Showcase site", "Check the page", False).matches("CI / Showcase site"))

    def test_names_a_matrix_job_by_its_values(self):
        storage = self.verdict.Expected("Storage", "Storage against real servers", False, matrix=True)
        self.assertTrue(storage.matches("Storage / Storage against real servers (smb, 3)"))
        self.assertTrue(storage.matches("Storage / Storage against real servers"))
        self.assertFalse(storage.matches("Storage / Storage against real servers again"))
        alone = self.verdict.Expected("Storage", "Storage against real servers", False)
        self.assertFalse(alone.matches("Storage / Storage against real servers (smb, 3)"))
        build = self.verdict.Expected("Installer", "Build for ${{ matrix.name }}", False, matrix=True)
        self.assertTrue(build.matches("Installer / Build for macOS"))

    def test_a_call_missing_from_the_needs(self):
        self.assertIn("Installer: missing", self.judge(self.jobs(), {"app": {"result": "success"}}).problems)

    def test_the_jobs_of_this_repository(self):
        found = self.verdict.expected_jobs(ROOT)
        names = {(one.call, one.name): one.may_skip for one in found}
        self.assertIs(names[("App", "Build Cartouche.ipa")], False)
        self.assertIs(names[("Storage", "Storage against real servers")], False)
        self.assertIs(names[("Installer", "Build for ${{ matrix.name }}")], False)
        self.assertEqual({one.name for one in found if one.matrix}, {"Build for ${{ matrix.name }}"})
        self.assertIs(names[("Builder", "Mac app")], False)
        self.assertIs(names[("Telemetry", "Telemetry server")], False)
        self.assertIs(names[("CI", "Workflow audit")], False)
        self.assertIs(names[("App", "Ad's Mac or GitHub")], False)
        self.assertIs(names[("Launcher screens", "UI tests and screenshots")], False)
        self.assertIs(names[("Showcase site", "Check the page")], False)
        for skipped in (("Telemetry", "Deploy the telemetry server"), ("Builder", "Publish Cartouche Builder"),
                        ("Builder", "Full test pass on this commit"), ("Installer", "Publish the installer"),
                        ("Launcher screens", "Keep the screenshots on a branch"), ("Showcase site", "Publish it on gh-pages"),
                        ("App", "Watch Ad's Mac"), ("Launcher screens", "Watch Ad's Mac")):
            self.assertIs(names[skipped], True, skipped)

    def test_the_summary_names_each_part(self):
        found = self.judge(self.jobs(**{"App / Build Cartouche.ipa": "failure"}),
                           {"app": {"result": "failure"}, "installer": {"result": "success"}})
        text = self.verdict.summary(found, "https://github.com/o/r/actions/runs/1")
        self.assertIn("**Not passed**: no release can be published from this commit.", text)
        self.assertIn("| App | failure |", text)
        self.assertIn("| Installer | passed |", text)
        self.assertIn("- App / Build Cartouche.ipa: failure", text)
        self.assertIn("[re-run the failed jobs](https://github.com/o/r/actions/runs/1)", text)


if __name__ == "__main__":
    unittest.main()
