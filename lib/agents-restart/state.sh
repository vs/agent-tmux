# Agent state and session IDs for agents-restart.
# Sourced after common.sh and discover.sh; bash 3.2 compatible.
#
# ar_state <type> ...  and  ar_session_id <type> <pid> <agent_cwd>  dispatch per type;
# each type's implementation lives in its own _ar_<type>_* functions.

# ---- Claude ----------------------------------------------------------------

# ar_claude_refresh -> sets AR_CLAUDE_TSV: "pid status waitingFor sessionId" per
# line, "-" for null/empty, and AR_CLAUDE_OK=1 when `claude agents --json`
# succeeded (0 when it failed; the TSV is then empty). Call once per poll cycle.
ar_claude_refresh() {
  local json
  AR_CLAUDE_TSV=""; AR_CLAUDE_OK=0
  json=$(claude agents --json 2>/dev/null </dev/null) || return 0
  AR_CLAUDE_TSV=$(printf '%s' "$json" | jq -r '
    if type == "array" then .[] else empty end
    | select(type == "object")
    | [ (.pid // "" | tostring), (.status // "" | tostring), (.waitingFor // "" | tostring), (.sessionId // "" | tostring) ]
    | map(if . == "" then "-" else gsub("[\t\n]"; " ") end) | @tsv' 2>/dev/null) || return 0
  AR_CLAUDE_OK=1
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

# _ar_clean: stdin lines -> stdout "<kind><TAB><plain><TAB><nodim>" per line.
# plain has all escape sequences removed; nodim additionally drops text inside
# SGR 2 (dim) runs. NBSP becomes a space, tabs become spaces. kind is "R" for a
# horizontal rule line, "I" for a line starting with the prompt glyph, else "O"
# (classified on plain text, so dim rules and prompts still count).
_ar_clean() {
  LC_ALL=C awk '
    function clean(line,   out, i, n, c, j, params, np, k, p, dim, fin, x, skip) {
      out = ""; OUTD = ""; dim = 0; n = length(line); i = 1
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
        out = out c
        if (!dim) OUTD = OUTD c
        i++
      }
      gsub(/\302\240/, " ", out); gsub(/\302\240/, " ", OUTD)
      gsub(/\t/, " ", out); gsub(/\t/, " ", OUTD)
      return out
    }
    {
      t = clean($0)
      s = t; sub(/^[ \t]+/, "", s)
      kind = "O"
      if (s ~ /^\342\224\200\342\224\200/) kind = "R"
      else if (substr(s, 1, 3) == "\342\235\257") kind = "I"
      print kind "\t" t "\t" OUTD
    }'
}

# _ar_input_box <screen> -> "ok<TAB>text" when the input box is positively
# identified (the two bottom-most rule lines with a prompt-glyph line between
# them); text is all non-dim content in the box (placeholder removed), trimmed.
# Prints "bad" otherwise.
_ar_input_box() {
  printf '%s\n' "$1" | _ar_clean | LC_ALL=C awk -F'\t' '
    { kind[NR] = $1; nd[NR] = $3 }
    END {
      bot = 0; top = 0
      for (i = NR; i >= 1; i--) if (kind[i] == "R") { if (!bot) bot = i; else { top = i; break } }
      if (!bot || !top) { print "bad"; exit }
      out = ""; seen = 0
      for (i = top + 1; i < bot; i++) {
        t = nd[i]
        if (!seen && kind[i] == "I") {
          seen = 1
          s = t; sub(/^[ \t]+/, "", s)
          if (substr(s, 1, 3) == "\342\235\257") t = substr(s, 4)
        }
        out = out " " t
      }
      if (!seen) { print "bad"; exit }
      gsub(/^[ \t]+|[ \t]+$/, "", out)
      gsub(/[ \t]+/, " ", out)
      print "ok\t" out
    }'
}

# ar_input_text <screen> -> non-dim text in Claude'"'"'s input box, trimmed; empty when
# the box is empty or not recognized (check ar_input_box_ok for the latter).
ar_input_text() {
  local r; r=$(_ar_input_box "$1")
  [[ "$r" == ok* ]] && printf '%s\n' "${r#ok	}" || true
}

# ar_input_box_ok <screen> -> 0 when the input box is positively identified.
ar_input_box_ok() {
  [[ "$(_ar_input_box "$1" | head -1)" == ok* ]]
}

# ar_claude_background <screen> -> e.g. "1 shell" / "2 background tasks", or empty.
# Looks anywhere below the input box for "N shell(s)|background task(s)|agent(s)|
# monitor(s)|teammate(s)", plus subagent rows of the agent panel ("◯ name  ...").
ar_claude_background() {
  printf '%s\n' "$1" | _ar_clean | LC_ALL=C awk -F'\t' '
    { kind[NR] = $1; txt[NR] = $2 }
    END {
      bot = 0
      for (i = NR; i >= 1; i--) if (kind[i] == "R") { bot = i; break }
      if (!bot) exit
      re = "[0-9]+ (shells?|background tasks?|agents?|monitors?|teammates?)([^a-z]|$)"
      out = ""; sub_n = 0
      for (i = bot + 1; i <= NR; i++) {
        t = txt[i]
        rest = t
        while (match(rest, re)) {
          m = substr(rest, RSTART, RLENGTH)
          sub(/[^a-z]$/, "", m)
          out = out (out == "" ? "" : ", ") m
          rest = substr(rest, RSTART + RLENGTH)
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

# _ar_claude_state <sock> <pane> <pid> <argv_file> -> see ar_state.
_ar_claude_state() {
  local sock="$1" pane="$2" pid="$3" argv_file="$4" row status waiting screen bg
  if ar_is_teammate "$argv_file"; then echo teammate; return; fi
  row=$(_ar_claude_row "$pid")
  if [[ -z "$row" ]]; then
    # Listing worked but this pid is not in it, or the listing itself failed.
    if [[ "${AR_CLAUDE_OK:-0}" == 1 ]]; then echo unlisted; else echo "busy:status unavailable"; fi
    return
  fi
  status=$(echo "$row" | cut -f2); waiting=$(echo "$row" | cut -f3)
  if [[ "$status" == waiting || "$waiting" != "-" ]]; then echo prompt; return; fi
  case "$status" in
    busy) echo busy; return ;;
    idle) ;;
    -) echo "busy:status unknown"; return ;;
    *) echo "busy:$status"; return ;;
  esac
  screen=$(ar_screen "$sock" "$pane")
  bg=$(ar_claude_background "$screen")
  if [[ -n "$bg" ]]; then echo "busy:$bg"; return; fi
  if ar_has_teammates "$sock" "$pane" "$pid"; then echo "busy:teammates"; return; fi
  # idle only when the input box is positively identified and empty.
  if ! ar_input_box_ok "$screen"; then echo unrecognized; return; fi
  if [[ -n "$(ar_input_text "$screen")" ]]; then echo unsent; return; fi
  echo idle
}

# ---- Codex and Gemini --------------------------------------------------------
# Neither has a status API: state comes from the screen, session IDs from the
# session files they write. Screen rules were taken from live codex-cli 0.166.0
# screens and from the gemini-cli 0.67.0 source (its UI could not be observed
# live); anything that doesn't match them reads as `unrecognized` (fail closed).

# Patterns on the plain text of the last 15 screen lines. Prompt patterns start
# from swarm_pane_state (lib/swarm/status.sh).
_AR_PROMPT_RE='Do you want to|❯ 1\. Yes|Allow|Press enter to confirm|Waiting for team lead approval|Waiting for permission'
_AR_CODEX_PROMPT_RE='Would you like to|› 1\. Yes|wants to edit|needs your approval|Approve app tool call'
_AR_GEMINI_PROMPT_RE='Apply this change\?|Ready to start implementation\?|Waiting for user confirmation|● 1\. Allow'
# Codex: "• Working (5s • esc to interrupt)"; Gemini: "Thinking... (esc to cancel, 3s)".
_AR_CODEX_BUSY_RE='esc to interrupt\)|Waiting for background terminal'
_AR_GEMINI_BUSY_RE='esc to interrupt\)|\(esc to cancel, [0-9]'
# Background work left running after a turn.
_AR_CODEX_BG_RE='[0-9]+ background terminals? running'
_AR_GEMINI_BG_RE='[0-9]+ [Bb]ackground process(es)?'

# _ar_codex_input <screen> -> "ok<TAB>text" when Codex's composer is positively
# identified, else "bad". The composer is the bottom-most line starting with "›"
# (not a numbered menu item "› 1. ..."); its draft runs down to the last blank
# line (so blank draft lines stay inside it), and at most 3 footer lines (model,
# hints) follow that. text is the non-dim draft (the placeholder is dim), trimmed.
_ar_codex_input() {
  printf '%s\n' "$1" | _ar_clean | LC_ALL=C awk -F'\t' '
    function blank(s) { return s ~ /^[ \t]*$/ }
    { pl[NR] = $2; nd[NR] = $3 }
    END {
      p = 0
      for (i = NR; i >= 1; i--) if (substr(pl[i], 1, 3) == "\342\200\272") { p = i; break }
      if (!p) { print "bad"; exit }
      rest = substr(pl[p], 4); sub(/^[ \t]+/, "", rest)
      if (rest ~ /^[0-9]+\. /) { print "bad"; exit }
      e = 0
      for (i = NR; i > p; i--) if (blank(pl[i])) { e = i; break }
      if (!e || NR - e > 3) { print "bad"; exit }
      out = nd[p]; sub(/^[ \t]+/, "", out)
      if (substr(out, 1, 3) == "\342\200\272") out = substr(out, 4)
      for (i = p + 1; i < e; i++) out = out " " nd[i]
      gsub(/^[ \t]+|[ \t]+$/, "", out); gsub(/[ \t]+/, " ", out)
      print "ok\t" out
    }'
}

# _ar_gemini_input <screen> -> "ok<TAB>text" when Gemini's input box is
# positively identified, else "bad". The box is the bottom-most line starting
# with the ">" (or YOLO "*") prompt, directly below a border/half-block line or
# a padding line; its draft runs to the next border/half-block line (or, in the
# padded variant without one, to the last blank line), and at most 4 footer
# lines follow. Shell mode ("!"), reverse search and vim NORMAL mode are
# not trusted. The placeholder is drawn in a gray colour, not dim, so the known
# placeholder texts read as empty.
_ar_gemini_input() {
  printf '%s\n' "$1" | _ar_clean | LC_ALL=C awk -F'\t' '
    function blank(s) { return s ~ /^[ \t]*$/ }
    function rule(s,   t) {
      t = s; gsub(/[ \t]/, "", t)
      if (t == "") return 0
      gsub(/\342\224\200|\342\224\201|\342\225\255|\342\225\256|\342\225\257|\342\225\260|\342\226\204|\342\226\200/, "", t)
      return t == ""
    }
    { pl[NR] = $2; nd[NR] = $3 }
    END {
      p = 0
      for (i = NR; i >= 1; i--) if (pl[i] ~ /^ ? ?[>*]( |$)/) { p = i; break }
      if (p < 2 || !(rule(pl[p - 1]) || blank(pl[p - 1]))) { print "bad"; exit }
      e = 0
      for (i = p + 1; i <= NR; i++) if (rule(pl[i])) { e = i; break }
      if (!e) for (i = NR; i > p; i--) if (blank(pl[i])) { e = i; break }
      if (!e) { print "bad"; exit }
      n = 0
      for (i = e + 1; i <= NR; i++) if (!blank(pl[i])) n++
      if (n > 4) { print "bad"; exit }
      first = nd[p]; sub(/^ ? ?[>*] ?/, "", first)
      t = first; gsub(/^[ \t]+|[ \t]+$/, "", t)
      if (t == "Press '"'"'i'"'"' for INSERT mode.") { print "bad"; exit }
      if (t == "Type your message or @path/to/file" || t == "Press '"'"'Esc'"'"' for NORMAL mode." ||
          t ~ /^Type your message or .* \(Esc to exit\)$/) first = ""
      out = first
      for (i = p + 1; i < e; i++) out = out " " nd[i]
      gsub(/^[ \t]+|[ \t]+$/, "", out); gsub(/[ \t]+/, " ", out)
      print "ok\t" out
    }'
}

# _ar_screen_state <codex|gemini> <screen> -> prompt | busy | busy:<what> |
# unrecognized | unsent | idle (see ar_state).
_ar_screen_state() {
  local type="$1" screen="$2" tail prompt_re busy_re bg_re bg r
  case "$type" in
    codex) prompt_re="$_AR_PROMPT_RE|$_AR_CODEX_PROMPT_RE"; busy_re="$_AR_CODEX_BUSY_RE"; bg_re="$_AR_CODEX_BG_RE" ;;
    gemini) prompt_re="$_AR_PROMPT_RE|$_AR_GEMINI_PROMPT_RE"; busy_re="$_AR_GEMINI_BUSY_RE"; bg_re="$_AR_GEMINI_BG_RE" ;;
    *) echo unrecognized; return ;;
  esac
  tail=$(printf '%s\n' "$screen" | _ar_clean | cut -f2 | tail -n 15)
  if printf '%s\n' "$tail" | LC_ALL=C grep -qE "$prompt_re"; then echo prompt; return; fi
  if printf '%s\n' "$tail" | LC_ALL=C grep -qE "$busy_re"; then echo busy; return; fi
  bg=$(printf '%s\n' "$tail" | LC_ALL=C grep -oE "$bg_re" | sed 's/ running$//' | tr 'B' 'b' |
    awk '!seen[$0]++ { out = out (out == "" ? "" : ", ") $0 } END { print out }' || true)
  if [[ -n "$bg" ]]; then echo "busy:$bg"; return; fi
  r=$(_ar_${type}_input "$screen")
  if [[ "$r" != ok* ]]; then echo unrecognized; return; fi
  if [[ -n "${r#ok	}" ]]; then echo unsent; else echo idle; fi
}

# _ar_tree <pid> -> pid and its descendants, one per line, skipping Codex's
# shared app-server/exec-server daemons (they hold every session open).
_ar_tree() {
  awk -v root="$1" "$_AR_AWK_AGENT"'
    { read_ps() }
    END {
      head = 1; tail = 1; queue[1] = root
      while (head <= tail) {
        p = queue[head++]
        if (p != root && args[p] ~ / (app-server|exec-server|mcp-server)( |$)/) continue
        print p
        n = split(kids[p], k, " ")
        for (i = 1; i <= n; i++) queue[++tail] = k[i]
      }
    }' "$AR_PS_FILE"
}

# _ar_peer_starts <type> <pid> <cwd> -> start epochs of the other live <type>
# processes (not <pid>, its descendants or ancestors; not daemons) in <cwd>.
_ar_peer_starts() {
  local type="$1" pid="$2" cwd="$3" p c
  while IFS= read -r p; do
    [[ -n "$p" ]] || continue
    c=$(_ar_lsof_field "$p" cwd)
    [[ "$c" == "$cwd" ]] || continue
    _ar_start_epoch "$p" || true
  done < <(awk -v t="$type" -v me="$pid" "$_AR_AWK_AGENT"'
    { read_ps() }
    END {
      skip[me] = 1
      for (p = parent[me]; p != "" && !(p in skip); p = parent[p]) skip[p] = 1
      head = 1; tail = 1; queue[1] = me
      while (head <= tail) {
        p = queue[head++]; skip[p] = 1
        n = split(kids[p], k, " ")
        for (i = 1; i <= n; i++) queue[++tail] = k[i]
      }
      for (p in args)
        if (!(p in skip) && agent(args[p]) == t && args[p] !~ / (app-server|exec-server|mcp-server)( |$)/) print p
    }' "$AR_PS_FILE")
}

# _ar_pick_session <start> <target> <rows> <peers> -> "id <sid>" | "none" |
# "multi" | "peer". rows: "sid<TAB>created_epoch" per session of the agent's
# cwd; a session is the agent's when it was created at or after the agent
# started, or when it is <target> (the session its argv resumes). It is
# ambiguous ("peer") when another live agent of the same type in that cwd (peer
# start epochs, one per line) had also started by the time it was created.
_ar_pick_session() {
  printf '%s\n' "$3" | awk -F'\t' -v start="$1" -v target="$2" -v peers="$(printf '%s' "$4" | tr '\n' ' ')" '
    BEGIN { np = split(peers, P, " ") }
    NF >= 2 && $1 != "" && $2 + 0 >= start + 0 {
      for (i = 1; i <= np; i++) if (P[i] != "" && P[i] + 0 <= $2 + 0) amb = 1
      if (!($1 in mine)) { mine[$1] = 1; n++; id = $1 }
    }
    END {
      if (target != "" && !(target in mine)) { n++; id = target }
      if (amb) print "peer"
      else if (n == 1) print "id " id
      else if (n > 1) print "multi"
      else print "none"
    }'
}

# _ar_argv_after_program <pid> <program> -> argv words after the program word
# (argv0, or argv1 for an interpreter), one per line; empty when unreadable.
_ar_argv_after_program() {
  local tmp a seen=0 b rc=0
  tmp=$(mktemp "${TMPDIR:-/tmp}/agents-restart-argv.XXXXXX")
  ar_argv "$1" "$tmp" || rc=$?
  if [[ $rc == 0 || $rc == 2 ]]; then
    while IFS= read -r -d '' a; do
      if [[ $seen == 1 ]]; then printf '%s\n' "$a"; continue; fi
      b="${a##*/}"; b="${b%.js}"; b="${b%.mjs}"
      [[ "$b" == "$2" ]] && seen=1
    done < "$tmp"
  fi
  rm -f "$tmp"
}

# _ar_uuid <s> -> 0 when s looks like a session UUID.
_ar_uuid() {
  [[ "$1" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ ]]
}

# jq: epoch -> an ISO-8601 UTC timestamp ("...T23:16:06.176Z") in epoch seconds, 0 if not one.
_AR_JQ_EPOCH='def epoch: if type == "string" then (sub("\\.[0-9]+"; "") | try fromdateiso8601 catch 0) else 0 end;'

# _ar_codex_home -> Codex's home directory.
_ar_codex_home() { echo "${CODEX_HOME:-$HOME/.codex}"; }

# _ar_codex_target <pid> <home> -> the session ID that `codex [opts] resume <id|name>`
# in the agent's argv resumes, when it exists; else empty.
_ar_codex_target() {
  local pid="$1" home="$2" a prev="" sub="" t=""
  while IFS= read -r a; do
    if [[ -n "$prev" ]]; then prev=""; continue; fi
    case "$a" in
      -c|--config|-m|--model|-p|--profile|-s|--sandbox|-a|--ask-for-approval|-C|--cd|-i|--image|\
      --enable|--disable|--remote|--remote-auth-token-env|--add-dir|--local-provider) prev=1; continue ;;
      -*) continue ;;
    esac
    if [[ -z "$sub" ]]; then
      sub="$a"; [[ "$sub" == resume ]] || return 0
    else
      t="$a"; break
    fi
  done < <(_ar_argv_after_program "$pid" codex)
  [[ -n "$t" ]] || return 0
  if ! _ar_uuid "$t"; then
    t=$(jq -r --arg n "$t" 'select(.thread_name? == $n) | .id // empty' "$home/session_index.jsonl" 2>/dev/null | tail -n 1 || true)
    _ar_uuid "$t" || return 0
  fi
  if [[ -n "$(find "$home/sessions" "$home/archived_sessions" -name "rollout-*-$t.jsonl*" 2>/dev/null | head -n 1)" ]]; then
    echo "$t"
  fi
}

# _ar_codex_rows <home> <start> <cwd> -> "sid<TAB>created_epoch" for interactive
# top-level rollouts of <cwd> named at or after <start> (names use local time).
_ar_codex_rows() {
  local home="$1" start="$2" cwd="$3" since f b ts
  since=$(date -r "$start" +%Y%m%d%H%M%S 2>/dev/null || date -d "@$start" +%Y%m%d%H%M%S) || return 0
  while IFS= read -r f; do
    b="${f##*/}"; ts="${b#rollout-}"; ts="${ts:0:19}"; ts="${ts//[^0-9]/}"
    [[ ${#ts} == 14 && "$ts" -ge "$since" ]] || continue
    head -n 1 "$f" 2>/dev/null | jq -r --arg cwd "$cwd" "$_AR_JQ_EPOCH"'
      select(.type? == "session_meta") | .payload
      | select(.cwd == $cwd and (.id | type) == "string")
      | select((.thread_source // "user") == "user")
      | select((.source // "cli" | type) == "string" and .source != "exec")
      | select((.originator // "") != "codex_exec")
      | [.id, (.timestamp | epoch)] | @tsv' 2>/dev/null || true
  done < <(find "$home/sessions" -type f -name 'rollout-*.jsonl' 2>/dev/null)
}

# _ar_codex_session_id <pid> <cwd> -> session id, or "-".
# 1. A rollout the agent (or a child) holds open: `lsof -Fn` names matching
#    <codex home>/sessions/.../rollout-...-<uuid>.jsonl.
# 2. Codex 0.166 runs sessions in a shared app-server daemon that holds every
#    rollout open, so the TUI holds none: the agent's session is the one rollout
#    of its cwd created since it started, or the one its argv resumes; "-" when
#    there is none, more than one, or another live Codex in that cwd could own it.
_ar_codex_session_id() {
  local pid="$1" cwd="$2" home rhome pids ids n start target rows peers pick f
  home=$(_ar_codex_home); rhome=$(_ar_realpath "$home")
  ar_ps_snapshot
  pids=$(_ar_tree "$pid" | paste -sd, -)
  ids=$({ lsof -p "${pids:-$pid}" -Fn 2>/dev/null </dev/null || true; } | sed -n 's/^n//p' |
    while IFS= read -r f; do
      [[ "$f" == "$home/sessions/"* || "$f" == "$rhome/sessions/"* ]] || continue
      [[ "$f" =~ /rollout-.*-([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})\.jsonl$ ]] &&
        echo "${BASH_REMATCH[1]}"
    done | sort -u)
  n=$(printf '%s' "$ids" | grep -c . || true)
  if [[ "$n" == 1 ]]; then echo "$ids"; return; fi
  if [[ "$n" -gt 1 ]]; then echo -; return; fi
  start=$(_ar_start_epoch "$pid") || { echo -; return; }
  target=$(_ar_codex_target "$pid" "$home")
  rows=$(_ar_codex_rows "$home" "$start" "$cwd")
  peers=$(_ar_peer_starts codex "$pid" "$cwd")
  pick=$(_ar_pick_session "$start" "$target" "$rows" "$peers")
  if [[ "$pick" == "id "* ]]; then echo "${pick#id }"; else echo -; fi
}

# _ar_gemini_home -> Gemini's global directory.
_ar_gemini_home() { echo "${GEMINI_CLI_HOME:-$HOME}/.gemini"; }

# _ar_gemini_chats <cwd> -> the chats directory of that project, or empty.
# Gemini 0.67 keeps projects in tmp/<slug>/ with the project path in
# tmp/<slug>/.project_root; older versions used tmp/<sha256 of the path>/.
_ar_gemini_chats() {
  local gh d h
  gh=$(_ar_gemini_home)
  for d in "$gh"/tmp/*/; do
    [[ -f "$d.project_root" ]] || continue
    if [[ "$(cat "$d.project_root" 2>/dev/null)" == "$1" ]]; then echo "${d}chats"; return; fi
  done
  h=$(printf '%s' "$1" | { shasum -a 256 2>/dev/null || sha256sum; } | cut -d' ' -f1)
  [[ -d "$gh/tmp/$h/chats" ]] && echo "$gh/tmp/$h/chats"
  return 0
}

# _ar_gemini_target <pid> -> "uuid <id>" for --resume/-r/--session-id <uuid>,
# "latest" for --resume latest/<index>/no value, else empty.
_ar_gemini_target() {
  local a want="" v=""
  while IFS= read -r a; do
    if [[ -n "$want" ]]; then
      v="$a"; [[ "$v" == -* ]] && v=latest
      break
    fi
    case "$a" in
      --resume|-r|--session-id) want="$a" ;;
      --resume=*|--session-id=*) v="${a#*=}"; v="${v:-latest}"; break ;;
    esac
  done < <(_ar_argv_after_program "$1" gemini)
  [[ -n "$want" && -z "$v" ]] && v=latest
  [[ -n "$v" ]] || return 0
  if _ar_uuid "$v"; then echo "uuid $v"; else echo latest; fi
}

# _ar_gemini_rows <chats> <start> -> "sid<TAB>created<TAB>mtime<TAB>resumable(0|1)"
# for top-level, non-subagent sessions named or written at/after <start>.
_ar_gemini_rows() {
  local chats="$1" start="$2" since f b ts mt recs
  since=$(date -u -r "$start" +%Y%m%d%H%M 2>/dev/null || date -u -d "@$start" +%Y%m%d%H%M) || return 0
  for f in "$chats"/session-*.json "$chats"/session-*.jsonl; do
    [[ -f "$f" ]] || continue
    mt=$(_ar_mtime "$f") || continue
    b="${f##*/}"; ts="${b#session-}"; ts="${ts:0:16}"; ts="${ts//[^0-9]/}"
    [[ "$mt" -ge "$start" || ( ${#ts} == 12 && "$ts" -ge "$since" ) ]] || continue
    if [[ "$f" == *.jsonl ]]; then recs='[inputs | fromjson? // empty]'; else recs='[[inputs] | join("\n") | fromjson? // empty]'; fi
    jq -nRr --arg mt "$mt" --arg jsonl "$([[ "$f" == *.jsonl ]] && echo 1)" "$_AR_JQ_EPOCH"'
      def text: if type == "string" then .
        elif type == "array" then map(if type == "string" then . elif type == "object" then (.text // "") else "" end) | join("")
        elif type == "object" then (.text // "") else "" end;
      def trimmed: gsub("^\\s+|\\s+$"; "");
      def resumable:
        (.type == "gemini" and (((.content // "") | text | trimmed) != "" or ((.toolCalls // []) | length) > 0 or ((.thoughts // []) | length) > 0))
        or (.type == "user" and (((.content // "") | text | trimmed) as $t
              | $t != "" and ($t | test("^(/|\\?|<session_context>|<hook_context>)") | not)));
      '"$recs"' as $r
      | (if $jsonl == "1" then {meta: ($r[0] // {}), msgs: $r[1:]} else {meta: ($r[0] // {}), msgs: ($r[0].messages // [])} end)
      | select((.meta.sessionId | type) == "string" and .meta.kind != "subagent")
      | [.meta.sessionId, (.meta.startTime | epoch), $mt, (if any(.msgs[]?; type == "object" and resumable) then 1 else 0 end)]
      | @tsv' < "$f" 2>/dev/null || true
  done
}

# _ar_gemini_session_id <pid> <cwd> -> the value for `gemini --resume`: the
# session UUID (0.67 accepts it), "latest" when the session can't be pinned
# down, or "-" when guessing would be wrong (another live Gemini in the same
# project could own it, or the agent's own session has nothing to resume yet).
# The agent's session is the one created since it started or the one its argv
# resumes (for `-r latest`/`-r <index>`, the one written since it started).
_ar_gemini_session_id() {
  local pid="$1" cwd="$2" chats start target tid="" rows res peers pick own w
  ar_ps_snapshot
  start=$(_ar_start_epoch "$pid") || { echo -; return; }
  chats=$(_ar_gemini_chats "$cwd")
  peers=$(_ar_peer_starts gemini "$pid" "$cwd")
  [[ -n "$chats" && -d "$chats" ]] || { if [[ -n "$peers" ]]; then echo -; else echo latest; fi; return; }
  target=$(_ar_gemini_target "$pid")
  rows=$(_ar_gemini_rows "$chats" "$start")
  res=$(printf '%s\n' "$rows" | awk -F'\t' '$4 == 1')
  if [[ "$target" == "uuid "* ]]; then
    tid="${target#uuid }"
    if ! printf '%s\n' "$res" | cut -f1 | grep -qxF "$tid" &&
       [[ -z "$(find "$chats" -maxdepth 1 -name "session-*-${tid:0:8}.json*" 2>/dev/null | head -n 1)" ]]; then
      tid=""
    fi
  fi
  pick=$(_ar_pick_session "$start" "$tid" "$(printf '%s\n' "$res" | cut -f1,2)" "$peers")
  case "$pick" in
    "id "*) echo "${pick#id }"; return ;;
    peer) echo -; return ;;
  esac
  [[ -z "$peers" ]] || { echo -; return; }
  if [[ "$pick" == none ]]; then
    own=$(_ar_pick_session "$start" "" "$(printf '%s\n' "$rows" | cut -f1,2)" "")
    if [[ "$own" != none && "$target" != latest ]]; then echo -; return; fi
    if [[ "$target" == latest ]]; then
      w=$(printf '%s\n' "$res" | awk -F'\t' -v s="$start" '$3 + 0 >= s + 0 && $2 + 0 < s + 0 { print $1 }' | sort -u)
      if [[ -n "$w" && "$(printf '%s\n' "$w" | wc -l | tr -d ' ')" == 1 ]]; then echo "$w"; return; fi
    fi
  fi
  echo latest
}

# ---- Dispatch ----------------------------------------------------------------

# ar_state <type> <sock> <pane> <pid> <argv_file> -> one of:
#   teammate      teammate process (skip)
#   prompt        waiting on a permission/question prompt (skip)
#   busy          working
#   busy:<what>   background work, live teammates, unknown/unavailable status (wait)
#   unsent        unsent text in the input box (skip)
#   unrecognized  input box not positively identified (claude: while json says idle) (skip)
#   unlisted      not in a successful `claude agents --json` listing (cannot restart)
#   idle          safe to restart
# claude uses `claude agents --json` plus the screen; codex and gemini only the
# screen (prompt, busy, busy:<what>, unrecognized, unsent, idle).
ar_state() {
  local type="$1"; shift
  case "$type" in
    claude) _ar_claude_state "$@" ;;
    codex|gemini) _ar_screen_state "$type" "$(ar_screen "$1" "$2")" ;;
    *) echo "unsupported type: $type" >&2; return 1 ;;
  esac
}

# ar_session_id <type> <pid> <agent_cwd> -> session id, or "-" when unknown.
# gemini may also return "latest" (resume argument when the session can't be
# pinned down; shown as `resume: latest`).
ar_session_id() {
  local type="$1" pid="$2" row sid
  case "$type" in
    claude)
      row=$(_ar_claude_row "$pid")
      sid=$(echo "$row" | cut -f4)
      echo "${sid:--}"
      ;;
    codex) _ar_codex_session_id "$pid" "${3:-}" ;;
    gemini) _ar_gemini_session_id "$pid" "${3:-}" ;;
    *) echo "-" ;;
  esac
}
