#!/usr/bin/env python3
"""An FTP server for the storage tests: pyftpdlib, on 127.0.0.1.

usage: ftp_server.py --port P --root DIR --user U --password-file F
                     --reader R --reader-password-file G --read-only FOLDER
                     --passive FIRST-LAST [--no-mlsd]

The player's account U reads and writes DIR, but for its FOLDER, which it can
only read, as a folder of a NAS whose permissions say so; the account R can
only read. With --no-mlsd the server has neither MLSD nor MLST, and lists
folders with LIST alone, as `ls -l` writes them, as vsftpd and other servers
do. The passwords are read from files, never from the command line. Every
command is logged to stderr, but for the passwords, which pyftpdlib hides,
for the tests to see which the client sent.
"""

from __future__ import annotations

import argparse
import logging
import os
import sys

from pyftpdlib.authorizers import DummyAuthorizer
from pyftpdlib.handlers import FTPHandler
from pyftpdlib.servers import FTPServer


class ListOnlyHandler(FTPHandler):
    """A server without MLSD and MLST, whose FEAT says neither."""

    proto_cmds = {name: spec for name, spec in FTPHandler.proto_cmds.items() if name not in ("MLSD", "MLST")}


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--port", type=int, required=True)
    parser.add_argument("--root", required=True)
    parser.add_argument("--user", required=True)
    parser.add_argument("--password-file", required=True)
    parser.add_argument("--reader", required=True)
    parser.add_argument("--reader-password-file", required=True)
    parser.add_argument("--read-only", required=True, help="a folder of ROOT the player's account can only read")
    parser.add_argument("--passive", required=True, help="the data ports, FIRST-LAST")
    parser.add_argument("--no-mlsd", action="store_true")
    args = parser.parse_args(argv)

    def secret(path: str) -> str:
        with open(path, encoding="utf-8") as f:
            return f.read().strip()

    root = os.path.realpath(args.root)
    authorizer = DummyAuthorizer()
    # e: change folder, l: list, r: read; a, d, f, m, w: append, delete,
    # rename, make folders, write; M, T: modes and times.
    authorizer.add_user(args.user, secret(args.password_file), root, perm="elradfmwMT")
    authorizer.override_perm(args.user, os.path.join(root, args.read_only), perm="elr", recursive=True)
    authorizer.add_user(args.reader, secret(args.reader_password_file), root, perm="elr")

    handler = ListOnlyHandler if args.no_mlsd else FTPHandler
    handler.authorizer = authorizer
    first, last = (int(port) for port in args.passive.split("-"))
    handler.passive_ports = range(first, last + 1)
    handler.banner = "Cartouche storage tests"
    logging.basicConfig(level=logging.DEBUG, format="%(asctime)s %(message)s")
    server = FTPServer(("127.0.0.1", args.port), handler)
    server.max_cons = 64
    server.serve_forever()
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
