# Terminal output for agents-restart: header, plan lines, result lines and the
# summary. Sourced after common.sh and discover.sh; bash 3.2 compatible.
#
# Result lines live in a list of rows (ar_ui_add). A row with mark "spin" is in
# progress: in fancy mode it sits in the live region at the bottom, redrawn in
# place with a spinner and elapsed time by ar_ui_render. A row given a final
# mark (ok, skip, fail) is printed once, above the live region, and never
# redrawn. Not fancy: no colors, spinners or redraws; each row is printed as
# one plain line when it finishes.

_AR_SPIN=(⠋ ⠙ ⠹ ⠸ ⠼ ⠴ ⠦ ⠧ ⠇ ⠏)

# Nothing on the render path runs in $(...) except the clock read (at most
# once a second, see _ar_ui_tick): a Ctrl+C
# kills such subshells (they don't inherit the INT trap), so the helpers below
# return their result in a variable (_AR_V, _AR_LINE, AR_NOW) instead.

# _ar_term_cols -> the terminal width: `stty size` on /dev/tty, else tput with
# stderr on the terminal (ncurses reads the size from stdout/stderr), else 80.
_ar_term_cols() {
  local sz c=""
  if sz=$(stty size </dev/tty 2>/dev/null); then c="${sz##* }"; fi
  [[ "$c" =~ ^[0-9]+$ && "$c" -gt 0 ]] || c=$({ tput cols 2>/dev/tty; } 2>/dev/null) || c=""
  [[ "$c" =~ ^[0-9]+$ && "$c" -gt 0 ]] || c=80
  echo "$c"
}

# ar_ui_init -> AR_FANCY=1 when stdout is a terminal and NO_COLOR is unset or
# empty, else 0. Colors are on when fancy, or when CLICOLOR_FORCE is set to
# anything but 0 (and NO_COLOR is unset or empty): colored plain lines, no
# redraws, for viewers that render ANSI colors but not cursor movement (a
# Raycast script command's full output). Color variables are empty otherwise.
# Test hooks: AGENTS_RESTART_TEST_FANCY=1 forces fancy mode,
# AGENTS_RESTART_TEST_COLS the width.
ar_ui_init() {
  local color=0
  AR_FANCY=0
  if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then AR_FANCY=1; fi
  [[ "${AGENTS_RESTART_TEST_FANCY:-}" != 1 ]] || AR_FANCY=1
  if [[ $AR_FANCY == 1 ]] ||
     [[ -n "${CLICOLOR_FORCE:-}" && "${CLICOLOR_FORCE}" != 0 && -z "${NO_COLOR:-}" ]]; then
    color=1
  fi
  if [[ $color == 1 ]]; then
    AR_C_GREEN=$'\e[32m'; AR_C_YELLOW=$'\e[33m'; AR_C_RED=$'\e[31m'
    AR_C_DIM=$'\e[2m'; AR_C_BOLD=$'\e[1m'; AR_C_OFF=$'\e[0m'
  else
    AR_C_GREEN=""; AR_C_YELLOW=""; AR_C_RED=""; AR_C_DIM=""; AR_C_BOLD=""; AR_C_OFF=""
  fi
  if [[ $AR_FANCY == 1 ]]; then
    if [[ "${AGENTS_RESTART_TEST_COLS:-}" =~ ^[0-9]+$ ]]; then
      AR_UI_COLS=$AGENTS_RESTART_TEST_COLS
    else
      AR_UI_COLS=$(_ar_term_cols)
    fi
  else
    AR_UI_COLS=0
  fi
  AR_UI_N=0; AR_UI_LIVE=0
  AR_UI_PRE=(); AR_UI_PREPLAIN=(); AR_UI_MARK=(); AR_UI_TEXT=(); AR_UI_TAIL=()
  AR_UI_T0=(); AR_UI_DUR=(); AR_UI_DONE=()
  : "${AR_UI_W_ADDR:=6}" "${AR_UI_W_FOLDER:=8}" "${AR_UI_W_VER:=16}" "${AR_UI_W_STATE:=6}"
  AR_UI_W_TEXT=30
  AR_NOW="$(date +%s)000"
  _AR_FRAME=0
  ar_ui_clock
}

# _ar_now_ms -> milliseconds since the epoch (whole seconds when perl is missing).
_ar_now_ms() {
  perl -MTime::HiRes=time -e 'printf "%d\n", time * 1000' 2>/dev/null || echo "$(date +%s)000"
}

# ar_ui_clock: AR_NOW = now in ms; keeps the last value when the read is cut
# short. It spawns a process, so it runs at events (a restart starting or
# ending, the summary) and, through _ar_ui_tick, at most once a second.
ar_ui_clock() {
  local t
  t=$(_ar_now_ms) || t=""
  if [[ "$t" =~ ^[0-9]+$ ]]; then AR_NOW=$t; fi
  _AR_CLK_S=$SECONDS
  return 0
}

# _ar_ui_tick: once per frame: advance the spinner, and read the clock only
# when $SECONDS has moved on since the last read, so live elapsed times
# update once a second.
_ar_ui_tick() {
  _AR_FRAME=$(((${_AR_FRAME:-0} + 1) % 10))
  [[ "$SECONDS" == "${_AR_CLK_S:-}" ]] || ar_ui_clock
}

# _ar_dur_v <ms>: _AR_V = "2.1s", "1m12s" or "1h05m".
_ar_dur_v() {
  local ms="$1" s
  [[ "$ms" =~ ^[0-9]+$ ]] || ms=0
  s=$((ms / 1000))
  if [[ $s -lt 60 ]]; then
    printf -v _AR_V '%d.%ds' "$s" $(((ms % 1000) / 100))
  elif [[ $s -lt 3600 ]]; then
    printf -v _AR_V '%dm%02ds' $((s / 60)) $((s % 60))
  else
    printf -v _AR_V '%dh%02dm' $((s / 3600)) $((s % 3600 / 60))
  fi
}

# ar_ui_dur <ms> -> the same, printed.
ar_ui_dur() { _ar_dur_v "$1"; echo "$_AR_V"; }

# _ar_pad_v <text> <width>: _AR_V = text padded with spaces to width (longer
# text is kept whole).
_ar_pad_v() {
  local n=$(($2 - ${#1}))
  [[ $n -gt 0 ]] || n=0
  printf -v _AR_V '%s%*s' "$1" "$n" ""
}

# _ar_pad <text> <width> -> the same, printed.
_ar_pad() { _ar_pad_v "$1" "$2"; printf '%s' "$_AR_V"; }

# _ar_cols_v <addr> <folder> <type>: _AR_V = the pane, folder and type columns
# plus trailing gap, pane address dim; _AR_V2 = the same without colors.
_ar_cols_v() {
  local a f t
  _ar_pad_v "$1" "$AR_UI_W_ADDR"; a=$_AR_V
  _ar_pad_v "$2" "$AR_UI_W_FOLDER"; f=$_AR_V
  _ar_pad_v "$3" 6; t=$_AR_V
  _AR_V2="$a  $f  $t  "
  _AR_V="$AR_C_DIM$a$AR_C_OFF  $f  $t  "
}

# _ar_cols <addr> <folder> <type> -> the colored columns, printed.
_ar_cols() { _ar_cols_v "$1" "$2" "$3"; printf '%s' "$_AR_V"; }

# ar_ui_header -> "agents-restart  claude X · codex Y · gemini Z" (installed tools only).
ar_ui_header() {
  local t v out=""
  for t in claude codex gemini; do
    ar_installed_version "$t" >/dev/null
    v=$(ar_installed_version "$t")
    [[ -z "$v" ]] || out="$out${out:+ · }$t $v"
  done
  printf '%sagents-restart%s%s\n' "$AR_C_BOLD" "$AR_C_OFF" "${out:+  $out}"
}

# ar_ui_ver <old> <new> -> the version column text.
ar_ui_ver() {
  if [[ "$1" == - ]]; then echo "version unknown"; else echo "$1 → $2"; fi
}

# ar_ui_plan_line <addr> <folder> <type> <old> <new> <state> <sid>: one plan
# line. state "self" renders "this pane, skipped"; sid is shortened to 8 chars.
ar_ui_plan_line() {
  local addr="$1" folder="$2" type="$3" old="$4" new="$5" state="$6" sid="${7:--}"
  if [[ "$state" == self ]]; then
    printf '  %sthis pane, skipped\n' "$(_ar_cols "$addr" "$folder" "$type")"
    return
  fi
  printf '  %s%s  %s  %s%s%s\n' "$(_ar_cols "$addr" "$folder" "$type")" \
    "$(_ar_pad "$(ar_ui_ver "$old" "$new")" "$AR_UI_W_VER")" "$(_ar_pad "$state" "$AR_UI_W_STATE")" \
    "$AR_C_DIM" "${sid:0:8}" "$AR_C_OFF"
}

# ar_ui_uptodate <n> -> dim "N agent(s) up to date, left alone".
ar_ui_uptodate() {
  local s=s
  [[ "$1" != 1 ]] || s=""
  printf '  %s%d agent%s up to date, left alone%s\n' "$AR_C_DIM" "$1" "$s" "$AR_C_OFF"
}

# ar_ui_add <addr> <folder> <type> -> adds a hidden row; its index is in AR_UI_LAST.
ar_ui_add() {
  local i=$AR_UI_N
  _ar_cols_v "$1" "$2" "$3"
  AR_UI_PRE[i]=$_AR_V; AR_UI_PREPLAIN[i]=$_AR_V2
  AR_UI_MARK[i]=""; AR_UI_TEXT[i]=""; AR_UI_TAIL[i]=""; AR_UI_T0[i]=""; AR_UI_DUR[i]=""; AR_UI_DONE[i]=0
  AR_UI_N=$((i + 1))
  AR_UI_LAST=$i
}

# ar_ui_set <i> <mark> <text> [<since_ms>] [<dim tail>]: update row i.
# mark spin: in progress; elapsed counts from since_ms (kept when omitted).
# mark ok|skip|fail: finished; elapsed (since since_ms, if given) is frozen now.
# The dim tail (a session ID) follows the text.
ar_ui_set() {
  local i="$1" mark="$2" since="${4:-}"
  AR_UI_TEXT[i]="$3"; AR_UI_TAIL[i]="${5:-}"; AR_UI_MARK[i]="$mark"
  if [[ "$mark" == spin ]]; then
    [[ -z "$since" ]] || AR_UI_T0[i]="$since"
    return 0
  fi
  AR_UI_DUR[i]=""
  if [[ -n "$since" ]]; then
    ar_ui_clock
    _ar_dur_v $((AR_NOW - since)); AR_UI_DUR[i]=$_AR_V
  fi
  AR_UI_DONE[i]=1
}

# _ar_ui_line_v <i> <glyph> <dur> [<max cols> [nocut]]: _AR_LINE = the row's line.
# With max, the line is kept below max columns: the text is cut (and its
# padding shrunk) to fit; when even the columns don't fit, the whole line is
# cut, without colors. With nocut (frozen lines) only the padding shrinks.
_ar_ui_line_v() {
  local i="$1" glyph="$2" dur="$3" max="${4:-0}" text="${AR_UI_TEXT[$1]}" tail="${AR_UI_TAIL[$1]}"
  local tl dpart=0 room w=$AR_UI_W_TEXT s pre="${AR_UI_PREPLAIN[$1]}"
  tl=$((${#text} + ${#tail}))
  [[ -z "$tail" ]] || tl=$((tl + 1))
  [[ -z "$dur" ]] || dpart=$((2 + ${#dur}))
  if [[ $max -gt 0 ]]; then
    room=$((max - 1 - 2 - ${#pre} - dpart))
    if [[ "${5:-}" == nocut ]]; then
      [[ $room -ge $tl ]] || room=$tl
    elif [[ $room -lt 4 ]]; then
      s="$pre$text"; room=$((max - 3)); [[ $room -ge 1 ]] || room=1
      [[ ${#s} -le $room ]] || s="${s:0:$((room - 1))}…"
      _AR_LINE="$glyph $s"
      return 0
    fi
    if [[ $tl -gt $room ]]; then tail=""; text="${text:0:$((room - 1))}…"; tl=$room; fi
    [[ $w -le $room ]] || w=$room
  fi
  _AR_LINE="$glyph ${AR_UI_PRE[i]}$text${tail:+ $AR_C_DIM$tail$AR_C_OFF}"
  if [[ -n "$dur" ]]; then
    if [[ $tl -lt $w ]]; then printf -v s '%*s' $((w - tl)) ""; _AR_LINE="$_AR_LINE$s"; fi
    _AR_LINE="$_AR_LINE  $AR_C_DIM$dur$AR_C_OFF"
  fi
}

# ar_ui_render: print newly finished rows; in fancy mode also redraw the live
# region: cursor up over it, the screen below cleared (\e[J: a frozen line
# that wraps lands on blank rows), then each live line cleared (\e[2K) and
# drawn. Live lines stay narrower than the terminal, so the cursor-up count
# stays right; frozen lines only lose padding to fit.
ar_ui_render() {
  local i out="" live=0 frame glyph
  if [[ $AR_FANCY == 1 ]]; then
    [[ $AR_UI_LIVE -eq 0 ]] || out=$'\e['"${AR_UI_LIVE}A"
    out="$out"$'\r\e[J'
  fi
  for ((i = 0; i < AR_UI_N; i++)); do
    [[ ${AR_UI_DONE[i]} == 1 ]] || continue
    case "${AR_UI_MARK[i]}" in
      ok) glyph="${AR_C_GREEN}✓${AR_C_OFF}" ;;
      skip) glyph="${AR_C_YELLOW}–${AR_C_OFF}" ;;
      *) glyph="${AR_C_RED}✗${AR_C_OFF}" ;;
    esac
    _ar_ui_line_v "$i" "$glyph" "${AR_UI_DUR[i]}" "$AR_UI_COLS" nocut
    out="$out$_AR_LINE"$'\n'
    AR_UI_DONE[i]=2
  done
  if [[ $AR_FANCY == 1 ]]; then
    _ar_ui_tick
    frame=${_AR_SPIN[_AR_FRAME]}
    for ((i = 0; i < AR_UI_N; i++)); do
      [[ ${AR_UI_DONE[i]} == 0 && "${AR_UI_MARK[i]}" == spin ]] || continue
      _ar_dur_v $((AR_NOW - ${AR_UI_T0[i]:-$AR_NOW}))
      _ar_ui_line_v "$i" "$frame" "$_AR_V" "$AR_UI_COLS"
      out="$out"$'\e[2K'"$_AR_LINE"$'\n'
      live=$((live + 1))
    done
    AR_UI_LIVE=$live
  fi
  [[ -z "$out" ]] || printf '%s' "$out"
  return 0
}

# ar_ui_summary <restarted> <skipped> <failed> <elapsed ms> -> the summary line.
ar_ui_summary() {
  printf '%sagents-restart%s %s✓%s %d restarted · %d skipped · %d failed   %s%s%s\n' \
    "$AR_C_BOLD" "$AR_C_OFF" "$AR_C_GREEN" "$AR_C_OFF" "$1" "$2" "$3" \
    "$AR_C_DIM" "$(ar_ui_dur "$4")" "$AR_C_OFF"
}
