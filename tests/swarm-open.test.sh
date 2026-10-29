#!/usr/bin/env bash
# Tests for `swarm open` and the shorthand.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/swarm-lib.sh"
t_setup

t_session home
(sleep 600 | t_tmux -C attach -t home) >/dev/null 2>&1 &
ctl=$!; disown "$ctl"
sleep 0.5
export FAKE_ITERM_CODE=3

mkdir -p "$HOME/workspace"/{assup,code,"sp ace"}
printf 'group work assup code\n' > "$SWARM_CONFIG"
swarm work
mains() { t_tmux list-windows -t home -F '#{window_name} #{@swarm-role} #{@swarm-project}' | grep ' main ' || true; }
expect_eq "tabs in order" "assup-main main assup|code-main main code" "$(mains | tr '\n' '|' | sed 's/|$//')"
a=$(t_tmux list-windows -t home -F '#{window_id} #{window_name}' | awk '$2=="assup-main"{print $1}')
c=$(t_tmux list-windows -t home -F '#{window_id} #{window_name}' | awk '$2=="code-main"{print $1}')
expect_eq "two panes"  "2" "$(t_tmux list-panes -t "$a" | wc -l | tr -d ' ')"
expect_eq "labels"     "shell assup-main" "$(t_tmux list-panes -t "$a" -F '#{@name}' | tr '\n' ' ' | sed 's/ $//')"
want=$(cd -P "$HOME/workspace/assup" && pwd)
expect_eq "shell cwd"  "$want" "$(t_tmux display -p -t "$a.0" '#{pane_current_path}')"
expect_eq "tags"       "assup main $HOME/workspace/assup stack" "$(t_tmux display -p -t "$a" '#{@swarm-project} #{@swarm-role} #{@swarm-dir} #{@swarm-layout}')"
expect_eq "selected first" "$a" "$(t_tmux display -p -t home '#{window_id}')"
log2() { [ "$(wc -l < "$FAKE_CLAUDE_LOG")" -ge 2 ]; }
expect "both orchestrators started" 0 "" t_wait 15 log2
expect "orchestrator args" 0 "" grep -aqF -e $'--name\x1fassup-main' "$FAKE_CLAUDE_LOG"
expect_eq "first owns telegram"   "1" "$(t_tmux show -wv -t "$a" @swarm-telegram)"
expect_eq "second has no telegram tag" "" "$(t_tmux show -wv -t "$c" @swarm-telegram 2>/dev/null || true)"
expect "second has telegram off"  0 '"telegram@claude-plugins-official":false' grep -a code-main "$FAKE_CLAUDE_LOG"
expect "first has telegram on"    1 "" sh -c "grep -a assup-main '$FAKE_CLAUDE_LOG' | grep -q enabledPlugins"
expect "agent teams unset"        0 "" sh -c "grep -q 'env -u CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS' '$SWARM_STATE_DIR/run/assup-main.sh'"
t_tmux send-keys -t "$a.0" 'echo "ENV:$SWARM_PROJECT:$SWARM_ROLE"' Enter; sleep 0.5
expect "pane env tagged" 0 "ENV:assup:main" t_tmux capture-pane -p -t "$a.0"

printf '[{"name":"assup-main","status":"idle","waitingFor":null,"cwd":"x","pid":1,"sessionId":"s1"},{"name":"code-main","status":"idle","waitingFor":null,"cwd":"x","pid":2,"sessionId":"s2"}]' > "$FAKE_AGENTS_JSON"
n=$(t_tmux list-windows -t home | wc -l); swarm assup
expect_eq "reopen: no duplicate" "$n" "$(t_tmux list-windows -t home | wc -l)"

# Dead orchestrator but busy pane: not typed into, warned.
echo '[]' > "$FAKE_AGENTS_JSON"; t_tmux set -w -t "$a" @swarm-session-id s1
before=$(cat "$FAKE_CLAUDE_LOG")
expect "busy pane warned" 0 "orchestrator pane is busy; not relaunching" swarm assup
sleep 0.5
expect_eq "busy pane untouched" "$before" "$(cat "$FAKE_CLAUDE_LOG")"

# Free the pane, then resume.
apid=$(t_tmux list-panes -t "$a" -F '#{pane_pid}' | sed -n 2p)
t_tmux send-keys -t "$a.1" C-c
nochild() { ! pgrep -P "$apid" >/dev/null 2>&1; }
expect "agent pane idle" 0 "" t_wait 10 nochild
: > "$FAKE_CLAUDE_LOG"; swarm assup
expect "claude started" 0 "" t_wait 15 test -s "$FAKE_CLAUDE_LOG"
expect "dead orchestrator resumed" 0 "" grep -aqF -e $'--resume\x1fs1' "$FAKE_CLAUDE_LOG"
expect "resume keeps name" 0 "" grep -aqF -e $'--name\x1fassup-main' "$FAKE_CLAUDE_LOG"
expect_eq "resume: still no duplicate" "$n" "$(t_tmux list-windows -t home | wc -l)"

expect "unresolvable opens nothing" 1 "cannot resolve" swarm code nope
expect_eq "nothing added" "$n" "$(t_tmux list-windows -t home | wc -l)"
expect "open subcommand name" 1 "cannot resolve 'config'" swarm open config
expect "unknown flag" 1 "usage" swarm -x
mkdir -p "$WORK/elsewhere/assup"
expect "name clash different dir" 1 "project 'assup' is already open from $HOME/workspace/assup" swarm "$WORK/elsewhere/assup"

swarm "$HOME/workspace/sp ace"
expect_eq "space path name" "1" "$(t_tmux list-windows -t home -F '#{window_name}' | grep -c '^sp-ace-main$')"
echo '[broken' > "$FAKE_AGENTS_JSON"; expect "bad agents json tolerated" 0 "" swarm code

# telegram_project set: only that project owns it.
printf 'set telegram_project code\n' > "$SWARM_CONFIG"
mkdir -p "$HOME/workspace/third"; echo '[]' > "$FAKE_AGENTS_JSON"; : > "$FAKE_CLAUDE_LOG"
swarm third
expect "claude started" 0 "" t_wait 15 test -s "$FAKE_CLAUDE_LOG"
expect "telegram_project: others off" 0 'enabledPlugins' grep -a third-main "$FAKE_CLAUDE_LOG"
: > "$FAKE_ITERM_LOG"
FAKE_ITERM_CODE=0 swarm --own-window code 2>/dev/null || true
expect "own-window opens iTerm window" 0 "new-window --session swarm-code" cat "$FAKE_ITERM_LOG"
expect "own-window session exists" 0 "" t_tmux has-session -t =swarm-code
expect_eq "own-window main tab" "code-main main" "$(t_tmux list-windows -t =swarm-code -F '#{window_name} #{@swarm-role}')"
expect_eq "own-window panes" "2" "$(t_tmux list-panes -t =swarm-code | wc -l | tr -d ' ')"
# Reattach: second open with no client calls new-window again; with a client it doesn't.
: > "$FAKE_ITERM_LOG"
FAKE_ITERM_CODE=0 swarm --own-window code 2>/dev/null || true
expect "own-window reopen reattaches" 0 "new-window --session swarm-code" cat "$FAKE_ITERM_LOG"
(sleep 600 | t_tmux -C attach -t swarm-code) >/dev/null 2>&1 &
ctl2=$!; disown "$ctl2"; sleep 0.5
: > "$FAKE_ITERM_LOG"
FAKE_ITERM_CODE=0 swarm --own-window code 2>/dev/null || true
expect_eq "own-window with client: no new window" "" "$(cat "$FAKE_ITERM_LOG")"
pkill -P "$ctl2" 2>/dev/null || true; kill "$ctl2" 2>/dev/null || true

# Launcher fallback (stand-in commands).
lw() { bash -c 'source "$1"; shift; swarm_write_launcher "$@"' _ "$T_REPO/lib/swarm/agents.sh" "$@"; }
rm -f "$WORK/fb"
lw "$WORK/l1.sh" "$WORK" sh -c 'exit 3' --else sh -c "echo fb >> '$WORK/fb'"
bash "$WORK/l1.sh"
expect_eq "fast failure runs fallback" "fb" "$(cat "$WORK/fb" 2>/dev/null)"
rm -f "$WORK/fb"
lw "$WORK/l2.sh" "$WORK" sh -c 'exit 130' --else sh -c "echo fb >> '$WORK/fb'"
bash "$WORK/l2.sh"
expect_eq "interrupt skips fallback" "" "$(cat "$WORK/fb" 2>/dev/null)"
expect "home never opens a window" 1 "" sh -c "grep -v swarm-code '$FAKE_ITERM_LOG' | grep -q new-window"

pkill -P "$ctl" 2>/dev/null || true
kill "$ctl" 2>/dev/null || true
t_done
