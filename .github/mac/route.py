#!/usr/bin/env python3
"""Picks where a job that needs a Mac runs: on Ad's Mac when it can take it
now, on GitHub's otherwise (.github/mac/README.md). The first jobs of the App
and Launcher screens workflows run it, and their Mac job runs on what it
says (runs-on: fromJSON(needs.route.outputs.runner)).

Ad's Mac takes the job when:

- the job is one the Mac's hook runs (job_started.allowed()): a pull request
  from one of this repository's branches by its owner, or a run from the
  Actions tab; never a fork's pull request, which has no secret either;
- the run is one of App or Launcher screens itself, which Mac rescue can
  run again (rescue.py), never one of a workflow that calls them;
- MAC_RUNNER_TOKEN, which reads the repository's runners, is set;
- the run is at its first attempt: a run again, which the job's watch asks
  for when the Mac lost the job (watch.py), goes to GitHub;
- a runner with all the labels of MAC_LABELS (the Mac's runner of builds
  or of screenshots, its Xcode, its simulators) is online, and idle, or busy
  with no other job waiting for it: on each, one job runs and one waits, at
  most.

Anything else, an error of GitHub's API included, sends the job to GitHub's
Macs, where it ran before Ad's Mac.

Environment: MAC_LABELS, MAC_JOB (the job's name, for the summary),
RUNNERS_TOKEN (MAC_RUNNER_TOKEN), GH_TOKEN (the run's token, which reads its
jobs), and the run's GITHUB_* variables.
Outputs: runner, the job's runs-on as JSON; mac, true or false.
"""

from __future__ import annotations

import json
import os
import sys
from pathlib import Path
from typing import Callable

sys.path.insert(0, str(Path(__file__).resolve().parent))

import api  # noqa: E402
import job_started  # noqa: E402

GITHUB = "xcode-27"

# The workflows whose Mac job goes to Ad's Mac, and that Mac rescue runs
# again.
WORKFLOWS = (".github/workflows/app.yml", ".github/workflows/screens.yml")

# What a job waiting for a runner can be, in the API.
WAITING = ("queued", "waiting", "pending", "requested")


def pick(found: list[dict], wanted: set[str], waiting_for_mac: Callable[[], int]) -> tuple[dict | None, str]:
    """The runner of FOUND that takes the job, and why; None for GitHub's
    Macs. WAITING_FOR_MAC counts the jobs waiting for the Mac, asked only
    when the Mac is busy."""
    macs = [runner for runner in found if "cartouche-mac" in api.labels(runner)]
    matching = [runner for runner in macs if wanted <= api.labels(runner)]
    if not matching:
        if macs:
            missing = min((sorted(wanted - api.labels(runner)) for runner in macs), key=len)
            return None, f"Ad's Mac has no {', '.join(missing)}: install it there, then run install.sh again"
        return None, "no runner of Ad's Mac is registered"
    online = [runner for runner in matching if runner.get("status") == "online"]
    if not online:
        return None, "Ad's Mac is offline: asleep, away, low on battery or paused"
    idle = [runner for runner in online if not runner.get("busy")]
    if idle:
        return idle[0], "Ad's Mac is free"
    waiting = waiting_for_mac()
    if waiting == 0:
        return online[0], "Ad's Mac is busy, with no other job waiting for it: this one is next"
    return None, f"Ad's Mac is busy, with {waiting} more job{'s' if waiting > 1 else ''} waiting for it"


def waiting_for_mac(repository: str, token: str, wanted: frozenset = frozenset({"cartouche-mac"})) -> int:
    """The jobs of the repository's runs that wait for a runner of Ad's Mac
    with all the labels WANTED: the builds' or the screenshots'."""
    count = 0
    for status in ("queued", "in_progress"):
        runs = api.call("GET", f"/repos/{repository}/actions/runs?status={status}&per_page=30", token)
        for run in runs.get("workflow_runs", []):
            jobs = api.call("GET", f"/repos/{repository}/actions/runs/{run['id']}/jobs?per_page=100", token)
            count += sum(1 for job in jobs.get("jobs", [])
                         if job.get("status") in WAITING and set(wanted) <= set(job.get("labels", [])))
    return count


def route(env: dict, event: dict) -> tuple[dict | None, str]:
    """The runner of Ad's Mac for this run's job, and why; None for GitHub's."""
    repository = env["GITHUB_REPOSITORY"]
    ok, why = job_started.allowed(repository, [env.get("GITHUB_REPOSITORY_OWNER", "")], env, event)
    if not ok:
        return None, f"Ad's Mac would not take it: {why}"
    # owner/repository/.github/workflows/app.yml@refs/pull/1/merge: the
    # calling workflow's, when another calls this one.
    workflow = env.get("GITHUB_WORKFLOW_REF", "").split("@")[0]
    if not workflow.lower().startswith(repository.lower() + "/") or workflow[len(repository) + 1:] not in WORKFLOWS:
        return None, f"it is a run of {workflow or 'an unknown workflow'}, which Mac rescue could not run again"
    if not env.get("RUNNERS_TOKEN"):
        return None, "the repository has no MAC_RUNNER_TOKEN secret"
    if env.get("GITHUB_RUN_ATTEMPT", "1") != "1":
        return None, "a run again goes to GitHub's Macs"
    wanted = {label.strip() for label in env.get("MAC_LABELS", "").split(",") if label.strip()}
    found = api.runners(repository, env["RUNNERS_TOKEN"])
    wanted |= {"cartouche-mac"}
    return pick(found, wanted, lambda: waiting_for_mac(repository, env.get("GH_TOKEN", ""), frozenset(wanted)))


def main() -> int:
    env = dict(os.environ)
    try:
        with open(env["GITHUB_EVENT_PATH"]) as file:
            runner, why = route(env, json.load(file))
    except Exception as error:  # noqa: BLE001 - GitHub's Macs, whatever went wrong
        runner, why = None, f"choosing failed ({error})"
    job = env.get("MAC_JOB", "The Mac job")
    if runner is None:
        api.output(runner=json.dumps(GITHUB), mac="false")
        api.summary(f"{job} runs on GitHub's Macs ({GITHUB}): {why}.")
    else:
        labels = sorted({label.strip() for label in env.get("MAC_LABELS", "").split(",") if label.strip()} | {"cartouche-mac"})
        api.output(runner=json.dumps(["self-hosted", *labels]), mac="true")
        api.summary(f"{job} runs on Ad's Mac ({runner.get('name')}): {why}.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
