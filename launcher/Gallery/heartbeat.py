"""Says every minute that a build which prints nothing goes on, and what the
Mac has left of its memory and disk.

xcodebuild says nothing as it builds with -quiet, for minutes on GitHub's
Macs: the gallery and its UI tests (uitests.sh), the gallery before the
screenshots (capture.sh). Such a silence was taken for a stuck run, and the
run cancelled by hand: on 13 November the Full test pass of 0.12.1, 9
minutes into its screenshots (run 43468883424), on 14 November #175's UI
tests, 9 minutes into the iPad's (run 43574954177), and its harness
(harness.sh). A step that says nothing for ten minutes is not stuck: with a
line a minute, its log shows it.

Five runs were cancelled again that morning in their iPad step, on GitHub's
Macs, lines or not and by no one known: the line says what the Mac has left
too, as a Mac short of memory or disk would show it there first.

capture.sh builds within beating(). uitests.sh runs its build through this
file, which runs COMMAND as it is, prints "   still WHAT: N s (memory free
P%, disk free G GB)" every minute until it ends, then exits as COMMAND did:

    python3 launcher/Gallery/heartbeat.py WHAT COMMAND [ARGUMENT...]

The memory is macOS's memory_pressure's, left out where it says nothing.
HEARTBEAT_SECONDS sets another time than a minute, for the tests
(test_heartbeat.py). The harness, whose xcodebuild goes through a filter,
says the same from launcher/Harness/harness.sh.
"""

import contextlib
import os
import re
import shutil
import subprocess
import sys
import threading
import time


def every():
    """The seconds between two lines: a minute, or HEARTBEAT_SECONDS."""
    return float(os.environ.get("HEARTBEAT_SECONDS", "60"))


def left():
    """What the Mac has left, " (memory free 23%, disk free 12.4 GB)", of
    what it says."""
    said = []
    try:
        printed = subprocess.run(["memory_pressure"], capture_output=True, text=True, timeout=30).stdout
        found = re.search(r"^System-wide memory free percentage: (\d+%)", printed, re.M)
        if found:
            said.append(f"memory free {found.group(1)}")
    except (OSError, subprocess.SubprocessError):
        pass
    try:
        said.append(f"disk free {shutil.disk_usage('.').free / 1e9:.1f} GB")
    except OSError:
        pass
    return f" ({', '.join(said)})" if said else ""


@contextlib.contextmanager
def beating(what):
    """Prints "   still WHAT: N s" and what the Mac has left every minute,
    until the block ends."""
    since = time.monotonic()
    period = every()
    done = threading.Event()

    def beat():
        while not done.wait(period):
            line = f"   still {what}: {time.monotonic() - since:.0f} s{left()}\n"
            # The whole line at once, should the block print too.
            sys.stdout.write(line)
            sys.stdout.flush()

    thread = threading.Thread(target=beat, daemon=True)
    thread.start()
    try:
        yield
    finally:
        done.set()
        thread.join()


def main(arguments):
    if len(arguments) < 3:
        sys.exit(f"usage: {arguments[0]} WHAT COMMAND [ARGUMENT...]")
    with beating(arguments[1]):
        status = subprocess.call(arguments[2:])
    # A command a signal ended, as the shell gives its status.
    sys.exit(status if status >= 0 else 128 - status)


if __name__ == "__main__":
    main(sys.argv)
