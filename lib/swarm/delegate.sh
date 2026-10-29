# `swarm delegate`: open a lieutenant tab (shell | lieutenant). Sourced by
# bin/swarm; bash 3.2.

cmd_delegate() {
  local name="" model="" layout=stack brief_file="" use_stdin=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --model) [[ $# -ge 2 ]] || swarm_die "--model needs a value"; model="$2"; shift 2 ;;
      --layout) [[ $# -ge 2 ]] || swarm_die "--layout needs a value"; layout="$2"; shift 2 ;;
      --brief-file) [[ $# -ge 2 ]] || swarm_die "--brief-file needs a file"; brief_file="$2"; shift 2 ;;
      -) use_stdin=1; shift ;;
      -*) swarm_die "usage: swarm delegate <name> [--model M] [--layout stack|grid] (--brief-file F | -)" ;;
      *) [[ -z "$name" ]] || swarm_die "usage: swarm delegate <name> [--model M] [--layout stack|grid] (--brief-file F | -)"
         name="$1"; shift ;;
    esac
  done
  [[ -n "$name" ]] || swarm_die "usage: swarm delegate <name> [--model M] [--layout stack|grid] (--brief-file F | -)"
  case "$layout" in stack | grid) ;; *) swarm_die "layout must be stack or grid" ;; esac

  local caller session project dir
  caller=$(swarm_caller_window)
  if [[ "$(swarm_wopt "$caller" @swarm-role)" != main ]]; then
    swarm_die "swarm delegate must be run from a project's main tab"
  fi
  if [[ ! "$name" =~ ^[a-z0-9][a-z0-9-]*$ || "$name" == main ]]; then
    swarm_die "invalid lieutenant name '$name' (use lowercase letters, digits and -; not 'main')"
  fi
  session=$(tmx display-message -p -t "$caller" '#{session_name}')
  project=$(swarm_wopt "$caller" @swarm-project)
  dir=$(swarm_wopt "$caller" @swarm-dir)

  local id last="" others=""
  for id in $(swarm_windows "=$session" @swarm-project "$project"); do
    last="$id"
    if [[ "$(swarm_wopt "$id" @swarm-role)" == lieutenant \
       && "$(swarm_wopt "$id" @swarm-name)" == "$name" ]]; then
      swarm_die "lieutenant '$name' already exists in tab $project:$name"
    fi
  done

  local brief
  if [[ -n "$brief_file" ]]; then
    [[ -r "$brief_file" ]] || swarm_die "cannot read brief file: $brief_file"
    brief=$(cat "$brief_file")
  elif [[ $use_stdin == 1 ]]; then
    brief=$(cat)
  else
    swarm_die "usage: swarm delegate <name> [--model M] [--layout stack|grid] (--brief-file F | -)"
  fi
  [[ -n "${brief//[[:space:]]/}" ]] || swarm_die "empty brief"

  cfg_load
  [[ -n "$model" ]] || model=$(cfg_get lt_model)
  swarm_record_session_id "$caller" \
    "$(swarm_agents_tsv | awk -F'\t' -v n="${project}-main" '$1==n{print $5; exit}')"

  local run prompt first_msg
  run="$(swarm_state_dir)/run/${project}-${name}"
  mkdir -p "$run"
  printf '%s\n' "$brief" > "$run/brief.md"
  prompt=$(cat "$SWARM_ROOT/lib/swarm/lieutenant-prompt.md")
  prompt="${prompt//\{\{NAME\}\}/$name}"
  prompt="${prompt//\{\{PROJECT\}\}/$project}"
  prompt="${prompt//\{\{PARENT\}\}/${project}-main}"
  prompt="${prompt//\{\{DIR\}\}/$dir}"
  printf '%s\n' "$prompt" > "$run/prompt.md"
  # The header keeps a brief that starts with - from being read as an option.
  first_msg="Task brief from ${project}-main:"$'\n\n'"$brief"

  local env=(-e "SWARM_PROJECT=$project" -e SWARM_ROLE=lieutenant) out win shellp ltp
  out=$(tmx new-window -d -a -t "$last" -n "${project}:${name}" -c "$dir" "${env[@]}" \
    -P -F '#{window_id} #{pane_id}')
  win="${out% *}"; shellp="${out#* }"
  ltp=$(tmx split-window -h -d -t "$shellp" -c "$dir" "${env[@]}" -P -F '#{pane_id}')
  tmx set-option -w -t "$win" @swarm-role lieutenant
  tmx set-option -w -t "$win" @swarm-name "$name"
  tmx set-option -w -t "$win" @swarm-project "$project"
  tmx set-option -w -t "$win" @swarm-dir "$dir"
  tmx set-option -w -t "$win" @swarm-layout "$layout"
  tmx set-option -p -t "$shellp" @name shell
  tmx set-option -p -t "$ltp" @name "$name"
  swarm_retile_window "$win"

  swarm_write_launcher "$run/launch.sh" "$dir" \
    env CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1 claude --name "${project}-${name}" \
    --teammate-mode tmux --model "$model" --settings "$(swarm_settings_json 0)" \
    --append-system-prompt-file "$run/prompt.md" "$first_msg"
  tmx send-keys -t "$ltp" -l " clear; bash '$run/launch.sh'"
  tmx send-keys -t "$ltp" Enter

  for id in $(swarm_windows "=$session" @swarm-project "$project"); do
    [[ "$id" == "$win" ]] || others="${others:+$others,}$id"
  done
  swarm_iterm place-tab --new "$win" --project "$others" \
    || swarm_warn "could not place the tab in iTerm; it stays at the end"

  echo "delegated $name in tab ${project}:${name} (session ${project}-${name})"
}
