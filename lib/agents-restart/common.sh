# Shared helpers for agents-restart. Sourced by bin/agents-restart; bash 3.2 compatible.

_AR_LIB_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

ar_die() { echo "agents-restart: error: $*" >&2; exit 1; }
ar_warn() { echo "agents-restart: warning: $*" >&2; }

# _ar_socket_candidates -> the sockets in scope, one per line; "-" is the
# default server. AGENTS_RESTART_SOCKETS (space-separated) overrides the
# default scope (default server plus $SWARM_TMUX_SOCKET).
_ar_socket_candidates() {
  local s
  if [[ -n "${AGENTS_RESTART_SOCKETS:-}" ]]; then
    for s in $AGENTS_RESTART_SOCKETS; do echo "$s"; done
    return
  fi
  echo "-"
  [[ -z "${SWARM_TMUX_SOCKET:-}" ]] || echo "$SWARM_TMUX_SOCKET"
}

# ar_sockets -> the candidates, one per server: deduped by #{socket_path}
# (the swarm socket may be the default server), and sockets with no running
# server left out (they have no panes).
ar_sockets() {
  local s sp seen=$'\n'
  while IFS= read -r s; do
    sp=$(ar_tmux "$s" list-sessions -F '#{socket_path}' 2>/dev/null </dev/null | head -1) || sp=""
    [[ -n "$sp" ]] || continue
    case "$seen" in *$'\n'"$sp"$'\n'*) continue ;; esac
    seen="$seen$sp"$'\n'
    echo "$s"
  done < <(_ar_socket_candidates)
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
