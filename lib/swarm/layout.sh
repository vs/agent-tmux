# Layouts, helper labels and the retile hook. Sourced by bin/swarm; bash 3.2.
#
# Panes in a tagged window, in pane-index order: shell, agent (orchestrator or
# lieutenant), then helpers. Positions in `list-panes` order are used rather
# than literal indexes so a user's pane-base-index doesn't shift the roles.
#
# This file must stay sourceable on its own: layout_checksum is pure.

# layout_checksum <string> -> tmux's 4-hex-digit layout checksum.
layout_checksum() {
  local s="$1" csum=0 i c
  for ((i = 0; i < ${#s}; i++)); do
    printf -v c '%d' "'${s:i:1}"
    csum=$(( ((csum >> 1) + ((csum & 1) << 15) + c) & 0xffff ))
  done
  printf '%04x' "$csum"
}

# _layout_row <w> <h> <x> <y> <id>...: one row of panes side by side, widths
# split evenly with the remainder on the last pane.
_layout_row() {
  local w="$1" h="$2" x0="$3" y="$4"; shift 4
  local n=$# cw last out="" id i=0 x="$x0"
  if [[ $n == 1 ]]; then
    printf '%sx%s,%s,%s,%s' "$w" "$h" "$x" "$y" "$1"
    return
  fi
  cw=$(( (w - (n - 1)) / n ))
  last=$(( w - (n - 1) - cw * (n - 1) ))
  for id in "$@"; do
    i=$((i + 1))
    [[ -z "$out" ]] || out="$out,"
    if [[ $i == "$n" ]]; then
      out="${out}${last}x${h},${x},${y},${id}"
    else
      out="${out}${cw}x${h},${x},${y},${id}"
      x=$((x + cw + 1))
    fi
  done
  printf '%sx%s,%s,%s{%s}' "$w" "$h" "$x0" "$y" "$out"
}

# layout_grid <W> <H> <shell id> <right id>...: the grid layout body (no
# checksum). Shell column on the left; the right column holds 1-4 panes, one
# filling it, or two rows with ceil(k/2) panes on top.
layout_grid() {
  local W="$1" H="$2" shell="$3"; shift 3
  local S=$(( (W - 1) / 3 )) k=$# R top bot ntop right
  R=$(( W - 1 - S ))
  if [[ $k == 1 ]]; then
    right="${R}x${H},$((S + 1)),0,$1"
  else
    top=$(( (H - 1) / 2 )); bot=$(( H - 1 - top )); ntop=$(( (k + 1) / 2 ))
    right="${R}x${H},$((S + 1)),0[$(_layout_row "$R" "$top" $((S + 1)) 0 "${@:1:ntop}"),$(_layout_row "$R" "$bot" $((S + 1)) $((top + 1)) "${@:ntop+1}")]"
  fi
  printf '%sx%s,0,0{%sx%s,0,0,%s,%s}' "$W" "$H" "$S" "$H" "$shell" "$right"
}

_layout_stack() {
  tmx set-option -w -t "$1" main-pane-width 50% 2>/dev/null || true
  tmx select-layout -t "$1" main-vertical 2>/dev/null || true
}

# swarm_retile_window <@win>: apply @swarm-layout (default stack), then label
# helpers from their --agent-name.
swarm_retile_window() {
  local win="$1" layout panes size ids="" n=0 id pid args name body
  layout=$(swarm_wopt "$win" @swarm-layout)
  panes=$(tmx list-panes -t "$win" -F '#{pane_id} #{pane_pid}' 2>/dev/null) || return 0
  while read -r id pid; do
    [[ -n "$id" ]] || continue
    n=$((n + 1)); ids="$ids ${id#%}"
  done <<EOT
$panes
EOT
  if [[ $n -ge 2 ]]; then
    # Grid has room for shell + 4; with more panes, fall back to stack rather
    # than leave the window half laid out.
    if [[ "$layout" == grid && $n -le 5 ]]; then
      size=$(tmx display-message -p -t "$win" '#{window_width} #{window_height}' 2>/dev/null) || size=""
      if [[ -n "$size" ]]; then
        # shellcheck disable=SC2086
        body=$(layout_grid ${size% *} ${size#* } $ids)
        tmx select-layout -t "$win" "$(layout_checksum "$body"),$body" 2>/dev/null || true
      fi
    else
      _layout_stack "$win"
    fi
  fi

  local re='--agent-name ([^ ]+)' i=0
  while read -r id pid; do
    [[ -n "$id" ]] || continue
    i=$((i + 1))
    [[ $i -ge 3 ]] || continue
    args=$(ps -o args= -p "$pid" 2>/dev/null) || continue
    [[ "$args" =~ $re ]] || continue
    name="${BASH_REMATCH[1]}"
    if [[ "$(tmx display-message -p -t "$id" '#{@name}' 2>/dev/null)" != "$name" ]]; then
      tmx set-option -p -t "$id" @name "$name" 2>/dev/null || true
    fi
  done <<EOT
$panes
EOT
}

# _layout_tagged <session> -> @ids of windows with @swarm-role main/lieutenant,
# except zoomed ones (select-layout would unzoom them). One tmux call: this
# runs from global hooks on every split and kill-pane.
_layout_tagged() {
  local id zoomed role
  tmx list-windows -t "=$1" -F '#{window_id} #{window_zoomed_flag} #{@swarm-role}' 2>/dev/null \
    | while read -r id zoomed role; do
      [[ "$zoomed" != 1 ]] || continue
      case "$role" in main | lieutenant) echo "$id" ;; esac
    done
}

# cmd__retile_session <session> [--now]: run by the after-split-window and
# after-kill-pane hooks. Returns at once (before any delay) if the session has
# no tagged window. The delay lets Claude Code's own layout pass finish first.
# Prints nothing: run-shell shows stdout in the user's pane.
cmd__retile_session() {
  local session="${1:-}" now=0 delay win
  [[ "${2:-}" == --now ]] && now=1
  [[ -n "$session" ]] || return 0
  [[ -n "$(_layout_tagged "$session")" ]] || return 0
  if [[ $now == 0 ]]; then
    cfg_load
    delay=$(cfg_get retile_delay)
    sleep "$delay" 2>/dev/null || true
  fi
  for win in $(_layout_tagged "$session"); do
    swarm_retile_window "$win"
  done
}

# cmd_layout <stack|grid>: switch the caller's lieutenant window layout.
cmd_layout() {
  local want="${1:-}" win
  case "$want" in
    stack | grid) ;;
    *) swarm_die "usage: swarm layout <stack|grid>" ;;
  esac
  win=$(swarm_caller_window 2>/dev/null) || win=""
  if [[ -z "$win" || "$(swarm_wopt "$win" @swarm-role)" != lieutenant ]]; then
    swarm_die "swarm layout must be run from a lieutenant's pane"
  fi
  tmx set-option -w -t "$win" @swarm-layout "$want"
  swarm_retile_window "$win"
}
