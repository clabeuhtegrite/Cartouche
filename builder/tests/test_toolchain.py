import os
import unittest

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
