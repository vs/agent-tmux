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
expect_eq "agents-restart linked" "$T_REPO/bin/agents-restart" "$(readlink "$H/.local/bin/agents-restart")"
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

# tmux.conf: a fixed source line, linked to the repo's config
src_line='source-file -q ~/.agent-tmux/tmux.conf'
n_src() { grep -cxF "$src_line" "$H/.tmux.conf" || true; }
expect_eq "tmux.conf linked" "$T_REPO/config/tmux.conf" "$(readlink "$H/.agent-tmux/tmux.conf")"
expect_eq "tmux.conf: source line added once" "1" "$(n_src)"
expect_eq "tmux.conf: no repo path" "0" "$(grep -c "$T_REPO" "$H/.tmux.conf" || true)"
tmux_opt() {
  local d="$WORK/tmux-load" v
  mkdir -p "$d"
  v=$(env -u TMUX HOME="$H" TMUX_TMPDIR="$d" tmux -f "$H/.tmux.conf" new-session -d -s load \; show -gv pane-border-status 2>&1)
  env -u TMUX TMUX_TMPDIR="$d" tmux kill-server 2>/dev/null || true
  echo "$v"
}
expect_eq "tmux.conf: tmux loads the settings" "top" "$(tmux_opt)"

# a line already there, in any spelling, is left alone (byte for byte)
for line in "$src_line" 'source-file ~/.agent-tmux/tmux.conf' 'source-file -q "$HOME/.agent-tmux/tmux.conf"' "  source-file $H/.agent-tmux/tmux.conf"; do
  printf 'set -g mouse on\n%s\n' "$line" > "$H/.tmux.conf"
  cp "$H/.tmux.conf" "$WORK/before"
  expect "existing line: rerun ($line)" 0 "done." run_install
  expect_eq "existing line: untouched ($line)" "1" "$(cmp -s "$WORK/before" "$H/.tmux.conf" && echo 1)"
done

# a mention of agent-tmux alone doesn't count
printf '# agent-tmux removed for now\nset -g mouse on\n' > "$H/.tmux.conf"
expect "mention only: rerun" 0 "done." run_install
expect_eq "mention only: line added" "1" "$(n_src)"

# a line left by an older install (old repo path) is swapped in place, through
# a symlinked ~/.tmux.conf, with a backup
mkdir -p "$WORK/dotfiles"
printf 'set -g mouse on\n\n# agent-tmux\nsource-file "/old/place/agent-tmux/config/tmux.conf"\nset -g status off\n' > "$WORK/dotfiles/tmux.conf"
rm -f "$H/.tmux.conf"; ln -s "$WORK/dotfiles/tmux.conf" "$H/.tmux.conf"
expect "old line: rerun" 0 "updated ~/.tmux.conf to source ~/.agent-tmux/tmux.conf instead of the repo path" run_install
expect_eq "old line: swapped" $'set -g mouse on\n\n# agent-tmux\n'"$src_line"$'\nset -g status off' "$(cat "$WORK/dotfiles/tmux.conf")"
expect_eq "old line: still a symlink" "$WORK/dotfiles/tmux.conf" "$(readlink "$H/.tmux.conf")"
expect_eq "old line: backed up" "1" "$(grep -c '/old/place/' "$H"/.agent-tmux/backups/*/.tmux.conf | tail -1)"
expect_eq "old line: no temp file left" "" "$(ls -a "$H" | grep agent-tmux.tmp || true)"
expect "old line: rerun is a no-op" 0 "ok      ~/.tmux.conf sources ~/.agent-tmux/tmux.conf" run_install
t_done
