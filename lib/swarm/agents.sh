# Orchestrator launch helpers and `claude agents --json` access. Sourced by
# bin/swarm; bash 3.2 compatible. Task 8 extends this file.

# swarm_agents_tsv -> name<TAB>status<TAB>waitingFor<TAB>cwd<TAB>sessionId per
# agent; null or empty becomes "-" so that read with a tab IFS (which collapses
# empty fields) always sees exactly 5 columns. Prints nothing (and returns 0) when the command
# fails or prints something that isn't a JSON array.
swarm_agents_tsv() {
  local json
  json=$(claude agents --json 2>/dev/null) || return 0
  printf '%s' "$json" | jq -r '.[] | [.name, .status, .waitingFor, .cwd, .sessionId] | map(if . == null or . == "" then "-" else . end) | join("\t")' 2>/dev/null || true
}

# swarm_agent_live <name> -> 0 if the agent is listed. Safe under set -e.
swarm_agent_live() {
  local n rest tab=$'\t'
  while IFS="$tab" read -r n rest; do
    [[ "$n" == "$1" ]] && return 0
  done <<EOT
$(swarm_agents_tsv)
EOT
  return 1
}

# swarm_settings_json <telegram_on 0|1> -> the --settings JSON for a Claude
# started by swarm. Telegram off disables the plugin through enabledPlugins.
swarm_settings_json() {
  if [[ "$1" == 1 ]]; then
    printf '{"crossSessionInbound":"accept"}\n'
  else
    jq -nc --arg p "$(cfg_get telegram_plugin)" \
      '{crossSessionInbound:"accept",enabledPlugins:{($p):false}}'
  fi
}

_launcher_line() {
  local out="" a
  for a in "$@"; do out="$out $(printf '%q' "$a")"; done
  printf '%s' "${out# }"
}

# swarm_write_launcher <file> <dir> <cmd...> [--else <fallback cmd...>]
# Writes a bash script that cds to <dir> and runs <cmd> with every argument
# printf %q-quoted. With --else, the fallback runs when <cmd> fails within 15
# seconds (not when it was interrupted with ^C).
swarm_write_launcher() {
  local file="$1" dir="$2"; shift 2
  local primary=() fallback=() seen=0 a
  for a in "$@"; do
    if [[ $seen == 0 && "$a" == --else ]]; then seen=1; continue; fi
    if [[ $seen == 1 ]]; then fallback+=("$a"); else primary+=("$a"); fi
  done
  mkdir -p "$(dirname "$file")"
  {
    echo '#!/usr/bin/env bash'
    echo "cd $(printf '%q' "$dir") || exit 1"
    if [[ ${#fallback[@]} -eq 0 ]]; then
      echo "$(_launcher_line "${primary[@]}")"
    else
      echo 'SECONDS=0'
      echo "$(_launcher_line "${primary[@]}")"
      echo 'rc=$?'
      echo 'if [ "$rc" -ne 0 ] && [ "$rc" -ne 130 ] && [ "$SECONDS" -lt 15 ]; then'
      echo "  $(_launcher_line "${fallback[@]}")"
      echo 'fi'
    fi
  } > "$file"
  chmod +x "$file"
}

# swarm_orchestrator_cmd <project> <telegram_on> [session id] -> the claude
# command words, one per line.
swarm_orchestrator_cmd() {
  printf '%s\n' env -u CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS claude --name "$1-main" \
    --settings "$(swarm_settings_json "$2")"
  if [[ -n "${3:-}" ]]; then printf '%s\n' --resume "$3"; fi
}
