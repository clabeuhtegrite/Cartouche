#!/usr/bin/env python3
"""Writes catalog/nxnative.json: every game nxnative has a profile for.

The launcher's catalogue lists each of them, the player's own copies first.
The list comes from nxnative's game profiles at the commit Cartouche pins
(catalog/nxnative.commit), fetched by catalog/tools/fetch_nxnative.sh:

- dm/games/<title ID>/game.tsv: the game's name, App Store category, and
  the profile's opening comment, which says where nxnative plays it;
- dm/games/README.md: the table of games, with the build, SDK and engine.

A release for another region with its own profile ("13 Sentinels: Aegis
Rim, Asian release") becomes a variant of the main release, and a program
of another title (the games inside Super Mario 3D All-Stars) is left out:
the player imports the application, not its programs.

The list holds names and facts about the profiles, never where to get a
game, as every catalog file (catalog/README.md).

usage: nxnative_games.py NXNATIVE [--out FILE | --check FILE]
"""

from __future__ import annotations

import argparse
import json
import re
import subprocess
import sys
from pathlib import Path

GENRES = {
    "action-games": "action",
    "adventure-games": "adventure",
    "board-games": "board",
    "card-games": "card",
    "family-games": "family",
    "music-games": "music",
    "puzzle-games": "puzzle",
    "racing-games": "racing",
    "role-playing-games": "rpg",
    "simulation-games": "simulation",
    "sports-games": "sports",
    "strategy-games": "strategy",
}

REGIONS = {"Asian": "asia", "Japanese": "japan", "Korean": "korea", "Chinese": "china"}

TABLE_ROW = re.compile(
    r"^\| \[(?P<name>[^\]]+)\]\((?P<id>[0-9A-F]{16})/README\.md\) \| `(?P=id)` \| "
    r"(?P<build>[^|]*) \| (?P<sdk>[^|]*) \| (?P<engine>[^|]*) \| (?P<graphics>[^|]*) \|$")
VARIANT = re.compile(r"^(?P<base>.+), (?P<region>" + "|".join(REGIONS) + r") release$")


def read_profile(path: Path) -> tuple[dict[str, str], str]:
    """A game.tsv's keys (first value of each) and its opening comment."""
    keys: dict[str, str] = {}
    comment: list[str] = []
    for line in path.read_text(encoding="utf-8").splitlines():
        if line.startswith("#"):
            # The opening comment runs until the first section heading.
            if not keys and not line.startswith("# ----"):
                comment.append(line[1:].strip())
            continue
        if not line.strip():
            continue
        name, _, value = line.partition("\t")
        keys.setdefault(name, value.split("\t")[0])
    return keys, " ".join(comment)


def status(comment: str) -> str:
    """Where nxnative says the game plays, from its profile's opening comment:
    "iphone", "mac", "bringup", or "unknown" when the comment does not say."""
    if re.search(r"\bon the iPhone\b|\bMac and (on )?(the )?iPhone\b|\bPlays on the iPhone\b", comment):
        return "iphone"
    if re.search(r"\b[Ii]n bring-up\b|\b[Bb]ring-up has just started\b", comment):
        return "bringup"
    if re.search(r"\bPlays on the Mac\b|\b(tested|played|brought up) on the Mac\b|\bon the Mac\b", comment):
        return "mac"
    return "unknown"


def read_table(readme: Path) -> dict[str, dict[str, str]]:
    rows = {}
    for line in readme.read_text(encoding="utf-8").splitlines():
        match = TABLE_ROW.match(line)
        if match:
            rows[match["id"]] = {k: match[k].strip() for k in ("name", "build", "sdk", "engine", "graphics")}
    return rows


def games(nxnative: Path) -> list[dict]:
    root = nxnative / "dm" / "games"
    table = read_table(root / "README.md")
    profiles = {}
    for tsv in sorted(root.glob("*/game.tsv")):
        title_id = tsv.parent.name
        keys, comment = read_profile(tsv)
        if keys.get("title_id", title_id).upper() != title_id:
            raise SystemExit(f"{tsv}: title_id {keys.get('title_id')} is not its folder's")
        if "program_of" in keys:
            continue
        row = table.get(title_id)
        if row is None:
            raise SystemExit(f"{title_id}: not in the table of {root / 'README.md'}")
        category = keys.get("app_category", "").removeprefix("public.app-category.")
        game = {
            "titleId": title_id,
            "name": keys.get("name") or row["name"],
            "platform": "switch2" if title_id.startswith("04") else "switch",
            "genre": GENRES.get(category, "other"),
            "status": status(comment),
            "engine": row["engine"],
            "build": row["build"],
            "sdk": row["sdk"],
        }
        profiles[title_id] = (row["name"], game)

    by_table_name = {name: game for name, game in profiles.values()}
    result = []
    for table_name, game in profiles.values():
        variant = VARIANT.match(table_name)
        main = by_table_name.get(variant["base"]) if variant else None
        if main is not None and main is not game:
            main.setdefault("variants", []).append({
                "titleId": game["titleId"],
                "region": REGIONS[variant["region"]],
                "build": game["build"],
            })
            continue
        result.append(game)
    for game in result:
        game.get("variants", []).sort(key=lambda v: v["titleId"])
    result.sort(key=lambda g: (g["name"].casefold(), g["titleId"]))
    return result


def document(nxnative: Path) -> str:
    commit = subprocess.run(["git", "-C", str(nxnative), "rev-parse", "HEAD"],
                            check=True, capture_output=True, text=True).stdout.strip()
    data = {"schema": 1, "nxnative": commit, "games": games(nxnative)}
    return json.dumps(data, indent=2, ensure_ascii=False) + "\n"


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("nxnative", type=Path, help="nxnative at the pinned commit")
    group = parser.add_mutually_exclusive_group()
    group.add_argument("--out", type=Path, help="write the list there")
    group.add_argument("--check", type=Path, help="fail unless this file is the list")
    args = parser.parse_args()

    text = document(args.nxnative)
    if args.check:
        if args.check.read_text(encoding="utf-8") != text:
            print(f"{args.check} is not nxnative's list at this commit: run "
                  f"catalog/tools/nxnative_games.py NXNATIVE --out {args.check}", file=sys.stderr)
            return 1
        print(f"{args.check}: {len(json.loads(text)['games'])} games, up to date")
        return 0
    if args.out:
        args.out.write_text(text, encoding="utf-8")
        print(f"{args.out}: {len(json.loads(text)['games'])} games")
    else:
        sys.stdout.write(text)
    return 0


if __name__ == "__main__":
    sys.exit(main())
