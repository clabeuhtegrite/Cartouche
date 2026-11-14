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
  sign-in and the developer services, as cases Cartouche names;
- the outcome reads the error behind the titles SideStore wraps errors in,
  and every sentence SideStore's code gives invalidParameters, which it
  throws for what it did not expect, has the name of a reason, each one
  named still SideStore's (app/patches/sidestore/0018).
- the sign-in, and the step that registers this iPhone alone, check that
  SideStore reaches the iPhone before anything goes to Apple
  (app/patches/sidestore/0019), and the stages Cartouche reads of them are
  theirs.
- every sentence minimuxer gives when it cannot reach this iPhone, which
  SideStore passes on in its noVPN, invalidVPN, invalidPairingFile..., has
  the name of a reason, each one named still minimuxer's, and the words
  minimuxer tells a broken connection or a refused pairing by have the name
  of a detail (app/patches/sidestore/0022).

SideStore's sources are read as app/scripts/prepare.sh leaves them, every
patch applied, so that a later patch's fields count too. Needs the
LiveContainer and SideStore submodules, with SideSign and minimuxer.

Run from the repository root: python3 -m unittest discover -s app/tests -v
"""

import functools
import json
import re
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
FAILURE = ROOT / "launcher" / "Sources" / "CartoucheFailure.swift"
LAUNCHER = ROOT / "launcher" / "Sources"
PATCHES = ROOT / "app" / "patches" / "sidestore"
SIDESTORE = ROOT / "app" / "SideStore"
MINIMUXER = SIDESTORE / "Dependencies" / "minimuxer"
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


@functools.lru_cache(maxsize=None)
def own_sources() -> dict:
    """SideStore's own Swift sources, not those of its dependencies, by their
    path, every patch applied, with those a patch adds."""
    touched = {name for patch in sorted(PATCHES.glob("*.patch")) for name in hunks(patch)}
    names = {path.relative_to(SIDESTORE).as_posix() for path in SIDESTORE.rglob("*.swift")}
    names |= {name for name in touched if name.endswith(".swift")}
    return {name: patched(name) if name in touched else (SIDESTORE / name).read_text(encoding="utf-8")
            for name in sorted(names) if not name.startswith("Dependencies/")}


def swift_literal(text: str, index: int) -> tuple:
    """The string literal that opens at INDEX of TEXT, with each of its
    interpolations as "…", and where it ends."""
    escapes = {"n": "\n", "t": "\t", '"': '"', "\\": "\\", "'": "'", "0": ""}
    index += 1
    out = []
    while text[index] != '"':
        if text[index] != "\\":
            out.append(text[index])
            index += 1
        elif text[index + 1] == "(":
            depth, index = 1, index + 2
            while depth:
                if text[index] == '"':
                    index = swift_literal(text, index)[1]
                    continue
                depth += {"(": 1, ")": -1}.get(text[index], 0)
                index += 1
            out.append("…")
        else:
            out.append(escapes.get(text[index + 1], text[index + 1]))
            index += 2
    return "".join(out), index + 1


def invalid_parameters(text: str) -> list:
    """What each OperationError.invalidParameters in TEXT is given: the
    sentence its string literals make, or the expression itself when it
    holds none. The case's declaration and the patterns that bind what it
    carries are left out."""
    found = []
    for match in re.finditer(r"\binvalidParameters\(", text):
        if text[:match.start()].endswith("case ") or re.match(r"\s*(?:let|var)\b", text[match.end():]):
            continue
        index, depth, literals, expression = match.end(), 1, [], []
        while depth:
            if text[index] == '"':
                literal, index = swift_literal(text, index)
                literals.append(literal)
                continue
            depth += {"(": 1, ")": -1}.get(text[index], 0)
            if depth:
                expression.append(text[index])
            index += 1
        found.append(("".join(literals), None) if literals else (None, "".join(expression).strip()))
    return found


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


# The cases of MinimuxerError that say why minimuxer could not reach this
# iPhone, with a sentence of its own.
DEVICE_CASES = ("noVPN", "invalidVPN", "noConnection", "noDevice", "notReachable", "pairingNotLoaded", "notStarted")

# Sentences as minimuxer gives them, with what the outcome tells of them.
DEVICE_EXAMPLES = {
    "utun is present but no ipsec/IKEv2 interface found — LocalDevVPN may not support the lockdown protocol on iOS 26.4+":
        ("noIPsec", None),
    "VPN tunnel iface is up and tunnel peer IP 10.7.0.1 is known, but TCP port poll failed — device may be unreachable "
    "on this interface": ("portClosed", None),
    "Handshake failed: Connection reset by peer (os error 54)": ("handshake", "reset"),
    "Handshake failed: received fatal alert: bad_certificate": ("handshake", "badCertificate"),
    "Service connection failed, error: (Pairing rejected)": ("serviceRefused", "pairing"),
    "Lockdown session failed (pairing invalid): InvalidHostID": ("lockdownSession", None),
    "Connection refused (os error 61)": ("dropped", "refused"),
    "VPN tunnel iface is up but tunnel peer IP is not yet reachable — VPN may not be routing device traffic correctly. "
    "Cause: The request timed out.": ("noPeer", "timedOut"),
    "No utun interface detected — LocalDevVPN is not connected": ("noTunnel", None),
    "No pairing file has been loaded": ("notLoaded", None),
    "Something minimuxer never said": ("other", None),
}


def minimuxer_sources() -> dict:
    """Minimuxer's Swift sources, by their path in it: its own, its gateways'
    and their common code."""
    if not (MINIMUXER / "Sources").is_dir():
        raise AssertionError(f"{MINIMUXER.relative_to(ROOT)} is missing: run git submodule update --init --recursive")
    return {path.relative_to(MINIMUXER).as_posix(): path.read_text(encoding="utf-8")
            for folder in ("Sources", "DeviceGateway", "Common") for path in sorted((MINIMUXER / folder).rglob("*.swift"))}


def device_sentences(sources: dict) -> list:
    """The sentences minimuxer gives when it cannot reach this iPhone, by the
    file they are in: those of its errors for it, of the pairing files it
    refuses (invalidPairing), and of its gateways' invalidPairingFile, which
    becomes one. Each one with its interpolations as "…"."""
    found = []
    calls = re.compile(r"\.(?:" + "|".join(DEVICE_CASES) + r")\(\s*\"|invalidPairing\(protocol: [^,()]+, reason: \"")
    for name, text in sources.items():
        for match in calls.finditer(text):
            found.append((name, swift_literal(text, match.end() - 1)[0]))
        for match in re.finditer(r"GatewayError\(\.invalidPairingFile, reason: (\"|reason\))", text):
            if match.group(1) == '"':
                found.append((name, swift_literal(text, match.end() - 1)[0]))
                continue
            # A sentence the function made just before.
            made = list(re.finditer(r"let reason = \"", text[:match.start()]))
            if not made:
                raise AssertionError(f"{name}: the reason of an invalidPairingFile not found")
            found.append((name, swift_literal(text, made[-1].end() - 1)[0]))
    return found


def listed(text: str, name: str) -> list:
    """The (sentence, name) pairs of the table NAME of the outcome."""
    table = re.search(r"static let " + name + r"[^=]*= \[(.*?)\n    \]", text, re.S)
    if not table:
        raise AssertionError(f"{name} not found")
    return [(sentence.replace('\\"', '"'), told)
            for sentence, told in re.findall(r'^\s*\("((?:[^"\\]|\\.)*)", "(\w+)"\),$', table.group(1), re.M)]


def device_reason(reasons: list, details: list, sentence: str) -> tuple:
    """What CartoucheOutcome.reason(ofDeviceSentence:) gives SENTENCE: the
    reason of the first of minimuxer's sentences it holds, whatever its
    case, and the detail of the first of the library's words past them."""
    rest, reason = sentence.lower(), "other"
    found = next(((fragment.lower(), told) for fragment, told in reasons if fragment.lower() in rest), None)
    if found:
        reason = found[1]
        if reason != "dropped":
            rest = rest[rest.index(found[0]) + len(found[0]):]
    return reason, next((told for words, told in details if words in rest), None)


class SideStoreOutcomeTest(unittest.TestCase):
    def setUp(self):
        self.files = patch_files()
        self.outcome = self.files["SideStore/Intents/CartoucheOutcome.swift"]
        self.ours = ours()
        self.cause = block(self.ours, "var cause: CartoucheFailure.Cause", "CartoucheSideStoreOutcome.cause")
        self.sources = own_sources()
        self.sign_in = self.files["SideStore/Intents/CartoucheSignInIntent.swift"]
        self.device = patched("SideStore/Intents/CartoucheRegisterDeviceIntent.swift")

    def test_both_sides_name_the_same_keychain_item(self):
        account = re.compile(r'static let account = "([^"]+)"')
        self.assertEqual(account.search(self.outcome).group(1), account.search(self.ours).group(1))
        # SideStore's keychain service is Cartouche's bundle identifier, as
        # for the sign-in's items (app/tests/test_sign_in.py).
        self.assertIn("Bundle.Info.appbundleIdentifier", self.outcome)

    def test_each_action_leaves_the_one_cartouche_waits_for(self):
        theirs = cases(block(self.outcome, "enum Action: String", "SideStore's actions"))
        mine = cases(block(self.ours, "enum Action: String", "Cartouche's actions"))
        self.assertEqual(theirs, {"signIn", "device", "refresh", "update"})
        self.assertEqual(theirs, mine)
        left = {
            "SideStore/Intents/CartoucheSignInIntent.swift": "signIn",
            "AltStore/Intents/App Intents/RefreshAllAppsIntent.swift": "refresh",
            "SideStore/Intents/UpdateCartoucheIntent.swift": "update",
        }
        for name, action in left.items():
            self.assertEqual(re.findall(r"CartoucheOutcome\(action: \.(\w+)\)", self.files[name]), [action], name)
        self.assertEqual(re.findall(r"CartoucheOutcome\(action: \.(\w+)\)", self.device), ["device"])
        waited = {"CartoucheAccount.swift": ["signIn", "device"], "CartoucheRenewal.swift": ["refresh"],
                  "CartoucheUpdates.swift": ["update"]}
        for name, actions in waited.items():
            text = (LAUNCHER / name).read_text(encoding="utf-8")
            # The gallery's stand-ins make an outcome of their own, which
            # no action of SideStore's leaves.
            text = re.sub(r"^\s*#if CARTOUCHE_GALLERY\n.*?^\s*#endif\n", "", text, flags=re.M | re.S)
            self.assertEqual(re.findall(r"CartoucheSideStoreOutcome\(data: \$0, expecting: \.(\w+)", text), actions, name)

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

    def test_the_sign_in_reaches_this_iphone_before_apple(self):
        # Sign In to Cartouche makes minimuxer's readiness check before its
        # sign-in starts, and Register Cartouche's iPhone before Apple's
        # developer services (patch 0019).
        check = "try await CartoucheDeviceCheck.run()"
        sign_in = block(self.sign_in, "func perform()", "the sign-in's perform")
        self.assertLess(sign_in.index("handler.reach(.deviceCheck)"), sign_in.index(check))
        self.assertLess(sign_in.index(check), sign_in.index("handler.reach(.account)"))
        self.assertLess(sign_in.index(check), sign_in.index("SignInOperation("))
        device = block(self.device, "func perform()", "the device step's perform")
        self.assertLess(device.index(check), device.index("registerCurrentDevice("))
        self.assertIn("static var isDiscoverable: Bool { false }", self.device)
        self.assertIn("try await ensureMinimuxerReady()", patched("SideStore/Intents/CartoucheDeviceCheck.swift"))

    def test_the_stages_cartouche_reads_of_the_sign_in_are_sidestores(self):
        body = block(self.sign_in, "enum Stage: String, CaseIterable", "the sign-in's stages")
        order = re.findall(r"^\s*case (\w+)", body, re.M)
        self.assertLess(order.index("deviceCheck"), order.index("account"))
        # The step that registers this iPhone alone names its stages as the
        # sign-in does.
        device = set(re.findall(r'stage(?: =|:) "(\w+)"', block(self.device, "func perform()", "the device step's perform")))
        self.assertEqual(device, {"database", "account", "deviceCheck", "device", "finish"})
        self.assertLessEqual(device, set(order))
        # The stages before anything goes to Apple: Cartouche's own, before
        # it hands the sign-in over, then SideStore's before the account.
        message = (LAUNCHER / "CartoucheSignInMessage.swift").read_text(encoding="utf-8")
        listed = re.search(r"static let stagesBeforeApple: Set<String> = \[([^\]]*)\]", message)
        self.assertIsNotNone(listed, "the stages before Apple not found")
        before = set(re.findall(r'"(\w+)"', listed.group(1)))
        self.assertEqual(before - {"start"}, set(order[:order.index("account")]))
        self.assertIn('stage: "start"', (LAUNCHER / "CartoucheAccount.swift").read_text(encoding="utf-8"))
        # And those Cartouche tells the player's next step by, which its
        # words for the sign-in follow.
        read = set(re.findall(r'failure\.stage == "(\w+)"', message))
        read |= set(re.findall(r'case "(\w+)"\??:', block(message, "static func deviceMoment(", "deviceMoment")))
        self.assertEqual(read, {"deviceCheck", "device", "account"})
        self.assertLessEqual(read, set(order))
        words = (LAUNCHER / "CartoucheTextSideStore.swift").read_text(encoding="utf-8")
        self.assertIn("deviceMoment(of: failure)", block(words, "static func sideStoreMessage(", "sideStoreMessage"))

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

    def test_every_sentence_of_invalid_parameters_has_its_reason(self):
        # invalidParameters is what SideStore throws for what its own code
        # did not expect, with a sentence that can name an app: only the
        # name of its reason leaves the iPhone (patch 0018).
        listed = re.search(r"static let invalidParametersReasons[^=]*= \[(.*?)\n    \]", self.outcome, re.S)
        self.assertIsNotNone(listed, "the sentences of invalidParameters not found")
        reasons = [(sentence.replace('\\"', '"'), reason)
                   for sentence, reason in re.findall(r'^\s*\("((?:[^"\\]|\\.)*)", "(\w+)"\),$', listed.group(1), re.M)]
        self.assertGreaterEqual(len(reasons), 40)
        for _, reason in reasons:
            self.assertRegex(reason, r"^[a-z][A-Za-z0-9]{0,47}$")

        sentences, expressions = [], set()
        for name, text in self.sources.items():
            for sentence, expression in invalid_parameters(text):
                if sentence is None:
                    expressions.add(expression)
                else:
                    sentences.append((name, sentence))
        self.assertGreaterEqual(len(sentences), 50)
        for name, sentence in sentences:
            reason = next((reason for fragment, reason in reasons if fragment in sentence), None)
            self.assertIsNotNone(reason, f"{name}: no reason for {sentence!r}")
        # What SideStore passes on of another error's: minimuxer's (its
        # description, or the reason its connection mode is not
        # configured), a dialog it could not show, and an error's words.
        self.assertEqual(expressions, {"reason", "self.description", "errMsg", "error.localizedDescription"})

        # Each sentence the outcome names is still SideStore's, or minimuxer's.
        minimuxer = "\n".join(path.read_text(encoding="utf-8")
                              for path in sorted((SIDESTORE / "Dependencies" / "minimuxer" / "Sources").rglob("*.swift")))
        handlers = self.sources["SideStore/Handlers/PipelineHandler.swift"]
        for fragment, reason in reasons:
            said = any(fragment in sentence for _, sentence in sentences) or fragment in minimuxer or fragment in handlers
            self.assertTrue(said, f"{fragment!r} ({reason}) is no longer SideStore's")

        # What a sentence names, with the outcome's own expressions.
        subjects = re.search(r"static let invalidParametersSubjects = \[(.*?)\n    \]", self.outcome, re.S)
        self.assertIsNotNone(subjects, "what a sentence names not found")
        patterns = [pattern.replace("\\\\", "\\") for pattern in re.findall(r'^\s*"(.+)",$', subjects.group(1), re.M)]

        def subject(sentence):
            for pattern in patterns:
                found = re.search(pattern, sentence)
                if found:
                    return re.sub(r"(?<=.)Operation$", "", found.group(1))
            return None

        examples = {
            "FetchProvisioningProfilesOperation: context.targetAppBundle is nil": ("notInContext", "targetAppBundle"),
            "RefreshAppOperation.execute: self.context.provisioningProfiles is nil": ("notInContext", "provisioningProfiles"),
            "VerifyCertificateOperation: installedApp is missing in context.": ("notInContext", "installedApp"),
            "Missing StandaloneStep mapping for ScheduleExpirationWarningNotificationOperation":
                ("noStepMapping", "ScheduleExpirationWarningNotification"),
            "Missing progress weight for step 'scheduleExpirationWarningNotification' in steps list":
                ("noStepWeight", "scheduleExpirationWarningNotification"),
            "PipelineHandler: Cannot review permissions because presenting view controller is unavailable":
                ("askPermissions", None),
            "Could not resolve installed app for 'Mario Kart World'": ("noResultApp", None),
        }
        for sentence, (reason, missing) in examples.items():
            told = next((reason for fragment, reason in reasons if fragment in sentence), None)
            self.assertEqual((told, subject(sentence)), (reason, missing), sentence)

    def test_every_sentence_minimuxer_gives_for_this_iphone_has_its_reason(self):
        # Minimuxer's sentence for why it could not reach this iPhone can hold
        # the iPhone's address on the tunnel and the library's words: only
        # the names of its reason and of those words leave (patch 0022).
        reasons = listed(self.outcome, "deviceReasons")
        details = listed(self.outcome, "deviceDetails")
        self.assertGreaterEqual(len(reasons), 25)
        for _, told in reasons + details:
            self.assertRegex(told, r"^[a-z][A-Za-z0-9]{0,47}$")

        sources = minimuxer_sources()
        sentences = device_sentences(sources)
        self.assertGreaterEqual(len(sentences), 20)
        # With SideStore's own, which it gives as these errors.
        for name, text in self.sources.items():
            for match in re.finditer(r"OperationError\.(?:noVPN|invalidVPN|noConnection|noDevice|notReachable|"
                                     r"minimuxerNotStarted|pairingNotComplete|invalidPairingFile)\(\s*reason:\s*\"", text):
                sentences.append((name, swift_literal(text, match.end() - 1)[0]))
        self.assertIn(("SideStore/Intents/CartoucheDeviceCheck.swift", "No pairing file has been loaded"), sentences)
        for name, sentence in sentences:
            self.assertNotEqual(device_reason(reasons, details, sentence)[0], "other", f"{name}: no reason for {sentence!r}")

        # Each sentence the outcome names is still minimuxer's, or SideStore's.
        theirs = ("\n".join(sources.values()) + "\n".join(self.sources.values())).lower()
        for fragment, told in reasons:
            self.assertIn(fragment.lower(), theirs, f"{fragment!r} ({told}) is no longer minimuxer's")

        # The words minimuxer tells a broken connection by, which it then
        # gives alone as invalidVPN, are told as one, each with its detail;
        # those it tells a refused pairing by have theirs.
        errors = sources["Sources/MinimuxerError.swift"]
        dropped = re.findall(r'lower\.contains\("([^"]+)"\)', block(errors, "var isVPNDrop: Bool", "isVPNDrop"))
        self.assertGreaterEqual(len(dropped), 5)
        for words in dropped:
            reason, detail = device_reason(reasons, details, f"Tunnel: {words} (os error 54)")
            self.assertEqual(reason, "dropped", words)
            self.assertIsNotNone(detail, words)
        gateway = sources["DeviceGateway/idevice/IdeviceGateway.swift"]
        refused = re.findall(r'msg\.contains\("([^"]+)"\)', block(gateway, "func isPairingError(", "isPairingError"))
        self.assertGreaterEqual(len(refused), 4)
        for words in refused:
            self.assertIsNotNone(device_reason(reasons, details, f"Handshake failed: {words}")[1], words)

        for sentence, told in DEVICE_EXAMPLES.items():
            self.assertEqual(device_reason(reasons, details, sentence), told, sentence)

    def test_the_outcome_reads_minimuxers_sentence_from_each_of_its_errors(self):
        # Every error SideStore makes of minimuxer's errors for this iPhone
        # (MinimuxerError.asOperationError), and each of minimuxer's own,
        # gives the outcome its sentence.
        wrapper = self.sources["SideStore/Core/DeviceApi/MinimuxerWrapper.swift"]
        pairs = re.findall(r"case \.(\w+)\([^)]*\):\s*return \.(\w+)\(",
                           block(wrapper, "var asOperationError: OperationError", "asOperationError"))
        theirs = {source for source, target in pairs if target != "invalidParameters"}
        made = {target for source, target in pairs if target != "invalidParameters"}
        self.assertEqual(theirs, set(DEVICE_CASES) | {"invalidPairing"})
        sentence = block(self.outcome, "static func deviceSentence(of error: Error)", "deviceSentence")
        self.assertEqual(set(re.findall(r"OperationError\.(\w+)\(let", sentence)), made)
        self.assertEqual(set(re.findall(r"MinimuxerError\.(\w+)\(", sentence)), theirs)
        # Cartouche tells a cause from each.
        self.assertLessEqual(made | theirs, branches(self.cause)["operation"])
        # Read once the error behind SideStore's titles is, with what
        # minimuxer went through: the kind of pairing file it loaded, and
        # whether an IPsec interface was up.
        save = block(self.outcome, "func save(", "CartoucheOutcome.save")
        after = save[save.index("let error = Self.unwrapped(thrown)"):]
        told = block(after, "if let sentence = Self.deviceSentence(of: error)", "what minimuxer went through")
        for line in ("Self.reason(ofDeviceSentence: sentence)", 'outcome["reason"] = reason', 'outcome["detail"] = detail',
                     'outcome["pairingKind"] = minimuxerPairingProtocol().rawValue',
                     'outcome["ipsec"] = minimuxer.network.isIKEv2IPSecAvailable'):
            self.assertIn(line, told)
        self.assertIn("func minimuxerPairingProtocol() -> PairingProtocol", wrapper)
        self.assertIn("var isIKEv2IPSecAvailable: Bool { get }", minimuxer_sources()["Sources/MinimuxerApi.swift"])

    @unittest.skipUnless(shutil.which("swiftc"), "Needs Swift")
    def test_the_device_reasons_are_told_in_swift_as_here(self):
        # The outcome's own code, built alone with the cases of SideStore's
        # and minimuxer's errors it reads, tells each sentence as this test
        # does, and reads each error's sentence.
        code = ""
        for table in ("deviceReasons", "deviceDetails"):
            code += re.search(r"    static let " + table + r"[^=]*= \[.*?\n    \]", self.outcome, re.S).group(0) + "\n"
        for header in ("static func deviceSentence(of error: Error) -> String?",
                       "static func reason(ofDeviceSentence sentence: String) -> (reason: String, detail: String?)"):
            code += "    " + header + "\n    {" + block(self.outcome, header, header) + "}\n"
        source = """
import Foundation

enum PairingProtocol: String { case rppairing, lockdown, unknown }

enum OperationError: Error {
    case noVPN(reason: String), invalidVPN(reason: String), noConnection(reason: String), noDevice(reason: String)
    case notReachable(reason: String), minimuxerNotStarted(reason: String), pairingNotComplete(reason: String)
    case invalidPairingFile(reason: String), invalidParameters(String), unknownUDID(reason: String)
}

enum MinimuxerError: Error {
    case noVPN(String), invalidVPN(String), noConnection(String), noDevice(String), notReachable(String)
    case notStarted(String), pairingNotLoaded(String), invalidPairing(protocol: PairingProtocol, reason: String)
    case fetchUDID(String)
}

final class CartoucheOutcome {
""" + code + """
}

let errors: [(Error, String?)] = [
    (OperationError.noVPN(reason: "a"), "a"), (OperationError.invalidVPN(reason: "b"), "b"),
    (OperationError.noConnection(reason: "c"), "c"), (OperationError.noDevice(reason: "d"), "d"),
    (OperationError.notReachable(reason: "e"), "e"), (OperationError.minimuxerNotStarted(reason: "f"), "f"),
    (OperationError.pairingNotComplete(reason: "g"), "g"), (OperationError.invalidPairingFile(reason: "h"), "h"),
    (OperationError.invalidParameters("i"), nil), (OperationError.unknownUDID(reason: "j"), nil),
    (MinimuxerError.noVPN("k"), "k"), (MinimuxerError.invalidVPN("l"), "l"), (MinimuxerError.noConnection("m"), "m"),
    (MinimuxerError.noDevice("n"), "n"), (MinimuxerError.notReachable("o"), "o"), (MinimuxerError.notStarted("p"), "p"),
    (MinimuxerError.pairingNotLoaded("q"), "q"), (MinimuxerError.invalidPairing(protocol: .lockdown, reason: "r"), "r"),
    (MinimuxerError.fetchUDID("s"), nil), (CocoaError(.fileNoSuchFile), nil),
]
for (error, sentence) in errors where CartoucheOutcome.deviceSentence(of: error) != sentence {
    print("FAILED: the sentence of \\(error)")
    exit(1)
}

let sentences = try JSONDecoder().decode([String].self, from: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1])))
let told = sentences.map { sentence -> [String] in
    let (reason, detail) = CartoucheOutcome.reason(ofDeviceSentence: sentence)
    return [reason, detail ?? ""]
}
print(String(data: try JSONEncoder().encode(told), encoding: .utf8)!)
"""
        reasons = listed(self.outcome, "deviceReasons")
        details = listed(self.outcome, "deviceDetails")
        sentences = [sentence for _, sentence in device_sentences(minimuxer_sources())] + list(DEVICE_EXAMPLES)
        with tempfile.TemporaryDirectory() as temporary:
            folder = Path(temporary)
            (folder / "main.swift").write_text(source, encoding="utf-8")
            (folder / "sentences.json").write_text(json.dumps(sentences), encoding="utf-8")
            built = subprocess.run(["swiftc", str(folder / "main.swift"), "-o", str(folder / "checks"),
                                    "-module-cache-path", str(folder / "cache")], capture_output=True, text=True)
            self.assertEqual(built.returncode, 0, built.stderr)
            run = subprocess.run([str(folder / "checks"), str(folder / "sentences.json")],
                                 capture_output=True, text=True, timeout=60)
            self.assertEqual(run.returncode, 0, run.stdout + run.stderr)
        told = json.loads(run.stdout)
        self.assertEqual(len(told), len(sentences))
        for sentence, (reason, detail) in zip(sentences, told):
            self.assertEqual((reason, detail or None), device_reason(reasons, details, sentence), sentence)

    def test_the_outcome_reads_the_error_behind_a_title(self):
        save = block(self.outcome, "func save(", "CartoucheOutcome.save")
        # The error SideStore wrapped in a title, as Swift threw it.
        self.assertIn("let error = Self.unwrapped(thrown)", save)
        unwrapped = block(self.outcome, "static func unwrapped(", "CartoucheOutcome.unwrapped")
        self.assertIn("current as? ALTWrappedError", unwrapped)
        kind = block(self.outcome, "static func kind(of error: Error)", "CartoucheOutcome.kind(of:)")
        families = set(re.findall(r"case is (\w+): family", kind)) | {"CartoucheSignInError"}
        retyped = set(re.findall(r"case let typed as (\w+): return typed", unwrapped))
        self.assertEqual(families - {"CancellationError"}, retyped)
        # Only then are its case, Apple's code and its sentence read.
        after = save[save.index("let error = Self.unwrapped(thrown)"):]
        for reading in ("Self.kind(of: error)", "Self.appleCode(of: error)", "Self.httpStatus(of: error)",
                        "case OperationError.invalidParameters(let sentence) = error"):
            self.assertIn(reading, after, reading)


if __name__ == "__main__":
    unittest.main()
