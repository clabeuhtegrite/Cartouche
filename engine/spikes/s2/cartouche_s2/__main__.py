"""Spike S2: run nxnative's rewriter, patch_nso.py, on the modules of a folder
as the Cartouche app does on the iPhone (cartouche_s2.phone.run_job), and
print one line per file it writes, "S2 <file> <SHA-256>", then "S2 done".
The lines from a Mac and from iOS must be the same.

usage: python -m cartouche_s2 [--tools DIR] [--modules DIR] [--reference FILE] [--job FILE]

--tools is nxnative's dm/tools, by default dm/tools beside this package, as
the iOS app lays them out; --modules holds the modules (main, subsdk0...,
or the same with .nso), by default modules/ in this package; --reference is
a list of the Mac's files in the format of shasum -a 256; --job is a job
file, whose values replace these. Lines starting "S2-info" describe the run
and are not compared.
"""

import argparse
import json
import sys
from pathlib import Path

from . import phone

HERE = Path(__file__).resolve().parent


def main(argv=None):
    parser = argparse.ArgumentParser(prog="cartouche_s2")
    parser.add_argument("--tools", type=Path, default=HERE.parent / "dm" / "tools")
    parser.add_argument("--modules", type=Path, default=HERE / "modules")
    parser.add_argument("--reference", type=Path)
    parser.add_argument("--job", type=Path)
    args = parser.parse_args(argv)

    job = {"tools": str(args.tools), "modules": str(args.modules),
           "reference": str(args.reference) if args.reference else None}
    if args.job:
        job.update(json.loads(args.job.read_text(encoding="utf-8")))
    status = phone.run_job(job)

    print(f"S2-info Python {status['python']} on {status['platform']}, Capstone {status.get('capstone')}", flush=True)
    for module in status.get("modules", []):
        restarts = f", started again {module['restarts']} time(s)" if module.get("restarts") else ""
        print(f"S2-info {module['name']}: {module['state']}, {module.get('seconds', '?')} s{restarts}", flush=True)
    if status["state"] != "done":
        log = Path(status["work"]) / "rewrite.log"
        print(f"S2-info the job failed: {status.get('error')}", flush=True)
        if log.is_file():
            print("".join(log.read_text(encoding="utf-8", errors="replace").splitlines(True)[-40:]), flush=True)
        return 1
    for row in status["files"]:
        print(f"S2 {row['name']} {row['sha256']}", flush=True)
    if status["summary"].get("same") is not None:
        print(f"S2-info compared with {args.reference or job['reference']}: {status['summary']}", flush=True)
        for row in status["files"]:
            if row["mac"] != "same":
                print(f"S2-info {row['name']}: {row['mac']}", flush=True)
        for name in status["only_on_mac"]:
            print(f"S2-info {name}: only on the Mac", flush=True)
    print("S2 done", flush=True)
    return 0


if __name__ == "__main__":
    sys.exit(main())
