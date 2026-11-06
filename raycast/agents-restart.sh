#!/bin/bash

# Required parameters:
# @raycast.schemaVersion 1
# @raycast.title Restart Agents
# @raycast.mode fullOutput

# Optional parameters:
# @raycast.packageName agent-tmux
# @raycast.icon 🔄
# @raycast.description Restart the Claude, Codex and Gemini agents in tmux that are older than the installed CLI.

# Raycast runs script commands with a bare PATH (/usr/bin:/bin:...), so find
# agents-restart, tmux and the agent CLIs the way an interactive shell would:
# ~/.local/bin and Homebrew first, then mise's tool dirs (from $HOME, so the
# global config applies), or its shims when `mise env` isn't available.
PATH="$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:$PATH"
if command -v mise >/dev/null 2>&1 && mise_env=$(cd "$HOME" && mise env -s bash 2>/dev/null); then
  eval "$mise_env"
elif [[ -d "$HOME/.local/share/mise/shims" ]]; then
  PATH="$HOME/.local/share/mise/shims:$PATH"
fi
export PATH

if ! command -v agents-restart >/dev/null 2>&1; then
  echo "agents-restart not found on PATH; run install.sh from the agent-tmux repo"
  exit 1
fi

# Colored plain lines: Raycast renders ANSI colors but not in-place redraws.
export CLICOLOR_FORCE=1
exec agents-restart -y 2>&1
