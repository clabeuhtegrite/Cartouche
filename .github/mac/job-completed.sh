#!/bin/bash
# The runner's job completed hook on Ad's Mac (ACTIONS_RUNNER_HOOK_JOB_COMPLETED):
# the simulators the job booted shut down, so that the next job, and Ad's
# own apps, find the memory free.
xcrun simctl shutdown all >/dev/null 2>&1 || true
