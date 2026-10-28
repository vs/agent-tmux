# iTerm helper wrapper. Sourced by bin/swarm; bash 3.2 compatible.

# swarm_iterm <cmd> <args...> -> runs the helper; returns its exit code (3 if missing).
swarm_iterm() {
  if [[ -n "${SWARM_ITERM_HELPER:-}" ]]; then
    "$SWARM_ITERM_HELPER" "$@"
    return $?
  fi
  local root="${SWARM_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
  local py="${SWARM_PYTHON:-$HOME/.agent-tmux/venv/bin/python}"
  local script="$root/bin/swarm-iterm.py"
  if [[ ! -f "$script" ]]; then
    echo "swarm-iterm: helper not found: $script" >&2
    return 3
  fi
  if [[ ! -x "$py" ]]; then
    echo "swarm-iterm: python not found: $py (create the venv and pip install iterm2)" >&2
    return 3
  fi
  "$py" -I "$script" "$@"
}
