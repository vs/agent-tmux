#!/usr/bin/env bash
# Tests for swarm status/peek/report/close and swarm_track.
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
HELPER=$(t_tmux split-window -d -t "$LT_PANE" -P -F '#{pane_id}' -c "$HOME/workspace/assup")
t_tmux set-option -p -t "$HELPER" @name helper-1
t_tmux send-keys -t "$HELPER" "claude --agent-name helper-1" Enter
cwd="$HOME/workspace/assup"
cat > "$FAKE_AGENTS_JSON" <<JSON
[{"name":"assup-main","status":"idle","sessionId":"s1","cwd":"$cwd"},
 {"name":"assup-auth","status":"busy","cwd":"$cwd"}]
JSON

expect "status shows lieutenant busy" 0 "assup:auth" swarm status --all
expect "status helper label" 0 "helper-1" swarm status --all
expect "status project header" 0 "assup  (~/workspace/assup)" swarm status --all
expect_eq "json: lt state" "busy" "$(swarm status --all --json | jq -r '.[0].tabs[] | select(.name=="assup:auth") | .panes[] | select(.label=="auth") | .state')"
expect_eq "json: main idle" "idle" "$(swarm status --all --json | jq -r '.[] | select(.project=="assup") | .tabs[] | select(.role=="main") | .panes[1].state')"
expect_eq "session id recorded" "s1" "$(t_tmux show -wv -t "$MAIN_WIN" @swarm-session-id)"
expect_eq "lt keeps no session id" "" "$(t_tmux show -wqv -t "$LT_WIN" @swarm-session-id)"
expect "waiting shows what" 0 "waiting approve" sh -c "echo '[{\"name\":\"assup-auth\",\"status\":\"waiting\",\"waitingFor\":\"approve\"}]' > '$FAKE_AGENTS_JSON'; swarm status --all"
cat > "$FAKE_AGENTS_JSON" <<JSON
[{"name":"assup-main","status":"idle","sessionId":"s1","cwd":"$cwd"},
 {"name":"assup-auth","status":"busy","cwd":"$cwd"}]
JSON
expect "time in state grows" 0 "10m" env SWARM_NOW=$(( $(date +%s) + 600 )) swarm status --all
expect "default from non-swarm pane shows all" 0 "code" swarm status
U=$(t_tmux new-window -d -P -F '#{pane_id}' -t home)
expect "plain pane shows all" 0 "code  (" env TMUX_PANE="$U" swarm status
expect "caller's project only" 1 "" sh -c "TMUX_PANE=$LT_PANE swarm status | grep -q '^code'"
FAKE_AGENTS_FAIL=1 expect "agents failure -> unknown" 0 "unknown" swarm status --all

t_tmux send-keys -t "$HELPER" "Do you want to proceed?"; sleep 0.3
expect_eq "helper waiting heuristic" "waiting" "$(swarm status --all --json | jq -r '..|objects|select(.label=="helper-1")|.state')"
expect "peek" 0 "Do you want to proceed?" swarm peek assup:helper-1
expect "peek pane id" 0 "Do you want to proceed?" swarm peek "$HELPER"
expect "peek bare name in caller project" 0 "Do you want to proceed?" env TMUX_PANE="$LT_PANE" swarm peek helper-1
expect_eq "peek -n 1" "1" "$(swarm peek assup:helper-1 -n 1 | wc -l | tr -d ' ')"
expect "peek unknown" 1 "no such agent or tab 'assup:nope'" swarm peek assup:nope
expect "peek bare unknown outside" 1 "no such agent or tab 'auth'" swarm peek auth

expect "report outside lt" 1 "must be run from a lieutenant's pane" env TMUX_PANE="$MAIN_AGENT_PANE" swarm report done ok
expect "report no pane" 1 "must be run from a lieutenant's pane" env -u TMUX_PANE swarm report done ok
expect "report empty" 1 "report needs a message" env TMUX_PANE="$LT_PANE" swarm report done
expect "report bad kind" 1 "usage" env TMUX_PANE="$LT_PANE" swarm report maybe x
expect "report" 0 "" env TMUX_PANE="$LT_PANE" swarm report done "all tasks committed"
expect_eq "report option" "done: all tasks committed" "$(t_tmux show -wv -t "$LT_WIN" @swarm-report)"
expect "report from helper pane" 0 "" env TMUX_PANE="$HELPER" swarm report blocked need a key
expect_eq "report joins args" "blocked: need a key" "$(t_tmux show -wv -t "$LT_WIN" @swarm-report)"
expect "status shows report" 0 "report: blocked: need a key" swarm status --all

# swarm_track directly.
source "$T_REPO/lib/swarm/common.sh"; source "$T_REPO/lib/swarm/agents.sh"
a=$(SWARM_NOW=100 swarm_track k busy); b=$(SWARM_NOW=200 swarm_track k busy); c=$(SWARM_NOW=300 swarm_track k idle)
expect_eq "track keeps since" "100 100 300" "$a $b $c"

expect "close refuses main" 1 "not a lieutenant tab" swarm close assup:main
expect "close refuses helper name" 1 "no such agent or tab" swarm close assup:helper-1
expect "close refuses untagged pane" 1 "not a lieutenant tab" swarm close "$U"
expect "close unknown" 1 "no such agent or tab" swarm close assup:nope
expect "close" 0 "closed assup:auth" swarm close assup:auth
expect_eq "only lt tab gone" "assup-main" "$(t_tmux list-windows -t home -F '#{window_name}' | grep assup | tr '\n' ' ' | sed 's/ $//')"
expect_eq "untagged window survives" "1" "$(t_tmux list-panes -a -F '#{pane_id}' | grep -c "^$U\$")"
expect "status subcommand not a project" 0 "assup" swarm status
t_done
