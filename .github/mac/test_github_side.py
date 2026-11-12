"""Tests of what runs on GitHub for the jobs of Ad's Mac: route.py, which
picks the Mac or GitHub's Macs, watch.py, which sends a run back to GitHub's
when the Mac loses its job, and rescue.py, which runs it again."""

from __future__ import annotations

import datetime
import io
import json
import sys
import tempfile
import unittest
from contextlib import redirect_stdout
from pathlib import Path
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parent))

import api  # noqa: E402
import rescue  # noqa: E402
import route  # noqa: E402
import watch  # noqa: E402

REPOSITORY = "clabeuhtegrite/Cartouche"
OWNER = "clabeuhtegrite"
# The labels of the Mac's two runners, as install.sh gives them, and what
# the jobs of each ask for (MAC_LABELS, with cartouche-mac).
BUILDS = ("self-hosted", "macOS", "cartouche-mac", "cartouche-build", "xcode-27.2")
SCREENS = ("self-hosted", "macOS", "cartouche-mac", "cartouche-screens", "xcode-27.2", "ios-sim-27.2")
MAC = {"cartouche-mac", "cartouche-build", "xcode-27.2"}
SCREENSHOTS = {"cartouche-mac", "cartouche-screens", "xcode-27.2", "ios-sim-27.2"}


def runner(status: str = "online", busy: bool = False, labels=BUILDS, name: str = "ad-mac") -> dict:
    return {"id": 1, "name": name, "status": status, "busy": busy, "labels": [{"name": n} for n in labels]}


def pull_event(head: str = REPOSITORY) -> dict:
    return {
        "sender": {"login": OWNER}, "repository": {"full_name": REPOSITORY},
        "pull_request": {"number": 1, "user": {"login": OWNER},
                         "head": {"ref": "claude/x", "repo": {"full_name": head, "id": 7 if head == REPOSITORY else 8}},
                         "base": {"ref": "main", "repo": {"full_name": REPOSITORY, "id": 7}}},
    }


def run_env(**extra: str) -> dict:
    return {"GITHUB_REPOSITORY": REPOSITORY, "GITHUB_REPOSITORY_OWNER": OWNER, "GITHUB_EVENT_NAME": "pull_request",
            "GITHUB_ACTOR": OWNER, "GITHUB_TRIGGERING_ACTOR": OWNER, "GITHUB_RUN_ATTEMPT": "1",
            "GITHUB_RUN_ID": "500", "RUNNERS_TOKEN": "secret", "GH_TOKEN": "token",
            "GITHUB_WORKFLOW_REF": f"{REPOSITORY}/.github/workflows/app.yml@refs/pull/1/merge",
            "MAC_LABELS": "cartouche-build,xcode-27.2", "MAC_JOB": "Build Cartouche.ipa", **extra}


class PickTests(unittest.TestCase):
    def test_takes_a_free_mac(self):
        chosen, why = route.pick([runner()], MAC, lambda: self.fail("no need to count"))
        self.assertEqual(chosen["name"], "ad-mac")

    def test_queues_behind_the_job_the_mac_runs_when_nothing_else_waits(self):
        self.assertIsNotNone(route.pick([runner(busy=True)], MAC, lambda: 0)[0])

    def test_sends_to_github_when_jobs_wait_for_the_mac_already(self):
        chosen, why = route.pick([runner(busy=True)], MAC, lambda: 2)
        self.assertIsNone(chosen)
        self.assertIn("2 more jobs", why)

    def test_sends_to_github_when_the_mac_is_offline(self):
        self.assertIsNone(route.pick([runner(status="offline")], MAC, lambda: 0)[0])

    def test_sends_to_github_when_the_mac_lacks_a_label(self):
        chosen, why = route.pick([runner(labels=("cartouche-mac", "xcode-27.1"))], MAC, lambda: 0)
        self.assertIsNone(chosen)
        self.assertIn("xcode-27.2", why)

    def test_sends_to_github_without_a_runner_of_the_mac(self):
        self.assertIsNone(route.pick([runner(labels=("self-hosted", "xcode-27.2"))], MAC, lambda: 0)[0])
        self.assertIsNone(route.pick([], MAC, lambda: 0)[0])

    def test_the_screenshots_take_their_own_runner_while_a_build_runs(self):
        found = [runner(busy=True), runner(labels=SCREENS, name="ad-mac-screens")]
        chosen, why = route.pick(found, SCREENSHOTS, lambda: self.fail("no need to count"))
        self.assertEqual(chosen["name"], "ad-mac-screens")

    def test_a_build_never_goes_to_the_screenshots_runner(self):
        # Ad, 12 November: one job runs and one waits on each runner, at most.
        found = [runner(busy=True), runner(labels=SCREENS, name="ad-mac-screens")]
        self.assertEqual(route.pick(found, MAC, lambda: 0)[0]["name"], "ad-mac", "next, behind the build")
        chosen, why = route.pick(found, MAC, lambda: 1)
        self.assertIsNone(chosen)
        self.assertIn("1 more job waiting", why)

    def test_says_what_the_closest_runner_lacks(self):
        found = [runner(labels=("cartouche-mac", "cartouche-screens", "xcode-27.1")),
                 runner(labels=("cartouche-mac", "cartouche-build", "xcode-27.1"), name="ad-mac-2")]
        chosen, why = route.pick(found, MAC, lambda: 0)
        self.assertIsNone(chosen)
        self.assertIn("has no xcode-27.2:", why)


class RouteTests(unittest.TestCase):
    def route(self, env: dict, event: dict, runners: list | None = None) -> tuple[dict | None, str]:
        with mock.patch.object(api, "runners", return_value=[runner()] if runners is None else runners):
            return route.route(env, event)

    def test_the_mac_takes_a_pull_request_of_the_repository(self):
        self.assertIsNotNone(self.route(run_env(), pull_event())[0])

    def test_never_a_fork(self):
        chosen, why = self.route(run_env(), pull_event("javi11/Cartouche"))
        self.assertIsNone(chosen)
        self.assertIn("fork", why)

    def test_never_a_run_again(self):
        self.assertIsNone(self.route(run_env(GITHUB_RUN_ATTEMPT="2"), pull_event())[0])

    def test_never_without_the_secret(self):
        self.assertIsNone(self.route(run_env(RUNNERS_TOKEN=""), pull_event())[0])

    def test_never_a_push(self):
        self.assertIsNone(self.route(run_env(GITHUB_EVENT_NAME="push"), pull_event())[0])

    def test_never_a_workflow_that_calls_app_or_launcher_screens(self):
        called = run_env(GITHUB_WORKFLOW_REF=f"{REPOSITORY}/.github/workflows/full-pass.yml@refs/heads/main")
        chosen, why = self.route(called, pull_event())
        self.assertIsNone(chosen)
        self.assertIn("full-pass.yml", why)
        screens = run_env(GITHUB_WORKFLOW_REF=f"{REPOSITORY.lower()}/.github/workflows/screens.yml@refs/pull/1/merge")
        self.assertIsNotNone(self.route(screens, pull_event())[0])
        self.assertIsNone(self.route(run_env(GITHUB_WORKFLOW_REF=""), pull_event())[0])

    def test_counts_the_jobs_waiting_for_the_mac(self):
        answers = {
            f"/repos/{REPOSITORY}/actions/runs?status=queued&per_page=30": {"workflow_runs": [{"id": 1}]},
            f"/repos/{REPOSITORY}/actions/runs?status=in_progress&per_page=30": {"workflow_runs": [{"id": 2}]},
            f"/repos/{REPOSITORY}/actions/runs/1/jobs?per_page=100": {"jobs": [
                {"status": "queued", "labels": ["self-hosted", "cartouche-mac"]},
                {"status": "queued", "labels": ["xcode-27"]}]},
            f"/repos/{REPOSITORY}/actions/runs/2/jobs?per_page=100": {"jobs": [
                {"status": "in_progress", "labels": ["self-hosted", "cartouche-mac"]},
                {"status": "waiting", "labels": ["self-hosted", "cartouche-mac", "ios-sim-27.2"]}]},
        }
        with mock.patch.object(api, "call", side_effect=lambda method, path, token, body=None: answers[path]):
            self.assertEqual(route.waiting_for_mac(REPOSITORY, "token"), 2)

    def test_counts_only_the_jobs_waiting_for_the_same_runner(self):
        build = ["self-hosted", "cartouche-build", "cartouche-mac", "xcode-27.2"]
        screens = ["self-hosted", "cartouche-mac", "cartouche-screens", "ios-sim-27.2", "xcode-27.2"]
        answers = {
            f"/repos/{REPOSITORY}/actions/runs?status=queued&per_page=30": {"workflow_runs": [{"id": 1}]},
            f"/repos/{REPOSITORY}/actions/runs?status=in_progress&per_page=30": {"workflow_runs": [{"id": 2}]},
            f"/repos/{REPOSITORY}/actions/runs/1/jobs?per_page=100": {"jobs": [
                {"status": "queued", "labels": build}, {"status": "queued", "labels": screens}]},
            f"/repos/{REPOSITORY}/actions/runs/2/jobs?per_page=100": {"jobs": [
                {"status": "in_progress", "labels": build}, {"status": "waiting", "labels": screens}]},
        }
        with mock.patch.object(api, "call", side_effect=lambda method, path, token, body=None: answers[path]):
            self.assertEqual(route.waiting_for_mac(REPOSITORY, "token", frozenset(MAC)), 1)
            self.assertEqual(route.waiting_for_mac(REPOSITORY, "token", frozenset(SCREENSHOTS)), 2)

    def test_counts_the_jobs_waiting_for_the_runner_the_job_asks_for(self):
        found = [runner(busy=True), runner(labels=SCREENS, name="ad-mac-screens")]
        with mock.patch.object(route, "waiting_for_mac", return_value=1) as counted:
            chosen, why = self.route(run_env(), pull_event(), found)
        self.assertIsNone(chosen)
        self.assertEqual(counted.call_args.args[2], frozenset(MAC))


class RouteMainTests(unittest.TestCase):
    def main(self, env: dict, runners: list | None = None, error: Exception | None = None) -> dict:
        with tempfile.TemporaryDirectory() as folder:
            event, output = Path(folder, "event.json"), Path(folder, "output")
            event.write_text(json.dumps(pull_event()))
            env = {**env, "GITHUB_EVENT_PATH": str(event), "GITHUB_OUTPUT": str(output)}
            patch = mock.patch.object(api, "runners", side_effect=error) if error else \
                mock.patch.object(api, "runners", return_value=[runner()] if runners is None else runners)
            with mock.patch.dict("os.environ", env, clear=True), patch, redirect_stdout(io.StringIO()):
                self.assertEqual(route.main(), 0)
            return dict(line.split("=", 1) for line in output.read_text().splitlines())

    def test_gives_the_mac_s_labels_to_runs_on(self):
        outputs = self.main(run_env())
        self.assertEqual(json.loads(outputs["runner"]), ["self-hosted", "cartouche-build", "cartouche-mac", "xcode-27.2"])
        self.assertEqual(outputs["mac"], "true")

    def test_gives_github_s_macs_otherwise(self):
        outputs = self.main(run_env(), runners=[runner(status="offline")])
        self.assertEqual(json.loads(outputs["runner"]), "xcode-27")
        self.assertEqual(outputs["mac"], "false")

    def test_gives_github_s_macs_when_the_api_fails(self):
        outputs = self.main(run_env(), error=api.Error("GET /runners: HTTP 401"))
        self.assertEqual(json.loads(outputs["runner"]), "xcode-27")


def job(status: str, created: str = "2026-11-12T12:00:00Z", runner_name: str | None = None, name: str = "Build Cartouche.ipa", conclusion=None) -> dict:
    return {"name": name, "status": status, "created_at": created, "runner_name": runner_name, "conclusion": conclusion}


NOON = datetime.datetime(2026, 11, 12, 12, tzinfo=datetime.timezone.utc).timestamp()


class VerdictTests(unittest.TestCase):
    def test_waits_for_the_job(self):
        self.assertEqual(watch.verdict(None, 0, NOON)[0], "wait")
        self.assertEqual(watch.verdict(job("queued"), 0, NOON + 60)[0], "wait")
        self.assertEqual(watch.verdict(job("in_progress"), 2, NOON + 600)[0], "wait")

    def test_ends_with_the_job(self):
        self.assertEqual(watch.verdict(job("completed", conclusion="failure"), 5, NOON)[0], "done")

    def test_goes_back_when_the_mac_is_offline_three_checks_in_a_row(self):
        action, why = watch.verdict(job("queued"), 3, NOON + 60)
        self.assertEqual(action, "back")
        self.assertIn("before it took the job", why)
        self.assertIn("during the job", watch.verdict(job("in_progress"), 3, NOON + 60)[1])

    def test_goes_back_when_the_job_waited_too_long(self):
        self.assertEqual(watch.verdict(job("queued"), 0, NOON + 21 * 60)[0], "back")
        self.assertEqual(watch.verdict(job("in_progress"), 0, NOON + 60 * 60)[0], "wait")


class OnlineTests(unittest.TestCase):
    def test_a_running_job_needs_its_own_runner(self):
        found = [runner(), {**runner(status="offline"), "name": "other"}]
        self.assertTrue(watch.online(found, job("in_progress", runner_name="ad-mac"), MAC))
        self.assertFalse(watch.online(found, job("in_progress", runner_name="other"), MAC))

    def test_a_waiting_job_needs_a_runner_that_can_take_it(self):
        self.assertTrue(watch.online([runner()], job("queued"), MAC))
        self.assertFalse(watch.online([runner(status="offline")], job("queued"), MAC))
        self.assertFalse(watch.online([runner(labels=("cartouche-mac",))], job("queued"), MAC))


class Clock:
    def __init__(self, start: float) -> None:
        self.now = start

    def time(self) -> float:
        return self.now

    def sleep(self, seconds: float) -> None:
        self.now += seconds


class WatchTests(unittest.TestCase):
    def watch(self, jobs: list, runners: list, dispatch_fails: bool = False) -> tuple[str, list]:
        calls = []

        def call(method, path, token, body=None):
            calls.append((method, path, body))
            if method == "GET":
                return {"jobs": jobs.pop(0) if len(jobs) > 1 else jobs[0]}
            if dispatch_fails and path.endswith("/dispatches"):
                raise api.Error("HTTP 404")
            return None

        clock = Clock(NOON)
        with mock.patch.object(api, "call", side_effect=call), \
                mock.patch.object(api, "runners", side_effect=lambda r, t: runners.pop(0) if len(runners) > 1 else runners[0]), \
                redirect_stdout(io.StringIO()):
            said = watch.watch(run_env(DEFAULT_BRANCH="main"), clock=clock.time, sleep=clock.sleep)
        return said, [(m, p, b) for m, p, b in calls if m == "POST"]

    def test_ends_when_the_job_ends_on_the_mac(self):
        said, posts = self.watch([[job("queued")], [job("in_progress", runner_name="ad-mac")],
                                  [job("completed", conclusion="success")]], [[runner()]])
        self.assertIn("success", said)
        self.assertEqual(posts, [])

    def test_sends_the_run_back_when_the_mac_goes_offline(self):
        said, posts = self.watch([[job("in_progress", runner_name="ad-mac")]],
                                 [[runner()], [runner(status="offline")]])
        self.assertIn("during the job", said)
        self.assertEqual([p for _, p, _ in posts], [
            f"/repos/{REPOSITORY}/actions/workflows/mac-rescue.yml/dispatches",
            f"/repos/{REPOSITORY}/actions/runs/500/cancel"])
        self.assertEqual(posts[0][2], {"ref": "main", "inputs": {"run": "500"}})

    def test_cancels_nothing_when_mac_rescue_cannot_start(self):
        said, posts = self.watch([[job("queued")]] * 3 + [[job("completed", conclusion="success")]],
                                 [[runner(status="offline")]], dispatch_fails=True)
        self.assertNotIn(f"/repos/{REPOSITORY}/actions/runs/500/cancel", [p for _, p, _ in posts])

    def test_a_job_that_was_skipped_ends_the_watch(self):
        said, posts = self.watch([[job("completed", conclusion="skipped")]], [[runner()]])
        self.assertIn("skipped", said)

    def test_a_job_of_another_name_ends_the_watch_in_minutes(self):
        clock = Clock(NOON)
        with mock.patch.object(api, "call", return_value={"jobs": [job("queued", name="Other")]}), \
                redirect_stdout(io.StringIO()):
            said = watch.watch(run_env(DEFAULT_BRANCH="main"), clock=clock.time, sleep=clock.sleep)
        self.assertIn("no job named", said)
        self.assertLess(clock.now - NOON, (watch.MISSING_MINUTES + 1) * 60)


class RescueTests(unittest.TestCase):
    RUN = {"id": 500, "path": ".github/workflows/app.yml", "event": "pull_request", "run_attempt": 1,
           "head_repository": {"full_name": REPOSITORY}, "head_branch": "claude/x", "workflow_id": 9,
           "created_at": "2026-11-12T12:00:00Z"}

    def rescue(self, runs: list, newer: list | None = None) -> tuple[str, list]:
        posts = []

        def call(method, path, token, body=None):
            if method == "POST":
                posts.append(path)
                return None
            if "/workflows/" in path:
                return {"workflow_runs": newer if newer is not None else [runs[-1]]}
            return runs.pop(0) if len(runs) > 1 else runs[0]

        clock = Clock(NOON)
        with mock.patch.object(api, "call", side_effect=call):
            said = rescue.rescue({"GITHUB_REPOSITORY": REPOSITORY, "GH_TOKEN": "t", "RUN": "500"},
                                 clock=clock.time, sleep=clock.sleep)
        return said, posts

    def test_runs_again_the_run_its_watch_cancelled(self):
        said, posts = self.rescue([{**self.RUN, "status": "in_progress"},
                                   {**self.RUN, "status": "completed", "conclusion": "cancelled"}])
        self.assertEqual(posts, [f"/repos/{REPOSITORY}/actions/runs/500/rerun"])

    def test_leaves_a_run_a_newer_one_replaced(self):
        cancelled = {**self.RUN, "status": "completed", "conclusion": "cancelled"}
        said, posts = self.rescue([cancelled], newer=[cancelled, {**self.RUN, "id": 501, "created_at": "2026-11-12T12:05:00Z"}])
        self.assertEqual(posts, [])
        self.assertIn("501", said)

    def test_leaves_runs_that_never_go_to_the_mac(self):
        for changed in ({"path": ".github/workflows/release.yml"}, {"event": "push"}, {"run_attempt": 2},
                        {"head_repository": {"full_name": "javi11/Cartouche"}}):
            with self.subTest(changed=changed):
                said, posts = self.rescue([{**self.RUN, **changed, "status": "completed", "conclusion": "cancelled"}])
                self.assertEqual(posts, [])

    def test_leaves_a_run_that_ended_otherwise(self):
        said, posts = self.rescue([{**self.RUN, "status": "completed", "conclusion": "success"}])
        self.assertEqual(posts, [])

    def test_refuses_what_is_not_a_run_id(self):
        with mock.patch.object(api, "call", side_effect=AssertionError("no call")):
            self.assertIn("not the ID", rescue.rescue({"GITHUB_REPOSITORY": REPOSITORY, "RUN": "1;x"}))


if __name__ == "__main__":
    unittest.main()
