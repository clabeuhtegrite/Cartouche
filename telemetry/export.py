#!/usr/bin/env python3
"""Exports the telemetry database for one of the project's sessions, encrypted
for that session alone, so that the project can read its data itself from
where Cloudflare cannot be reached: the Telemetry export workflow
(.github/workflows/telemetry-export.yml, telemetry/README.md#export).

    python3 telemetry/export.py key --out DIR
        makes a key pair in DIR, export-key.pem, readable by its owner only,
        and prints its public key, which the workflow is run with;
    python3 telemetry/export.py export --key PUBLIC --out DIR [--days N]
        in the workflow, with the secrets CLOUDFLARE_API_TOKEN and
        CLOUDFLARE_ACCOUNT_ID: reads the database into a SQLite file and
        writes it into DIR, encrypted for PUBLIC;
    python3 telemetry/export.py open --key DIR/export-key.pem --ref FETCH_HEAD --out FILE
        decrypts the export the workflow left on the branch telemetry-export,
        once fetched (or --from a folder that holds its files), into FILE.

What leaves the database: each report as the server kept it, without its own
id, with the copy's random number and the session's cut to their first 8
digits, as the dashboard has them; how many reports each day brought and from
how many copies; and the day of each problem and whether GitHub has it. Never
a problem's words, which the private repository of the problems holds.

The SQLite file is gzipped and encrypted with AES-256-CBC under a random key;
that key, with the SHA-256 of what it encrypts, is encrypted with RSA-OAEP
(SHA-256) for the session's public key, an RSA key of 3072 bits or more.
Python's standard library and the openssl command only.
"""

from __future__ import annotations

import argparse
import base64
import datetime as dt
import gzip
import hashlib
import json
import os
import re
import sqlite3
import subprocess
import sys
import tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from sheets import API, DATABASE, Cloudflare, Refused  # noqa: E402  (the weekly sum's client of Cloudflare's API)

# What the workflow leaves on the branch, and what a session reads there.
MANIFEST = "export.json"
ENVELOPE = "telemetry.key.enc"
CONTENT = "telemetry.sqlite.gz.enc"
FILES = (MANIFEST, ENVELOPE, CONTENT)
PRIVATE_KEY = "export-key.pem"
SCHEMA = 1

KEY_BITS = 4096
LEAST_BITS = 3072
OAEP = ("-pkeyopt", "rsa_padding_mode:oaep", "-pkeyopt", "rsa_oaep_md:sha256", "-pkeyopt", "rsa_mgf1_md:sha256")
PAGE = 500

# The reports, a page at a time in the order the server received them, with
# D1's parameters as text. The first 8 digits of a random number are enough
# to count copies and sessions, as on the dashboard.
REPORTS = (
    "SELECT rowid AS n, kind, day, substr(install, 1, 8) AS install, seq, cartouche, device, ios, game, name, "
    "substr(session, 1, 8) AS session, json_remove(body, '$.id', '$.install', '$.session') AS body "
    f"FROM reports WHERE rowid > CAST(?1 AS INTEGER) AND day >= ?2 ORDER BY rowid LIMIT {PAGE}"
)
DAILY = "SELECT day, sum(count) AS reports, count(*) AS copies FROM daily WHERE day >= ?1 GROUP BY day ORDER BY day"
PROBLEMS = "SELECT day, issue IS NOT NULL AS filed FROM problems WHERE day >= ?1 ORDER BY day"

TABLES = """
CREATE TABLE reports (
  n INTEGER PRIMARY KEY,  -- the order the server received the reports in
  kind TEXT NOT NULL,
  day TEXT NOT NULL,
  install TEXT NOT NULL,
  seq INTEGER,
  cartouche TEXT,
  device TEXT,
  ios TEXT,
  game TEXT,
  name TEXT,
  session TEXT,
  body TEXT NOT NULL
);
CREATE INDEX reports_by_day ON reports (day);
CREATE TABLE daily (day TEXT PRIMARY KEY, reports INTEGER NOT NULL, copies INTEGER NOT NULL);
CREATE TABLE problems (day TEXT NOT NULL, filed INTEGER NOT NULL);
CREATE TABLE export (key TEXT PRIMARY KEY, value TEXT);
"""


def openssl(*arguments: str, data: bytes | None = None) -> bytes:
    """What openssl writes, or Refused with what it said."""
    try:
        done = subprocess.run(["openssl", *arguments], input=data, capture_output=True, timeout=300)
    except (OSError, subprocess.TimeoutExpired) as error:
        raise Refused(f"openssl could not run: {error}") from error
    if done.returncode != 0:
        said = done.stderr.decode(errors="replace").strip().splitlines()
        raise Refused(f"openssl {arguments[0]} failed: {said[0] if said else done.returncode}")
    return done.stdout


def fingerprint(public_der: bytes) -> str:
    """The key an export was made for, as the manifest and the commit name it."""
    return hashlib.sha256(public_der).hexdigest()[:16]


# MARK: The key


def make_key(out: Path) -> str:
    """Writes a key pair's private key into out, readable by its owner only,
    and returns its public key as the workflow takes it: its DER, in base64."""
    out.mkdir(parents=True, exist_ok=True)
    private = out / PRIVATE_KEY
    mask = os.umask(0o077)
    try:
        openssl("genpkey", "-algorithm", "RSA", "-pkeyopt", f"rsa_keygen_bits:{KEY_BITS}", "-out", str(private))
    finally:
        os.umask(mask)
    return base64.b64encode(openssl("pkey", "-in", str(private), "-pubout", "-outform", "DER")).decode()


def public_key(text: str, work: Path) -> bytes:
    """The DER of the public key the workflow was given, an RSA key of
    LEAST_BITS bits or more, or Refused."""
    text = "".join(text.split())
    if not text or len(text) > 4096 or not re.fullmatch(r"[A-Za-z0-9+/]+={0,2}", text):
        raise Refused("the key is not a public key in base64, as `export.py key` prints it")
    try:
        der = base64.b64decode(text, validate=True)
    except ValueError as error:
        raise Refused("the key is not a public key in base64, as `export.py key` prints it") from error
    path = work / "public.der"
    path.write_bytes(der)
    try:
        shown = openssl("pkey", "-pubin", "-inform", "DER", "-in", str(path), "-noout", "-text").decode(errors="replace")
    except Refused as error:
        raise Refused("the key is not a public key in base64, as `export.py key` prints it") from error
    bits = re.search(r"Public-Key: \((\d+) bit\)", shown)
    if "Modulus:" not in shown or not bits or int(bits.group(1)) < LEAST_BITS:
        raise Refused(f"the key must be an RSA key of {LEAST_BITS} bits or more")
    return der


# MARK: The export


def since(days: str, today: dt.date) -> str:
    """The first day of the export: the last N days, today's included, or
    every day the database holds when days is empty."""
    if days.strip() == "":
        return "0000-00-00"
    if not re.fullmatch(r"\d{1,4}", days.strip()) or int(days) < 1:
        raise Refused("days is a number of days, 1 or more, or empty for all of them")
    return (today - dt.timedelta(days=int(days) - 1)).isoformat()


def read_database(cloudflare: Cloudflare, first: str, into: Path) -> dict:
    """Copies what leaves the database into a new SQLite file; returns what
    it copied, for the export's own table."""
    database = cloudflare.database(DATABASE)
    sql = sqlite3.connect(into)
    try:
        sql.executescript(TABLES)
        count, after = 0, "0"
        while True:
            rows = cloudflare.query(database, REPORTS, [after, first])
            sql.executemany(
                "INSERT INTO reports VALUES (:n, :kind, :day, :install, :seq, :cartouche, :device, :ios, :game, "
                ":name, :session, :body)", rows)
            count += len(rows)
            if len(rows) < PAGE:
                break
            after = str(rows[-1]["n"])
        days = cloudflare.query(database, DAILY, [first])
        sql.executemany("INSERT INTO daily VALUES (:day, :reports, :copies)", days)
        problems = cloudflare.query(database, PROBLEMS, [first])
        sql.executemany("INSERT INTO problems VALUES (:day, :filed)", problems)
        made = {"schema": SCHEMA, "from": first, "reports": count, "days": len(days), "problems": len(problems)}
        sql.executemany("INSERT INTO export VALUES (?, ?)", [(key, str(value)) for key, value in made.items()])
        sql.commit()
        return made
    finally:
        sql.close()


def seal(plain: bytes, public_der: bytes, work: Path) -> tuple[bytes, bytes]:
    """plain encrypted for the key: the envelope, which holds the random key,
    its IV and plain's SHA-256 encrypted with RSA-OAEP, and the content."""
    secret, iv = os.urandom(32), os.urandom(16)
    content = openssl("enc", "-aes-256-cbc", "-K", secret.hex(), "-iv", iv.hex(), data=plain)
    path = work / "public.der"
    path.write_bytes(public_der)
    envelope = openssl("pkeyutl", "-encrypt", "-pubin", "-keyform", "DER", "-inkey", str(path), *OAEP,
                       data=secret + iv + hashlib.sha256(plain).digest())
    return envelope, content


def export(cloudflare: Cloudflare, key: str, days: str, out: Path, today: dt.date, run: str | None) -> dict:
    """Writes the export's three files into out; returns its manifest."""
    with tempfile.TemporaryDirectory() as folder:
        work = Path(folder)
        public_der = public_key(key, work)
        made = read_database(cloudflare, since(days, today), work / "telemetry.sqlite")
        plain = gzip.compress((work / "telemetry.sqlite").read_bytes(), mtime=0)
        envelope, content = seal(plain, public_der, work)
    manifest = {"schema": SCHEMA, "generated": dt.datetime.now(dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
                "key": fingerprint(public_der), "run": run}
    out.mkdir(parents=True, exist_ok=True)
    (out / ENVELOPE).write_bytes(envelope)
    (out / CONTENT).write_bytes(content)
    (out / MANIFEST).write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")
    return {**manifest, "reports": made["reports"]}


# MARK: Opening it


def read_files(ref: str | None, source: Path | None) -> dict[str, bytes]:
    """The export's files, from a commit git has (the branch, once fetched)
    or from a folder."""
    files = {}
    for name in FILES:
        if ref is not None:
            done = subprocess.run(["git", "show", f"{ref}:{name}"], capture_output=True, timeout=120)
            if done.returncode != 0:
                raise Refused(f"git has no {name} at {ref}: fetch the branch telemetry-export first")
            files[name] = done.stdout
        else:
            path = source / name
            if not path.is_file():
                raise Refused(f"{source} has no {name}")
            files[name] = path.read_bytes()
    return files


def unseal(files: dict[str, bytes], private: Path) -> bytes:
    """The SQLite file the export holds, for the session that holds the key
    it was made for, or Refused."""
    try:
        manifest = json.loads(files[MANIFEST])
    except ValueError as error:
        raise Refused("the export's manifest is not JSON") from error
    if not isinstance(manifest, dict) or manifest.get("schema") != SCHEMA:
        raise Refused("this export is of another format: update telemetry/export.py")
    mine = fingerprint(openssl("pkey", "-in", str(private), "-pubout", "-outform", "DER"))
    if manifest.get("key") != mine:
        raise Refused(f"this export was made for the key {manifest.get('key')}, not {mine}: run the workflow with yours")
    opened = openssl("pkeyutl", "-decrypt", "-inkey", str(private), *OAEP, data=files[ENVELOPE])
    if len(opened) != 80:
        raise Refused("the export's envelope is damaged")
    secret, iv, digest = opened[:32], opened[32:48], opened[48:]
    plain = openssl("enc", "-d", "-aes-256-cbc", "-K", secret.hex(), "-iv", iv.hex(), data=files[CONTENT])
    if hashlib.sha256(plain).digest() != digest:
        raise Refused("the export is damaged: its content is not what was encrypted")
    return gzip.decompress(plain)


# MARK: The command


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    commands = parser.add_subparsers(dest="command", required=True)
    key = commands.add_parser("key", help="make a key pair and print its public key")
    key.add_argument("--out", type=Path, required=True, help="the folder of the private key")
    made = commands.add_parser("export", help="read the database and encrypt it for a public key")
    made.add_argument("--key", required=True, help="the public key, as `key` prints it")
    made.add_argument("--days", default="", help="only the reports of the last N days; all of them when empty")
    made.add_argument("--out", type=Path, required=True, help="where the export's files are written")
    made.add_argument("--today", type=dt.date.fromisoformat, default=dt.datetime.now(dt.timezone.utc).date())
    opened = commands.add_parser("open", help="decrypt an export into a SQLite file")
    opened.add_argument("--key", type=Path, required=True, help="the private key, export-key.pem")
    where = opened.add_mutually_exclusive_group(required=True)
    where.add_argument("--ref", help="the commit of the branch telemetry-export, such as FETCH_HEAD")
    where.add_argument("--from", dest="source", type=Path, help="a folder that holds the export's files")
    opened.add_argument("--out", type=Path, required=True, help="the SQLite file to write")
    args = parser.parse_args(argv)

    try:
        if args.command == "key":
            print(make_key(args.out))
            return 0
        if args.command == "export":
            token, account = os.environ.get("CLOUDFLARE_API_TOKEN"), os.environ.get("CLOUDFLARE_ACCOUNT_ID")
            if not token or not account:
                raise Refused("CLOUDFLARE_API_TOKEN and CLOUDFLARE_ACCOUNT_ID are not set: the database cannot be read")
            cloudflare = Cloudflare(account, token, os.environ.get("CLOUDFLARE_API") or API)
            manifest = export(cloudflare, args.key, args.days, args.out, args.today, os.environ.get("GITHUB_RUN_ID"))
            # Nothing of what the database holds goes to the job's log.
            print(f"The export is encrypted for the key {manifest['key']}.")
            return 0
        sqlite = unseal(read_files(args.ref, args.source), args.key)
        args.out.parent.mkdir(parents=True, exist_ok=True)
        mask = os.umask(0o077)
        try:
            args.out.write_bytes(sqlite)
        finally:
            os.umask(mask)
        print(f"Opened into {args.out}.")
        return 0
    except Refused as error:
        print(f"::error::{error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
