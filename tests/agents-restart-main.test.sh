#!/usr/bin/env bash
# Tests for the agents-restart command: plan, confirm, wait-and-restart loop,
# output, summary, exit codes and Ctrl+C. Fake agents on a private tmux server.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/agents-restart-lib.sh"
t_setup
cd "$T_REPO"

export AGENTS_RESTART_POLL=1
loglines() { wc -l < "$FAKE_AGENT_LOG" | tr -d ' '; }
alive() { kill -0 "$1" 2>/dev/null; }
quits() { cat "$WORK/quits.log" 2>/dev/null || true; }

# fresh: a new, empty tmux server (old fakes die with their panes).
fresh() {
  t_tmux kill-server 2>/dev/null || true
  t_wait 5 bash -c '! tmux -L "$SWARM_TMUX_SOCKET" has-session' || true
  rm -f "$WORK/quits.log"
}

# _pane_child <target> -> pid of the pane shell's first child.
_pane_child() {
  local pp
  pp=$(t_tmux display-message -p -t "$1" '#{pane_pid}')
  pgrep -P "$pp" | head -1
}

# spawn <name> <command> -> pid of the fake agent started in a new session
# named <name>, in folder $WORK/<name> (the folder column shows <name>).
spawn() {
  local name="$1" cmd="$2" pid
  mkdir -p "$WORK/$name"
  t_session "$name" "$WORK/$name"
  t_tmux send-keys -t "$name" "$cmd" Enter
  t_wait 10 bash -c "[ -n \"\$(pgrep -P \$(tmux -L $SWARM_TMUX_SOCKET display-message -p -t $name '#{pane_pid}'))\" ]"
  pid=$(_pane_child "$name")
  case "$cmd" in *claude*) t_wait 10 test -e "$WORK/agents/$pid" ;; esac
  sleep 0.3
  echo "$pid"
}

# run <args...>: agents-restart in plain mode; sets OUT and CODE.
run() {
  CODE=0
  OUT=$(NO_COLOR=1 agents-restart "$@" 2>"$WORK/err") || CODE=$?
}
show() { printf '%s\n--- stderr\n%s\n' "$OUT" "$(cat "$WORK/err")"; }
has() { # has <name> <extended regex>
  if printf '%s\n' "$OUT" | grep -qE "$2"; then t_pass "$1"; else t_fail "$1" "$(show)"; fi
}
count() { printf '%s\n' "$OUT" | grep -cE "$1" || true; }

t_install_fake claude 1.0.0
t_install_fake claude 2.0.0
t_install_fake codex 0.1.0
t_use_version claude 2.0.0
# Hide any real codex/gemini on PATH: they read as not installed.
for t in codex gemini; do printf '#!/bin/sh\nexit 127\n' > "$WORK/bin/$t"; chmod +x "$WORK/bin/$t"; done
# Outdated agents run from the old install's own path (a PATH symlink would
# follow t_use_version); resume commands run `claude` from PATH (2.0.0).
OLD="$WORK/installs/claude/1.0.0/claude"

# ---- two outdated idle claudes + one up to date ------------------------------
P1=$(spawn one "$OLD")
P2=$(spawn two "$OLD")
P3=$(spawn three claude)
for p in $P1 $P2 $P3; do t_setscreen "$p" "$T_CLAUDE_IDLE"; done
sleep 0.5
run -y
expect_eq "main: exit 0" 0 "$CODE"
has "main: header" '^agents-restart  claude 2\.0\.0$'
has "main: plan line" "^  [^ ]+ +one +claude +1\.0\.0 → 2\.0\.0 +idle +fake-$(printf %s "$P1" | cut -c1-3)"
expect_eq "main: two restarted lines" 2 "$(count '^✓ ')"
has "main: restarted line names the session" "^✓ .*two +claude +resumed fake-"
has "main: up to date count, singular" '^  1 agent up to date, left alone$'
has "main: summary" '^agents-restart ✓ 2 restarted · 0 skipped · 0 failed +[0-9.]+s$'
expect_eq "main: no escapes in plain output" 0 "$(printf '%s' "$OUT" | grep -c $'\x1b' || true)"
expect_eq "main: up-to-date agent alive" 0 "$(alive "$P3"; echo $?)"
expect_eq "main: up-to-date agent not resumed" 0 "$(grep -c "fake-$P3" "$FAKE_AGENT_LOG" || true)"
expect_eq "main: log = 3 starts + 2 resumes" 5 "$(loglines)"
expect_eq "main: first resumed at 2.0.0" 1 "$(grep -c "^--resume"$'\x1f'"fake-$P1"$'\t2.0.0$' "$FAKE_AGENT_LOG" || true)"
expect_eq "main: old agents gone" "1 1" "$(alive "$P1"; echo -n "$? "; alive "$P2"; echo $?)"

# ---- unknown running version ----------------------------------------------------
fresh
mkdir -p "$WORK/installs/claude/dev"
t_fake_agent_script > "$WORK/installs/claude/dev/claude"
chmod +x "$WORK/installs/claude/dev/claude"
PU=$(spawn unk "$WORK/installs/claude/dev/claude")
t_setscreen "$PU" "$T_CLAUDE_IDLE"
sleep 0.5
run -y
expect_eq "unknown: exit 0" 0 "$CODE"
has "unknown: plan says version unknown" "unk +claude +version unknown +idle"
has "unknown: restarted" "^✓ .*unk +claude +resumed"

# ---- nothing outdated ------------------------------------------------------------
run -y
expect_eq "up to date: exit 0" 0 "$CODE"
has "up to date: message" '^all agents up to date$'

# ---- --dry-run, no terminal, declined confirmation -------------------------------
fresh
PD=$(spawn dry "$OLD")
t_setscreen "$PD" "$T_CLAUDE_IDLE"
sleep 0.5
before=$(loglines)
run --dry-run
expect_eq "dry-run: exit 0" 0 "$CODE"
has "dry-run: plan line" "dry +claude +1\.0\.0 → 2\.0\.0 +idle"
expect_eq "dry-run: no confirmation asked" 0 "$(count 'Restart ')"
expect_eq "dry-run: nothing started" "$before" "$(loglines)"
expect_eq "dry-run: nothing quit" "" "$(quits)"

CODE=0
OUT=$(NO_COLOR=1 perl -MPOSIX -e 'POSIX::setsid() or die "setsid: $!"; exec @ARGV' agents-restart 2>&1) || CODE=$?
expect_eq "no tty: exit 1" 1 "$CODE"
has "no tty: message" 'not a terminal; pass -y'
expect_eq "no tty: nothing quit" "" "$(quits)"

mkdir -p "$WORK/ui"
t_session ui "$WORK/ui"
t_tmux send-keys -t ui "NO_COLOR=1 agents-restart > $WORK/confirm.out 2>&1; echo rc=\$? >> $WORK/confirm.out" Enter
if t_wait 20 bash -c "tmux -L $SWARM_TMUX_SOCKET capture-pane -p -t ui | grep -q 'Restart 1 agent? \[Y/n\]'"; then
  t_pass "confirm: asks on the terminal"
else
  t_fail "confirm: asks on the terminal" "$(t_tmux capture-pane -p -t ui)"
fi
t_tmux send-keys -t ui n Enter
t_wait 10 grep -q '^rc=' "$WORK/confirm.out" || true
expect_eq "confirm: declined exits 0" 1 "$(grep -c '^rc=0$' "$WORK/confirm.out" || true)"
expect_eq "confirm: declined restarts nothing" "$before" "$(loglines)"
expect_eq "confirm: declined quits nothing" "" "$(quits)"
t_tmux kill-session -t ui

# ---- busy agent: waits, restarts once idle -----------------------------------------
fresh
PB=$(spawn busy "$OLD")
t_setscreen "$PB" "$T_CLAUDE_IDLE"
t_agent_set "$PB" '{"status":"busy"}'
before=$(loglines)
(NO_COLOR=1 agents-restart -y > "$WORK/busy.out" 2>&1; echo $? > "$WORK/busy.rc") &
sleep 2.5
expect_eq "busy: not quit while busy" "" "$(quits)"
expect_eq "busy: alive while busy" 0 "$(alive "$PB"; echo $?)"
expect_eq "busy: nothing started while busy" "$before" "$(loglines)"
t_agent_set "$PB" '{"status":"idle"}'
t_wait 30 test -s "$WORK/busy.rc" || true
OUT=$(cat "$WORK/busy.out")
expect_eq "busy: exit 0" 0 "$(cat "$WORK/busy.rc" 2>/dev/null)"
has "busy: restarted after the flip" "^✓ .*busy +claude +resumed fake-${PB:0:3}"

# ---- agents to skip ----------------------------------------------------------------
fresh
PP=$(spawn prm "$OLD")
PR=$(spawn unr "$OLD")
PS=$(spawn uns "$OLD")
PT=$(spawn tmm "$OLD --team-name crew")
PC=$(spawn cdx "$WORK/installs/codex/0.1.0/codex")
t_setscreen "$PP" "$T_CLAUDE_IDLE"
t_setscreen "$PT" "$T_CLAUDE_IDLE"
t_setscreen "$PS" "$(printf '%s\n❯ half typed\n%s\n  footer\n' "$T_RULE" "$T_RULE")"
t_agent_set "$PP" '{"status":"waiting","waitingFor":"approve Bash"}'
sleep 0.5
run -y
expect_eq "skips: exit 0" 0 "$CODE"
has "skips: header lists installed tools only" '^agents-restart  claude 2\.0\.0$'
has "skips: permission prompt" "^– .*prm +claude +skipped: permission prompt"
has "skips: unrecognized screen" "^– .*unr +claude +skipped: screen not recognized"
has "skips: unsent input" "^– .*uns +claude +skipped: unsent input"
has "skips: teammate" "^– .*tmm +claude +skipped: teammate"
has "skips: tool not installed" "^– .*cdx +codex +skipped: codex not installed"
has "skips: summary" '^agents-restart ✓ 0 restarted · 5 skipped · 0 failed'
expect_eq "skips: nothing quit" "" "$(quits)"
expect_eq "skips: all alive" "0 0 0 0 0" "$(for p in $PP $PR $PS $PT $PC; do alive "$p"; echo -n "$? "; done | sed 's/ $//')"

# ---- failures ------------------------------------------------------------------------
fresh
PH=$(spawn hng "$OLD")
PL=$(spawn unl "$OLD")
t_tmux send-keys -t hng HANG Enter
sleep 0.3
t_setscreen "$PH" "$T_CLAUDE_IDLE"
t_setscreen "$PL" "$T_CLAUDE_IDLE"
rm -f "$WORK/agents/$PL"
sleep 0.5
CODE=0
OUT=$(NO_COLOR=1 AGENTS_RESTART_EXIT_TIMEOUT=2 agents-restart -y 2>"$WORK/err") || CODE=$?
expect_eq "fail: exit 1" 1 "$CODE"
has "fail: exit timeout" "^✗ .*hng +claude +failed: didn't exit within 2s"
has "fail: unlisted" "^✗ .*unl +claude +failed: not listed by claude agents"
has "fail: summary" '^agents-restart ✓ 0 restarted · 0 skipped · 2 failed'
after_summary=$(printf '%s\n' "$OUT" | sed -n '/^agents-restart ✓/,$p')
case "$after_summary" in
  *"claude --resume fake-$PH"*) t_pass "fail: manual resume command under the summary" ;;
  *) t_fail "fail: manual resume command under the summary" "$(show)" ;;
esac
expect_eq "fail: both alive" "0 0" "$(alive "$PH"; echo -n "$? "; alive "$PL"; echo $?)"

# ---- the caller's own pane -------------------------------------------------------------
fresh
PM=$(spawn me "$OLD")
PO=$(spawn other "$OLD")
t_setscreen "$PM" "$T_CLAUDE_IDLE"
t_setscreen "$PO" "$T_CLAUDE_IDLE"
sleep 0.5
sp=$(t_tmux display-message -p '#{socket_path}')
mepane=$(t_tmux display-message -p -t me '#{pane_id}')
CODE=0
OUT=$(NO_COLOR=1 TMUX="$sp,1,0" TMUX_PANE="$mepane" agents-restart -y 2>"$WORK/err") || CODE=$?
expect_eq "self: exit 0" 0 "$CODE"
has "self: plan line" "^  [^ ]+ +me +claude +this pane, skipped"
has "self: other restarted" "^✓ .*other +claude +resumed"
expect_eq "self: own agent alive" 0 "$(alive "$PM"; echo $?)"
expect_eq "self: own agent not quit" 0 "$(quits | grep -c "^$PM"$'\t' || true)"

# ---- Ctrl+C while waiting ----------------------------------------------------------------
# set -m puts the background run in its own process group with SIGINT at its
# default (a non-interactive background job would start with SIGINT ignored);
# kill -INT to the group is what Ctrl+C does.
fresh
PW=$(spawn wait "$OLD")
t_setscreen "$PW" "$T_CLAUDE_IDLE"
t_agent_set "$PW" '{"status":"busy"}'
before=$(loglines)
set -m
NO_COLOR=1 agents-restart -y > "$WORK/int.out" 2>&1 &
ipid=$!
set +m
t_wait 20 grep -q '1\.0\.0 → 2\.0\.0' "$WORK/int.out" || true
sleep 1
kill -INT -- -"$ipid" 2>/dev/null || true
CODE=0; wait "$ipid" 2>/dev/null || CODE=$?
OUT=$(cat "$WORK/int.out")
expect_eq "int: exit 130" 130 "$CODE"
has "int: waiting agent marked" "^– .*wait +claude +not restarted \(interrupted\)"
has "int: summary" '^agents-restart ✓ 0 restarted · 1 skipped · 0 failed'
expect_eq "int: agent alive" 0 "$(alive "$PW"; echo $?)"
expect_eq "int: nothing quit" "" "$(quits)"
expect_eq "int: nothing started" "$before" "$(loglines)"

# ---- Ctrl+C mid-restart: the restart in flight still completes ------------------------------
fresh
PF=$(spawn flight "$OLD")
PW2=$(spawn queued "$OLD")
t_tmux send-keys -t flight SLOW Enter
sleep 0.3
t_setscreen "$PF" "$T_CLAUDE_IDLE"
t_setscreen "$PW2" "$T_CLAUDE_IDLE"
t_agent_set "$PW2" '{"status":"busy"}'
sleep 0.5
set -m
NO_COLOR=1 AGENTS_RESTART_START_TIMEOUT=5 agents-restart -y > "$WORK/int2.out" 2>&1 &
ipid=$!
set +m
t_wait 30 grep -q "^$PF"$'\t' "$WORK/quits.log" || true
kill -INT -- -"$ipid" 2>/dev/null || true
CODE=0; wait "$ipid" 2>/dev/null || CODE=$?
OUT=$(cat "$WORK/int2.out")
expect_eq "int mid-flight: exit 130" 130 "$CODE"
expect_eq "int mid-flight: resume command still typed" 1 \
  "$(grep -c "^--resume"$'\x1f'"fake-$PF"$'\t2.0.0$' "$FAKE_AGENT_LOG" || true)"
has "int mid-flight: restarted line" "^✓ .*flight +claude +resumed"
has "int mid-flight: queued agent marked" "^– .*queued +claude +not restarted \(interrupted\)"
expect_eq "int mid-flight: queued agent alive" 0 "$(alive "$PW2"; echo $?)"

# ---- fancy mode on a real terminal -----------------------------------------------------------
fresh
PX=$(spawn fx "$OLD")
PY=$(spawn fy "$OLD")
t_setscreen "$PX" "$T_CLAUDE_IDLE"
t_setscreen "$PY" "$T_CLAUDE_IDLE"
t_agent_set "$PY" '{"status":"busy"}'
sleep 0.5
mkdir -p "$WORK/ui"
t_session ui "$WORK/ui"
t_tmux send-keys -t ui "clear; agents-restart -y; echo rc=\$?" Enter
cap() { t_tmux capture-pane -p -t ui; }
if t_wait 30 bash -c "tmux -L $SWARM_TMUX_SOCKET capture-pane -p -t ui | grep -qE '^[⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏] .*fy +claude +waiting for turn to end +[0-9.]+s'"; then
  t_pass "fancy: spinner line while waiting"
else
  t_fail "fancy: spinner line while waiting" "$(cap)"
fi
t_agent_set "$PY" '{"status":"idle"}'
t_wait 30 bash -c "tmux -L $SWARM_TMUX_SOCKET capture-pane -p -t ui | grep -q '^rc='" || true
screen=$(cap)
expect_eq "fancy: exit 0" 1 "$(printf '%s\n' "$screen" | grep -c '^rc=0$' || true)"
expect_eq "fancy: two frozen restarted lines" 2 "$(printf '%s\n' "$screen" | grep -cE '^✓ .*resumed' || true)"
expect_eq "fancy: no spinner left behind" 0 "$(printf '%s\n' "$screen" | grep -cE '^[⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏]' || true)"
expect_eq "fancy: summary once" 1 "$(printf '%s\n' "$screen" | grep -c '^agents-restart ✓ 2 restarted · 0 skipped · 0 failed' || true)"
expect_eq "fancy: colored marks" 1 "$(t_tmux capture-pane -e -p -t ui | grep -c $'\x1b\\[32m✓' | awk '{ print ($1 >= 1) }')"

t_done
