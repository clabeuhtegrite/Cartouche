"""Checks telemetry/export.py, which exports the telemetry database encrypted
for one session's key, against a stand-in for Cloudflare's API (standin.py)
whose D1 database holds the reports of app-reports.json and
builder-reports.json as the Worker keeps them.

- the session that made the key opens the export into SQLite, and finds each
  report whole, without its id, with the copy's and the session's random
  numbers cut to their first 8 digits; the days' counts; the problems' days,
  never their words;
- nothing of the database can be read in the files without the key, and
  another key cannot open them;
- only an RSA public key of 3072 bits or more is taken; --days keeps the
  last days; the reports are read a page at a time;
- without the secrets, nothing is read, and the run fails.

Run from the repository root: python3 -m unittest discover -s telemetry/test -v
"""

import base64
import copy
import json
import re
import shutil
import sqlite3
import subprocess
import sys
import tempfile
import unittest
import uuid
from pathlib import Path

from standin import ACCOUNT, TOKEN, Cloudflare, environment, serve

HERE = Path(__file__).resolve().parent
EXPORT = HERE.parent / "export.py"
SCHEMA = HERE.parent / "schema.sql"
TODAY = "2026-11-11"
INSTALL = "8c1f6c2e-7a2f-4e19-8c3d-2f6a9b0e1d7c"
MAC = "5d2e7f10-3c4b-4a5d-9e6f-7a8b9c0d1e2f"
FILES = ("export.json", "telemetry.key.enc", "telemetry.sqlite.gz.enc")

APP = json.loads((HERE / "app-reports.json").read_text(encoding="utf-8"))["reports"]
BUILDER = json.loads((HERE / "builder-reports.json").read_text(encoding="utf-8"))["reports"]


def schema_as_deployed() -> str:
    lines = SCHEMA.read_text(encoding="utf-8").splitlines()
    return "\n".join(line for line in lines if not line.lstrip().startswith("--"))


def run(*arguments, env=None, check=True):
    done = subprocess.run([sys.executable, str(EXPORT), *arguments], env=env, capture_output=True, text=True,
                          timeout=300)
    if check:
        assert done.returncode == 0, done.stderr
    return done


class ExportTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.keys = Path(tempfile.mkdtemp())
        cls.public = run("key", "--out", str(cls.keys / "mine")).stdout.strip()
        cls.other = run("key", "--out", str(cls.keys / "other")).stdout.strip()

    @classmethod
    def tearDownClass(cls):
        shutil.rmtree(cls.keys)

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

    # MARK: Helpers

    def keep(self, report, install=INSTALL, day=TODAY):
        """A report as the Worker keeps it."""
        report = copy.deepcopy(report)
        report.update(id=str(uuid.uuid4()), install=install)
        self.cloudflare.sql.execute(
            "INSERT INTO reports (id, kind, install, day, seq, cartouche, device, ios, game, name, session, body) "
            "VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
            (report["id"], report["kind"], install, day, report.get("seq"), report.get("cartouche"),
             report.get("device"), report.get("ios"), report.get("game"), report.get("name"), report.get("session"),
             json.dumps(report)))
        return report

    def fill(self):
        kept = [self.keep(report) for report in APP] + [self.keep(report, install=MAC) for report in BUILDER]
        self.cloudflare.sql.executemany("INSERT INTO daily VALUES (?, ?, ?)",
                                        [(INSTALL, TODAY, 2), (MAC, TODAY, len(BUILDER)), (INSTALL, "2026-11-10", 5)])
        self.cloudflare.sql.executemany(
            "INSERT INTO problems VALUES (?, ?, ?, ?, ?)",
            [(str(uuid.uuid4()), TODAY, "The game quits at the second race", "What the player wrote", None),
             (str(uuid.uuid4()), "2026-11-10", "", "", 3)])
        return kept

    def export(self, key=None, days=None, secrets=True):
        values = {"CLOUDFLARE_API_TOKEN": TOKEN, "CLOUDFLARE_ACCOUNT_ID": ACCOUNT} if secrets else {}
        arguments = ["export", "--key", self.public if key is None else key, "--out", str(self.work / "export"), "--today", TODAY]
        if days is not None:
            arguments += ["--days", days]
        return run(*arguments, env=environment(self.server, **values), check=False)

    def open(self, key="mine", check=True):
        out = self.work / f"opened-{key}.sqlite"
        done = run("open", "--key", str(self.keys / key / "export-key.pem"), "--from", str(self.work / "export"),
                   "--out", str(out), check=check)
        if done.returncode != 0:
            return done
        sql = sqlite3.connect(out)
        sql.row_factory = sqlite3.Row
        self.addCleanup(sql.close)
        return sql

    # MARK: Tests

    def test_the_session_with_the_key_finds_every_report_whole(self):
        kept = self.fill()
        done = self.export()
        self.assertEqual(done.returncode, 0, done.stderr)
        self.assertEqual(sorted(p.name for p in (self.work / "export").iterdir()), sorted(FILES))
        sql = self.open()
        rows = sql.execute("SELECT * FROM reports ORDER BY n").fetchall()
        self.assertEqual(len(rows), len(kept))
        for row, report in zip(rows, kept):
            self.assertEqual(row["install"], report["install"][:8])
            self.assertEqual(row["session"], report["session"][:8] if report.get("session") else None)
            self.assertEqual((row["kind"], row["day"], row["device"], row["game"], row["name"]),
                             (report["kind"], TODAY, report.get("device"), report.get("game"), report.get("name")))
            body = json.loads(row["body"])
            whole = {key: value for key, value in report.items() if key not in ("id", "install", "session")}
            self.assertEqual(body, whole)
        session = sql.execute("SELECT json_extract(body, '$.fps.median') AS fps, json_extract(body, '$.end.pc') AS pc "
                              "FROM reports WHERE kind = 'session'").fetchone()
        self.assertEqual((session["fps"], session["pc"]), (59.9, "main+0x1a2b3c"))
        self.assertEqual([tuple(r) for r in sql.execute("SELECT day, reports, copies FROM daily ORDER BY day")],
                         [("2026-11-10", 5, 1), (TODAY, 2 + len(BUILDER), 2)])
        self.assertEqual([tuple(r) for r in sql.execute("SELECT day, filed FROM problems ORDER BY day")],
                         [("2026-11-10", 1), (TODAY, 0)])
        made = dict(sql.execute("SELECT key, value FROM export").fetchall())
        self.assertEqual(made["reports"], str(len(kept)))

    def test_nothing_of_the_database_shows_without_the_key(self):
        self.fill()
        done = self.export()
        self.assertEqual(done.returncode, 0, done.stderr)
        files = {name: (self.work / "export" / name).read_bytes() for name in FILES}
        for secret in (INSTALL[:8].encode(), MAC[:8].encode(), b"iPhone19,4", b"Mac16,12", b"0400C3F00006E000",
                       b"SQLite format", b"second race"):
            for name, data in files.items():
                self.assertNotIn(secret, data, f"{secret!r} in {name}")
        # Nor in the job's log.
        for secret in (INSTALL[:8], "iPhone19,4", "0400C3F00006E000"):
            self.assertNotIn(secret, done.stdout + done.stderr)
        manifest = json.loads(files["export.json"])
        self.assertEqual(sorted(manifest), ["generated", "key", "run", "schema"])
        self.assertRegex(manifest["key"], r"^[0-9a-f]{16}$")

    def test_another_key_cannot_open_it(self):
        self.fill()
        self.assertEqual(self.export().returncode, 0)
        done = self.open("other", check=False)
        self.assertNotEqual(done.returncode, 0)
        self.assertIn("made for the key", done.stderr)
        # Nor with the manifest made to name it.
        manifest = self.work / "export" / "export.json"
        named = json.loads(manifest.read_text())
        named["key"] = re.search(r"not ([0-9a-f]{16})", done.stderr).group(1)
        manifest.write_text(json.dumps(named))
        forged = self.open("other", check=False)
        self.assertNotEqual(forged.returncode, 0)
        self.assertFalse((self.work / "opened-other.sqlite").exists())

    def test_a_damaged_export_does_not_open(self):
        self.fill()
        self.assertEqual(self.export().returncode, 0)
        content = self.work / "export" / "telemetry.sqlite.gz.enc"
        data = bytearray(content.read_bytes())
        data[len(data) // 2] ^= 0x01
        content.write_bytes(bytes(data))
        done = self.open(check=False)
        self.assertNotEqual(done.returncode, 0)

    def test_only_an_rsa_key_of_3072_bits_or_more_is_taken(self):
        self.fill()
        small = self.work / "small.pem"
        subprocess.run(["openssl", "genpkey", "-algorithm", "RSA", "-pkeyopt", "rsa_keygen_bits:2048", "-out", str(small)],
                       check=True, capture_output=True)
        curve = self.work / "curve.pem"
        subprocess.run(["openssl", "genpkey", "-algorithm", "EC", "-pkeyopt", "ec_paramgen_curve:P-256", "-out", str(curve)],
                       check=True, capture_output=True)

        def public(path):
            der = subprocess.run(["openssl", "pkey", "-in", str(path), "-pubout", "-outform", "DER"], check=True,
                                 capture_output=True).stdout
            return base64.b64encode(der).decode()

        for key in (public(small), public(curve), "not a key", base64.b64encode(b"\x30\x03\x02\x01\x01").decode(), ""):
            done = self.export(key=key)
            self.assertNotEqual(done.returncode, 0, key)
            self.assertFalse((self.work / "export").exists(), key)
        self.assertEqual(self.cloudflare.queries, [], "the database was read for a key not taken")

    def test_days_keeps_only_the_last_days(self):
        self.fill()
        old = self.keep(APP[1], day="2026-10-01")
        self.assertEqual(self.export(days="7").returncode, 0)
        sql = self.open()
        self.assertEqual(sql.execute("SELECT count(*) FROM reports WHERE day < '2026-11-05'").fetchone()[0], 0)
        self.assertEqual(sql.execute("SELECT count(*) FROM reports").fetchone()[0], len(APP) + len(BUILDER))
        shutil.rmtree(self.work / "export")
        self.assertEqual(self.export(days="").returncode, 0)
        sql = self.open()
        self.assertEqual(sql.execute("SELECT min(day) FROM reports").fetchone()[0], "2026-10-01")
        self.assertEqual(old["install"][:8], sql.execute("SELECT install FROM reports WHERE day = '2026-10-01'").fetchone()[0])
        for days in ("0", "-3", "seven", "7; DROP TABLE reports"):
            self.assertNotEqual(self.export(days=days).returncode, 0, days)

    def test_the_reports_are_read_a_page_at_a_time(self):
        event = next(r for r in APP if r["kind"] == "event")
        for index in range(1203):
            self.keep({**event, "seq": index + 1})
        self.assertEqual(self.export().returncode, 0)
        sql = self.open()
        self.assertEqual(sql.execute("SELECT count(*), count(DISTINCT n) FROM reports").fetchone()[:], (1203, 1203))
        pages = [query for query in self.cloudflare.queries if query[0].startswith("SELECT rowid AS n")]
        self.assertEqual(len(pages), 3)

    def test_without_the_secrets_nothing_is_read(self):
        self.fill()
        done = self.export(secrets=False)
        self.assertNotEqual(done.returncode, 0)
        self.assertIn("CLOUDFLARE_API_TOKEN", done.stderr)
        self.assertEqual(self.cloudflare.calls, [])
        self.assertFalse((self.work / "export").exists())


if __name__ == "__main__":
    unittest.main()
