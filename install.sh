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

source_line="source-file \"$REPO/config/tmux.conf\""
if [[ -f "$HOME/.tmux.conf" ]] && grep -qF "$source_line" "$HOME/.tmux.conf"; then
  info "ok      ~/.tmux.conf sources config/tmux.conf"
else
  printf '\n# agent-tmux\n%s\n' "$source_line" >> "$HOME/.tmux.conf"
  info "updated ~/.tmux.conf to source config/tmux.conf"
fi
if tmux list-sessions >/dev/null 2>&1; then
  tmux source-file "$REPO/config/tmux.conf"
fi

# --- Claude Code: allow tmux-bridge without prompting ---

claude_settings="$HOME/.claude/settings.json"
claude_rule='Bash(tmux-bridge:*)'
[[ -f "$claude_settings" ]] || echo '{}' > "$claude_settings"
if jq -e --arg r "$claude_rule" '.permissions.allow // [] | index($r)' "$claude_settings" >/dev/null; then
  info "ok      Claude Code allows $claude_rule"
else
  cp "$claude_settings" "$claude_settings.bak-$TS"
  jq --arg r "$claude_rule" '.permissions.allow = ((.permissions.allow // []) + [$r])' \
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
