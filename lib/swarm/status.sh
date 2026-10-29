# `swarm status`, `peek`, `report`, `close`. Sourced by bin/swarm; bash 3.2.

# _swarm_screen <%pane> <n> -> the last n non-trailing-blank screen lines.
_swarm_screen() {
  tmx capture-pane -p -t "$1" 2>/dev/null \
    | awk '{ l[NR] = $0 } END { n = NR; while (n > 0 && l[n] ~ /^[[:space:]]*$/) n--; for (i = 1; i <= n; i++) print l[i] }' \
    | tail -n "$2"
}

# swarm_pane_state <%pane> -> waiting|running (heuristic for helper panes).
swarm_pane_state() {
  if _swarm_screen "$1" 15 | grep -qE 'Do you want to|❯ 1\. Yes|Allow|Press enter to confirm'; then
    echo waiting
  else
    echo running
  fi
}

# _swarm_tagged_windows -> "@id session" for every swarm-tagged window.
_swarm_tagged_windows() {
  local id sess
  tmx list-windows -a -F '#{window_id} #{session_name}' 2>/dev/null | while read -r id sess; do
    [[ -z "$(swarm_wopt "$id" @swarm-role)" ]] || echo "$id $sess"
  done
}

# _swarm_caller_project -> the caller's project, or empty.
_swarm_caller_project() {
  [[ -n "${TMUX_PANE:-}" ]] || return 0
  local w
  w=$(tmx display-message -p -t "$TMUX_PANE" '#{window_id}' 2>/dev/null) || return 0
  swarm_wopt "$w" @swarm-project
}

# _swarm_agent_pane <@win> -> the agent pane (second in list order).
_swarm_agent_pane() {
  tmx list-panes -t "$1" -F '#{pane_id}' 2>/dev/null | sed -n 2p
}

# _swarm_find_tab <project> <main|lt name> -> @win of that main/lieutenant tab.
_swarm_find_tab() {
  local id sess role
  while read -r id sess; do
    [[ -n "$id" && "$(swarm_wopt "$id" @swarm-project)" == "$1" ]] || continue
    role=$(swarm_wopt "$id" @swarm-role)
    if [[ "$2" == main && "$role" == main ]] \
      || [[ "$role" == lieutenant && "$(swarm_wopt "$id" @swarm-name)" == "$2" ]]; then
      echo "$id"; return 0
    fi
  done <<EOT
$(_swarm_tagged_windows)
EOT
  return 1
}

# swarm_resolve_tab <name|project:name|%pane> -> "@win %pane"; dies if unknown.
swarm_resolve_tab() {
  local t="$1" project name win pane id sess p label
  if [[ "$t" == %* ]]; then
    win=$(tmx display-message -p -t "$t" '#{window_id}' 2>/dev/null) || win=""
    [[ -n "$win" ]] || swarm_die "no such agent or tab '$t'"
    echo "$win $t"; return 0
  fi
  if [[ "$t" == *:* ]]; then
    project="${t%%:*}"; name="${t#*:}"
  else
    project=$(_swarm_caller_project); name="$t"
  fi
  if [[ -n "$project" && -n "$name" ]]; then
    if win=$(_swarm_find_tab "$project" "$name"); then
      pane=$(_swarm_agent_pane "$win")
      echo "$win $pane"; return 0
    fi
    while read -r id sess; do
      [[ -n "$id" && "$(swarm_wopt "$id" @swarm-project)" == "$project" ]] || continue
      while IFS='|' read -r p label; do
        [[ -n "$p" && "$label" == "$name" ]] && { echo "$id $p"; return 0; }
      done <<EOT2
$(tmx list-panes -t "$id" -F '#{pane_id}|#{@name}' | sed 1,2d)
EOT2
    done <<EOT
$(_swarm_tagged_windows)
EOT
  fi
  swarm_die "no such agent or tab '$t'"
}

# _status_agent <session> -> "status<TAB>waitingFor<TAB>cwd<TAB>sessionId".
_status_agent() {
  printf '%s\n' "$_STATUS_TSV" | awk -F'\t' -v n="$1" '$1==n{print $2"\t"$3"\t"$4"\t"$5; exit}'
}

_status_lines() {
  _swarm_screen "$1" 3 | jq -Rs 'split("\n") | map(select(. != ""))'
}

# _status_tab <@win> -> one tab JSON object on a line.
_status_tab() {
  local win="$1" project role name dir layout report tname asess now tab=$'\t'
  project=$(swarm_wopt "$win" @swarm-project)
  role=$(swarm_wopt "$win" @swarm-role)
  name=$(swarm_wopt "$win" @swarm-name)
  dir=$(swarm_wopt "$win" @swarm-dir)
  layout=$(swarm_wopt "$win" @swarm-layout)
  report=$(swarm_wopt "$win" @swarm-report)
  tname=$(tmx display-message -p -t "$win" '#{window_name}')
  now=$(swarm_now)
  if [[ "$role" == main ]]; then asess="$project-main"; else asess="$project-$name"; fi

  local ag st wf cwd sid="-" astate="unknown" branch="" i=0 pid label state since lines panes="" obj
  ag=$(_status_agent "$asess")
  if [[ -n "$ag" ]]; then
    IFS="$tab" read -r st wf cwd sid <<EOT
$ag
EOT
    astate="$st"
    [[ "$wf" == - ]] || astate="$st $wf"
    swarm_record_session_id "$win" "$sid"
    if [[ "$cwd" == - ]]; then
      cwd=""
    else
      branch=$(git -C "$cwd" rev-parse --abbrev-ref HEAD 2>/dev/null) || branch=""
    fi
  else
    cwd=""
  fi
  while IFS='|' read -r pid label; do
    [[ -n "$pid" ]] || continue
    since=null
    if [[ $i == 0 ]]; then state="-"
    elif [[ $i == 1 ]]; then
      state="$astate"; since=$(swarm_track "state:$asess" "$state")
    else
      state=$(swarm_pane_state "$pid"); since=$(swarm_track "state:$pid" "$state")
    fi
    lines=$(_status_lines "$pid")
    obj=$(jq -nc --arg pane "$pid" --arg label "$label" --arg state "$state" \
      --argjson since "$since" --argjson now "$now" --argjson lines "$lines" \
      '{pane:$pane,label:$label,state:$state,since:$since,
        minutes:(if $since == null then null else (($now - $since) / 60 | floor | if . < 0 then 0 else . end) end),
        lines:$lines}')
    panes="${panes:+$panes,}$obj"
    i=$((i + 1))
  done <<EOT
$(tmx list-panes -t "$win" -F '#{pane_id}|#{@name}')
EOT
  jq -nc --arg window "$win" --arg name "$tname" --arg role "$role" --arg project "$project" \
    --arg dir "$dir" --arg report "$report" --arg layout "$layout" --arg cwd "$cwd" \
    --arg branch "$branch" --argjson panes "[${panes}]" \
    '{window:$window,name:$name,role:$role,project:$project,dir:$dir,report:$report,
      layout:$layout,cwd:$cwd,branch:$branch,panes:$panes}'
}

cmd_status() {
  local json=0 all=0 a
  for a in "$@"; do
    case "$a" in
      --json) json=1 ;;
      --all) all=1 ;;
      *) swarm_die "usage: swarm status [--json] [--all]" ;;
    esac
  done
  local only="" id sess tabs=""
  [[ $all == 1 ]] || only=$(_swarm_caller_project)
  _STATUS_TSV=$(swarm_agents_tsv)
  while read -r id sess; do
    [[ -n "$id" ]] || continue
    [[ -z "$only" || "$(swarm_wopt "$id" @swarm-project)" == "$only" ]] || continue
    tabs="$tabs$(_status_tab "$id")"$'\n'
  done <<EOT
$(_swarm_tagged_windows)
EOT
  local data
  data=$(printf '%s' "$tabs" | jq -s '
    group_by(.project) | map({project: .[0].project, dir: .[0].dir,
      tabs: map({window,name,role,report,layout,cwd,branch,panes})})')
  if [[ $json == 1 ]]; then
    printf '%s\n' "$data"
    return 0
  fi
  printf '%s\n' "$data" | jq -r --arg home "$HOME" '
    def pad($n): . + ([range(([$n - length, 0] | max))] | map(" ") | join(""));
    def tilde: if startswith($home) then "~" + .[($home | length):] else . end;
    def mins: if .minutes == null then "" else "\(.minutes)m" end;
    .[] | "\(.project)  (\(.dir | tilde))",
      (.tabs[] | . as $t | $t.panes[1] as $a |
        "  " + ($t.name | pad(14)) + ($t.role | pad(12)) + (($a.state // "unknown") | pad(10))
        + (($a | mins) | pad(6)) + ("report: " + (if $t.report == "" then "-" else $t.report end))
        + (if $t.branch != "" then "  branch " + $t.branch else "" end)
        + (if $t.cwd != "" then "  " + ($t.cwd | tilde) else "" end),
        ($t.panes[] | "    " + (.label | pad(10)) + (.state | pad(10)) + ((. | mins) | pad(5)) + "| "
          + (.lines | join(" ⏎ ") | .[0:100])))'
}

cmd_peek() {
  local target="" n=40
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -n) [[ $# -ge 2 && "$2" =~ ^[0-9]+$ ]] || swarm_die "-n needs a number"; n="$2"; shift 2 ;;
      -*) swarm_die "usage: swarm peek <name|project:name|%pane> [-n lines]" ;;
      *) [[ -z "$target" ]] || swarm_die "usage: swarm peek <name|project:name|%pane> [-n lines]"
         target="$1"; shift ;;
    esac
  done
  [[ -n "$target" ]] || swarm_die "usage: swarm peek <name|project:name|%pane> [-n lines]"
  local r
  r=$(swarm_resolve_tab "$target") || exit 1
  _swarm_screen "${r#* }" "$n"
}

cmd_report() {
  local win kind text
  win=$(swarm_caller_window 2>/dev/null) || win=""
  if [[ -z "$win" || "$(swarm_wopt "$win" @swarm-role)" != lieutenant ]]; then
    swarm_die "swarm report must be run from a lieutenant's pane"
  fi
  kind="${1:-}"
  case "$kind" in done | blocked) shift ;; *) swarm_die "usage: swarm report <done|blocked> <text>" ;; esac
  text="$*"
  [[ -n "${text//[[:space:]]/}" ]] || swarm_die "report needs a message"
  tmx set-option -w -t "$win" @swarm-report "$kind: $text"
}

cmd_close() {
  [[ $# -eq 1 ]] || swarm_die "usage: swarm close <name|project:name>"
  local t="$1" win project name role
  if [[ "$t" == %* ]]; then
    win=$(swarm_resolve_tab "$t"); win="${win% *}"
  else
    if [[ "$t" == *:* ]]; then project="${t%%:*}"; name="${t#*:}"
    else project=$(_swarm_caller_project); name="$t"; fi
    win=""
    [[ -z "$project" ]] || win=$(_swarm_find_tab "$project" "$name") || win=""
    [[ -n "$win" ]] || swarm_die "no such agent or tab '$t'"
  fi
  role=$(swarm_wopt "$win" @swarm-role)
  [[ "$role" == lieutenant ]] || swarm_die "not a lieutenant tab: '$t'"
  project=$(swarm_wopt "$win" @swarm-project)
  name=$(swarm_wopt "$win" @swarm-name)
  tmx kill-window -t "$win"
  echo "closed $project:$name"
}
