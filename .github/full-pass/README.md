# Full test pass

A pull request runs only the tests of what it changes: the storage tests when the storage code changes, the screenshots when a screen does, the Builder's Mac app when the Builder does. The [Full test pass](../workflows/full-pass.yml) runs all of them on one commit, and nothing is published from a commit until it has passed there: no version of Cartouche, of Cartouche Builder or of the Installer.

## What it runs

It calls each workflow that tests a part of the project, whole, with `full: true`: whatever the paths that choose their jobs for a pull request, without the memo of an earlier run, and without the jobs that publish, push or deploy.

| Part | Workflow | What runs |
| --- | --- | --- |
| CI | [ci.yml](../workflows/ci.yml) | the publish guard and the catalog, the app's sources and their branding tests, the shell scripts, Cartouche Builder's engine, the workflow audit, the site's tests |
| App | [app.yml](../workflows/app.yml) | the launcher's tests (`swift test`), then the app, its publish guard and its entry in the SideStore source |
| Storage | [storage.yml](../workflows/storage.yml) | the storage code against real servers, with an IPA past 4 GiB |
| Launcher screens | [screens.yml](../workflows/screens.yml) | the launcher's gallery, its UI tests and a screenshot of every scenario |
| Builder | [builder.yml](../workflows/builder.yml) | Cartouche Builder's tests, its app, its layout check, its disk image and its screenshots |
| Installer | [installer.yml](../workflows/installer.yml) | the Installer's tests, its Mac app and its Windows setup |
| Telemetry | [telemetry.yml](../workflows/telemetry.yml) | the telemetry server, its dashboard, its database and the weekly sum into the game sheets |
| Showcase site | [site.yml](../workflows/site.yml) | the page, and its download links against the releases as they are |

Its last job, **Every test passed** ([`verdict.py`](verdict.py)), reads the jobs of the run and fails when one failed, did not end, or was skipped though the pass must run it: only the jobs that publish, push or deploy, and those of pull requests alone, may be. Its summary gives each part's result. The builds, the screenshots and the UI tests' results stay with the run.

## When it runs

- On main, when a commit changes a version: `CARTOUCHE_VERSION` in `app/config.env`, `builder/pyproject.toml` or `installer/src-tauri/tauri.conf.json`. The pull request that raises a version starts it as it is merged.
- On main, when the pass itself changes.
- From **Actions › Full test pass › Run workflow**, on any branch.
- From the Release, Builder and Installer workflows, when none has run on their commit.

One pass runs at a time on a branch, as the Macs are few: another waits for it. It takes about an hour, more when the Macs are busy.

## How a release waits for it

The [Release](../workflows/release.yml) workflow, and the [Builder](../workflows/builder.yml) and [Installer](../workflows/installer.yml) workflows with **Publish** ticked, have the job **Full test pass on this commit** ([`wait_for_pass.py`](wait_for_pass.py)) once what they publish is built, and publish only once it has passed:

- a pass of this commit has passed: it goes on;
- one is queued or running: it waits for it, up to about five hours;
- one has failed, with none running: it stops, with the pass's link. Fix main, or, when a runner failed the pass rather than the code (a Mac that stopped answering), **Re-run failed jobs** on the pass, then re-run this job;
- none has run: it waits three minutes for the one a push may be starting, then starts one on its branch, if the branch is still at its commit, and waits for it;
- a pass of an earlier commit of main holds when every commit since changes only `app/sidestore-source.json`, as the pull request "Source: Cartouche X" does: the Builder can be published after it.

So a release goes as before: merge the pull request of the version, then run **Release** (and **Builder** or **Installer** with **Publish** ticked) on main. Each builds what it publishes while the pass runs, then waits for it, and publishes once it has passed. A build that fails starts no pass.

## Keeping it whole

The pass does not run on pull requests. The Workflow audit checks how it is wired instead ([`wiring.py`](wiring.py)), and fails a pull request that would:

- add a workflow that runs on pull requests without the pass calling it, unless it tests nothing (`NOT_TESTS`);
- call a workflow that does not take the boolean input `full` from `workflow_call`, or read an input in a test job that `workflow_call` does not take: in the pass, it is empty;
- read a secret in a test job that the call does not pass: a called workflow has only the secrets its call passes;
- let a job that writes or deploys run in the pass: its condition has `!inputs.full`;
- grant a call less than its workflow's jobs ask for, which GitHub checks before it starts the pass, skipped jobs included;
- keep two artifacts under the same name in the pass's one run;
- publish a release from a job that does not wait, directly or through the jobs it needs, for the pass of its commit.

[actionlint](../actionlint.yaml), in the same audit, checks what GitHub would refuse to start, as a call with an input the workflow does not take.

A workflow that tests something new takes `full` from `workflow_call` and is called by the pass. A job added to a workflow the pass calls runs in it by itself.

Tests, in the CI's Workflow audit: `python3 -m unittest discover -s .github/full-pass -v` (the wiring's tests need PyYAML).
