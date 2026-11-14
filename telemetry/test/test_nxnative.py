"""Checks telemetry/nxnative.py, the weekly page for nxnative's developers,
against a stand-in for Cloudflare's API (standin.py) whose D1 database holds
sessions and events as the Worker keeps them, made from the reports of
app-reports.json.

- a game three installs played gets a line, of the medians of each
  install's own; two installs make no line, and a figure fewer than three
  installs gave shows –; the peak is each install's highest, of its sessions
  that drew a frame;
- the sessions on iPhones without BC textures, those whose game process ran
  without Increased Memory Limit, and those of changed builds are set apart;
- the lines by model and by commit, the crashes and the builds by commit
  show only what three installs, or three Macs, share; a commit, a model or
  a step fewer share is never named;
- no install's, session's or report's number is ever written;
- a session sent again counts once, at its highest seq; only the 28 days
  before the run count; a copy of another region counts for its game;
- without the secrets, nothing is read.

Run from the repository root: python3 -m unittest discover -s telemetry/test -v
"""

import copy
import json
import shutil
import subprocess
import sys
import tempfile
import unittest
import uuid
from pathlib import Path

from standin import ACCOUNT, TOKEN, Cloudflare, environment, serve

HERE = Path(__file__).resolve().parent
PAGE = HERE.parent / "nxnative.py"
SCHEMA = HERE.parent / "schema.sql"
MKW = "0400C3F00006E000"
SENTINELS = "01003FC01670C000"
SENTINELS_JAPAN = "010045C014650000"
TODAY = "2026-11-12"
# The reading of the log from which the slowest 5% counts (sheets.SLOWEST_READER).
READER = 2
MKW_NAME = f"Mario Kart World `{MKW}`"

TEMPLATE = next(r for r in json.loads((HERE / "app-reports.json").read_text(encoding="utf-8"))["reports"]
                if r["kind"] == "session")

# The catalog of the tests: two games of nxnative's list, one with a copy of
# another region.
NXNATIVE = {"schema": 1, "nxnative": "0123456789abcdef0123456789abcdef01234567", "games": [
    {"titleId": SENTINELS, "name": "13 Sentinels: Aegis Rim", "platform": "switch", "genre": "rpg",
     "status": "bringup", "engine": "Vanillaware's engine", "build": "1.10", "sdk": "11.4.3",
     "variants": [{"titleId": SENTINELS_JAPAN, "region": "japan", "build": "1.00 (base)"}]},
    {"titleId": MKW, "name": "Mario Kart World", "platform": "switch2", "genre": "racing",
     "status": "iphone", "engine": "Nintendo's engine", "build": "1.0.0", "sdk": "20.0.0"},
]}


def schema_as_deployed() -> str:
    lines = SCHEMA.read_text(encoding="utf-8").splitlines()
    return "\n".join(line for line in lines if not line.lstrip().startswith("--"))


def tables(page: str, title: str) -> list[list[dict]]:
    """The tables of the page's section TITLE, each as its rows, each row
    as its cells by their column."""
    section = page.split(f"\n## {title}\n", 1)[1].split("\n## ", 1)[0]
    found, current = [], []
    for line in section.splitlines() + [""]:
        if line.startswith("|"):
            current.append([cell.strip() for cell in line.strip().strip("|").split("|")])
        elif current:
            found.append([dict(zip(current[0], row)) for row in current[2:]])
            current = []
    return found


def rows(page: str, title: str) -> list[dict]:
    found = tables(page, title)
    return found[0] if found else []


class NxnativePageTest(unittest.TestCase):
    def setUp(self):
        self.cloudflare = Cloudflare()
        self.cloudflare.databases.append({"uuid": "d1-0", "name": "cartouche-telemetry", "jurisdiction": "eu"})
        self.cloudflare.sql.executescript(schema_as_deployed())
        self.server = serve(self.cloudflare)
        self.addCleanup(self.cloudflare.sql.close)
        self.addCleanup(self.server.server_close)
        self.addCleanup(self.server.shutdown)
        self.work = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, self.work)
        self.catalog = self.work / "catalog"
        self.catalog.mkdir()
        (self.catalog / "nxnative.json").write_text(json.dumps(NXNATIVE, indent=2) + "\n", encoding="utf-8")
        self.phones = [str(uuid.uuid4()) for _ in range(12)]
        self.macs = [str(uuid.uuid4()) for _ in range(6)]
        self.ids = []

    # MARK: Helpers

    def session(self, install, day="2026-11-10", device="iPhone19,4", game=MKW, session=None, seq=1, **fields):
        """A session as the Worker keeps it: the fixture's, with these fields."""
        report = copy.deepcopy(TEMPLATE)
        report.update(id=str(uuid.uuid4()), install=install, device=device, game=game, seq=seq,
                      session=session or str(uuid.uuid4()), end={"kind": "unknown"}, reader=READER)
        for key, value in fields.items():
            if value is None:
                report.pop(key, None)
            else:
                report[key] = value
        self.insert(report, day)
        return report

    def event(self, install, name, day="2026-11-10", device="Mac16,12", ios="27.1", seq=1, limit=None, iml=None,
              game=None, **fields):
        """An event as the Worker keeps it."""
        report = {"schema": 1, "kind": "event", "id": str(uuid.uuid4()), "install": install, "seq": seq,
                  "cartouche": "0.11.2", "device": device, "ios": ios, "language": "en", "name": name,
                  "fields": fields}
        if game:
            report["game"] = game
        if limit is not None:
            report.update(memoryLimitMiB=limit, increasedMemoryLimit=iml)
        self.insert(report, day)
        return report

    def insert(self, report, day):
        self.ids += [report["id"], report["install"]] + ([report["session"]] if report.get("session") else [])
        self.cloudflare.sql.execute(
            "INSERT INTO reports (id, kind, install, day, seq, cartouche, device, ios, game, name, session, body) "
            "VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
            (report["id"], report["kind"], report["install"], day, report["seq"], report["cartouche"],
             report["device"], report["ios"], report.get("game"), report.get("name"), report.get("session"),
             json.dumps(report)))

    def run_page(self, secrets=True):
        values = {"GITHUB_OUTPUT": str(self.work / "output"), "GITHUB_STEP_SUMMARY": str(self.work / "summary.md")}
        if secrets:
            values.update(CLOUDFLARE_API_TOKEN=TOKEN, CLOUDFLARE_ACCOUNT_ID=ACCOUNT)
        result = subprocess.run(
            [sys.executable, str(PAGE), "--catalog", str(self.catalog), "--out", str(self.work / "page"),
             "--today", TODAY],
            env=environment(self.server, **values), capture_output=True, text=True, timeout=60)
        self.assertEqual(result.returncode, 0, result.stderr)
        return result

    def page(self):
        path = self.work / "page" / "README.md"
        self.assertTrue(path.exists(), "the page was not written")
        return path.read_text(encoding="utf-8")

    def output(self):
        return (self.work / "output").read_text(encoding="utf-8")

    # MARK: Lines and figures

    def test_a_game_three_installs_played_gets_a_line_of_their_medians(self):
        for phone, fps in zip(self.phones[:3], (58.0, 59.0, 60.0)):
            self.session(phone, fps={"median": fps, "low5": fps - 6})
        # The third install's other session moves its own median, not the others'.
        self.session(self.phones[2], day="2026-11-11", fps={"median": 30.0, "low5": 20.0})
        result = self.run_page()
        self.assertEqual(self.output(), "written=true\n")
        page = self.page()
        self.assertTrue(page.startswith("# nxnative's games on players' iPhones\n"))
        self.assertIn("measured of nxnative's games from 2026-11-10 to 2026-11-11,", page)
        self.assertIn("4 game sessions from 3 installs, 2.3 hours of play. 4 of the 4 sessions that count name "
                      "their nxnative commit.", page)
        # Each install's median: 58, 59 and (60 + 30) / 2 = 45: their median is 58; of the slowest 5%, 52, 53
        # and 37: 52. The rest is the fixture's: 35.2 minutes, a p99 of 33.4 ms, 3.1 stutters a minute, 76 of
        # 108 waiting for shaders, 210 ms of shader stall, 21.43 s of preparation, a peak of 4,813 MiB, serious
        # heat after 24 minutes.
        figures = {"Installs": "3", "Sessions": "4", "Hours": "2.3", "Target fps": "60", "FPS median": "58.0",
                   "FPS slowest 5%": "52.0", "Frame p99 ms": "33.4", "Stutters a minute": "3",
                   "Waiting for shaders": "70%", "Shader stall ms a minute": "210", "Prepare s": "21.4",
                   "Peak MiB": "4,813", "Reached serious heat": "4 of 4", "Crashed": "0", "Failed to boot": "0",
                   "Out of memory": "0", "Drew no frame": "0"}
        self.assertEqual(rows(page, "By game"), [{"Game": MKW_NAME, "nxnative": "`6c3aeb3d70a1`", **figures}])
        self.assertEqual(rows(page, "By game and model"),
                         [{"Game": MKW_NAME, "Model": "`iPhone19,4`", "nxnative": "`6c3aeb3d70a1`", **figures}])
        self.assertEqual(rows(page, "By game and nxnative commit"),
                         [{"Game": MKW_NAME, "nxnative": "`6c3aeb3d70a1`", **figures}])
        summary = (self.work / "summary.md").read_text(encoding="utf-8")
        self.assertIn("4 game sessions from 3 installs", summary)
        self.assertIn("The page goes on the branch `nxnative-measurements`.", result.stdout)

    def test_two_installs_make_no_line(self):
        for phone in self.phones[:2]:
            self.session(phone, game=SENTINELS)
        for phone in self.phones[:3]:
            self.session(phone)
        self.run_page()
        page = self.page()
        self.assertEqual([row["Game"] for row in rows(page, "By game")], [MKW_NAME])
        self.assertNotIn(SENTINELS, page)
        self.assertNotIn("13 Sentinels", page)

    def test_a_figure_fewer_than_three_installs_gave_shows_a_dash(self):
        self.session(self.phones[0])
        self.session(self.phones[1])
        self.session(self.phones[2], fps=None, memory=None, frames=10)
        self.run_page()
        line = rows(self.page(), "By game")[0]
        self.assertEqual((line["Installs"], line["FPS median"], line["FPS slowest 5%"], line["Peak MiB"]),
                         ("3", "–", "–", "–"))
        self.assertEqual((line["Frame p99 ms"], line["Drew no frame"]), ("33.4", "0"))

    def test_the_peak_is_each_installs_highest_of_its_sessions_that_drew_a_frame(self):
        self.session(self.phones[0], memory={"peakMiB": 4000})
        # Ended before its first frame: its peak does not count, its crash does.
        self.session(self.phones[0], memory={"peakMiB": 7000}, frames=None, fps=None,
                     end={"kind": "crash", "signal": 11})
        self.session(self.phones[1], memory={"peakMiB": 4500})
        self.session(self.phones[1], memory={"peakMiB": 4700})
        self.session(self.phones[1], memory={"peakMiB": 6900}, frames=0, fps=None)
        self.session(self.phones[2], memory={"peakMiB": 5000})
        self.run_page()
        line = rows(self.page(), "By game")[0]
        # Each install's highest: 4000, 4700 and 5000.
        self.assertEqual((line["Peak MiB"], line["Sessions"], line["Crashed"], line["Drew no frame"]),
                         ("4,700", "6", "1", "1"))

    def test_sessions_that_are_not_nxnatives_doing_are_set_apart(self):
        for phone in self.phones[:3]:
            self.session(phone)
        # An iPhone of 4 GB: its game process has the limit iOS gives Cartouche, and counts.
        self.session(self.phones[3], memoryLimitMiB=3376, process={"limitMiB": 3376, "peakMiB": 2900})
        for phone in self.phones[4:7]:
            self.session(phone, device="iPhone15,4")
        for phone in self.phones[7:10]:
            self.session(phone, memoryLimitMiB=8192, process={"limitMiB": 3376, "peakMiB": 3300})
        for phone in self.phones[10:12]:
            self.session(phone, nxnativeChanged=True)
        self.run_page()
        page = self.page()
        self.assertEqual([(row["Game"], row["Installs"]) for row in rows(page, "By game")], [(MKW_NAME, "4")])
        self.assertIn(
            "Set apart: 3 sessions on iPhones whose GPU reads no BC texture (A16 and older), which nxnative refuses, "
            "from 3 installs; 3 sessions whose game process ran without Increased Memory Limit, which is "
            "Cartouche's doing, from 3 installs; sessions of builds with changes of their own, from fewer than 3 "
            "installs.", page)
        self.assertNotIn("iPhone15,4", page)
        self.assertIn("12 game sessions from 12 installs", page)

    # MARK: What several installs share

    def test_lines_by_model_and_by_commit_name_only_what_three_installs_share(self):
        for phone in self.phones[:3]:
            self.session(phone, nxnative="aaaaaaaaaaaa")
        for phone in self.phones[3:6]:
            self.session(phone, device="iPhone18,2", nxnative="bbbbbbbbbbbb")
        self.session(self.phones[6], device="iPhone18,2", nxnative="aaaaaaaaaaaa")
        for phone in self.phones[7:9]:
            self.session(phone, nxnative="cccccccccccc")
        self.session(self.phones[9], device="iPhone17,1", nxnative=None)
        self.run_page()
        page = self.page()
        self.assertEqual([(r["Game"], r["nxnative"], r["Installs"]) for r in rows(page, "By game")],
                         [(MKW_NAME, "`aaaaaaaaaaaa` (+2)", "10")])
        self.assertEqual([(r["Model"], r["nxnative"], r["Installs"]) for r in rows(page, "By game and model")],
                         [("`iPhone19,4`", "`aaaaaaaaaaaa` (+1)", "5"), ("`iPhone18,2`", "`bbbbbbbbbbbb` (+1)", "4")])
        self.assertEqual([(r["nxnative"], r["Installs"]) for r in rows(page, "By game and nxnative commit")],
                         [("`aaaaaaaaaaaa`", "4"), ("`bbbbbbbbbbbb`", "3")])
        self.assertIn("9 of the 10 sessions that count name their nxnative commit.", page)
        self.assertNotIn("cccccccccccc", page)
        self.assertNotIn("iPhone17,1", page)

    def test_a_crash_shows_when_three_installs_share_it(self):
        crash = {"kind": "crash", "signal": 11, "pc": "main+0x10", "lr": "main+0x08"}
        for phone in self.phones[:3]:
            self.session(phone, nxnative="aaaaaaaaaaaa", end=crash)
        self.session(self.phones[3], device="iPhone17,2", nxnative="aaaaaaaaaaaa",
                     end={**crash, "pc": "main+0x99", "lr": "main+0x98"})
        for phone in self.phones[4:6]:
            self.session(phone, end={"kind": "crash", "signal": 6, "pc": "main+0x20"})
        self.run_page()
        page = self.page()
        by_signal, exact = tables(page, "Crashes")
        self.assertEqual(by_signal, [{"Game": MKW_NAME, "Signal": "SIGSEGV", "Installs": "4", "Sessions": "4",
                                      "Models": "`iPhone19,4` (+1)", "nxnative": "`aaaaaaaaaaaa`",
                                      "Minutes in": "35.2"}])
        self.assertEqual(exact, [{"Game": MKW_NAME, "Version": "1.0.0", "nxnative": "`aaaaaaaaaaaa`",
                                  "Signal": "SIGSEGV", "pc": "`main+0x10`", "lr": "`main+0x08`", "Installs": "3",
                                  "Sessions": "3", "Minutes in": "35.2"}])
        for unshared in ("main+0x99", "main+0x98", "SIGABRT", "main+0x20", "iPhone17,2"):
            self.assertNotIn(unshared, page)
        self.assertEqual(rows(page, "By game")[0]["Crashed"], "6")

    def test_no_installs_sessions_or_reports_number_is_written(self):
        for phone in self.phones[:3]:
            self.session(phone, end={"kind": "crash", "signal": 11, "pc": "main+0x10", "lr": "main+0x08"})
            self.event(phone, "app.opened", device="iPhone19,4", ios="27.3", limit=8192, iml=True)
        for mac in self.macs[:3]:
            self.event(mac, "builder.opened", nxnative="aaaaaaaaaaaa", forkOfNxnative=False)
            self.event(mac, "builder.built", nxnative="aaaaaaaaaaaa")
        result = self.run_page()
        written = self.page() + result.stdout + result.stderr + (self.work / "summary.md").read_text(encoding="utf-8")
        self.assertIn("`aaaaaaaaaaaa` | 3 |", written)
        for number in self.ids:
            self.assertNotIn(number, written)
            self.assertNotIn(number[:8], written)
            self.assertNotIn(number.replace("-", "")[:12], written)

    # MARK: Devices and builds

    def test_devices_as_each_install_last_started_cartouche(self):
        self.event(self.phones[0], "app.opened", device="iPhone19,4", ios="27.2.1", seq=1, limit=8192, iml=True)
        for phone in self.phones[:3]:
            self.event(phone, "app.opened", day="2026-11-11", device="iPhone19,4", ios="27.3", seq=5, limit=8192,
                       iml=True)
        for phone in self.phones[3:6]:
            self.event(phone, "app.opened", device="iPhone18,2", ios="27.2.1", limit=4096, iml=False)
        self.event(self.phones[6], "app.opened", device="iPhone15,4", ios="26.5", limit=6144, iml=True)
        self.run_page()
        page = self.page()
        devices = page.split("\n## Devices\n", 1)[1].split("\n## ", 1)[0]
        self.assertIn("The installs that started Cartouche, as each last did: 7 installs.", devices)
        self.assertIn("- Models: `iPhone18,2` 3, `iPhone19,4` 3; fewer than 3 installs on 1 other model.", devices)
        self.assertIn("- iOS: 27.2 3, 27.3 3.", devices)
        self.assertIn("8,192 MiB on 3", devices)
        self.assertIn("4,096 MiB without Increased Memory Limit on 3", devices)
        self.assertNotIn("6,144", devices)
        self.assertIn("- iPhones whose GPU reads no BC texture (A16 and older): fewer than 3 installs.", devices)
        self.assertNotIn("iPhone15,4", page)
        self.assertNotIn("26.5", page)

    def test_builds_by_commit_leave_out_forks_and_what_is_not_nxnatives(self):
        for mac in self.macs[:3]:
            self.event(mac, "builder.opened", nxnative="aaaaaaaaaaaa", forkOfNxnative=False)
            self.event(mac, "builder.failed", nxnative="aaaaaaaaaaaa", stage="app build", cause="app_build")
        for mac in self.macs[:2]:
            self.event(mac, "builder.built", nxnative="aaaaaaaaaaaa")
        self.event(self.macs[2], "builder.failed", nxnative="aaaaaaaaaaaa", stage="unpack v0", cause="damaged")
        # Not nxnative's: the player stopped the build; Cartouche Builder's own code failed.
        self.event(self.macs[0], "builder.failed", nxnative="aaaaaaaaaaaa", stage="extract v0", cause="stopped")
        self.event(self.macs[1], "builder.failed", nxnative="aaaaaaaaaaaa", stage="deliver", cause="builder")
        # A Mac that follows a fork of nxnative, as it last started.
        self.event(self.macs[3], "builder.opened", nxnative="aaaaaaaaaaaa", forkOfNxnative=False, seq=1)
        self.event(self.macs[3], "builder.opened", nxnative="aaaaaaaaaaaa", forkOfNxnative=True, seq=2)
        self.event(self.macs[3], "builder.built", nxnative="aaaaaaaaaaaa", seq=3)
        for mac in self.macs[4:6]:
            self.event(mac, "builder.built", nxnative="bbbbbbbbbbbb")
        self.run_page()
        page = self.page()
        self.assertEqual(rows(page, "Builds on players' Macs, by nxnative commit"), [
            {"nxnative": "`aaaaaaaaaaaa`", "Macs": "3", "Built": "2", "Failed": "4",
             "Where they failed": "app build 3, other steps 1"}])
        for left_out in ("bbbbbbbbbbbb", "unpack v0", "extract v0", "deliver"):
            self.assertNotIn(left_out, page.split("## How it is summed up")[0])

    def test_the_games_no_mac_built_for_cartouche_builder(self):
        """unbuilt.json: a game three Macs tried and none built, as Pokopia
        on 14 November 2026 (8 failures on 4 Macs, up to 7.9 hours), for the
        app to warn of before a fourth spends its night on it."""
        pokopia, other = "0400A3A01EE4C000", "0100F2C0115B6000"
        hours = {self.macs[0]: [28493], self.macs[1]: [16878, 8741], self.macs[2]: [3600]}
        for mac, attempts in hours.items():
            for seconds in attempts:
                self.event(mac, "builder.failed", game=pokopia, nxnative="aaaaaaaaaaaa", stage="iOS shaders", cause="nxnative", seconds=seconds)
        # Not the game's own: a stop, the Mac's Xcode, the player's files.
        self.event(self.macs[3], "builder.failed", game=pokopia, nxnative="aaaaaaaaaaaa", stage="iOS shaders", cause="stopped", seconds=600)
        self.event(self.macs[4], "builder.failed", game=pokopia, nxnative="aaaaaaaaaaaa", stage="unpack v0", cause="damaged", seconds=60)
        # Another game three Macs failed, and one built.
        for mac in self.macs[:3]:
            self.event(mac, "builder.failed", game=other, nxnative="aaaaaaaaaaaa", stage="shader split", cause="nxnative", seconds=100)
        self.event(self.macs[5], "builder.built", game=other, nxnative="aaaaaaaaaaaa", seconds=2000)
        # A game two Macs failed: too few to say.
        for mac in self.macs[:2]:
            self.event(mac, "builder.failed", game=SENTINELS, nxnative="aaaaaaaaaaaa", stage="app build", cause="nxnative", seconds=50)
        self.run_page()
        found = json.loads((self.work / "page" / "unbuilt.json").read_text(encoding="utf-8"))
        self.assertEqual(found, {"schema": 1, "from": "2026-10-15", "to": "2026-11-11", "games": [
            {"titleId": pokopia, "macs": 3, "failures": 4, "hours": 4.7, "stage": "iOS shaders"}]})
        text = json.dumps(found)
        for number in self.ids:
            self.assertNotIn(number, text)

    def test_a_game_built_by_a_fork_alone_is_still_unbuilt(self):
        pokopia = "0400A3A01EE4C000"
        for mac in self.macs[:3]:
            self.event(mac, "builder.failed", game=pokopia, nxnative="aaaaaaaaaaaa", stage="iOS shaders", seconds=7200)
        self.event(self.macs[3], "builder.opened", nxnative="cccccccccccc", forkOfNxnative=True)
        self.event(self.macs[3], "builder.built", game=pokopia, nxnative="cccccccccccc", seq=2)
        self.run_page()
        found = json.loads((self.work / "page" / "unbuilt.json").read_text(encoding="utf-8"))
        self.assertEqual([(g["titleId"], g["macs"], g["hours"]) for g in found["games"]], [(pokopia, 3, 2.0)])

    # MARK: Which sessions count

    def test_the_slowest_5_percent_counts_only_from_the_reading_that_takes_pauses_out(self):
        # As Super Mario Bros. Wonder's on the iPhone19,4 on 2026-11-13: 59.6 fps, and 4 fps in the slowest 5% of
        # the time, from the stretches that held a pause behind the console.
        for phone in self.phones[:3]:
            self.session(phone, reader=1, fps={"median": 59.6, "low5": 4.0})
        self.run_page()
        line = rows(self.page(), "By game")[0]
        self.assertEqual((line["FPS median"], line["FPS slowest 5%"]), ("59.6", "–"))
        # Read again with the reading that takes the pauses out, the same sessions count.
        for phone in self.phones[:3]:
            self.session(phone, day="2026-11-11", fps={"median": 59.6, "low5": 52.0})
        self.run_page()
        line = rows(self.page(), "By game")[0]
        self.assertEqual((line["Sessions"], line["FPS median"], line["FPS slowest 5%"]), ("6", "59.6", "52.0"))

    def test_a_session_sent_again_counts_once_at_its_highest_seq(self):
        again = str(uuid.uuid4())
        self.session(self.phones[0], session=again, seq=3, fps={"median": 20.0, "low5": 10.0})
        self.session(self.phones[0], session=again, seq=5, day="2026-11-11", fps={"median": 60.0, "low5": 58.0})
        self.session(self.phones[1], fps={"median": 60.0, "low5": 58.0})
        self.session(self.phones[2], fps={"median": 60.0, "low5": 58.0})
        self.run_page()
        line = rows(self.page(), "By game")[0]
        self.assertEqual((line["Sessions"], line["FPS median"], line["FPS slowest 5%"]), ("3", "60.0", "58.0"))

    def test_only_the_28_days_before_the_run_count(self):
        for phone in self.phones[:3]:
            self.session(phone, day="2026-10-15")
        self.session(self.phones[0], day="2026-10-14", end={"kind": "crash", "signal": 11})
        self.session(self.phones[1], day=TODAY, end={"kind": "crash", "signal": 11})
        self.run_page()
        page = self.page()
        self.assertIn("from 2026-10-15 to 2026-11-11,", page)
        line = rows(page, "By game")[0]
        self.assertEqual((line["Sessions"], line["Crashed"]), ("3", "0"))

    def test_a_copy_of_another_region_counts_for_its_game(self):
        self.session(self.phones[0], game=SENTINELS)
        self.session(self.phones[1], game=SENTINELS_JAPAN)
        self.session(self.phones[2], game=SENTINELS_JAPAN)
        self.run_page()
        page = self.page()
        self.assertEqual([(r["Game"], r["Installs"]) for r in rows(page, "By game")],
                         [(f"13 Sentinels: Aegis Rim `{SENTINELS}`", "3")])
        self.assertNotIn(SENTINELS_JAPAN, page)

    def test_a_week_without_sessions_still_makes_a_page(self):
        self.run_page()
        self.assertEqual(self.output(), "written=true\n")
        page = self.page()
        self.assertIn("from 2026-10-15 to 2026-11-11,", page)
        self.assertIn("0 game sessions from 0 installs, 0.0 hours of play.", page)
        self.assertIn("No game was played on 3 installs or more.", page)
        self.assertIn("No nxnative commit was built on 3 Macs or more.", page)
        # What the slowest 5% counts, so that a low one is not read as nxnative's alone.
        self.assertIn("it counts only from the sessions Cartouche read with its reading 2 of the log or a later one",
                      page)

    # MARK: Secrets

    def test_without_the_secrets_nothing_is_read(self):
        self.session(self.phones[0])
        result = self.run_page(secrets=False)
        self.assertIn("not set", result.stdout)
        self.assertEqual(self.output(), "written=false\n")
        self.assertEqual(self.cloudflare.calls, [])
        self.assertFalse((self.work / "page").exists())

    def test_a_refusal_fails_the_run_with_cloudflares_words(self):
        values = {"CLOUDFLARE_API_TOKEN": "another-token", "CLOUDFLARE_ACCOUNT_ID": ACCOUNT}
        result = subprocess.run(
            [sys.executable, str(PAGE), "--catalog", str(self.catalog), "--out", str(self.work / "page")],
            env=environment(self.server, **values), capture_output=True, text=True, timeout=60)
        self.assertEqual(result.returncode, 1)
        self.assertIn("10000: Authentication error", result.stderr)
        self.assertNotIn("another-token", result.stdout + result.stderr)
        self.assertFalse((self.work / "page").exists())


if __name__ == "__main__":
    unittest.main()
