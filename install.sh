#!/usr/bin/env bash
# install.sh — set up what the Claude Code plugin can't: tmux-bridge and the
# smux skill for Codex, pane labels in tmux, and permission rules so neither
# agent asks before running tmux-bridge. Safe to re-run.
set -euo pipefail

REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
TS=$(date +%Y%m%d-%H%M%S)
# Backups live outside the skill folders: Claude Code and Codex would load a
# backup left next to a skill as a second copy of it.
BACKUP_DIR="$HOME/.agent-tmux/backups/$TS"

info() { echo "agent-tmux: $*"; }
die()  { echo "agent-tmux: error: $*" >&2; exit 1; }

for tool in tmux jq; do
  command -v "$tool" >/dev/null 2>&1 || die "$tool is required; install it (e.g. brew install $tool) and re-run"
done

# Point dst at src. A symlink elsewhere is replaced; a real file or directory
# is moved into BACKUP_DIR first.
link() {
  local src="$1" dst="$2"
  mkdir -p "$(dirname "$dst")"
  if [[ -L "$dst" && "$(readlink "$dst")" == "$src" ]]; then
    info "ok      $dst"
    return
  fi
  if [[ -L "$dst" ]]; then
    rm "$dst"
  elif [[ -e "$dst" ]]; then
    local backup="$BACKUP_DIR${dst#"$HOME"}"
    mkdir -p "$(dirname "$backup")"
    mv "$dst" "$backup"
    info "backup  $dst -> $backup"
  fi
  ln -s "$src" "$dst"
  info "linked  $dst -> $src"
}

# --- CLI and Codex skill ---
# Claude Code gets both skills and bin/ from the plugin itself.

link "$REPO/bin/tmux-bridge" "$HOME/.local/bin/tmux-bridge"
link "$REPO/bin/swarm" "$HOME/.local/bin/swarm"
link "$REPO/bin/agents-restart" "$HOME/.local/bin/agents-restart"
link "$REPO/bin/iterm-upgrade" "$HOME/.local/bin/iterm-upgrade"
link "$REPO/bin/iterm-tmux" "$HOME/.local/bin/iterm-tmux"
link "$REPO/skills/smux" "$HOME/.codex/skills/smux"

# Earlier versions linked the skills into ~/.claude/skills; with the plugin
# installed those would load a second copy of each skill.
for skill in smux codex-review; do
  dst="$HOME/.claude/skills/$skill"
  if [[ -L "$dst" && "$(readlink "$dst")" == "$REPO/skills/$skill" ]]; then
    rm "$dst"
    info "removed $dst (the plugin provides it)"
  fi
done

if ! tr ':' '\n' <<<"$PATH" | grep -qx "$HOME/.local/bin"; then
  info "warning: ~/.local/bin is not on PATH; add it so agents can run tmux-bridge"
fi

# --- tmux: pane labels in borders ---

# ~/.tmux.conf sources a fixed path, linked to this repo's config: the line
# never names the repo, so it survives a moved repo (the next run re-points the
# link) and a dotfiles repo can carry it as is (-q: no error where agent-tmux
# isn't installed).
link "$REPO/config/tmux.conf" "$HOME/.agent-tmux/tmux.conf"
tmux_conf="$HOME/.tmux.conf"
source_line='source-file -q ~/.agent-tmux/tmux.conf'
sourced_re='^[[:space:]]*source-file([[:space:]]+-q)?[[:space:]]+["'\'']?(~|\$HOME|'"$HOME"')/\.agent-tmux/tmux\.conf["'\'']?[[:space:]]*$'
# Earlier versions appended `source-file "<repo>/config/tmux.conf"` under a
# "# agent-tmux" line; that line is swapped for the new one in place.
swap_old='prev == "# agent-tmux" && /^source-file ".*\/config\/tmux\.conf"$/ { print line; found = 1; prev = $0; next }
  { print; prev = $0 }
  END { exit !found }'
if [[ -f "$tmux_conf" ]] && grep -qE "$sourced_re" "$tmux_conf"; then
  info "ok      ~/.tmux.conf sources ~/.agent-tmux/tmux.conf"
elif [[ -f "$tmux_conf" ]] && awk -v line="$source_line" "$swap_old" "$tmux_conf" > "$tmux_conf.agent-tmux.tmp"; then
  backup="$BACKUP_DIR/.tmux.conf"
  mkdir -p "$BACKUP_DIR"
  cp "$tmux_conf" "$backup"
  # Write through the path, so a symlinked ~/.tmux.conf (dotfiles) stays a link.
  cat "$tmux_conf.agent-tmux.tmp" > "$tmux_conf"
  rm -f "$tmux_conf.agent-tmux.tmp"
  info "updated ~/.tmux.conf to source ~/.agent-tmux/tmux.conf instead of the repo path (backup: $backup)"
else
  rm -f "$tmux_conf.agent-tmux.tmp"
  printf '\n# agent-tmux\n%s\n' "$source_line" >> "$tmux_conf"
  info "updated ~/.tmux.conf to source ~/.agent-tmux/tmux.conf"
fi
if tmux list-sessions >/dev/null 2>&1; then
  tmux source-file "$REPO/config/tmux.conf"
fi

# --- swarm: starter config and iTerm helper venv ---

swarm_conf="$HOME/.agent-tmux/swarm.conf"
if [[ -e "$swarm_conf" ]]; then
  info "ok      $swarm_conf"
else
  mkdir -p "$(dirname "$swarm_conf")"
  cp "$REPO/config/swarm.conf.example" "$swarm_conf"
  info "created $swarm_conf"
fi

if [[ "${AGENT_TMUX_SKIP_VENV:-0}" == 1 ]]; then
  info "skipped iTerm helper venv (AGENT_TMUX_SKIP_VENV=1)"
elif ! command -v python3 >/dev/null 2>&1; then
  info "warning: python3 not found; iTerm tab placement and hotkey detection are disabled"
else
  venv="$HOME/.agent-tmux/venv"
  if "$venv/bin/python" -I -c 'import iterm2' >/dev/null 2>&1; then
    info "ok      $venv has iterm2"
  elif python3 -m venv "$venv" && "$venv/bin/pip" install -q iterm2; then
    info "installed iterm2 into $venv"
  else
    info "warning: could not install iterm2 into $venv; iTerm tab placement and hotkey detection are disabled"
  fi
fi

# --- iTerm: hotkey profiles reattach their tmux session ---
# A hotkey profile running a bare `tmux -CC` starts a new session each time,
# stranding the old one after an iTerm restart; iterm-tmux reattaches it.

if [[ "${AGENT_TMUX_SKIP_ITERM:-0}" == 1 ]]; then
  info "skipped iTerm hotkey profile (AGENT_TMUX_SKIP_ITERM=1)"
else
  SWARM_ROOT="$REPO"
  # shellcheck disable=SC1091
  source "$REPO/lib/swarm/iterm.sh"
  wrapper="$HOME/.local/bin/iterm-tmux"
  if ! profiles=$(swarm_iterm hotkey-profiles 2>/dev/null); then
    info "skipped iTerm hotkey profile: the iTerm API isn't reachable (iTerm closed, its Python API off, or a dialog open); re-run install.sh to set it"
  else
    while IFS=$'\t' read -r guid custom cmd name; do
      [[ -n "$guid" && "$custom" == Yes ]] || continue
      if [[ "$cmd" == "$wrapper" ]]; then
        info "ok      iTerm profile '$name' runs iterm-tmux"
      elif [[ "$cmd" =~ ^([^[:space:]]*/)?tmux[[:space:]]+-CC[[:space:]]*$ ]]; then
        mkdir -p "$BACKUP_DIR"
        printf '%s\t%s\t%s\n' "$guid" "$name" "$cmd" >> "$BACKUP_DIR/iterm-profiles.tsv"
        if swarm_iterm set-profile-command --guid "$guid" --command "$wrapper"; then
          info "updated iTerm profile '$name': $cmd -> $wrapper (old command in $BACKUP_DIR/iterm-profiles.tsv)"
        else
          info "warning: could not update iTerm profile '$name'"
        fi
      fi
    done <<<"$profiles"
  fi
fi

# --- Claude Code: allow tmux-bridge and swarm without prompting ---
# Not `swarm close`: killing a running lieutenant should always ask.

claude_settings="$HOME/.claude/settings.json"
claude_rules=('Bash(tmux-bridge:*)')
for sub in open delegate status peek report watch layout config; do
  claude_rules+=("Bash(swarm $sub:*)")
done
mkdir -p "$(dirname "$claude_settings")"
[[ -f "$claude_settings" ]] || echo '{}' > "$claude_settings"
missing=()
for rule in "${claude_rules[@]}"; do
  if jq -e --arg r "$rule" '.permissions.allow // [] | index($r)' "$claude_settings" >/dev/null; then
    info "ok      Claude Code allows $rule"
  else
    missing+=("$rule")
  fi
done
if [[ ${#missing[@]} -gt 0 ]]; then
  cp "$claude_settings" "$claude_settings.bak-$TS"
  jq --argjson add "$(printf '%s\n' "${missing[@]}" | jq -R . | jq -s .)" \
    '.permissions.allow = ((.permissions.allow // []) + $add)' \
    "$claude_settings" > "$claude_settings.tmp"
  mv "$claude_settings.tmp" "$claude_settings"
  info "updated $claude_settings (backup: $claude_settings.bak-$TS)"
fi

# --- Codex: run tmux-bridge without prompting, outside the sandbox ---

codex_rules="$HOME/.codex/rules/default.rules"
codex_rule='prefix_rule(pattern=["tmux-bridge"], decision="allow")'
mkdir -p "$(dirname "$codex_rules")"
if [[ -f "$codex_rules" ]] && grep -qF "$codex_rule" "$codex_rules"; then
  info "ok      Codex allows tmux-bridge"
else
  echo "$codex_rule" >> "$codex_rules"
  info "updated $codex_rules"
fi

info "done. Restart running Codex sessions to pick up the skill and rule."
info "Raycast: add $REPO/raycast under Settings → Script Commands → Add Script Directory for the Restart Agents and Upgrade iTerm2 commands."
