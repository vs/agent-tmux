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
expect "no args prints usage"   1 "usage: swarm"                  swarm
expect "unknown dash flag"      1 "usage: swarm"                  swarm --nope
expect "unknown subcommand"     1 "swarm: error: unknown subcommand frob" swarm frob
expect "unimplemented hidden"   1 "unknown subcommand _resolve"  swarm _resolve
# /bin/sh may be bash in sh mode (macOS), so compare the first pane to a later one.
t_session shelltest
t_session shelltest2
sleep 0.3
expect_eq "first session pane shell matches /bin/sh" \
  "$(t_tmux display-message -p -t shelltest2 '#{pane_current_command}')" \
  "$(t_tmux display-message -p -t shelltest '#{pane_current_command}')"
expect_eq "default-shell is /bin/sh" "/bin/sh" "$(t_tmux show-options -gv default-shell)"
t_done
