"""cartouche-guard: run the publish guard on files before they are published.

    cartouche-guard --kind app build/app/Cartouche.ipa
    cartouche-guard --kind catalog catalog/devices.json catalog/games/*.json
"""

from __future__ import annotations

import argparse
import sys
from pathlib import Path

from . import APP_BUNDLE_ID, guard


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(prog="cartouche-guard", description=__doc__.splitlines()[0])
    parser.add_argument("--kind", required=True, choices=sorted(guard.MAX_SIZE))
    parser.add_argument("--app-bundle-id", default=APP_BUNDLE_ID)
    parser.add_argument("files", nargs="+")
    return parser


def main(argv: list[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    failed = False
    for name in args.files:
        try:
            guard.check_file(Path(name), args.kind, app_bundle_id_expected=args.app_bundle_id)
        except guard.Rejected as exc:
            print(f"REFUSED {exc}", file=sys.stderr)
            failed = True
        else:
            print(f"ok      {name}")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
