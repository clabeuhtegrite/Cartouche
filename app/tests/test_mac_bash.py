"""Checks the repository's shell scripts against the bash of a Mac, 3.2, as
/bin/bash and as the bash that env finds without Homebrew's: on Ad's Mac and
on GitHub's, where the gallery, the harness, the app and Cartouche Builder are
built and tested.

bash 3.2 finds where a command substitution, $( ... ), ends by reading what
it holds as shell, a here-document's lines included: an apostrophe there, as
in a comment of the Python a here-document holds, opens a quote that never
closes, and the script stops before it runs, with "unexpected EOF while
looking for matching `)'", as launcher/Gallery/uitests.sh did on the Mac on
2026-11-13. bash 4 and later, on Linux, where shellcheck and bash -n pass,
read a here-document as a here-document, so only this test sees it.

Run from the repository root: python3 -m unittest discover -s app/tests -v
"""

import re
import subprocess
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]

# A here-document opened inside a command substitution, on the same line:
# $(python3 - <<'PY', $(cat <<EOF, $(... <<-"END".
OPENER = re.compile(r"\$\([^)]*<<-?\s*(['\"]?)(\w+)\1")


def scripts():
    """The repository's shell scripts: its .sh files and those without an
    extension that start with a shell's #!, outside the sources it checks
    out as submodules."""
    tracked = subprocess.run(["git", "-C", str(ROOT), "ls-files", "-z"], check=True,
                             capture_output=True).stdout.decode().split("\0")
    found = []
    for name in tracked:
        path = ROOT / name
        if not name or not path.is_file():
            continue
        if name.endswith(".sh"):
            found.append(path)
        elif "." not in path.name:
            with path.open("rb") as file:
                first = file.readline()
            if re.match(rb"#!.*\b(ba)?sh\b", first):
                found.append(path)
    return sorted(found)


def open_for_bash_32(body):
    """What bash 3.2 leaves open once it has read BODY, the lines of a
    here-document inside $( ), as shell: a quote, or a parenthesis, or one
    closed too many, which ends the command substitution there. None when
    it reads them through."""
    depth = 0
    quote = None
    i = 0
    while i < len(body):
        c = body[i]
        if quote == "'":
            if c == "'":
                quote = None
        elif quote == '"':
            if c == "\\":
                i += 1
            elif c == '"':
                quote = None
        elif c == "\\":
            i += 1
        elif c in "'\"":
            quote = c
        elif c == "(":
            depth += 1
        elif c == ")":
            depth -= 1
            if depth < 0:
                return "a parenthesis closed too many, which ends the $( ) there"
        i += 1
    if quote:
        return f"a quote, {quote}"
    if depth:
        return "a parenthesis"
    return None


class MacBashTest(unittest.TestCase):
    def test_bash_32_reads_a_here_document_in_a_command_substitution_through(self):
        documents = 0
        for script in scripts():
            lines = script.read_text(encoding="utf-8").split("\n")
            for number, line in enumerate(lines):
                opener = OPENER.search(line)
                if not opener:
                    continue
                end = opener.group(2)
                body = []
                for following in lines[number + 1:]:
                    if following.strip() == end:
                        break
                    body.append(following)
                documents += 1
                with self.subTest(script=str(script.relative_to(ROOT)), line=number + 1):
                    for offset, text in enumerate(body):
                        if open_for_bash_32(text):
                            # The first line that leaves something open, as
                            # an apostrophe in a comment does.
                            where = f"; line {number + 2 + offset} leaves {open_for_bash_32(text)} open: {text.strip()}"
                            break
                    else:
                        where = ""
                    self.assertIsNone(open_for_bash_32("\n".join(body)),
                                      f"bash 3.2 does not find the end of this $( ){where}")
        self.assertGreater(documents, 0, "no here-document inside $( ) any more: is the test still needed?")

    def test_an_apostrophe_in_a_comment_leaves_a_quote_open(self):
        self.assertEqual(open_for_bash_32("# The newest iPads come last in simctl's list.\n"), "a quote, '")
        self.assertEqual(open_for_bash_32("print(sorted(names)\n"), "a parenthesis")
        self.assertIsNotNone(open_for_bash_32("exit)\n"))
        self.assertIsNone(open_for_bash_32("print(f\"{kind['name']} (M5)\")\n"))
        self.assertIsNone(open_for_bash_32('"""17 for an iPhone 17 Pro; None for any other device."""\n'))
        self.assertIsNone(open_for_bash_32("print(\"it's \\\"quoted\\\" (here)\")\n"))


if __name__ == "__main__":
    unittest.main()
