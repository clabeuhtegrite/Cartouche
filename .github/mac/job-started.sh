#!/bin/bash
# The runner's job started hook on Ad's Mac (ACTIONS_RUNNER_HOOK_JOB_STARTED),
# in root's folder, which the runner's account cannot change: it refuses
# every job but this repository's own (job_started.py). The runner gives it
# its own environment and the job's GITHUB_* variables, never the
# workflow's env.
exec /usr/bin/python3 -I /Library/CartoucheCI/job_started.py
