#!/bin/bash
# The runner's job completed hook on Ad's Mac (ACTIONS_RUNNER_HOOK_JOB_COMPLETED):
# how the Mac was doing at the end of the job, for the job's log, where the
# runs can be compared; then the simulators the job booted shut down, so
# that the next job, and Ad's own apps, find the memory free. The runner
# runs it with bash -e -o pipefail: nothing here may fail the job.
set +e +o pipefail
case "$(sysctl -n kern.memorystatus_vm_pressure_level 2>/dev/null)" in
  1) pressure=normal ;;
  2) pressure=warn ;;
  4) pressure=critical ;;
  *) pressure=unknown ;;
esac
free="$(sysctl -n kern.memorystatus_level 2>/dev/null)"
swap="$(sysctl -n vm.swapusage 2>/dev/null | sed -n 's/.*used = \([0-9.]*[MG]\).*/\1/p')"
load="$(sysctl -n vm.loadavg 2>/dev/null | tr -d '{}' | xargs)"
jobs="$(pgrep -f Runner.Worker | wc -l | tr -d ' ')"
echo "Ad's Mac at the end of this job: memory pressure $pressure, ${free:-?}% of the memory free, swap used ${swap:-?}, load ${load:-?} (1, 5 and 15 minutes), ${jobs:-?} job(s) running."
xcrun simctl shutdown all >/dev/null 2>&1 || true
