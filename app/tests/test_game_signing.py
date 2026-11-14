"""Checks the pieces of a game's signing, and of why a game did not sign or
did not start, that meet across the launcher, LiveContainer's patches, its
pinned sources and the harness, so that a rename fails here, on Linux,
rather than on an iPhone (launcher/Sources/CartoucheGameSigning.swift,
docs/decisions.md, 89):

- LiveContainer hands zsign the files Cartouche lists, through the
  Objective-C class the launcher declares, never zsign's own list, which
  took every 64-bit Mach-O, a GPU's too (app/patches/livecontainer/0013);
  the harness signs the same files;
- zsign and LiveContainer still say what Cartouche reads in their words:
  the lines zsign writes for each file it could not sign or read, the
  certificate it could not open, LiveContainer's keys and its sentences,
  and LiveProcess's error as it ends a game's process;
- AppSceneViewController keeps that error before it says the game's
  process has ended (app/patches/livecontainer/0014), the game host reads
  it there, and the harness's stand-in keeps it the same way;
- every cause an error of the app gives has its name on the dashboard.

Needs the LiveContainer submodule.
Run from the repository root: python3 -m unittest discover -s app/tests -v
"""

import json
import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SOURCES = ROOT / "launcher" / "Sources"
SIGNING = SOURCES / "CartoucheGameSigning.swift"
HOST = SOURCES / "CartoucheGameHost.swift"
FAILURE = SOURCES / "CartoucheFailure.swift"
HARNESS = ROOT / "launcher" / "Harness" / "Sources"
PATCHES = ROOT / "app" / "patches" / "livecontainer"
LIVECONTAINER = ROOT / "app" / "LiveContainer"
DASHBOARD = ROOT / "telemetry" / "dashboard" / "index.html"


def patch_named(suffix: str) -> str:
    found = sorted(PATCHES.glob(f"*-{suffix}.patch"))
    if len(found) != 1:
        raise AssertionError(f"expected one patch named *-{suffix}.patch in {PATCHES.relative_to(ROOT)}, found {len(found)}")
    return found[0].read_text(encoding="utf-8")


def changed_lines(patch: str, path: str, sign: str) -> list[str]:
    """The lines PATCH adds ("+") or removes ("-") in the file at PATH."""
    for hunk in re.split(r"^diff --git ", patch, flags=re.M):
        if hunk.startswith(f"a/{path} b/{path}"):
            return [line[1:] for line in hunk.splitlines()
                    if line.startswith(sign) and not line.startswith(sign * 3)]
    return []


def hunk_lines(patch: str, path: str) -> list[str]:
    """The lines of PATCH's hunks for the file at PATH, as the file has them
    once patched: its context and what it adds."""
    for hunk in re.split(r"^diff --git ", patch, flags=re.M):
        if hunk.startswith(f"a/{path} b/{path}"):
            body = hunk.split("\n@@", 1)[1] if "\n@@" in hunk else ""
            return [line[1:] for line in body.splitlines()[1:] if line[:1] in (" ", "+")]
    return []


class GameSigningTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        if not (LIVECONTAINER / "LiveContainerSwiftUI").is_dir():
            raise unittest.SkipTest("the LiveContainer submodule is not checked out")
        cls.signing = SIGNING.read_text(encoding="utf-8")
        cls.host = HOST.read_text(encoding="utf-8")
        cls.sign_patch = patch_named("sign-only-the-files-ios-loads-code-from")
        cls.exit_patch = patch_named("say-why-an-apps-process-ended-on-an-error-as-it-ends")

    # MARK: The files zsign signs

    def test_livecontainer_hands_zsign_the_files_cartouche_lists(self):
        added = "\n".join(changed_lines(self.sign_patch, "LiveContainerSwiftUI/Utilities/LCUtils.m", "+"))
        removed = "\n".join(changed_lines(self.sign_patch, "LiveContainerSwiftUI/Utilities/LCUtils.m", "-"))
        self.assertIn("signWithAppPath:", removed, "zsign's own list goes")
        self.assertNotIn("signWithAppPath:", added)
        self.assertIn("NSArray<NSString *> *files = [CartoucheSignedFiles pathsInBundle:path.path];", added)
        self.assertIn('[NSClassFromString(@"ZSigner") signMachOPathArr:files ', added)
        # The class and its call, under the Objective-C names the patch
        # calls them by, public, as LiveContainerSwiftUI is a framework,
        # whose Swift header has only what is public.
        self.assertRegex(self.signing, r"@objc\(CartoucheSignedFiles\)\s+public final class CartoucheSignedFiles: NSObject \{")
        self.assertIn("@objc public static func paths(inBundle bundle: String) -> [String] {", self.signing)
        self.assertIn("CartoucheGameSigning.filesToSign(inBundle:", self.signing)
        # LCUtils.m sees the launcher's Swift through that header.
        lcutils = (LIVECONTAINER / "LiveContainerSwiftUI" / "Utilities" / "LCUtils.m").read_text(encoding="utf-8")
        self.assertIn('#import "LiveContainerSwiftUI-Swift.h"', lcutils)
        self.assertIn("[NSClassFromString(@\"ZSigner\") signWithAppPath:[path path] ", lcutils,
                      "the line the patch replaces is still LiveContainer's")

    def test_zsign_still_signs_a_list_as_cartouche_calls_it(self):
        zsigner = (LIVECONTAINER / "ZSign" / "zsigner.h").read_text(encoding="utf-8")
        self.assertIn("+ (NSProgress*)signMachOPathArr:(NSArray<NSString*>*)machoPathArr bundleId:(NSString *)bundleId "
                      "cert:(NSData *)key", re.sub(r"\s+", " ", zsigner))

    def test_the_harness_signs_the_files_cartouche_lists(self):
        harness = (HARNESS / "HarnessLiveContainer.swift").read_text(encoding="utf-8")
        sign = re.search(r"static func sign\(bundle: String, completion:.*?\n    \}\n", harness, re.S)
        self.assertIsNotNone(sign, "HarnessLC.sign(bundle:completion:) is gone")
        self.assertIn("let files = CartoucheSignedFiles.paths(inBundle: bundle)", sign.group(0))
        self.assertIn("HarnessMachO.zsignFailure", sign.group(0), "zsign fails on a file it cannot sign, as the real one")

    # MARK: The words Cartouche reads

    def test_zsign_still_says_what_cartouche_reads(self):
        zsign = (LIVECONTAINER / "ZSign" / "zsign.mm").read_text(encoding="utf-8")
        self.assertIn('[NSString stringWithFormat:@"Failed to Sign %@", machoPath]', zsign)
        self.assertIn('[NSString stringWithFormat:@"Invalid mach-o file! %@", machoPath]', zsign)
        self.assertIn('[errorList componentsJoinedByString:@"\\n"]', zsign, "a line for each file")
        self.assertIn('@"Failed to initialize zSignAsset. Maybe wrong password?"', zsign)
        for read in ['"Failed to Sign "', '"Invalid mach-o file! "', '"zSignAsset"']:
            self.assertIn(read, self.signing)

    def test_livecontainer_still_says_what_cartouche_reads(self):
        app_info = (LIVECONTAINER / "LiveContainerSwiftUI" / "Models" / "LCAppInfo.m").read_text(encoding="utf-8")
        macho = (LIVECONTAINER / "LiveContainer" / "LCMachOUtils.m").read_text(encoding="utf-8")
        lcutils = (LIVECONTAINER / "LiveContainerSwiftUI" / "Utilities" / "LCUtils.m").read_text(encoding="utf-8")
        said = {
            "The app you tried to install is encrypted": app_info,
            '@"Info.plist not found"': app_info,
            '@"Failed to map %s: %s"': macho,
            '@"Failed to open %s: %s"': macho,
            '@"Not a Mach-O file"': macho,
            '@"Failed to load ZSign: ': lcutils,
        }
        for words, source in said.items():
            self.assertIn(words, source)
        for read in ['"The app you tried to install is encrypted"', '"Info.plist not found"', '"Failed to map "',
                     '"Failed to open "', '"Not a Mach-O file"', '"Failed to load ZSign"']:
            self.assertIn(read, self.signing)

    def test_livecontainers_keys_are_still_its_own(self):
        keys = re.findall(r'\("(lc\.signer\.\w+)", \.\w+\)', self.signing)
        self.assertEqual(sorted(keys), ["lc.signer.crashDuringSignErr", "lc.signer.latestCertificateInvalidErr",
                                        "lc.signer.noCertificateFoundErr"])
        strings = json.loads((LIVECONTAINER / "Resources" / "Localizable.xcstrings").read_text(encoding="utf-8"))["strings"]
        for key in keys:
            self.assertIn(key, strings, f"LiveContainer no longer has {key}")
        # The kinds they had in the measurements before stay theirs.
        for reason, kind in [("noCertificate", "noCertificateFound"), ("certificateRefused", "latestCertificateInvalid"),
                             ("interrupted", "crashDuringSign")]:
            self.assertIn(f'case {reason} = "{kind}"', self.signing)

    def test_liveprocess_still_says_why_it_ended_a_games_process(self):
        bootstrap = (LIVECONTAINER / "LiveContainer" / "LCBootstrap.m").read_text(encoding="utf-8")
        self.assertIn('@"App returned from its main function with code %d."', bootstrap)
        self.assertIn('@"%@\\nCall stack: %@"', bootstrap)
        self.assertGreaterEqual(bootstrap.count('cancelRequestWithError:[NSError errorWithDomain:@"LiveProcess" code:1 '), 2,
                                "an app LiveProcess could not run, and one that threw")
        self.assertIn('"App returned from its main function with code "', self.signing)
        self.assertIn('"\\nCall stack:"', self.signing)

    # MARK: Why the game's process ended

    def test_the_scene_keeps_the_error_before_it_says_the_process_ended(self):
        header = "\n".join(changed_lines(self.exit_patch, "MultitaskSupport/AppSceneViewController.h", "+"))
        self.assertIn("@property(nonatomic) NSError *exitError;", header)
        block = hunk_lines(self.exit_patch, "MultitaskSupport/AppSceneViewController.m")
        lines = [line.strip() for line in block]
        start = lines.index("[_extension setRequestCancellationBlock:^(NSUUID *uuid, NSError *error) {")
        kept = lines.index("weakSelf.exitError = error;")
        cleaned = lines.index("[weakSelf appTerminationCleanUp];", start)
        passed = lines.index("[weakSelf.delegate appSceneVC:weakSelf didInitializeWithError:error];")
        self.assertLess(start, kept)
        self.assertLess(kept, cleaned, "kept before appTerminationCleanUp tells the delegate the app exited")
        self.assertLess(cleaned, passed, "LiveContainer's own order otherwise")
        # The block the patch changes is still LiveContainer's.
        scene = (LIVECONTAINER / "MultitaskSupport" / "AppSceneViewController.m").read_text(encoding="utf-8")
        self.assertRegex(scene, r"setRequestCancellationBlock:\^\(NSUUID \*uuid, NSError \*error\) \{\s*"
                                r"\[weakSelf appTerminationCleanUp\];\s*"
                                r"\[weakSelf\.delegate appSceneVC:weakSelf didInitializeWithError:error\];")

    def test_the_game_host_reads_the_error_as_the_game_ends(self):
        exit_ = re.search(r"fileprivate func sceneDidExit\(_ vc: AppSceneViewController\) \{.*?\n    \}\n", self.host, re.S)
        self.assertIsNotNone(exit_, "CartoucheGameHost.sceneDidExit is gone")
        body = exit_.group(0)
        self.assertIn("vc.exitError", body)
        self.assertIn('domain == "LiveProcess"', body, "LiveProcess's own errors only")
        self.assertIn("error: error)", body, "passed on to gameDidEnd")
        harness = (HARNESS / "HarnessScenes.swift").read_text(encoding="utf-8")
        self.assertIn("var exitError: Error!", harness)
        ended = re.search(r"private func processEnded\(on error: NSError\) \{.*?\n    \}\n", harness, re.S)
        self.assertIsNotNone(ended, "the harness's LiveProcess no longer ends a game on an error")
        steps = ended.group(0)
        self.assertLess(steps.index("exitError = error"), steps.index("appTerminationCleanUp()"))
        self.assertLess(steps.index("appTerminationCleanUp()"), steps.index("didInitializeWithError: error"))
        self.assertIn('NSError(domain: "LiveProcess", code: 1,', harness)

    # MARK: The measurements

    def test_every_cause_has_its_name_on_the_dashboard(self):
        failure = FAILURE.read_text(encoding="utf-8")
        body = re.search(r"enum Cause: String[^{]*\{(.*?)\n    \}", failure, re.S)
        self.assertIsNotNone(body, "CartoucheFailure.Cause is gone")
        causes = re.findall(r"^\s*case (\w+)", body.group(1), re.M)
        self.assertIn("notSigned", causes)
        self.assertIn("gameEndedOnError", causes)
        labels = re.search(r"const FAILURE_CAUSES = \{(.*?)\};", DASHBOARD.read_text(encoding="utf-8"), re.S)
        self.assertIsNotNone(labels, "the dashboard no longer names the causes")
        named = set(re.findall(r"(\w+):\s*\"", labels.group(1)))
        self.assertEqual([cause for cause in causes if cause not in named], [],
                         "a cause without its name on the dashboard shows as its key")


if __name__ == "__main__":
    unittest.main()
