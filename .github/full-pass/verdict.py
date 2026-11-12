#!/usr/bin/env python3
"""Say whether the Full test pass ran every test job, and each one passed.

The pass's last job runs this once every call has ended, whatever their
results. A call's result is not enough by itself: a workflow whose test job
was skipped, by a condition the pass does not meet, still succeeds. This
reads the jobs of the run with GitHub's API, the latest try of each, and
fails when:

- a call did not succeed (NEEDS, the needs context as JSON);
- a job failed, was cancelled or did not end;
- a job was skipped that the pass must run: only the jobs that write or
  deploy, which the pass skips, and those of pull requests alone may be
  (wiring.may_skip);
- a job the pass must run is not in the run at all.

It writes each part's result to the run's summary.

usage: verdict.py --run-id ID --needs JSON [--repository OWNER/NAME]
                  [--root DIR] [--summary FILE]
"""

from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys
from dataclasses import dataclass, field
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import wiring  # noqa: E402

TEMPLATE = re.compile(r"\$\{\{.*?\}\}")


@dataclass(frozen=True)
class Expected:
    """A job of a called workflow, as the run names it: '<call> / <job>'."""

    call: str
    name: str
    may_skip: bool
    matrix: bool = False

    def matches(self, run_name: str) -> bool:
        # A matrix job's name has expressions, as 'Build for ${{ matrix.name }}'.
        pattern = ".+".join(re.escape(part) for part in TEMPLATE.split(self.name))
        if self.matrix:
            # GitHub adds each matrix job's values to a name that does not give them: 'Test (macOS, 27)'.
            pattern += r"(?: \(.+\))?"
        prefix = f"{self.call} / "
        if run_name.startswith(prefix):
            return re.fullmatch(pattern, run_name[len(prefix):]) is not None
        # Should GitHub ever name a called job without its call.
        return " / " not in run_name and re.fullmatch(pattern, run_name) is not None


@dataclass
class Verdict:
    problems: list[str] = field(default_factory=list)
    parts: list[tuple[str, str]] = field(default_factory=list)

    @property
    def passed(self) -> bool:
        return not self.problems


def expected_jobs(root: Path) -> list[Expected]:
    every = wiring.workflows(root)
    found = []
    for call in wiring.calls(every[wiring.PASS]):
        for key, job in (every[call.workflow].get("jobs") or {}).items():
            matrix = "matrix" in (job.get("strategy") or {})
            found.append(Expected(call.name, wiring.job_name(key, job), wiring.may_skip(job), matrix))
    return found


def judge(expected: list[Expected], calls: dict[str, str], needs: dict, jobs: list[dict], own: str) -> Verdict:
    """The verdict on a run: `calls` maps each call's key to its name, `jobs` are the API's."""
    verdict = Verdict()
    for key, name in calls.items():
        result = (needs.get(key) or {}).get("result", "missing")
        verdict.parts.append((name, result))
        if result != "success":
            verdict.problems.append(f"{name}: {result}")

    jobs = [job for job in jobs if job.get("name") != own]
    for job in jobs:
        name, status, conclusion = job.get("name", ""), job.get("status"), job.get("conclusion")
        known = [one for one in expected if one.matches(name)]
        if status != "completed":
            verdict.problems.append(f"{name} has not ended ({status})")
        elif conclusion == "skipped":
            if not known or not all(one.may_skip for one in known):
                verdict.problems.append(f"{name} was skipped: in the full test pass every test job runs")
        elif conclusion != "success":
            verdict.problems.append(f"{name}: {conclusion}")
    for one in expected:
        if not one.may_skip and not any(one.matches(job.get("name", "")) for job in jobs):
            verdict.problems.append(f"{one.call} / {one.name} is not in the run")
    return verdict


def summary(verdict: Verdict, url: str) -> str:
    lines = ["## Full test pass", ""]
    lines.append("Every test job ran and passed." if verdict.passed else "**Not passed**: no release can be published from this commit.")
    lines += ["", "| Part | Result |", "| --- | --- |"]
    lines += [f"| {name} | {'passed' if result == 'success' else result} |" for name, result in verdict.parts]
    if verdict.problems:
        lines += ["", "What went wrong:", ""]
        lines += [f"- {problem}" for problem in verdict.problems]
        lines += ["", f"Fix main, or [re-run the failed jobs]({url}) when a runner failed them rather than the code."]
    return "\n".join(lines)


def run_jobs(repository: str, run_id: str) -> list[dict]:
    out = subprocess.run(
        ["gh", "api", "--paginate", "--slurp", f"repos/{repository}/actions/runs/{run_id}/jobs?filter=latest&per_page=100"],
        check=True, capture_output=True, text=True,
    ).stdout
    return [job for page in json.loads(out) for job in page.get("jobs", [])]


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("--run-id", required=True, help="this run's ID, GITHUB_RUN_ID")
    parser.add_argument("--needs", required=True, help="the needs context, as JSON")
    parser.add_argument("--own", default="Every test passed", help="this job's name, left out of the jobs judged")
    parser.add_argument("--repository", default=os.environ.get("GITHUB_REPOSITORY", ""), help="OWNER/NAME")
    parser.add_argument("--root", type=Path, default=Path(__file__).resolve().parents[2], help="the repository's checkout")
    parser.add_argument("--summary", type=Path, help="a Markdown file to add the verdict to")
    args = parser.parse_args(argv[1:])

    full_pass = wiring.load_yaml(args.root / ".github/workflows" / wiring.PASS)
    calls = {call.key: call.name for call in wiring.calls(full_pass)}
    verdict = judge(expected_jobs(args.root), calls, json.loads(args.needs), run_jobs(args.repository, args.run_id), args.own)
    url = f"{os.environ.get('GITHUB_SERVER_URL', 'https://github.com')}/{args.repository}/actions/runs/{args.run_id}"
    if args.summary:
        with args.summary.open("a") as out:
            out.write(summary(verdict, url) + "\n")
    for problem in verdict.problems:
        print(f"::error::{problem}")
    if verdict.passed:
        print("Every test job of the full test pass ran and passed")
    return 0 if verdict.passed else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv))
