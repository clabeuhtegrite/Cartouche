#!/usr/bin/env python3
"""Sums up the game sessions Cartouche's telemetry received into the results
of the game sheets in catalog/games/, for the Game measurements workflow
(.github/workflows/measurements.yml), each week.

For each sheet, and each iPhone model at least three iPhones played the game
on in the last 28 days, one result: how the game ran, as the median of each
iPhone's own median so that each iPhone counts once however much it played,
how its sessions ended, and a status that follows from them
(telemetry/README.md#game-sheets). A model fewer iPhones played the game on
gets no result: the sheets show figures of several iPhones, never of one
(docs/privacy.md). The results testers wrote stay as they are; a measured
result is replaced by the model's new one, and kept while the model has none.

It reads the D1 database through Cloudflare's API, with the secrets
CLOUDFLARE_API_TOKEN and CLOUDFLARE_ACCOUNT_ID, and does nothing without
them. It writes the sheets that changed into --out, says what it found in the
job's summary, and sets the job's output changed to true or false.

    python3 telemetry/sheets.py --catalog catalog --out build/sheets

Python's standard library only.
"""

from __future__ import annotations

import argparse
import datetime as dt
import json
import os
import re
import statistics
import sys
import urllib.error
import urllib.parse
import urllib.request
from collections import Counter, defaultdict
from dataclasses import dataclass
from pathlib import Path

DATABASE = "cartouche-telemetry"
API = "https://api.cloudflare.com/client/v4"
# The models a sheet's result may name (catalog/schema/game.schema.json).
DEVICE = re.compile(r"^(iPhone|iPad)[0-9]+,[0-9]+$")

# A result needs this many iPhones of the model, and so does each of its
# figures.
MIN_IPHONES = 3
WINDOW_DAYS = 28
PAGE = 2000

# How a session ended badly (CartoucheGameLog.swift): it crashed, it never
# drew a frame, or iOS stopped it for its memory. "unknown" is a game the
# player closed as much as one iOS stopped without a word, and "quit" one
# the player quit behind the console, so neither counts.
ENDED_BADLY = {"crash": "crash", "memory-likely": "out of memory", "boot-failed": "did not start"}

# The status of a model's result:
#   does-not-run          no session drew a frame;
#   boots                 half of the sessions or more ended badly;
#   playable-with-issues  a tenth of them or more ended badly, or the median
#                         frame rate is under 90 % of the rate the game asks
#                         for, or that of the slowest 5 % of the time under
#                         75 % of it;
#   playable              otherwise.
BOOTS = 0.5
ISSUES = 0.1
ISSUES_FPS = 0.9
ISSUES_SLOWEST = 0.75

# The sessions one day received, a page at a time, with D1's parameters
# as text. A session sent again because its log grew is the same session
# with a higher seq.
SESSIONS = (
    "SELECT id, install, session, seq, day, device, ios, game, "
    "json_extract(body, '$.nxnative') AS nxnative, "
    "json_extract(body, '$.frames') AS frames, "
    "json_extract(body, '$.fps.median') AS fps, "
    "json_extract(body, '$.fps.low5') AS slowest, "
    "json_extract(body, '$.targetFps') AS target, "
    "json_extract(body, '$.stutters.perMinute') AS stutters, "
    "json_extract(body, '$.memory.peakMiB') AS peak, "
    "json_extract(body, '$.end.kind') AS ending "
    f"FROM reports WHERE kind = 'session' AND day = ?1 AND id > ?2 ORDER BY id LIMIT {PAGE}"
)


class Refused(Exception):
    """Cloudflare refused a call, or could not be reached."""


class Cloudflare:
    def __init__(self, account: str, token: str, base: str = API):
        self.base = f"{base}/accounts/{account}"
        self.token = token

    def call(self, method: str, path: str, body=None, query=None):
        url = self.base + path + ("?" + urllib.parse.urlencode(query) if query else "")
        request = urllib.request.Request(
            url, method=method, data=None if body is None else json.dumps(body).encode(),
            headers={"Authorization": f"Bearer {self.token}", "Content-Type": "application/json"})
        try:
            with urllib.request.urlopen(request, timeout=60) as response:
                answer = json.load(response)
        except urllib.error.HTTPError as error:
            try:
                answer = json.load(error)
            except ValueError:
                answer = {"errors": [{"code": error.code, "message": error.reason}]}
        except (urllib.error.URLError, OSError) as error:
            raise Refused(f"Cloudflare could not be reached for {method} {path}: {error}") from error
        if not isinstance(answer, dict) or answer.get("success") is not True:
            errors = answer.get("errors") if isinstance(answer, dict) else None
            words = "; ".join(f"{e.get('code')}: {e.get('message')}" for e in errors or []) or "no reason given"
            raise Refused(f"Cloudflare refused {method} {path}: {words}")
        return answer.get("result")

    def database(self, name: str) -> str:
        found = [d for d in self.call("GET", "/d1/database", query={"name": name}) or [] if d.get("name") == name]
        if not found:
            raise Refused(f"there is no D1 database {name}: the telemetry server is not deployed")
        return found[0]["uuid"]

    def query(self, database: str, sql: str, params: list) -> list[dict]:
        return self.call("POST", f"/d1/database/{database}/query", {"sql": sql, "params": params})[0]["results"]


def read_sessions(cloudflare: Cloudflare, database: str, first: dt.date, last: dt.date) -> list[dict]:
    """The sessions received from first to last, each once, at its highest seq."""
    sessions: dict[tuple[str, str], dict] = {}
    day = first
    while day <= last:
        after = ""
        while True:
            rows = cloudflare.query(database, SESSIONS, [day.isoformat(), after])
            for row in rows:
                key = (row["install"], row["session"])
                if key not in sessions or (row["seq"] or 0) > (sessions[key]["seq"] or 0):
                    sessions[key] = row
            if len(rows) < PAGE:
                break
            after = rows[-1]["id"]
        day += dt.timedelta(days=1)
    return list(sessions.values())


# MARK: Figures


def version(text: str) -> tuple[int, ...]:
    return tuple(int(part) for part in text.split(".") if part.isdigit())


def number(value) -> float | None:
    return float(value) if isinstance(value, (int, float)) and not isinstance(value, bool) else None


def drew_frames(session: dict) -> bool:
    """Whether the session got into the game: it drew a frame."""
    return (number(session.get("frames")) or 0) > 0 or number(session.get("fps")) is not None


def median(values: list[float]) -> float | None:
    """The median, when enough iPhones gave a value."""
    return statistics.median(values) if len(values) >= MIN_IPHONES else None


def rounded(value: float | None, digits: int = 1) -> float | int | None:
    if value is None:
        return None
    value = round(value, digits)
    return int(value) if value == int(value) else value


def shown(value: float) -> str:
    return f"{rounded(value):g}"


@dataclass
class IPhone:
    """One iPhone's sessions of the game."""

    sessions: list[dict]

    def values(self, key: str) -> list[float]:
        return [v for v in (number(s.get(key)) for s in self.sessions) if v is not None]

    def median(self, key: str) -> float | None:
        values = self.values(key)
        return statistics.median(values) if values else None

    @property
    def peak(self) -> float | None:
        """Its highest memory peak, of the sessions that drew a frame: one
        that ended before its first frame had loaded little of the game,
        and says nothing of what it needs. Cartouche reads a sheet's peak to
        choose where a game starts (docs/decisions.md, 48)."""
        values = [v for v in (number(s.get("peak")) for s in self.sessions if drew_frames(s)) if v is not None]
        return max(values) if values else None

    @property
    def ios(self) -> str:
        return max(self.sessions, key=lambda s: (s["day"], s["seq"] or 0))["ios"]


@dataclass
class Result:
    """A model's sessions of a game, summed up."""

    device: str
    iphones: list[IPhone]

    @property
    def sessions(self) -> list[dict]:
        return [s for phone in self.iphones for s in phone.sessions]

    def figure(self, key: str) -> float | None:
        return median([v for v in (phone.median(key) for phone in self.iphones) if v is not None])

    @property
    def target(self) -> int | None:
        targets = Counter(int(s["target"]) for s in self.sessions if number(s.get("target")))
        return max(targets.items(), key=lambda item: (item[1], item[0]))[0] if targets else None

    @property
    def ended_badly(self) -> Counter:
        return Counter(s["ending"] for s in self.sessions if s.get("ending") in ENDED_BADLY)

    @property
    def played(self) -> int:
        return sum(1 for s in self.sessions if drew_frames(s))

    @property
    def status(self) -> str:
        sessions = len(self.sessions)
        badly = sum(self.ended_badly.values()) / sessions
        target, fps, slowest = self.target, self.figure("fps"), self.figure("slowest")
        if self.played == 0:
            return "does-not-run"
        if badly >= BOOTS:
            return "boots"
        if badly >= ISSUES:
            return "playable-with-issues"
        if target and fps is not None and fps < ISSUES_FPS * target:
            return "playable-with-issues"
        if target and slowest is not None and slowest < ISSUES_SLOWEST * target:
            return "playable-with-issues"
        return "playable"

    @property
    def ios(self) -> str:
        versions = Counter(phone.ios for phone in self.iphones)
        return max(versions.items(), key=lambda item: (item[1], version(item[0])))[0]

    @property
    def engine(self) -> str:
        commits = Counter(s["nxnative"][:12] for s in self.sessions if s.get("nxnative"))
        if not commits:
            return "nxnative, its build not reported"
        commit = max(commits.items(), key=lambda item: (item[1], item[0]))[0]
        others = len(commits) - 1
        if not others:
            return f"nxnative {commit}"
        return f"nxnative {commit} and {others} other build{'s' if others > 1 else ''}"

    def note(self) -> str:
        sessions = self.sessions
        days = sorted(s["day"] for s in sessions)
        lead = (f"Measured by Cartouche on {len(self.iphones)} iPhones, "
                f"{len(sessions)} sessions from {days[0]} to {days[-1]}")
        running = []
        fps, slowest, stutters, target = self.figure("fps"), self.figure("slowest"), self.figure("stutters"), self.target
        if fps is not None:
            running.append(f"{shown(fps)} fps" + (f" for {target}" if target else "") + " (median)")
        if slowest is not None:
            running.append(f"{shown(slowest)} fps in the slowest 5% of the time")
        if stutters is not None:
            running.append(f"{shown(stutters)} stutters a minute")
        badly = self.ended_badly
        count = sum(badly.values())
        if count:
            kinds = ", ".join(
                f"{n} {'crash' + ('es' if n > 1 else '') if kind == 'crash' else ENDED_BADLY[kind]}"
                for kind, n in sorted(badly.items(), key=lambda item: (-item[1], item[0])))
            ending = f"{count} session{'s' if count > 1 else ''} ended badly: {kinds}."
        else:
            ending = "None ended badly."
        # The first parts that fit in the 300 letters a note may have.
        while running:
            text = f"{lead}: {', '.join(running)}. {ending}"
            if len(text) <= 300:
                return text
            running.pop()
        return f"{lead}. {ending}"[:300]

    def entry(self) -> dict:
        sessions = self.sessions
        days = sorted(s["day"] for s in sessions)
        entry = {
            "device": self.device,
            "iOS": self.ios,
            "date": days[-1],
            "engine": self.engine,
            "status": self.status,
        }
        peak = median([v for v in (phone.peak for phone in self.iphones) if v is not None])
        if peak is not None:
            entry["peakMemoryMiB"] = max(int(round(peak)), 1)
        entry["notes"] = [self.note()]
        measured = {"iPhones": len(self.iphones), "sessions": len(sessions), "from": days[0], "to": days[-1]}
        for key, value in (("fps", self.figure("fps")), ("slowestFps", self.figure("slowest")),
                           ("targetFps", self.target), ("stuttersPerMinute", self.figure("stutters"))):
            if value is not None:
                measured[key] = rounded(value)
        measured["endedBadlyPercent"] = rounded(100 * sum(self.ended_badly.values()) / len(sessions))
        entry["measured"] = measured
        return entry


def results(sessions: list[dict], sheet_of: dict[str, str],
            main_of: dict[str, str]) -> tuple[dict[str, list[Result]], dict[str, int], int]:
    """The results of each sheet; how many iPhones played each game without a
    sheet, for those that several did; how many models of a sheet's game too
    few iPhones played on."""
    phones: dict[tuple[str, str], dict[str, list[dict]]] = defaultdict(lambda: defaultdict(list))
    unsheeted: dict[str, set[str]] = defaultdict(set)
    for session in sessions:
        game = session.get("game")
        if not game or not DEVICE.match(session.get("device") or ""):
            continue
        sheet = sheet_of.get(game)
        if sheet is None:
            unsheeted[main_of.get(game, game)].add(session["install"])
            continue
        phones[(sheet, session["device"])][session["install"]].append(session)
    found: dict[str, list[Result]] = defaultdict(list)
    too_few = 0
    for (sheet, device), by_install in sorted(phones.items()):
        if len(by_install) < MIN_IPHONES:
            too_few += 1
            continue
        found[sheet].append(Result(device, [IPhone(by_install[i]) for i in sorted(by_install)]))
    several = {game: len(installs) for game, installs in sorted(unsheeted.items()) if len(installs) >= MIN_IPHONES}
    return found, several, too_few


def merged(sheet: dict, measured: list[Result]) -> dict:
    """The sheet with its measured results replaced by those measured now."""
    testers = [r for r in sheet["results"] if "measured" not in r]
    kept = {r["device"]: r for r in sheet["results"] if "measured" in r}
    kept.update({result.device: result.entry() for result in measured})
    return {**sheet, "results": testers + [kept[device] for device in sorted(kept)]}


def text(value) -> str:
    return json.dumps(value, indent=2, ensure_ascii=False) + "\n"


# MARK: The run


def run(catalog: Path, out: Path, today: dt.date, cloudflare: Cloudflare) -> tuple[list[str], list[str]]:
    """Writes the sheets that changed into out; returns their names, and the
    lines of the job's summary."""
    nxnative = json.loads((catalog / "nxnative.json").read_text(encoding="utf-8"))
    names = {game["titleId"]: game["name"] for game in nxnative["games"]}
    sheets = {path.stem: (path, json.loads(path.read_text(encoding="utf-8")))
              for path in sorted((catalog / "games").glob("*.json"))}
    # A copy of another region reports its own title ID.
    sheet_of: dict[str, str] = {}
    main_of: dict[str, str] = {}
    for game in nxnative["games"]:
        ids = [game["titleId"]] + [v["titleId"] for v in game.get("variants", [])]
        for i in ids:
            main_of.setdefault(i, game["titleId"])
        for sheet in (i for i in ids if i in sheets):
            for i in ids:
                sheet_of.setdefault(i, sheet)
    for sheet in sheets:
        sheet_of.setdefault(sheet, sheet)

    first, last = today - dt.timedelta(days=WINDOW_DAYS), today - dt.timedelta(days=1)
    database = cloudflare.database(DATABASE)
    sessions = read_sessions(cloudflare, database, first, last)
    found, several, too_few = results(sessions, sheet_of, main_of)

    changed = []
    lines = [f"## Game measurements, {first} to {last}", "",
             f"{len(sessions)} game sessions, from {len({s['install'] for s in sessions})} iPhones.", ""]
    if found:
        lines += ["| Game | Model | iPhones | Sessions | Status |", "| --- | --- | --- | --- | --- |"]
    for sheet_id, measured in sorted(found.items()):
        path, sheet = sheets[sheet_id]
        for result in measured:
            lines.append(f"| {sheet['name']} | {result.device} | {len(result.iphones)} | "
                         f"{len(result.sessions)} | {result.status} |")
        written = text(merged(sheet, measured))
        if written != path.read_text(encoding="utf-8"):
            out.mkdir(parents=True, exist_ok=True)
            (out / path.name).write_text(written, encoding="utf-8")
            changed.append(path.name)
    if found:
        lines.append("")
    if too_few:
        lines += [f"Left out: {too_few} model{'s' if too_few > 1 else ''} of a game with a sheet, "
                  f"played on fewer than {MIN_IPHONES} iPhones.", ""]
    if several:
        lines += [f"Played on {MIN_IPHONES} iPhones or more, with no sheet: " + ", ".join(
            f"{names[game]} ({game}, {count} iPhones)" if game in names else f"{game} ({count} iPhones)"
            for game, count in several.items()) + ".", ""]
    lines.append(f"Sheets changed: {', '.join(changed)}." if changed else "No sheet changed.")
    return changed, lines


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("--catalog", type=Path, default=Path("catalog"))
    parser.add_argument("--out", type=Path, required=True, help="where the sheets that changed are written")
    parser.add_argument("--today", type=dt.date.fromisoformat, default=dt.datetime.now(dt.timezone.utc).date(),
                        help="the day of the run, in UTC: the sessions of the 28 days before it count")
    args = parser.parse_args(argv)

    def output(changed: bool) -> None:
        if os.environ.get("GITHUB_OUTPUT"):
            with open(os.environ["GITHUB_OUTPUT"], "a", encoding="utf-8") as file:
                file.write(f"changed={'true' if changed else 'false'}\n")

    token, account = os.environ.get("CLOUDFLARE_API_TOKEN"), os.environ.get("CLOUDFLARE_ACCOUNT_ID")
    if not token or not account:
        print("::notice::CLOUDFLARE_API_TOKEN and CLOUDFLARE_ACCOUNT_ID are not set: no measurement was read.")
        output(False)
        return 0
    cloudflare = Cloudflare(account, token, os.environ.get("CLOUDFLARE_API") or API)
    try:
        changed, lines = run(args.catalog, args.out, args.today, cloudflare)
    except Refused as error:
        print(f"::error::{error}", file=sys.stderr)
        return 1
    print("\n".join(lines))
    if os.environ.get("GITHUB_STEP_SUMMARY"):
        with open(os.environ["GITHUB_STEP_SUMMARY"], "a", encoding="utf-8") as file:
            file.write("\n".join(lines) + "\n")
    output(bool(changed))
    return 0


if __name__ == "__main__":
    sys.exit(main())
