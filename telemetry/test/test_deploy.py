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
  never printed;
- the dashboard goes with them: its Worker and its page as they are, with
  the catalog's names, covers and chips in the page's place for them, and
  nothing in a name that could close it; the same database and problems'
  repository, no logs, its workers.dev address and no daily run; an Access
  application's team and audience when they are given; and the job's
  summary says where it is;
- the deploy reads what both addresses answer: the server its name, the
  dashboard its closed page or Access's sign-in; a server behind Access,
  which the iPhones could no longer send to, fails the deploy and says
  where to take it out.

The stand-in (standin.py) runs the SQL it is sent on SQLite, as D1 would.

Run from the repository root: python3 -m unittest discover -s telemetry/test -v
"""

import json
import re
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

from standin import ACCOUNT, GITHUB_TOKEN, PREFIX, TOKEN, Cloudflare, environment, serve

HERE = Path(__file__).resolve().parent
DEPLOY = HERE.parent / "deploy.sh"
WORKER = HERE.parent / "worker.js"
DASHBOARD_WORKER = HERE.parent / "dashboard" / "worker.js"
DASHBOARD_PAGE = HERE.parent / "dashboard" / "index.html"
CATALOG = HERE.parent.parent / "catalog"
PLACEHOLDER = '<script type="application/json" id="catalog">{}</script>'
CATALOG_ELEMENT = re.compile(r'<script type="application/json" id="catalog">(.*?)</script>', re.S)
AUD = "4714c1358e65fe4b408ad6d432a5f878f08194bdb4752441fd56faefa9b2b6f2"


@unittest.skipUnless(shutil.which("curl") and shutil.which("jq"), "the deploy needs curl and jq")
class DeployTest(unittest.TestCase):
    def setUp(self):
        self.cloudflare = Cloudflare()
        self.server = serve(self.cloudflare)
        self.addCleanup(self.cloudflare.sql.close)
        self.addCleanup(self.server.server_close)
        self.addCleanup(self.server.shutdown)

    def deploy(self, script=DEPLOY, **secrets):
        return subprocess.run(["bash", str(script)], env=environment(self.server, **{"TELEMETRY_CHECK_TRIES": "0", **secrets}),
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
        self.assertEqual(self.cloudflare.enabled, {name: {"enabled": True, "previews_enabled": False}
                                                   for name in ("cartouche-telemetry", "cartouche-dashboard")})
        self.assertEqual(self.cloudflare.schedules, {"cartouche-telemetry": [{"cron": "17 3 * * *"}]})
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
        self.assertEqual(self.cloudflare.scripts["cartouche-dashboard"]["metadata"]["bindings"], self.bindings())

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

    def dashboard(self):
        return self.cloudflare.scripts["cartouche-dashboard"]

    def test_the_dashboard_goes_with_its_page_and_the_catalog(self):
        result = self.deploy_with_secrets()
        self.assertEqual(result.returncode, 0, result.stderr)
        metadata = self.dashboard()["metadata"]
        self.assertEqual(metadata["main_module"], "worker.js")
        self.assertEqual(metadata["bindings"], [{"type": "d1", "name": "DB", "id": self.cloudflare.databases[0]["uuid"]}])
        self.assertEqual(metadata["observability"], {"enabled": False})
        self.assertEqual(metadata["compatibility_date"], self.cloudflare.scripts["cartouche-telemetry"]["metadata"]["compatibility_date"])
        modules = self.dashboard()["modules"]
        self.assertEqual(sorted(modules), ["index.html", "worker.js"])
        self.assertEqual(modules["worker.js"], ("application/javascript+module", DASHBOARD_WORKER.read_bytes()))
        kind, page = modules["index.html"]
        self.assertEqual(kind, "text/plain")
        page = page.decode()
        element = CATALOG_ELEMENT.search(page)
        self.assertEqual(page.replace(element.group(0), PLACEHOLDER), DASHBOARD_PAGE.read_text(encoding="utf-8"))
        catalog = json.loads(element.group(1))
        covers = {cover["titleId"]: cover["cover"] for cover in json.loads((CATALOG / "covers.json").read_text())["covers"]}
        for game in json.loads((CATALOG / "nxnative.json").read_text())["games"]:
            self.assertEqual(catalog["games"][game["titleId"]], [game["name"], covers.get(game["titleId"])])
            for variant in game.get("variants", []):
                self.assertEqual(catalog["aliases"][variant["titleId"]], game["titleId"])
        for device in json.loads((CATALOG / "devices.json").read_text())["devices"]:
            self.assertEqual(catalog["devices"][device["identifier"]], [device["chip"], device["memoryGB"]])
        self.assertIn(f"https://cartouche-dashboard.{self.cloudflare.subdomain}.workers.dev", result.stdout)
        self.assertIn("opens behind Cloudflare Access only", result.stdout)

    def test_a_name_in_the_catalog_cannot_close_the_catalogs_element(self):
        name = "</script><script>alert(1)</script> & <!-- co"
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            shutil.copytree(HERE.parent, root / "telemetry", ignore=shutil.ignore_patterns("__pycache__", "test"))
            (root / "catalog").mkdir()
            for file in ("covers.json", "devices.json"):
                shutil.copy(CATALOG / file, root / "catalog" / file)
            games = json.loads((CATALOG / "nxnative.json").read_text())
            games["games"][0]["name"] = name
            (root / "catalog" / "nxnative.json").write_text(json.dumps(games))
            result = self.deploy(root / "telemetry" / "deploy.sh", CLOUDFLARE_API_TOKEN=TOKEN, CLOUDFLARE_ACCOUNT_ID=ACCOUNT)
        self.assertEqual(result.returncode, 0, result.stderr)
        page = self.dashboard()["modules"]["index.html"][1].decode()
        self.assertEqual(page.count("</script>"), DASHBOARD_PAGE.read_text(encoding="utf-8").count("</script>"))
        self.assertNotIn("<!--", CATALOG_ELEMENT.search(page).group(1))
        self.assertEqual(json.loads(CATALOG_ELEMENT.search(page).group(1))["games"][games["games"][0]["titleId"]][0], name)

    def test_the_dashboard_reads_the_tokens_of_an_access_application_given_to_it(self):
        result = self.deploy(CLOUDFLARE_API_TOKEN=TOKEN, CLOUDFLARE_ACCOUNT_ID=ACCOUNT,
                             CLOUDFLARE_ACCESS_TEAM="cartouche", CLOUDFLARE_ACCESS_AUD=AUD)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.dashboard()["metadata"]["bindings"][1:], [
            {"type": "plain_text", "name": "ACCESS_TEAM_DOMAIN", "text": "cartouche"},
            {"type": "plain_text", "name": "ACCESS_AUD", "text": AUD},
        ])
        self.assertEqual([binding["name"] for binding in self.bindings()], ["DB"])

    def test_the_jobs_summary_says_where_the_dashboard_is(self):
        with tempfile.TemporaryDirectory() as folder:
            summary = Path(folder) / "summary.md"
            result = self.deploy(CLOUDFLARE_API_TOKEN=TOKEN, CLOUDFLARE_ACCOUNT_ID=ACCOUNT, GITHUB_STEP_SUMMARY=str(summary))
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn(f"Dashboard: the dashboard is at https://cartouche-dashboard.{self.cloudflare.subdomain}.workers.dev",
                          summary.read_text())

    def checked(self):
        """A deploy that asks each Worker's address once, with its summary."""
        with tempfile.TemporaryDirectory() as folder:
            summary = Path(folder) / "summary.md"
            result = self.deploy(CLOUDFLARE_API_TOKEN=TOKEN, CLOUDFLARE_ACCOUNT_ID=ACCOUNT, TELEMETRY_CHECK_TRIES="1",
                                 GITHUB_STEP_SUMMARY=str(summary))
            return result, summary.read_text() if summary.exists() else ""

    def test_the_deploy_reads_what_both_addresses_answer(self):
        result, summary = self.checked()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn(f"The telemetry server answers at https://cartouche-telemetry.{self.cloudflare.subdomain}.workers.dev",
                      result.stdout)
        self.assertIn("closed until Cloudflare Access protects it", result.stdout)
        self.assertNotIn("::error::", result.stdout)
        self.cloudflare.behind_access("cartouche-dashboard")
        result, summary = self.checked()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("Dashboard: the dashboard is at", result.stdout)
        self.assertIn("behind Cloudflare Access.", summary)

    def test_a_server_behind_access_fails_the_deploy(self):
        self.cloudflare.behind_access("cartouche-telemetry")
        self.cloudflare.behind_access("cartouche-dashboard")
        result, summary = self.checked()
        self.assertEqual(result.returncode, 1)
        self.assertIn("::error::Cloudflare Access protects the telemetry server", result.stdout)
        self.assertIn("Workers & Pages › cartouche-telemetry › Access", result.stdout)
        self.assertIn("**Cloudflare Access protects the telemetry server", summary)
        # Both Workers went up all the same.
        self.assertEqual(set(self.cloudflare.scripts), {"cartouche-telemetry", "cartouche-dashboard"})

    def test_without_the_secrets_nothing_happens(self):
        result = self.deploy()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("not deployed", result.stdout)
        self.assertEqual(self.cloudflare.calls, [])


if __name__ == "__main__":
    unittest.main()
