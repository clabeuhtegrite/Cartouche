"""nxnative's rewriter, patch_nso.py, run inside this process.

iOS lets an app start no other process, so the rewriter runs here with runpy,
and this module does by hand what a new process would give it:

- its modules are forgotten after each run, as a new process starts without
  them;
- the environment variables of a run are set for that run only;
- when it starts itself again through os.execve(), which iOS does not allow,
  it runs again here with the environment it asked for. patch_nso.py does
  that with DM_PATCH_FRONT when a module's patch area needs more room before
  the module's base than its first pass left;
- its SIGTERM handler is put back as it was afterwards;
- where a process cannot fork (iOS), it runs with one worker, since its
  workers are forked processes (DM_REWRITE_J=1).
"""

import gc
import os
import runpy
import signal
import sys
import threading
from pathlib import Path

# A rewrite that starts itself again more often than this is looping.
MAX_RESTARTS = 3


class Restart(Exception):
    """patch_nso.py asked to start again, with this environment."""

    def __init__(self, env):
        super().__init__("patch_nso.py starts itself again")
        self.env = dict(env)


def _restart(path, args, env):
    """Stands for os.execve() while patch_nso.py runs."""
    raise Restart(env)


def can_fork():
    return sys.platform not in ("ios", "tvos", "watchos") and hasattr(os, "fork")


def _forget(tools):
    """Drops the modules loaded from nxnative's dm folder (the rewriter's own,
    and dm/games/game.py, which some of them import), or from the rewriter's
    folder when it is not in one."""
    prefix = str(tools.parent if tools.parent.name == "dm" else tools)
    for name, loaded in list(sys.modules.items()):
        if str(getattr(loaded, "__file__", None) or "").startswith(prefix):
            del sys.modules[name]


def _set_environment(wanted):
    """Makes os.environ hold exactly `wanted`."""
    for key in [key for key in os.environ if key not in wanted]:
        del os.environ[key]
    for key, value in wanted.items():
        if os.environ.get(key) != value:
            os.environ[key] = value


def rewrite(tools, module, out, name=None, env=None):
    """patch_nso.py MODULE OUT NAME in this process, with the environment
    variables `env` set for this run only. NAME is the module's name, by
    default its file name without extension. Returns how many times the
    rewriter started itself again."""
    tools = Path(tools).resolve()
    module = Path(module)
    script = tools / "patch_nso.py"
    run_env = dict(os.environ)
    run_env.update(env or {})
    if not can_fork():
        run_env.setdefault("DM_REWRITE_J", "1")

    saved_env = dict(os.environ)
    saved_argv, saved_path = sys.argv, list(sys.path)
    saved_execve = os.execve
    main_thread = threading.current_thread() is threading.main_thread()
    saved_sigterm = signal.getsignal(signal.SIGTERM) if main_thread else None
    restarts = 0
    try:
        _set_environment(run_env)
        while True:
            sys.argv = [str(script), str(module), str(out), name or module.stem]
            sys.path[:] = [str(tools)] + saved_path
            os.execve = _restart
            try:
                runpy.run_path(str(script), run_name="__main__")
                return restarts
            except Restart as again:
                restarts += 1
                if restarts > MAX_RESTARTS:
                    raise RuntimeError(f"patch_nso.py started itself again {restarts} times on {module.name}") from None
                _set_environment(again.env)
            except SystemExit as stop:
                if stop.code not in (None, 0):
                    raise RuntimeError(f"patch_nso.py stopped on {module.name}: {stop.code}") from None
                return restarts
            finally:
                os.execve = saved_execve
                _forget(tools)
                gc.collect()
    finally:
        os.execve = saved_execve
        sys.argv, sys.path[:] = saved_argv, saved_path
        _set_environment(saved_env)
        if main_thread and saved_sigterm is not None:
            signal.signal(signal.SIGTERM, saved_sigterm)
