#!/usr/bin/env python3
"""Runs again, on GitHub's Macs, a run whose job Ad's Mac lost or did not
take in time (.github/mac/README.md). Mac rescue (mac-rescue.yml) runs it
from main, for the run the job's watch (watch.py) named before it cancelled
it: it waits for that run to end, then runs it again, and a run again goes
to GitHub's Macs (route.py).

It runs nothing again when the run is not one that route.py sends to the
Mac (App or Launcher screens, of a pull request or of the Actions tab, at
its first attempt), when the run ended otherwise than cancelled, or when a
newer run of its workflow and branch replaced it: run again, the old one
would cancel the new one, which shares its concurrency group.

Environment: RUN (the run's ID), GH_TOKEN (the token of Mac rescue's own
run), GITHUB_REPOSITORY.
"""

from __future__ import annotations

import os
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import api  # noqa: E402
from job_started import EVENTS  # noqa: E402
from route import WORKFLOWS  # noqa: E402

WAIT_MINUTES = 15


def refusal(run: dict, repository: str) -> str:
    """Why RUN is not one to run again; empty when it is."""
    path = (run.get("path") or "").split("@")[0]
    if path not in WORKFLOWS:
        return f"it is a run of {path or 'an unknown workflow'}, which never goes to Ad's Mac"
    if run.get("event") not in EVENTS:
        return f"it is a run of a {run.get('event')!r} event, which never goes to Ad's Mac"
    if (run.get("head_repository") or {}).get("full_name", "").lower() != repository.lower():
        return "it is a run of a fork, which never goes to Ad's Mac"
    if run.get("run_attempt") != 1:
        return f"it is at attempt {run.get('run_attempt')}, on GitHub's Macs already"
    return ""


def rescue(env: dict, clock=time.time, sleep=time.sleep) -> str:
    repository, token = env["GITHUB_REPOSITORY"], env.get("GH_TOKEN", "")
    number = env.get("RUN", "").strip()
    if not number.isdigit():
        return f"{number!r} is not the ID of a run"
    run = api.call("GET", f"/repos/{repository}/actions/runs/{number}", token)
    why = refusal(run, repository)
    if why:
        return f"nothing run again: {why}"
    started = clock()
    while run.get("status") != "completed":
        if clock() - started > WAIT_MINUTES * 60:
            return f"nothing run again: the run did not end in {WAIT_MINUTES} minutes"
        sleep(10)
        run = api.call("GET", f"/repos/{repository}/actions/runs/{number}", token)
    if run.get("conclusion") != "cancelled":
        return f"nothing run again: the run ended {run.get('conclusion')}"
    newer = api.call("GET", f"/repos/{repository}/actions/workflows/{run['workflow_id']}/runs"
                            f"?branch={run.get('head_branch')}&event={run.get('event')}&per_page=5", token)
    latest = max(newer.get("workflow_runs", []), key=lambda r: r.get("created_at", ""), default=run)
    if latest.get("id") != run.get("id"):
        return f"nothing run again: run {latest.get('id')} replaced it"
    api.call("POST", f"/repos/{repository}/actions/runs/{number}/rerun", token)
    return f"run {number} runs again, on GitHub's Macs"


def main() -> int:
    try:
        said = rescue(dict(os.environ))
    except api.Error as error:
        print(f"::error::{error}")
        return 1
    api.summary(f"Mac rescue: {said}.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
