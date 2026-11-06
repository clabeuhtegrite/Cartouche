"""Checks how cartouche_s2.rewriter runs a rewriter inside this process, with
stand-ins for nxnative's patch_nso.py: the environment of a run, a restart
through os.execve(), a failure, and what is put back afterwards.

Run from the repository root: python3 -m unittest discover -s engine/spikes/s2/tests -v
"""

import os
import sys
import tempfile
import textwrap
import unittest
from pathlib import Path
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from cartouche_s2 import rewriter  # noqa: E402

# Writes what it was given, after starting itself again once with
# DM_PATCH_FRONT, as patch_nso.py does when its patch area does not fit.
RESTARTING = """
    import os, sys
    import helper
    src, out, name = sys.argv[1:4]
    if "DM_PATCH_FRONT" not in os.environ:
        os.execve(sys.executable, [sys.executable] + sys.argv, dict(os.environ, DM_PATCH_FRONT="0x10000"))
    with open(os.path.join(out, name + ".txt"), "w") as f:
        f.write(" ".join([os.environ["DM_PATCH_FRONT"], os.environ.get("DM_REWRITE_J", "-"),
                          os.environ.get("S2_TEST", "-"), helper.VALUE, os.path.basename(src)]))
"""


class RewriterTest(unittest.TestCase):
    def setUp(self):
        self.folder = Path(tempfile.mkdtemp(prefix="s2-rewriter-test-"))
        self.tools = self.folder / "dm" / "tools"
        self.tools.mkdir(parents=True)
        (self.tools / "helper.py").write_text("VALUE = 'helper'\n")
        self.module = self.folder / "main"
        self.module.write_bytes(b"NSO0")
        self.out = self.folder / "out"
        self.out.mkdir()

    def script(self, text):
        (self.tools / "patch_nso.py").write_text(textwrap.dedent(text))

    def test_a_restart_runs_again_in_this_process_and_everything_is_put_back(self):
        self.script(RESTARTING)
        before_env, before_path, before_argv = dict(os.environ), list(sys.path), sys.argv
        execve = os.execve
        self.assertEqual(rewriter.rewrite(self.tools, self.module, self.out, env={"S2_TEST": "yes"}), 1)
        front, workers, test, helper, source = (self.out / "main.txt").read_text().split()
        self.assertEqual((front, test, helper, source), ("0x10000", "yes", "helper", "main"))
        self.assertEqual(workers, "-" if rewriter.can_fork() else "1")
        self.assertEqual(dict(os.environ), before_env)
        self.assertEqual((sys.path, sys.argv), (before_path, before_argv))
        self.assertIs(os.execve, execve)
        self.assertNotIn("helper", sys.modules)

    def test_one_worker_where_the_process_cannot_fork(self):
        self.script(RESTARTING)
        with mock.patch.object(rewriter, "can_fork", return_value=False):
            rewriter.rewrite(self.tools, self.module, self.out, name="sdk")
        self.assertEqual((self.out / "sdk.txt").read_text().split()[1], "1")
        self.assertNotIn("DM_REWRITE_J", os.environ)

    def test_a_failure_names_the_module_and_still_puts_everything_back(self):
        self.script("import sys\nsys.exit('[RED] the module is damaged')\n")
        before_env = dict(os.environ)
        with self.assertRaisesRegex(RuntimeError, r"stopped on main: \[RED\] the module is damaged"):
            rewriter.rewrite(self.tools, self.module, self.out, env={"S2_TEST": "yes"})
        self.assertEqual(dict(os.environ), before_env)

    def test_a_rewriter_that_keeps_starting_again_is_stopped(self):
        self.script("import os, sys\nos.execve(sys.executable, sys.argv, dict(os.environ))\n")
        with self.assertRaisesRegex(RuntimeError, "started itself again"):
            rewriter.rewrite(self.tools, self.module, self.out)

    def test_an_exit_with_code_zero_is_a_success(self):
        self.script("import sys\nsys.exit(0)\n")
        self.assertEqual(rewriter.rewrite(self.tools, self.module, self.out), 0)


if __name__ == "__main__":
    unittest.main()
