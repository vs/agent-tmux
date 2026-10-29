# `swarm open`: main tabs (shell | orchestrator). Sourced by bin/swarm; bash 3.2.

# swarm_main_window <session> <project> -> @id of the main tab, or nothing.
swarm_main_window() {
  local id
  for id in $(swarm_windows "$1" @swarm-project "$2"); do
    if [[ "$(swarm_wopt "$id" @swarm-role)" == main ]]; then
      echo "$id"
      return 0
    fi
  done
  return 0
}

# Sets _OPEN_TG to 1 when <project> should own Telegram, else 0.
_OPEN_TG_TAKEN=0
_open_telegram() {
  local project="$1" tp id tg proj live=0
  tp=$(cfg_get telegram_project)
  if [[ -n "$tp" ]]; then
    if [[ "$project" == "$tp" ]]; then _OPEN_TG=1; else _OPEN_TG=0; fi
    return 0
  fi
  _OPEN_TG=0
  [[ $_OPEN_TG_TAKEN == 0 ]] || return 0
  while read -r id tg proj; do
    if [[ "$tg" == 1 && -n "$proj" ]] && swarm_agent_live "${proj}-main"; then live=1; break; fi
  done <<EOT
$(tmx list-windows -a -F '#{window_id} #{@swarm-telegram} #{@swarm-project}' 2>/dev/null || true)
EOT
  if [[ $live == 0 ]]; then _OPEN_TG=1; _OPEN_TG_TAKEN=1; fi
  return 0
}

# _open_launch <project> <dir> <agent pane> <resume id>: type the launcher in.
_open_launch() {
  local project="$1" dir="$2" pane="$3" sid="$4" launcher cmd=() fresh=() w
  launcher="$(swarm_state_dir)/run/${project}-main.sh"
  while IFS= read -r w; do fresh+=("$w"); done <<EOT
$(swarm_orchestrator_cmd "$project" "$_OPEN_TG")
EOT
  if [[ -n "$sid" ]]; then
    while IFS= read -r w; do cmd+=("$w"); done <<EOT
$(swarm_orchestrator_cmd "$project" "$_OPEN_TG" "$sid")
EOT
    swarm_write_launcher "$launcher" "$dir" "${cmd[@]}" --else "${fresh[@]}"
  else
    swarm_write_launcher "$launcher" "$dir" "${fresh[@]}"
  fi
  tmx send-keys -t "$pane" -l "bash '$launcher'"
  tmx send-keys -t "$pane" Enter
}

_open_tag() {
  local win="$1" project="$2" dir="$3"
  tmx set-option -w -t "$win" @swarm-project "$project"
  tmx set-option -w -t "$win" @swarm-role main
  tmx set-option -w -t "$win" @swarm-dir "$dir"
  tmx set-option -w -t "$win" @swarm-layout stack
}

_open_tag_telegram() {
  if [[ "$_OPEN_TG" == 1 ]]; then
    tmx set-option -w -t "$1" @swarm-telegram 1
  else
    tmx set-option -wu -t "$1" @swarm-telegram 2>/dev/null || true
  fi
}

# _open_new_tab <session> <project> <dir> <first-window-of-new-session 0|1>
# Sets _OPEN_WIN, _OPEN_AGENT.
_open_new_tab() {
  local session="$1" project="$2" dir="$3" fresh="$4" last out win shellp
  local env=(-e "SWARM_PROJECT=$project" -e SWARM_ROLE=main)
  if [[ $fresh == 1 ]]; then
    out=$(tmx list-windows -t "=$session" -F '#{window_id} #{pane_id}' | head -n 1)
    win="${out% *}"; shellp="${out#* }"
    tmx rename-window -t "$win" "${project}-main"
  else
    last=$(tmx list-windows -t "=$session" -F '#{window_id}' | tail -n 1)
    out=$(tmx new-window -d -a -t "$last" -n "${project}-main" -c "$dir" "${env[@]}" \
      -P -F '#{window_id} #{pane_id}')
    win="${out% *}"; shellp="${out#* }"
  fi
  _OPEN_AGENT=$(tmx split-window -h -d -t "$shellp" -c "$dir" "${env[@]}" -P -F '#{pane_id}')
  _OPEN_WIN="$win"
  _open_tag "$win" "$project" "$dir"
  tmx set-option -p -t "$shellp" @name shell
  tmx set-option -p -t "$_OPEN_AGENT" @name "${project}-main"
  swarm_retile_window "$win"
}

cmd_open() {
  local own=0 res name dir session win sid pane panes pid first="" tab=$'\t'
  while [[ $# -gt 0 && "$1" == -* ]]; do
    case "$1" in
      --own-window) own=1; shift ;;
      *) swarm_die "usage: swarm open [--own-window] <name|group|path>..." ;;
    esac
  done
  [[ $# -gt 0 ]] || swarm_die "usage: swarm open [--own-window] <name|group|path>..."
  cfg_load   # cfg_resolve runs in a subshell, so load here for cfg_get
  res=$(cfg_resolve "$@") || exit 1

  local home=""
  if [[ $own == 0 ]]; then
    home=$(swarm_home_session) || exit 1
    # Refuse a name clash before creating anything.
    while IFS="$tab" read -r name dir; do
      [[ -n "$name" ]] || continue
      win=$(swarm_main_window "$home" "$name")
      if [[ -n "$win" && "$(swarm_wopt "$win" @swarm-dir)" != "$dir" ]]; then
        swarm_die "project '$name' is already open from $(swarm_wopt "$win" @swarm-dir)"
      fi
    done <<EOT
$res
EOT
  fi

  while IFS="$tab" read -r name dir; do
    [[ -n "$name" ]] || continue
    local fresh=0 attached
    if [[ $own == 1 ]]; then
      session="swarm-$name"
      if ! tmx has-session -t "=$session" 2>/dev/null; then
        tmx new-session -d -s "$session" -c "$dir" -e "SWARM_PROJECT=$name" -e SWARM_ROLE=main
        fresh=1
      fi
    else
      session="$home"
    fi

    win=$(swarm_main_window "$session" "$name")
    if [[ -n "$win" ]]; then
      if [[ "$(swarm_wopt "$win" @swarm-dir)" != "$dir" ]]; then
        swarm_die "project '$name' is already open from $(swarm_wopt "$win" @swarm-dir)"
      fi
      if swarm_agent_live "${name}-main"; then
        [[ -n "$first" ]] || first="$win"
        continue
      fi
      panes=$(tmx list-panes -t "$win" -F '#{pane_id} #{pane_pid}')
      pane=$(printf '%s\n' "$panes" | sed -n '2p')
      pid="${pane#* }"; pane="${pane% *}"
      if [[ -z "$pane" ]]; then
        swarm_warn "${name}-main has no orchestrator pane; not relaunching"
      elif pgrep -P "$pid" >/dev/null 2>&1; then
        swarm_warn "orchestrator pane is busy; not relaunching"
      else
        sid=$(swarm_wopt "$win" @swarm-session-id)
        _open_telegram "$name"
        _open_tag_telegram "$win"
        _open_launch "$name" "$dir" "$pane" "$sid"
      fi
      [[ -n "$first" ]] || first="$win"
      continue
    fi

    _open_telegram "$name"
    _open_new_tab "$session" "$name" "$dir" "$fresh"
    _open_tag_telegram "$_OPEN_WIN"
    _open_launch "$name" "$dir" "$_OPEN_AGENT" ""
    [[ -n "$first" ]] || first="$_OPEN_WIN"

    if [[ $own == 1 ]]; then
      attached=$(tmx list-clients -t "=$session" -F '#{client_name}' 2>/dev/null || true)
      if [[ -z "$attached" ]]; then
        swarm_iterm new-window --session "$session" \
          || swarm_warn "could not open an iTerm window for $session"
      fi
    fi
  done <<EOT
$res
EOT
  [[ -z "$first" ]] || tmx select-window -t "$first"
}
