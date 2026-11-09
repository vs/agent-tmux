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
expect_eq "iterm-upgrade linked" "$T_REPO/bin/iterm-upgrade" "$(readlink "$H/.local/bin/iterm-upgrade")"
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

# iTerm hotkey profiles: a bare `tmux -CC` (or the old iterm-tmux wrapper)
# becomes `tmux -CC new-session -A -s main`, with the old command kept, and
# the session the hotkey window shows is renamed to main. Others are left alone.
cat > "$WORK/bin/fake-iterm-hk" <<'EOF'
#!/usr/bin/env bash
echo "$*" >> "$FAKE_ITERM_LOG"
case "$1" in
  hotkey-profiles) printf '%s\n' "$FAKE_PROFILES" ;;
  hotkey-windows) [[ -z "${FAKE_HOTKEY_IDS:-}" ]] || echo "$FAKE_HOTKEY_IDS" ;;
esac
EOF
chmod +x "$WORK/bin/fake-iterm-hk"
export SWARM_ITERM_HELPER="$WORK/bin/fake-iterm-hk"
ttmux() { env -u TMUX TMUX_TMPDIR="$WORK/tmux" tmux "$@"; }
want="$(command -v tmux) -CC new-session -A -s main"

: > "$FAKE_ITERM_LOG"
ttmux new-session -d -s 37
FAKE_HOTKEY_IDS=$(ttmux display-message -p -t =37: '#{window_id}'); export FAKE_HOTKEY_IDS
export FAKE_PROFILES=$'G1\tYes\t/opt/homebrew/bin/tmux -CC\ttmux\nG2\tNo\t\tDefault\nG3\tYes\t/bin/zsh -l\tzsh'
expect "hotkey: rerun" 0 "updated iTerm profile 'tmux': /opt/homebrew/bin/tmux -CC -> $want" run_install
expect_eq "hotkey: only the tmux profile set" "set-profile-command --guid G1 --command $want" "$(grep set-profile "$FAKE_ITERM_LOG")"
expect_eq "hotkey: old command backed up" "1" "$(grep -c $'^G1\ttmux\t/opt/homebrew/bin/tmux -CC$' "$H"/.agent-tmux/backups/*/iterm-profiles.tsv | tail -1)"
expect_eq "hotkey: its session renamed" "main" "$(ttmux list-sessions -F '#{session_name}')"

: > "$FAKE_ITERM_LOG"
export FAKE_PROFILES=$'G1\tYes\t'"$want"$'\ttmux'
expect "hotkey: already set" 0 "ok      iTerm profile 'tmux' reattaches tmux session 'main'" run_install
expect_eq "hotkey: already set, not touched" "" "$(grep set-profile "$FAKE_ITERM_LOG" || true)"

# from the iterm-tmux wrapper of an earlier version: link and state removed
ln -s "$T_REPO/bin/iterm-tmux" "$H/.local/bin/iterm-tmux"
echo 37 > "$H/.agent-tmux/hotkey-session"
ttmux kill-server; ttmux new-session -d -s 37
FAKE_HOTKEY_IDS=$(ttmux display-message -p -t =37: '#{window_id}'); export FAKE_HOTKEY_IDS
export FAKE_PROFILES=$'G1\tYes\t'"$H/.local/bin/iterm-tmux"$'\ttmux'
expect "wrapper: replaced" 0 "updated iTerm profile 'tmux': $H/.local/bin/iterm-tmux -> $want" run_install
expect_eq "wrapper: link removed" "0" "$([[ -L "$H/.local/bin/iterm-tmux" ]] && echo 1 || echo 0)"
expect_eq "wrapper: state removed" "0" "$([[ -e "$H/.agent-tmux/hotkey-session" ]] && echo 1 || echo 0)"
expect_eq "wrapper: session renamed" "main" "$(ttmux list-sessions -F '#{session_name}')"

# a main session already there: nothing renamed
ttmux new-session -d -s 37
FAKE_HOTKEY_IDS=$(ttmux display-message -p -t =37: '#{window_id}'); export FAKE_HOTKEY_IDS
export FAKE_PROFILES=$'G1\tYes\t/opt/homebrew/bin/tmux -CC\ttmux'
expect "main exists: rerun" 0 "done." run_install
expect_eq "main exists: 37 kept" $'37\nmain' "$(ttmux list-sessions -F '#{session_name}' | sort)"

# a profile naming another session is left alone
: > "$FAKE_ITERM_LOG"
export FAKE_PROFILES=$'G1\tYes\t/usr/local/bin/tmux -CC new -s work -A\ttmux'
expect "other name: left alone" 0 "reattaches tmux session 'work' (left as is)" run_install
expect_eq "other name: not touched" "" "$(grep set-profile "$FAKE_ITERM_LOG" || true)"
ttmux kill-server

unset FAKE_PROFILES FAKE_HOTKEY_IDS
FAKE_ITERM_CODE=3 SWARM_ITERM_HELPER="$WORK/bin/fake-iterm" expect "hotkey: no iTerm API" 0 "skipped iTerm hotkey profile" run_install

# the profile command parser
. "$T_REPO/lib/swarm/iterm.sh"
expect_eq "parse: new-session -A -s"  "main" "$(iterm_profile_session '/opt/homebrew/bin/tmux -CC new-session -A -s main')"
expect_eq "parse: new -s -A"          "w-1"  "$(iterm_profile_session 'tmux -CC new -s w-1 -A')"
expect_eq "parse: bare -CC"           ""     "$(iterm_profile_session '/opt/homebrew/bin/tmux -CC')"
expect_eq "parse: attach only"        ""     "$(iterm_profile_session 'tmux -CC attach -t main')"
t_done
