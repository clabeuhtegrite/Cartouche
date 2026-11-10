"""Checks telemetry/deploy.sh against a stand-in for Cloudflare's API.

- The first deploy creates the D1 database in the EU jurisdiction, applies
  schema.sql to it, uploads worker.js with the database bound as DB and no
  logs, creates the account's workers.dev subdomain when it has none, opens
  the Worker's address there and sets its daily run;
- a deploy again uses the same database and subdomain;
- a database of that name in another jurisdiction stops the deploy;
- without the secrets, the deploy does nothing;
- with the problems' token, the Worker has it and the private repository
  to file problems in, never one GitHub says is public, and the token is
  never printed.

The stand-in (standin.py) runs the SQL it is sent on SQLite, as D1 would.

Run from the repository root: python3 -m unittest discover -s telemetry/test -v
"""

import shutil
import subprocess
import unittest
from pathlib import Path

from standin import ACCOUNT, GITHUB_TOKEN, PREFIX, TOKEN, Cloudflare, environment, serve

HERE = Path(__file__).resolve().parent
DEPLOY = HERE.parent / "deploy.sh"
WORKER = HERE.parent / "worker.js"


@unittest.skipUnless(shutil.which("curl") and shutil.which("jq"), "the deploy needs curl and jq")
class DeployTest(unittest.TestCase):
    def setUp(self):
        self.cloudflare = Cloudflare()
        self.server = serve(self.cloudflare)
        self.addCleanup(self.cloudflare.sql.close)
        self.addCleanup(self.server.server_close)
        self.addCleanup(self.server.shutdown)

    def deploy(self, **secrets):
        return subprocess.run(["bash", str(DEPLOY)], env=environment(self.server, TELEMETRY_CHECK_TRIES="0", **secrets),
                              capture_output=True, text=True, timeout=60)

    def deploy_with_secrets(self):
        return self.deploy(CLOUDFLARE_API_TOKEN=TOKEN, CLOUDFLARE_ACCOUNT_ID=ACCOUNT)

    def test_the_first_deploy_sets_everything_up(self):
        result = self.deploy_with_secrets()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(len(self.cloudflare.databases), 1)
        database = self.cloudflare.databases[0]
        self.assertEqual((database["name"], database["jurisdiction"]), ("cartouche-telemetry", "eu"))
        tables = {row[0] for row in self.cloudflare.sql.execute("SELECT name FROM sqlite_master WHERE type = 'table'")}
        self.assertEqual(tables, {"reports", "daily", "problems"})
        self.assertNotIn("--", self.cloudflare.last_sql)
        script = self.cloudflare.scripts["cartouche-telemetry"]
        self.assertEqual(script["metadata"]["main_module"], "worker.js")
        self.assertEqual(script["metadata"]["bindings"], [{"type": "d1", "name": "DB", "id": database["uuid"]}])
        self.assertEqual(script["metadata"]["observability"], {"enabled": False})
        self.assertRegex(script["metadata"]["compatibility_date"], r"^\d{4}-\d{2}-\d{2}$")
        self.assertEqual(script["module type"], "application/javascript+module")
        self.assertEqual(script["module"], WORKER.read_bytes())
        self.assertRegex(self.cloudflare.subdomain, r"^cartouche-[0-9a-f]{8}$")
        self.assertEqual(self.cloudflare.enabled, {"enabled": True, "previews_enabled": False})
        self.assertEqual(self.cloudflare.schedules, [{"cron": "17 3 * * *"}])
        self.assertIn(f"https://cartouche-telemetry.{self.cloudflare.subdomain}.workers.dev", result.stdout + result.stderr)
        self.assertNotIn(TOKEN, result.stdout + result.stderr)

    def test_a_deploy_again_keeps_the_database_and_the_subdomain(self):
        self.assertEqual(self.deploy_with_secrets().returncode, 0)
        subdomain = self.cloudflare.subdomain
        self.cloudflare.sql.execute("INSERT INTO reports (id, kind, install, day, body) VALUES ('a', 'event', 'i', 'd', '{}')")
        result = self.deploy_with_secrets()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(len(self.cloudflare.databases), 1)
        self.assertEqual(self.cloudflare.subdomain, subdomain)
        self.assertEqual(self.cloudflare.calls.count(("PUT", f"{PREFIX}/workers/subdomain")), 1)
        self.assertEqual(self.cloudflare.sql.execute("SELECT count(*) FROM reports").fetchone()[0], 1)

    def test_a_database_outside_the_eu_stops_the_deploy(self):
        self.cloudflare.databases.append({"uuid": "d1-us", "name": "cartouche-telemetry", "jurisdiction": "us"})
        result = self.deploy_with_secrets()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("not eu", result.stderr)
        self.assertEqual(self.cloudflare.scripts, {})

    def test_a_refusal_stops_the_deploy_with_cloudflares_words(self):
        result = self.deploy(CLOUDFLARE_API_TOKEN="another-token", CLOUDFLARE_ACCOUNT_ID=ACCOUNT)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("10000: Authentication error", result.stderr)
        self.assertEqual(self.cloudflare.databases, [])

    def deploy_with_problems(self, repository="clabeuhtegrite/cartouche-reports", token=GITHUB_TOKEN):
        github = f"http://127.0.0.1:{self.server.server_port}/github"
        return self.deploy(CLOUDFLARE_API_TOKEN=TOKEN, CLOUDFLARE_ACCOUNT_ID=ACCOUNT, GITHUB_API_URL=github,
                           CARTOUCHE_REPORTS_TOKEN=token, CARTOUCHE_REPORTS_REPOSITORY=repository)

    def bindings(self):
        return self.cloudflare.scripts["cartouche-telemetry"]["metadata"]["bindings"]

    def test_the_worker_files_problems_in_the_private_repository(self):
        self.cloudflare.repositories["clabeuhtegrite/cartouche-reports"] = True
        result = self.deploy_with_problems()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.bindings()[1:], [
            {"type": "plain_text", "name": "PROBLEMS_REPOSITORY", "text": "clabeuhtegrite/cartouche-reports"},
            {"type": "secret_text", "name": "PROBLEMS_TOKEN", "text": GITHUB_TOKEN},
        ])
        self.assertIn("go to clabeuhtegrite/cartouche-reports, a private repository", result.stdout)
        self.assertNotIn(GITHUB_TOKEN, result.stdout + result.stderr)

    def test_a_token_github_refuses_still_goes_to_the_worker(self):
        result = self.deploy_with_problems(token="github_pat_expired")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual([binding["name"] for binding in self.bindings()], ["DB", "PROBLEMS_REPOSITORY", "PROBLEMS_TOKEN"])
        self.assertIn("::warning::Problems: the token cannot read clabeuhtegrite/cartouche-reports", result.stdout)
        self.assertNotIn("github_pat_expired", result.stdout + result.stderr)

    def test_a_public_repository_gets_no_problem(self):
        self.cloudflare.repositories["clabeuhtegrite/Cartouche"] = False
        result = self.deploy_with_problems(repository="clabeuhtegrite/Cartouche")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual([binding["name"] for binding in self.bindings()], ["DB"])
        self.assertIn("::error::Problems: clabeuhtegrite/Cartouche is public", result.stdout)

    def test_without_the_secrets_nothing_happens(self):
        result = self.deploy()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("not deployed", result.stdout)
        self.assertEqual(self.cloudflare.calls, [])


if __name__ == "__main__":
    unittest.main()
