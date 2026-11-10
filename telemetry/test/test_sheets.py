"""Checks telemetry/sheets.py, the weekly sum of the game sessions into the
game sheets, against a stand-in for Cloudflare's API (standin.py) whose D1
database holds sessions as the Worker keeps them, made from the session of
app-reports.json.

- a model three iPhones played on gets a result, made of the medians of each
  iPhone's own; a model two iPhones played on gets none, and neither does any
  of its figures that fewer than three iPhones measured;
- a session sent again counts once, at its highest seq; only the 28 days
  before the run count; a copy of another region counts for its game;
- the status follows from how the sessions ended and the frame rate;
- testers' results stay, a measured result of a model measured again is
  replaced, and the sheet stays valid for its schema and the publish guard;
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
ROOT = HERE.parents[1]
SHEETS = HERE.parent / "sheets.py"
SCHEMA = HERE.parent / "schema.sql"
SCHEMA_OF_SHEETS = ROOT / "catalog" / "schema" / "game.schema.json"
MKW = "0400C3F00006E000"
SENTINELS = "01003FC01670C000"
SENTINELS_JAPAN = "010045C014650000"
TODAY = "2026-11-12"

TEMPLATE = next(r for r in json.loads((HERE / "app-reports.json").read_text(encoding="utf-8"))["reports"]
                if r["kind"] == "session")

# The catalog of the tests, in the catalog's own formats: two games of
# nxnative's list, one with a copy of another region, and a sheet with a
# tester's result.
NXNATIVE = {"schema": 1, "nxnative": "0123456789abcdef0123456789abcdef01234567", "games": [
    {"titleId": SENTINELS, "name": "13 Sentinels: Aegis Rim", "platform": "switch", "genre": "rpg",
     "status": "bringup", "engine": "Vanillaware's engine", "build": "1.10", "sdk": "11.4.3",
     "variants": [{"titleId": SENTINELS_JAPAN, "region": "japan", "build": "1.00 (base)"}]},
    {"titleId": MKW, "name": "Mario Kart World", "platform": "switch2", "genre": "racing",
     "status": "iphone", "engine": "Nintendo's engine", "build": "1.0.0", "sdk": "20.0.0"},
]}
TESTER = {"device": "iPhone19,4", "iOS": "27.3", "date": "2026-11-05", "engine": "nxnative 0d9b6358",
          "status": "playable", "notes": ["Ran smoothly at 1080p in handheld mode."]}
SHEET = {"schema": 1, "titleId": MKW, "name": "Mario Kart World", "platform": "switch2",
         "requirements": {"minimumIOS": "26.0", "bcTextureCompression": True, "increasedMemoryLimit": True},
         "recommended": {"resolution": "1080p", "mode": "handheld"}, "results": [TESTER]}

try:
    import jsonschema
except ImportError:  # the Telemetry workflow installs it with the publish guard
    jsonschema = None

sys.path.insert(0, str(ROOT / "guard"))
from cartouche_guard.guard import check_catalog  # noqa: E402  (the guard is Python's standard library only)


def schema_as_deployed() -> str:
    lines = SCHEMA.read_text(encoding="utf-8").splitlines()
    return "\n".join(line for line in lines if not line.lstrip().startswith("--"))


class SheetsTest(unittest.TestCase):
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
        (self.catalog / "games").mkdir(parents=True)
        (self.catalog / "nxnative.json").write_text(json.dumps(NXNATIVE, indent=2) + "\n", encoding="utf-8")
        (self.catalog / "games" / f"{MKW}.json").write_text(json.dumps(SHEET, indent=2) + "\n", encoding="utf-8")
        self.phones = [str(uuid.uuid4()) for _ in range(5)]

    # MARK: Helpers

    def session(self, install, day="2026-11-10", device="iPhone19,4", game=MKW, session=None, seq=1, **fields):
        """A session as the Worker keeps it: the fixture's, with these fields."""
        report = copy.deepcopy(TEMPLATE)
        report.update(id=str(uuid.uuid4()), install=install, device=device, game=game, seq=seq,
                      session=session or str(uuid.uuid4()), end={"kind": "unknown"})
        for key, value in fields.items():
            if value is None:
                report.pop(key, None)
            else:
                report[key] = value
        self.cloudflare.sql.execute(
            "INSERT INTO reports (id, kind, install, day, seq, cartouche, device, ios, game, name, session, body) "
            "VALUES (?, 'session', ?, ?, ?, ?, ?, ?, ?, NULL, ?, ?)",
            (report["id"], install, day, seq, report["cartouche"], device, report["ios"], game, report["session"],
             json.dumps(report)))
        return report

    def run_sheets(self, secrets=True):
        values = {"GITHUB_OUTPUT": str(self.work / "output"), "GITHUB_STEP_SUMMARY": str(self.work / "summary.md")}
        if secrets:
            values.update(CLOUDFLARE_API_TOKEN=TOKEN, CLOUDFLARE_ACCOUNT_ID=ACCOUNT)
        result = subprocess.run(
            [sys.executable, str(SHEETS), "--catalog", str(self.catalog), "--out", str(self.work / "sheets"),
             "--today", TODAY],
            env=environment(self.server, **values), capture_output=True, text=True, timeout=60)
        self.assertEqual(result.returncode, 0, result.stderr)
        return result

    def output(self):
        return (self.work / "output").read_text(encoding="utf-8")

    def written(self, title=MKW):
        path = self.work / "sheets" / f"{title}.json"
        return json.loads(path.read_text(encoding="utf-8")) if path.exists() else None

    def measured(self, title=MKW):
        sheet = self.written(title)
        self.assertIsNotNone(sheet, "the sheet was not written")
        return {r["device"]: r for r in sheet["results"] if "measured" in r}

    def assert_valid(self, sheet):
        check_catalog(json.dumps(sheet).encode(), "sheet")
        for result in sheet["results"]:
            self.assertLessEqual(len(result["engine"]), 120)
            for note in result.get("notes", []):
                self.assertLessEqual(len(note), 300)
        if jsonschema is not None:
            schema = json.loads(SCHEMA_OF_SHEETS.read_text(encoding="utf-8"))
            jsonschema.validate(sheet, schema)

    # MARK: Tests

    def test_three_iphones_of_a_model_make_a_result_of_their_medians(self):
        for phone, fps, peak, stutters in zip(self.phones[:3], (58.0, 59.0, 60.0), (4640, 4720, 4800), (1.2, 1.4, 1.6)):
            self.session(phone, fps={"median": fps, "low5": fps - 6}, memory={"peakMiB": peak},
                         stutters={"count": 10, "perMinute": stutters})
        # The third iPhone's other session moves its own median, not the others'.
        self.session(self.phones[2], day="2026-11-11", fps={"median": 30.0, "low5": 20.0},
                     memory={"peakMiB": 5200}, stutters={"count": 40, "perMinute": 4.0})
        self.run_sheets()
        self.assertEqual(self.output(), "changed=true\n")
        result = self.measured()["iPhone19,4"]
        self.assertEqual(result["status"], "playable")
        self.assertEqual(result["date"], "2026-11-11")
        self.assertEqual(result["iOS"], "27.3")
        self.assertEqual(result["engine"], "nxnative 6c3aeb3d70a1")
        # Each iPhone's median: 58, 59 and (60 + 30) / 2 = 45: their median is 58.
        self.assertEqual(result["measured"], {
            "iPhones": 3, "sessions": 4, "from": "2026-11-10", "to": "2026-11-11", "fps": 58, "slowestFps": 52,
            "targetFps": 60, "stuttersPerMinute": 1.4, "endedBadlyPercent": 0})
        # Each iPhone's highest peak: 4640, 4720 and 5200.
        self.assertEqual(result["peakMemoryMiB"], 4720)
        self.assertEqual(result["notes"], [
            "Measured by Cartouche on 3 iPhones, 4 sessions from 2026-11-10 to 2026-11-11: 58 fps for 60 (median), "
            "52 fps in the slowest 5% of the time, 1.4 stutters a minute. None ended badly."])
        sheet = self.written()
        self.assertEqual(sheet["results"][0], TESTER, "the tester's result stays first, as it was")
        self.assert_valid(sheet)
        summary = (self.work / "summary.md").read_text(encoding="utf-8")
        self.assertIn("| Mario Kart World | iPhone19,4 | 3 | 4 | playable |", summary)

    def test_a_model_no_sheet_may_name_is_left_out(self):
        for phone in self.phones[:3]:
            self.session(phone, device="iPod9,1")
        self.run_sheets()
        self.assertEqual(self.output(), "changed=false\n")

    def test_two_iphones_make_no_result(self):
        for phone in self.phones[:2]:
            self.session(phone)
        self.session(self.phones[0], device="iPhone18,1")
        result = self.run_sheets()
        self.assertEqual(self.output(), "changed=false\n")
        self.assertIsNone(self.written())
        self.assertIn("Left out: 2 models of a game with a sheet, played on fewer than 3 iPhones.", result.stdout)
        self.assertNotIn("iPhone18,1", result.stdout + (self.work / "summary.md").read_text(encoding="utf-8"))

    def test_a_figure_fewer_than_three_iphones_measured_is_left_out(self):
        self.session(self.phones[0], memory={"peakMiB": 4000})
        self.session(self.phones[1], memory={"peakMiB": 4100})
        self.session(self.phones[2], memory=None, fps=None, stutters=None, frames=10)
        self.run_sheets()
        result = self.measured()["iPhone19,4"]
        self.assertNotIn("peakMemoryMiB", result)
        self.assertNotIn("fps", result["measured"])
        self.assertNotIn("stuttersPerMinute", result["measured"])
        self.assertEqual(result["notes"], [
            "Measured by Cartouche on 3 iPhones, 3 sessions from 2026-11-10 to 2026-11-10. None ended badly."])
        self.assert_valid(self.written())

    def test_a_session_sent_again_counts_once_at_its_highest_seq(self):
        again = str(uuid.uuid4())
        self.session(self.phones[0], session=again, seq=3, fps={"median": 20.0, "low5": 10.0})
        self.session(self.phones[0], session=again, seq=5, day="2026-11-11", fps={"median": 60.0, "low5": 58.0})
        self.session(self.phones[1], fps={"median": 60.0, "low5": 58.0})
        self.session(self.phones[2], fps={"median": 60.0, "low5": 58.0})
        self.run_sheets()
        result = self.measured()["iPhone19,4"]
        self.assertEqual(result["measured"]["sessions"], 3)
        self.assertEqual(result["measured"]["fps"], 60)
        self.assertEqual(result["status"], "playable")

    def test_only_the_28_days_before_the_run_count(self):
        for phone in self.phones[:3]:
            self.session(phone, day="2026-10-15")
        self.session(self.phones[0], day="2026-10-14", end={"kind": "crash", "signal": 11})
        self.session(self.phones[1], day=TODAY, end={"kind": "crash", "signal": 11})
        self.run_sheets()
        result = self.measured()["iPhone19,4"]
        self.assertEqual((result["measured"]["sessions"], result["measured"]["from"]), (3, "2026-10-15"))
        self.assertEqual(result["measured"]["endedBadlyPercent"], 0)

    def test_a_copy_of_another_region_counts_for_its_game(self):
        sheet = {"schema": 1, "titleId": SENTINELS, "name": "13 Sentinels: Aegis Rim", "platform": "switch",
                 "requirements": {"minimumIOS": "26.0", "bcTextureCompression": True, "increasedMemoryLimit": False},
                 "results": []}
        (self.catalog / "games" / f"{SENTINELS}.json").write_text(json.dumps(sheet, indent=2) + "\n")
        self.session(self.phones[0], game=SENTINELS)
        self.session(self.phones[1], game=SENTINELS_JAPAN)
        self.session(self.phones[2], game=SENTINELS_JAPAN)
        self.run_sheets()
        self.assertEqual(self.measured(SENTINELS)["iPhone19,4"]["measured"]["iPhones"], 3)
        self.assertIsNone(self.written(MKW))
        self.assert_valid(self.written(SENTINELS))

    def test_the_status_follows_how_the_sessions_ended_and_the_frame_rate(self):
        crash = {"kind": "crash", "signal": 11, "pc": "main+0x10"}
        cases = {
            "iPhone17,1": ([{"frames": None, "fps": None, "end": {"kind": "boot-failed"}}] * 3, "does-not-run"),
            "iPhone17,2": ([{"end": crash}, {"end": {"kind": "memory-likely"}}, {}], "boots"),
            "iPhone17,3": ([{"end": crash}] + [{}] * 8, "playable-with-issues"),
            "iPhone17,4": ([{"fps": {"median": 50.0, "low5": 45.0}}] * 3, "playable-with-issues"),
            "iPhone17,5": ([{"fps": {"median": 59.0, "low5": 40.0}}] * 3, "playable-with-issues"),
            # A game the player quit behind the console ended well.
            "iPhone18,1": ([{"fps": {"median": 55.0, "low5": 46.0}}] * 2
                           + [{"fps": {"median": 55.0, "low5": 46.0}, "end": {"kind": "quit"}}], "playable"),
        }
        for device, (sessions, _) in cases.items():
            for i, fields in enumerate(sessions):
                self.session(self.phones[i % 3], device=device, **fields)
        self.run_sheets()
        measured = self.measured()
        self.assertEqual({device: measured[device]["status"] for device in cases},
                         {device: status for device, (_, status) in cases.items()})
        self.assertEqual(measured["iPhone17,2"]["notes"][0].split(". ")[-1],
                         "2 sessions ended badly: 1 crash, 1 out of memory.")
        self.assertEqual(measured["iPhone17,2"]["measured"]["endedBadlyPercent"], 66.7)
        self.assert_valid(self.written())

    def test_a_model_measured_again_is_replaced_and_the_others_stay(self):
        path = self.catalog / "games" / f"{MKW}.json"
        sheet = json.loads(path.read_text(encoding="utf-8"))
        old = {"device": "iPhone19,4", "iOS": "27.2", "date": "2026-10-01", "engine": "nxnative 0123456789ab",
               "status": "boots", "notes": ["Older."],
               "measured": {"iPhones": 3, "sessions": 3, "from": "2026-09-20", "to": "2026-10-01"}}
        other = {**old, "device": "iPhone18,3"}
        sheet["results"] += [other, old]
        path.write_text(json.dumps(sheet, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
        for phone in self.phones[:3]:
            self.session(phone)
        self.run_sheets()
        results = self.written()["results"]
        self.assertEqual([r["device"] for r in results], ["iPhone19,4", "iPhone18,3", "iPhone19,4"])
        self.assertNotIn("measured", results[0])
        self.assertEqual(results[1], other)
        self.assertEqual((results[2]["date"], results[2]["status"]), ("2026-11-10", "playable"))

    def test_the_same_figures_again_change_nothing(self):
        for phone in self.phones[:3]:
            self.session(phone)
        self.run_sheets()
        shutil.copy(self.work / "sheets" / f"{MKW}.json", self.catalog / "games" / f"{MKW}.json")
        shutil.rmtree(self.work / "sheets")
        (self.work / "output").unlink()
        self.run_sheets()
        self.assertEqual(self.output(), "changed=false\n")
        self.assertIsNone(self.written())

    def test_engines_and_games_without_a_sheet(self):
        builds = ("6c3aeb3d70a1", "6c3aeb3d70a1", "aaaaaaaaaaaa", "bbbbbbbbbbbbbbbbbbbb")
        for i, build in enumerate(builds):
            self.session(self.phones[i % 3], nxnative=build)
        for phone in self.phones[:3]:
            self.session(phone, game="0100F2C0115B6000")
        for phone, game in zip(self.phones[:3], (SENTINELS, SENTINELS_JAPAN, SENTINELS_JAPAN)):
            self.session(phone, game=game)
        result = self.run_sheets()
        self.assertEqual(self.measured()["iPhone19,4"]["engine"], "nxnative 6c3aeb3d70a1 and 2 other builds")
        self.assertIn(f"with no sheet: 13 Sentinels: Aegis Rim ({SENTINELS}, 3 iPhones), "
                      "0100F2C0115B6000 (3 iPhones).", result.stdout)

    def test_without_the_secrets_nothing_is_read(self):
        self.session(self.phones[0])
        result = self.run_sheets(secrets=False)
        self.assertIn("not set", result.stdout)
        self.assertEqual(self.output(), "changed=false\n")
        self.assertEqual(self.cloudflare.calls, [])

    def test_a_refusal_fails_the_run_with_cloudflares_words(self):
        values = {"CLOUDFLARE_API_TOKEN": "another-token", "CLOUDFLARE_ACCOUNT_ID": ACCOUNT}
        result = subprocess.run(
            [sys.executable, str(SHEETS), "--catalog", str(self.catalog), "--out", str(self.work / "sheets")],
            env=environment(self.server, **values), capture_output=True, text=True, timeout=60)
        self.assertEqual(result.returncode, 1)
        self.assertIn("10000: Authentication error", result.stderr)
        self.assertNotIn("another-token", result.stdout + result.stderr)


if __name__ == "__main__":
    unittest.main()
