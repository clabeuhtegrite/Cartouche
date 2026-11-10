"""Checks how the telemetry server's address reaches the app.

- app/config.env gives CARTOUCHE_TELEMETRY_URL, empty or an https address;
- app/scripts/build.sh passes it to app/scripts/package.sh, which writes it
  into the Info.plist under the key the launcher reads
  (launcher/Sources/CartoucheTelemetry.swift);
- the launcher posts its reports to the routes the Worker serves
  (telemetry/worker.js).

Run from the repository root: python3 -m unittest discover -s app/tests -v
"""

import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
CONFIG = ROOT / "app" / "config.env"
BUILD = ROOT / "app" / "scripts" / "build.sh"
PACKAGE = ROOT / "app" / "scripts" / "package.sh"
LAUNCHER = ROOT / "launcher" / "Sources" / "CartoucheTelemetry.swift"
WORKER = ROOT / "telemetry" / "worker.js"


def setting(name: str) -> str:
    for line in CONFIG.read_text(encoding="utf-8").splitlines():
        key, _, value = line.partition("=")
        if key.strip() == name:
            return value.strip()
    raise AssertionError(f"{name} is not in app/config.env")


class TelemetryAddressTest(unittest.TestCase):
    def test_the_config_gives_an_https_address_or_none(self):
        url = setting("CARTOUCHE_TELEMETRY_URL")
        self.assertTrue(url == "" or re.fullmatch(r"https://[^\s\"<>]+", url), url)

    def test_the_build_carries_it_into_the_info_plist_the_launcher_reads(self):
        key = re.search(r'forInfoDictionaryKey: "(CartoucheTelemetry\w*)"', LAUNCHER.read_text(encoding="utf-8"))
        self.assertIsNotNone(key, "the Info.plist key the launcher reads")
        self.assertIn(f"Add :{key.group(1)} string $TELEMETRY_URL", PACKAGE.read_text(encoding="utf-8"))
        self.assertIn('--telemetry-url "${CARTOUCHE_TELEMETRY_URL:-}"', BUILD.read_text(encoding="utf-8"))

    def test_the_launcher_posts_to_the_routes_the_worker_serves(self):
        launcher = LAUNCHER.read_text(encoding="utf-8")
        worker = WORKER.read_text(encoding="utf-8")
        routes = re.findall(r'appendingPathComponent\("(v1/\w+)"\)', launcher)
        self.assertEqual(sorted(routes), ["v1/forget", "v1/reports"])
        for route in routes:
            self.assertIn(f'"/{route}"', worker)


if __name__ == "__main__":
    unittest.main()
