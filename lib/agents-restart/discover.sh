# Discovery for agents-restart: panes, agent processes, versions.
# Sourced after common.sh; bash 3.2 compatible.

_AR_TAB=$'\t'

# ar_panes -> TSV: sock pane_id addr pane_pid shell_cwd, for every pane on every socket.
ar_panes() {
  local sock
  while IFS= read -r sock; do
    ar_tmux "$sock" list-panes -a -F \
      "#{pane_id}${_AR_TAB}#{session_name}:#{window_index}.#{pane_index}${_AR_TAB}#{pane_pid}${_AR_TAB}#{pane_current_path}" \
      2>/dev/null </dev/null |
      awk -F'\t' -v s="$sock" 'BEGIN { OFS = "\t" }
        { for (i = 1; i <= 4; i++) if ($i == "") $i = "-"; print s, $1, $2, $3, $4 }' || true
  done < <(ar_sockets)
}

# ar_ps_snapshot -> fills $AR_PS_FILE (created if unset) with "pid ppid args".
ar_ps_snapshot() {
  if [[ -z "${AR_PS_FILE:-}" ]]; then
    AR_PS_FILE=$(mktemp "${TMPDIR:-/tmp}/agents-restart-ps.XXXXXX")
  fi
  ps -A -o pid=,ppid=,args= > "$AR_PS_FILE" 2>/dev/null </dev/null || true
}

# awk functions shared by the process-table readers: agent(args) -> the agent
# type an argv line runs ("" when none); base(path) -> last path component.
_AR_AWK_AGENT='
    function base(p,   n, a) { n = split(p, a, "/"); return a[n] }
    function agent(args,   n, a, b0, b1) {
      n = split(args, a, /[ \t]+/)
      b0 = base(a[1]); sub(/^-/, "", b0)
      if (b0 ~ /^(claude|codex|gemini)$/) return b0
      if (b0 ~ /^(node|bash|sh|python[0-9.]*)$/ && n >= 2) {
        b1 = base(a[2]); sub(/\.(m?js)$/, "", b1)
        if (b1 ~ /^(claude|codex|gemini)$/) return b1
      }
      return ""
    }
    function read_ps(   line) {
      pid = $1; ppid = $2
      line = $0; sub(/^[ \t]*[0-9]+[ \t]+[0-9]+[ \t]*/, "", line)
      args[pid] = line; parent[pid] = ppid
      kids[ppid] = kids[ppid] " " pid
    }'

# ar_agent_in_pane <pane_pid> -> "pid<TAB>type" of the topmost agent descendant.
ar_agent_in_pane() {
  local root="$1"
  [[ -n "${AR_PS_FILE:-}" && -s "$AR_PS_FILE" ]] || ar_ps_snapshot
  awk -v root="$root" "$_AR_AWK_AGENT"'
    { read_ps() }
    END {
      head = 1; tail = 1; queue[1] = root
      while (head <= tail) {
        p = queue[head++]
        if (p in args) {
          t = agent(args[p])
          if (t != "") { print p "\t" t; exit }
        }
        n = split(kids[p], k, " ")
        for (i = 1; i <= n; i++) queue[++tail] = k[i]
      }
    }' "$AR_PS_FILE"
}

# _ar_realpath <path> -> absolute path with symlinks resolved; unchanged if missing.
_ar_realpath() {
  local p="$1" d n=0 l
  [[ -e "$p" || -L "$p" ]] || { echo "$p"; return; }
  while [[ -L "$p" && $n -lt 20 ]]; do
    d=$(cd "$(dirname "$p")" && pwd -P)
    l=$(readlink "$p")
    [[ "$l" == /* ]] && p="$l" || p="$d/$l"
    n=$((n + 1))
  done
  d=$(cd "$(dirname "$p")" 2>/dev/null && pwd -P) || { echo "$p"; return; }
  echo "$d/$(basename "$p")"
}

# _ar_lsof_field <pid> <fd> -> first path reported for that fd ("txt" or "cwd").
_ar_lsof_field() {
  { lsof -p "$1" -a -d "$2" -Fn 2>/dev/null </dev/null | sed -n 's/^n//p' | head -1; } || true
}

# ar_running_path <pid> -> realpath of the running program (may be deleted).
ar_running_path() {
  local pid="$1" args a0 a1 b0 p
  [[ -n "${AR_PS_FILE:-}" && -s "$AR_PS_FILE" ]] || ar_ps_snapshot
  args=$(awk -v p="$pid" '$1 == p { sub(/^[ \t]*[0-9]+[ \t]+[0-9]+[ \t]*/, ""); print; exit }' "$AR_PS_FILE")
  # shellcheck disable=SC2086
  set -- $args
  a0="${1:-}"; a1="${2:-}"
  b0="${a0##*/}"; b0="${b0#-}"
  case "$b0" in
    node|bash|sh|python*)
      if [[ -n "$a1" ]]; then
        p="$a1"
        if [[ "$p" != /* ]]; then
          local cwd; cwd=$(_ar_lsof_field "$pid" cwd)
          [[ -n "$cwd" ]] && p="$cwd/$p"
        fi
        _ar_realpath "$p"
        return
      fi
      ;;
  esac
  p=$(_ar_lsof_field "$pid" txt)
  [[ -n "$p" ]] && _ar_realpath "$p" || true
}

# ar_version_from_path <path> -> last x.y.z path component belonging to an agent
# install, or empty. A component counts when its parent directory name contains
# claude/codex/gemini (case-insensitive), or the parent is "versions" and the
# grandparent does. This keeps Node's own version out of npm-installed agents.
ar_version_from_path() {
  local IFS=/ c v="" i=0 parent="" grand="" lp lg
  local re='[0-9]+\.[0-9]+\.[0-9]+'
  # shellcheck disable=SC2086
  for c in $1; do
    if [[ -n "$c" && "$c" =~ $re ]]; then
      lp=$(printf '%s' "$parent" | tr 'A-Z' 'a-z')
      lg=$(printf '%s' "$grand" | tr 'A-Z' 'a-z')
      if [[ "$lp" == *claude* || "$lp" == *codex* || "$lp" == *gemini* ||
            ( "$lp" == versions && ( "$lg" == *claude* || "$lg" == *codex* || "$lg" == *gemini* ) ) ]]; then
        v="${BASH_REMATCH[0]}"
      fi
    fi
    grand="$parent"; parent="$c"
    i=$((i + 1))
  done
  echo "$v"
}

# _ar_is_interpreted <pid> -> 0 when argv0 is an interpreter running a script.
_ar_is_interpreted() {
  local args b0
  [[ -n "${AR_PS_FILE:-}" && -s "$AR_PS_FILE" ]] || ar_ps_snapshot
  args=$(awk -v p="$1" '$1 == p { sub(/^[ \t]*[0-9]+[ \t]+[0-9]+[ \t]*/, ""); print; exit }' "$AR_PS_FILE")
  # shellcheck disable=SC2086
  set -- $args
  b0="${1:-}"; b0="${b0##*/}"; b0="${b0#-}"
  case "$b0" in
    node|bash|sh|python*) [[ -n "${2:-}" ]] ;;
    *) return 1 ;;
  esac
}

# _ar_find_pkg <script path> -> nearest enclosing package.json of a known agent.
_ar_find_pkg() {
  local d name
  d=$(dirname "$1")
  while [[ -n "$d" && "$d" != / && "$d" != . ]]; do
    if [[ -f "$d/package.json" ]]; then
      name=$(jq -r '.name // empty' "$d/package.json" 2>/dev/null || true)
      case "$name" in
        @anthropic-ai/claude-code|@openai/codex|@google/gemini-cli) echo "$d/package.json"; return 0 ;;
      esac
    fi
    d=$(dirname "$d")
  done
  return 0
}

# _ar_start_epoch <pid> -> the process start time in epoch seconds; 1 if unknown.
_ar_start_epoch() {
  local ls
  ls=$(LC_ALL=C ps -o lstart= -p "$1" 2>/dev/null </dev/null) || return 1
  ls=$(echo $ls)
  [[ -n "$ls" ]] || return 1
  LC_ALL=C date -j -f "%a %b %e %T %Y" "$ls" +%s 2>/dev/null
}

# _ar_mtime <file> -> modification time in epoch seconds; 1 if unknown.
_ar_mtime() {
  stat -f %m "$1" 2>/dev/null || stat -c %Y "$1" 2>/dev/null
}

# _ar_modified_since_start <pid> <file> -> 0 when file is newer than the process.
_ar_modified_since_start() {
  local mt st
  [[ -e "$2" ]] || return 1
  mt=$(_ar_mtime "$2") || return 1
  st=$(_ar_start_epoch "$1") || return 1
  [[ "$mt" -gt "$st" ]]
}

# _ar_semver <text> -> first x.y.z in text, or empty.
_ar_semver() {
  if [[ "$1" =~ [0-9]+\.[0-9]+\.[0-9]+ ]]; then echo "${BASH_REMATCH[0]}"; fi
}

# ar_running_version <pid> -> version of the running program, or empty (unknown).
# Unknown also when the program file changed after the process started (in-place
# upgrade: the file no longer describes what is running).
ar_running_version() {
  local pid="$1" path file v out pj interp=0
  path=$(ar_running_path "$pid")
  [[ -n "$path" ]] || return 0
  _ar_is_interpreted "$pid" && interp=1
  file="$path"
  v=$(ar_version_from_path "$path")
  if [[ -z "$v" ]]; then
    if [[ $interp == 1 ]]; then
      pj=$(_ar_find_pkg "$path")
      if [[ -n "$pj" ]]; then
        v=$(_ar_semver "$(jq -r '.version // empty' "$pj" 2>/dev/null || true)")
        file="$pj"
      fi
    elif [[ -f "$path" && -x "$path" ]]; then
      out=$("$path" --version 2>/dev/null </dev/null | head -1 || true)
      v=$(_ar_semver "$out")
    fi
  fi
  [[ -n "$v" ]] || return 0
  if _ar_modified_since_start "$pid" "$file"; then return 0; fi
  echo "$v"
}

# ar_installed_version <type> -> semver of `<type> --version` on PATH; cached per
# type (the cache only persists when called outside $(...)).
ar_installed_version() {
  local type="$1" var out v
  var="_AR_IV_$(printf '%s' "$1" | tr -c 'A-Za-z0-9\n' '_')"
  if eval "[[ -n \${$var+x} ]]"; then
    echo "${!var}"
    return
  fi
  v=""
  if command -v "$type" >/dev/null 2>&1; then
    out=$("$type" --version 2>/dev/null </dev/null | head -1 || true)
    v=$(_ar_semver "$out")
  fi
  printf -v "$var" '%s' "$v"
  echo "$v"
}

# ar_outdated <running_ver> <installed_ver> -> 0 when unknown or different.
ar_outdated() {
  [[ "$1" == "-" || "$1" != "$2" ]]
}

# ar_discover <workdir> -> one TSV record per agent pane:
# sock pane addr folder type pid running_ver installed_ver agent_cwd shell_cwd argv_file parent_pid argv_exact
# Pane IDs are per server: argv files are named <socket index>.<pane>.argv, and
# when more than one server has panes, addr is prefixed with the socket name
# ("default" for the default server), e.g. swarm:37:2.0.
ar_discover() {
  local workdir="$1" sock pane addr ppid shell_cwd hit pid type
  local rv iv acwd folder argv_file rc exact parent scwd panes nsock si s socks=()
  mkdir -p "$workdir"
  ar_ps_snapshot
  panes=$(ar_panes)
  nsock=$(printf '%s\n' "$panes" | awk -F'\t' 'NF { print $1 }' | sort -u | wc -l | tr -d ' ')
  while IFS=$'\t' read -r sock pane addr ppid shell_cwd; do
    [[ -n "$sock" ]] || continue
    si=0
    for s in ${socks[@]+"${socks[@]}"}; do [[ "$s" == "$sock" ]] && break; si=$((si + 1)); done
    [[ $si -lt ${#socks[@]} ]] || socks+=("$sock")
    if [[ "$nsock" -gt 1 ]]; then
      s="$sock"; [[ "$s" != - ]] || s=default
      addr="$s:$addr"
    fi
    hit=$(ar_agent_in_pane "$ppid")
    [[ -n "$hit" ]] || continue
    pid="${hit%%$'\t'*}"; type="${hit#*$'\t'}"

    rv=$(ar_running_version "$pid"); rv="${rv:--}"
    ar_installed_version "$type" >/dev/null
    iv=$(ar_installed_version "$type"); iv="${iv:--}"
    acwd=$(_ar_lsof_field "$pid" cwd); acwd="${acwd:--}"
    if [[ "$acwd" == "-" ]]; then folder="-"; else folder=$(basename "$acwd"); fi
    scwd=$(_ar_lsof_field "$ppid" cwd)
    if [[ -n "$scwd" ]]; then shell_cwd="$scwd"; fi

    argv_file="$workdir/$si.$pane.argv"
    rc=0; ar_argv "$pid" "$argv_file" || rc=$?
    case "$rc" in
      0) exact=1 ;;
      2) exact=0 ;;
      *) continue ;;
    esac
    parent=$(awk -v p="$pid" '$1 == p { print $2; exit }' "$AR_PS_FILE")
    parent="${parent:--}"

    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
      "$sock" "$pane" "$addr" "$folder" "$type" "$pid" "$rv" "$iv" \
      "$acwd" "$shell_cwd" "$argv_file" "$parent" "$exact"
  done <<<"$panes"
}
