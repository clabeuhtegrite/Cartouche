#!/usr/bin/python3
"""What the screenshots need that an Xcode's simulators cannot run
(launcher/Gallery/capture.sh): an iPad, and each device the gallery's
scenarios name, such as the iPhone Duo, which only a runtime made for it
may run (on GitHub's Macs, iOS 27.1 and iOS-27-2-iPhone19-4, not Xcode
27.2's own iOS 27.2). install.sh gives the label ios-sim-<version> to an
Xcode that runs them all.

usage: xcrun simctl list -j runtimes | simulators.py SCENARIOS

prints what is missing, comma-separated, and nothing when the Xcode runs
them all.
"""

from __future__ import annotations

import json
import sys


def missing(listing: dict, scenarios: dict) -> list:
    """What SCENARIOS (scenarios.json) need that no available iOS runtime of
    LISTING (simctl list -j runtimes) runs."""
    wanted = {scenario["device"] for scenario in scenarios.get("scenarios", []) if scenario.get("device")}
    runs = set()
    for runtime in listing.get("runtimes", []):
        if runtime.get("platform") == "iOS" and runtime.get("isAvailable"):
            runs |= {kind.get("name", "") for kind in runtime.get("supportedDeviceTypes", [])}
    ipad = [] if any(name.startswith("iPad") for name in runs) else ["an iPad"]
    return ipad + sorted(wanted - runs)


def main(argv: list) -> int:
    with open(argv[1]) as file:
        scenarios = json.load(file)
    try:
        listing = json.load(sys.stdin)
    except ValueError:
        listing = None
    print("any simulator (simctl did not answer)" if not isinstance(listing, dict) else ", ".join(missing(listing, scenarios)))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
