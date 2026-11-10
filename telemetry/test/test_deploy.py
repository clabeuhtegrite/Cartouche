"""Checks telemetry/deploy.sh against a stand-in for Cloudflare's API.

- The first deploy creates the D1 database in the EU jurisdiction, applies
  schema.sql to it, uploads worker.js with the database bound as DB and no
  logs, creates the account's workers.dev subdomain when it has none, opens
  the Worker's address there and sets its daily run;
- a deploy again uses the same database and subdomain;
- a database of that name in another jurisdiction stops the deploy;
- without the secrets, the deploy does nothing.

The stand-in runs the SQL it is sent on SQLite, as D1 would.

Run from the repository root: python3 -m unittest discover -s telemetry/test -v
"""

import email
import email.policy
import json
import os
import re
import shutil
import sqlite3
import subprocess
import threading
import unittest
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import parse_qs, urlparse

HERE = Path(__file__).resolve().parent
DEPLOY = HERE.parent / "deploy.sh"
WORKER = HERE.parent / "worker.js"
ACCOUNT = "0123456789abcdef0123456789abcdef"
TOKEN = "a-token-for-the-tests"
PREFIX = f"/client/v4/accounts/{ACCOUNT}"


class Cloudflare:
    """What the stand-in holds, and every call it answered."""

    def __init__(self):
        self.calls = []
        self.databases = []
        self.subdomain = None
        self.sql = sqlite3.connect(":memory:", check_same_thread=False)
        self.scripts = {}
        self.enabled = None
        self.schedules = None

    def answer(self, method, path, query, headers, body):
        self.calls.append((method, path))
        if headers.get("Authorization") != f"Bearer {TOKEN}":
            return 403, {"success": False, "errors": [{"code": 10000, "message": "Authentication error"}]}
        if not path.startswith(PREFIX):
            return 404, {"success": False, "errors": [{"code": 7003, "message": "No route"}]}
        path = path[len(PREFIX):]
        if (method, path) == ("GET", "/d1/database"):
            name = query.get("name", [""])[0]
            return 200, {"success": True, "result": [d for d in self.databases if name in d["name"]]}
        if (method, path) == ("POST", "/d1/database"):
            request = json.loads(body)
            database = {"uuid": f"d1-{len(self.databases)}", **request}
            self.databases.append(database)
            return 200, {"success": True, "result": database}
        match = re.fullmatch(r"/d1/database/([^/]+)/query", path)
        if method == "POST" and match:
            self.sql.executescript(json.loads(body)["sql"])
            self.last_sql = json.loads(body)["sql"]
            return 200, {"success": True, "result": [{"success": True, "results": [], "meta": {}}]}
        if (method, path) == ("GET", "/workers/subdomain"):
            if self.subdomain is None:
                return 404, {"success": False, "errors": [{"code": 10007, "message": "This account has no subdomain"}]}
            return 200, {"success": True, "result": {"subdomain": self.subdomain}}
        if (method, path) == ("PUT", "/workers/subdomain"):
            self.subdomain = json.loads(body)["subdomain"]
            return 200, {"success": True, "result": {"subdomain": self.subdomain}}
        match = re.fullmatch(r"/workers/scripts/([^/]+)", path)
        if method == "PUT" and match:
            message = email.message_from_bytes(
                b"Content-Type: " + headers["Content-Type"].encode() + b"\r\n\r\n" + body, policy=email.policy.HTTP)
            parts = {part.get_param("name", header="content-disposition"): part for part in message.iter_parts()}
            self.scripts[match.group(1)] = {
                "metadata": json.loads(parts["metadata"].get_content()),
                "module type": parts["worker.js"].get_content_type(),
                "module": parts["worker.js"].get_payload(decode=True),
            }
            return 200, {"success": True, "result": {"id": match.group(1)}}
        match = re.fullmatch(r"/workers/scripts/([^/]+)/subdomain", path)
        if method == "POST" and match:
            self.enabled = json.loads(body)
            return 200, {"success": True, "result": self.enabled}
        match = re.fullmatch(r"/workers/scripts/([^/]+)/schedules", path)
        if method == "PUT" and match:
            self.schedules = json.loads(body)
            return 200, {"success": True, "result": {"schedules": self.schedules}}
        return 404, {"success": False, "errors": [{"code": 7003, "message": f"No route for {method} {path}"}]}


def serve(cloudflare):
    class Handler(BaseHTTPRequestHandler):
        def handle_one(self):
            url = urlparse(self.path)
            length = int(self.headers.get("Content-Length") or 0)
            body = self.rfile.read(length) if length else b""
            status, answer = cloudflare.answer(self.command, url.path, parse_qs(url.query), self.headers, body)
            data = json.dumps(answer).encode()
            self.send_response(status)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)

        do_GET = do_POST = do_PUT = handle_one

        def log_message(self, *args):
            pass

    server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    return server


@unittest.skipUnless(shutil.which("curl") and shutil.which("jq"), "the deploy needs curl and jq")
class DeployTest(unittest.TestCase):
    def setUp(self):
        self.cloudflare = Cloudflare()
        self.server = serve(self.cloudflare)
        self.addCleanup(self.cloudflare.sql.close)
        self.addCleanup(self.server.server_close)
        self.addCleanup(self.server.shutdown)

    def deploy(self, **secrets):
        environment = {key: value for key, value in os.environ.items()
                       if key.lower() not in ("http_proxy", "https_proxy", "all_proxy", "github_step_summary")}
        environment.update(CLOUDFLARE_API=f"http://127.0.0.1:{self.server.server_port}/client/v4",
                           TELEMETRY_CHECK_TRIES="0", NO_PROXY="127.0.0.1", **secrets)
        return subprocess.run(["bash", str(DEPLOY)], env=environment, capture_output=True, text=True, timeout=60)

    def deploy_with_secrets(self):
        return self.deploy(CLOUDFLARE_API_TOKEN=TOKEN, CLOUDFLARE_ACCOUNT_ID=ACCOUNT)

    def test_the_first_deploy_sets_everything_up(self):
        result = self.deploy_with_secrets()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(len(self.cloudflare.databases), 1)
        database = self.cloudflare.databases[0]
        self.assertEqual((database["name"], database["jurisdiction"]), ("cartouche-telemetry", "eu"))
        tables = {row[0] for row in self.cloudflare.sql.execute("SELECT name FROM sqlite_master WHERE type = 'table'")}
        self.assertEqual(tables, {"reports", "daily"})
        self.assertNotIn("--", self.cloudflare.last_sql)
        script = self.cloudflare.scripts["cartouche-telemetry"]
        self.assertEqual(script["metadata"]["main_module"], "worker.js")
        self.assertEqual(script["metadata"]["bindings"], [{"type": "d1", "name": "DB", "id": database["uuid"]}])
        self.assertEqual(script["metadata"]["observability"], {"enabled": False})
        self.assertRegex(script["metadata"]["compatibility_date"], r"^\d{4}-\d{2}-\d{2}$")
        self.assertEqual(script["module type"], "application/javascript+module")
        self.assertEqual(script["module"], WORKER.read_bytes())
        self.assertRegex(self.cloudflare.subdomain, r"^cartouche-[0-9a-f]{8}$")
        self.assertEqual(self.cloudflare.enabled, {"enabled": True, "previews_enabled": False})
        self.assertEqual(self.cloudflare.schedules, [{"cron": "17 3 * * *"}])
        self.assertIn(f"https://cartouche-telemetry.{self.cloudflare.subdomain}.workers.dev", result.stdout + result.stderr)
        self.assertNotIn(TOKEN, result.stdout + result.stderr)

    def test_a_deploy_again_keeps_the_database_and_the_subdomain(self):
        self.assertEqual(self.deploy_with_secrets().returncode, 0)
        subdomain = self.cloudflare.subdomain
        self.cloudflare.sql.execute("INSERT INTO reports (id, kind, install, day, body) VALUES ('a', 'event', 'i', 'd', '{}')")
        result = self.deploy_with_secrets()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(len(self.cloudflare.databases), 1)
        self.assertEqual(self.cloudflare.subdomain, subdomain)
        self.assertEqual(self.cloudflare.calls.count(("PUT", f"{PREFIX}/workers/subdomain")), 1)
        self.assertEqual(self.cloudflare.sql.execute("SELECT count(*) FROM reports").fetchone()[0], 1)

    def test_a_database_outside_the_eu_stops_the_deploy(self):
        self.cloudflare.databases.append({"uuid": "d1-us", "name": "cartouche-telemetry", "jurisdiction": "us"})
        result = self.deploy_with_secrets()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("not eu", result.stderr)
        self.assertEqual(self.cloudflare.scripts, {})

    def test_a_refusal_stops_the_deploy_with_cloudflares_words(self):
        result = self.deploy(CLOUDFLARE_API_TOKEN="another-token", CLOUDFLARE_ACCOUNT_ID=ACCOUNT)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("10000: Authentication error", result.stderr)
        self.assertEqual(self.cloudflare.databases, [])

    def test_without_the_secrets_nothing_happens(self):
        result = self.deploy()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("not deployed", result.stdout)
        self.assertEqual(self.cloudflare.calls, [])


if __name__ == "__main__":
    unittest.main()
