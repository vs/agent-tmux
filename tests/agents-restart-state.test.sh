#!/usr/bin/env bash
# Tests for agents-restart Claude state, background work and session IDs.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/agents-restart-lib.sh"
t_setup
cd "$T_REPO"
source lib/agents-restart/common.sh
source lib/agents-restart/discover.sh
source lib/agents-restart/state.sh
source lib/agents-restart/sessions.sh

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
expect_eq "no box: no text" "" "$(ar_input_text "❯ abc")"
expect "no box is not ok" 1 "" ar_input_box_ok "❯ abc"
expect "box is ok" 0 "" ar_input_box_ok "$(box '❯ ' "$FOOT")"
expect "bash mode box (no prompt glyph) is not ok" 1 "" ar_input_box_ok "$(box '! rm -rf x' "$FOOT")"
expect "one rule only is not ok" 1 "" ar_input_box_ok "$(printf '%s\n❯ \n%s\n' "$RULE" "$FOOT")"
DIALOG=$(printf 'Do you want to proceed?\n❯ 1. Yes\n  2. No\n')
expect "dialog is not an input box" 1 "" ar_input_box_ok "$DIALOG"
expect_eq "dim rules still identify box" "hi" "$(ar_input_text "$(box "❯ hi" "$FOOT" | sed "s/^─/${E}[2m─/; s/─\$/─${E}[0m/")")"
expect_eq "other non-dim line in box counts as text" "note hi" "$(ar_input_text "$(printf '%s\n  note\n❯ hi\n%s\n%s\n' "$RULE" "$RULE" "$FOOT")")"
expect_eq "background noun without dot" "1 shell" "$(ar_claude_background "$(box '❯ ' "  1 shell running")")"

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
expect_eq "AR_CLAUDE_OK 0 after failure" 0 "$AR_CLAUDE_OK"
expect_eq "state after failure" "busy:status unavailable" "$(FAKE_AGENTS_FAIL=1 ar_claude_refresh; st "$R0")"
ar_claude_refresh
expect_eq "AR_CLAUDE_OK 1 after success" 1 "$AR_CLAUDE_OK"
AR_CLAUDE_TSV=$(echo "$AR_CLAUDE_TSV" | grep -v "^$P0	")
expect_eq "pid missing from good listing" unlisted "$(st "$R0")"
ar_claude_refresh

# idle with placeholder (the fake's default screen is a bare prompt; draw the placeholder)
setscreen "$P0" "$(box "$ph" "$FOOT")"
t_wait 5 screen_has "$R0" "Try" || echo "screen not drawn"
ar_claude_refresh
expect_eq "idle with placeholder" idle "$(st "$R0")"

# dialog / missing box with json idle must not be idle
setscreen "$P0" "$DIALOG"
t_wait 5 screen_has "$R0" "Do you want"
expect_eq "dialog with json idle" unrecognized "$(st "$R0")"
setscreen "$P0" "$(printf '%s\n! rm -rf x\n%s\n%s\n' "$RULE" "$RULE" "$FOOT")"
t_wait 5 screen_has "$R0" "rm -rf"
expect_eq "bash-mode box with json idle" unrecognized "$(st "$R0")"
setscreen "$P0" "$(box "$ph" "$FOOT")"
t_wait 5 screen_has "$R0" "Try"

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
t_agent_set "$P0" '{"status":"compacting"}'; ar_claude_refresh
expect_eq "unknown status is busy" "busy:compacting" "$(st "$R0")"
t_agent_set "$P0" '{"status":null}'; ar_claude_refresh
expect_eq "null status" "busy:status unknown" "$(st "$R0")"
t_agent_set "$P0" '{"status":5,"sessionId":7}'; ar_claude_refresh
expect_eq "non-string fields tolerated" "busy:5" "$(st "$R0")"
expect_eq "other rows survive odd entry" 1 "$(echo "$AR_CLAUDE_TSV" | grep -c "^$P2	")"
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

# ===== Codex and Gemini =====================================================
FX="$T_REPO/tests/fixtures/agents-restart"
fx() { cat "$FX/$1.screen"; }
sst() { _ar_screen_state "$1" "$2"; }

# --- Codex screens (captured from codex-cli 0.166.0, paths sanitized) ---
expect_eq "codex idle (dim placeholder)" idle "$(sst codex "$(fx codex-idle)")"
expect_eq "codex unsent" unsent "$(sst codex "$(fx codex-unsent)")"
expect_eq "codex working" busy "$(sst codex "$(fx codex-busy)")"
expect_eq "codex background terminal" "busy:1 background terminal" "$(sst codex "$(fx codex-bgterm)")"
expect_eq "codex approval" prompt "$(sst codex "$(fx codex-approval)")"
expect_eq "codex hooks dialog" unrecognized "$(sst codex "$(fx codex-hooks)")"
expect_eq "codex permissions menu" unrecognized "$(sst codex "$(fx codex-permissions)")"
expect_eq "codex rate-limit modal" unrecognized "$(sst codex "$(fx codex-ratemodal)")"
CFOOT="  ${E}[38;2;246;226;183mGPT-5 high${E}[39m · /Users/me/proj"
cbox() { printf '%s\n' "• ok" "" "$1" "" "$CFOOT"; }
expect_eq "codex bare prompt" idle "$(sst codex "$(cbox "${E}[1m›${E}[0m ")")"
expect_eq "codex other dim placeholder" idle "$(sst codex "$(cbox "${E}[1m›${E}[0m ${E}[2mFind and fix a bug in @filename${E}[0m")")"
expect_eq "codex draft after blank lines" unsent "$(sst codex "$(printf '%s\n' "• ok" "" "› " "  " "  third line" "" "$CFOOT")")"
expect_eq "codex multi-line draft" unsent "$(sst codex "$(printf '%s\n' "• ok" "" "› " "  second line" "" "$CFOOT")")"
expect_eq "codex numbered draft is not trusted" unrecognized "$(sst codex "$(cbox "› 1. fix it")")"
expect_eq "codex prompt line without footer gap" unrecognized "$(sst codex "$(printf '%s\n' "• ok" "" "› ")")"
expect_eq "codex no prompt line" unrecognized "$(sst codex "$(printf '%s\n' "• ok" "" "$CFOOT")")"
expect_eq "codex too much below prompt" unrecognized "$(sst codex "$(printf '%s\n' "› " "" a b c d)")"
expect_eq "codex old busy text scrolled away" idle "$(sst codex "$(printf '%s\n' "(1s • esc to interrupt)" 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 "" "› " "" "$CFOOT")")"
expect_eq "codex waiting for background terminal" busy "$(sst codex "$(cbox "› " | sed '1s/.*/• Waiting for background terminal/')")"
expect_eq "codex two background terminals" "busy:2 background terminals" "$(sst codex "$(printf '%s\n' "  2 background terminals running · /ps to view" "" "› " "" "$CFOOT")")"

# --- Gemini screens (built from gemini-cli 0.67.0 source; trust/auth captured live) ---
GTOP="${E}[38;2;30;30;46m$(printf '▄%.0s' $(seq 1 60))${E}[39m"
GBOT="${E}[38;2;30;30;46m$(printf '▀%.0s' $(seq 1 60))${E}[39m"
GPH=" ${E}[38;2;203;166;247m> ${E}[39m${E}[7m ${E}[27m${E}[38;2;108;112;134m Type your message or @path/to/file${E}[39m"
GFOOT=" ~/proj (main*)          no sandbox          gemini-3-pro"
gscreen() { # gscreen <status line> <input line> [box top] [box bottom]
  printf '%s\n' "✦ ok" "" "$1" "${3-$GTOP}" "$2" "${4-$GBOT}" "$GFOOT"
}
expect_eq "gemini idle (gray placeholder)" idle "$(sst gemini "$(gscreen "" "$GPH")")"
expect_eq "gemini idle, padded box" idle "$(sst gemini "$(gscreen "" "$GPH" "" "")")"
expect_eq "gemini idle, line border" idle "$(sst gemini "$(gscreen "" "$GPH" "$(printf '─%.0s' $(seq 1 60))" "")")"
expect_eq "gemini idle, unfocused placeholder" idle "$(sst gemini "$(gscreen "" " > ${E}[38;2;108;112;134m  Type your message or @path/to/file${E}[39m")")"
expect_eq "gemini yolo prompt" idle "$(sst gemini "$(gscreen "" " * ${E}[38;2;108;112;134m  Type your message or @path/to/file${E}[39m")")"
expect_eq "gemini vim insert placeholder" idle "$(sst gemini "$(gscreen "" " > ${E}[38;2;108;112;134m  Press 'Esc' for NORMAL mode.${E}[39m")")"
expect_eq "gemini vim normal mode not trusted" unrecognized "$(sst gemini "$(gscreen "" " > ${E}[38;2;108;112;134m  Press 'i' for INSERT mode.${E}[39m")")"
expect_eq "gemini shell mode not trusted" unrecognized "$(sst gemini "$(gscreen "" " ! ${E}[38;2;108;112;134m  Type your shell command${E}[39m")")"
expect_eq "gemini unsent" unsent "$(sst gemini "$(gscreen "" " > fix the tests")")"
expect_eq "gemini multi-line draft" unsent "$(sst gemini "$(printf '%s\n' "✦ ok" "" "$GTOP" " > " "   second" "$GBOT" "$GFOOT")")"
expect_eq "gemini draft after blank lines" unsent "$(sst gemini "$(printf '%s\n' "✦ ok" "" "$GTOP" " > " "   " "   third" "$GBOT" "$GFOOT")")"
expect_eq "gemini padded draft after blank lines" unsent "$(sst gemini "$(printf '%s\n' "✦ ok" "" "" " > " "   " "   third" "" "$GFOOT")")"
expect_eq "gemini busy" busy "$(sst gemini "$(gscreen "⠋ Thinking... (esc to cancel, 3s)" "$GPH")")"
expect_eq "gemini background process" "busy:1 background process" "$(sst gemini "$(gscreen " 1 GEMINI.md file | 1 Background process" "$GPH")")"
GAPPROVE=$(printf '%s\n' "╭──────────────────────────╮" "│ ?  Shell ls              │" "│ Allow execution of: 'ls'?│" "│ ● 1. Allow once          │" "│   2. Allow for this session" "╰──────────────────────────╯")
expect_eq "gemini approval" prompt "$(sst gemini "$GAPPROVE
$(gscreen "" "$GPH")")"
expect_eq "gemini trust dialog" unrecognized "$(sst gemini "$(fx gemini-trust)")"
expect_eq "gemini auth dialog" prompt "$(sst gemini "$(fx gemini-auth)")"
expect_eq "gemini no box above prompt" unrecognized "$(sst gemini "$(printf '%s\n' "✦ ok" "text" "$GPH" "$GBOT" "$GFOOT")")"
expect_eq "gemini no box below prompt" unrecognized "$(sst gemini "$(printf '%s\n' "✦ ok" "$GTOP" "$GPH" "$GFOOT")")"

# --- ar_state end to end for codex (screen read through tmux) ---
t_install_fake codex 0.166.0; t_use_version codex 0.166.0
t_install_fake gemini 0.67.0; t_use_version gemini 0.67.0
real() { (cd "$1" && pwd -P); }
pane_agent() { ar_ps_snapshot; ar_agent_in_pane "$(t_tmux display-message -p -t "$1" '#{pane_pid}')" | cut -f1; }
started() { [ -n "$(pane_agent "$1")" ]; }
# start <target-window> <dir> <cmd>: run cmd in a new window; prints the agent pid.
start() {
  t_tmux new-window -d -t "$1" -c "$2"
  t_tmux send-keys -t "$1" "$3" Enter
  t_wait 10 started "$1" || { echo "agent in $1 did not start" >&2; return 1; }
  pane_agent "$1"
}
mkdir -p "$WORK/c0"
t_session s2 "$WORK/c0"
CP0=$(start s2:1 "$WORK/c0" "codex")
setscreen "$CP0" "$(fx codex-busy)"
cscreen_has() { ar_screen "$SWARM_TMUX_SOCKET" s2:1 | grep -q "$1"; }
t_wait 5 cscreen_has "Working" || echo "codex screen not drawn"
expect_eq "ar_state codex busy" busy "$(ar_state codex "$SWARM_TMUX_SOCKET" s2:1 "$CP0" /dev/null)"
setscreen "$CP0" "$(fx codex-idle)"
cscreen_lacks() { ! cscreen_has "$1"; }
t_wait 5 cscreen_lacks "Working" || echo "codex screen not drawn"
expect_eq "ar_state codex idle" idle "$(ar_state codex "$SWARM_TMUX_SOCKET" s2:1 "$CP0" /dev/null)"

# --- ar_session_id codex: rollout held open ---
export CODEX_HOME="$WORK/codex"
ROLL="$CODEX_HOME/sessions/2026/11/05/rollout-2026-11-05T10-00-00-019b8601-9767-7a90-86f1-d14b21a74e7e.jsonl"
mkdir -p "$(dirname "$ROLL")" "$WORK/elsewhere"
bash -c 'exec 3>"$1"; sleep 30' _ "$ROLL" & HOLD=$!; disown
bash -c 'exec 3>"$1"; sleep 30' _ "$WORK/elsewhere/rollout-2026-11-05T10-00-00-019b8601-9767-7a90-86f1-d14b21a74e7f.jsonl" & HOLD2=$!; disown
holding() { lsof -p "$1" -Fn 2>/dev/null | grep -q rollout; }
t_wait 5 holding "$HOLD"; t_wait 5 holding "$HOLD2"
expect_eq "codex session id from open rollout" 019b8601-9767-7a90-86f1-d14b21a74e7e "$(ar_session_id codex "$HOLD" /x)"
expect_eq "codex rollout outside codex home ignored" - "$(ar_session_id codex "$HOLD2" /x)"
kill "$HOLD" "$HOLD2" 2>/dev/null || true

# --- ar_session_id codex: rollouts by cwd and start time (shared app-server daemon) ---
# mkroll <epoch> <uuid> <cwd> [jq filter]: rollout as Codex names it (local time).
mkroll() {
  local ep="$1" id="$2" cwd="$3" f="${4:-.}" ts d iso
  ts=$(date -r "$ep" +%Y-%m-%dT%H-%M-%S); d=$(date -r "$ep" +%Y/%m/%d)
  iso=$(date -u -r "$ep" +%Y-%m-%dT%H:%M:%S.176Z)
  mkdir -p "$CODEX_HOME/sessions/$d"
  jq -nc --arg id "$id" --arg ts "$iso" --arg cwd "$cwd" \
    '{timestamp: $ts, type: "session_meta", payload: {id: $id, timestamp: $ts, cwd: $cwd, originator: "codex-tui", source: "cli", thread_source: "user"}}' |
    jq -c "$f" > "$CODEX_HOME/sessions/$d/rollout-$ts-$id.jsonl"
  echo '{"type":"turn_context"}' >> "$CODEX_HOME/sessions/$d/rollout-$ts-$id.jsonl"
}
rmroll() { find "$CODEX_HOME/sessions" -name "*$1*" -exec rm -f {} +; }
U1=01a1adff-8398-72b1-b333-af3dfa74feb1; U2=01a1adff-8398-72b1-b333-af3dfa74feb2
U3=01a1adff-8398-72b1-b333-af3dfa74feb3; U5=01a1adff-8398-72b1-b333-af3dfa74feb5
U6=01a1adff-8398-72b1-b333-af3dfa74feb6; U9=01a1adff-8398-72b1-b333-af3dfa74feb9
mkdir -p "$WORK/c1" "$WORK/c2" "$WORK/c3"
D1=$(real "$WORK/c1"); D2=$(real "$WORK/c2"); D3=$(real "$WORK/c3")
CA=$(start s2:2 "$D1" "codex")
SA=$(_ar_start_epoch "$CA")
expect_eq "codex no rollout yet" - "$(ar_session_id codex "$CA" "$D1")"
mkroll "$SA" "$U1" "$D1"
expect_eq "codex rollout created since start" "$U1" "$(ar_session_id codex "$CA" "$D1")"
mkroll $((SA - 50)) "$U9" "$D1"
mkroll $((SA + 3)) "$U2" "$D2"
mkroll $((SA + 4)) "$U3" "$D1" '.payload.thread_source = "subagent"'
mkroll $((SA + 4)) "$U5" "$D1" '.payload.source = "exec"'
mkroll $((SA + 4)) "$U6" "$D1" '.payload.source = {"subagent": "x"}'
expect_eq "codex ignores older, other-cwd, subagent and exec rollouts" "$U1" "$(ar_session_id codex "$CA" "$D1")"
rmroll "$U3"; rmroll "$U5"; rmroll "$U6"
mkroll $((SA + 5)) "$U3" "$D1"
expect_eq "codex two rollouts since start is ambiguous" - "$(ar_session_id codex "$CA" "$D1")"
rmroll "$U3"
sleep 1.2
CB=$(start s2:3 "$D1" "codex")
SB=$(_ar_start_epoch "$CB")
expect_eq "codex older peer keeps its own rollout" "$U1" "$(ar_session_id codex "$CA" "$D1")"
expect_eq "codex younger peer without rollout" - "$(ar_session_id codex "$CB" "$D1")"
mkroll "$SB" "$U3" "$D1"
expect_eq "codex rollout after both starts is ambiguous (older)" - "$(ar_session_id codex "$CA" "$D1")"
expect_eq "codex rollout after both starts is ambiguous (younger)" - "$(ar_session_id codex "$CB" "$D1")"
CC=$(start s2:4 "$D2" "codex -m o3 resume $U2")
expect_eq "codex resumed by uuid" "$U2" "$(ar_session_id codex "$CC" "$D2")"
echo "{\"id\":\"$U6\",\"thread_name\":\"my thread\",\"updated_at\":\"2026-11-05T23:16:32Z\"}" >> "$CODEX_HOME/session_index.jsonl"
mkroll $((SA - 500)) "$U6" "$D3"
CD=$(start s2:5 "$D3" "codex resume 'my thread'")
expect_eq "codex resumed by session name" "$U6" "$(ar_session_id codex "$CD" "$D3")"
mkdir -p "$WORK/c4"; D4=$(real "$WORK/c4")
CE=$(start s2:6 "$D4" "codex resume --last")
expect_eq "codex resume --last is unknown" - "$(ar_session_id codex "$CE" "$D4")"
CF=$(start s2:7 "$D4" "codex resume 01a1adff-0000-0000-0000-000000000000")
expect_eq "codex resume of a missing session" - "$(ar_session_id codex "$CF" "$D4")"

# --- ar_session_id gemini ---
GH="$HOME/.gemini"
# gproj <dir> <slug>: register a project directory the way Gemini 0.67 does.
gproj() { mkdir -p "$GH/tmp/$2/chats"; printf '%s' "$1" > "$GH/tmp/$2/.project_root"; }
# mkgs <chats dir> <start epoch> <uuid> <resumable 0|1> [kind]: session file as Gemini names it.
mkgs() {
  local dir="$1" ep="$2" id="$3" res="$4" kind="${5:-main}" ts iso f
  ts=$(date -u -r "$ep" +%Y-%m-%dT%H-%M); iso=$(date -u -r "$ep" +%Y-%m-%dT%H:%M:%S.500Z)
  f="$dir/session-$ts-${id:0:8}.jsonl"
  jq -nc --arg id "$id" --arg t "$iso" --arg k "$kind" \
    '{sessionId: $id, projectHash: "h", startTime: $t, lastUpdated: $t, kind: $k}' > "$f"
  if [[ "$res" == 1 ]]; then
    jq -nc --arg t "$iso" '{id: "m1", timestamp: $t, type: "user", content: [{text: "reply with ok"}]}' >> "$f"
    jq -nc --arg t "$iso" '{id: "m2", timestamp: $t, type: "gemini", content: "ok"}' >> "$f"
  else
    jq -nc --arg t "$iso" '{id: "m1", timestamp: $t, type: "user", content: [{text: "/help"}]}' >> "$f"
  fi
  echo "$f"
}
V1=7b0c1d2e-0000-4000-8000-000000000001; V2=7b0c1d2e-0000-4000-8000-000000000002
V3=7b0c1d2e-0000-4000-8000-000000000003; V4=7b0c1d2e-0000-4000-8000-000000000004
V5=7b0c1d2e-0000-4000-8000-000000000005; V6=7b0c1d2e-0000-4000-8000-000000000006
V7=7b0c1d2e-0000-4000-8000-000000000007; V8=7b0c1d2e-0000-4000-8000-000000000008
for i in 1 2 3 4 5 6 7 8; do mkdir -p "$WORK/g$i"; done
E1=$(real "$WORK/g1"); E2=$(real "$WORK/g2"); E3=$(real "$WORK/g3"); E4=$(real "$WORK/g4")
E5=$(real "$WORK/g5"); E6=$(real "$WORK/g6"); E7=$(real "$WORK/g7"); E8=$(real "$WORK/g8")
t_session s3 "$E1"
GA=$(start s3:1 "$E1" "gemini"); SGA=$(_ar_start_epoch "$GA")
gproj "$E1" g1
expect_eq "gemini no session file: latest" latest "$(ar_session_id gemini "$GA" "$E1")"
mkgs "$GH/tmp/g1/chats" $((SGA - 900)) "$V8" 1 >/dev/null
mkgs "$GH/tmp/g1/chats" "$SGA" "$V1" 1 >/dev/null
mkdir -p "$GH/tmp/g1/chats/$V1"; mkgs "$GH/tmp/g1/chats/$V1" $((SGA + 2)) "$V7" 1 subagent >/dev/null
expect_eq "gemini session started since agent start" "$V1" "$(ar_session_id gemini "$GA" "$E1")"
GB=$(start s3:2 "$E2" "gemini"); SGB=$(_ar_start_epoch "$GB")
gproj "$E2" g2
mkgs "$GH/tmp/g2/chats" $((SGB - 900)) "$V8" 1 >/dev/null
mkgs "$GH/tmp/g2/chats" "$SGB" "$V2" 0 >/dev/null
expect_eq "gemini own session not resumable yet" - "$(ar_session_id gemini "$GB" "$E2")"
GC=$(start s3:3 "$E3" "gemini")
expect_eq "gemini project unknown: latest" latest "$(ar_session_id gemini "$GC" "$E3")"
GD=$(start s3:4 "$E4" "gemini"); SGD=$(_ar_start_epoch "$GD")
H4=$(printf '%s' "$E4" | shasum -a 256 | cut -d' ' -f1); mkdir -p "$GH/tmp/$H4/chats"
mkgs "$GH/tmp/$H4/chats" "$SGD" "$V4" 1 >/dev/null
expect_eq "gemini legacy hash directory" "$V4" "$(ar_session_id gemini "$GD" "$E4")"
GE=$(start s3:5 "$E5" "gemini"); SGE=$(_ar_start_epoch "$GE")
gproj "$E5" g5
mkgs "$GH/tmp/g5/chats" "$SGE" "$V5" 1 >/dev/null
sleep 1.2
GF=$(start s3:6 "$E5" "gemini")
expect_eq "gemini older peer keeps its session" "$V5" "$(ar_session_id gemini "$GE" "$E5")"
expect_eq "gemini younger peer: ambiguous" - "$(ar_session_id gemini "$GF" "$E5")"
gproj "$E6" g6
F6=$(mkgs "$GH/tmp/g6/chats" $((SGA - 3000)) "$V6" 1)
mkgs "$GH/tmp/g6/chats" $((SGA - 2000)) "$V3" 1 >/dev/null
touch -t "$(date -r $((SGA - 1000)) +%Y%m%d%H%M.%S)" "$GH/tmp/g6/chats/"*
GG=$(start s3:7 "$E6" "gemini -r latest -m pro")
touch "$F6"
expect_eq "gemini -r latest: the session written since start" "$V6" "$(ar_session_id gemini "$GG" "$E6")"
gproj "$E7" g7
mkgs "$GH/tmp/g7/chats" $((SGA - 3000)) "$V7" 1 >/dev/null
GI=$(start s3:8 "$E7" "gemini --resume $V7")
expect_eq "gemini --resume uuid" "$V7" "$(ar_session_id gemini "$GI" "$E7")"
expect_eq "gemini vanished pid" - "$(ar_session_id gemini 999999 "$E7")"
expect_eq "codex vanished pid" - "$(ar_session_id codex 999999 "$E7")"
gproj "$E8" g8
GJ=$(start s3:9 "$E8" "gemini"); SGJ=$(_ar_start_epoch "$GJ")
jq -n --arg id "$V8" --arg t "$(date -u -r "$SGJ" +%Y-%m-%dT%H:%M:%S.000Z)" \
  '{sessionId: $id, startTime: $t, lastUpdated: $t, messages: [{type: "user", content: "hi"}]}' \
  > "$GH/tmp/g8/chats/session-$(date -u -r "$SGJ" +%Y-%m-%dT%H-%M)-${V8:0:8}.json"
expect_eq "gemini legacy .json session" "$V8" "$(ar_session_id gemini "$GJ" "$E8")"

t_done
