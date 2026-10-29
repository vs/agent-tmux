# `swarm open`: main tabs (shell | orchestrator over a plain claude). Sourced by bin/swarm; bash 3.2.

# swarm_find_main <project> -> "@win session" of the project's main tab in
# any session, or nothing. One project has one orchestrator across sessions.
swarm_find_main() {
  local id role proj sess
  while IFS='|' read -r id role proj sess; do
    if [[ -n "$id" && "$role" == main && "$proj" == "$1" ]]; then
      echo "$id $sess"
      return 0
    fi
  done <<EOT
$(tmx list-windows -a -F '#{window_id}|#{@swarm-role}|#{@swarm-project}|#{session_name}' 2>/dev/null || true)
EOT
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
  # An owner is live when `claude agents` lists it, or when its pane is busy:
  # an orchestrator started seconds ago may not be listed yet.
  local names="" pane
  while read -r id tg proj; do
    [[ "$tg" == 1 && -n "$proj" ]] || continue
    [[ -n "$names" ]] || names=" $(swarm_agents_tsv | cut -f1 | tr '\n' ' ')"
    if [[ "$names" == *" ${proj}-main "* ]]; then live=1; break; fi
    pane=$(tmx list-panes -t "$id" -F '#{pane_id}' 2>/dev/null | sed -n 2p)
    if [[ -n "$pane" ]] && ! swarm_pane_idle "$pane"; then live=1; break; fi
  done <<EOT
$(tmx list-windows -a -F '#{window_id} #{@swarm-telegram} #{@swarm-project}' 2>/dev/null || true)
EOT
  if [[ $live == 0 ]]; then _OPEN_TG=1; _OPEN_TG_TAKEN=1; fi
  return 0
}

# _open_launch <project> <dir> <agent pane> <resume id>: type the launcher in.
# Typed lines start with a space (kept out of shell history) and clear the
# screen, so the pane shows only the agent.
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
  tmx send-keys -t "$pane" -l " clear; bash '$launcher'"
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

# _open_here_pane -> the caller's pane when its tab can become a main tab:
# a single pane, not a swarm tab. Else nothing.
_open_here_pane() {
  [[ -n "${TMUX_PANE:-}" ]] || return 0
  local out
  out=$(tmx display-message -p -t "$TMUX_PANE" '#{window_panes}|#{@swarm-role}' 2>/dev/null) || return 0
  [[ "$out" == "1|" ]] || return 0
  echo "$TMUX_PANE"
}

# _open_new_tab <session> <project> <dir> [<shell pane>]: with a shell pane
# (a new session's first window, or the caller's tab), build the tab around
# it; else append a new window. Sets _OPEN_WIN, _OPEN_AGENT.
_open_new_tab() {
  local session="$1" project="$2" dir="$3" shellp="${4:-}" last out win auxp
  local env=(-e "SWARM_PROJECT=$project" -e SWARM_ROLE=main)
  if [[ -n "$shellp" ]]; then
    win=$(tmx display-message -p -t "$shellp" '#{window_id}')
    tmx rename-window -t "$win" "${project}-main"
  else
    last=$(tmx list-windows -t "=$session" -F '#{window_id}' | tail -n 1)
    out=$(tmx new-window -d -a -t "$last" -n "${project}-main" -c "$dir" "${env[@]}" \
      -P -F '#{window_id} #{pane_id}')
    win="${out% *}"; shellp="${out#* }"
  fi
  _OPEN_AGENT=$(tmx split-window -h -d -t "$shellp" -c "$dir" "${env[@]}" -P -F '#{pane_id}')
  # A plain Claude for the user under the orchestrator (index 2, so the
  # orchestrator stays the second pane). Started once; never relaunched.
  auxp=$(tmx split-window -v -d -t "$_OPEN_AGENT" -c "$dir" -P -F '#{pane_id}')
  _OPEN_WIN="$win"
  _open_tag "$win" "$project" "$dir"
  tmx set-option -p -t "$shellp" @name shell
  tmx set-option -p -t "$_OPEN_AGENT" @name "${project}-main"
  tmx set-option -p -t "$auxp" @name claude
  swarm_retile_window "$win"
  tmx send-keys -t "$auxp" -l " clear; claude"
  tmx send-keys -t "$auxp" Enter
}

# _open_reattach <session>: for --own-window, open an iTerm window when the
# session has no attached client.
_open_reattach() {
  local attached
  attached=$(tmx list-clients -t "=$1" -F '#{client_name}' 2>/dev/null || true)
  if [[ -z "$attached" ]]; then
    swarm_iterm new-window --session "$1" \
      || swarm_warn "could not open an iTerm window for $1"
  fi
}

cmd_open() {
  local own=0 res name dir session win sid pane first="" tab=$'\t'
  while [[ $# -gt 0 && "$1" == -* ]]; do
    case "$1" in
      --own-window) own=1; shift ;;
      *) swarm_die "usage: swarm open [--own-window] <name|group|path>..." ;;
    esac
  done
  [[ $# -gt 0 ]] || swarm_die "usage: swarm open [--own-window] <name|group|path>..."
  cfg_load   # cfg_resolve runs in a subshell, so load here for cfg_get
  res=$(cfg_resolve "$@") || exit 1

  local home="" here="" herecd="" found shellp
  if [[ $own == 0 ]]; then
    # Run from a plain tab: the first new project takes it, and the rest go
    # into its session.
    here=$(_open_here_pane)
    if [[ -n "$here" ]]; then
      home=$(tmx display-message -p -t "$here" '#{session_name}')
    else
      home=$(swarm_home_session) || exit 1
    fi
  fi
  # Refuse clashes before creating anything: the name taken by another
  # directory, or the project open in its own window when asked for home (or
  # the reverse).
  while IFS="$tab" read -r name dir; do
    [[ -n "$name" ]] || continue
    found=$(swarm_find_main "$name")
    [[ -n "$found" ]] || continue
    win="${found%% *}"; session="${found#* }"
    if [[ "$(swarm_wopt "$win" @swarm-dir)" != "$dir" ]]; then
      swarm_die "project '$name' is already open from $(swarm_wopt "$win" @swarm-dir)"
    fi
    if [[ $own == 1 && "$session" != "swarm-$name" ]] \
       || [[ $own == 0 && "$session" == "swarm-$name" ]]; then
      swarm_die "project '$name' is already open in session '$session'"
    fi
  done <<EOT
$res
EOT

  while IFS="$tab" read -r name dir; do
    [[ -n "$name" ]] || continue
    shellp=""
    found=$(swarm_find_main "$name")
    if [[ -n "$found" ]]; then
      # Reuse the tab where it is, even if another session was home then.
      session="${found#* }"
    elif [[ $own == 1 ]]; then
      session="swarm-$name"
      if ! tmx has-session -t "=$session" 2>/dev/null; then
        tmx new-session -d -s "$session" -c "$dir" -e "SWARM_PROJECT=$name" -e SWARM_ROLE=main
        shellp=$(tmx list-panes -t "=$session" -F '#{pane_id}' | head -n 1)
      fi
    else
      session="$home"
      if [[ -n "$here" ]]; then herecd="$dir"; fi
      shellp="$here"; here=""
    fi

    if [[ -n "$found" ]]; then
      win="${found%% *}"
      if swarm_agent_live "${name}-main"; then
        [[ -n "$first" ]] || first="$win"
        [[ $own == 0 ]] || _open_reattach "$session"
        continue
      fi
      pane=$(tmx list-panes -t "$win" -F '#{pane_id}' | sed -n '2p')
      if [[ -z "$pane" ]]; then
        swarm_warn "${name}-main has no orchestrator pane; not relaunching"
      elif ! swarm_pane_idle "$pane"; then
        swarm_warn "orchestrator pane is busy; not relaunching"
      else
        sid=$(swarm_wopt "$win" @swarm-session-id)
        _open_telegram "$name"
        _open_tag_telegram "$win"
        _open_launch "$name" "$dir" "$pane" "$sid"
      fi
      [[ -n "$first" ]] || first="$win"
      [[ $own == 0 ]] || _open_reattach "$session"
      continue
    fi

    _open_telegram "$name"
    _open_new_tab "$session" "$name" "$dir" "$shellp"
    _open_tag_telegram "$_OPEN_WIN"
    _open_launch "$name" "$dir" "$_OPEN_AGENT" ""
    [[ -n "$first" ]] || first="$_OPEN_WIN"

    [[ $own == 0 ]] || _open_reattach "$session"
  done <<EOT
$res
EOT
  [[ -z "$first" ]] || tmx select-window -t "$first"
  # The caller's shell is the tab's shell pane but can't be moved from here:
  # type the cd for it to run once swarm exits.
  if [[ -n "$herecd" ]]; then
    tmx send-keys -t "$TMUX_PANE" -l " cd -- $(printf '%q' "$herecd") && clear"
    tmx send-keys -t "$TMUX_PANE" Enter
  fi
}
