# Shared helpers for swarm. Sourced by bin/swarm; bash 3.2 compatible.

swarm_die() { echo "swarm: error: $*" >&2; exit 1; }
swarm_warn() { echo "swarm: warning: $*" >&2; }

# tmux, against the private socket when SWARM_TMUX_SOCKET is set.
tmx() {
  if [[ -n "${SWARM_TMUX_SOCKET:-}" ]]; then
    tmux -L "$SWARM_TMUX_SOCKET" "$@"
  else
    tmux "$@"
  fi
}

swarm_state_dir() {
  local d="${SWARM_STATE_DIR:-$HOME/.agent-tmux/swarm}"
  mkdir -p "$d"
  echo "$d"
}

# swarm_wopt <@win> <key> -> value of the window option, or empty.
swarm_wopt() {
  tmx show-options -wqv -t "$1" "$2" 2>/dev/null || true
}

# swarm_windows <session> [key value] -> @ids in index order.
swarm_windows() {
  local session="$1" key="${2:-}" value="${3:-}" id
  tmx list-windows -t "$session" -F '#{window_id}' 2>/dev/null | while IFS= read -r id; do
    if [[ -z "$key" ]] || [[ "$(swarm_wopt "$id" "$key")" == "$value" ]]; then
      echo "$id"
    fi
  done
}

swarm_caller_window() {
  local w=""
  if [[ -n "${TMUX_PANE:-}" ]]; then
    w=$(tmx display-message -p -t "$TMUX_PANE" '#{window_id}' 2>/dev/null) || w=""
  fi
  [[ -n "$w" ]] || swarm_die "not inside a tmux pane"
  echo "$w"
}

swarm_sanitize() {
  printf '%s' "$1" | sed 's/[^A-Za-z0-9_-]/-/g'
}
