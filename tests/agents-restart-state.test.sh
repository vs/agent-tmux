#!/usr/bin/env bash
# Tests for agents-restart Claude state, background work and session IDs.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/agents-restart-lib.sh"
t_setup
cd "$T_REPO"
source lib/agents-restart/common.sh
source lib/agents-restart/discover.sh
source lib/agents-restart/state.sh

E=$'\033'
RULE=$(printf '─%.0s' $(seq 1 40))
NB=$'\xc2\xa0'
box() { printf '%s\n%s\n%s\n%s\n' "$RULE" "$1" "$RULE" "$2"; }
FOOT="  ⏵⏵ auto mode on (shift+tab to cycle)"

# --- ar_input_text ---
ph="${E}[39m❯${NB} ${E}[2mTry${E}[0m ${E}[2m\"refactor${E}[0m ${E}[2mNavigation.tsx\"${E}[0m"
expect_eq "placeholder reads as empty" "" "$(ar_input_text "$(box "$ph" "$FOOT")")"
expect_eq "bare prompt reads as empty" "" "$(ar_input_text "$(box '❯ ' "$FOOT")")"
expect_eq "real draft" "fix the tests" "$(ar_input_text "$(box '❯ fix the tests' "$FOOT")")"
expect_eq "draft with SGR and nbsp" "fix it" "$(ar_input_text "$(box "${E}[39m❯${NB} ${E}[0mfix it" "$FOOT")")"
expect_eq "draft then dim suffix" "fix" "$(ar_input_text "$(box "❯ fix${E}[2m hint${E}[22m" "$FOOT")")"
expect_eq "dim ends with bare reset m" "x" "$(ar_input_text "$(box "❯ ${E}[2mhint${E}[mx" "$FOOT")")"
expect_eq "256-color 38;5;2 is not dim" "red" "$(ar_input_text "$(box "❯ ${E}[38;5;2mred${E}[0m" "$FOOT")")"
expect_eq "truecolor 38;2;2;2;2 is not dim" "rgb" "$(ar_input_text "$(box "❯ ${E}[38;2;2;2;2mrgb${E}[0m" "$FOOT")")"
expect_eq "OSC and other CSI stripped" "hi" "$(ar_input_text "$(box "❯ ${E}]8;;http://x${E}\\${E}[?25h${E}[1Khi" "$FOOT")")"
expect_eq "multi-line draft" "line one line two" "$(ar_input_text "$(printf '%s\n❯ line one\n  line two\n%s\n%s\n' "$RULE" "$RULE" "$FOOT")")"
expect_eq "old output above box ignored" "" "$(ar_input_text "$(printf '❯ old prompt\n%s\n%s\n%s\n%s\n%s\n' "$RULE" '❯ ' "$RULE" "$FOOT" "")")"
expect_eq "no box: last prompt line" "abc" "$(ar_input_text "❯ abc")"

# --- ar_claude_background ---
expect_eq "no background" "" "$(ar_claude_background "$(box '❯ ' "$FOOT")")"
expect_eq "1 shell" "1 shell" "$(ar_claude_background "$(box '❯ ' "  ⏵⏵ auto mode on · 1 shell")")"
expect_eq "colored footer" "2 background tasks" "$(ar_claude_background "$(box '❯ ' "  ${E}[2m⏵⏵ auto mode on ·${E}[0m 2 background tasks")")"
expect_eq "several kinds" "1 shell, 2 monitors" "$(ar_claude_background "$(box '❯ ' "  ⏵⏵ auto mode on · 1 shell · 2 monitors")")"
expect_eq "status line percent is not background" "" "$(ar_claude_background "$(box '❯ ' "  tmux │ ⎇ main │ 25% ▓▓ → 01:50 AM   /rc
$FOOT")")"
expect_eq "text in box ignored" "" "$(ar_claude_background "$(box '❯ run 3 agents · 2 shells' "$FOOT")")"
expect_eq "subagent rows" "2 subagents" "$(ar_claude_background "$(box '❯ ' "$FOOT
  ⏺ main
  ◯ general-purpose  Task one   31s · ↓ 59.2k tokens
  ◯ Explore  Task two   1s · ↓ 1k tokens")")"

# --- ar_is_teammate ---
printf 'claude\0--agent-id\0helper-a@s\0--team-name\0t\0' > "$WORK/tm.argv"
printf 'claude\0--model\0haiku\0' > "$WORK/plain.argv"
printf 'claude\0--team-name=t\0' > "$WORK/tm2.argv"
printf 'claude\0--append-system-prompt\0--agent-id\0' > "$WORK/tm3.argv"
expect "teammate argv" 0 "" ar_is_teammate "$WORK/tm.argv"
expect "teammate eq form" 0 "" ar_is_teammate "$WORK/tm2.argv"
expect "plain argv" 1 "" ar_is_teammate "$WORK/plain.argv"
expect "missing argv file" 1 "" ar_is_teammate "$WORK/nope.argv"

# --- ar_claude_refresh / session ids / ar_state end to end ---
t_install_fake claude 2.0.0
t_use_version claude 2.0.0
mkdir -p "$WORK/pa" "$WORK/pb"
t_session s1 "$WORK/pa"
t_tmux send-keys -t s1 "claude" Enter
t_tmux new-window -t s1 -c "$WORK/pb"
t_tmux send-keys -t s1:1 "claude --agent-id helper-a@s --agent-name helper-a --team-name t --model haiku" Enter
t_tmux new-window -t s1 -c "$WORK/pb"
t_tmux send-keys -t s1:2 "claude" Enter
t_tmux new-window -t s1 -c "$WORK/pb"
t_tmux send-keys -t s1:3 "claude" Enter
t_tmux new-window -t s1 -c "$WORK/pb"
t_tmux send-keys -t s1:4 "claude" Enter
four() { [ "$(ar_discover "$WORK/d0" | wc -l | tr -d ' ')" = 5 ]; }
t_wait 15 four
mkdir -p "$WORK/d"
ar_discover "$WORK/d" > "$WORK/d.tsv"
rec() { awk -F'\t' -v a="$1" '$3 == a' "$WORK/d.tsv"; }
fld() { echo "$1" | cut -f"$2"; }
R0=$(rec s1:0.0); R1=$(rec s1:1.0); R2=$(rec s1:2.0); R3=$(rec s1:3.0); R4=$(rec s1:4.0)
P0=$(fld "$R0" 6); P1=$(fld "$R1" 6); P2=$(fld "$R2" 6); P3=$(fld "$R3" 6); P4=$(fld "$R4" 6)
st() { # st <record> -> ar_state for that record
  ar_state claude "$(fld "$1" 1)" "$(fld "$1" 2)" "$(fld "$1" 6)" "$(fld "$1" 11)"
}
setscreen() { printf '%s' "$2" > "$WORK/screen/$1"; }
screen_has() { ar_screen "$(fld "$1" 1)" "$(fld "$1" 2)" | grep -q "$2"; }

ar_claude_refresh
expect_eq "refresh has rows" 1 "$(echo "$AR_CLAUDE_TSV" | grep -c "^$P0	idle	-	fake-$P0$")"
expect_eq "session id" "fake-$P0" "$(ar_session_id claude "$P0" /x)"
expect_eq "session id unknown pid" "-" "$(ar_session_id claude 999999 /x)"
FAKE_AGENTS_FAIL=1 ar_claude_refresh
expect_eq "refresh failure leaves empty" "" "$AR_CLAUDE_TSV"
expect_eq "session id after failure" "-" "$(ar_session_id claude "$P0" /x)"
expect_eq "state after failure is not idle" "busy:status unknown" "$(FAKE_AGENTS_FAIL=1 ar_claude_refresh; st "$R0")"

# idle with placeholder (the fake's default screen is a bare prompt; draw the placeholder)
setscreen "$P0" "$(box "$ph" "$FOOT")"
t_wait 5 screen_has "$R0" "Try" || echo "screen not drawn"
ar_claude_refresh
expect_eq "idle with placeholder" idle "$(st "$R0")"

# unsent
setscreen "$P0" "$(box '❯ fix the tests' "$FOOT")"
t_wait 5 screen_has "$R0" "fix the tests"
expect_eq "unsent draft" unsent "$(st "$R0")"

# background footer
setscreen "$P0" "$(box '❯ ' "  ⏵⏵ auto mode on · 1 shell")"
t_wait 5 screen_has "$R0" "1 shell"
expect_eq "busy with shell" "busy:1 shell" "$(st "$R0")"
setscreen "$P0" "$(box '❯ fix the tests' "  ⏵⏵ auto mode on · 1 shell")"
t_wait 5 screen_has "$R0" "fix the tests"
expect_eq "background beats unsent" "busy:1 shell" "$(st "$R0")"

# json status
setscreen "$P0" "$(box '❯ ' "$FOOT")"
t_agent_set "$P0" '{"status":"busy"}'; ar_claude_refresh
expect_eq "status busy" busy "$(st "$R0")"
t_agent_set "$P0" '{"status":"idle","waitingFor":"approve"}'; ar_claude_refresh
expect_eq "waitingFor prompt" prompt "$(st "$R0")"
t_agent_set "$P0" '{"status":"waiting"}'; ar_claude_refresh
expect_eq "status waiting prompt" prompt "$(st "$R0")"
t_agent_set "$P0" '{"status":"waiting","waitingFor":"approve"}'; ar_claude_refresh
expect_eq "waiting row waitingFor" "$P0	waiting	approve	fake-$P0" "$(echo "$AR_CLAUDE_TSV" | grep "^$P0	")"
t_agent_set "$P0" '{"status":"idle"}'

# teammate pane and a lead in the same window
expect_eq "teammate pane" teammate "$(st "$R1")"
expect "has_teammates false for a lone window" 1 "" ar_has_teammates "$(fld "$R2" 1)" "$(fld "$R2" 2)" "$P2"
t_tmux split-window -t s1:2 -c "$WORK/pb" "claude --agent-id helper-b@s --team-name t"
two_in_win() { [ "$(t_tmux list-panes -t s1:2 | wc -l | tr -d ' ')" = 2 ]; }
t_wait 5 two_in_win
setscreen "$P2" "$(box '❯ ' "$FOOT")"
sleep 1
expect "has_teammates true" 0 "" ar_has_teammates "$(fld "$R2" 1)" "$(fld "$R2" 2)" "$P2"
ar_claude_refresh
expect_eq "lead with live teammates" "busy:teammates" "$(st "$R2")"
expect "has_teammates ignores other windows" 1 "" ar_has_teammates "$(fld "$R3" 1)" "$(fld "$R3" 2)" "$P3"

# trailing blank lines are trimmed
setscreen "$P4" "$(box '❯ ' "$FOOT")
"
t_wait 5 screen_has "$R4" "auto mode"
expect_eq "trailing blanks trimmed" "$FOOT" "$(ar_screen "$(fld "$R4" 1)" "$(fld "$R4" 2)" | tail -1 | sed 's/\x1b\[[0-9;]*m//g')"

t_done
