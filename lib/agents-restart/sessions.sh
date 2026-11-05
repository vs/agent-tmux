# Session IDs of Codex and Gemini agents for agents-restart, read from the
# session files they write. Sourced after common.sh and discover.sh; bash 3.2
# compatible. ar_session_id (state.sh) dispatches here.

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
