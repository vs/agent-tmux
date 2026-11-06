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

# ar_ui_init -> AR_FANCY=1 when stdout is a terminal and NO_COLOR is unset or
# empty, else 0. Color variables are empty when not fancy.
ar_ui_init() {
  AR_FANCY=0
  if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then AR_FANCY=1; fi
  if [[ $AR_FANCY == 1 ]]; then
    AR_C_GREEN=$'\e[32m'; AR_C_YELLOW=$'\e[33m'; AR_C_RED=$'\e[31m'
    AR_C_DIM=$'\e[2m'; AR_C_BOLD=$'\e[1m'; AR_C_OFF=$'\e[0m'
    AR_UI_COLS=$(tput cols 2>/dev/null </dev/tty) || AR_UI_COLS=""
    [[ "$AR_UI_COLS" =~ ^[0-9]+$ && "$AR_UI_COLS" -gt 20 ]] || AR_UI_COLS=80
  else
    AR_C_GREEN=""; AR_C_YELLOW=""; AR_C_RED=""; AR_C_DIM=""; AR_C_BOLD=""; AR_C_OFF=""
    AR_UI_COLS=0
  fi
  AR_UI_N=0; AR_UI_LIVE=0
  AR_UI_PRE=(); AR_UI_PRELEN=(); AR_UI_MARK=(); AR_UI_TEXT=(); AR_UI_TAIL=()
  AR_UI_T0=(); AR_UI_DUR=(); AR_UI_DONE=()
  : "${AR_UI_W_ADDR:=6}" "${AR_UI_W_FOLDER:=8}" "${AR_UI_W_VER:=16}" "${AR_UI_W_STATE:=6}"
  AR_UI_W_TEXT=30
}

# _ar_now_ms -> milliseconds since the epoch (whole seconds when perl is missing).
_ar_now_ms() {
  perl -MTime::HiRes=time -e 'printf "%d\n", time * 1000' 2>/dev/null || echo "$(date +%s)000"
}

# ar_ui_dur <ms> -> "2.1s", "1m12s" or "1h05m".
ar_ui_dur() {
  local ms="$1" s
  [[ "$ms" -ge 0 ]] 2>/dev/null || ms=0
  s=$((ms / 1000))
  if [[ $s -lt 60 ]]; then
    printf '%d.%ds\n' "$s" $(((ms % 1000) / 100))
  elif [[ $s -lt 3600 ]]; then
    printf '%dm%02ds\n' $((s / 60)) $((s % 60))
  else
    printf '%dh%02dm\n' $((s / 3600)) $((s % 3600 / 60))
  fi
}

# _ar_pad <text> <width> -> text followed by spaces up to width (at least one
# column is never added; longer text is returned whole).
_ar_pad() {
  local n=$(($2 - ${#1}))
  printf '%s' "$1"
  [[ $n -le 0 ]] || printf '%*s' "$n" ""
}

# _ar_cols <addr> <folder> <type> -> the pane, folder and type columns plus
# trailing gap, with the pane address dim.
_ar_cols() {
  printf '%s%s%s  %s  %s  ' "$AR_C_DIM" "$(_ar_pad "$1" "$AR_UI_W_ADDR")" "$AR_C_OFF" \
    "$(_ar_pad "$2" "$AR_UI_W_FOLDER")" "$(_ar_pad "$3" 6)"
}

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
  AR_UI_PRE[i]=$(_ar_cols "$1" "$2" "$3")
  AR_UI_PRELEN[i]=$((AR_UI_W_ADDR + 2 + AR_UI_W_FOLDER + 2 + 6 + 2))
  [[ ${#2} -le $AR_UI_W_FOLDER ]] || AR_UI_PRELEN[i]=$((AR_UI_PRELEN[i] + ${#2} - AR_UI_W_FOLDER))
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
    return
  fi
  AR_UI_DUR[i]=""
  [[ -z "$since" ]] || AR_UI_DUR[i]=$(ar_ui_dur $(($(_ar_now_ms) - since)))
  AR_UI_DONE[i]=1
}

# _ar_ui_line <i> <glyph> <dur> [<max width>] -> the row's text.
_ar_ui_line() {
  local i="$1" glyph="$2" dur="$3" max="${4:-0}" text="${AR_UI_TEXT[$1]}" tail="${AR_UI_TAIL[$1]}"
  local tl room
  tl=$((${#text} + ${tail:+1} + ${#tail}))
  if [[ $max -gt 0 ]]; then
    room=$((max - 2 - AR_UI_PRELEN[i] - 2 - ${#dur}))
    if [[ $tl -gt $room ]]; then
      tail=""; [[ $room -ge 2 ]] || room=2
      text="${text:0:$((room - 1))}…"; tl=$room
    fi
  fi
  printf '%s %s%s%s%s' "$glyph" "${AR_UI_PRE[i]}" "$text" "${tail:+ $AR_C_DIM$tail$AR_C_OFF}"
  if [[ -n "$dur" ]]; then
    [[ $tl -ge $AR_UI_W_TEXT ]] || printf '%*s' $((AR_UI_W_TEXT - tl)) ""
    printf '  %s%s%s' "$AR_C_DIM" "$dur" "$AR_C_OFF"
  fi
}

# _ar_ui_glyph <mark> -> the colored status mark.
_ar_ui_glyph() {
  case "$1" in
    ok) printf '%s✓%s' "$AR_C_GREEN" "$AR_C_OFF" ;;
    skip) printf '%s–%s' "$AR_C_YELLOW" "$AR_C_OFF" ;;
    fail) printf '%s✗%s' "$AR_C_RED" "$AR_C_OFF" ;;
  esac
}

# ar_ui_render: print newly finished rows; in fancy mode also redraw the live
# region (cursor up over it, each line cleared with \e[2K, rest of screen
# cleared so a shrinking region leaves nothing behind).
ar_ui_render() {
  local i out="" live=0 now frame
  if [[ $AR_FANCY == 1 && $AR_UI_LIVE -gt 0 ]]; then out=$'\e['"${AR_UI_LIVE}A"$'\r'; fi
  for ((i = 0; i < AR_UI_N; i++)); do
    [[ ${AR_UI_DONE[i]} == 1 ]] || continue
    [[ $AR_FANCY == 0 ]] || out="$out"$'\e[2K'
    out="$out$(_ar_ui_line "$i" "$(_ar_ui_glyph "${AR_UI_MARK[i]}")" "${AR_UI_DUR[i]}")"$'\n'
    AR_UI_DONE[i]=2
  done
  if [[ $AR_FANCY == 1 ]]; then
    now=$(_ar_now_ms)
    frame=${_AR_SPIN[$(((now / 100) % 10))]}
    for ((i = 0; i < AR_UI_N; i++)); do
      [[ ${AR_UI_DONE[i]} == 0 && "${AR_UI_MARK[i]}" == spin ]] || continue
      out="$out"$'\e[2K'"$(_ar_ui_line "$i" "$frame" "$(ar_ui_dur $((now - ${AR_UI_T0[i]:-$now})))" "$AR_UI_COLS")"$'\n'
      live=$((live + 1))
    done
    out="$out"$'\e[J'
    AR_UI_LIVE=$live
  fi
  [[ -z "$out" ]] || printf '%s' "$out"
}

# ar_ui_summary <restarted> <skipped> <failed> <elapsed ms> -> the summary line.
ar_ui_summary() {
  printf '%sagents-restart%s %s✓%s %d restarted · %d skipped · %d failed   %s%s%s\n' \
    "$AR_C_BOLD" "$AR_C_OFF" "$AR_C_GREEN" "$AR_C_OFF" "$1" "$2" "$3" \
    "$AR_C_DIM" "$(ar_ui_dur "$4")" "$AR_C_OFF"
}
