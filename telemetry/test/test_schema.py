"""Checks the telemetry database (telemetry/schema.sql) with the statements
the Worker makes (telemetry/worker.js), on SQLite, which D1 is.

- schema.sql runs again without harm, as each deploy applies it;
- the Worker's statements run on it: the daily count adds up and gives its
  total back, a report sent again is kept once, and forgetting a copy of
  Cartouche or expiring old reports deletes what it should and nothing else.

Node reads the statements out of worker.js.

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
WORKER = HERE.parent / "worker.js"

INSTALL = "8c1f6c2e-7a2f-4e19-8c3d-2f6a9b0e1d7c"
OTHER = "11111111-2222-4333-8444-555555555555"


def schema_as_deployed() -> str:
    """schema.sql as deploy.sh sends it: without its comments."""
    lines = SCHEMA.read_text(encoding="utf-8").splitlines()
    return "\n".join(line for line in lines if not re.match(r"\s*--", line))


def worker_statements() -> dict:
    node = shutil.which("node")
    if node is None:
        raise unittest.SkipTest("node is not installed")
    script = "const { SQL } = await import(process.argv[1]); process.stdout.write(JSON.stringify(SQL));"
    result = subprocess.run([node, "--input-type=module", "-e", script, WORKER.as_uri()],
                            check=True, capture_output=True, text=True)
    return json.loads(result.stdout)


class SchemaTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.sql = worker_statements()

    def setUp(self):
        self.db = sqlite3.connect(":memory:")
        self.db.executescript(schema_as_deployed())

    def tearDown(self):
        self.db.close()

    def insert(self, id, install=INSTALL, day="2026-11-10", kind="event"):
        self.db.execute(self.sql["insert"], (id, kind, install, day, 1, "0.10.0", "iPhone19,4", "27.3",
                                             "0400C3F00006E000", "game.installed", None, "{}"))

    def count(self, install, day, added):
        return self.db.execute(self.sql["count"], (install, day, added)).fetchone()[0]

    def rows(self, table, column):
        return sorted(row[0] for row in self.db.execute(f"SELECT {column} FROM {table}"))

    def test_the_worker_makes_these_statements_only(self):
        self.assertEqual(sorted(self.sql),
                         ["count", "expireDaily", "expireReports", "forgetDaily", "forgetReports", "insert"])

    def test_the_schema_runs_again_without_harm(self):
        self.insert("a")
        self.db.executescript(schema_as_deployed())
        self.assertEqual(self.rows("reports", "id"), ["a"])

    def test_the_deploy_sends_no_comment(self):
        self.assertNotIn("--", schema_as_deployed())

    def test_the_daily_count_adds_up_and_gives_its_total(self):
        self.assertEqual(self.count(INSTALL, "2026-11-10", 2), 2)
        self.assertEqual(self.count(INSTALL, "2026-11-10", 3), 5)
        self.assertEqual(self.count(INSTALL, "2026-11-11", 1), 1)
        self.assertEqual(self.count(OTHER, "2026-11-10", 4), 4)

    def test_a_report_sent_again_is_kept_once(self):
        self.insert("a")
        self.insert("a")
        self.assertEqual(self.rows("reports", "id"), ["a"])

    def test_forgetting_a_copy_of_cartouche_leaves_the_others(self):
        self.insert("a")
        self.insert("b", install=OTHER)
        self.count(INSTALL, "2026-11-10", 1)
        self.count(OTHER, "2026-11-10", 1)
        self.db.execute(self.sql["forgetReports"], (INSTALL,))
        self.db.execute(self.sql["forgetDaily"], (INSTALL,))
        self.assertEqual(self.rows("reports", "install"), [OTHER])
        self.assertEqual(self.rows("daily", "install"), [OTHER])

    def test_old_reports_and_past_counts_go(self):
        self.insert("old", day="2024-10-09")
        self.insert("kept", day="2024-10-10")
        self.count(INSTALL, "2026-11-07", 1)
        self.count(INSTALL, "2026-11-08", 1)
        self.db.execute(self.sql["expireReports"], ("2024-10-10",))
        self.db.execute(self.sql["expireDaily"], ("2026-11-08",))
        self.assertEqual(self.rows("reports", "id"), ["kept"])
        self.assertEqual(self.rows("daily", "day"), ["2026-11-08"])


if __name__ == "__main__":
    unittest.main()
