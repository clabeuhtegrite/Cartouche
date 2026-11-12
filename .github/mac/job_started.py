#!/usr/bin/python3
"""The runner's job started hook on Ad's Mac: it refuses every job but this
repository's own, before the job's first step (.github/mac/README.md).

A job runs on the Mac only when GitHub's own description of it says so: the
GITHUB_* variables the runner sets and the event it writes
(GITHUB_EVENT_PATH), which no workflow can change. The runner gives the hook
these and its own environment, never the workflow's env
(Runner.Worker/JobHookProvider.cs). The job must be:

- a run of this repository (config.json, which install.sh writes, root's);
- of a pull request from one of its own branches, or of a workflow started
  from its Actions tab;
- by its owner, who opened the pull request, started the run and, when it
  is a run again, ran it again.

Any other job fails here and runs nothing: one of a pull request from a
fork, even one whose workflow asks for this Mac; of Dependabot; of a push, a
schedule or a release, which stay on GitHub's Macs. The runner has only
downloaded the actions the job names by then.

route.py, which picks the Mac for a job, applies the same rules
(allowed()), so that it never sends the Mac a job it would refuse.
"""

from __future__ import annotations

import json
import os
import sys

CONFIG = "/Library/CartoucheCI/config.json"

# What the Mac takes: the builds and screenshots of pull requests, and the
# same from the Actions tab.
EVENTS = ("pull_request", "workflow_dispatch")


def lower(value) -> str:
    return value.lower() if isinstance(value, str) else ""


def allowed(repository: str, owners: list[str], env: dict, event: dict) -> tuple[bool, str]:
    """(True, why) when the job may run on the Mac, (False, why) else.
    REPOSITORY is owner/name, OWNERS the logins whose jobs it takes, ENV the
    job's GITHUB_* variables and EVENT the event they describe."""
    repository = lower(repository)
    owners = {lower(owner) for owner in owners if lower(owner)}
    if not repository or not owners:
        return False, "the Mac's configuration names no repository or owner"
    if lower(env.get("GITHUB_REPOSITORY")) != repository:
        return False, f"a job of {env.get('GITHUB_REPOSITORY')!r}, not of {repository}"
    name = env.get("GITHUB_EVENT_NAME", "")
    if name not in EVENTS:
        return False, f"a job of a {name!r} event: the Mac takes pull requests and the Actions tab's runs only"
    for variable in ("GITHUB_ACTOR", "GITHUB_TRIGGERING_ACTOR"):
        if lower(env.get(variable)) not in owners:
            return False, f"{variable} is {env.get(variable)!r}, not the repository's owner"
    if lower((event.get("sender") or {}).get("login")) not in owners:
        return False, f"the event's sender is {(event.get('sender') or {}).get('login')!r}"
    if lower((event.get("repository") or {}).get("full_name")) != repository:
        return False, "the event is of another repository"
    if name == "workflow_dispatch":
        return True, f"a run of {env.get('GITHUB_REPOSITORY')} started by {env.get('GITHUB_ACTOR')}"

    pull = event.get("pull_request") or {}
    head = (pull.get("head") or {}).get("repo") or {}
    base = (pull.get("base") or {}).get("repo") or {}
    if lower(base.get("full_name")) != repository:
        return False, "the pull request is into another repository"
    if lower(head.get("full_name")) != repository or head.get("id") is None or head.get("id") != base.get("id"):
        return False, f"the pull request comes from {head.get('full_name')!r}, a fork"
    author = (pull.get("user") or {}).get("login")
    if lower(author) not in owners:
        return False, f"the pull request is {author!r}'s, not the repository's owner's"
    branch = (pull.get("head") or {}).get("ref") or ""
    if branch.startswith("dependabot/"):
        return False, f"the pull request is Dependabot's ({branch})"
    return True, f"pull request #{pull.get('number')} of {env.get('GITHUB_REPOSITORY')}, from its branch {branch}"


def main() -> int:
    try:
        with open(CONFIG) as file:
            config = json.load(file)
        with open(os.environ["GITHUB_EVENT_PATH"]) as file:
            event = json.load(file)
        ok, why = allowed(config.get("repository", ""), config.get("owners", []), dict(os.environ), event)
    except Exception as error:  # noqa: BLE001 - anything unexpected refuses the job
        ok, why = False, f"the hook could not read the job: {error}"
    if ok:
        print(f"Ad's Mac takes this job: {why}.")
        return 0
    print(f"::error::This job does not run on Ad's Mac: {why}.")
    return 1


if __name__ == "__main__":
    sys.exit(main())
