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
  _ar_peers "$1" "$2" | awk -F'\t' -v c="$3" '$2 == c && $1 != "" { print $1 }'
}

# _ar_peers <type> <pid> -> "start<TAB>cwd" of every other live <type> process
# (not <pid>, its descendants or ancestors; not daemons).
_ar_peers() {
  local type="$1" pid="$2" p c
  while IFS= read -r p; do
    [[ -n "$p" ]] || continue
    c=$(_ar_lsof_field "$p" cwd)
    [[ -n "$c" ]] || continue
    printf '%s\t%s\n' "$(_ar_start_epoch "$p" || true)" "$c"
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

# _ar_files_since <start> <dir> <name glob> -> files under dir modified at or
# after <start> (1 s slack, so a file written in the second before counts too);
# returns 1 when the cutoff can't be set up.
_ar_files_since() {
  local start="$1" dir="$2" name="$3" ref stamp
  stamp=$(date -r $((start - 1)) +%Y%m%d%H%M.%S 2>/dev/null || date -d "@$((start - 1))" +%Y%m%d%H%M.%S) || return 1
  ref=$(mktemp "${AR_WD:-${TMPDIR:-/tmp}}/agents-restart-since.XXXXXX") || return 1
  if ! touch -t "$stamp" "$ref" 2>/dev/null; then rm -f "$ref"; return 1; fi
  find "$dir" -type f -name "$name" -newer "$ref" 2>/dev/null || true
  rm -f "$ref"
}

# _ar_pick_session <cands> <peers> -> "sid<TAB>file" of the agent's session, or "-".
# cands: "sid<TAB>mtime<TAB>file" lines (a sid may repeat). The answer is
# "-" unless there is exactly one distinct sid and no live peer (other agent of
# the same type in the same cwd; start epochs, one per line) had started by the
# time any candidate was last written: such a peer could have written it.
_ar_pick_session() {
  printf '%s\n' "$1" | awk -F'\t' -v peers="$(printf '%s' "$2" | tr '\n' ' ')" '
    BEGIN { np = split(peers, P, " ") }
    NF >= 3 && $1 != "" {
      for (i = 1; i <= np; i++) if (P[i] != "" && P[i] + 0 <= $2 + 0) amb = 1
      if (!($1 in seen)) { seen[$1] = 1; n++ }
      if (!($1 in best) || $2 + 0 > bm[$1]) { best[$1] = $3; bm[$1] = $2 + 0 }
      id = $1
    }
    END { if (amb || n != 1) print "-"; else print id "\t" best[id] }'
}

# _ar_argv_after_program <pid> <program> -> argv words after the program word
# (argv0, or argv1 for an interpreter), one per line; empty when unreadable.
_ar_argv_after_program() {
  local tmp a seen=0 b rc=0
  tmp=$(mktemp "${AR_WD:-${TMPDIR:-/tmp}}/agents-restart-argv.XXXXXX")
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


# _ar_codex_home -> Codex's home directory.
_ar_codex_home() { echo "${CODEX_HOME:-$HOME/.codex}"; }

# _ar_codex_target <pid> <home> -> the session ID that `codex [opts] resume
# <id|name>` in the agent's argv resumes; "-" when argv has `resume` but no
# ID that resolves to exactly one existing session (--last, picker, unknown
# or duplicate name); empty when argv has no `resume`.
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
  [[ "$sub" == resume ]] || return 0
  if [[ -n "$t" ]] && ! _ar_uuid "$t"; then
    t=$(jq -r --arg n "$t" 'select(.thread_name? == $n) | .id // empty' "$home/session_index.jsonl" 2>/dev/null | sort -u || true)
    [[ "$(printf '%s\n' "$t" | grep -c .)" == 1 ]] || t=""
  fi
  if [[ -n "$t" ]] && _ar_uuid "$t" && [[ -n "$(_ar_codex_file "$home" "$t")" ]]; then
    echo "$t"
  else
    echo -
  fi
}

# _ar_codex_file <home> <sid> -> the newest rollout file of that session, or empty.
_ar_codex_file() {
  local f best="" bm=-1 m
  while IFS= read -r f; do
    m=$(_ar_mtime "$f") || continue
    if [[ "$m" -gt "$bm" ]]; then best="$f"; bm="$m"; fi
  done < <(find "$1/sessions" "$1/archived_sessions" -type f -name "rollout-*-$2.jsonl*" 2>/dev/null)
  echo "$best"
}

# _ar_codex_meta <file> -> the session_meta payload of a rollout as compact
# JSON (zstd-compressed .jsonl.zst too); returns 1 when it can't be read.
_ar_codex_meta() {
  local line
  case "$1" in
    *.zst) command -v zstd >/dev/null 2>&1 || return 1
           line=$(zstd -dcq "$1" 2>/dev/null | head -n 1) ;;
    *) line=$(head -n 1 "$1" 2>/dev/null) ;;
  esac
  printf '%s\n' "$line" | jq -ce 'select(.type == "session_meta") | .payload | select(type == "object")' 2>/dev/null
}

# _ar_codex_cands <home> <start> -> "sid<TAB>mtime<TAB>file<TAB>cwd" for every
# interactive (originator codex-tui), top-level rollout written since <start>,
# in any cwd. Returns 1 when a rollout written since then can't be read (it
# could be the agent's).
_ar_codex_cands() {
  local home="$1" start="$2" files f meta row
  files=$(_ar_files_since "$start" "$home/sessions" 'rollout-*') || return 1
  while IFS= read -r f; do
    [[ "$f" == *.jsonl || "$f" == *.jsonl.zst ]] || continue
    meta=$(_ar_codex_meta "$f") || return 1
    row=$(printf '%s\n' "$meta" | jq -r '
      select((.id | type) == "string" and (.cwd | type) == "string")
      | select(.originator == "codex-tui")
      | select((.thread_source // "user") == "user")
      | select((.source // "cli" | type) == "string" and .source != "exec")
      | [.id, .cwd] | @tsv' 2>/dev/null) || return 1
    [[ -n "$row" ]] && printf '%s\t%s\t%s\t%s\n' "${row%%$'\t'*}" "$(_ar_mtime "$f" || echo 0)" "$f" "${row#*$'\t'}"
  done <<< "$files"
  return 0
}

# _ar_codex_has_cd <pid> -> 0 when argv sets the working directory (-C/--cd).
_ar_codex_has_cd() {
  local a
  while IFS= read -r a; do
    case "$a" in -C|-C?*|--cd|--cd=*) return 0 ;; esac
  done < <(_ar_argv_after_program "$1" codex)
  return 1
}

# _ar_codex_session <pid> <cwd> -> "sid<TAB>file" of the agent's session, or "-".
# 1. A rollout the agent (or a child) holds open: `lsof -Fn` names matching
#    <codex home>/sessions/.../rollout-...-<uuid>.jsonl.
# 2. Codex 0.166 runs sessions in a shared app-server daemon that holds every
#    rollout open, so the TUI holds none. Candidates are then every codex-tui
#    rollout of the agent's cwd written since it started, plus the session its
#    argv resumes; the session is the only candidate (see _ar_pick_session).
#    `resume` without a resolvable ID gives "-".
#    Codex can run a session in another directory (-C/--cd, or resuming a
#    session into its saved directory), where it would be invisible here: so
#    "-" also when argv has -C/--cd, or when a rollout of another cwd was
#    written since the agent started and no other live Codex runs in that cwd.
_ar_codex_session() {
  local pid="$1" cwd="$2" home rhome pids ids n start target all cands peers f c
  home=$(_ar_codex_home); rhome=$(_ar_realpath "$home")
  ar_ps_snapshot
  pids=$(_ar_tree "$pid" | paste -sd, -)
  ids=$({ lsof -p "${pids:-$pid}" -Fn 2>/dev/null </dev/null || true; } | sed -n 's/^n//p' |
    while IFS= read -r f; do
      [[ "$f" == "$home/sessions/"* || "$f" == "$rhome/sessions/"* ]] || continue
      [[ "$f" =~ /rollout-.*-([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})\.jsonl$ ]] &&
        printf '%s\t%s\n' "${BASH_REMATCH[1]}" "$f"
    done | sort -u)
  n=$(printf '%s' "$ids" | cut -f1 | sort -u | grep -c . || true)
  if [[ "$n" == 1 ]]; then printf '%s\n' "$ids" | head -n 1; return; fi
  if [[ "$n" -gt 1 ]]; then echo -; return; fi
  start=$(_ar_start_epoch "$pid") || { echo -; return; }
  target=$(_ar_codex_target "$pid" "$home")
  [[ "$target" != - ]] || { echo -; return; }
  ! _ar_codex_has_cd "$pid" || { echo -; return; }
  all=$(_ar_codex_cands "$home" "$start") || { echo -; return; }
  peers=$(_ar_peers codex "$pid")
  while IFS= read -r c; do
    [[ -n "$c" && "$c" != "$cwd" ]] || continue
    printf '%s\n' "$peers" | cut -f2 | grep -qxF "$c" || { echo -; return; }
  done < <(printf '%s\n' "$all" | cut -f4 | sort -u)
  cands=$(printf '%s\n' "$all" | awk -F'\t' -v c="$cwd" '$4 == c { print $1 "\t" $2 "\t" $3 }')
  if [[ -n "$target" ]]; then
    f=$(_ar_codex_file "$home" "$target")
    cands=$(printf '%s\n%s\t%s\t%s' "$cands" "$target" "$(_ar_mtime "$f" || echo 0)" "$f")
  fi
  _ar_pick_session "$cands" "$(printf '%s\n' "$peers" | awk -F'\t' -v c="$cwd" '$2 == c && $1 != "" { print $1 }')"
}

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

# _ar_gemini_target <pid> -> the UUID given to --resume/-r/--session-id; "-"
# when such a flag has another value (latest, an index, none); empty when
# argv has none of them.
_ar_gemini_target() {
  local a want="" v="" found=""
  while IFS= read -r a; do
    if [[ -n "$want" ]]; then
      v="$a"; [[ "$v" == -* ]] && v=""
      break
    fi
    case "$a" in
      --resume|-r|--session-id) want="$a"; found=1 ;;
      --resume=*|--session-id=*) v="${a#*=}"; found=1; break ;;
    esac
  done < <(_ar_argv_after_program "$1" gemini)
  [[ -n "$found" ]] || return 0
  if _ar_uuid "$v"; then echo "$v"; else echo -; fi
}

# _ar_gemini_parse <file> -> "sid<TAB>resumable(0|1)", "skip" for a subagent
# session, or returns 1 when the file isn't a session Gemini would read.
# Resumable follows Gemini's isResumableMessageRecord.
_ar_gemini_parse() {
  local recs out
  if [[ "$1" == *.jsonl ]]; then recs='[inputs | fromjson? // empty]'; else recs='[[inputs] | join("\n") | fromjson? // empty]'; fi
  out=$(jq -nRr --arg jsonl "$([[ "$1" == *.jsonl ]] && echo 1)" '
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
    | if .meta.kind == "subagent" then "skip"
      elif (.meta.sessionId | type) != "string" then empty
      else [.meta.sessionId, (if any(.msgs[]?; type == "object" and resumable) then 1 else 0 end)] | @tsv end' < "$1" 2>/dev/null)
  [[ -n "$out" ]] || return 1
  printf '%s\n' "$out"
}

# _ar_gemini_cands <chats> <start> -> "sid<TAB>mtime<TAB>file<TAB>resumable" for
# every top-level session file written since <start>, resumable or not.
# Returns 1 when such a file can't be read.
_ar_gemini_cands() {
  local files f p
  files=$(_ar_files_since "$2" "$1" 'session-*') || return 1
  while IFS= read -r f; do
    [[ "$f" == "$1/session-"*.json || "$f" == "$1/session-"*.jsonl ]] || continue
    [[ "${f#"$1"/}" != */* ]] || continue
    p=$(_ar_gemini_parse "$f") || return 1
    [[ "$p" == skip ]] && continue
    printf '%s\t%s\t%s\t%s\n' "${p%%$'\t'*}" "$(_ar_mtime "$f" || echo 0)" "$f" "${p#*$'\t'}"
  done <<< "$files"
  return 0
}

# _ar_gemini_session <pid> <cwd> -> "sid<TAB>file" of the agent's session, or "-".
# Gemini 0.67 accepts `--resume <uuid>`. Candidates are every top-level session
# file of the project written since the agent started (Gemini writes its own
# at startup, also when resuming), plus the session --resume/--session-id
# names; the session is the only candidate (see _ar_pick_session) and must have
# resumable content. --resume latest/<index> gives "-".
_ar_gemini_session() {
  local pid="$1" cwd="$2" chats start target cands peers pick f p
  ar_ps_snapshot
  start=$(_ar_start_epoch "$pid") || { echo -; return; }
  chats=$(_ar_gemini_chats "$cwd")
  [[ -n "$chats" && -d "$chats" ]] || { echo -; return; }
  target=$(_ar_gemini_target "$pid")
  [[ "$target" != - ]] || { echo -; return; }
  cands=$(_ar_gemini_cands "$chats" "$start") || { echo -; return; }
  if [[ -n "$target" ]]; then
    for f in "$chats"/session-*-"${target:0:8}".json "$chats"/session-*-"${target:0:8}".jsonl; do
      [[ -f "$f" ]] || continue
      p=$(_ar_gemini_parse "$f") || continue
      [[ "${p%%$'\t'*}" == "$target" ]] || continue
      cands=$(printf '%s\n%s\t%s\t%s\t%s' "$cands" "$target" "$(_ar_mtime "$f" || echo 0)" "$f" "${p#*$'\t'}")
    done
    printf '%s\n' "$cands" | cut -f1 | grep -qxF "$target" || { echo -; return; }
  fi
  peers=$(_ar_peer_starts gemini "$pid" "$cwd")
  pick=$(_ar_pick_session "$(printf '%s\n' "$cands" | cut -f1-3)" "$peers")
  [[ "$pick" != - ]] || { echo -; return; }
  # Only a session with something to resume (Gemini rejects others).
  if printf '%s\n' "$cands" | awk -F'\t' -v s="${pick%%$'\t'*}" '$1 == s && $4 == 1 { ok = 1 } END { exit !ok }'; then
    echo "$pick"
  else
    echo -
  fi
}
