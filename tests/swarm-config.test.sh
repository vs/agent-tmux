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
t_done
