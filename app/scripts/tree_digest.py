#!/usr/bin/env python3
"""Print a digest of a folder: every path in it, what it is (folder, file,
executable file or link), each file's bytes and each link's target, but no
times, owners or other mode bits. Two folders with the same digest hold the
same sources, wherever and whenever they were copied, on macOS as on Linux.

app/scripts/build.sh names the built-in SideStore after the digest of its
prepared sources, so that CI builds it again only when they change
(.github/workflows/app.yml).

usage: tree_digest.py DIR
"""

from __future__ import annotations

import hashlib
import os
import stat
import sys
from pathlib import Path


def digest(root: Path) -> str:
    total = hashlib.sha256()

    def add(kind: str, relative: str, data: bytes = b"") -> None:
        name = relative.encode("utf-8", "surrogateescape")
        total.update(b"%s %d %s %d\n" % (kind.encode(), len(name), name, len(data)))
        total.update(data)

    for folder, folders, files in os.walk(root):
        # Walked in name order; links to folders are listed, never followed.
        folders.sort()
        for name in sorted(folders + files):
            path = Path(folder, name)
            relative = path.relative_to(root).as_posix()
            mode = os.lstat(path).st_mode
            if stat.S_ISLNK(mode):
                add("link", relative, os.fsencode(os.readlink(path)))
            elif stat.S_ISDIR(mode):
                add("folder", relative)
            elif stat.S_ISREG(mode):
                content = hashlib.sha256()
                with open(path, "rb") as file:
                    for block in iter(lambda: file.read(1 << 20), b""):
                        content.update(block)
                add("program" if mode & 0o111 else "file", relative, content.digest())
            else:
                add("other", relative)
    return total.hexdigest()


def main(argv: list[str]) -> int:
    if len(argv) != 2 or not Path(argv[1]).is_dir():
        print(__doc__.strip().splitlines()[-1], file=sys.stderr)
        return 2
    print(digest(Path(argv[1])))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
