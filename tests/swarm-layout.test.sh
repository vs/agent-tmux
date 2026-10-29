#!/usr/bin/env bash
# Tests for layouts, helper labels, `swarm layout` and the retile hooks.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/swarm-lib.sh"
t_setup
REPO="$T_REPO"

t_session test
t_tmux set-option -g window-size manual   # keep 241x61 with no client attached

# wait_for <cmd...>: poll until the command succeeds (up to ~5 s).
wait_for() {
  local i
  for i in $(seq 50); do "$@" && return 0; sleep 0.1; done
  return 1
}
has_agent_name() { ps -o args= -p "$1" 2>/dev/null | grep -q -- '--agent-name'; }

# newwin <role> <layout>: a tagged 241x61 window with one pane; echoes its id.
newwin() {
  local w
  w=$(t_tmux new-window -d -P -F '#{window_id}' -t test)
  t_tmux resize-window -t "$w" -x 241 -y 61
  t_tmux set-option -w -t "$w" @swarm-role "$1"
  t_tmux set-option -w -t "$w" @swarm-layout "$2"
  echo "$w"
}

# mkwin <role> <layout> <n_helpers>: shell, agent to its right, then helpers
# split off the agent pane running the fake claude. Echoes the window id.
mkwin() {
  local w agent i p
  w=$(newwin "$1" "$2")
  agent=$(t_tmux split-window -h -d -P -F '#{pane_id}' -t "$w")
  for ((i = 1; i <= $3; i++)); do
    p=$(t_tmux split-window -d -P -F '#{pane_pid}' -t "$agent" "claude --agent-name helper-$i")
    wait_for has_agent_name "$p"
  done
  echo "$w"
}
geom() { t_tmux list-panes -t "$1" -F '#{pane_index}:#{pane_left},#{pane_top},#{pane_width}x#{pane_height}'; }
csum() { /bin/bash -c '. "$1"; layout_checksum "$2"' _ "$REPO/lib/swarm/layout.sh" "$1"; }
# old_layout <@win>: tmux's own `checksum,body` layout string. tmux 3.8 prints
# JSON layouts but still sends the old format to control-mode clients.
old_layout() {
  { echo "display-message -p -t $1 '#{window_layout}'"; sleep 0.3; } \
    | t_tmux -C attach -t test 2>/dev/null | grep -E '^[0-9a-f]{4},' | head -1
}
pane_ids() { t_tmux list-panes -t "$1" -F '#{pane_id}' | tr -d '%' | tr '\n' ' '; }

# --- stack -------------------------------------------------------------------
w=$(mkwin lieutenant stack 1)
t_tmux set-option -p -t "$w.1" @name lt-label
swarm _retile-session test --now
expect_eq "stack: shell left half"  "0:0,0,120x61" "$(geom "$w" | sed -n 1p)"
expect_eq "stack: agent top-right"  "1:121,0,"     "$(geom "$w" | sed -n 2p | cut -c1-8)"
expect_eq "stack: helper below agent" "121"        "$(t_tmux display -p -t "$w.2" '#{pane_left}')"
expect_eq "label from --agent-name" "helper-1"     "$(t_tmux display -p -t "$w.2" '#{@name}')"
expect_eq "agent label left alone"  "lt-label"     "$(t_tmux display -p -t "$w.1" '#{@name}')"
expect_eq "shell not labelled"      ""             "$(t_tmux display -p -t "$w.0" '#{@name}')"

# --- grid --------------------------------------------------------------------
g=$(mkwin lieutenant grid 3)
swarm _retile-session test --now
expect_eq "grid: shell width (W-1)/3" "0:0,0,80x61" "$(geom "$g" | sed -n 1p)"
expect_eq "grid: agent top-left of right" "1:81,0,"  "$(geom "$g" | sed -n 2p | cut -c1-7)"
expect_eq "grid: 2x2 bottom row y"   "31"            "$(t_tmux display -p -t "$g.3" '#{pane_top}')"
expect_eq "grid: helper-3 bottom-right" "1"          "$(t_tmux display -p -t "$g.4" '#{?#{e|>:#{pane_left},81},1,0}')"
set -- $(pane_ids "$g")
expect_eq "grid: full layout" \
  "241x61,0,0{80x61,0,0,$1,160x61,81,0[160x30,81,0{79x30,81,0,$2,80x30,161,0,$3},160x30,81,31{79x30,81,31,$4,80x30,161,31,$5}]}" \
  "$(old_layout "$g" | cut -d, -f2-)"
for i in 2 3 4; do
  expect_eq "grid: helper $i labelled" "1" "$(t_tmux display -p -t "$g.$i" '#{?#{m:helper-*,#{@name}},1,0}')"
done
g2=$(mkwin lieutenant grid 1)
swarm _retile-session test --now
expect_eq "grid k=2: agent above helper" "1:81,0,160x30 2:81,31,160x30" \
  "$(geom "$g2" | sed -n '2,3p' | tr '\n' ' ' | sed 's/ $//')"
g1=$(mkwin lieutenant grid 0)
swarm _retile-session test --now
expect_eq "grid k=1: agent fills right column" "0:0,0,80x61 1:81,0,160x61" \
  "$(geom "$g1" | tr '\n' ' ' | sed 's/ $//')"
big=$(mkwin lieutenant grid 4)
swarm _retile-session test --now
expect_eq "grid with >5 panes falls back to stack" "0:0,0,120x61" "$(geom "$big" | sed -n 1p)"

# --- main window, untagged windows, delay ------------------------------------
m=$(mkwin main stack 0)
t_tmux resize-pane -t "$m.0" -x 50
u=$(t_tmux new-window -d -P -F '#{window_id}' -t test); t_tmux split-window -t "$u"; t_tmux split-window -t "$u"
t_tmux resize-pane -t "$u.0" -y 7
before=$(t_tmux display -p -t "$u" '#{window_layout}')
start=$(date +%s); echo "set retile_delay 5" > "$SWARM_CONFIG"
t_session untagged; swarm _retile-session untagged
expect_eq "untagged session: returns at once" "1" "$(( $(date +%s) - start < 2 ))"
expect "missing session: quiet no-op" 0 "" swarm _retile-session nosuch
swarm _retile-session test --now
expect_eq "main window retiled" "120" "$(t_tmux display -p -t "$m.0" '#{pane_width}')"
expect_eq "untagged window unchanged" "$before" "$(t_tmux display -p -t "$u" '#{window_layout}')"
expect_eq "untagged window not renamed or labelled" "" "$(t_tmux list-panes -t "$u" -F '#{@name}' | tr -d '\n')"
t_tmux resize-pane -t "$m.0" -x 50
echo "set retile_delay 1" > "$SWARM_CONFIG"
start=$(date +%s); swarm _retile-session test
expect_eq "tagged session: waits retile_delay" "1" "$(( $(date +%s) - start >= 1 ))"
expect_eq "tagged session: retiled after delay" "120" "$(t_tmux display -p -t "$m.0" '#{pane_width}')"
rm -f "$SWARM_CONFIG"

# --- checksum ----------------------------------------------------------------
expect_eq "checksum: tmux man page vector" "bb62" "$(csum '159x48,0,0{79x48,0,0,79x48,80,0}')"
for win in "$g" "$w" "$g2"; do
  lay=$(old_layout "$win")
  expect_eq "checksum matches tmux ($win)" "${lay%%,*}" "$(csum "${lay#*,}")"
done

# --- swarm layout ------------------------------------------------------------
expect "layout from plain terminal" 1 "must be run from a lieutenant's pane" swarm layout grid
expect "layout outside lieutenant" 1 "must be run from a lieutenant's pane" env TMUX_PANE="$(t_tmux display -p -t "$u" '#{pane_id}')" swarm layout grid
expect "layout from main window" 1 "must be run from a lieutenant's pane" env TMUX_PANE="$(t_tmux display -p -t "$m.1" '#{pane_id}')" swarm layout grid
expect "layout bad name" 1 "usage: swarm layout <stack|grid>" env TMUX_PANE="$(t_tmux display -p -t "$w.1" '#{pane_id}')" swarm layout tiled
expect_eq "nothing changed" "stack|main|$before" \
  "$(t_tmux show -wv -t "$w" @swarm-layout)|$(t_tmux show -wv -t "$m" @swarm-role)|$(t_tmux display -p -t "$u" '#{window_layout}')"
expect "layout from lieutenant" 0 "" env TMUX_PANE="$(t_tmux display -p -t "$w.1" '#{pane_id}')" swarm layout grid
expect_eq "layout sets option" "grid" "$(t_tmux show -wv -t "$w" @swarm-layout)"
expect_eq "layout retiles at once" "80" "$(t_tmux display -p -t "$w.0" '#{pane_width}')"
expect "layout back to stack" 0 "" env TMUX_PANE="$(t_tmux display -p -t "$w.2" '#{pane_id}')" swarm layout stack
expect_eq "stack again" "120" "$(t_tmux display -p -t "$w.0" '#{pane_width}')"

# --- hooks (config/tmux.conf), end to end on the private server --------------
t_tmux -f "$REPO/config/tmux.conf" source-file "$REPO/config/tmux.conf"
hooks=$(t_tmux show-hooks -g)
# show-hooks prints the stored command re-quoted, so the inner quotes show as \".
for hk in after-split-window after-kill-pane; do
  expect_eq "$hk hook keeps literal format" "1" \
    "$(printf '%s\n' "$hooks" | grep "^$hk\\[90\\]" | grep -c '_retile-session \\"#{session_name}\\"')"
done
mkdir -p "$HOME/.local/bin"
ln -s "$REPO/bin/swarm" "$HOME/.local/bin/swarm"
t_tmux set-environment -g SWARM_TMUX_SOCKET "$SWARM_TMUX_SOCKET"
echo "set retile_delay 0.1" > "$SWARM_CONFIG"
pane_w() { [[ "$(t_tmux display -p -t "$1" '#{pane_width}')" == "$2" ]]; }

h=$(newwin lieutenant stack)
t_tmux split-window -h -d -l 200 -t "$h"
expect_eq "hook split: starts narrow" "40" "$(t_tmux display -p -t "$h.0" '#{pane_width}')"
if wait_for pane_w "$h.0" 120; then t_pass "hook re-tiles after split"; else t_fail "hook re-tiles after split" "$(geom "$h")"; fi
t_tmux split-window -d -t "$h.1" "claude --agent-name hooked"
lab() { [[ "$(t_tmux display -p -t "$1" '#{@name}')" == "$2" ]]; }
if wait_for lab "$h.2" hooked; then t_pass "hook labels helper"; else t_fail "hook labels helper" "@name=$(t_tmux display -p -t "$h.2" '#{@name}')"; fi
t_tmux resize-pane -t "$h.0" -x 30
t_tmux kill-pane -t "$h.2"
if wait_for pane_w "$h.0" 120; then t_pass "hook re-tiles after kill-pane"; else t_fail "hook re-tiles after kill-pane" "$(geom "$h")"; fi

t_tmux split-window -d -t "$u"
after=$(t_tmux display -p -t "$u" '#{window_layout}')
ut=$(t_tmux display -p -t untagged: '#{window_id}')
t_tmux split-window -d -t "$ut"; t_tmux resize-pane -t "$ut.0" -y 9
uafter=$(t_tmux display -p -t "$ut" '#{window_layout}')
sleep 1
expect_eq "hook leaves untagged window in tagged session" "$after" "$(t_tmux display -p -t "$u" '#{window_layout}')"
expect_eq "hook leaves untagged session" "$uafter" "$(t_tmux display -p -t "$ut" '#{window_layout}')"
t_done
