#!/usr/bin/env python3
"""Watches, from GitHub, the job route.py sent to Ad's Mac, and sends the
run back to GitHub's Macs when the Mac lost the job or does not take it
(.github/mac/README.md). It runs beside the job, in the same run.

The run goes back to GitHub's Macs:

- when Ad's Mac is offline at 3 checks in a row, a minute, while its job
  waits for it or runs: it went to sleep, lost the network, or its
  supervisor stopped it;
- when the job has waited 20 minutes for the Mac (QUEUE_MINUTES), or as
  long as MAC_QUEUE_MINUTES says: the UI tests and screenshots wait 45, as
  long as the job before them takes on the Mac.

For that, it asks Mac rescue (mac-rescue.yml, from main) to run this run
again once it has ended, then cancels it: a run again goes to GitHub's Macs
(route.py). Without Mac rescue to ask, it cancels nothing.

It ends with the job, and does nothing else: a job that fails on the Mac
fails, as it would on GitHub's.

Environment: MAC_JOB (the job's name), MAC_LABELS, MAC_QUEUE_MINUTES
(optional), RUNNERS_TOKEN (MAC_RUNNER_TOKEN, which reads the runners),
GH_TOKEN (the run's token, which reads its jobs, cancels it and starts Mac
rescue), DEFAULT_BRANCH, and the run's GITHUB_* variables.
"""

from __future__ import annotations

import datetime
import os
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import api  # noqa: E402

CHECK_SECONDS = 20
OFFLINE_CHECKS = 3
QUEUE_MINUTES = 20
# The longest wait for the Mac and the job's timeout-minutes, together; the
# watch's job has a few minutes more (test_mac_side.py, WorkflowTests).
LONGEST_MINUTES = 150
# The Mac's job needs what the watch needs: it is in the run by the time the
# watch starts, unless the workflow names it otherwise than MAC_JOB.
MISSING_MINUTES = 5
WAITING = ("queued", "waiting", "pending", "requested")


def seconds(stamp: str | None) -> float | None:
    if not stamp:
        return None
    return datetime.datetime.fromisoformat(stamp.replace("Z", "+00:00")).timestamp()


def verdict(job: dict | None, offline: int, now: float, queue_minutes: float = QUEUE_MINUTES) -> tuple[str, str]:
    """("wait", "done" or "back", why) for the Mac's JOB, seen at NOW, when
    Ad's Mac was offline at the last OFFLINE checks."""
    if job is None:
        return "wait", "the job has not started to wait for a runner"
    if job.get("status") == "completed":
        return "done", f"the job ended: {job.get('conclusion')}"
    waiting = job.get("status") in WAITING
    if offline >= OFFLINE_CHECKS:
        return "back", "Ad's Mac went offline " + ("before it took the job" if waiting else "during the job")
    since = seconds(job.get("created_at"))
    if waiting and since is not None and now - since > queue_minutes * 60:
        return "back", f"Ad's Mac did not take the job in {queue_minutes:.0f} minutes"
    return "wait", "the job waits for Ad's Mac" if waiting else "the job runs on Ad's Mac"


def online(found: list[dict], job: dict | None, wanted: set[str]) -> bool:
    """Whether the runner the job runs on, or one that can take it, is online."""
    name = (job or {}).get("runner_name")
    if name and (job or {}).get("status") not in WAITING:
        return any(runner.get("name") == name and runner.get("status") == "online" for runner in found)
    return any(wanted <= api.labels(runner) and runner.get("status") == "online" for runner in found)


def back_to_github(env: dict, why: str) -> bool:
    """Asks Mac rescue to run this run again, then cancels it: whether it did."""
    repository, run = env["GITHUB_REPOSITORY"], env["GITHUB_RUN_ID"]
    token = env.get("GH_TOKEN", "")
    try:
        api.call("POST", f"/repos/{repository}/actions/workflows/mac-rescue.yml/dispatches", token,
                 {"ref": env.get("DEFAULT_BRANCH") or "main", "inputs": {"run": run}})
    except api.Error as error:
        print(f"::warning::{why}, but Mac rescue could not be started, so the run stays as it is: {error}")
        return False
    api.summary(f"Back to GitHub's Macs: {why}. Mac rescue runs this run again once it is cancelled.")
    api.call("POST", f"/repos/{repository}/actions/runs/{run}/cancel", token)
    return True


def watch(env: dict, clock=time.time, sleep=time.sleep) -> str:
    repository, run = env["GITHUB_REPOSITORY"], env["GITHUB_RUN_ID"]
    attempt = env.get("GITHUB_RUN_ATTEMPT", "1")
    name = env.get("MAC_JOB", "")
    wanted = {label.strip() for label in env.get("MAC_LABELS", "").split(",") if label.strip()} | {"cartouche-mac"}
    queue_minutes = float(env.get("MAC_QUEUE_MINUTES") or QUEUE_MINUTES)
    started = clock()
    offline = 0
    said = ""
    stuck = False  # Mac rescue could not be started: the run stays as it is
    while clock() - started < LONGEST_MINUTES * 60:
        try:
            jobs = api.call("GET", f"/repos/{repository}/actions/runs/{run}/attempts/{attempt}/jobs?per_page=100",
                            env.get("GH_TOKEN", "")).get("jobs", [])
            job = next((j for j in jobs if j.get("name") == name), None)
            if job is None and clock() - started > MISSING_MINUTES * 60:
                return f"this run has no job named {name!r}"
            if job is not None and job.get("status") != "completed" and env.get("RUNNERS_TOKEN"):
                up = online(api.runners(repository, env["RUNNERS_TOKEN"]), job, wanted)
                offline = 0 if up else offline + 1
            action, why = verdict(job, offline, clock(), queue_minutes)
        except (api.Error, KeyError, ValueError) as error:
            action, why = "wait", f"GitHub did not answer ({error})"
        if why != said:
            print(f"{datetime.datetime.now(datetime.timezone.utc):%H:%M:%S} {why}", flush=True)
            said = why
        if action == "done":
            return why
        if action == "back" and not stuck:
            if back_to_github(env, why):
                return why
            stuck = True
        sleep(CHECK_SECONDS)
    return "the watch ran out of time"


def main() -> int:
    try:
        api.summary(f"Watch of Ad's Mac: {watch(dict(os.environ))}.")
    except Exception as error:  # noqa: BLE001 - a watch that fails must not fail the run
        print(f"::warning::the watch of Ad's Mac stopped: {error}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
