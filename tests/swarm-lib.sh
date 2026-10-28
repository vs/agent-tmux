# Shared test helpers for swarm tests. Source it, then call t_setup.
# Everything runs against a private tmux server (SWARM_TMUX_SOCKET).

T_REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
t_failures=0

t_pass() { echo "ok   $1"; }
t_fail() { echo "FAIL $1"; echo "$2" | sed 's/^/     /'; t_failures=$((t_failures + 1)); }

t_cleanup() {
  tmux -L "$SWARM_TMUX_SOCKET" kill-server 2>/dev/null || true
  rm -rf "$WORK"
}

t_setup() {
  WORK=$(mktemp -d)
  export SWARM_TMUX_SOCKET="swarm-test-$$"
  export SWARM_CONFIG="$WORK/swarm.conf"
  export SWARM_STATE_DIR="$WORK/state"
  export HOME="$WORK/home"
  mkdir -p "$WORK/bin" "$HOME"
  export PATH="$WORK/bin:$T_REPO/bin:$PATH"
  unset TMUX TMUX_PANE
  export FAKE_CLAUDE_LOG="$WORK/claude.log" FAKE_ITERM_LOG="$WORK/iterm.log"
  export FAKE_AGENTS_JSON="$WORK/agents.json"
  echo '[]' > "$FAKE_AGENTS_JSON"
  : > "$FAKE_CLAUDE_LOG"; : > "$FAKE_ITERM_LOG"

  cat > "$WORK/bin/claude" <<'FAKE'
#!/usr/bin/env bash
if [[ "${1:-}" == "agents" && "${2:-}" == "--json" ]]; then
  [[ "${FAKE_AGENTS_FAIL:-0}" == 1 ]] && exit 1
  cat "${FAKE_AGENTS_JSON:-/dev/null}" 2>/dev/null || echo '[]'
  exit 0
fi
args=""
for a in "$@"; do args="${args}${a}"$'\x1f'; done
printf '%s\n' "${args%$'\x1f'}" >> "$FAKE_CLAUDE_LOG"
while :; do sleep 60; done
FAKE
  cat > "$WORK/bin/fake-iterm" <<'FAKE'
#!/usr/bin/env bash
echo "$*" >> "$FAKE_ITERM_LOG"
[[ -n "${FAKE_ITERM_OUT:-}" ]] && echo "$FAKE_ITERM_OUT"
exit "${FAKE_ITERM_CODE:-0}"
FAKE
  chmod +x "$WORK/bin/claude" "$WORK/bin/fake-iterm"
  export SWARM_ITERM_HELPER="$WORK/bin/fake-iterm"
  trap t_cleanup EXIT
}

t_tmux() { tmux -L "$SWARM_TMUX_SOCKET" "$@"; }

# t_session <name> [dir]: detached 200x50 session on the private server.
t_session() {
  local name="$1" dir="${2:-$WORK}"
  if t_tmux has-session 2>/dev/null; then
    t_tmux new-session -d -s "$name" -x 200 -y 50 -c "$dir"
  else
    tmux -L "$SWARM_TMUX_SOCKET" -f /dev/null new-session -d -s "$name" -x 200 -y 50 -c "$dir"
  fi
  t_tmux set-option -g default-shell /bin/sh
}

# expect <name> <exit code> <output substring> <cmd...>
expect() {
  local name="$1" want_code="$2" want_out="$3"; shift 3
  local out code=0
  out=$("$@" 2>&1) || code=$?
  if [[ "$code" == "$want_code" && "$out" == *"$want_out"* ]]; then
    t_pass "$name"
  else
    t_fail "$name" "exit $code (want $want_code), output:
$out"
  fi
}

# expect_eq <name> <want> <got>
expect_eq() {
  if [[ "$2" == "$3" ]]; then t_pass "$1"; else t_fail "$1" "want: $2
got:  $3"; fi
}

t_done() {
  if [[ $t_failures -gt 0 ]]; then echo "$t_failures test(s) failed"; exit 1; fi
  echo "all passed"
}
