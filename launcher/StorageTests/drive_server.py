#!/usr/bin/env python3
"""A stand-in for Google's servers, for the storage tests: the sign-in of
the player's own OAuth client, of the iOS type, with PKCE, and the Drive API,
version 3, as Cartouche uses them (launcher/Sources/CartoucheStorageDrive.swift),
on 127.0.0.1, with Python's standard library alone.

usage: drive_server.py --port P --root DIR --data DIR --client-id ID
                       --account EMAIL --refresh-token-file F
                       --read-only FOLDER --games FOLDER --small NAME
                       [--page-size N]

DIR's folders and files are the player's My Drive, read where they are; a
file sent to it is kept in --data, and a file removed is removed for good, as
Cartouche removes them. The refresh token in F is a sign-in the player made
once, which servers.json gives the tests; each sign-in on the page gives
another. FOLDER, at the root, is one the player's account can only read, as
Drive says of a folder shared with it to read only. The games folder also
holds what Cartouche must neither list nor read: a Google Doc, a shortcut, a
file in the bin, a file whose name has a "/", and an older file of the small
IPA's name; the root, a folder named on a Mac, "Partie enregistrée", with
"écran.txt" in it, both decomposed (NFD). A page of a listing holds N files
at most, 4 by default, so that Cartouche reads the games folder in several.

As Google's servers do: an access token lasts an hour; Drive's files are
found by queries, and a name can be on several; a file is read by ranges,
and written with the resumable upload, in pieces of 256 KiB multiples but
the last, the server saying how much it holds; and the errors come as
Google gives them (the reasons of the errors of the Drive API, the codes of
OAuth's), but that a message never names a real project.

What only the tests ask, with POST, on /test/:

    expire                    every access token ends, as after an hour
    revoke?refresh_token=T    T ends, as Google ends it after 7 days
    next-sign-in?refuse=1     the player does not allow the access
    next-sign-in?scope=S      the player allows S alone
    next-sign-in?lasting=0    the code gives no refresh token
    fail?path=P&method=M&status=S&reason=R&count=N
                              the next N requests on paths starting with P,
                              of the method M if given, fail with S and R
    cut-next-upload?mode=M    the next piece sent: half of it kept, then 503
                              (M = 503) or the connection closed (M = close)
    redirect-next?path=P      the next request on P is sent elsewhere (302)
    drive-off?on=1            the Drive API is off in the player's project
    full?on=1                 the Drive is full
    reset                     none of these any more

Every request is logged to stderr, without a token, a code or a secret, for
the tests to see what Cartouche asked.
"""

from __future__ import annotations

import argparse
import base64
import hashlib
import json
import os
import re
import secrets
import sys
import threading
import time
import unicodedata
import urllib.parse
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

FOLDER = "application/vnd.google-apps.folder"
DOCUMENT = "application/vnd.google-apps.document"
SHORTCUT = "application/vnd.google-apps.shortcut"
GOOGLE_TYPES = "application/vnd.google-apps."
DRIVE_SCOPE = "https://www.googleapis.com/auth/drive"
GRANULE = 256 << 10
LIMIT = 15 << 30
BLOCK = 1 << 20
# A project number as Google writes them, which is no one's.
PROJECT = "123456789012"
ACTIVATION = f"https://console.developers.google.com/apis/api/drive.googleapis.com/overview?project={PROJECT}"
# What a Mac named, decomposed, at the root.
DECOMPOSED_FOLDER = "Partie enregistrée"
DECOMPOSED_FILE = "écran.txt"
DECOMPOSED_TEXT = "Écran titre\n".encode("utf-8")


def now_text(when: float | None = None) -> str:
    moment = datetime.fromtimestamp(time.time() if when is None else when, tz=timezone.utc)
    return moment.strftime("%Y-%m-%dT%H:%M:%S.") + f"{moment.microsecond // 1000:03d}Z"


def new_id() -> str:
    """A file's ID, as Drive's look: 33 characters of base64url."""
    return "1" + secrets.token_urlsafe(24)[:32]


def token(prefix: str) -> str:
    return prefix + secrets.token_urlsafe(32)


def challenge_of(verifier: str) -> str:
    digest = hashlib.sha256(verifier.encode("ascii")).digest()
    return base64.urlsafe_b64encode(digest).decode("ascii").rstrip("=")


class Item:
    """A file or a folder of the Drive."""

    def __init__(self, name: str, mime: str, parent: str | None, path: Path | None = None,
                 size: int | None = None, modified: float | None = None, owned: bool = False):
        self.id = new_id()
        self.name = name
        self.mime = mime
        self.parent = parent
        self.path = path
        self.size = size
        self.modified = time.time() if modified is None else modified
        self.trashed = False
        # Whether the account can add to it, for a folder.
        self.writable = True
        # Whether its bytes are the server's own, to remove with it.
        self.owned = owned

    @property
    def is_folder(self) -> bool:
        return self.mime == FOLDER

    @property
    def is_binary(self) -> bool:
        return not self.mime.startswith(GOOGLE_TYPES)

    def resource(self) -> dict:
        body = {"kind": "drive#file", "id": self.id, "name": self.name, "mimeType": self.mime,
                "modifiedTime": now_text(self.modified), "trashed": self.trashed}
        if self.parent:
            body["parents"] = [self.parent]
        if self.is_binary and self.size is not None:
            body["size"] = str(self.size)
        return body


class Upload:
    """A resumable upload, from its start to the file it makes."""

    def __init__(self, name: str, parent: str, mime: str, declared: int | None, blob: Path):
        self.id = secrets.token_urlsafe(24)
        self.name = name
        self.parent = parent
        self.mime = mime
        self.declared = declared
        self.blob = blob
        self.held = 0
        self.file: Item | None = None
        self.lock = threading.Lock()
        blob.write_bytes(b"")


class Drive:
    """The Drive, its sign-ins and what the tests asked of it."""

    def __init__(self, args: argparse.Namespace):
        self.lock = threading.RLock()
        self.client = args.client_id
        self.redirect = "com.googleusercontent.apps." + args.client_id[: -len(".apps.googleusercontent.com")] + ":/oauth2redirect"
        self.account = args.account
        self.page_size = args.page_size
        self.data = Path(args.data)
        (self.data / "blobs").mkdir(parents=True, exist_ok=True)
        self.items: dict[str, Item] = {}
        root = Item("My Drive", FOLDER, None)
        root.id = "0A" + secrets.token_urlsafe(16)[:17] + "Uk9PVA"
        self.root = root.id
        self.items[root.id] = root
        self.codes: dict[str, dict] = {}
        self.refresh: dict[str, dict] = {}
        self.access: dict[str, dict] = {}
        self.pages: dict[str, tuple[str, int]] = {}
        self.uploads: dict[str, Upload] = {}
        self.reset()
        with open(args.refresh_token_file, encoding="utf-8") as f:
            self.refresh[f.read().strip()] = {"scope": DRIVE_SCOPE}
        self.seed(Path(args.root), root.id)
        read_only = self.child(root.id, args.read_only)
        if read_only is None:
            raise SystemExit(f"no folder {args.read_only} in {args.root}")
        self.close_folder(read_only)
        games = self.child(root.id, args.games)
        if games is None:
            raise SystemExit(f"no folder {args.games} in {args.root}")
        self.add_oddities(games, args.small)

    def reset(self) -> None:
        with self.lock:
            self.sign_in: dict = {}
            self.failures: list[dict] = []
            self.cut: str | None = None
            self.redirects: list[str] = []
            self.drive_off = False
            self.full = False

    # MARK: The files

    def seed(self, folder: Path, parent: str) -> None:
        for entry in sorted(folder.iterdir()):
            if entry.is_dir():
                item = Item(entry.name, FOLDER, parent, modified=entry.stat().st_mtime)
                self.items[item.id] = item
                self.seed(entry, item.id)
            elif entry.is_file():
                info = entry.stat()
                item = Item(entry.name, "application/octet-stream", parent, path=entry, size=info.st_size,
                            modified=info.st_mtime)
                self.items[item.id] = item

    def close_folder(self, folder: Item) -> None:
        folder.writable = False
        for item in list(self.items.values()):
            if item.parent == folder.id and item.is_folder:
                self.close_folder(item)

    def add_oddities(self, games: Item, small: str) -> None:
        def add(item: Item) -> Item:
            self.items[item.id] = item
            return item

        add(Item("Notes de jeux", DOCUMENT, games.id))
        add(Item("Raccourci vers " + small, SHORTCUT, games.id))
        bin_ipa = self.data / "blobs" / "corbeille.ipa"
        bin_ipa.write_bytes(b"PK\x03\x04 dans la corbeille")
        add(Item("Dans la corbeille [0100CA27C0DE2000].ipa", "application/octet-stream", games.id, path=bin_ipa,
                 size=bin_ipa.stat().st_size, owned=True)).trashed = True
        slash = self.data / "blobs" / "barre.ipa"
        slash.write_bytes(b"PK\x03\x04 un nom avec une barre")
        add(Item("Jeux/Noël [0100CA27C0DE3000].ipa", "application/octet-stream", games.id, path=slash,
                 size=slash.stat().st_size, owned=True))
        # An older file of the small IPA's name, as Drive keeps both when one
        # is sent again: Cartouche reads the newest.
        older = self.data / "blobs" / "ancienne.ipa"
        older.write_bytes(b"Une ancienne copie, que Cartouche ne lit pas.\n" * 64)
        add(Item(small, "application/octet-stream", games.id, path=older, size=older.stat().st_size,
                 modified=time.time() - 400 * 86400, owned=True))
        # A folder and a file named on a Mac, decomposed: Cartouche finds
        # them by their composed names too.
        folder = add(Item(unicodedata.normalize("NFD", DECOMPOSED_FOLDER), FOLDER, self.root))
        screen = self.data / "blobs" / "ecran.txt"
        screen.write_bytes(DECOMPOSED_TEXT)
        add(Item(unicodedata.normalize("NFD", DECOMPOSED_FILE), "text/plain", folder.id, path=screen,
                 size=len(DECOMPOSED_TEXT), owned=True))

    def child(self, parent: str, name: str) -> Item | None:
        for item in self.items.values():
            if item.parent == parent and item.name == name and not item.trashed:
                return item
        return None

    def resolve(self, file_id: str) -> Item | None:
        return self.items.get(self.root if file_id == "root" else file_id)

    def usage(self) -> int:
        return sum(item.size or 0 for item in self.items.values() if item.is_binary)

    def remove(self, item: Item) -> None:
        for other in [other for other in self.items.values() if other.parent == item.id]:
            self.remove(other)
        self.items.pop(item.id, None)
        if item.owned and item.path is not None:
            item.path.unlink(missing_ok=True)

    def writable(self, folder: Item) -> bool:
        return folder.is_folder and folder.writable


class Failure(Exception):
    """An answer of the Drive API's other than 2xx."""

    def __init__(self, status: int, reason: str, message: str, domain: str = "global", extra: dict | None = None):
        super().__init__(message)
        self.status = status
        self.body = {"error": {"code": status, "message": message,
                               "errors": [{"message": message, "domain": domain, "reason": reason}]}}
        if extra:
            self.body["error"].update(extra)


def not_found(file_id: str) -> Failure:
    return Failure(404, "notFound", f"File not found: {file_id}.")


def no_permission(file_id: str) -> Failure:
    return Failure(403, "insufficientFilePermissions",
                   f"The user does not have sufficient permissions for file {file_id}.")


def drive_off() -> Failure:
    message = (f"Google Drive API has not been used in project {PROJECT} before or it is disabled. Enable it by "
               f"visiting {ACTIVATION} then retry. If you enabled this API recently, wait a few minutes for the "
               "action to propagate to our systems and retry.")
    return Failure(403, "accessNotConfigured", message, domain="usageLimits", extra={
        "status": "PERMISSION_DENIED",
        "details": [
            {"@type": "type.googleapis.com/google.rpc.ErrorInfo", "reason": "SERVICE_DISABLED",
             "domain": "googleapis.com",
             "metadata": {"service": "drive.googleapis.com", "consumer": f"projects/{PROJECT}",
                          "activationUrl": ACTIVATION, "containerInfo": PROJECT,
                          "serviceTitle": "Google Drive API"}},
            {"@type": "type.googleapis.com/google.rpc.LocalizedMessage", "locale": "en-US", "message": message},
            {"@type": "type.googleapis.com/google.rpc.Help",
             "links": [{"description": "Google developers console API activation", "url": ACTIVATION}]},
        ],
    })


QUOTED = r"'((?:[^'\\]|\\.)*)'"
IN_PARENTS = re.compile(r"^" + QUOTED + r"\s+in\s+parents$")
NAME_IS = re.compile(r"^name\s*=\s*" + QUOTED + r"$")
TRASHED_IS = re.compile(r"^trashed\s*=\s*(true|false)$")
CONTENT_RANGE = re.compile(r"^bytes (?:(\d+)-(\d+)|\*)/(\d+|\*)$")
READ_RANGE = re.compile(r"^bytes=(\d+)-(\d*)$")


def clauses(query: str) -> list[str]:
    """QUERY's clauses, between its "and"s outside quotes."""
    parts, current, quoted, index = [], [], False, 0
    while index < len(query):
        char = query[index]
        if quoted:
            current.append(char)
            if char == "\\" and index + 1 < len(query):
                current.append(query[index + 1])
                index += 2
                continue
            if char == "'":
                quoted = False
        elif char == "'":
            quoted = True
            current.append(char)
        elif query.startswith(" and ", index):
            parts.append("".join(current).strip())
            current = []
            index += 5
            continue
        else:
            current.append(char)
        index += 1
    parts.append("".join(current).strip())
    return parts


def unquote(text: str) -> str:
    return re.sub(r"\\(.)", r"\1", text)


def matcher(drive: Drive, query: str):
    """What QUERY finds, as a test of an item; Failure for what Drive would
    not take."""
    tests = []
    for clause in clauses(query):
        if not clause:
            continue
        if found := IN_PARENTS.match(clause):
            parent = unquote(found.group(1))
            parent = drive.root if parent == "root" else parent
            tests.append(lambda item, parent=parent: item.parent == parent)
        elif found := NAME_IS.match(clause):
            name = unquote(found.group(1))
            tests.append(lambda item, name=name: item.name == name)
        elif found := TRASHED_IS.match(clause):
            trashed = found.group(1) == "true"
            tests.append(lambda item, trashed=trashed: item.trashed == trashed)
        else:
            raise Failure(400, "invalid", "Invalid Value", extra={"status": "INVALID_ARGUMENT"})
    return lambda item: item.id != drive.root and all(test(item) for test in tests)


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    server_version = "CartoucheDriveStandIn/1"
    # Each answer at once: its headers and its body go in two writes, which
    # Nagle's algorithm would hold until the client acknowledges the first.
    disable_nagle_algorithm = True
    drive: Drive

    # MARK: Answering

    def log_message(self, format: str, *args) -> None:  # noqa: A002
        pass

    def note(self, status: int, extra: str = "") -> None:
        """The request, as the log keeps it: its method, its path and the
        query's parts that say what Cartouche asked, never a token."""
        split = urllib.parse.urlsplit(self.path)
        query = urllib.parse.parse_qs(split.query, keep_blank_values=True)
        shown = []
        for name in ("q", "uploadType", "alt", "fields", "pageToken", "prompt", "login_hint"):
            if name in query:
                value = "…" if name == "pageToken" else query[name][0]
                shown.append(f"{name}={value}")
        for header in ("Range", "Content-Range"):
            if self.headers.get(header):
                shown.append(f"{header}: {self.headers[header]}")
        line = f"{now_text()} {self.command} {split.path} {' '.join(shown)} -> {status}{' ' + extra if extra else ''}"
        sys.stderr.write(line.replace("\n", " ") + "\n")
        sys.stderr.flush()

    def answer(self, status: int, body: bytes = b"", content_type: str = "application/json; charset=UTF-8",
               headers: dict | None = None, extra: str = "", reason: str | None = None) -> None:
        self.drain()
        self.note(status, extra)
        self.send_response(status, reason)
        if body or status not in (204, 308):
            self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        for name, value in (headers or {}).items():
            self.send_header(name, value)
        self.end_headers()
        if body and self.command != "HEAD":
            self.wfile.write(body)

    def json(self, status: int, body: dict, headers: dict | None = None, extra: str = "") -> None:
        self.answer(status, json.dumps(body).encode("utf-8"), headers=headers, extra=extra)

    def fail(self, failure: Failure) -> None:
        self.json(failure.status, failure.body, extra=failure.body["error"]["errors"][0]["reason"])

    def body(self) -> bytes:
        """What the request sent, read once."""
        if self.consumed:
            return b""
        self.consumed = True
        length = int(self.headers.get("Content-Length") or 0)
        return self.rfile.read(length) if length else b""

    def drain(self) -> None:
        """What the request sent that was not read, read, for the connection
        to take the next one."""
        length = int(self.headers.get("Content-Length") or 0) if not self.consumed else 0
        self.consumed = True
        while length > 0:
            chunk = self.rfile.read(min(BLOCK, length))
            if not chunk:
                self.close_connection = True
                return
            length -= len(chunk)

    def query(self) -> dict[str, str]:
        split = urllib.parse.urlsplit(self.path)
        return {name: values[0] for name, values in urllib.parse.parse_qs(split.query, keep_blank_values=True).items()}

    # MARK: Requests

    def do_GET(self) -> None:  # noqa: N802
        self.route()

    def do_POST(self) -> None:  # noqa: N802
        self.route()

    def do_PUT(self) -> None:  # noqa: N802
        self.route()

    def do_DELETE(self) -> None:  # noqa: N802
        self.route()

    def route(self) -> None:
        self.consumed = False
        path = urllib.parse.urlsplit(self.path).path
        try:
            if path.startswith("/test/"):
                return self.test_hook(path[len("/test/"):])
            if path == "/o/oauth2/v2/auth" and self.command == "GET":
                return self.sign_in_page()
            if path == "/token" and self.command == "POST":
                return self.token()
            if path.startswith("/drive/v3/") or path.startswith("/upload/drive/v3/"):
                return self.drive_request(path)
            self.answer(404, b"Not Found", content_type="text/plain")
        except Failure as failure:
            self.fail(failure)
        except (BrokenPipeError, ConnectionResetError):
            self.close_connection = True

    # MARK: Signing in

    def sign_in_page(self) -> None:
        """Google's page, as if the player signed in and chose: it sends
        them back to the client's address with a code, or why there is
        none."""
        drive = self.drive
        q = self.query()
        problems = []
        if q.get("client_id") != drive.client:
            problems.append("client_id")
        if q.get("redirect_uri") != drive.redirect:
            problems.append("redirect_uri")
        if q.get("response_type") != "code":
            problems.append("response_type")
        if q.get("code_challenge_method") != "S256" or len(q.get("code_challenge", "")) != 43:
            problems.append("code_challenge")
        if not q.get("state"):
            problems.append("state")
        if problems:
            return self.answer(400, ("Error 400: invalid_request " + " ".join(problems)).encode(), "text/plain",
                               extra=" ".join(problems))
        with drive.lock:
            choice, drive.sign_in = drive.sign_in, {}
            back = {"state": q["state"]}
            if choice.get("refuse"):
                back["error"] = "access_denied"
            else:
                code = "4/0A" + secrets.token_urlsafe(40)
                scope = choice.get("scope") or q.get("scope", "")
                drive.codes[code] = {"challenge": q["code_challenge"], "scope": scope,
                                     "lasting": choice.get("lasting", "1") != "0" or q.get("prompt") == "consent",
                                     "until": time.time() + 600}
                back["code"] = code
                back["scope"] = scope
        location = drive.redirect + "?" + urllib.parse.urlencode(back, quote_via=urllib.parse.quote)
        self.answer(302, b"", "text/html", headers={"Location": location}, extra="refused" if "error" in back else "")

    def token(self) -> None:
        drive = self.drive
        form = {name: values[0] for name, values in urllib.parse.parse_qs(self.body().decode("utf-8"),
                                                                            keep_blank_values=True).items()}
        grant = form.get("grant_type", "")

        def refuse(status: int, error: str, description: str) -> None:
            self.json(status, {"error": error, "error_description": description}, extra=f"{grant} {error}")

        if form.get("client_id") != drive.client:
            return refuse(401, "invalid_client", "The OAuth client was not found.")
        if "client_secret" in form:
            return refuse(400, "invalid_request", "client_secret is not applicable for the client type.")
        with drive.lock:
            if grant == "authorization_code":
                code = drive.codes.pop(form.get("code", ""), None)
                if form.get("redirect_uri") != drive.redirect:
                    return refuse(400, "redirect_uri_mismatch", "Bad Request")
                if code is None or code["until"] < time.time():
                    return refuse(400, "invalid_grant", "Malformed auth code.")
                if challenge_of(form.get("code_verifier", "")) != code["challenge"]:
                    return refuse(400, "invalid_grant", "Invalid code verifier.")
                refresh = token("1//0") if code["lasting"] else None
                if refresh:
                    drive.refresh[refresh] = {"scope": code["scope"]}
                answer = {"access_token": self.new_access(refresh, code["scope"]), "expires_in": 3599,
                          "scope": code["scope"], "token_type": "Bearer"}
                if refresh:
                    # As for a project in testing: seven days.
                    answer["refresh_token"] = refresh
                    answer["refresh_token_expires_in"] = 604799
                return self.json(200, answer, extra=grant + (" lasting" if refresh else " without a refresh token"))
            if grant == "refresh_token":
                refresh = form.get("refresh_token", "")
                kept = drive.refresh.get(refresh)
                if kept is None:
                    return refuse(400, "invalid_grant", "Token has been expired or revoked.")
                answer = {"access_token": self.new_access(refresh, kept["scope"]), "expires_in": 3599,
                          "scope": kept["scope"], "token_type": "Bearer"}
                return self.json(200, answer, extra=grant)
        refuse(400, "unsupported_grant_type", "Invalid grant_type: " + grant)

    def new_access(self, refresh: str | None, scope: str) -> str:
        access = token("ya29.")
        self.drive.access[access] = {"refresh": refresh, "scope": scope, "until": time.time() + 3599}
        return access

    def authorized(self) -> None:
        """Throws what Google says of a request without a token it takes."""
        drive = self.drive
        header = self.headers.get("Authorization", "")
        kept = drive.access.get(header[len("Bearer "):]) if header.startswith("Bearer ") else None
        if kept is None or kept["until"] < time.time():
            raise Failure(401, "authError", "Request had invalid authentication credentials.",
                          extra={"status": "UNAUTHENTICATED"})
        if DRIVE_SCOPE not in kept["scope"].split():
            raise Failure(403, "insufficientPermissions", "Request had insufficient authentication scopes.",
                          extra={"status": "PERMISSION_DENIED"})

    # MARK: The Drive API

    def drive_request(self, path: str) -> None:
        drive = self.drive
        with drive.lock:
            for redirect in drive.redirects:
                if path.startswith(redirect):
                    drive.redirects.remove(redirect)
                    self.body()
                    return self.answer(302, b"", "text/html", headers={"Location": "/elsewhere" + path})
            for rule in drive.failures:
                if path.startswith(rule["path"]) and rule["method"] in ("", self.command) and rule["count"] > 0:
                    rule["count"] -= 1
                    self.body()
                    raise Failure(rule["status"], rule["reason"], rule["message"], domain=rule["domain"])
        self.authorized()
        if drive.drive_off:
            self.body()
            raise drive_off()
        parts = [urllib.parse.unquote(part) for part in path.split("/")[1:]]
        if parts[0] == "upload":
            return self.upload(parts[3:])
        rest = parts[2:]
        if rest == ["about"] and self.command == "GET":
            with drive.lock:
                usage = drive.usage()
            return self.json(200, {"kind": "drive#about", "user": {"emailAddress": drive.account},
                                   "storageQuota": {"limit": str(LIMIT), "usage": str(usage)}})
        if rest == ["files"] and self.command == "GET":
            return self.list_files()
        if rest == ["files"] and self.command == "POST":
            return self.make()
        if len(rest) == 2 and rest[0] == "files" and self.command == "GET":
            return self.get_file(rest[1])
        if len(rest) == 2 and rest[0] == "files" and self.command == "DELETE":
            return self.delete_file(rest[1])
        raise Failure(404, "notFound", "Not Found")

    def list_files(self) -> None:
        drive = self.drive
        q = self.query()
        with drive.lock:
            if "pageToken" in q:
                kept = drive.pages.pop(q["pageToken"], None)
                if kept is None or kept[0] != q.get("q", ""):
                    raise Failure(400, "invalid", "Invalid Value")
                offset = kept[1]
            else:
                offset = 0
            test = matcher(drive, q.get("q", ""))
            found = sorted((item for item in drive.items.values() if test(item)), key=lambda item: item.id)
            size = min(int(q.get("pageSize", "100")), drive.page_size)
            page = found[offset:offset + size]
            body = {"kind": "drive#fileList", "incompleteSearch": False, "files": [item.resource() for item in page]}
            if offset + size < len(found):
                next_token = secrets.token_urlsafe(24)
                drive.pages[next_token] = (q.get("q", ""), offset + size)
                body["nextPageToken"] = next_token
        self.json(200, body, extra=f"{len(page)} of {len(found)}")

    def get_file(self, file_id: str) -> None:
        drive = self.drive
        q = self.query()
        with drive.lock:
            item = drive.resolve(file_id)
            if item is None:
                raise not_found(file_id)
            if q.get("alt") != "media":
                body = item.resource()
                body["capabilities"] = {"canAddChildren": drive.writable(item),
                                        "canDelete": item.parent is not None and drive.writable(drive.items[item.parent])}
                return self.json(200, body)
            if not item.is_binary or item.path is None:
                raise Failure(403, "fileNotDownloadable",
                              "Only files with binary content can be downloaded. Use Export with Docs Editors files.")
            path, size = item.path, item.size or 0
        start, end, status = 0, size - 1, 200
        wanted = self.headers.get("Range")
        if wanted:
            found = READ_RANGE.match(wanted.strip())
            if found is None:
                raise Failure(400, "badRange", "Bad Range")
            start = int(found.group(1))
            end = min(int(found.group(2)) if found.group(2) else size - 1, size - 1)
            if start >= size:
                return self.answer(416, b"", "text/plain", headers={"Content-Range": f"bytes */{size}"})
            status = 206
        count = max(end - start + 1, 0)
        self.drain()
        self.note(status)
        self.send_response(status)
        self.send_header("Content-Type", "application/octet-stream")
        self.send_header("Content-Length", str(count))
        if status == 206:
            self.send_header("Content-Range", f"bytes {start}-{end}/{size}")
        self.end_headers()
        with open(path, "rb") as f:
            f.seek(start)
            left = count
            while left > 0:
                chunk = f.read(min(BLOCK, left))
                if not chunk:
                    break
                self.wfile.write(chunk)
                left -= len(chunk)

    def metadata(self) -> dict:
        try:
            body = json.loads(self.body() or b"{}")
        except ValueError:
            raise Failure(400, "parseError", "Parse Error") from None
        if not isinstance(body, dict):
            raise Failure(400, "parseError", "Parse Error")
        return body

    def parent_of(self, metadata: dict) -> Item:
        """The folder METADATA puts a new file in, which the account must
        be able to add to."""
        drive = self.drive
        parents = metadata.get("parents") or ["root"]
        parent = drive.resolve(parents[0])
        if parent is None:
            raise not_found(parents[0])
        if not drive.writable(parent):
            raise no_permission(parent.id)
        return parent

    def make(self) -> None:
        drive = self.drive
        metadata = self.metadata()
        name = metadata.get("name") or "Untitled"
        with drive.lock:
            parent = self.parent_of(metadata)
            item = Item(name, metadata.get("mimeType") or "application/octet-stream", parent.id, size=0)
            if not item.is_folder:
                item.path = drive.data / "blobs" / item.id
                item.path.write_bytes(b"")
                item.owned = True
            drive.items[item.id] = item
        self.json(200, item.resource(), extra=name)

    def delete_file(self, file_id: str) -> None:
        drive = self.drive
        with drive.lock:
            item = drive.resolve(file_id)
            if item is None:
                raise not_found(file_id)
            if item.id == drive.root:
                raise Failure(403, "cannotDeleteRootFolder", "The root folder cannot be deleted.")
            parent = drive.items.get(item.parent or "")
            if parent is not None and not drive.writable(parent):
                raise no_permission(item.id)
            drive.remove(item)
        self.answer(204, b"", extra=item.name)

    # MARK: The resumable upload

    def upload(self, rest: list[str]) -> None:
        q = self.query()
        if rest != ["files"]:
            raise Failure(404, "notFound", "Not Found")
        if self.command == "POST":
            if q.get("uploadType") != "resumable":
                raise Failure(400, "badRequest", "Only resumable uploads here.")
            return self.start_upload(q)
        upload = self.drive.uploads.get(q.get("upload_id", ""))
        if upload is None:
            self.body()
            raise Failure(404, "notFound", "No such upload.")
        if self.command == "DELETE":
            with self.drive.lock:
                self.drive.uploads.pop(upload.id, None)
            upload.blob.unlink(missing_ok=True)
            return self.answer(499, b"", "text/plain", reason="Client Closed Request")
        if self.command == "PUT":
            return self.put_piece(upload)
        raise Failure(404, "notFound", "Not Found")

    def start_upload(self, q: dict[str, str]) -> None:
        drive = self.drive
        metadata = self.metadata()
        declared = self.headers.get("X-Upload-Content-Length")
        with drive.lock:
            parent = self.parent_of(metadata)
            if drive.full:
                raise Failure(403, "storageQuotaExceeded", "The user's Drive storage quota has been exceeded.",
                              domain="usageLimits")
            upload = Upload(metadata.get("name") or "Untitled", parent.id,
                            self.headers.get("X-Upload-Content-Type") or "application/octet-stream",
                            int(declared) if declared else None, drive.data / "blobs" / ("upload-" + secrets.token_hex(8)))
            drive.uploads[upload.id] = upload
        port = self.server.server_address[1]
        location = (f"http://127.0.0.1:{port}/upload/drive/v3/files?"
                    + urllib.parse.urlencode({"uploadType": "resumable", "fields": q.get("fields", ""),
                                              "upload_id": upload.id}))
        self.answer(200, b"", headers={"Location": location}, extra=upload.name)

    def held(self, upload: Upload, extra: str = "") -> None:
        headers = {"Range": f"bytes=0-{upload.held - 1}"} if upload.held else {}
        self.answer(308, b"", headers=headers, reason="Resume Incomplete", extra=extra or f"holds {upload.held}")

    def finished(self, upload: Upload) -> None:
        drive = self.drive
        with drive.lock:
            if upload.file is None:
                item = Item(upload.name, upload.mime, upload.parent, path=upload.blob, size=upload.held, owned=True)
                drive.items[item.id] = item
                upload.file = item
        self.json(200, upload.file.resource(), extra=f"made {upload.name}")

    def put_piece(self, upload: Upload) -> None:
        found = CONTENT_RANGE.match((self.headers.get("Content-Range") or "").strip())
        length = int(self.headers.get("Content-Length") or 0)
        if found is None:
            raise Failure(400, "badContentRange", "Failed to parse Content-Range header.")
        first, last, total = found.group(1), found.group(2), found.group(3)
        total_size = None if total == "*" else int(total)
        with upload.lock:
            if first is None:
                # How much the server holds, or the end of a file of that size.
                self.drain()
                if upload.file is not None or (total_size is not None and upload.held == total_size):
                    return self.finished(upload)
                return self.held(upload)
            start, end = int(first), int(last)
            if end < start or end - start + 1 != length:
                raise Failure(400, "badContentRange", "The Content-Range does not match the bytes sent.")
            if total_size is not None and end + 1 > total_size:
                raise Failure(400, "badContentRange", "The Content-Range goes past the file's size.")
            final = total_size is not None and end + 1 == total_size
            if not final and length % GRANULE:
                raise Failure(400, "badRequest", "Every piece but the last is a multiple of 256 KiB.")
            if total_size is not None and upload.declared is not None and total_size != upload.declared:
                raise Failure(400, "badRequest", "Not the size given when the upload started.")
            if start > upload.held:
                raise Failure(400, "badRequest", f"The upload holds {upload.held} bytes, not {start}.")
            with self.drive.lock:
                cut, self.drive.cut = self.drive.cut, None
            # The bytes the server holds already are dropped.
            skip = upload.held - start
            keep = (length // 2) // GRANULE * GRANULE if cut else length
            self.consumed = True
            with open(upload.blob, "r+b") as f:
                f.seek(upload.held)
                left, offset = length, 0
                while left > 0:
                    chunk = self.rfile.read(min(BLOCK, left))
                    if not chunk:
                        self.close_connection = True
                        return
                    begin = max(skip - offset, 0)
                    finish = min(len(chunk), keep - offset)
                    if finish > begin:
                        f.write(chunk[begin:finish])
                    offset += len(chunk)
                    left -= len(chunk)
            upload.held = max(upload.held, start + keep)
            if cut == "close":
                self.note(0, f"cut, holds {upload.held}")
                self.close_connection = True
                self.connection.shutdown(2)
                return
            if cut:
                raise Failure(503, "backendError", "Service Unavailable")
            if final:
                return self.finished(upload)
            self.held(upload)

    # MARK: The tests' requests

    def test_hook(self, name: str) -> None:
        drive = self.drive
        q = self.query()
        self.body()
        with drive.lock:
            if name == "expire":
                drive.access.clear()
            elif name == "revoke":
                refresh = q.get("refresh_token", "")
                drive.refresh.pop(refresh, None)
                for access in [access for access, kept in drive.access.items() if kept["refresh"] == refresh]:
                    drive.access.pop(access)
            elif name == "next-sign-in":
                drive.sign_in = q
            elif name == "fail":
                status = int(q.get("status", "503"))
                reason = q.get("reason") or {429: "rateLimitExceeded", 503: "backendError"}.get(status, "backendError")
                domain = "usageLimits" if "RateLimit" in reason else "global"
                drive.failures.append({"path": q.get("path", "/"), "method": q.get("method", ""), "status": status,
                                       "reason": reason, "domain": domain, "message": reason,
                                       "count": int(q.get("count", "1"))})
            elif name == "cut-next-upload":
                drive.cut = q.get("mode", "503")
            elif name == "redirect-next":
                drive.redirects.append(q.get("path", "/"))
            elif name == "drive-off":
                drive.drive_off = q.get("on", "1") == "1"
            elif name == "full":
                drive.full = q.get("on", "1") == "1"
            elif name == "reset":
                drive.reset()
            else:
                return self.answer(404, b"no such hook", "text/plain")
        self.answer(204, b"", extra=name)


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--port", type=int, required=True)
    parser.add_argument("--root", required=True)
    parser.add_argument("--data", required=True)
    parser.add_argument("--client-id", required=True)
    parser.add_argument("--account", required=True)
    parser.add_argument("--refresh-token-file", required=True)
    parser.add_argument("--read-only", required=True)
    parser.add_argument("--games", required=True)
    parser.add_argument("--small", required=True)
    parser.add_argument("--page-size", type=int, default=4)
    args = parser.parse_args(argv)
    if not args.client_id.endswith(".apps.googleusercontent.com"):
        parser.error("--client-id: an iOS client's ID, ending with .apps.googleusercontent.com")

    Handler.drive = Drive(args)
    server = ThreadingHTTPServer(("127.0.0.1", args.port), Handler)
    server.daemon_threads = True
    sys.stderr.write(f"{now_text()} Google's stand-in on port {args.port}\n")
    sys.stderr.flush()
    server.serve_forever()
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
