#!/usr/bin/env python3
"""Check that main's ruleset requires only checks that every pull request reports.

A required check that no workflow reports on a pull request, because its job
was renamed or its workflow only runs for some paths, would block every pull
request into main. Each context in .github/rulesets/main.json must be the name
of a job in a workflow that runs on every pull request.

usage: check_rulesets.py [REPOSITORY_ROOT]
"""

from __future__ import annotations

import json
import sys
from pathlib import Path

import yaml


def pull_request_jobs(workflows: Path) -> set[str]:
    names = set()
    for path in sorted(workflows.glob("*.yml")):
        workflow = yaml.safe_load(path.read_text())
        # PyYAML reads the key "on" as True.
        triggers = workflow.get("on", workflow.get(True))
        if isinstance(triggers, str):
            triggers = {triggers: None}
        elif isinstance(triggers, list):
            triggers = dict.fromkeys(triggers)
        if "pull_request" not in (triggers or {}):
            continue
        filters = triggers["pull_request"] or {}
        if any(key in filters for key in ("paths", "paths-ignore", "branches", "branches-ignore")):
            continue
        for key, job in workflow.get("jobs", {}).items():
            names.add(job.get("name", key))
    return names


def main(argv: list[str]) -> int:
    root = Path(argv[1]) if len(argv) > 1 else Path(__file__).resolve().parents[2]
    ruleset = json.loads((root / ".github/rulesets/main.json").read_text())
    required = [
        check["context"]
        for rule in ruleset["rules"]
        if rule["type"] == "required_status_checks"
        for check in rule["parameters"]["required_status_checks"]
    ]
    reported = pull_request_jobs(root / ".github/workflows")
    missing = [context for context in required if context not in reported]
    for context in missing:
        print(f"main.json requires {context!r}, which no workflow reports on every pull request", file=sys.stderr)
    if not required:
        print("main.json requires no check", file=sys.stderr)
        return 1
    if not missing:
        print(f"main.json requires {len(required)} checks, all reported on every pull request")
    return 1 if missing else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
