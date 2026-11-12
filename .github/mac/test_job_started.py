"""Tests of job_started.py, the hook that refuses on Ad's Mac every job but
this repository's own."""

from __future__ import annotations

import io
import json
import sys
import tempfile
import unittest
from contextlib import redirect_stdout
from pathlib import Path
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parent))

import job_started  # noqa: E402

REPOSITORY = "clabeuhtegrite/Cartouche"
OWNER = "clabeuhtegrite"


def environment(event: str = "pull_request", actor: str = OWNER, triggering: str = OWNER, repository: str = REPOSITORY) -> dict:
    return {"GITHUB_REPOSITORY": repository, "GITHUB_EVENT_NAME": event,
            "GITHUB_ACTOR": actor, "GITHUB_TRIGGERING_ACTOR": triggering}


def pull(head: str = REPOSITORY, head_id: int = 7, author: str = OWNER, branch: str = "claude/thread", sender: str = OWNER) -> dict:
    return {
        "sender": {"login": sender},
        "repository": {"full_name": REPOSITORY},
        "pull_request": {
            "number": 131, "user": {"login": author},
            "head": {"ref": branch, "repo": {"full_name": head, "id": head_id}},
            "base": {"ref": "main", "repo": {"full_name": REPOSITORY, "id": 7}},
        },
    }


def allowed(env: dict, event: dict) -> bool:
    return job_started.allowed(REPOSITORY, [OWNER], env, event)[0]


class AllowedTests(unittest.TestCase):
    def test_takes_a_pull_request_from_a_branch_of_the_repository_by_its_owner(self):
        self.assertTrue(allowed(environment(), pull()))

    def test_takes_a_run_of_the_actions_tab_by_the_owner(self):
        event = {"sender": {"login": OWNER}, "repository": {"full_name": REPOSITORY}}
        self.assertTrue(allowed(environment("workflow_dispatch"), event))

    def test_names_ignore_case(self):
        env = environment(repository="Clabeuhtegrite/cartouche", actor="ClabeuhTegrite")
        self.assertTrue(allowed(env, pull(head="CLABEUHTEGRITE/CARTOUCHE")))

    def test_refuses_a_fork(self):
        self.assertFalse(allowed(environment(), pull(head="javi11/Cartouche", head_id=99)))

    def test_refuses_a_fork_that_took_the_repository_s_name(self):
        self.assertFalse(allowed(environment(), pull(head_id=99)))

    def test_refuses_a_pull_request_with_no_head_repository(self):
        event = pull()
        event["pull_request"]["head"]["repo"] = None
        self.assertFalse(allowed(environment(), event))

    def test_refuses_another_author_another_actor_or_another_sender(self):
        self.assertFalse(allowed(environment(), pull(author="javi11")))
        self.assertFalse(allowed(environment(actor="javi11"), pull()))
        self.assertFalse(allowed(environment(), pull(sender="javi11")))

    def test_refuses_a_run_again_by_someone_else(self):
        self.assertFalse(allowed(environment(triggering="javi11"), pull()))

    def test_refuses_a_job_without_its_actors(self):
        env = environment()
        del env["GITHUB_TRIGGERING_ACTOR"]
        self.assertFalse(allowed(env, pull()))

    def test_refuses_dependabot(self):
        self.assertFalse(allowed(environment(actor="dependabot[bot]", triggering="dependabot[bot]"), pull()))
        self.assertFalse(allowed(environment(), pull(branch="dependabot/github_actions/x")))

    def test_refuses_every_other_event(self):
        for event in ("push", "pull_request_target", "schedule", "workflow_run", "issue_comment", "release", ""):
            with self.subTest(event=event):
                self.assertFalse(allowed(environment(event), pull()))

    def test_refuses_another_repository(self):
        self.assertFalse(allowed(environment(repository="someone/Cartouche"), pull()))
        event = pull()
        event["repository"]["full_name"] = "someone/Cartouche"
        self.assertFalse(allowed(environment(), event))

    def test_refuses_everything_without_a_configuration(self):
        self.assertFalse(job_started.allowed("", [OWNER], environment(), pull())[0])
        self.assertFalse(job_started.allowed(REPOSITORY, [], environment(), pull())[0])
        self.assertFalse(job_started.allowed(REPOSITORY, [""], environment(), pull())[0])


class MainTests(unittest.TestCase):
    def run_hook(self, config: dict | None, event: dict | None) -> tuple[int, str]:
        with tempfile.TemporaryDirectory() as folder:
            config_path = Path(folder, "config.json")
            event_path = Path(folder, "event.json")
            if config is not None:
                config_path.write_text(json.dumps(config))
            if event is not None:
                event_path.write_text(json.dumps(event))
            printed = io.StringIO()
            env = {**environment(), "GITHUB_EVENT_PATH": str(event_path)}
            with mock.patch.object(job_started, "CONFIG", str(config_path)), \
                    mock.patch.dict("os.environ", env, clear=True), redirect_stdout(printed):
                code = job_started.main()
        return code, printed.getvalue()

    def test_lets_the_job_run(self):
        code, said = self.run_hook({"repository": REPOSITORY, "owners": [OWNER]}, pull())
        self.assertEqual(code, 0)
        self.assertIn("Ad's Mac takes this job", said)

    def test_fails_the_job_of_a_fork(self):
        code, said = self.run_hook({"repository": REPOSITORY, "owners": [OWNER]}, pull(head="javi11/Cartouche", head_id=9))
        self.assertEqual(code, 1)
        self.assertIn("::error::This job does not run on Ad's Mac", said)

    def test_fails_the_job_when_it_cannot_read_the_configuration_or_the_event(self):
        self.assertEqual(self.run_hook(None, pull())[0], 1)
        self.assertEqual(self.run_hook({"repository": REPOSITORY, "owners": [OWNER]}, None)[0], 1)


class HookScriptTests(unittest.TestCase):
    def test_the_hook_runs_root_s_copy_in_isolated_mode(self):
        script = Path(__file__).with_name("job-started.sh").read_text()
        self.assertIn(f"exec /usr/bin/python3 -I {Path(job_started.CONFIG).parent}/job_started.py", script)
        self.assertNotIn(" ", str(Path(job_started.CONFIG).parent), "the runner puts the path in bash's command line")


if __name__ == "__main__":
    unittest.main()
