#!/usr/bin/env python3
"""Check that the Full test pass runs every test of the repository, and publishes nothing.

The Full test pass (.github/workflows/full-pass.yml) calls each workflow that
tests a part of the project with `full: true`. It runs on main, not on pull
requests: this check, in the CI's Workflow audit, is what fails a pull request
that would leave a test out of it, stop it from starting, or let it publish:

- it calls every workflow that runs on pull requests, but the ones in
  NOT_TESTS, and the ones in ALSO_TESTS, each with `full: true`;
- each workflow it calls takes the boolean input `full` from `workflow_call`,
  and every input its test jobs read is one of its workflow_call inputs: an
  input the pass does not give reads as empty, and would skip a step or a job;
- every secret its test jobs read is passed by the call, as a called workflow
  has none of the repository's secrets but those its call passes, unless the
  pass does not need it (UNNEEDED_SECRETS);
- each job that can write or deploy, which the pass must skip, says so in its
  condition with `!inputs.full`;
- each call is granted what its workflow's jobs ask for: GitHub checks that,
  skipped jobs included, before it starts the pass;
- no two of the workflows it calls keep an artifact under the same name, since
  the pass is one run;
- its verdict (verdict.py) waits for every call, whatever their results;
- every job of the repository that publishes a release waits, directly or
  through the jobs it needs, for the pass of its commit (wait_for_pass.py).

usage: wiring.py [REPOSITORY_ROOT]
"""

from __future__ import annotations

import re
import sys
from dataclasses import dataclass
from pathlib import Path

PASS = "full-pass.yml"

# Workflows that run on pull requests but test nothing of the project.
NOT_TESTS = {
    "covers.yml": "asks IGDB for the catalog's covers, for a pull request to commit",
}

# Workflows that do not run on pull requests, yet test a part of the project.
ALSO_TESTS = {
    "site.yml": "the showcase page with the download links of the releases as they are",
}

# Secrets that test jobs read, and that the pass need not pass them.
UNNEEDED_SECRETS = {
    "MAC_RUNNER_TOKEN": "route.py sends no job of a workflow another calls to Ad's Mac: it picks GitHub's Macs "
                        "before it reads the token that finds Ad's",
}

LEVELS = {"none": 0, "read": 1, "write": 2}
LEVEL_NAMES = {value: name for name, value in LEVELS.items()}

INPUT = re.compile(r"\binputs\.([A-Za-z_][A-Za-z0-9_-]*)")
SECRET = re.compile(r"\bsecrets\.([A-Za-z_][A-Za-z0-9_]*)")


def load_yaml(path: Path):
    import yaml

    return yaml.safe_load(path.read_text())


def triggers(workflow: dict) -> dict:
    """The workflow's events, as a dict whatever form `on` takes."""
    # PyYAML reads the key "on" as True.
    on = workflow.get("on", workflow.get(True))
    if isinstance(on, str):
        return {on: None}
    if isinstance(on, list):
        return dict.fromkeys(on)
    return on or {}


def condition(job: dict) -> str:
    return str(job.get("if", ""))


def permissions(value) -> dict[str, str]:
    """A permissions block as scope: level, whatever form it takes."""
    if value is None:
        return {}
    if isinstance(value, str):
        level = {"write-all": "write", "read-all": "read"}.get(value, "none")
        return {scope: level for scope in ("actions", "contents", "id-token", "packages", "pull-requests", "statuses")}
    return {scope: str(level) for scope, level in value.items()}


def writes(job: dict) -> bool:
    """Whether a job can write to the repository or deploy: the pass skips it."""
    return "write" in permissions(job.get("permissions")).values() or "environment" in job


def pull_request_only(job: dict) -> bool:
    """A job that runs for pull requests alone, such as the memo of an earlier run."""
    return "github.event_name == 'pull_request'" in condition(job)


def may_skip(job: dict) -> bool:
    """Whether the pass may skip a job: one that writes or deploys, or one of pull requests alone."""
    return writes(job) or pull_request_only(job)


def strings(value):
    """Every string in a YAML value."""
    if isinstance(value, str):
        yield value
    elif isinstance(value, dict):
        for key, item in value.items():
            yield from strings(key)
            yield from strings(item)
    elif isinstance(value, list):
        for item in value:
            yield from strings(item)


def inputs_read(value) -> set[str]:
    return {match for text in strings(value) for match in INPUT.findall(text)}


def secrets_read(value) -> set[str]:
    """The secrets a value reads, but the token every workflow has."""
    return {match for text in strings(value) for match in SECRET.findall(text)} - {"GITHUB_TOKEN"}


def call_inputs(workflow: dict) -> dict:
    call = triggers(workflow).get("workflow_call") or {}
    return call.get("inputs") or {}


def job_name(key: str, job: dict) -> str:
    return str(job.get("name", key))


def runs(job: dict, text: str) -> bool:
    return any(text in str(step.get("run", "")) for step in job.get("steps") or [])


def needs(job: dict) -> list[str]:
    value = job.get("needs") or []
    return [value] if isinstance(value, str) else list(value)


@dataclass(frozen=True)
class Call:
    key: str
    name: str
    workflow: str
    job: dict


def calls(full_pass: dict) -> list[Call]:
    """The jobs of the pass that call a workflow of this repository."""
    found = []
    for key, job in (full_pass.get("jobs") or {}).items():
        uses = job.get("uses")
        if isinstance(uses, str) and uses.startswith("./.github/workflows/"):
            found.append(Call(key, job_name(key, job), uses.removeprefix("./.github/workflows/"), job))
    return found


def workflows(root: Path) -> dict[str, dict]:
    return {path.name: load_yaml(path) for path in sorted((root / ".github/workflows").glob("*.yml"))}


def tested(all_workflows: dict[str, dict]) -> set[str]:
    """The workflows the pass must call."""
    on_pull_requests = {name for name, workflow in all_workflows.items() if "pull_request" in triggers(workflow)}
    return (on_pull_requests - set(NOT_TESTS)) | set(ALSO_TESTS)


def check(root: Path) -> list[str]:
    """What is wrong with the pass's wiring, one sentence each: nothing when it is right."""
    every = workflows(root)
    if PASS not in every:
        return [f".github/workflows/{PASS} is missing"]
    full_pass = every[PASS]
    problems = []
    if "pull_request" in triggers(full_pass):
        problems.append(f"{PASS} runs on pull requests: it is meant for main, and checked here instead")

    called = calls(full_pass)
    names = [call.workflow for call in called]
    for name in sorted(tested(every) - set(names)):
        problems.append(f"{PASS} does not call {name}, which tests a part of the project")
    for name in sorted(set(names) - tested(every)):
        if name in every:
            problems.append(f"{PASS} calls {name}, which tests nothing: add it to ALSO_TESTS with why, or drop the call")
    for name in sorted({name for name in names if names.count(name) > 1}):
        problems.append(f"{PASS} calls {name} more than once")

    artifacts: dict[str, str] = {}
    for call in called:
        workflow = every.get(call.workflow)
        if workflow is None:
            problems.append(f"{PASS} calls {call.workflow}, which does not exist")
            continue
        if (call.job.get("with") or {}).get("full") is not True:
            problems.append(f"{PASS} calls {call.workflow} without `full: true`")
        declared = call_inputs(workflow)
        full = declared.get("full")
        if not isinstance(full, dict) or full.get("type") != "boolean" or full.get("default", False) is not False:
            problems.append(f"{call.workflow} does not take the boolean input `full`, false unless given, from workflow_call")
        for key in sorted(set(call.job.get("with") or {}) - set(declared)):
            problems.append(f"{PASS} gives {call.workflow} the input `{key}`, which its workflow_call does not take")

        # What the pass evaluates for the whole workflow, then for each job it runs.
        whole = {key: workflow.get(key) for key in ("concurrency", "env", "defaults")}
        read, secrets = inputs_read(whole), secrets_read(whole)
        for key, job in (workflow.get("jobs") or {}).items():
            if writes(job) and "!inputs.full" not in condition(job):
                problems.append(f"{call.workflow}: the job {key} can write or deploy, and its condition lacks `!inputs.full`")
            if not may_skip(job):
                read |= inputs_read(job)
                secrets |= secrets_read(job)
            for step in job.get("steps") or []:
                if str(step.get("uses", "")).startswith("actions/upload-artifact@"):
                    artifact = str((step.get("with") or {}).get("name", ""))
                    owner = artifacts.setdefault(artifact, call.workflow)
                    if owner != call.workflow:
                        problems.append(f"{owner} and {call.workflow} both keep an artifact named {artifact!r}, in the pass's one run")
        for name in sorted(read - set(declared)):
            problems.append(f"{call.workflow} reads `inputs.{name}`, which its workflow_call does not take: in the pass it is empty")
        passed = call.job.get("secrets")
        if passed != "inherit":
            for name in sorted(secrets - set(passed or {}) - set(UNNEEDED_SECRETS)):
                problems.append(f"{call.workflow} reads `secrets.{name}`, which {PASS} does not pass it: in the pass it is empty")

        granted = permissions(call.job.get("permissions", full_pass.get("permissions")))
        wanted = [permissions(workflow.get("permissions"))]
        wanted += [permissions(job.get("permissions")) for job in (workflow.get("jobs") or {}).values()]
        for scope in sorted({scope for asked in wanted for scope in asked}):
            level = max(LEVELS.get(asked.get(scope, "none"), 0) for asked in wanted)
            if level > LEVELS.get(granted.get(scope, "none"), 0):
                problems.append(f"{PASS} grants {call.workflow} less than `{scope}: {LEVEL_NAMES[level]}`, "
                                "which one of its jobs asks for: the pass would not start")

    verdicts = [key for key, job in (full_pass.get("jobs") or {}).items() if runs(job, ".github/full-pass/verdict.py")]
    if len(verdicts) != 1:
        problems.append(f"{PASS} has {len(verdicts)} jobs that run verdict.py, not one")
    else:
        verdict = full_pass["jobs"][verdicts[0]]
        for call in called:
            if call.key not in needs(verdict):
                problems.append(f"the verdict of {PASS} does not wait for {call.key}")
        if "always()" not in condition(verdict):
            problems.append(f"the verdict of {PASS} runs only when every call passed: its condition needs `always()`")

    for name, workflow in every.items():
        jobs = workflow.get("jobs") or {}
        for key, job in jobs.items():
            if not runs(job, "gh release create"):
                continue
            seen, todo = set(), needs(job)
            while todo:
                need = todo.pop()
                if need in seen or need not in jobs:
                    continue
                seen.add(need)
                todo += needs(jobs[need])
            if not any(runs(jobs[need], ".github/full-pass/wait_for_pass.py") for need in seen):
                problems.append(f"{name}: the job {key} publishes a release without waiting for the full test pass of its commit")
    return problems


def main(argv: list[str]) -> int:
    root = Path(argv[1]) if len(argv) > 1 else Path(__file__).resolve().parents[2]
    problems = check(root)
    for problem in problems:
        print(problem, file=sys.stderr)
    if not problems:
        count = len(calls(load_yaml(root / ".github/workflows" / PASS)))
        print(f"The full test pass calls the {count} workflows that test, and every release waits for it")
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
