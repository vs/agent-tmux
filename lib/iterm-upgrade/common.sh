# Shared helpers for iterm-upgrade. Sourced by bin/iterm-upgrade after
# lib/agents-restart/{common,discover}.sh (for ar_sockets, ar_tmux and the
# agent matcher) and lib/swarm/iterm.sh (for swarm_iterm). bash 3.2 compatible.

IU_TAB=$'\t'
IU_BUNDLE=com.googlecode.iterm2

iu_die() { echo "iterm-upgrade: error: $*" >&2; exit 1; }
iu_warn() { echo "iterm-upgrade: warning: $*" >&2; }

iu_dir() { echo "${ITERM_UPGRADE_DIR:-$HOME/.agent-tmux/iterm-upgrade}"; }
iu_app() { echo "${ITERM_UPGRADE_APP:-/Applications/iTerm.app}"; }
iu_hotkey_state() { echo "${ITERM_TMUX_STATE:-$HOME/.agent-tmux/hotkey-session}"; }

# iu_log <text...> -> appends a line to the run's log.
iu_log() { echo "$*" >> "$IU_LOG"; }

# iu_wait <secs> <cmd...> -> polls until cmd succeeds; 1 on timeout.
iu_wait() {
  local n=$(( $1 * 4 )); shift
  while ! "$@" 2>/dev/null; do
    n=$((n - 1)); [[ $n -gt 0 ]] || return 1
    sleep 0.25
  done
}

# iu_iterm <args...> -> swarm_iterm with a time limit of
# ITERM_UPGRADE_API_TIMEOUT seconds (default 10): an iTerm held up by a modal
# dialog never answers its API. 124 on timeout.
iu_iterm() {
  local out="$IU_TMP/iterm.$RANDOM" pid rc=0 n
  n=$(( ${ITERM_UPGRADE_API_TIMEOUT:-10} * 4 ))
  swarm_iterm "$@" > "$out" 2>/dev/null </dev/null &
  pid=$!
  while kill -0 "$pid" 2>/dev/null; do
    n=$((n - 1))
    if [[ $n -le 0 ]]; then
      pkill -P "$pid" 2>/dev/null || true
      kill "$pid" 2>/dev/null || true
      wait "$pid" 2>/dev/null || true
      rm -f "$out"
      iu_log "iTerm API timed out: $1"
      return 124
    fi
    sleep 0.25
  done
  wait "$pid" || rc=$?
  cat "$out"
  rm -f "$out"
  return $rc
}

# --- process table ---

# iu_ps_snapshot -> fills $IU_PS_FILE with "pid ppid args" lines.
# ITERM_UPGRADE_PS names a canned table instead (tests).
iu_ps_snapshot() {
  if [[ -n "${ITERM_UPGRADE_PS:-}" ]]; then
    IU_PS_FILE="$ITERM_UPGRADE_PS"
    return
  fi
  IU_PS_FILE="$IU_TMP/ps"
  ps -A -o pid=,ppid=,args= > "$IU_PS_FILE" 2>/dev/null </dev/null || true
}

# awk helpers on top of agents-restart's agent(): iterm(args) is iTerm itself
# or its session server; tmux(args) is a tmux client or server.
_IU_AWK="$_AR_AWK_AGENT"'
    function iterm(a) { return a ~ /iTerm\.app\/Contents\/MacOS\/iTerm2|\/iTermServer-/ }
    function tmux(a,   n, x, b) {
      n = split(a, x, /[ \t]+/); b = base(x[1]); sub(/^-/, "", b)
      return b == "tmux"
    }
    # where(pid) -> "tmux" or "iterm" for the nearest such ancestor, else "".
    function where(p,   guard) {
      p = parent[p]
      while (p != "" && p > 1 && guard++ < 200) {
        if (tmux(args[p])) return "tmux"
        if (iterm(args[p])) return "iterm"
        p = parent[p]
      }
      return ""
    }
    function nested(p,   guard) {
      p = parent[p]
      while (p != "" && p > 1 && guard++ < 200) {
        if (agent(args[p]) != "") return 1
        p = parent[p]
      }
      return 0
    }'

# iu_where <pid> -> "tmux", "iterm" or "" for the process's nearest ancestor.
iu_where() {
  # read_ps() owns the globals pid and ppid, hence "self".
  awk -v self="$1" "$_IU_AWK"'
    { read_ps() }
    END { print where(self) }' "$IU_PS_FILE"
}

# iu_stray_agents -> "pid<TAB>type" of each agent running in a plain iTerm
# session (not under tmux): quitting iTerm ends those for good.
iu_stray_agents() {
  awk "$_IU_AWK"'
    { read_ps() }
    END {
      for (p in args) {
        t = agent(args[p])
        if (t != "" && !nested(p) && where(p) == "iterm") print p "\t" t
      }
    }' "$IU_PS_FILE" | sort -n
}

# --- tmux clients ---

# iu_snapshot -> "sock<TAB>session<TAB>mode<TAB>client" per attached session:
# mode "cc" for an iTerm tmux integration (-CC) client, "plain" for a plain
# `tmux attach` running in an iTerm tab. A session shown twice is listed once,
# preferring cc. Clients in other terminals are left out.
iu_snapshot() {
  local sock cm sess client pid
  while IFS= read -r sock; do
    while IFS="$IU_TAB" read -r cm sess client pid; do
      [[ -n "$sess" ]] || continue
      if [[ "$cm" == 1 ]]; then
        printf '%s\t%s\tcc\t%s\n' "$sock" "$sess" "$client"
      elif [[ "$(iu_where "$pid")" == iterm ]]; then
        printf '%s\t%s\tplain\t%s\n' "$sock" "$sess" "$client"
      fi
    done < <(ar_tmux "$sock" list-clients \
      -F "#{client_control_mode}${IU_TAB}#{session_name}${IU_TAB}#{client_name}${IU_TAB}#{client_pid}" \
      2>/dev/null </dev/null || true)
  done < <(ar_sockets) |
    awk -F'\t' '{ k = $1 FS $2; if (!(k in row) || $3 == "cc") row[k] = $0; if (!(k in seen)) { seen[k] = 1; order[++n] = k } }
      END { for (i = 1; i <= n; i++) print row[order[i]] }'
}

# iu_clients <sock> <session> -> the session's client names, one per line.
iu_clients() {
  ar_tmux "$1" list-clients -t "=$2" -F '#{client_name}' 2>/dev/null </dev/null || true
}

iu_attached() { [[ -n "$(iu_clients "$1" "$2")" ]]; }
iu_has_session() { ar_tmux "$1" has-session -t "=$2" 2>/dev/null </dev/null; }

# iu_windows <sock> <session> -> its window count.
iu_windows() {
  ar_tmux "$1" list-windows -t "=$2" -F x 2>/dev/null </dev/null | wc -l | tr -d ' '
}

# iu_detached_sessions -> "sock<TAB>session" of every session with no client.
iu_detached_sessions() {
  local sock
  while IFS= read -r sock; do
    ar_tmux "$sock" list-sessions -F "#{session_attached}${IU_TAB}#{session_name}" 2>/dev/null </dev/null |
      awk -F'\t' -v s="$sock" '$1 == 0 { print s "\t" $2 }' || true
  done < <(ar_sockets)
}

# --- iTerm hotkey window ---

# iu_wrapper_installed -> 0 when a hotkey profile runs iterm-tmux.
iu_wrapper_installed() {
  iu_iterm hotkey-profiles |
    awk -F'\t' '$2 == "Yes" && $3 ~ /(^|\/)iterm-tmux$/ { found = 1 } END { exit !found }'
}

# iu_hotkey_session <snapshot file> -> the session (default server, -CC) that
# iTerm's hotkey window shows, or nothing. Falls back to the session
# iterm-tmux last opened when the iTerm API can't tell.
iu_hotkey_session() {
  local snap="$1" ids id name s
  ids=$(iu_iterm hotkey-windows || true)
  for id in $ids; do
    name=$(ar_tmux - display-message -p -t "$id" '#{session_name}' 2>/dev/null </dev/null) || continue
    if awk -F'\t' -v s="$name" '$1 == "-" && $2 == s && $3 == "cc" { f = 1 } END { exit !f }' "$snap"; then
      echo "$name"
      return
    fi
  done
  [[ -z "$ids" ]] || return 0
  s=$(cat "$(iu_hotkey_state)" 2>/dev/null || true)
  if [[ -n "$s" ]] && awk -F'\t' -v s="$s" '$1 == "-" && $2 == s && $3 == "cc" { f = 1 } END { exit !f }' "$snap"; then
    echo "$s"
  fi
}
