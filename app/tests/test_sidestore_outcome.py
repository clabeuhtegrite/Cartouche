"""Checks that what the built-in SideStore leaves Cartouche on how its
actions ended (app/patches/sidestore/0014) lines up with what Cartouche reads
of it (CartoucheSideStoreOutcome, launcher/Sources/CartoucheFailure.swift):

- both sides name the same keychain item and the same actions, and each
  action of SideStore leaves the one Cartouche waits for;
- Cartouche reads every field SideStore writes, each as a number, a name or
  a flag;
- the stages and families Cartouche tells causes from are ones SideStore
  leaves, and the cases it names are cases of SideStore's errors;
- the sentences Cartouche tells LiveContainer's bridge failures by, when
  SideStore left nothing, are still LiveContainer's;
- Apple's HTTP errors without an answer of its own, such as its 429 when it
  limits the sign-ins (app/patches/sidestore/0016), are told apart in the
  sign-in and the developer services, as cases Cartouche names.

SideStore's sources are read as app/scripts/prepare.sh leaves them, every
patch applied, so that a later patch's fields count too. Needs the
LiveContainer and SideStore submodules, with SideSign and minimuxer.

Run from the repository root: python3 -m unittest discover -s app/tests -v
"""

import functools
import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
FAILURE = ROOT / "launcher" / "Sources" / "CartoucheFailure.swift"
LAUNCHER = ROOT / "launcher" / "Sources"
PATCHES = ROOT / "app" / "patches" / "sidestore"
SIDESTORE = ROOT / "app" / "SideStore"
BRIDGE = ROOT / "app" / "LiveContainer" / "SideStoreSupport"

# The families whose errors Cartouche tells no cause from but their codes.
UNMAPPED_FAMILIES = {"cocoa", "posix", "system", "other"}


HUNK = re.compile(r"^@@ -(\d+)(?:,(\d+))? \+\d+(?:,(\d+))? @@")


@functools.lru_cache(maxsize=None)
def hunks(patch: Path) -> dict:
    """The hunks of PATCH, by the file they change: each one as the line it
    starts at in the file before, how many of its lines it replaces, and its
    lines, as (" ", "-" or "+", text)."""
    found, current = {}, None
    lines = patch.read_text(encoding="utf-8").split("\n")
    index = 0
    while index < len(lines):
        line = lines[index]
        index += 1
        if line.startswith("+++ "):
            current = None if line.startswith("+++ /dev/null") else line[len("+++ b/"):].rstrip("\t")
            if current:
                found.setdefault(current, [])
            continue
        header = HUNK.match(line)
        if not (current and header):
            continue
        start, old, new = int(header.group(1)), int(header.group(2) or 1), int(header.group(3) or 1)
        replaced, body = old, []
        while old > 0 or new > 0:
            if index >= len(lines):
                raise AssertionError(f"{patch.name}: a hunk of {current} ends early")
            text = lines[index]
            index += 1
            if text.startswith("\\"):
                continue  # "\ No newline at end of file"
            tag, text = (text[:1], text[1:]) if text else (" ", "")
            if tag not in " -+":
                raise AssertionError(f"{patch.name}: a hunk of {current} has a line that is not one")
            body.append((tag, text))
            old -= tag != "+"
            new -= tag != "-"
        found[current].append((start, replaced, tuple(body)))
    return found


def patched(path: str) -> str:
    """PATH of SideStore's sources as app/scripts/prepare.sh leaves it: the
    submodule's, with every patch applied in name order, each hunk where
    its lines are, nearest the line it gives, as patch(1) does."""
    if not (SIDESTORE / "Dependencies" / "SideSign" / "Sources").is_dir():
        raise AssertionError(f"{SIDESTORE.relative_to(ROOT)} is missing: run git submodule update --init --recursive")
    original = SIDESTORE / path
    lines = original.read_text(encoding="utf-8").split("\n") if original.exists() else []
    for patch in sorted(PATCHES.glob("*.patch")):
        shift = drift = 0
        for start, replaced, body in hunks(patch).get(path, []):
            before = [text for tag, text in body if tag != "+"]
            after = [text for tag, text in body if tag != "-"]
            given = (start if replaced == 0 else start - 1) + shift
            at = next((position for distance in range(len(lines) + 1)
                       for position in (given + drift - distance, given + drift + distance)
                       if 0 <= position <= len(lines) - len(before)
                       and lines[position:position + len(before)] == before), None)
            if at is None:
                raise AssertionError(f"{patch.name} does not apply to {path}")
            lines[at:at + len(before)] = after
            drift = at - given
            shift += len(after) - len(before)
    return "\n".join(lines)


def patch_files() -> dict:
    """The files patch 0014 changes, by their path, every patch applied."""
    patches = sorted(PATCHES.glob("*-tell-cartouche-where-its-actions-stopped-and-why.patch"))
    if len(patches) != 1:
        raise AssertionError(f"expected one outcome patch in {PATCHES.relative_to(ROOT)}, found {len(patches)}")
    return {name: patched(name) for name in hunks(patches[0])}


def block(text: str, opening: str, what: str) -> str:
    """The body of the braces that follow OPENING, which may open on the next
    line (SideStore's style) or on the same one (Cartouche's)."""
    start = text.find(opening)
    if start < 0:
        raise AssertionError(f"{what} not found")
    first = text.index("{", start + len(opening))
    depth = 0
    for index in range(first, len(text)):
        if text[index] == "{":
            depth += 1
        elif text[index] == "}":
            depth -= 1
            if depth == 0:
                return text[first + 1:index]
    raise AssertionError(f"{what} does not close")


def cases(body: str) -> set:
    """The cases an enumeration's body declares, without what they carry."""
    names = set()
    for declaration in re.findall(r"^\s*case ([^\n]+)", body, re.M):
        for part in re.split(r",\s*(?![^()]*\))", declaration):
            name = re.match(r"(\w+)", part.strip())
            if name:
                names.add(name.group(1))
    return names


def error_cases(path: Path, name: str) -> set:
    if not path.exists():
        raise AssertionError(f"{path.relative_to(ROOT)} is missing: run git submodule update --init --recursive")
    text = path.read_text(encoding="utf-8")
    return cases(block(text, f"enum {name}:", f"{name} in {path.relative_to(ROOT)}").split("var ")[0])


def ours() -> str:
    return block(FAILURE.read_text(encoding="utf-8"), "struct CartoucheSideStoreOutcome:", "CartoucheSideStoreOutcome")


def branches(cause: str) -> dict:
    """The kinds each family's branch of CartoucheSideStoreOutcome.cause
    names, by family."""
    found = {}
    switch = block(cause, "switch family", "the switch on the family")
    for match in re.finditer(r'^        case ((?:"\w+"(?:, )?)+):\n(.*?)(?=^        (?:case|default)\b)', switch, re.M | re.S):
        families = re.findall(r'"(\w+)"', match.group(1))
        # The kinds its own cases name, not the family or stage it compares.
        kinds = set()
        for listed in re.findall(r'case ((?:"\w+",?\s*)+):', match.group(2)):
            kinds |= set(re.findall(r'"(\w+)"', listed))
        for family in families:
            found[family] = kinds
    return found


class SideStoreOutcomeTest(unittest.TestCase):
    def setUp(self):
        self.files = patch_files()
        self.outcome = self.files["SideStore/Intents/CartoucheOutcome.swift"]
        self.ours = ours()
        self.cause = block(self.ours, "var cause: CartoucheFailure.Cause", "CartoucheSideStoreOutcome.cause")

    def test_both_sides_name_the_same_keychain_item(self):
        account = re.compile(r'static let account = "([^"]+)"')
        self.assertEqual(account.search(self.outcome).group(1), account.search(self.ours).group(1))
        # SideStore's keychain service is Cartouche's bundle identifier, as
        # for the sign-in's items (app/tests/test_sign_in.py).
        self.assertIn("Bundle.Info.appbundleIdentifier", self.outcome)

    def test_each_action_leaves_the_one_cartouche_waits_for(self):
        theirs = cases(block(self.outcome, "enum Action: String", "SideStore's actions"))
        mine = cases(block(self.ours, "enum Action: String", "Cartouche's actions"))
        self.assertEqual(theirs, {"signIn", "refresh", "update"})
        self.assertEqual(theirs, mine)
        left = {
            "SideStore/Intents/CartoucheSignInIntent.swift": "signIn",
            "AltStore/Intents/App Intents/RefreshAllAppsIntent.swift": "refresh",
            "SideStore/Intents/UpdateCartoucheIntent.swift": "update",
        }
        for name, action in left.items():
            self.assertEqual(re.findall(r"CartoucheOutcome\(action: \.(\w+)\)", self.files[name]), [action], name)
        waited = {"CartoucheAccount.swift": "signIn", "CartoucheRenewal.swift": "refresh", "CartoucheUpdates.swift": "update"}
        for name, action in waited.items():
            text = (LAUNCHER / name).read_text(encoding="utf-8")
            self.assertEqual(re.findall(r"CartoucheSideStoreOutcome\(data: \$0, expecting: \.(\w+)", text), [action], name)

    def test_cartouche_reads_every_field_sidestore_writes(self):
        save = block(self.outcome, "func save(", "CartoucheOutcome.save")
        written = set(re.findall(r'^\s*"(\w+)": ', save, re.M)) | set(re.findall(r'outcome\["(\w+)"\]', save))
        noted = set(re.findall(r'\.note\("(\w+)"', self.files["SideStore/Intents/CartoucheSignInIntent.swift"]))
        self.assertIn("codeAsked", noted)
        keys = cases(block(self.ours, "enum Key: String, CodingKey", "the keys Cartouche reads"))
        self.assertEqual(written | noted, keys)
        # Each one read as a number, a name or a flag, apart from the four
        # every outcome has.
        typed = set()
        for listed in re.findall(r"for key in \[Key\.(\w+((?:, \.\w+)*))\]", self.ours):
            typed |= {name.strip(" .") for name in listed[0].split(",")}
        self.assertEqual(typed, keys - {"version", "action", "ok", "date"})
        version = int(re.search(r"static let version = (\d+)", self.outcome).group(1))
        self.assertIn("(1...99).contains(written.version)", self.ours)
        self.assertTrue(1 <= version <= 99)

    def test_the_stages_cartouche_tells_causes_from_are_sidestores(self):
        stages = cases(block(self.files["SideStore/Intents/CartoucheSignInIntent.swift"],
                             "enum Stage: String, CaseIterable", "the sign-in's stages"))
        named = set(re.findall(r'stage == "(\w+)"', self.cause))
        self.assertEqual(named, {"database", "certificate"})
        self.assertLessEqual(named, stages)
        # A refresh or an update leaves its last operation as its stage:
        # the trail AsyncOperation keeps.
        self.assertIn("CartoucheOutcome.reached(", self.files["SideStore/Core/Operations/AsyncOperation.swift"])

    def test_every_family_sidestore_leaves_has_its_causes(self):
        kind = block(self.outcome, "static func kind(of error: Error)", "CartoucheOutcome.kind(of:)")
        families = set(re.findall(r'family = "(\w+)"', kind)) | set(re.findall(r'return \("(\w+)", ', kind))
        self.assertEqual(families - UNMAPPED_FAMILIES, set(branches(self.cause)))

    def test_the_cases_cartouche_names_are_sidestores(self):
        found = branches(self.cause)
        sidesign = SIDESTORE / "Dependencies" / "SideSign" / "Sources"
        portal = error_cases(sidesign / "Models" / "Errors.swift", "DeveloperPortalError")
        signer = error_cases(sidesign / "Models" / "Errors.swift", "SignerError")
        operation = error_cases(SIDESTORE / "SideStore" / "Core" / "Operations" / "Errors" / "OperationError.swift",
                                "OperationError")
        minimuxer = error_cases(SIDESTORE / "Dependencies" / "minimuxer" / "Sources" / "MinimuxerError.swift",
                                "MinimuxerError")
        mine = block(self.files["SideStore/Intents/CartoucheSignInIntent.swift"], "enum Kind: String", "the sign-in's kinds")
        self.assertLessEqual(found["portal"], portal)
        self.assertLessEqual(found["signer"], signer)
        self.assertLessEqual(found["operation"], operation | minimuxer)
        self.assertEqual(found["operation"], found["minimuxer"])
        self.assertLessEqual(found["cartouche"], cases(mine))

    def test_the_bridges_sentences_are_still_livecontainers(self):
        listed = re.search(r"static let bridgeSentences[^=]*= \[(.*?)\n    \]", FAILURE.read_text(encoding="utf-8"), re.S)
        self.assertIsNotNone(listed, "the bridge's sentences not found")
        sentences = re.findall(r'^\s*\("([^"]+)", \.(\w+)\),$', listed.group(1), re.M)
        self.assertEqual(len(sentences), 7)
        bridge = "\n".join(path.read_text(encoding="utf-8") for path in sorted(BRIDGE.glob("*.swift")))
        for sentence, _ in sentences:
            self.assertIn('"' + sentence, bridge, sentence)

    def test_apples_http_errors_are_told_apart_from_its_answers(self):
        # Apple's 429, and its pages for other errors, become
        # ServerError.httpStatus before SideSign reads them as an answer
        # (patch 0016): in the sign-in, its verification codes and the
        # developer services.
        requests = {
            "Authentication.swift": ["func sendAuthenticationRequest(", "func sendTrustedDevice2FACodeRequest(",
                                     "func sendPhone2FACodeRequest("],
            "DeveloperPortalAPI.swift": ["func sendRequest<", "func sendServicesRequest<"],
        }
        for name, functions in requests.items():
            text = patched("Dependencies/SideSign/Sources/DeveloperPortal/" + name)
            for function in functions:
                self.assertIn("ServerError.httpFailure(response, body: data)", block(text, function, function), function)
        # Its outcome gives the status as http, and the service and the wait.
        self.assertIn("case ServerError.httpStatus(let status, _, _)", self.outcome)
        self.assertIn("if case ServerError.httpStatus(_, let retryAfter, let service) = error", self.outcome)

    def test_the_server_errors_cartouche_tells_pages_by_are_sidesigns(self):
        # Cartouche tells Apple's pages and HTTP errors by these cases of
        # SideSign's ServerError (CartoucheSignInMessage.trouble), the
        # first one patch 0016's.
        errors = patched("Dependencies/SideSign/Sources/Models/Errors.swift")
        server = cases(block(errors, "enum ServerError:", "SideSign's ServerError").split("var ")[0])
        message = (LAUNCHER / "CartoucheSignInMessage.swift").read_text(encoding="utf-8")
        named = set(re.findall(r'kind == "(\w+)"', block(message, "static func trouble(", "CartoucheSignInMessage.trouble")))
        self.assertEqual(named, {"httpStatus", "invalidResponseFormat"})
        self.assertLessEqual(named, server)


if __name__ == "__main__":
    unittest.main()
