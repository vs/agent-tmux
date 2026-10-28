#!/usr/bin/env bash
# Tests for home-session detection (`swarm _home`).
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/swarm-lib.sh"
t_setup

t_session home
t_session other
(sleep 600 | t_tmux -C attach -t home) >/dev/null 2>&1 &
ctl=$!; disown "$ctl"
sleep 0.5

export FAKE_ITERM_CODE=3                       # API unavailable
expect_eq "control-mode fallback" "home" "$(swarm _home)"
export FAKE_ITERM_CODE=0 FAKE_ITERM_OUT="$(t_tmux display -p -t other '#{window_id}')"
expect_eq "hotkey window wins" "other" "$(swarm _home)"
export FAKE_ITERM_OUT="@999"
expect_eq "stale hotkey id falls through" "home" "$(swarm _home)"
export FAKE_ITERM_OUT="$(t_tmux display -p -t other '#{window_id}')"
echo "set session home" > "$SWARM_CONFIG"
expect_eq "config wins" "home" "$(swarm _home)"
echo "set session nosuch" > "$SWARM_CONFIG"
expect "config session missing" 1 "nosuch" swarm _home
rm "$SWARM_CONFIG"; export FAKE_ITERM_CODE=3; unset FAKE_ITERM_OUT
pkill -P "$ctl" 2>/dev/null || true   # the sleep and the control client
kill "$ctl" 2>/dev/null || true
sleep 0.5
n_before=$(t_tmux list-sessions | wc -l)
expect "nothing attached fails" 1 "attach tmux in your hotkey window first" swarm _home
expect "error names config path" 1 "$SWARM_CONFIG" swarm _home
expect_eq "nothing created" "$n_before" "$(t_tmux list-sessions | wc -l)"
t_done
