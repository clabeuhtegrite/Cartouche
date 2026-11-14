import os
import unittest
from unittest import mock

from cartouche_builder import toolchain
from cartouche_builder.paths import Paths

from support import Home


class Toolchain(Home):
    def test_dotnet_only_for_a_checkout_that_builds_with_it(self):
        self.assertFalse(toolchain.needs_dotnet(None))
        engine = self.tmp / "nxnative"
        engine.mkdir()
        self.assertFalse(toolchain.needs_dotnet(engine))  # not cloned yet: the newest nxnative needs none
        (engine / "dm/tools/nx_extract").mkdir(parents=True)
        self.assertTrue(toolchain.needs_dotnet(engine))  # before nxnative 641636e2
        native = engine / toolchain.NATIVE_NX_EXTRACT
        native.parent.mkdir(parents=True)
        native.write_bytes(b"\xcf\xfa\xed\xfe")
        self.assertFalse(toolchain.needs_dotnet(engine))

    def test_doctor_says_where_the_homebrew_tools_are_and_skips_dotnet(self):
        tools = self.tmp / "bin"
        tools.mkdir()
        for name in ("xcodegen", "zstd", "glslangValidator"):
            path = tools / name
            path.write_text("#!/bin/sh\nexit 0\n")
            path.chmod(0o755)
        engine = self.tmp / "nxnative"
        native = engine / toolchain.NATIVE_NX_EXTRACT
        native.parent.mkdir(parents=True)
        native.write_bytes(b"\xcf\xfa\xed\xfe")
        saved = os.environ.get("PATH", "")
        os.environ["PATH"] = str(tools) + os.pathsep + saved
        try:
            checks = {c.key: c for c in toolchain.doctor(Paths.default(), engine)}
        finally:
            os.environ["PATH"] = saved
        self.assertTrue(checks["homebrew_tools"].ok)
        self.assertEqual(checks["homebrew_tools"].found, str(tools))
        self.assertTrue(checks["dotnet"].ok)
        self.assertFalse(checks["dotnet"].blocking)
        self.assertNotIn("dotnet", [c.key for c in toolchain.blocking(list(checks.values()))])

    def test_the_xcode_nxnative_builds_with(self):
        self.assertEqual(toolchain.wanted_xcode(None), toolchain.XCODE)
        engine = self.tmp / "nxnative"
        engine.mkdir()
        self.assertEqual(toolchain.wanted_xcode(engine), toolchain.XCODE)  # a checkout without the file
        tools = engine / toolchain.OWN_COMPILERS
        tools.parent.mkdir(parents=True)
        tools.write_text("import os\nXCODE_VERSION = '27.3'   # the Xcode whose Metal compiler dmsh_chain.lock records\nXCODE = f'Xcode {XCODE_VERSION}'\n")
        self.assertEqual(toolchain.wanted_xcode(engine), "27.3")

    def test_an_older_xcode_than_nxnatives_stops_the_builds(self):
        """Xcode 27.1's Metal compiler, which nxnative refuses for every NVN
        game: the doctor says to update Xcode before any build is tried."""
        engine = self.tmp / "nxnative"
        tools = engine / toolchain.OWN_COMPILERS
        tools.parent.mkdir(parents=True)
        tools.write_text("XCODE_VERSION = '27.2'\n")
        for found, ok in (("27.1 (27B44)", False), ("27.2 (27C55)", True), ("27.3 (27D20)", True)):
            with self.subTest(xcode=found), mock.patch.object(toolchain, "xcode_version", return_value=found):
                xcode = {c.key: c for c in toolchain.doctor(Paths.default(), engine)}["xcode"]
                self.assertEqual((xcode.ok, xcode.blocking, xcode.found), (ok, True, found))
        with mock.patch.object(toolchain, "xcode_version", return_value="27.1 (27B44)"):
            xcode = {c.key: c for c in toolchain.doctor(Paths.default(), engine)}["xcode"]
        self.assertEqual(xcode.fix, "Xcode 27.1 is older than Xcode 27.2, whose Metal compiler nxnative builds the shaders with: "
                                    "update Xcode in the App Store (the page “This Mac's tools” does it with you).")
        self.assertEqual(xcode.command, "")
        with mock.patch.object(toolchain, "xcode_version", return_value=None):
            xcode = {c.key: c for c in toolchain.doctor(Paths.default(), engine)}["xcode"]
        self.assertEqual((xcode.ok, xcode.command), (False, "sudo xcode-select -s /Applications/Xcode-27.2.app"))

    def test_doctor_names_missing_tools(self):
        saved = os.environ.get("PATH", "")
        os.environ["PATH"] = str(self.tmp / "empty")
        try:
            checks = {c.key: c for c in toolchain.doctor(Paths.default(), None)}
        finally:
            os.environ["PATH"] = saved
        brew = checks["homebrew_tools"]
        if brew.ok:  # a machine with them in /opt/homebrew or /usr/local
            self.skipTest("Homebrew's tools are installed here")
        self.assertIn("brew install", brew.command)


if __name__ == "__main__":
    unittest.main()
