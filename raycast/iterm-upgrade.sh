#!/bin/bash

# Required parameters:
# @raycast.schemaVersion 1
# @raycast.title Upgrade iTerm2
# @raycast.mode fullOutput

# Optional parameters:
# @raycast.packageName agent-tmux
# @raycast.icon ⬆️
# @raycast.argument1 { "type": "dropdown", "placeholder": "Upgrade", "optional": true, "data": [{ "title": "Upgrade", "value": "upgrade" }, { "title": "Dry run", "value": "dry-run" }, { "title": "Restart only", "value": "restart" }, { "title": "Reattach", "value": "reattach" }] }
# @raycast.description Upgrade iTerm2 with Homebrew, restart it, and reattach its tmux sessions, so the agents in them come back.

# Raycast runs script commands with a bare PATH (/usr/bin:/bin:...), so put
# ~/.local/bin and Homebrew first: iterm-upgrade needs brew, tmux and jq.
PATH="$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:$PATH"
export PATH

if ! command -v iterm-upgrade >/dev/null 2>&1; then
  echo "iterm-upgrade not found on PATH; run install.sh from the agent-tmux repo"
  exit 1
fi

# Raycast has no terminal to confirm in, so the run is the confirmation (-y).
# iterm-upgrade still refuses when agents run outside tmux, since quitting
# iTerm would end them.
case "${1:-upgrade}" in
  ""|upgrade) exec iterm-upgrade -y 2>&1 ;;
  dry-run) exec iterm-upgrade --dry-run 2>&1 ;;
  restart) exec iterm-upgrade -y --no-upgrade 2>&1 ;;
  reattach) exec iterm-upgrade --reattach 2>&1 ;;
  *) echo "unknown mode: $1"; exit 2 ;;
esac
