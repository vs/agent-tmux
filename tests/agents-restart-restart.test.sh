#!/usr/bin/env bash
# Tests for ar_restart_one: quit an idle agent and type its resume command.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/agents-restart-lib.sh"
t_setup
cd "$T_REPO"
source lib/agents-restart/common.sh
source lib/agents-restart/discover.sh
source lib/agents-restart/state.sh
source lib/agents-restart/sessions.sh
source lib/agents-restart/resume.sh
source lib/agents-restart/restart.sh

RULE=$(printf '─%.0s' $(seq 1 40))
IDLE=$(printf '%s\n❯ \n%s\n  ⏵⏵ auto mode on (shift+tab to cycle)\n' "$RULE" "$RULE")
setscreen() { printf '%s' "$2" > "$WORK/screen/$1"; }
fld() { echo "$1" | cut -f"$2"; }

t_install_fake claude 1.0.0
t_install_fake claude 2.0.0
t_use_version claude 1.0.0
mkdir -p "$WORK/pa"
t_session s1 "$WORK/pa"
for w in 1 2 3 4 5; do t_tmux new-window -t s1 -c "$WORK/pa"; done
t_tmux send-keys -t s1:0 "claude" Enter
t_tmux send-keys -t s1:1 "claude" Enter
t_tmux send-keys -t s1:2 "claude" Enter
t_tmux send-keys -t s1:3 "sh -c 'claude; read x'" Enter
t_tmux send-keys -t s1:4 "claude" Enter
t_tmux send-keys -t s1:5 "claude" Enter
# pane shapes with no job-control shell to return to
t_tmux new-window -d -t s1 -c "$WORK/pa" "sh -c 'claude; read x'"
t_tmux new-window -d -t s1 -c "$WORK/pa" "$WORK/bin/claude"
six() { [ "$(ar_discover "$WORK/d0" | wc -l | tr -d ' ')" = 8 ]; }
t_wait 15 six
mkdir -p "$WORK/d"
ar_discover "$WORK/d" > "$WORK/d.tsv"
rec() { awk -F'\t' -v a="$1" '$3 == a' "$WORK/d.tsv"; }
R0=$(rec s1:0.0); R1=$(rec s1:1.0); R2=$(rec s1:2.0); R3=$(rec s1:3.0); R4=$(rec s1:4.0); R5=$(rec s1:5.0); R6=$(rec s1:6.0); R7=$(rec s1:7.0)
for r in "$R0" "$R1" "$R2" "$R3" "$R4" "$R5" "$R6" "$R7"; do setscreen "$(fld "$r" 6)" "$IDLE"; done
sleep 1
t_use_version claude 2.0.0   # the upgrade
loglines() { wc -l < "$FAKE_AGENT_LOG" | tr -d ' '; }
alive() { kill -0 "$1" 2>/dev/null; }
SID0=fake-$(fld "$R0" 6)

# no session id: nothing sent
before=$(loglines)
out=$(ar_restart_one "$R1" -)
expect_eq "no sid: result" $'fail\tno session id\t-' "$out"
sleep 1
expect_eq "no sid: agent alive" 0 "$(alive "$(fld "$R1" 6)"; echo $?)"
expect_eq "no sid: nothing started" "$before" "$(loglines)"

# unreadable argv file
bad="${R1/$WORK\/d\//$WORK/d/nope-}"
out=$(ar_restart_one "$bad" "sid")
expect_eq "unreadable argv" $'fail\tcan\'t read arguments\t-' "$out"

# not idle: unsent draft
setscreen "$(fld "$R1" 6)" "$(printf '%s\n❯ half typed\n%s\n  footer\n' "$RULE" "$RULE")"
sleep 1
out=$(ar_restart_one "$R1" "fake-$(fld "$R1" 6)")
expect_eq "unsent: state changed" $'fail\tstate changed\t-' "$out"
sleep 1
expect_eq "unsent: agent alive" 0 "$(alive "$(fld "$R1" 6)"; echo $?)"
expect_eq "unsent: nothing started" "$before" "$(loglines)"

# hung agent: quit ignored
P2=$(fld "$R2" 6)
t_tmux send-keys -t s1:2 "HANG" Enter
sleep 0.5
out=$(AGENTS_RESTART_EXIT_TIMEOUT=2 ar_restart_one "$R2" "fake-$P2")
expect_eq "hang: result" $'fail\tdidn\'t exit within 2s\tclaude --resume fake-'"$P2" "$out"
expect_eq "hang: agent alive" 0 "$(alive "$P2"; echo $?)"
expect_eq "hang: nothing started" "$before" "$(loglines)"

# shell not in foreground after the agent exits
P3=$(fld "$R3" 6)
out=$(ar_restart_one "$R3" "fake-$P3")
case "$out" in
  $'fail\tshell not at prompt\t'*"claude --resume fake-$P3") t_pass "no prompt: result" ;;
  *) t_fail "no prompt: result" "$out" ;;
esac
expect_eq "no prompt: nothing typed after quit" "$before" "$(loglines)"
expect_eq "no prompt: pane did not get the command" 0 "$(t_tmux capture-pane -p -t s1:3 | grep -c 'resume' || true)"

# pane shapes without a shell to return to: nothing sent, pane and agent survive
for pair in "R6:sh -c shape" "R7:bare agent shape"; do
  r=${pair%%:*}; r=${!r}; P=$(fld "$r" 6)
  out=$(ar_restart_one "$r" "fake-$P" 2>/dev/null)
  expect_eq "${pair#*:}: result" $'fail\tpane has no shell to return to\t-' "$out"
  sleep 1
  expect_eq "${pair#*:}: agent alive" 0 "$(alive "$P"; echo $?)"
  expect_eq "${pair#*:}: pane exists" 1 "$(t_tmux list-panes -a -F '#{pane_id}' | grep -cx "$(fld "$r" 2)")"
  expect_eq "${pair#*:}: nothing started" "$before" "$(loglines)"
done

# success
out=$(ar_restart_one "$R0" "$SID0")
newsid=$(echo "$out" | cut -f2)
expect_eq "ok: result tag" ok "$(echo "$out" | cut -f1)"
expect_eq "ok: one line" 1 "$(echo "$out" | wc -l | tr -d ' ')"
expect_eq "ok: new sid is the resumed one" "$SID0" "$newsid"
expect_eq "ok: old agent gone" 1 "$(alive "$(fld "$R0" 6)"; echo $?)"
expect_eq "ok: new start logged with 2.0.0 and --resume" 1 \
  "$(grep -c "^--resume"$'\x1f'"$SID0"$'\t2.0.0$' "$FAKE_AGENT_LOG")"

# bad timeout values fall back to defaults and still work
out=$(AGENTS_RESTART_EXIT_TIMEOUT=x AGENTS_RESTART_START_TIMEOUT=y ar_restart_one "$R4" "fake-$(fld "$R4" 6)")
expect_eq "non-numeric timeouts use defaults" ok "$(echo "$out" | cut -f1)"

# didn't come back: the resume command exits at once
mkdir -p "$WORK/installs/claude/3.0.0"
cat > "$WORK/installs/claude/3.0.0/claude" <<STUB
#!/bin/sh
[ "\$1" = agents ] && exec "$WORK/installs/claude/2.0.0/claude" "\$@"
exit 0
STUB
chmod +x "$WORK/installs/claude/3.0.0/claude"
t_use_version claude 3.0.0
P5=$(fld "$R5" 6)
out=$(AGENTS_RESTART_START_TIMEOUT=1 ar_restart_one "$R5" "fake-$P5")
case "$out" in
  $'fail\tdidn\'t come back\t'*"claude --resume fake-$P5") t_pass "no come back: result" ;;
  *) t_fail "no come back: result" "$out" ;;
esac
t_use_version claude 2.0.0

# timeouts must be integers >= 1
expect_eq "timeout 0 -> default" 15 "$(_ar_pos_int 0 15)"
expect_eq "timeout 3" 3 "$(_ar_pos_int 3 15)"
expect_eq "timeout junk -> default" 15 "$(_ar_pos_int 1.5 15)"

# codex: /quit, result ok<TAB>-
t_install_fake codex 0.166.0; t_install_fake codex 0.167.0
t_use_version codex 0.166.0
export CODEX_HOME="$WORK/codex" AGENTS_RESTART_STABLE_DELAY=0.3 AGENTS_RESTART_QUIET_SECS=1
mkdir -p "$CODEX_HOME/sessions"
t_session s2 "$WORK/pa"
t_tmux send-keys -t s2 "codex" Enter
cdone() { ar_discover "$WORK/dc" | grep -q "s2:0.0"; }
mkdir -p "$WORK/dc"; t_wait 15 cdone
RC=$(ar_discover "$WORK/dc" | awk -F'\t' '$3 == "s2:0.0"')
CP=$(fld "$RC" 6)
setscreen "$CP" "$(cat "$T_REPO/tests/fixtures/agents-restart/codex-idle.screen")"
cidle() { [ "$(ar_state codex "$SWARM_TMUX_SOCKET" s2:0.0 "$CP" /dev/null)" = idle ]; }
t_wait 15 cidle
t_use_version codex 0.167.0
before=$(loglines)
out=$(ar_restart_one "$RC" "019a1adf-8398-72b1-b333-af3dfa74fe00")
expect_eq "codex: result" $'ok\t-' "$out"
expect_eq "codex: old agent gone" 1 "$(alive "$CP"; echo $?)"
expect_eq "codex: resumed with 0.167.0" 1 "$(grep -c "^resume"$'\x1f'"019a1adf-8398-72b1-b333-af3dfa74fe00"$'\t0.167.0$' "$FAKE_AGENT_LOG")"

t_done
