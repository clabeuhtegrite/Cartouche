#!/usr/bin/env python3
"""List the branches of this repository that are no longer in use, and why.

The Branches workflow lists the repository's branches and pull requests with
GitHub's API, one JSON object per line, and runs this on them with the
SideStore source of main. It prints the branches to delete, one per line: the
commit the branch is at, a space, then its name. It deletes nothing itself:
the workflow's second job deletes each branch only if it is still at that
commit, so that a push made since keeps it.

A branch is deleted when:

- it is the head of a pull request that is closed, merged or not, and is
  still at the commit that pull request ended on: the pull request keeps
  those commits, and Restore branch on its page brings the branch back;
- it is release/v<version>, and main's SideStore source lists that version
  or a later one: its release was merged, or a later one replaced it;
- a workflow made it for another branch (launcher-screens/<branch>,
  builder-screens/<branch>, catalog-covers/<branch>), and that branch is gone
  or goes.

Every other branch stays: the default branch, the branches something reads,
the head of an open pull request, and a branch with commits that no pull
request ended on, which is work in progress that only its author deletes.

usage: clean_branches.py BRANCHES PULLS SOURCE --default BRANCH
                         [--repository OWNER/NAME] [--summary FILE]
"""

from __future__ import annotations

import argparse
import json
import re
import sys
from dataclasses import dataclass
from pathlib import Path

# The branches something reads, and what reads them.
READ = {
    "gh-pages": "the showcase site, which GitHub Pages serves (site.yml)",
    "live-covers": "the covers Cartouche reads every day (live-covers.yml)",
}

# The branches a workflow keeps for another branch: <prefix><that branch>.
MADE_FOR = ("launcher-screens/", "builder-screens/", "catalog-covers/")

RELEASE = re.compile(r"release/v(\d+)\.(\d+)\.(\d+)")
VERSION = re.compile(r"(\d+)\.(\d+)\.(\d+)")


@dataclass(frozen=True)
class Pull:
    number: int
    open: bool
    merged: bool
    ref: str
    sha: str


@dataclass(frozen=True)
class Verdict:
    branch: str
    sha: str
    delete: bool
    reason: str


def version_name(version: tuple[int, ...]) -> str:
    return ".".join(map(str, version))


def judge(branch: str, sha: str, pulls: list[Pull], latest: tuple[int, ...] | None, default: str) -> Verdict:
    """The verdict on a branch that no workflow made for another one."""
    def keep(reason: str) -> Verdict:
        return Verdict(branch, sha, False, reason)

    def delete(reason: str) -> Verdict:
        return Verdict(branch, sha, True, reason)

    if branch == default:
        return keep("the default branch")
    if branch in READ:
        return keep(READ[branch])
    heads = [pull for pull in pulls if pull.ref == branch]
    opened = sorted(pull.number for pull in heads if pull.open)
    if opened:
        return keep("the head of " + ", ".join(f"#{number}" for number in opened) + ", open")
    ended = [pull for pull in heads if pull.sha == sha]
    if ended:
        last = max(ended, key=lambda pull: pull.number)
        return delete(f"merged in #{last.number}" if last.merged else f"#{last.number}, closed without being merged")
    release = RELEASE.fullmatch(branch)
    if release and latest is not None and tuple(map(int, release.groups())) <= latest:
        return delete(f"main's SideStore source lists {version_name(latest)}")
    if heads:
        last = max(heads, key=lambda pull: pull.number)
        return keep(f"commits since #{last.number} ended")
    return keep("commits that no pull request has")


def plan(branches: dict[str, str], pulls: list[Pull], versions: list[tuple[int, ...]], default: str) -> list[Verdict]:
    """A verdict on each branch, by name."""
    latest = max(versions, default=None)
    verdicts = {
        branch: judge(branch, sha, pulls, latest, default)
        for branch, sha in branches.items()
        if not branch.startswith(MADE_FOR)
    }
    for branch, sha in branches.items():
        prefix = next((prefix for prefix in MADE_FOR if branch.startswith(prefix)), None)
        if prefix is None:
            continue
        source = branch[len(prefix):]
        made = verdicts.get(source)
        if made is None:
            verdicts[branch] = Verdict(branch, sha, True, f"made for {source}, which is gone")
        elif made.delete:
            verdicts[branch] = Verdict(branch, sha, True, f"made for {source}, which goes")
        else:
            verdicts[branch] = Verdict(branch, sha, False, f"made for {source}, which stays")
    return [verdicts[branch] for branch in sorted(verdicts)]


def read_lines(path: Path) -> list[dict]:
    return [json.loads(line) for line in path.read_text().splitlines() if line.strip()]


def read_branches(path: Path) -> dict[str, str]:
    return {entry["name"]: entry["sha"] for entry in read_lines(path)}


def read_pulls(path: Path, repository: str | None) -> list[Pull]:
    """The pull requests whose head is a branch of this repository, not of a fork."""
    return [
        Pull(int(entry["number"]), entry["state"] == "open", bool(entry["merged"]), entry["ref"], entry["sha"])
        for entry in read_lines(path)
        if repository is None or (entry.get("repository") or "").lower() == repository.lower()
    ]


def read_versions(path: Path) -> list[tuple[int, ...]]:
    """The versions of the apps the SideStore source lists."""
    source = json.loads(path.read_text())
    versions = []
    for app in source.get("apps", []):
        for entry in app.get("versions", []):
            match = VERSION.fullmatch(str(entry.get("version", "")))
            if match:
                versions.append(tuple(map(int, match.groups())))
    return versions


def cell(text: str) -> str:
    return text.replace("|", "\\|")


def summary(verdicts: list[Verdict]) -> str:
    deleted = [verdict for verdict in verdicts if verdict.delete]
    kept = [verdict for verdict in verdicts if not verdict.delete]
    lines = [
        "## Branches",
        "",
        f"{len(verdicts)} branches: {len(deleted)} to delete if they are still at the commit below, {len(kept)} kept.",
        "",
    ]
    for title, group in (("To delete", deleted), ("Kept", kept)):
        if not group:
            continue
        lines += [f"### {title}", "", "| Branch | Commit | Why |", "| --- | --- | --- |"]
        lines += [f"| {cell(verdict.branch)} | {verdict.sha[:7]} | {cell(verdict.reason)} |" for verdict in group]
        lines.append("")
    return "\n".join(lines)


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("branches", type=Path, help="the branches, as JSON lines of name and sha")
    parser.add_argument("pulls", type=Path, help="the pull requests, as JSON lines of number, state, merged, ref, sha and repository")
    parser.add_argument("source", type=Path, help="main's app/sidestore-source.json")
    parser.add_argument("--default", required=True, help="the default branch")
    parser.add_argument("--repository", help="OWNER/NAME: pull requests from other repositories, forks, are left out")
    parser.add_argument("--summary", type=Path, help="a Markdown file to add the table of every branch to")
    args = parser.parse_args(argv[1:])

    verdicts = plan(read_branches(args.branches), read_pulls(args.pulls, args.repository),
                    read_versions(args.source), args.default)
    for verdict in verdicts:
        print(f"{'delete' if verdict.delete else 'keep  '} {verdict.branch}: {verdict.reason}", file=sys.stderr)
        if verdict.delete:
            print(f"{verdict.sha} {verdict.branch}")
    if args.summary:
        with args.summary.open("a") as out:
            out.write(summary(verdicts) + "\n")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
