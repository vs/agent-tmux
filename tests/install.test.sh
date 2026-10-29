#!/usr/bin/env bash
# Tests for install.sh, run against a temp HOME and a private tmux tmpdir so
# they never touch the real tmux server or the real settings.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/swarm-lib.sh"
t_setup
H="$HOME"
mkdir -p "$WORK/tmux" "$H/.claude"
echo '{"permissions":{"allow":["Bash(tmux-bridge:*)"]}}' > "$H/.claude/settings.json"

run_install() {
  env -u TMUX -u TMUX_PANE HOME="$H" TMUX_TMPDIR="$WORK/tmux" AGENT_TMUX_SKIP_VENV=1 \
    PATH="$WORK/bin:$PATH" "$T_REPO/install.sh"
}
rules() { jq --arg r "$1" '[.permissions.allow[] | select(. == $r)] | length' "$H/.claude/settings.json"; }

expect "install runs" 0 "done." run_install
expect_eq "tmux-bridge linked" "$T_REPO/bin/tmux-bridge" "$(readlink "$H/.local/bin/tmux-bridge")"
expect_eq "swarm linked" "$T_REPO/bin/swarm" "$(readlink "$H/.local/bin/swarm")"
expect_eq "config created" "1" "$( [ -f "$H/.agent-tmux/swarm.conf" ] && echo 1)"
expect_eq "config is the example" "1" "$(cmp -s "$T_REPO/config/swarm.conf.example" "$H/.agent-tmux/swarm.conf" && echo 1)"
expect_eq "example sets root" "1" "$(grep -c '^root ~/workspace$' "$H/.agent-tmux/swarm.conf")"
for r in open delegate status peek report watch layout config; do
  expect_eq "allow $r" "1" "$(rules "Bash(swarm $r:*)")"
done
expect_eq "close not allowed" "0" "$(jq '[.permissions.allow[] | select(test("swarm close"))] | length' "$H/.claude/settings.json")"
expect_eq "tmux-bridge rule kept" "1" "$(rules 'Bash(tmux-bridge:*)')"
expect_eq "settings backed up" "1" "$(ls "$H/.claude"/settings.json.bak-* | head -1 | grep -c bak)"

echo "# mine" > "$H/.agent-tmux/swarm.conf"
expect "rerun" 0 "done." run_install
expect_eq "config not overwritten" "# mine" "$(cat "$H/.agent-tmux/swarm.conf")"
expect_eq "rerun: no duplicate open" "1" "$(rules 'Bash(swarm open:*)')"
expect_eq "rerun: no duplicate bridge" "1" "$(rules 'Bash(tmux-bridge:*)')"
expect_eq "rerun: rule count" "9" "$(jq '.permissions.allow | length' "$H/.claude/settings.json")"
expect_eq "venv skipped" "0" "$( [ -e "$H/.agent-tmux/venv" ] && echo 1 || echo 0)"
t_done
