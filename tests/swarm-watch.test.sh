#!/usr/bin/env bash
# Tests for swarm watch.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/swarm-lib.sh"
t_setup

t_session home
(sleep 600 | t_tmux -C attach -t home) >/dev/null 2>&1 &
ctl=$!; disown "$ctl"
sleep 0.5
export FAKE_ITERM_CODE=0

mkdir -p "$HOME/workspace"/{assup,code}
swarm assup code
win_of() { t_tmux list-windows -t home -F '#{window_id} #{window_name}' | awk -v n="$1" '$2==n{print $1}'; }
MAIN_WIN=$(win_of assup-main)
MAIN_AGENT_PANE=$(t_tmux list-panes -t "$MAIN_WIN" -F '#{pane_id}' | sed -n 2p)
echo x | TMUX_PANE=$MAIN_AGENT_PANE swarm delegate auth - >/dev/null
LT_WIN=$(win_of assup:auth)
LT_PANE=$(t_tmux list-panes -t "$LT_WIN" -F '#{pane_id}' | sed -n 2p)

T0=$(date +%s)
REPO_DIR="$WORK/repo"
git init -q "$REPO_DIR"
git -C "$REPO_DIR" config user.email t@t; git -C "$REPO_DIR" config user.name t
GIT_COMMITTER_DATE="$((T0 - 7200)) +0000" git -C "$REPO_DIR" commit -q --allow-empty -m old

tick() { SWARM_NOW=$1 swarm watch --project assup --once; }
agents() { printf '[{"name":"assup-auth","status":"%s","waitingFor":null,"cwd":"%s","pid":1,"sessionId":"x"}]' "$1" "$REPO_DIR" > "$FAKE_AGENTS_JSON"; }
add_helpers() {
  local i
  for i in $(seq 1 "$1"); do
    t_tmux split-window -d -t "$LT_PANE" "claude --agent-name helper-$i"
  done
}

# Each tick records the session ids of the project's main and lieutenant tabs.
CODE_WIN=$(win_of code-main)
printf '[{"name":"assup-main","status":"idle","sessionId":"m1"},{"name":"assup-auth","status":"busy","sessionId":"l1"},{"name":"code-main","status":"idle","sessionId":"c1"}]' > "$FAKE_AGENTS_JSON"
tick $T0 >/dev/null
expect_eq "watch records main session id" "m1" "$(t_tmux show -wqv -t "$MAIN_WIN" @swarm-session-id)"
expect_eq "watch records lt session id" "l1" "$(t_tmux show -wqv -t "$LT_WIN" @swarm-session-id)"
expect_eq "watch leaves other projects" "" "$(t_tmux show -wqv -t "$CODE_WIN" @swarm-session-id)"

agents busy;  expect_eq "busy fresh: quiet" "" "$(tick $T0)"
expect_eq "stalled after 20m" "stalled auth 20" "$(tick $((T0+1200)))"
expect_eq "fires once" "" "$(tick $((T0+1260)))"
agents waiting; expect_eq "waiting never fires" "" "$(tick $((T0+1300)))"
agents idle;    expect_eq "idle fresh: quiet" "" "$(tick $((T0+1310)))"
expect_eq "idle-unreported after 2m" "idle-unreported auth" "$(tick $((T0+1430)))"
expect_eq "idle-unreported fires once" "" "$(tick $((T0+1440)))"
t_tmux set -w -t "$LT_WIN" @swarm-report "done: ok"; agents busy; tick $((T0+1450)) >/dev/null; agents idle
tick $((T0+1460)) >/dev/null
expect_eq "reported idle: quiet" "" "$(tick $((T0+1700)))"
add_helpers 2
expect_eq "over-cap in stack" "over-cap auth 2" "$(tick $((T0+1710)))"
expect_eq "over-cap fires once" "" "$(tick $((T0+1715)))"
t_tmux set -w -t "$LT_WIN" @swarm-layout grid
expect_eq "grid allows 2" "" "$(tick $((T0+1720)))"

# Stalled with no new commit (mirror), then with a new commit (R3).
T1=$((T0+2000))
agents busy; tick $T1 >/dev/null
expect_eq "no new commit: stalled fires" "stalled auth 21" "$(tick $((T1+1260)))"
agents idle; tick $((T1+1270)) >/dev/null
T2=$((T1+3000))
agents busy; tick $T2 >/dev/null
GIT_COMMITTER_DATE="$((T2 + 600)) +0000" git -C "$REPO_DIR" commit -q --allow-empty -m new
expect_eq "new commit prevents stalled" "" "$(tick $((T2+1260)))"

# idle-unreported waits for the last helper pane to close: a teams lead sits
# idle while its teammates work.
t_tmux set -wu -t "$LT_WIN" @swarm-report
T3=$((T2+3000))
agents idle; expect_eq "idle with helpers: quiet" "" "$(tick $T3)"
expect_eq "idle with helpers past idle_min: quiet" "" "$(tick $((T3+600)))"
for p in $(t_tmux list-panes -t "$LT_WIN" -F '#{pane_id}' | sed 1,2d); do t_tmux kill-pane -t "$p"; done
expect_eq "helpers closed: clock restarts" "" "$(tick $((T3+610)))"
expect_eq "helpers closed: quiet before idle_min" "" "$(tick $((T3+729)))"
expect_eq "helpers closed: fires after idle_min" "idle-unreported auth" "$(tick $((T3+730)))"

FAKE_AGENTS_FAIL=1 expect "agents failure: no output, exit 0" 0 "" swarm watch --project assup --once
expect "watch outside swarm tab" 1 "needs --project" env -u TMUX_PANE swarm watch --once
expect "watch bad arg" 1 "usage" swarm watch --bogus
t_done
