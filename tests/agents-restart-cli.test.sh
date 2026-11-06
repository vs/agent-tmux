#!/usr/bin/env bash
# Tests for the agents-restart skeleton: flags, sockets, exact argv.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/agents-restart-lib.sh"
t_setup
cd "$T_REPO"

expect "help" 0 "usage: agents-restart" agents-restart --help
expect "bad flag" 2 "usage: agents-restart" agents-restart --nope

expect_eq "sockets default" "-" "$(env -u SWARM_TMUX_SOCKET -u AGENTS_RESTART_SOCKETS bash -c 'source lib/agents-restart/common.sh; _ar_socket_candidates')"
expect_eq "sockets with swarm" $'-\nfoo' "$(env -u AGENTS_RESTART_SOCKETS SWARM_TMUX_SOCKET=foo bash -c 'source lib/agents-restart/common.sh; _ar_socket_candidates')"
expect_eq "sockets override" $'-\nbar' "$(AGENTS_RESTART_SOCKETS='- bar' bash -c 'source lib/agents-restart/common.sh; _ar_socket_candidates')"

python3 -c 'import time; time.sleep(30)' "a b" '{"k": 1}' &
sp=$!
sleep 0.3
code=0
(source lib/agents-restart/common.sh; ar_argv "$sp" "$WORK/argv") || code=$?
expect_eq "argv exact rc" "0" "$code"
expect_eq "argv exact" $'a b\n{"k": 1}' "$(tr '\0' '\n' < "$WORK/argv" | tail -2)"
kill "$sp" 2>/dev/null || true; wait "$sp" 2>/dev/null || true

code=0
(source lib/agents-restart/common.sh; ar_argv 999999 "$WORK/argv2") || code=$?
expect_eq "argv gone rc" "1" "$code"

# Harness: fake agent versions, listing and quit.
t_install_fake claude 1.0.0
t_install_fake claude 2.0.0
t_use_version claude 1.0.0
expect "fake version" 0 "1.0.0 (fake)" claude --version
t_use_version claude 2.0.0
expect "fake version switch" 0 "2.0.0 (fake)" claude --version
t_session s1
t_tmux send-keys -t s1 "claude --resume abc" Enter
t_wait 5 grep -q . "$FAKE_AGENT_LOG"
expect "fake logs argv" 0 $'--resume\x1fabc\t2.0.0' cat "$FAKE_AGENT_LOG"
expect "fake listed" 0 '"sessionId":"abc"' claude agents --json
pid=$(jq -r '.[0].pid' < <(claude agents --json))
t_agent_set "$pid" '{"status":"busy"}'
expect "fake override" 0 '"status":"busy"' claude agents --json
t_tmux send-keys -t s1 "/exit" Enter
t_wait 5 bash -c '[ "$(claude agents --json)" = "[]" ]'
expect_eq "fake exits and unlists" "[]" "$(claude agents --json)"
# fancy rendering reads the clock (a perl process) at most about once a second
n=$(bash -c 'source lib/agents-restart/common.sh; source lib/agents-restart/discover.sh; source lib/agents-restart/ui.sh
  log="$1.perl"; perl() { echo x >> "$log"; command perl "$@"; }
  ar_installed_version() { :; }
  AGENTS_RESTART_TEST_FANCY=1 AGENTS_RESTART_TEST_COLS=80; ar_ui_init
  ar_ui_add 0:0.0 f claude; ar_ui_set "$AR_UI_LAST" spin waiting "$AR_NOW"
  : > "$log"
  for i in $(seq 1 25); do ar_ui_render; sleep 0.1; done > /dev/null
  wc -l < "$log"' _ "$WORK/clk" 2>/dev/null | tr -d ' ')
if [[ "$n" =~ ^[0-9]+$ && $n -ge 1 && $n -le 5 ]]; then t_pass "render: clock read about once a second ($n reads / 25 frames)"
else t_fail "render: clock read about once a second" "reads: ${n:-none}"; fi

# CLICOLOR_FORCE: colors without a terminal, but no redraws (Raycast's full output)
ui_mode() {
  env "$@" bash -c 'source lib/agents-restart/common.sh; source lib/agents-restart/discover.sh; source lib/agents-restart/ui.sh
    ar_installed_version() { :; }
    ar_ui_init; ar_ui_add 0:0.0 f claude; ar_ui_set "$AR_UI_LAST" ok resumed
    printf "fancy=%s cols=%s\n" "$AR_FANCY" "$AR_UI_COLS"; ar_ui_render' | cat
}
out=$(ui_mode CLICOLOR_FORCE=1)
expect_eq "clicolor: no redraws" "fancy=0 cols=0" "$(head -1 <<<"$out")"
case "$out" in *$'\e[32m✓'*) t_pass "clicolor: colored mark" ;; *) t_fail "clicolor: colored mark" "$out" ;; esac
case "$out" in *$'\e[J'*|*$'\e[2K'*) t_fail "clicolor: no cursor codes" "$out" ;; *) t_pass "clicolor: no cursor codes" ;; esac
case "$(ui_mode CLICOLOR_FORCE=1 NO_COLOR=1)" in *$'\e['*) t_fail "clicolor: NO_COLOR wins" "colors" ;; *) t_pass "clicolor: NO_COLOR wins" ;; esac
case "$(ui_mode CLICOLOR_FORCE=0)" in *$'\e['*) t_fail "clicolor: 0 means off" "colors" ;; *) t_pass "clicolor: 0 means off" ;; esac
case "$(ui_mode -u CLICOLOR_FORCE)" in *$'\e['*) t_fail "clicolor: plain by default" "colors" ;; *) t_pass "clicolor: plain by default" ;; esac

# temp files go to the run's work dir (removed on exit, Ctrl+C included), not $TMPDIR
mkdir -p "$WORK/wd" "$WORK/tmpd"
AR_WD="$WORK/wd" TMPDIR="$WORK/tmpd" bash -c 'for f in lib/agents-restart/*.sh; do source "$f"; done
  rm() { :; }   # keep the files to look at them
  _ar_launcher_env $$ claude; _ar_argv_after_program $$ bash; _ar_files_since "$(date +%s)" "$AR_WD" x' >/dev/null 2>&1 || true
expect_eq "temp files: none in TMPDIR" "" "$(ls "$WORK/tmpd")"
expect_eq "temp files: in the work dir" 3 "$(ls "$WORK/wd" | grep -c '^agents-restart-' || true)"

t_done
