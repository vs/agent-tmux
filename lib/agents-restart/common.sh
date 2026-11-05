# Shared helpers for agents-restart. Sourced by bin/agents-restart; bash 3.2 compatible.

_AR_LIB_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

ar_die() { echo "agents-restart: error: $*" >&2; exit 1; }
ar_warn() { echo "agents-restart: warning: $*" >&2; }

# ar_sockets -> one tmux socket per line; "-" is the default server.
# AGENTS_RESTART_SOCKETS (space-separated) overrides the default scope.
ar_sockets() {
  local s
  if [[ -n "${AGENTS_RESTART_SOCKETS:-}" ]]; then
    for s in $AGENTS_RESTART_SOCKETS; do echo "$s"; done
    return
  fi
  echo "-"
  [[ -z "${SWARM_TMUX_SOCKET:-}" ]] || echo "$SWARM_TMUX_SOCKET"
}

# ar_tmux <sock> <args...> -> tmux against that socket ("-" = default server).
ar_tmux() {
  local sock="$1"; shift
  if [[ "$sock" == "-" ]]; then
    tmux "$@"
  else
    tmux -L "$sock" "$@"
  fi
}

# ar_argv <pid> <outfile> -> NUL-separated argv in <outfile>.
# Returns 0 exact, 2 approximate (no python3: whitespace split), 1 gone.
ar_argv() {
  local pid="$1" out="$2" args
  if command -v python3 >/dev/null 2>&1; then
    python3 "$_AR_LIB_DIR/../../bin/agents-restart-argv" "$pid" > "$out" 2>/dev/null || return 1
    return 0
  fi
  args=$(ps -o args= -p "$pid" 2>/dev/null) || return 1
  [[ -n "$args" ]] || return 1
  # shellcheck disable=SC2086
  printf '%s\0' $args > "$out"
  return 2
}
