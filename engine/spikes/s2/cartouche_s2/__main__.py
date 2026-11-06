"""Spike S2: run nxnative's rewriter, patch_nso.py, on each module given and
print one line per file it writes, "S2 <module>/<file> <SHA-256>", then
"S2 done". The lines from a Mac and from iOS must be the same.

usage: python -m cartouche_s2 [--tools DIR] [--modules DIR]

--tools is nxnative's dm/tools, by default dm/tools beside this package, as
the iOS app lays them out; --modules holds the .nso files, by default
modules/ in this package. Lines starting "S2-info" describe the run and are
not compared.
"""

import argparse
import hashlib
import platform
import runpy
import sys
import tempfile
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent


def sha256(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def rewrite(tools, module, out):
    """patch_nso.py MODULE OUT NAME, in this process, since iOS lets an app
    start no other process. Its own modules are dropped afterwards, as a new
    process would start without them."""
    script = tools / "patch_nso.py"
    argv, path = sys.argv, list(sys.path)
    sys.argv = [str(script), str(module), str(out), module.stem]
    sys.path.insert(0, str(tools))
    try:
        runpy.run_path(str(script), run_name="__main__")
    except SystemExit as stop:
        if stop.code not in (None, 0):
            raise RuntimeError(f"patch_nso.py stopped on {module.name}: {stop.code}") from None
    finally:
        sys.argv, sys.path[:] = argv, path
        for name, loaded in list(sys.modules.items()):
            if str(getattr(loaded, "__file__", None) or "").startswith(str(tools)):
                del sys.modules[name]


def main(argv=None):
    parser = argparse.ArgumentParser(prog="cartouche_s2")
    parser.add_argument("--tools", type=Path, default=HERE.parent / "dm" / "tools")
    parser.add_argument("--modules", type=Path, default=HERE / "modules")
    args = parser.parse_args(argv)

    import capstone   # what patch_nso.py imports first: a failure to load it shows here
    print(f"S2-info Python {platform.python_version()} on {sys.platform} {platform.machine()}, "
          f"Capstone {capstone.__version__}", flush=True)
    modules = sorted(args.modules.glob("*.nso"))
    if not modules:
        raise SystemExit(f"S2: no .nso in {args.modules}")
    for module in modules:
        out = Path(tempfile.mkdtemp(prefix=f"s2-{module.stem}-"))
        start = time.monotonic()
        rewrite(args.tools.resolve(), module, out)
        print(f"S2-info {module.name} rewritten in {time.monotonic() - start:.2f} s", flush=True)
        for written in sorted(out.iterdir()):
            print(f"S2 {module.stem}/{written.name} {sha256(written)}", flush=True)
    print("S2 done", flush=True)
    return 0


if __name__ == "__main__":
    sys.exit(main())
