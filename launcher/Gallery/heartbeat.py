"""Says every minute that a build which prints nothing goes on.

xcodebuild says nothing as it builds with -quiet, for minutes on GitHub's
Macs: the gallery and its UI tests (uitests.sh), the gallery before the
screenshots (capture.sh). Such a silence was taken for a stuck run, and the
run cancelled by hand: on 13 November the Full test pass of 0.12.1, 9
minutes into its screenshots (run 43468883424), on 14 November #175's UI
tests, 9 minutes into the iPad's (run 43574954177), and its harness
(harness.sh). A step that says nothing for ten minutes is not stuck: with a
line a minute, its log shows it.

capture.sh builds within beating(). uitests.sh runs its build through this
file, which runs COMMAND as it is, prints "   still WHAT: N s" every minute
until it ends, then exits as COMMAND did:

    python3 launcher/Gallery/heartbeat.py WHAT COMMAND [ARGUMENT...]

HEARTBEAT_SECONDS sets another time than a minute, for the tests
(test_heartbeat.py). The harness, whose xcodebuild goes through a filter,
says the same from launcher/Harness/harness.sh.
"""

import contextlib
import os
import subprocess
import sys
import threading
import time


def every():
    """The seconds between two lines: a minute, or HEARTBEAT_SECONDS."""
    return float(os.environ.get("HEARTBEAT_SECONDS", "60"))


@contextlib.contextmanager
def beating(what):
    """Prints "   still WHAT: N s" every minute until the block ends."""
    since = time.monotonic()
    period = every()
    done = threading.Event()

    def beat():
        while not done.wait(period):
            # The whole line at once, should the block print too.
            sys.stdout.write(f"   still {what}: {time.monotonic() - since:.0f} s\n")
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
