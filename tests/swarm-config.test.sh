#!/usr/bin/env bash
# Tests for `swarm config` and the CLI skeleton.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/swarm-lib.sh"
t_setup

cat > "$SWARM_CONFIG" <<'CONF'
# comment
root ~/workspace
root /tmp/other   # trailing comment
project tmux-agent ~/workspace/tmux
group work assup code tmux-agent
set lt_model sonnet
bogus line here
CONF
expect "config prints roots"    1 "root $HOME/workspace"          swarm config
expect "trailing comment stripped" 1 $'root /tmp/other\n' swarm config
expect "config prints project"  1 "project tmux-agent $HOME/workspace/tmux" swarm config
expect "config prints group"    1 "group work assup code tmux-agent" swarm config
expect "config setting"         1 "set lt_model sonnet"           swarm config
expect "config default kept"    1 "set stall_min 20"              swarm config
expect "config reports bad line" 1 "line 7: unknown directive 'bogus'" swarm config
sed -i '' '/bogus/d' "$SWARM_CONFIG"
expect "config clean exits 0"   0 "set retile_delay 0.6"          swarm config
rm "$SWARM_CONFIG"
expect "missing config = defaults" 0 "root $HOME/workspace"       swarm config
# Project and group names must be safe in tmux targets; numeric settings must
# be numbers (an invalid one falls back to the default).
mkdir -p "$HOME/workspace/my.proj" "$HOME/workspace/x"
cat > "$SWARM_CONFIG" <<'CONF'
project my.proj ~/workspace/my.proj
project ok_1-a ~/workspace/x
group a.b ok_1-a
set stall_min soon
set idle_min 2.5
set poll_sec
set retile_delay 0.25
set retile_delay fast
CONF
expect "bad project name" 1 "line 1: invalid project name 'my.proj' (use letters, digits, - and _)" swarm config
expect "good project name kept" 1 "project ok_1-a $HOME/workspace/x" swarm config
expect "bad project not listed" 1 "" sh -c "swarm config 2>/dev/null | grep -q 'project my.proj'"
expect "bad group name" 1 "line 3: invalid group name 'a.b' (use letters, digits, - and _)" swarm config
expect "stall_min not a number" 1 "line 4: setting 'stall_min' must be a number" swarm config
expect "idle_min integer"       1 "line 5: setting 'idle_min' must be a number" swarm config
expect "poll_sec empty"         1 "line 6: setting 'poll_sec' must be a number" swarm config
expect "retile_delay decimal ok" 1 "" sh -c "swarm config 2>&1 | grep -q 'line 7'"
expect "retile_delay not a number" 1 "line 8: setting 'retile_delay' must be a number" swarm config
expect "invalid falls back: stall_min" 1 "set stall_min 20" swarm config
expect "invalid falls back: idle_min"  1 "set idle_min 2"$'\n' swarm config
expect "invalid falls back: poll_sec"  1 "set poll_sec 15" swarm config
expect "invalid falls back: retile_delay" 1 "set retile_delay 0.6" swarm config
expect "resolve refuses bad project" 1 "line 1: invalid project name 'my.proj'" swarm _resolve my.proj
expect "open refuses bad project" 1 "line 1: invalid project name 'my.proj'" swarm open my.proj
expect "resolve refuses bad group" 1 "line 3: invalid group name 'a.b'" swarm _resolve a.b
printf 'set stall_min 5\nset retile_delay .5\n' > "$SWARM_CONFIG"
expect "valid numbers accepted" 0 $'set stall_min 5\nset idle_min 2\nset poll_sec 15\nset retile_delay .5' swarm config
rm "$SWARM_CONFIG"

expect "no args prints usage"   1 "usage: swarm"                  swarm
expect "unknown dash flag"      1 "usage: swarm"                  swarm --nope
expect "unknown name is a project" 1 "swarm: error: cannot resolve 'frob'" swarm frob
expect "underscore name is a project" 1 "cannot resolve '_bogus'" swarm _bogus
# /bin/sh may be bash in sh mode (macOS), so compare the first pane to a later one.
t_session shelltest
t_session shelltest2
sleep 0.3
expect_eq "first session pane shell matches /bin/sh" \
  "$(t_tmux display-message -p -t shelltest2 '#{pane_current_command}')" \
  "$(t_tmux display-message -p -t shelltest '#{pane_current_command}')"
expect_eq "default-shell is /bin/sh" "/bin/sh" "$(t_tmux show-options -gv default-shell)"
t_done
