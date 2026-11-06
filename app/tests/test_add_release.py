"""Checks app/scripts/add_release.py, which adds a release of Cartouche to
the source its built-in SideStore reads (app/sidestore-source.json).

Run from the repository root: python3 -m unittest discover -s app/tests -v
"""

import hashlib
import json
import plistlib
import sys
import tempfile
import unittest
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "app" / "scripts"))

import add_release  # noqa: E402

BUNDLE_ID = "io.github.clabeuhtegrite.cartouche"
URL = "https://github.com/clabeuhtegrite/Cartouche/releases/download/v{0}/Cartouche-{0}.ipa"
SOURCE = ROOT / "app" / "sidestore-source.json"


def listed(source):
    """The versions of Cartouche a source lists, newest first."""
    return [release["version"] for app in source["apps"] for release in app.get("versions", [])]


def above(versions):
    """A version higher than every one given. The repository's source gains
    a version at each release, so the tests that read it never assume which."""
    major, minor, patch = max((add_release.parse_version(v) for v in versions), default=(0, 1, 0))
    return f"{major}.{minor}.{patch + 1}"


class AddReleaseTest(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.made = 0

    def ipa(self, version="0.1.1", bundle_id=BUNDLE_ID, build=None, apps=1):
        self.made += 1
        path = Path(self.directory.name) / f"{self.made}" / f"Cartouche-{version}.ipa"
        path.parent.mkdir()
        info = {
            "CFBundleIdentifier": bundle_id,
            "CFBundleShortVersionString": version,
            "CFBundleVersion": build or version,
            "MinimumOSVersion": "15.0",
        }
        with zipfile.ZipFile(path, "w") as archive:
            for index in range(apps):
                archive.writestr(f"Payload/App{index}.app/Info.plist", plistlib.dumps(info))
            archive.writestr("Payload/App0.app/Frameworks/SideStoreApp.framework/Info.plist", plistlib.dumps({}))
        return path

    def add(self, source, ipa, version="0.1.1", **changes):
        arguments = dict(ipa=ipa, url=URL.format(version), notes="Fixes.\n",
                         date="2026-11-07T08:00:00Z", bundle_id=BUNDLE_ID, version=version)
        arguments.update(changes)
        return add_release.add_release(source, **arguments)

    def test_the_repository_source_takes_a_release(self):
        source = json.loads(SOURCE.read_text(encoding="utf-8"))
        before = listed(source)
        released = above(before)
        ipa = self.ipa(released)
        app, = self.add(source, ipa, released)["apps"]
        self.assertEqual(app["bundleIdentifier"], BUNDLE_ID)
        version, *older = app["versions"]
        self.assertEqual([v["version"] for v in older], before[:add_release.KEPT_VERSIONS - 1])
        self.assertEqual(version["version"], released)
        self.assertEqual(version["downloadURL"], URL.format(released))
        self.assertEqual(version["size"], ipa.stat().st_size)
        self.assertEqual(version["sha256"], hashlib.sha256(ipa.read_bytes()).hexdigest())
        self.assertEqual(version["minOSVersion"], "15.0")
        self.assertEqual(version["localizedDescription"], "Fixes.")
        # Every key SideStore requires of an app and of a version.
        for key in ("name", "bundleIdentifier", "developerName", "localizedDescription", "iconURL"):
            self.assertTrue(app[key], key)
        for key in ("version", "date", "downloadURL", "size"):
            self.assertIn(key, version)

    def test_the_newest_release_comes_first(self):
        source = self.add({"apps": []}, self.ipa("0.1.1"), "0.1.1")
        source = self.add(source, self.ipa("0.2.0"), "0.2.0")
        self.assertEqual([v["version"] for v in source["apps"][0]["versions"]], ["0.2.0", "0.1.1"])

    def test_old_releases_are_dropped_after_ten(self):
        source = {"apps": []}
        for patch in range(12):
            version = f"0.1.{patch}"
            source = self.add(source, self.ipa(version), version)
        versions = [v["version"] for v in source["apps"][0]["versions"]]
        self.assertEqual(len(versions), add_release.KEPT_VERSIONS)
        self.assertEqual(versions[0], "0.1.11")

    def test_a_release_must_be_higher_than_the_ones_listed(self):
        source = self.add({"apps": []}, self.ipa("0.2.0"), "0.2.0")
        for version in ("0.2.0", "0.1.9"):
            with self.subTest(version=version), self.assertRaises(add_release.ReleaseError):
                self.add(json.loads(json.dumps(source)), self.ipa(version), version)

    def test_the_ipa_must_be_cartouche_at_the_released_version(self):
        cases = {
            "another app": dict(ipa=self.ipa(bundle_id="com.kdt.livecontainer")),
            "another version": dict(ipa=self.ipa("0.1.2")),
            "another build version": dict(ipa=self.ipa(build="3.8.11")),
            "two apps": dict(ipa=self.ipa(apps=2)),
            "a plain http address": dict(ipa=self.ipa(), url="http://example.com/Cartouche.ipa"),
            "a version SideStore cannot compare": dict(ipa=self.ipa("0.1"), version="0.1"),
        }
        for what, changes in cases.items():
            with self.subTest(what), self.assertRaises(add_release.ReleaseError):
                self.add({"apps": []}, **changes)

    def test_the_source_lists_nothing_but_cartouche(self):
        source = {"apps": [{"bundleIdentifier": "org.example.other", "versions": []}]}
        with self.assertRaises(add_release.ReleaseError):
            self.add(source, self.ipa())

    def test_the_command_writes_the_source(self):
        directory = Path(self.directory.name)
        source = directory / "source.json"
        source.write_text(SOURCE.read_text(encoding="utf-8"), encoding="utf-8")
        released = above(listed(json.loads(source.read_text(encoding="utf-8"))))
        config = directory / "config.env"
        config.write_text(f"CARTOUCHE_BUNDLE_ID={BUNDLE_ID}\nCARTOUCHE_VERSION={released}\n", encoding="utf-8")
        notes = directory / "notes.md"
        notes.write_text("Fixes.\n", encoding="utf-8")
        status = add_release.main([
            "--ipa", str(self.ipa(released)), "--url", URL.format(released), "--notes", str(notes),
            "--source", str(source), "--config", str(config),
        ])
        self.assertEqual(status, 0)
        written = json.loads(source.read_text(encoding="utf-8"))
        self.assertEqual(written["apps"][0]["versions"][0]["version"], released)
        self.assertEqual(written["name"], "Cartouche")


if __name__ == "__main__":
    unittest.main()
