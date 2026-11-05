#!/usr/bin/env bash
# Tests for agents-restart discovery: panes, agent processes, versions.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/agents-restart-lib.sh"
t_setup
cd "$T_REPO"
source lib/agents-restart/common.sh
source lib/agents-restart/discover.sh

expect_eq "version from upgrading path" 2.1.317 "$(ar_version_from_path /x/claude-code@latest/2.1.317.upgrading/claude)"
expect_eq "version from mise path" 2.1.318 "$(ar_version_from_path /h/.local/share/mise/installs/claude-code/2.1.318/claude)"
expect_eq "no version in path" "" "$(ar_version_from_path /usr/local/bin/claude)"
expect "outdated unknown" 0 "" ar_outdated - 2.0.0
expect "outdated differs" 0 "" ar_outdated 1.0.0 2.0.0
expect "not outdated" 1 "" ar_outdated 2.0.0 2.0.0

t_install_fake claude 1.0.0
t_install_fake claude 2.0.0
t_install_fake gemini 0.5.0
t_install_fake gemini 0.6.0
t_use_version gemini 0.6.0
t_use_version claude 2.0.0
mkdir -p "$WORK/pa" "$WORK/pb" "$WORK/pc" "$WORK/pd"

t_session s1 "$WORK/pa"
t_tmux send-keys -t s1 "$WORK/installs/claude/1.0.0/claude" Enter
t_tmux new-window -t s1 -c "$WORK/pb"
t_tmux send-keys -t s1:1 "claude" Enter
t_tmux new-window -t s1 -c "$WORK/pc"
t_tmux new-window -t s1 -c "$WORK/pd"
t_tmux send-keys -t s1:3 "bash $WORK/installs/gemini/0.5.0/gemini" Enter
n_agents() { [ "$(jq 'length' < <(claude agents --json))" = 2 ]; }
t_wait 10 n_agents
three_found() { [ "$(ar_discover "$WORK/dw" | wc -l | tr -d ' ')" = 3 ]; }
t_wait 10 three_found

expect "panes lists shells" 0 "s1:2.0" ar_panes
expect_eq "panes count" 4 "$(ar_panes | wc -l | tr -d ' ')"

mkdir -p "$WORK/d"
out=$(ar_discover "$WORK/d")
expect_eq "three agents found" 3 "$(echo "$out" | wc -l | tr -d ' ')"

rec() { echo "$out" | awk -F'\t' -v f="$1" '$4 == f'; }
f() { echo "$1" | cut -f"$2"; }
r1=$(rec pa); r2=$(rec pb); r3=$(rec pd)
expect_eq "old: type" claude "$(f "$r1" 5)"
expect_eq "old: running" 1.0.0 "$(f "$r1" 7)"
expect_eq "old: installed" 2.0.0 "$(f "$r1" 8)"
expect_eq "old: addr" "s1:0.0" "$(f "$r1" 3)"
expect_eq "old: argv file" "$WORK/d/$(f "$r1" 2).argv" "$(f "$r1" 11)"
expect_eq "old: argv exact" 1 "$(f "$r1" 13)"
expect_eq "old: pid numeric" 1 "$(f "$r1" 6 | grep -cE '^[0-9]+$')"
ar_outdated "$(f "$r1" 7)" "$(f "$r1" 8)" && ok=0 || ok=1
expect_eq "old: outdated" 0 "$ok"
expect_eq "new: running" 2.0.0 "$(f "$r2" 7)"
ar_outdated "$(f "$r2" 7)" "$(f "$r2" 8)" && ok=0 || ok=1
expect_eq "new: not outdated" 1 "$ok"
expect_eq "gemini: type" gemini "$(f "$r3" 5)"
expect_eq "gemini: running (interpreted)" 0.5.0 "$(f "$r3" 7)"
expect_eq "gemini: installed" 0.6.0 "$(f "$r3" 8)"
expect_eq "plain shell: no record" 0 "$(echo "$out" | awk -F'\t' '$4 == "pc"' | wc -l | tr -d ' ')"
expect_eq "agent cwd" "pa" "$(basename "$(f "$r1" 9)")"
expect_eq "parent pid numeric" 1 "$(f "$r1" 12 | grep -cE '^[0-9]+$')"
expect "running path" 0 "installs/claude/1.0.0/claude" ar_running_path "$(f "$r1" 6)"

# --- R5: version only from agent-owned path components
expect_eq "R5 claude versions dir" 2.1.318 "$(ar_version_from_path /h/.local/share/claude/versions/2.1.318)"
expect_eq "R5 gemini npm" 0.66.0 "$(ar_version_from_path /h/mise/installs/npm-google-gemini-cli/0.66.0/node_modules/x/gemini.js)"
expect_eq "R5 node version ignored" "" "$(ar_version_from_path /h/mise/installs/node/22.11.0/lib/node_modules/@openai/codex/bin/codex.js)"

# --- topmost selection on a synthetic ps snapshot
AR_PS_FILE="$WORK/ps.syn"
cat > "$AR_PS_FILE" <<'PS'
  100     1 sh
  101   100 node /usr/lib/node_modules/@openai/codex/bin/codex.js --foo
  102   101 /usr/lib/node_modules/@openai/codex/vendor/codex/codex --foo
  200     1 -zsh
  201   200 claude --resume x
  202   201 /opt/claude helper
  300     1 -zsh
  301   300 vim claude.txt
PS
expect_eq "topmost: codex wrapper over native child" $'101\tcodex' "$(ar_agent_in_pane 100)"
expect_eq "topmost: claude over its subprocess" $'201\tclaude' "$(ar_agent_in_pane 200)"
expect_eq "no agent in tree" "" "$(ar_agent_in_pane 300)"
unset AR_PS_FILE

# --- installed version: missing command
expect_eq "installed version missing command" "" "$(ar_installed_version no-such-agent-tool)"

# --- native binaries (lsof txt branch), rename, in-place upgrade
mknative() { mkdir -p "$WORK/installs/claude/$1"; cp /bin/sleep "$WORK/installs/claude/$1/claude"
  # macOS kills copied arm64e system binaries unless re-signed.
  ! command -v codesign >/dev/null || codesign -s - --force "$WORK/installs/claude/$1/claude" 2>/dev/null; }
mknative 3.0.0
mknative 4.0.0
mkdir -p "$WORK/pe" "$WORK/pf"
t_session s2 "$WORK/pe"
t_tmux send-keys -t s2 "$WORK/installs/claude/3.0.0/claude 300" Enter
t_tmux new-window -t s2 -c "$WORK/pf"
t_tmux send-keys -t s2:1 "$WORK/installs/claude/4.0.0/claude 300" Enter
native_up() { ar_discover "$WORK/dn" | awk -F'\t' '$4 == "pe"' | grep -q .; }
t_wait 10 native_up
ar_ps_snapshot
npid=$(ar_discover "$WORK/dn" | awk -F'\t' '$4 == "pe" { print $6 }')
expect "native running path via lsof txt" 0 "installs/claude/3.0.0/claude" ar_running_path "$npid"
expect_eq "native running version" 3.0.0 "$(ar_running_version "$npid")"

mv "$WORK/installs/claude/3.0.0" "$WORK/installs/claude/3.0.0.upgrading"
expect_eq "renamed running file keeps version" 3.0.0 "$(ar_running_version "$npid")"
rm -rf "$WORK/installs/claude/3.0.0.upgrading"
expect_eq "deleted running file keeps version" 3.0.0 "$(ar_running_version "$npid")"

sleep 1.2
touch "$WORK/installs/claude/4.0.0/claude"
out2=$(ar_discover "$WORK/dn")
expect_eq "R6 file newer than process: unknown version renders -" "-" "$(echo "$out2" | awk -F'\t' '$4 == "pf" { print $7 }')"

# --- interpreted npm agent: package.json supplies the version, not node's path
pk="$WORK/mise/installs/node/22.11.0/lib/node_modules/@openai/codex"
mkdir -p "$pk/bin" "$WORK/pg"
echo '{"name":"@openai/codex","version":"9.9.9"}' > "$pk/package.json"
printf 'sleep 300\n' > "$pk/bin/codex.js"
sleep 1.2
t_session s3 "$WORK/pg"
t_tmux send-keys -t s3 "bash $pk/bin/codex.js" Enter
codex_up() { ar_discover "$WORK/dc" | awk -F'\t' '$4 == "pg"' | grep -q .; }
t_wait 10 codex_up
out3=$(ar_discover "$WORK/dc")
expect_eq "npm codex: type" codex "$(echo "$out3" | awk -F'\t' '$4 == "pg" { print $5 }')"
expect_eq "npm codex: version from package.json" 9.9.9 "$(echo "$out3" | awk -F'\t' '$4 == "pg" { print $7 }')"

# --- regression: agent vanishes between snapshot and lsof, under set -euo pipefail
ppid_c=$(ar_panes | awk -F'\t' '$3 == "s1:2.0" { print $4 }')
ar_ps_snapshot() {
  AR_PS_FILE="$WORK/ps.vanish"
  ps -A -o pid=,ppid=,args= > "$AR_PS_FILE"
  echo "99999 $ppid_c claude" >> "$AR_PS_FILE"
}
set +e
( set -euo pipefail; ar_discover "$WORK/dv" > "$WORK/dv.out" ); vrc=$?
set -e
expect_eq "discover survives vanished agent (rc)" 0 "$vrc"
expect_eq "vanished agent yields no record" 0 "$(awk -F'\t' '$6 == 99999' "$WORK/dv.out" | wc -l | tr -d ' ')"
source lib/agents-restart/discover.sh

t_done
