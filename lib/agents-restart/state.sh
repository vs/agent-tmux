# Agent state and session IDs for agents-restart.
# Sourced after common.sh and discover.sh; bash 3.2 compatible.
#
# ar_state <type> ...  and  ar_session_id <type> <pid> <agent_cwd>  dispatch per type;
# each type's implementation lives in its own _ar_<type>_* functions.

# ---- Claude ----------------------------------------------------------------

# ar_claude_refresh -> sets AR_CLAUDE_TSV: "pid status waitingFor sessionId" per
# line, "-" for null/empty. Call once per poll cycle. On failure it is left empty.
ar_claude_refresh() {
  local json
  AR_CLAUDE_TSV=""
  json=$(claude agents --json 2>/dev/null </dev/null) || return 0
  AR_CLAUDE_TSV=$(printf '%s' "$json" | jq -r '
    if type == "array" then .[] else empty end
    | [ (.pid // "" | tostring), (.status // ""), (.waitingFor // "" | tostring), (.sessionId // "") ]
    | map(if . == "" then "-" else gsub("[\t\n]"; " ") end) | @tsv' 2>/dev/null) || AR_CLAUDE_TSV=""
}

# _ar_claude_row <pid> -> the TSV row for that pid, or empty.
_ar_claude_row() {
  printf '%s\n' "${AR_CLAUDE_TSV:-}" | awk -F'\t' -v p="$1" '$1 == p { print; exit }'
}

# ar_screen <sock> <pane> -> pane contents with escapes, trailing blank lines trimmed.
ar_screen() {
  ar_tmux "$1" capture-pane -e -p -t "$2" 2>/dev/null </dev/null | LC_ALL=C awk '
    { lines[NR] = $0 }
    END {
      n = NR
      while (n > 0) {
        t = lines[n]
        gsub(/\033\[[0-9;:?]*[ -\/]*[@-~]/, "", t)
        gsub(/[ \t\r]|\302\240/, "", t)
        if (t != "") break
        n--
      }
      for (i = 1; i <= n; i++) print lines[i]
    }' || true
}

# _ar_clean: stdin lines -> stdout "<kind><TAB><text>" per line, where text has
# all escape sequences removed. With mode "dim", text inside SGR 2 (dim) runs is
# dropped as well (mode "plain" keeps it). NBSP becomes a space. kind is "R" for
# a horizontal rule line, "I" for a line starting with the prompt glyph, else "O".
_ar_clean() {
  LC_ALL=C awk -v mode="$1" '
    function clean(line,   out, i, n, c, j, params, np, k, p, dim, fin, x, skip) {
      out = ""; dim = 0; n = length(line); i = 1
      while (i <= n) {
        c = substr(line, i, 1)
        if (c == "\033") {
          x = substr(line, i + 1, 1)
          if (x == "[") {
            j = i + 2
            while (j <= n && substr(line, j, 1) ~ /[0-9;:?<=>]/) j++
            while (j <= n && substr(line, j, 1) ~ /[ -\/]/) j++
            fin = substr(line, j, 1)
            if (fin == "m") {
              params = substr(line, i + 2, j - i - 2)
              np = split(params, P, /[;:]/)
              if (params == "") dim = 0
              skip = 0
              for (k = 1; k <= np; k++) {
                p = P[k]
                if (skip > 0) { skip--; continue }
                if (p == "" || p == "0" || p == "22") dim = 0
                else if (p == "2") dim = 1
                else if (p == "38" || p == "48" || p == "58") {
                  if (P[k + 1] == "5") skip = 2
                  else if (P[k + 1] == "2") skip = 4
                }
              }
            }
            i = j + 1
          } else if (x == "]") {
            j = i + 2
            while (j <= n) {
              if (substr(line, j, 1) == "\007") { j++; break }
              if (substr(line, j, 2) == "\033\\") { j += 2; break }
              j++
            }
            i = j
          } else {
            i += 2
          }
          continue
        }
        if (!(dim && mode == "dim")) out = out c
        i++
      }
      gsub(/\302\240/, " ", out)
      return out
    }
    {
      t = clean($0)
      s = t; sub(/^[ \t]+/, "", s)
      kind = "O"
      if (s ~ /^\342\224\200\342\224\200/) kind = "R"
      else if (substr(s, 1, 3) == "\342\235\257") kind = "I"
      print kind "\t" t
    }'
}

# ar_input_text <screen> -> text of Claude's input box: the first line after the
# prompt glyph (plus any continuation lines) between the two bottom-most rules,
# with dim runs (the placeholder) removed, whitespace-trimmed.
ar_input_text() {
  printf '%s\n' "$1" | _ar_clean dim | LC_ALL=C awk -F'\t' '
    { kind[NR] = $1; txt[NR] = substr($0, 3) }
    END {
      bot = 0; top = 0
      for (i = NR; i >= 1; i--) if (kind[i] == "R") { if (!bot) bot = i; else { top = i; break } }
      if (!bot || !top) {
        # No complete box: fall back to the last prompt line.
        for (i = NR; i >= 1; i--) if (kind[i] == "I") { top = i - 1; bot = NR + 1; break }
        if (!top && !bot) exit
      }
      out = ""; seen = 0
      for (i = top + 1; i < bot; i++) {
        t = txt[i]
        if (!seen) {
          s = t; sub(/^[ \t]+/, "", s)
          if (substr(s, 1, 3) != "\342\235\257") continue
          t = substr(s, 4); seen = 1
        }
        out = out " " t
      }
      gsub(/^[ \t]+|[ \t]+$/, "", out)
      gsub(/[ \t]+/, " ", out)
      print out
    }'
}

# ar_claude_background <screen> -> e.g. "1 shell" / "2 background tasks", or empty.
# Looks below the input box: footer segments after "·" such as "· 1 shell", and
# subagent rows of the agent panel ("◯ name  description").
ar_claude_background() {
  printf '%s\n' "$1" | _ar_clean plain | LC_ALL=C awk -F'\t' '
    { kind[NR] = $1; txt[NR] = substr($0, 3) }
    END {
      bot = 0
      for (i = NR; i >= 1; i--) if (kind[i] == "R") { bot = i; break }
      if (!bot) exit
      re = "[0-9]+ (shells?|background tasks?|agents?|monitors?|teammates?)([^a-z]|$)"
      out = ""; sub_n = 0
      for (i = bot + 1; i <= NR; i++) {
        t = txt[i]
        p = index(t, "\302\267")
        if (p > 0) {
          rest = substr(t, p + 2)
          while (match(rest, re)) {
            m = substr(rest, RSTART, RLENGTH)
            sub(/[^a-z]$/, "", m)
            out = out (out == "" ? "" : ", ") m
            rest = substr(rest, RSTART + RLENGTH)
          }
        }
        s = t; sub(/^[ \t]+/, "", s)
        if (substr(s, 1, 3) == "\342\227\257") sub_n++
      }
      if (sub_n > 0) out = out (out == "" ? "" : ", ") sub_n " subagent" (sub_n > 1 ? "s" : "")
      print out
    }'
}

# ar_is_teammate <argv_file> -> 0 when argv has --agent-id or --team-name.
ar_is_teammate() {
  local a
  [[ -s "$1" ]] || return 1
  while IFS= read -r -d '' a; do
    case "$a" in
      --agent-id|--agent-id=*|--team-name|--team-name=*) return 0 ;;
    esac
  done < "$1"
  return 1
}

# ar_has_teammates <sock> <pane> <pid> -> 0 when another Claude in the same tmux
# window is a teammate (teammates of a lead live in its window).
ar_has_teammates() {
  local sock="$1" pane="$2" pid="$3" win pid2 tmp hit opid otype rc found=1
  win=$(ar_tmux "$sock" display-message -p -t "$pane" '#{window_id}' 2>/dev/null </dev/null) || return 1
  [[ -n "$win" ]] || return 1
  ar_ps_snapshot
  tmp=$(mktemp "${TMPDIR:-/tmp}/agents-restart-tm.XXXXXX")
  while IFS= read -r pid2; do
    [[ -n "$pid2" ]] || continue
    hit=$(ar_agent_in_pane "$pid2")
    [[ -n "$hit" ]] || continue
    opid="${hit%%$'\t'*}"; otype="${hit#*$'\t'}"
    [[ "$otype" == claude && "$opid" != "$pid" ]] || continue
    rc=0; ar_argv "$opid" "$tmp" || rc=$?
    [[ $rc == 0 || $rc == 2 ]] || continue
    if ar_is_teammate "$tmp"; then found=0; break; fi
  done < <(ar_tmux "$sock" list-panes -t "$win" -F '#{pane_pid}' 2>/dev/null </dev/null)
  rm -f "$tmp"
  return $found
}

# _ar_claude_state <sock> <pane> <pid> <argv_file> -> teammate|prompt|busy|busy:<what>|unsent|idle
_ar_claude_state() {
  local sock="$1" pane="$2" pid="$3" argv_file="$4" row status waiting screen bg
  if ar_is_teammate "$argv_file"; then echo teammate; return; fi
  row=$(_ar_claude_row "$pid")
  if [[ -z "$row" ]]; then
    # No status from `claude agents --json`: cannot rule out a prompt or a turn.
    echo "busy:status unknown"; return
  fi
  status=$(echo "$row" | cut -f2); waiting=$(echo "$row" | cut -f3)
  if [[ "$status" == waiting || "$waiting" != "-" ]]; then echo prompt; return; fi
  if [[ "$status" == busy ]]; then echo busy; return; fi
  screen=$(ar_screen "$sock" "$pane")
  bg=$(ar_claude_background "$screen")
  if [[ -n "$bg" ]]; then echo "busy:$bg"; return; fi
  if ar_has_teammates "$sock" "$pane" "$pid"; then echo "busy:teammates"; return; fi
  if [[ -n "$(ar_input_text "$screen")" ]]; then echo unsent; return; fi
  echo idle
}

# ---- Dispatch ----------------------------------------------------------------

# ar_state <type> <sock> <pane> <pid> <argv_file>
ar_state() {
  local type="$1"; shift
  case "$type" in
    claude) _ar_claude_state "$@" ;;
    *) echo "unsupported type: $type" >&2; return 1 ;;
  esac
}

# ar_session_id <type> <pid> <agent_cwd> -> session id, or "-" when unknown.
ar_session_id() {
  local type="$1" pid="$2" row sid
  case "$type" in
    claude)
      row=$(_ar_claude_row "$pid")
      sid=$(echo "$row" | cut -f4)
      echo "${sid:--}"
      ;;
    *) echo "-" ;;
  esac
}
