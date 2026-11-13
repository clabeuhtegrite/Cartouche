# The runners on Ad's Mac

GitHub runs five macOS jobs at a time for the whole account, and every Mac job of the CI waits for one of them: in the morning, App, Storage and Builder wait 20 to 35 minutes, and the screenshots take about half of all the Mac time. So the two longest Mac jobs of a pull request, the app's build (**Build Cartouche.ipa**, [App](../workflows/app.yml)) and the launcher's UI tests and screenshots (**UI tests and screenshots**, [Launcher screens](../workflows/screens.yml)), run on Ad's Mac when it can take them now, each on a runner of its own, and on GitHub's Macs otherwise. Everything else stays on GitHub's: main, releases, the Storage tests (root's servers), Builder, the installer.

## Where a job runs

[`route.py`](route.py), the first job of App and Launcher screens (**Ad's Mac or GitHub**), sends the job to Ad's Mac when:

- it is a job the Mac takes: a pull request from one of this repository's branches by its owner, or a run from the Actions tab (the hook's rules below); never a fork's pull request, which has no secret either, nor Dependabot's;
- it is a run of App or Launcher screens themselves, which Mac rescue can run again: a workflow that calls them runs them on GitHub's Macs;
- the secret `MAC_RUNNER_TOKEN` is set: it reads the repository's runners;
- the run is at its first attempt: a run again always goes to GitHub's Macs;
- the Mac's runner of the job is online with every label the job needs, and free, or busy with no other job waiting for it: on each runner, one job runs and one waits, at most. `ad-mac` takes the app's builds (`cartouche-mac`, `cartouche-build`, and `xcode-<version>` of the workflow's Xcode), `ad-mac-screens` the UI tests and screenshots (`cartouche-mac`, `cartouche-screens`, `xcode-<version>` and `ios-sim-<version>`): a build never waits behind them, which take every core of the Mac where a build takes few.

Anything else, an error of GitHub's API included, sends it to `xcode-27`, as before the Mac. The run's summary says where the job went, and why.

Beside a job on the Mac, **Watch Ad's Mac** ([`watch.py`](watch.py)) sends the run back to GitHub's Macs when the Mac is offline for a minute while the job waits for it or runs (it went to sleep, lost the network, or its supervisor stopped it), or when the job has waited 20 minutes (an hour for the UI tests and screenshots, which may wait behind a job of theirs, 46 minutes on the Mac): it starts [Mac rescue](../workflows/mac-rescue.yml) from main, which waits for the run to end and runs it again ([`rescue.py`](rescue.py)), then cancels the run. A job that fails on the Mac fails, as it would on GitHub's.

On the Mac, a job differs from GitHub's in three steps ([`job.sh`](job.sh)): it finds the workflow's Xcode in `/Applications` (`DEVELOPER_DIR`), where GitHub's Macs run `xcode-select` with sudo; it downloads ldid and XcodeGen at the versions and SHA-256 pinned in `job.sh`, where GitHub's Macs use Homebrew; it keeps the SideStores it built on its own disk, a folder for each key (its ldid is not Homebrew's), where GitHub's Macs use the Actions cache. Its simulators stay from one run to the next, shut down between jobs.

A job that may run on the Mac uses the Actions cache on GitHub's Macs only: the cache puts its compression in an entry's version, and the Mac, which has no zstd, keeps gzip entries that no job on GitHub's runners finds. The note that a pull request's UI tests and screenshots are done goes to the cache from a job on Ubuntu after them (`memo` in [`screens.yml`](../workflows/screens.yml)), as Ubuntu looks for it.

## No one else's job

The runners' job started hook ([`job_started.py`](job_started.py)), which the job can neither skip nor change, fails every job but this repository's own before the job's first step, whatever its workflow asks for: a fork's pull request whose workflow names the Mac's labels fails there and runs nothing. It reads only what GitHub says of the job, the `GITHUB_*` variables and the event: the runner gives a hook its own environment and these, never the workflow's `env` (`Runner.Worker/JobHookProvider.cs` of actions/runner). The job must be a run of this repository, of a `pull_request` from one of its branches or of a `workflow_dispatch`, by its owner, who opened the pull request, started the run, and ran it again if it was. `route.py` applies the same rules (`allowed()`), so that it never sends the Mac a job it would refuse.

Each runner's jobs run as an account of its own, `cartouche-ci` for the builds and `cartouche-ci-screens` for the screenshots, so that the simulators one shuts down and the caches it keeps are its own: hidden, with no password, so that no one logs in to it, with a group of its own, and refused every other account's home, the other runner's included, by an ACL, in case macOS counts it in `staff`, which most homes let in. It reads none of Ad's files, cannot use sudo, and owns only its home: its runner, the jobs' checkouts and what they build. The hooks, the supervisor and their configuration are root's (`/Library/CartoucheCI`), out of the jobs' reach. What still runs there is what the pull requests of this repository's branches run: the repository's code, and the pinned Swift packages, submodules, tools and actions it uses.

## When the Mac takes jobs

The supervisor ([`supervisor.py`](supervisor.py)), a LaunchDaemon of root, keeps each runner online only while the Mac can take a job without getting in Ad's way, and offline otherwise, so that the jobs go to GitHub's Macs:

- on mains power, or on the battery at 30% or more: below 30% it stops once the job it runs ends, below 20% at once;
- with 30 GB free to start; below 15 GB it stops once its job ends, below 8 GB at once;
- while every Xcode of its labels is in `/Applications`;
- unless Ad paused it, which stops it at once;
- unless the runner stopped by itself 3 times in half an hour, as it does once GitHub forgets a runner offline for 14 days: it tries again an hour later, and `cartouche-ci logs` says why (run `install.sh` again with a new registration token).

While a job runs, the Mac does not go to sleep by itself, on the battery too (`caffeinate -i -s`); closing the lid still puts it to sleep, and the watch sends the job back to GitHub. Each runner runs one job at a time, at a lower priority than Ad's apps: `Nice` 5 for the builds, 10 for the screenshots, which give way to the builds. At the end of each job, the job completed hook ([`job-completed.sh`](job-completed.sh)) prints in the job's log how the Mac was doing (memory pressure, free memory, swap, load, jobs running), where the runs can be compared, then shuts down the account's simulators. Once a day, while no job runs, the supervisor removes Xcode's builds left for three days, the SideStores beyond the four newest, simulators of runtimes no longer installed and the runner's logs of more than a week.

## Install, pause, remove

Once, on GitHub:

1. A fine-grained token that reads the runners: **Settings › Developer settings › Fine-grained tokens › Generate new token**, repository **Cartouche** only, permission **Administration: Read-only**. Saved as the repository's secret `MAC_RUNNER_TOKEN` (**Settings › Secrets and variables › Actions**). Without it, or once it expires, every job runs on GitHub's Macs.
2. A registration token for the runners: **Settings › Actions › Runners › New self-hosted runner**, the token of the `./config.sh` line, valid an hour, which registers both.

Then, in Terminal on the Mac, from an administrator account, with the commit to install ([`install.sh`](install.sh) says what it makes):

```sh
curl -fsSL https://raw.githubusercontent.com/clabeuhtegrite/Cartouche/COMMIT/.github/mac/install.sh -o /tmp/cartouche-ci.sh
sudo bash /tmp/cartouche-ci.sh COMMIT
```

It asks for the registration token once, and offers to download the iOS simulators of the CI's Xcode when the Mac lacks them (about 8 GB); without them, only the builds come to the Mac. Run again with a later commit, it updates the Mac's files; it asks for a new registration token only when a runner is new or its labels change (an Xcode installed or removed). Run it while no job runs on the Mac: a runner that registers again stops the job it runs.

[`cartouche-ci`](cartouche-ci), in `/usr/local/bin`:

```sh
cartouche-ci              # what the runners do now, and their last jobs
cartouche-ci pause        # stops them now, until cartouche-ci resume
cartouche-ci resume
cartouche-ci logs
cartouche-ci uninstall    # removes it all, their accounts included
```

## Tests

In the CI's Workflow audit: `python3 -m unittest discover -s .github/mac -v`, which checks the hook's rules, the route, the watch, Mac rescue, the supervisor's choices and how the workflows and the installer meet (with PyYAML). The scripts that run on the Mac keep to its Python, 3.9 (`/usr/bin/python3`).
