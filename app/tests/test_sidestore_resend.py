"""Checks that the built-in SideStore sends a sign-in request to Apple again
when Apple answers 429, Too Many Requests, as the Cartouche Installer does
(app/patches/sidestore/0020):

- the sign-in's requests to Apple's sign-in server, GrandSlam, go through
  GrandSlamResend, and those of the verification code and of the developer
  services do not, as in isideload, which the Installer signs in with;
- a request goes again as many times as in the Installer's isideload, which
  the Installer leaves at its default (installer/src-tauri), a short pause
  apart, and GrandSlamResend names that isideload, so that a new one has
  this checked again;
- each request sent again counts in the outcome Cartouche reads, from every
  sign-in SideStore makes;
- GrandSlamResend itself, built and run with Swift where there is one: a
  request goes again while Apple answers 429, ten times at most, and only
  then; the last answer comes back, each request sent again is told, and
  a sign-in cancelled while it waits stops.

SideStore's sources are read as app/scripts/prepare.sh leaves them, every
patch applied. Needs the SideStore submodule, with SideSign.

Run from the repository root: python3 -m unittest discover -s app/tests -v
"""

import re
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

from test_sidestore_outcome import PATCHES, block, hunks, own_sources, patched

ROOT = Path(__file__).resolve().parents[2]
SIDESIGN = "Dependencies/SideSign/Sources/"
RESEND = SIDESIGN + "DeveloperPortal/GrandSlamResend.swift"
AUTHENTICATION = SIDESIGN + "DeveloperPortal/Authentication.swift"
PORTAL = SIDESIGN + "DeveloperPortal/DeveloperPortalAPI.swift"
SIGN_IN = "SideStore/Core/Operations/StandaloneOperations/SignInOperation.swift"
OUTCOME = "SideStore/Intents/CartoucheOutcome.swift"
INSTALLER = ROOT / "installer" / "src-tauri"

# How many times isideload sends a request again after GrandSlam's 429 when
# its builder is left at its default (AppleAccountBuilder, err_429_retries),
# by the version the Installer builds with. A new isideload is read again
# (src/auth/builder.rs and grandslam.rs), then added here.
ISIDELOAD_RESENDS = {"0.5.2": 10}


def installer_isideload() -> str:
    cargo = re.search(r'^isideload\s*=\s*\{[^}]*version\s*=\s*"([^"]+)"',
                      (INSTALLER / "Cargo.toml").read_text(encoding="utf-8"), re.M)
    if not cargo:
        raise AssertionError("installer/src-tauri/Cargo.toml no longer names isideload")
    return cargo.group(1)


class SideStoreResendTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.resend = patched(RESEND)
        cls.authentication = patched(AUTHENTICATION)
        cls.portal = patched(PORTAL)

    def test_the_sign_ins_requests_go_again_and_no_others(self):
        self.assertIn("public enum GrandSlamResend", self.resend, "patch 0020 adds GrandSlamResend to SideSign")
        send = block(self.authentication, "func sendAuthenticationRequest(", "sendAuthenticationRequest")
        resend, request = send.find("GrandSlamResend.sending("), send.find("session.data(for: request)")
        self.assertGreaterEqual(resend, 0, "the sign-in's requests to GrandSlam do not go again")
        self.assertEqual(send.count("session.data(for:"), 1)
        self.assertLess(resend, request, "the request is sent outside GrandSlamResend")
        # Its two requests, then the app tokens, as in isideload.
        self.assertEqual(self.authentication.count("try await sendAuthenticationRequest("), 3)
        # Neither the verification code's requests nor the developer
        # services', which isideload sends once.
        others = {
            AUTHENTICATION: (self.authentication, ["func sendTrustedDevice2FACodeRequest(", "func sendPhone2FACodeRequest(",
                                                   "func validateTrustedDevice2FACode(", "func validatePhone2FACode("]),
            PORTAL: (self.portal, ["func sendRequest<", "func sendServicesRequest<"]),
        }
        for name, (text, functions) in others.items():
            for function in functions:
                self.assertNotIn("GrandSlamResend", block(text, function, function), function)
        # Nowhere else in SideSign, nor in the files the patches add to it.
        sidestore = ROOT / "app" / "SideStore"
        sources = {path.relative_to(sidestore).as_posix() for path in (sidestore / SIDESIGN).rglob("*.swift")}
        sources |= {name for patch in sorted(PATCHES.glob("*.patch")) for name in hunks(patch)
                    if name.startswith(SIDESIGN) and name.endswith(".swift")}
        users = sorted(name for name in sources if name != RESEND and "GrandSlamResend.sending(" in patched(name))
        self.assertEqual(users, [AUTHENTICATION])

    def test_as_many_times_as_the_installer_a_short_pause_apart(self):
        version = installer_isideload()
        self.assertIn(version, ISIDELOAD_RESENDS,
                      f"the Installer builds with isideload {version}: read again how many times it sends a request "
                      "GrandSlam answers 429 again (err_429_retries), then add it to ISIDELOAD_RESENDS")
        limit = re.search(r"public static let limit = (\d+)\b", self.resend)
        self.assertIsNotNone(limit, "GrandSlamResend.limit not found")
        self.assertEqual(int(limit.group(1)), ISIDELOAD_RESENDS[version])
        self.assertEqual(set(re.findall(r"isideload (\d+\.\d+\.\d+)", self.resend)), {version})
        # The Installer leaves isideload's default.
        for path in sorted((INSTALLER / "src").rglob("*.rs")):
            self.assertNotIn("err_429_retries", path.read_text(encoding="utf-8"), path.relative_to(ROOT))
        pause = re.search(r"public static let pause: UInt64 = ([\d_]+)\b", self.resend)
        self.assertIsNotNone(pause, "GrandSlamResend.pause not found")
        self.assertTrue(0 < int(pause.group(1).replace("_", "")) <= 2_000_000_000, "a pause of two seconds at most")

    def test_each_request_sent_again_counts_in_the_outcome(self):
        operation = patched(SIGN_IN)
        told = operation.find("GrandSlamResend.$resent.withValue({ CartoucheOutcome.resent() })")
        self.assertGreaterEqual(told, 0, "SignInOperation does not tell CartoucheOutcome of the requests sent again")
        self.assertIn("try await self.signIn(appleID: appleID, password: password)", operation[told:told + 200])
        # Every sign-in of SideStore's goes through SignInOperation.signIn.
        callers = sorted(name for name, text in own_sources().items()
                         if re.search(r"AuthManager\.shared\.signIn\(\s*appleID:", text))
        self.assertEqual(callers, [SIGN_IN])

        outcome = patched(OUTCOME)
        self.assertIn("static func resent()", outcome)
        start = block(outcome, "init(action: Action)", "CartoucheOutcome.init")
        self.assertIn("Self.resends = 0", start)
        save = block(outcome, "func save(", "CartoucheOutcome.save")
        self.assertIn('outcome["resent"] = resends', save)

    @unittest.skipUnless(shutil.which("swiftc"), "Needs Swift")
    def test_grandslam_resend_sends_again_as_the_installer_does(self):
        checks = r'''
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

final class Count: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func add() { lock.lock(); value += 1; lock.unlock() }
    var total: Int { lock.lock(); defer { lock.unlock() }; return value }
}

struct Failed: Error {}

func answer(_ status: Int) -> (Data, URLResponse) {
    let url = URL(string: "https://gsa.apple.com/grandslam/GsService2")!
    return (Data(), HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: [:])!)
}

/// Apple answers with STATUSES in turn, the last one again once they run
/// out; 0 is a request that fails before any answer.
func run(_ statuses: [Int], times: Int = GrandSlamResend.limit) async -> (status: Int, sent: Int, told: [Int], resent: Int) {
    var sent = 0
    var told: [Int] = []
    let resent = Count()
    do {
        let last = try await GrandSlamResend.$resent.withValue({ resent.add() }) {
            try await GrandSlamResend.sending(times: times, pause: 0, noting: { told.append($0) }) {
                sent += 1
                let status = statuses[min(sent, statuses.count) - 1]
                if status == 0 { throw Failed() }
                return answer(status)
            }
        }
        return ((last.1 as! HTTPURLResponse).statusCode, sent, told, resent.total)
    } catch {
        return (0, sent, told, resent.total)
    }
}

func expect(_ found: (status: Int, sent: Int, told: [Int], resent: Int), _ status: Int, sent: Int, _ what: String) {
    let told = Array(stride(from: 1, to: sent, by: 1))
    guard found.status == status, found.sent == sent, found.told == told, found.resent == told.count else {
        print("FAILED: \(what): \(found), expected status \(status) after \(sent) sent")
        exit(1)
    }
}

@main
struct Checks {
    static func main() async throws {
        guard GrandSlamResend.limit == 10, GrandSlamResend.pause == 1_000_000_000 else {
            print("FAILED: ten times at most, a second apart"); exit(1)
        }
        expect(await run([200]), 200, sent: 1, "Apple's answer at once")
        expect(await run([429, 429, 429, 200]), 200, sent: 4, "Apple's answer at the third request sent again")
        expect(await run([429]), 429, sent: 11, "Apple's 429 every time: ten times again, then its 429")
        expect(await run([429] + Array(repeating: 429, count: 9) + [200]), 200, sent: 11, "Apple's answer at the tenth")
        expect(await run([503]), 503, sent: 1, "another error of Apple's goes once")
        expect(await run([400]), 400, sent: 1, "an answer of Apple's with an error goes once")
        expect(await run([429, 503]), 503, sent: 2, "another error after a 429 ends it")
        expect(await run([429], times: 0), 429, sent: 1, "never again when told so")
        expect(await run([0]), 0, sent: 1, "a request that fails goes once, its error thrown")
        expect(await run([429, 0]), 0, sent: 2, "a request sent again that fails throws its error")

        // Nobody counting.
        let alone = try await GrandSlamResend.sending(pause: 0) { answer(200) }
        guard (alone.1 as! HTTPURLResponse).statusCode == 200 else { print("FAILED: alone"); exit(1) }

        // A second apart.
        let start = Date()
        var sent = 0
        let late = try await GrandSlamResend.sending {
            sent += 1
            return answer(sent == 1 ? 429 : 200)
        }
        let waited = Date().timeIntervalSince(start)
        guard (late.1 as! HTTPURLResponse).statusCode == 200, sent == 2, waited >= 0.9, waited < 5 else {
            print("FAILED: a second apart, waited \(waited)"); exit(1)
        }

        // Cancelled while it waits: it stops, without sending again.
        let count = Count()
        let signIn = Task {
            let last = try await GrandSlamResend.sending {
                count.add()
                return answer(429)
            }
            return (last.1 as! HTTPURLResponse).statusCode
        }
        try await Task.sleep(nanoseconds: 200_000_000)
        signIn.cancel()
        let cancelled: Bool
        do { _ = try await signIn.value; cancelled = false } catch is CancellationError { cancelled = true }
        guard cancelled, count.total == 1 else {
            print("FAILED: cancelled while waiting, sent \(count.total)"); exit(1)
        }
        print("GrandSlamResend checks passed")
    }
}
'''
        with tempfile.TemporaryDirectory() as temporary:
            folder = Path(temporary)
            (folder / "GrandSlamResend.swift").write_text(self.resend, encoding="utf-8")
            (folder / "Checks.swift").write_text(checks, encoding="utf-8")
            # Built alone first with every concurrency check, as SideSign's
            # Swift 6 would.
            strict = subprocess.run([
                "swiftc", "-typecheck", "-strict-concurrency=complete", "-warnings-as-errors",
                "-module-cache-path", str(folder / "cache"), str(folder / "GrandSlamResend.swift"),
            ], capture_output=True, text=True)
            self.assertEqual(strict.returncode, 0, strict.stderr)
            built = subprocess.run([
                "swiftc", "-parse-as-library", "-module-name", "ResendChecks",
                str(folder / "GrandSlamResend.swift"), str(folder / "Checks.swift"),
                "-o", str(folder / "checks"), "-module-cache-path", str(folder / "cache"),
            ], capture_output=True, text=True)
            self.assertEqual(built.returncode, 0, built.stderr)
            run = subprocess.run([str(folder / "checks")], capture_output=True, text=True, timeout=60)
            self.assertEqual(run.returncode, 0, run.stdout + run.stderr)
            self.assertIn("GrandSlamResend checks passed", run.stdout)


if __name__ == "__main__":
    unittest.main()
