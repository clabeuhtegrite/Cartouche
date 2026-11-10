"""A stand-in for the part of Cloudflare's API that telemetry/deploy.sh and
telemetry/sheets.py call, for their tests. It runs the SQL it is sent on
SQLite, as D1 would: a script as it comes, or one statement with its
parameters, whose rows it answers. Under /github, it answers as GitHub's API
does for a repository, to the deploy's check of the problems' repository.
"""

import email
import email.policy
import json
import os
import re
import sqlite3
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse

ACCOUNT = "0123456789abcdef0123456789abcdef"
TOKEN = "a-token-for-the-tests"
PREFIX = f"/client/v4/accounts/{ACCOUNT}"
GITHUB_TOKEN = "github_pat_for_the_tests"


class Cloudflare:
    """What the stand-in holds, and every call it answered."""

    def __init__(self):
        self.calls = []
        self.databases = []
        self.subdomain = None
        self.sql = sqlite3.connect(":memory:", check_same_thread=False)
        self.sql.row_factory = sqlite3.Row
        self.queries = []
        self.scripts = {}
        # Each script's workers.dev address and daily run: name -> body.
        self.enabled = {}
        self.schedules = {}
        # GitHub's repositories the token can read: name -> private.
        self.repositories = {}

    def answer(self, method, path, query, headers, body):
        self.calls.append((method, path))
        if path.startswith("/github/repos/"):
            name = path[len("/github/repos/"):]
            if headers.get("Authorization") != f"Bearer {GITHUB_TOKEN}":
                return 401, {"message": "Bad credentials"}
            if method != "GET" or name not in self.repositories:
                return 404, {"message": "Not Found"}
            return 200, {"full_name": name, "private": self.repositories[name]}
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
            if match.group(1) not in [d["uuid"] for d in self.databases]:
                return 404, {"success": False, "errors": [{"code": 7404, "message": "No such database"}]}
            request = json.loads(body)
            self.last_sql = request["sql"]
            if "params" in request:
                self.queries.append((request["sql"], request["params"]))
                rows = [dict(row) for row in self.sql.execute(request["sql"], request["params"])]
            else:
                self.sql.executescript(request["sql"])
                rows = []
            return 200, {"success": True, "result": [{"success": True, "results": rows, "meta": {}}]}
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
                # Every module, by its name: its type and its bytes.
                "modules": {name: (part.get_content_type(), part.get_payload(decode=True))
                            for name, part in parts.items() if name != "metadata"},
            }
            return 200, {"success": True, "result": {"id": match.group(1)}}
        match = re.fullmatch(r"/workers/scripts/([^/]+)/subdomain", path)
        if method == "POST" and match:
            self.enabled[match.group(1)] = json.loads(body)
            return 200, {"success": True, "result": self.enabled[match.group(1)]}
        match = re.fullmatch(r"/workers/scripts/([^/]+)/schedules", path)
        if method == "PUT" and match:
            self.schedules[match.group(1)] = json.loads(body)
            return 200, {"success": True, "result": {"schedules": self.schedules[match.group(1)]}}
        return 404, {"success": False, "errors": [{"code": 7003, "message": f"No route for {method} {path}"}]}


def serve(cloudflare):
    """The stand-in on a port of its own, until the server is shut down."""

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


def environment(server, **values):
    """The environment of a run against the stand-in: no proxy, and nothing
    of the job's own summary or outputs unless given."""
    kept = {key: value for key, value in os.environ.items()
            if key.lower() not in ("http_proxy", "https_proxy", "all_proxy", "github_step_summary", "github_output")}
    kept.update(CLOUDFLARE_API=f"http://127.0.0.1:{server.server_port}/client/v4", NO_PROXY="127.0.0.1", **values)
    return kept
