"""Checks how the telemetry dashboard (telemetry/dashboard/worker.js) reads
the telemetry database (telemetry/schema.sql), on SQLite, which D1 is:

- a page of reports is one JSON array that the database writes itself,
  newest first, each report a row of the columns the page reads, with
  JSON's own types: a number stays a number, yes or no true or false, and
  a session's settings an object;
- a session's own part follows SESSION field by field, an event's is its
  fields, and every field of the reports Cartouche makes (app-reports.json)
  goes to the page;
- only the first 8 digits of a copy's number, and of a session's, leave;
- the pages go down from the newest report to the first of the window,
  which the index of days finds without reading a report, and a page of
  2,000 of the app's sessions stays under D1's 2 MB a string;
- what the server took today and yesterday, and the problems GitHub does
  not have yet, add up.

Node reads the statements out of dashboard/worker.js, with the page it
imports as text (text-modules.mjs).

Run from the repository root: python3 -m unittest discover -s telemetry/test -v
"""

import json
import re
import shutil
import sqlite3
import subprocess
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
SCHEMA = HERE.parent / "schema.sql"
DASHBOARD = HERE.parent / "dashboard" / "worker.js"
TEXT_MODULES = HERE / "text-modules.mjs"
APP_REPORTS = json.loads((HERE / "app-reports.json").read_text(encoding="utf-8"))["reports"]

TOP = 2**53 - 1
# Fields of a report the page has no use for: its schema, and its own id.
UNSHOWN = {"schema", "id"}


def schema_as_deployed() -> str:
    lines = SCHEMA.read_text(encoding="utf-8").splitlines()
    return "\n".join(line for line in lines if not re.match(r"\s*--", line))


def dashboard() -> dict:
    node = shutil.which("node")
    if node is None:
        raise unittest.SkipTest("node is not installed")
    script = ("const { SQL, REPORT, SESSION, LIMITS } = await import(process.argv[1]);"
              "process.stdout.write(JSON.stringify({ SQL, REPORT, SESSION, LIMITS }));")
    result = subprocess.run([node, "--import", TEXT_MODULES.as_uri(), "--input-type=module", "-e", script, DASHBOARD.as_uri()],
                            check=True, capture_output=True, text=True)
    return json.loads(result.stdout)


def paths(report: dict, prefix: str = "") -> list:
    """The fields of a report by their paths, such as fps.median; settings
    and an event's fields are one each."""
    found = []
    for key, value in report.items():
        path = prefix + key
        if isinstance(value, dict) and key not in ("settings", "fields"):
            found += paths(value, path + ".")
        else:
            found.append(path)
    return found


def at(report: dict, path: str):
    value = report
    for key in path.split("."):
        if not isinstance(value, dict) or key not in value:
            return None
        value = value[key]
    return value


class DashboardTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.dashboard = dashboard()
        cls.sql = cls.dashboard["SQL"]
        cls.report = cls.dashboard["REPORT"]
        cls.session = cls.dashboard["SESSION"]

    def setUp(self):
        self.db = sqlite3.connect(":memory:")
        self.db.executescript(schema_as_deployed())
        self.counter = 0

    def tearDown(self):
        self.db.close()

    def keep(self, report: dict, day: str):
        """A report as the server keeps it (telemetry/worker.js, SQL.insert)."""
        self.counter += 1
        report = {**report, "id": f"00000000-0000-4000-8000-{self.counter:012d}"}
        self.db.execute(
            "INSERT INTO reports (id, kind, install, day, seq, cartouche, device, ios, game, name, session, body) "
            "VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12) ON CONFLICT (id) DO NOTHING",
            (report["id"], report["kind"], report["install"], day, report["seq"], report["cartouche"], report["device"],
             report["ios"], report.get("game"), report.get("name"), report.get("session"), json.dumps(report)))

    def event(self, seq: int, install: str = "8c1f6c2e-7a2f-4e19-8c3d-2f6a9b0e1d7c") -> dict:
        return {"schema": 1, "kind": "event", "seq": seq, "install": install, "cartouche": "0.10.0",
                "device": "iPhone19,4", "ios": "27.3", "name": "app.opened", "fields": {"games": seq}}

    def first(self, start: str):
        row = self.db.execute(self.sql["first"], (start,)).fetchone()
        return row[0] if row else None

    def pages(self, start: str, size: int) -> list:
        """The pages as the Worker reads them: from the newest down."""
        lowest = self.first(start)
        if lowest is None:
            return []
        pages, below = [], TOP
        while True:
            rows, after, count = self.db.execute(self.sql["page"], (lowest, below, size, start)).fetchone()
            if not count:
                return pages
            pages.append(json.loads(rows))
            if count < size:
                return pages
            below = after

    def test_a_page_holds_each_report_as_a_row_of_its_columns(self):
        session, event = APP_REPORTS
        self.keep(session, "2026-11-10")
        self.keep(event, "2026-11-10")
        [page] = self.pages("2026-11-01", 2000)
        self.assertEqual([row[self.report.index("kind")] for row in page], ["event", "session"])
        for row, sent in zip(reversed(page), APP_REPORTS):
            self.assertEqual(len(row), len(self.report))
            got = dict(zip(self.report, row))
            self.assertEqual(got["day"], "2026-11-10")
            self.assertEqual(got["install"], sent["install"][:8])
            for name in ("kind", "seq", "device", "ios", "cartouche", "language", "game", "name"):
                self.assertEqual(got[name], sent.get(name), name)
            self.assertIs(got["increasedMemoryLimit"], sent["increasedMemoryLimit"])
            self.assertEqual(got["memoryLimitMiB"], sent["memoryLimitMiB"])
            self.assertIsInstance(got["memoryLimitMiB"], int)
        sessionRow = dict(zip(self.report, page[1]))["data"]
        self.assertEqual(len(sessionRow), len(self.session))
        for path, value in zip(self.session, sessionRow):
            expected = session["session"][:8] if path == "session" else at(session, path)
            self.assertEqual(value, expected, path)
            self.assertIs(type(value), type(expected), path)
        self.assertEqual(dict(zip(self.report, page[0]))["data"], event["fields"])

    def test_every_field_cartouche_sends_goes_to_the_page(self):
        session, event = APP_REPORTS
        shown = set(self.report) | set(self.session)
        self.assertEqual([path for path in paths(session) if path not in shown | UNSHOWN], [])
        self.assertEqual([path for path in paths(event) if path not in shown | UNSHOWN | {"fields"}], [])

    def test_a_field_the_log_did_not_have_is_null(self):
        session = {key: value for key, value in APP_REPORTS[0].items() if key not in ("end", "fps", "dlc")}
        self.keep(session, "2026-11-10")
        [[row]] = self.pages("2026-11-10", 2000)
        data = dict(zip(self.session, dict(zip(self.report, row))["data"]))
        for path in ("end.kind", "end.signal", "fps.median", "fps.low5", "dlc"):
            self.assertIsNone(data[path], path)
        self.assertEqual(data["minutes"], APP_REPORTS[0]["minutes"])

    def test_pages_go_down_from_the_newest_report_to_the_first_of_the_window(self):
        for day in range(1, 8):
            self.keep(self.event(day), f"2026-11-0{day}")
        pages = self.pages("2026-11-03", 2)
        seq = self.report.index("seq")
        self.assertEqual([[row[seq] for row in page] for page in pages], [[7, 6], [5, 4], [3]])

    def test_a_report_of_an_earlier_day_received_late_stays_out(self):
        # Two instances of the Worker around midnight: the later report
        # carries the day before.
        self.keep(self.event(1), "2026-11-03")
        self.keep(self.event(2), "2026-11-02")
        self.keep(self.event(3), "2026-11-03")
        seq = self.report.index("seq")
        self.assertEqual([[row[seq] for row in page] for page in self.pages("2026-11-03", 2000)], [[3, 1]])

    def test_an_empty_window_has_no_first_report(self):
        self.keep(self.event(1), "2026-10-01")
        self.assertIsNone(self.first("2026-11-01"))
        rows, after, count = self.db.execute(self.sql["page"], (1, TOP, 2000, "2026-11-01")).fetchone()
        self.assertEqual((json.loads(rows), after, count), ([], None, 0))

    def test_the_first_report_comes_from_the_index_of_days_and_pages_from_the_rowid(self):
        plan = " ".join(row[-1] for row in self.db.execute("EXPLAIN QUERY PLAN " + self.sql["first"], ("2026-11-01",)))
        self.assertIn("COVERING INDEX reports_by_day", plan)
        plan = " ".join(row[-1] for row in self.db.execute("EXPLAIN QUERY PLAN " + self.sql["page"], (1, TOP, 2000, "2026-11-01")))
        self.assertIn("INTEGER PRIMARY KEY", plan)

    def test_a_page_of_the_apps_sessions_stays_under_two_megabytes(self):
        session = APP_REPORTS[0]
        size = self.dashboard["LIMITS"]["page"]
        for number in range(size):
            self.keep({**session, "session": f"{number:08x}-7a2f-4e19-8c3d-2f6a9b0e1d7c", "seq": number}, "2026-11-10")
        rows, _, count = self.db.execute(self.sql["page"], (1, TOP, size, "2026-11-10")).fetchone()
        self.assertEqual(count, size)
        self.assertLess(len(rows.encode()), 2_000_000)

    def test_what_the_server_took_and_the_problems_add_up(self):
        self.db.executemany("INSERT INTO daily (install, day, count) VALUES (?, ?, ?)", [
            ("a", "2026-11-10", 10), ("b", "2026-11-10", 5), ("a", "2026-11-09", 7), ("c", "2026-11-08", 3)])
        rows = self.db.execute(self.sql["received"], ("2026-11-09",)).fetchall()
        self.assertEqual(sorted(rows), [("2026-11-09", 7, 1), ("2026-11-10", 15, 2)])
        self.assertEqual(self.db.execute(self.sql["problems"], ("2026-11-10",)).fetchone(), (None, None))
        self.db.executemany("INSERT INTO problems (id, day, title, body, issue) VALUES (?, ?, ?, ?, ?)", [
            ("p1", "2026-11-10", "t", "b", None), ("p2", "2026-11-09", "t", "b", None), ("p3", "2026-11-10", "", "", 12)])
        self.assertEqual(self.db.execute(self.sql["problems"], ("2026-11-10",)).fetchone(), (2, 2))


if __name__ == "__main__":
    unittest.main()
