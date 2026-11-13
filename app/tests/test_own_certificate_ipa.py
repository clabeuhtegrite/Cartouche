"""Checks app/scripts/own_certificate_ipa.py, which makes the Cartouche IPA a
player signs on the iPhone with their own certificate, from the release's
IPA (docs/imported-signing.md).

Run from the repository root: python3 -m unittest discover -s app/tests -v
"""

import io
import plistlib
import re
import stat
import sys
import tempfile
import unittest
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "app" / "scripts"))

import add_release  # noqa: E402
import own_certificate_ipa  # noqa: E402

BUNDLE_ID = "io.github.clabeuhtegrite.cartouche"
APP = "Payload/LiveContainer.app"
DATE = (2026, 11, 13, 12, 0, 0)
EXECUTABLE = 0o100755 << 16
LINK = (stat.S_IFLNK | 0o755) << 16


def release_ipa(path: Path, *, binary=True, info=None, extra=()):
    """An IPA laid out as package.sh lays out Cartouche's: the app, its
    frameworks with the built-in SideStore, LiveProcess and the widget."""
    plist = {
        "CFBundleIdentifier": BUNDLE_ID,
        "CartoucheBundleIdentifier": BUNDLE_ID,
        "CFBundleShortVersionString": "0.13.0",
        "CFBundleVersion": "0.13.0",
        "CFBundleDisplayName": "LiveContainer",
        "ALTAppGroups": ["group.com.SideStore.SideStore"],
    }
    plist.update(info or {})
    entries = [
        (f"{APP}/", None, 0o40755 << 16),
        (f"{APP}/Info.plist", plistlib.dumps(plist, fmt=plistlib.FMT_BINARY if binary else plistlib.FMT_XML), 0),
        (f"{APP}/LiveContainer", b"\xcf\xfa\xed\xfe main executable" * 64, EXECUTABLE),
        (f"{APP}/_CodeSignature/CodeResources", b"<plist>the release's seal</plist>", 0),
        (f"{APP}/CartoucheCatalog/devices.json", b'{"devices": []}', 0),
        (f"{APP}/Frameworks/SideStoreApp.framework/SideStore", b"sidestore dylib", EXECUTABLE),
        (f"{APP}/Frameworks/SideStoreApp.framework/PlugIns/AltIntents.appex/AltIntents", b"intents", EXECUTABLE),
        # The built-in SideStore's own PlugIns folder, which package.sh
        # leaves empty once it has moved SideStore's widget into the app's.
        (f"{APP}/Frameworks/SideStoreApp.framework/PlugIns/", None, 0o40755 << 16),
        (f"{APP}/Frameworks/Current", b"SideStoreApp.framework", LINK),
        (f"{APP}/PlugIns/", None, 0o40755 << 16),
        (f"{APP}/PlugIns/LiveProcess.appex/Info.plist", plistlib.dumps({"CFBundleIdentifier": f"{BUNDLE_ID}.LiveProcess"}), 0),
        (f"{APP}/PlugIns/LiveProcess.appex/LiveProcess", b"liveprocess", EXECUTABLE),
        (f"{APP}/PlugIns/LiveWidgetExtension.appex/LiveWidgetExtension", b"widget", EXECUTABLE),
        (f"{APP}/Watch/CartoucheWatch.app/Info.plist", plistlib.dumps({}), 0),
        *extra,
    ]
    with zipfile.ZipFile(path, "w") as archive:
        for name, data, mode in entries:
            info = zipfile.ZipInfo(name, date_time=DATE)
            info.compress_type = zipfile.ZIP_DEFLATED
            info.create_system = 3
            info.external_attr = mode
            archive.writestr(info, data or b"")
    return path


class OwnCertificateIPATest(unittest.TestCase):
    def setUp(self):
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        self.folder = Path(directory.name)

    def make(self, **layout):
        ipa = release_ipa(self.folder / "Cartouche.ipa", **layout)
        out = self.folder / "out" / "Cartouche-Own-Certificate.ipa"
        left_out = own_certificate_ipa.make(ipa, out, BUNDLE_ID)
        return ipa, out, left_out

    def test_the_app_starts_in_the_mode_of_the_players_own_certificate(self):
        for binary in (True, False):
            with self.subTest(binary=binary):
                ipa, out, _ = self.make(binary=binary)
                with zipfile.ZipFile(ipa) as before, zipfile.ZipFile(out) as after:
                    old = before.read(f"{APP}/Info.plist")
                    new = after.read(f"{APP}/Info.plist")
                self.assertEqual(new.startswith(b"bplist"), binary, "the Info.plist keeps its format")
                info = plistlib.loads(new)
                self.assertIs(info["CartoucheImportedSigning"], True)
                self.assertNotIn("CartoucheSigningHandoffKey", info)
                # Nothing else of the Info.plist changes.
                del info["CartoucheImportedSigning"]
                self.assertEqual(info, plistlib.loads(old))

    def test_no_app_extension_is_left(self):
        _, out, left_out = self.make()
        with zipfile.ZipFile(out) as archive:
            names = archive.namelist()
        self.assertFalse([name for name in names if ".appex" in name], "an app extension is left")
        self.assertFalse([name for name in names if name.startswith(f"{APP}/Watch")], "the Watch app is left")
        self.assertEqual(sorted(left_out), ["AltIntents.appex", "LiveProcess.appex", "LiveWidgetExtension.appex", "Watch"])
        # The PlugIns folders themselves, now empty, go too: no entry is left
        # that only an extension filled, the app's or a framework's.
        self.assertNotIn(f"{APP}/PlugIns/", names)
        self.assertNotIn(f"{APP}/Frameworks/SideStoreApp.framework/PlugIns/", names)

    def test_the_release_workflow_takes_the_ipa_it_makes(self):
        # add_release.py refuses an IPA with a folder of extensions left,
        # even an empty one in a framework, as the release's IPA has.
        _, out, _ = self.make()
        add_release.check_own_certificate_ipa(out, BUNDLE_ID, "0.13.0")

    def test_everything_else_is_the_releases(self):
        ipa, out, _ = self.make()
        with zipfile.ZipFile(ipa) as before, zipfile.ZipFile(out) as after:
            kept = [entry for entry in before.infolist()
                    if ".appex" not in entry.filename and "/Watch/" not in entry.filename
                    and entry.filename not in (f"{APP}/PlugIns/", f"{APP}/Frameworks/SideStoreApp.framework/PlugIns/")]
            self.assertEqual([entry.filename for entry in after.infolist()], [entry.filename for entry in kept],
                             "the same entries, in the same order")
            for entry in kept:
                copied = after.getinfo(entry.filename)
                with self.subTest(entry=entry.filename):
                    self.assertEqual(copied.date_time, entry.date_time)
                    self.assertEqual(copied.external_attr, entry.external_attr, "its permissions, or its link")
                    self.assertEqual(copied.compress_type, entry.compress_type)
                    if entry.filename != f"{APP}/Info.plist":
                        self.assertEqual(after.read(entry.filename), before.read(entry.filename))
            link = after.getinfo(f"{APP}/Frameworks/Current")
            self.assertTrue(stat.S_ISLNK(link.external_attr >> 16), "a link stays a link")
            executable = after.getinfo(f"{APP}/LiveContainer")
            self.assertTrue((executable.external_attr >> 16) & 0o111, "the app's executable stays one")

    def test_the_same_release_makes_the_same_ipa(self):
        ipa, out, _ = self.make()
        again = self.folder / "again.ipa"
        own_certificate_ipa.make(ipa, again, BUNDLE_ID)
        self.assertEqual(out.read_bytes(), again.read_bytes())

    def test_only_a_release_of_cartouche_is_taken(self):
        cases = {
            "another app": {"CFBundleIdentifier": "com.kdt.livecontainer"},
            "LiveContainer without Cartouche's build": {"CartoucheBundleIdentifier": None},
            "an IPA the Cartouche Installer signed for one player":
                {"CartoucheSigningHandoffKey": b"\x00" * 32},
        }
        for index, (case, info) in enumerate(cases.items()):
            with self.subTest(case=case):
                plist = {key: value for key, value in info.items() if value is not None}
                ipa = release_ipa(self.folder / f"{index}.ipa", info=plist)
                if info.get("CartoucheBundleIdentifier", "") is None:
                    ipa = self.without_key(ipa, "CartoucheBundleIdentifier")
                out = self.folder / f"{index}-out.ipa"
                with self.assertRaises(own_certificate_ipa.OwnCertificateError):
                    own_certificate_ipa.make(ipa, out, BUNDLE_ID)
                self.assertFalse(out.exists(), "nothing written")
                self.assertEqual(list(self.folder.glob("*.part")), [], "no partial file left")

    def without_key(self, ipa: Path, key: str) -> Path:
        stripped = ipa.with_name("stripped-" + ipa.name)
        with zipfile.ZipFile(ipa) as source, zipfile.ZipFile(stripped, "w") as target:
            for entry in source.infolist():
                data = source.read(entry)
                if entry.filename == f"{APP}/Info.plist":
                    info = plistlib.loads(data)
                    info.pop(key, None)
                    data = plistlib.dumps(info, fmt=plistlib.FMT_BINARY)
                target.writestr(entry, data)
        return stripped

    def test_an_ipa_must_hold_one_app(self):
        two = self.folder / "two.ipa"
        with zipfile.ZipFile(two, "w") as archive:
            for name in ("One", "Two"):
                archive.writestr(f"Payload/{name}.app/Info.plist",
                                 plistlib.dumps({"CFBundleIdentifier": BUNDLE_ID, "CartoucheBundleIdentifier": BUNDLE_ID}))
        empty = self.folder / "empty.ipa"
        with zipfile.ZipFile(empty, "w") as archive:
            archive.writestr("Payload/", b"")
        not_a_zip = self.folder / "text.ipa"
        not_a_zip.write_text("not an IPA")
        for ipa in (two, empty, not_a_zip):
            with self.subTest(ipa=ipa.name), self.assertRaises(own_certificate_ipa.OwnCertificateError):
                own_certificate_ipa.make(ipa, self.folder / "out.ipa", BUNDLE_ID)

    def test_the_command_line(self):
        ipa = release_ipa(self.folder / "Cartouche.ipa")
        out = self.folder / "Cartouche-0.13.0-Own-Certificate.ipa"
        printed = io.StringIO()
        sys.stdout, saved = printed, sys.stdout
        try:
            code = own_certificate_ipa.main(["--ipa", str(ipa), "--out", str(out)])
        finally:
            sys.stdout = saved
        self.assertEqual(code, 0)
        self.assertIn("CartoucheImportedSigning set", printed.getvalue())
        with zipfile.ZipFile(out) as archive:
            self.assertIs(plistlib.loads(archive.read(f"{APP}/Info.plist"))["CartoucheImportedSigning"], True)
        sys.stderr, saved = io.StringIO(), sys.stderr
        try:
            self.assertEqual(own_certificate_ipa.main(["--ipa", str(self.folder / "missing.ipa"), "--out", str(out)]), 1)
        finally:
            sys.stderr = saved

    def test_the_keys_are_the_ones_cartouche_and_its_installer_read(self):
        # A key renamed on one side only would make an IPA Cartouche does
        # not take for one signed with the player's own certificate.
        swift = "".join((ROOT / "launcher/Sources" / name).read_text(encoding="utf-8") for name in (
            "CartoucheImportedSigning.swift", "CartoucheSetup.swift",
            # CartoucheSigningMode, which tells the Installer's install from
            # one signed on the iPhone.
            "CartoucheOwnSignature.swift"))
        installer = (ROOT / "installer/src-tauri/src/imported_signing.rs").read_text(encoding="utf-8")
        patch = next((ROOT / "app/patches/livecontainer").glob("*imported-signing*.patch")).read_text(encoding="utf-8")
        for key in (own_certificate_ipa.IMPORTED, own_certificate_ipa.HANDOFF_KEY, own_certificate_ipa.CARTOUCHE_ID):
            with self.subTest(key=key):
                self.assertIn(f'"{key}"', swift)
        self.assertIn(f'"{own_certificate_ipa.IMPORTED}"', installer)
        self.assertIn(f'"{own_certificate_ipa.HANDOFF_KEY}"', installer)
        self.assertIn(f'@"{own_certificate_ipa.IMPORTED}"', patch, "LiveContainer's side of the mode reads it too")
        # At its first start, LiveContainer's bootstrap takes the shared
        # settings from Cartouche's own sandbox for an install in this mode,
        # since iOS gives no suite named after the app itself: 0.12.0 stopped
        # there (#155). The key it reads is the one this IPA has.
        bootstrap = patch.split("+++ b/LiveContainer/LCBootstrap.m", 1)[1].split("--- a/", 1)[0]
        source = "\n".join(line[1:] for line in bootstrap.splitlines() if line.startswith((" ", "+")))
        shared = re.search(r"lcSharedDefaults = .*?;", source, re.S).group()
        self.assertIn(f'infoDictionary[@"{own_certificate_ipa.IMPORTED}"]', shared)
        self.assertRegex(shared, r"\?\s*lcUserDefaults\s*:", "an install in this mode takes Cartouche's own settings")
        # The installer leaves out the same extensions before it signs.
        self.assertRegex(installer, re.compile(r'\["PlugIns", "Watch"\]'))


if __name__ == "__main__":
    unittest.main()
