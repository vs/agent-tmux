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
sleep 1

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

t_done
