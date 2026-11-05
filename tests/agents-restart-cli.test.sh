#!/usr/bin/env bash
# Tests for the agents-restart skeleton: flags, sockets, exact argv.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/agents-restart-lib.sh"
t_setup
cd "$T_REPO"

expect "help" 0 "usage: agents-restart" agents-restart --help
expect "bad flag" 2 "usage: agents-restart" agents-restart --nope

expect_eq "sockets default" "-" "$(env -u SWARM_TMUX_SOCKET -u AGENTS_RESTART_SOCKETS bash -c 'source lib/agents-restart/common.sh; ar_sockets')"
expect_eq "sockets with swarm" $'-\nfoo' "$(env -u AGENTS_RESTART_SOCKETS SWARM_TMUX_SOCKET=foo bash -c 'source lib/agents-restart/common.sh; ar_sockets')"
expect_eq "sockets override" $'-\nbar' "$(AGENTS_RESTART_SOCKETS='- bar' bash -c 'source lib/agents-restart/common.sh; ar_sockets')"

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
t_done
