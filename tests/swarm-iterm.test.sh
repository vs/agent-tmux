#!/usr/bin/env bash
# Tests for the iTerm helper (pure plan-order, error paths, shell wrapper).
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/swarm-lib.sh"
t_setup
REPO="$T_REPO"

py() { python3 -I "$REPO/bin/swarm-iterm.py" "$@"; }
expect_eq "moves new after project"  "27,30,28,29" "$(py plan-order --tabs 27,28,29,30 --new 30 --project 27)"
expect_eq "after last project tab"   "1,5,6,7,9"   "$(py plan-order --tabs 1,5,7,6,9 --new 7 --project 5,6)"
expect_eq "no project tab: unchanged" "1,2,3"      "$(py plan-order --tabs 1,2,3 --new 3 --project 8)"
expect_eq "already in place"         "1,2,3"       "$(py plan-order --tabs 1,2,3 --new 2 --project 1)"
expect_eq "@ ids accepted"           "27,30,28"    "$(py plan-order --tabs @27,@28,@30 --new @30 --project @27)"

if python3 -I -c 'import iterm2' 2>/dev/null; then
  t_pass "api missing exits 3 (skipped: iterm2 importable)"
else
  expect "api missing exits 3" 3 "swarm-iterm:" python3 -I "$REPO/bin/swarm-iterm.py" hotkey-windows
fi

expect "wrapper: uses SWARM_ITERM_HELPER" 0 "" bash -c ". $REPO/lib/swarm/common.sh; . $REPO/lib/swarm/iterm.sh; swarm_iterm hotkey-windows"
expect_eq "wrapper: helper got args" "hotkey-windows" "$(cat "$FAKE_ITERM_LOG")"
FAKE_ITERM_OUT="@1 @2" expect "wrapper: passes output" 0 "@1 @2" bash -c ". $REPO/lib/swarm/common.sh; . $REPO/lib/swarm/iterm.sh; swarm_iterm hotkey-windows"
FAKE_ITERM_CODE=3 expect "wrapper: passes exit code" 3 "" bash -c ". $REPO/lib/swarm/common.sh; . $REPO/lib/swarm/iterm.sh; swarm_iterm hotkey-windows"
unset SWARM_ITERM_HELPER
expect "wrapper: missing python" 3 "" env SWARM_PYTHON=/nonexistent/python bash -c ". $REPO/lib/swarm/common.sh; . $REPO/lib/swarm/iterm.sh; swarm_iterm hotkey-windows"
t_done
