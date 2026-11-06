# Restart one agent pane for agents-restart: quit the agent, type its resume command.
# Sourced after common.sh, discover.sh, state.sh and resume.sh; bash 3.2 compatible.

_ar_fail() { printf 'fail\t%s\t%s\n' "$1" "${2:--}"; }

# _ar_shell_foreground <pane_pid> -> 0 when the pane's shell owns the terminal
# foreground (same idea as swarm_pane_idle in lib/swarm/common.sh).
_ar_shell_foreground() {
  local tpgid
  tpgid=$(ps -o tpgid= -p "$1" 2>/dev/null </dev/null | tr -d ' ') || return 1
  [[ -n "$tpgid" && "$tpgid" == "$1" ]]
}

# _ar_pid_gone <pid> -> 0 when the process no longer exists (a zombie counts).
_ar_pid_gone() {
  local st
  kill -0 "$1" 2>/dev/null || return 0
  st=$(ps -o stat= -p "$1" 2>/dev/null </dev/null | tr -d ' ') || return 0
  [[ -z "$st" || "$st" == Z* ]]
}

# _ar_send <sock> <pane> <text>: type text, pause, press Enter. Separate
# send-keys calls: Codex swallows an Enter sent in the same call.
# Returns 1 when the text was not typed, 2 when it was typed but Enter failed.
_ar_send() {
  ar_tmux "$1" send-keys -t "$2" -l "$3" </dev/null || return 1
  sleep 0.5
  ar_tmux "$1" send-keys -t "$2" Enter </dev/null || return 2
}

# _ar_pos_int <value> <default> -> value when an integer >= 1, else default.
_ar_pos_int() {
  local v
  v=$(_ar_env_num "$1" "$2" int)
  [[ "$v" -ge 1 ]] || v="$2"
  echo "$v"
}

# _ar_quit_and_type <sock> <pane> <type> <pid> <pane_pid> <resume_cmd> <exit_timeout>
# Steps 2-4 of ar_restart_one. Returns 0 once the resume command is typed; on
# any failure prints the fail line itself and returns 1 (nothing more is sent).
_ar_quit_and_type() {
  local sock="$1" pane="$2" type="$3" pid="$4" ppid="$5" cmd="$6" tmo="$7" quit deadline src
  quit=/quit; [[ "$type" == claude ]] && quit=/exit
  src=0
  _ar_send "$sock" "$pane" "$quit" || src=$?
  case "$src" in
    0) ;;
    1) _ar_fail "state changed"; return 1 ;;
    *) _ar_fail "quit key not sent; $quit left in input" "$cmd"; return 1 ;;
  esac
  deadline=$(( $(date +%s) + tmo ))
  until _ar_pid_gone "$pid" && _ar_shell_foreground "$ppid"; do
    if [[ $(date +%s) -ge $deadline ]]; then
      if _ar_pid_gone "$pid"; then
        _ar_fail "shell not at prompt" "$cmd"
      else
        _ar_fail "didn't exit within ${tmo}s" "$cmd"
      fi
      return 1
    fi
    sleep 0.2
  done
  # Re-check right before typing: something may have grabbed the terminal since.
  if ! _ar_shell_foreground "$ppid"; then _ar_fail "shell not at prompt" "$cmd"; return 1; fi
  src=0
  _ar_send "$sock" "$pane" "$cmd" || src=$?
  case "$src" in
    0) ;;
    1) _ar_fail "shell not at prompt" "$cmd"; return 1 ;;
    *) _ar_fail "resume command typed but not submitted" "$cmd"; return 1 ;;
  esac
}

# ar_restart_one <record> <sid> -> exactly one stdout line:
#   ok<TAB><new_sid or ->
#   fail<TAB><reason><TAB><resume_cmd or ->
# <record> is the ar_discover TSV; <sid> the session id from ar_session_id.
# Steps: precheck (sid known, argv read exactly, every flag known so the resume
# command is built, ar_state is
# exactly idle) -> /exit or /quit -> wait for the agent to be gone and the
# shell to own the foreground -> type the resume command -> wait for a new agent
# process (claude: listed in `claude agents --json`, its sessionId is reported).
# Nothing is ever killed; on any failure after the quit keys nothing more is
# typed. Diagnostics go to stderr.
#
# Ctrl+C: from the quit keys until the resume command is typed, SIGINT is
# ignored (trap '' INT), so an interrupt can never leave an agent quit without
# its resume command typed. The caller's INT trap is restored afterwards; an INT
# that arrives in that window is not replayed, so Task 7 must not rely on
# delivery during a restart (its trap only matters between and after panes).
# The caller's INT handler must be flag-only (set a variable, nothing else): the
# saved trap string is re-installed in this shell, and subshells such as $(...)
# inherit it.
ar_restart_one() {
  local record="$1" sid="${2:--}"
  local sock pane addr folder type pid rv iv acwd scwd argf parent exact
  IFS=$'\t' read -r sock pane addr folder type pid rv iv acwd scwd argf parent exact <<<"$record"
  local etmo stmo settle cmd ppid tpg st old_trap rc deadline hit npid row nsid now seen="" seen_at=0

  etmo=$(_ar_pos_int "${AGENTS_RESTART_EXIT_TIMEOUT:-}" 15)
  stmo=$(_ar_pos_int "${AGENTS_RESTART_START_TIMEOUT:-}" 20)
  settle=$(_ar_pos_int "${AGENTS_RESTART_SETTLE_SECS:-}" 3)

  # 1. precheck: everything is verified before any key is sent
  if [[ -z "$sid" || "$sid" == - ]]; then _ar_fail "no session id"; return 0; fi
  if [[ ! "$pid" =~ ^[0-9]+$ ]]; then echo "agents-restart: bad agent pid '$pid'" >&2; _ar_fail "state changed"; return 0; fi
  if [[ -z "$argf" || "$argf" == - || ! -r "$argf" ]]; then _ar_fail "can't read arguments"; return 0; fi
  # a whitespace-split argv (no python3, or its helper failed) may have split
  # or joined arguments: never build a resume command from it
  if [[ "$exact" != 1 ]]; then _ar_fail "can't read exact arguments"; return 0; fi
  rc=0; cmd=$(ar_resume_cmd "$type" "$argf" "$sid" "$acwd" "$scwd" "$parent" "$(ar_tool_path "$type")") || rc=$?
  if [[ $rc == 3 && -n "$cmd" ]]; then
    echo "agents-restart: $pane: $cmd; nothing sent" >&2
    _ar_fail "$cmd"; return 0
  fi
  if [[ $rc != 0 || -z "$cmd" ]]; then _ar_fail "can't read arguments"; return 0; fi
  ppid=$(ar_tmux "$sock" display-message -p -t "$pane" '#{pane_pid}' 2>/dev/null </dev/null) || ppid=""
  if [[ -z "$ppid" ]]; then echo "agents-restart: pane $pane not found" >&2; _ar_fail "state changed"; return 0; fi
  # The agent must be a job in the foreground of a job-control shell we can
  # return to: not the pane's own process (/exit would close the pane), and not
  # sharing the pane process's group (`sh -c 'agent; more'`, where the wait
  # below would pass at once and the command would be typed into whatever runs
  # next).
  tpg=$(ps -o tpgid= -p "$ppid" 2>/dev/null </dev/null | tr -d ' ') || tpg=""
  if [[ ! "$ppid" =~ ^[0-9]+$ || "$pid" == "$ppid" || -z "$tpg" || "$tpg" == "$ppid" ]]; then
    echo "agents-restart: $pane has no job-control shell to return to; nothing sent" >&2
    _ar_fail "pane has no shell to return to"; return 0
  fi
  if [[ "$type" == claude ]]; then
    ar_claude_refresh
    # the session may have changed (/resume, /clear) since the caller read sid
    row=$(_ar_claude_row "$pid")
    nsid=$(echo "$row" | cut -f4)
    if [[ -n "$nsid" && "$nsid" != - && "$nsid" != "$sid" ]]; then
      echo "agents-restart: $pane now runs session $nsid, not $sid; nothing sent" >&2
      _ar_fail "state changed"; return 0
    fi
  fi
  st=$(ar_state "$type" "$sock" "$pane" "$pid" "$argf") || st=""
  if [[ "$st" != idle ]]; then
    echo "agents-restart: $pane is '$st', not idle; nothing sent" >&2
    _ar_fail "state changed"; return 0
  fi

  # 2-4. quit, wait for the shell, type the resume command (INT ignored)
  old_trap=$(trap -p INT)
  trap '' INT
  rc=0
  _ar_quit_and_type "$sock" "$pane" "$type" "$pid" "$ppid" "$cmd" "$etmo" || rc=$?
  if [[ -n "$old_trap" ]]; then eval "$old_trap"; else trap - INT; fi
  [[ $rc -eq 0 ]] || return 0

  # 5. wait for the new agent process. Codex and Gemini have no listing to
  # confirm the session: their new process must still be running more than
  # <settle> seconds after it was first seen (a resume that fails at once,
  # e.g. an unknown session, exits within that time).
  deadline=$(( $(date +%s) + stmo ))
  while :; do
    ar_ps_snapshot
    hit=$(ar_agent_in_pane "$ppid")
    npid="${hit%%$'\t'*}"
    now=$(date +%s)
    if [[ -n "$npid" && "$npid" != "$pid" ]]; then
      if [[ "$type" != claude ]]; then
        if [[ "$npid" != "$seen" ]]; then
          seen="$npid"; seen_at=$now
          # a process first seen before the deadline gets its full settle time
          [[ $now -ge $deadline ]] || deadline=$(( deadline > now + settle + 1 ? deadline : now + settle + 1 ))
        elif [[ $((now - seen_at)) -gt $settle ]] && ! _ar_pid_gone "$npid"; then
          printf 'ok\t-\n'; return 0
        fi
      fi
    else
      seen=""
    fi
    if [[ -n "$npid" && "$npid" != "$pid" && "$type" == claude ]]; then
      ar_claude_refresh
      row=$(_ar_claude_row "$npid")
      if [[ -n "$row" ]]; then
        nsid=$(echo "$row" | cut -f4)
        printf 'ok\t%s\n' "${nsid:--}"; return 0
      fi
    fi
    [[ $now -lt $deadline ]] || break
    sleep 0.2
  done
  _ar_fail "didn't come back" "$cmd"
}
