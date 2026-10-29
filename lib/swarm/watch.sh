# `swarm watch`: print one line per newly active stuck condition. Sourced by
# bin/swarm; bash 3.2.

# _watch_commit_time <cwd> -> newest commit time on any branch; 0 if unknown.
_watch_commit_time() {
  local t=""
  if [[ -n "$1" && "$1" != - ]]; then
    t=$(git -C "$1" log --all -1 --format=%ct 2>/dev/null) || t=""
  fi
  echo "${t:-0}"
}

# watch_tick <project>: one pass over the project's lieutenants. Prints each
# condition that is newly active; $STATE/watch-<project>.active remembers them.
watch_tick() {
  local project="$1" tsv now stall idle_min tab=$'\t'
  tsv=$(swarm_agents_tsv)
  # No agent data (command failed, nothing running): leave state untouched.
  [[ -n "$tsv" ]] || return 0
  now=$(swarm_now)
  stall=$(cfg_get stall_min); idle_min=$(cfg_get idle_min)
  local file active="" win sess name layout report panes agent_pane
  file="$(swarm_state_dir)/watch-$project.active"
  local line st wf cwd sid n since mins ct hash ssince cap npanes nhelpers tracked
  local role
  while read -r win sess; do
    [[ -n "$win" && "$(swarm_wopt "$win" @swarm-project)" == "$project" ]] || continue
    role=$(swarm_wopt "$win" @swarm-role)
    if [[ "$role" == main ]]; then
      swarm_record_session_id "$win" \
        "$(printf '%s\n' "$tsv" | awk -F'\t' -v n="$project-main" '$1==n{print $5; exit}')"
      continue
    fi
    [[ "$role" == lieutenant ]] || continue
    name=$(swarm_wopt "$win" @swarm-name)
    layout=$(swarm_wopt "$win" @swarm-layout)
    report=$(swarm_wopt "$win" @swarm-report)
    panes=$(tmx list-panes -t "$win" -F '#{pane_id}' 2>/dev/null)
    npanes=$(printf '%s\n' "$panes" | grep -c . || true)
    nhelpers=$((npanes - 2)); [[ $nhelpers -ge 0 ]] || nhelpers=0
    agent_pane=$(printf '%s\n' "$panes" | sed -n 2p)

    cap=1; [[ "$layout" == grid ]] && cap=3
    if [[ $nhelpers -gt $cap ]]; then
      active="${active}over-cap $name $nhelpers"$'\n'
    fi

    line=$(printf '%s\n' "$tsv" | awk -F'\t' -v n="$project-$name" '$1==n{print; exit}')
    [[ -n "$line" ]] || continue
    IFS="$tab" read -r n st wf cwd sid <<EOT
$line
EOT
    swarm_record_session_id "$win" "$sid"
    # Idle time counts from the last helper pane closing: a lead waiting on
    # its teammates is idle but not stuck.
    tracked="$st"; [[ "$st" != idle ]] || tracked="idle:$nhelpers"
    since=$(swarm_track "watch-state:$project-$name" "$tracked")
    ssince="$now"
    if [[ -n "$agent_pane" ]]; then
      hash=$(tmx capture-pane -p -t "$agent_pane" 2>/dev/null | cksum)
      ssince=$(swarm_track "watch-screen:$agent_pane" "$hash")
    fi
    case "$st" in
      busy)
        if [[ $((now - since)) -ge $((stall * 60)) && $((now - ssince)) -ge $((stall * 60)) ]]; then
          ct=$(_watch_commit_time "$cwd")
          if [[ "$ct" -lt $((now - stall * 60)) ]]; then
            mins=$(((now - since) / 60))
            active="${active}stalled $name $mins"$'\n'
          fi
        fi ;;
      idle)
        if [[ $nhelpers == 0 && $((now - since)) -ge $((idle_min * 60)) && -z "$report" ]]; then
          active="${active}idle-unreported $name"$'\n'
        fi ;;
    esac
  done <<EOT
$(_swarm_tagged_windows)
EOT
  # Identity of a condition ignores the changing minutes of `stalled`.
  local c key old
  old=""
  [[ ! -f "$file" ]] || old=$(cat "$file")
  while IFS= read -r c; do
    [[ -n "$c" ]] || continue
    key=$(printf '%s' "$c" | awk '$1=="stalled"{print $1" "$2; next}{print $1" "$2}')
    if ! printf '%s\n' "$old" | awk -v k="$key" '{kk=$1" "$2} kk==k{f=1} END{exit !f}'; then
      echo "$c"
    fi
  done <<EOT
$active
EOT
  printf '%s' "$active" > "$file"
}

cmd_watch() {
  local project="" once=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --project) [[ $# -ge 2 ]] || swarm_die "--project needs a name"; project="$2"; shift 2 ;;
      --once) once=1; shift ;;
      *) swarm_die "usage: swarm watch [--project P] [--once]" ;;
    esac
  done
  [[ -n "$project" ]] || project=$(_swarm_caller_project)
  [[ -n "$project" ]] || swarm_die "swarm watch needs --project outside a swarm tab"
  cfg_load
  if [[ $once == 1 ]]; then
    watch_tick "$project"
    return 0
  fi
  while :; do
    watch_tick "$project" || true
    sleep "$(cfg_get poll_sec)"
  done
}
