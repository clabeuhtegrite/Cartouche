#!/usr/bin/env python3
"""Wait for the Full test pass of a commit, and pass only once it has passed.

The Release workflow, and the Builder and Installer workflows when they
publish, run this before they publish anything from a commit:

- a pass of this commit has passed: done;
- one is queued or running: wait for it, then look again;
- one has failed, and none is running: fail, with its link, without starting
  another: fix main, or re-run its failed jobs when a runner failed them;
- one was cancelled, and none is running: with --start, run it again, once,
  and wait for it, rather than start another: each workflow that waited for
  it started one of its own (13 November). Cancelled again once run again:
  fail, with its link;
- a pass of an earlier commit of main has passed, and the commits since change
  only Cartouche's SideStore source, as the pull request "Source: Cartouche X"
  does: done, since nothing the pass tests has changed;
- none has run: with --start, start one on --ref, which must still be at this
  commit, and wait for it. A push to main that changes a version starts one
  by itself: it may take a minute to show, so this waits a little first.

usage: wait_for_pass.py --sha SHA --ref REF [--start] [--minutes N]
                        [--repository OWNER/NAME] [--summary FILE]
"""

from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
import time
from dataclasses import dataclass
from typing import Callable, Protocol

WORKFLOW = "full-pass.yml"

# What the commits after a pass may change without a new one.
UNTESTED_SINCE = {"app/sidestore-source.json"}

FAILED = {"failure", "timed_out", "startup_failure", "action_required"}

# How long a pass a push to main starts may take to show, and one this starts.
SHOWS_WITHIN = 180
STARTED_SHOWS_WITHIN = 300
POLL = 60


@dataclass(frozen=True)
class Run:
    id: int
    sha: str
    status: str
    conclusion: str | None
    url: str
    created: str = ""
    attempt: int = 1

    @classmethod
    def of(cls, run: dict) -> Run:
        return cls(run["id"], run["head_sha"], run["status"], run.get("conclusion"), run["html_url"],
                   run.get("created_at", ""), run.get("run_attempt", 1))

    @property
    def running(self) -> bool:
        return self.status != "completed"

    @property
    def passed(self) -> bool:
        return self.status == "completed" and self.conclusion == "success"

    @property
    def failed(self) -> bool:
        return self.status == "completed" and self.conclusion in FAILED

    @property
    def cancelled(self) -> bool:
        return self.status == "completed" and self.conclusion == "cancelled"


class Api(Protocol):
    def runs_of(self, sha: str) -> list[Run]: ...
    def passed_on_main(self) -> list[Run]: ...
    def commit_of(self, ref: str) -> str: ...
    def start(self, ref: str) -> None: ...
    def rerun(self, run_id: int) -> bool: ...


class Git(Protocol):
    def is_ancestor(self, ancestor: str, sha: str) -> bool: ...
    def changed(self, since: str, sha: str) -> set[str]: ...


@dataclass(frozen=True)
class Outcome:
    passed: bool
    message: str
    url: str = ""


def short(ref: str) -> str:
    return ref.removeprefix("refs/heads/").removeprefix("refs/tags/")


def earlier_pass(api: Api, git: Git, sha: str) -> Run | None:
    """A pass of main that holds for this commit: only the SideStore source changed since."""
    for run in api.passed_on_main():
        if run.sha != sha and git.is_ancestor(run.sha, sha) and git.changed(run.sha, sha) <= UNTESTED_SINCE:
            return run
    return None


def wait(api: Api, git: Git, sha: str, ref: str, start: bool, minutes: float,
         sleep: Callable[[float], None] = time.sleep, now: Callable[[], float] = time.monotonic,
         say: Callable[[str], None] = print) -> Outcome:
    began = now()
    deadline = began + minutes * 60
    # The passes of this commit there were when this started one, and when.
    before: set[int] = set()
    started_at = None
    waiting_for = None
    # The cancelled pass this asked GitHub to run again, and when.
    rerun: Run | None = None
    rerun_at = 0.0
    while True:
        runs = api.runs_of(sha)
        passed = [run for run in runs if run.passed]
        if passed:
            return Outcome(True, f"The full test pass of {sha[:12]} passed", passed[0].url)
        running = [run for run in runs if run.running]
        if running:
            if waiting_for != running[0].id:
                waiting_for = running[0].id
                say(f"Waiting for the full test pass of {sha[:12]}: {running[0].url}")
            if now() >= deadline:
                return Outcome(False, f"The full test pass of {sha[:12]} has not ended after {minutes:g} minutes",
                               running[0].url)
            sleep(POLL)
            continue
        failed = [run for run in runs if run.failed]
        if failed:
            return Outcome(False, f"The full test pass of {sha[:12]} failed: fix main, or re-run its failed jobs "
                                  "when a runner failed them rather than the code, then re-run this job",
                           failed[0].url)
        earlier = earlier_pass(api, git, sha)
        if earlier:
            return Outcome(True, f"The full test pass of {earlier.sha[:12]} passed, and the commits since change "
                                 "only Cartouche's SideStore source", earlier.url)
        cancelled = [run for run in runs if run.cancelled]
        if cancelled:
            # The newest: GitHub lists the runs newest first.
            latest = cancelled[0]
            if rerun is not None and (latest.id, latest.attempt) == (rerun.id, rerun.attempt):
                # Not running again yet: GitHub may take a moment to show it.
                if now() - rerun_at >= STARTED_SHOWS_WITHIN:
                    return Outcome(False, f"The full test pass of {sha[:12]} was cancelled, and does not run again: "
                                          "run it again from the Actions tab, then re-run this job", latest.url)
                sleep(15)
                continue
            if rerun is not None or latest.attempt > 1:
                return Outcome(False, f"The full test pass of {sha[:12]} was cancelled again once run again: "
                                      "run it again from the Actions tab, then re-run this job", latest.url)
            if not start:
                return Outcome(False, f"The full test pass of {sha[:12]} was cancelled: run it again from the "
                                      "Actions tab, then re-run this job", latest.url)
            say(f"The full test pass of {sha[:12]} was cancelled: running it again, once: {latest.url}")
            if not api.rerun(latest.id):
                # Another job waiting for it may have run it again already.
                say("GitHub did not run it again for this job: waiting for it to run")
            rerun, rerun_at = latest, now()
            sleep(15)
            continue
        if started_at is not None:
            new = [run for run in runs if run.id not in before]
            if new:
                # It ended without passing, failing or being cancelled.
                return Outcome(False, f"The full test pass started on {short(ref)} was {new[0].conclusion}: "
                                      "run it again from the Actions tab, then re-run this job", new[0].url)
            if now() - started_at >= STARTED_SHOWS_WITHIN:
                return Outcome(False, f"The full test pass started on {short(ref)} does not show")
            sleep(15)
            continue
        if not start:
            return Outcome(False, f"No full test pass has run on {sha[:12]}: run Actions › Full test pass on it, "
                                  "then re-run this job")
        if not runs and now() - began < SHOWS_WITHIN:
            # The push of this very commit may be about to start one.
            sleep(15)
            continue
        head = api.commit_of(short(ref))
        if head != sha:
            return Outcome(False, f"No full test pass has run on {sha[:12]}, and {short(ref)} is at {head[:12]} "
                                  f"now: run this workflow on {short(ref)} again")
        say(f"No full test pass has run on {sha[:12]}: starting one on {short(ref)}")
        before = {run.id for run in runs}
        api.start(short(ref))
        started_at = now()
        sleep(15)


class GitHub:
    def __init__(self, repository: str):
        self.repository = repository

    def get(self, path: str) -> dict:
        out = subprocess.run(["gh", "api", path], check=True, capture_output=True, text=True).stdout
        return json.loads(out)

    def runs_of(self, sha: str) -> list[Run]:
        found = self.get(f"repos/{self.repository}/actions/workflows/{WORKFLOW}/runs?head_sha={sha}&per_page=100")
        return [Run.of(run) for run in found.get("workflow_runs", [])]

    def passed_on_main(self) -> list[Run]:
        found = self.get(f"repos/{self.repository}/actions/workflows/{WORKFLOW}/runs?branch=main&status=success&per_page=30")
        return [Run.of(run) for run in found.get("workflow_runs", [])]

    def commit_of(self, ref: str) -> str:
        return self.get(f"repos/{self.repository}/commits/{ref}")["sha"]

    def start(self, ref: str) -> None:
        subprocess.run(["gh", "api", "-X", "POST", f"repos/{self.repository}/actions/workflows/{WORKFLOW}/dispatches",
                        "-f", f"ref={ref}"], check=True, capture_output=True, text=True)

    def rerun(self, run_id: int) -> bool:
        return subprocess.run(["gh", "api", "-X", "POST", f"repos/{self.repository}/actions/runs/{run_id}/rerun"],
                              capture_output=True, text=True).returncode == 0


class Checkout:
    def is_ancestor(self, ancestor: str, sha: str) -> bool:
        return subprocess.run(["git", "merge-base", "--is-ancestor", ancestor, sha], capture_output=True).returncode == 0

    def changed(self, since: str, sha: str) -> set[str]:
        out = subprocess.run(["git", "diff", "--name-only", since, sha], check=True, capture_output=True, text=True).stdout
        return set(out.split())


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("--sha", required=True, help="the commit to be published, GITHUB_SHA")
    parser.add_argument("--ref", required=True, help="the branch or tag the workflow runs on, GITHUB_REF")
    parser.add_argument("--start", action="store_true", help="start a pass on --ref when none has run on the commit, or run a cancelled one again")
    parser.add_argument("--minutes", type=float, default=280, help="how long to wait for a pass that runs")
    parser.add_argument("--repository", default=os.environ.get("GITHUB_REPOSITORY", ""), help="OWNER/NAME")
    parser.add_argument("--summary", help="a Markdown file to add the outcome to")
    args = parser.parse_args(argv[1:])

    outcome = wait(GitHub(args.repository), Checkout(), args.sha, args.ref, args.start, args.minutes)
    line = outcome.message + (f": {outcome.url}" if outcome.url else "")
    print(f"::{'notice' if outcome.passed else 'error'}::{line}")
    if args.summary:
        with open(args.summary, "a") as out:
            link = f" ([the run]({outcome.url}))" if outcome.url else ""
            out.write(f"## Full test pass\n\n{outcome.message}{link}.\n")
    return 0 if outcome.passed else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv))
