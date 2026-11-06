# The agents-restart command: plan, confirm, wait for each outdated agent to be
# idle and restart it, report. Sourced last; bash 3.2 compatible.
#
# Per outdated agent (index j) the A_* arrays hold its record fields, its UI
# row (A_ROW), whether it is still pending (A_PEND=1), its state at plan time
# (A_PLAN), consecutive unrecognized polls (A_UNREC) and its waiting text.

# _ar_self <sock> <pane> -> 0 when that pane is the caller's own ($TMUX_PANE on
# the server whose socket is the first field of $TMUX).
_ar_self() {
  local sp
  [[ -n "${TMUX_PANE:-}" && -n "${TMUX:-}" && "$2" == "$TMUX_PANE" ]] || return 1
  sp=$(ar_tmux "$1" list-sessions -F '#{socket_path}' 2>/dev/null </dev/null | head -1) || return 1
  [[ -n "$sp" && "$sp" == "${TMUX%%,*}" ]]
}

# _ar_wait_text <state> -> the in-progress text for a state that keeps waiting.
_ar_wait_text() {
  case "$1" in
    idle) echo "waiting" ;;
    busy) echo "waiting for turn to end" ;;
    busy:*) echo "waiting: ${1#busy:}" ;;
    unrecognized) echo "waiting: screen not recognized" ;;
    *) echo "waiting: $1" ;;
  esac
}

# _ar_finish <j> <ok|skip|fail> <text> [<since_ms>] [<dim tail>]: end agent j.
# Failures are also written to the diagnostics log.
_ar_finish() {
  A_PEND[$1]=0
  case "$2" in
    ok) AR_N_OK=$((AR_N_OK + 1)) ;;
    skip) AR_N_SKIP=$((AR_N_SKIP + 1)) ;;
    fail)
      AR_N_FAIL=$((AR_N_FAIL + 1))
      echo "agents-restart: ${A_ADDR[$1]} (${A_TYPE[$1]} pid ${A_PID[$1]}): $3" >> "$AR_WD/err" ;;
  esac
  ar_ui_set "${A_ROW[$1]}" "$2" "$3" "${4:-}" "${5:-}"
}

# _ar_manual <j> <cmd>: list a resume command to run by hand under the summary.
_ar_manual() {
  _ar_pad_v "${A_ADDR[$1]}" "$AR_UI_W_ADDR"
  AR_MANUAL="$AR_MANUAL$_AR_V  $2"$'\n'
}

# _ar_refresh: fresh process table and Claude listing for the next state checks.
_ar_refresh() {
  ar_ps_snapshot
  [[ $AR_HAS_CLAUDE == 0 ]] || ar_claude_refresh
}

# _ar_pause <secs>: sleep, redrawing the live region; returns early on Ctrl+C.
_ar_pause() {
  local n
  n=$(awk -v s="$1" 'BEGIN { n = int(s * 10 + 0.5); print (n < 1 ? 1 : n) }')
  while [[ $n -gt 0 && $AR_INT == 0 ]]; do
    ar_ui_render
    sleep 0.1
    n=$((n - 1))
  done
}

# _ar_restart <j>: restart agent j now: ar_restart_one runs in the background
# with INT, HUP and TERM ignored (it is bounded by the exit and start
# timeouts), so the live region keeps moving and neither Ctrl+C nor a closed
# terminal can leave the agent quit but not resumed. This function returns
# only after the job has ended. A "state changed" result leaves the agent pending.
_ar_restart() {
  local j="$1" t0 sid res tag reason cmd rc
  ar_ui_clock; t0=$AR_NOW
  ar_ui_set "${A_ROW[j]}" spin "restarting" "$t0"
  sid=$(ar_session_id "${A_TYPE[j]}" "${A_PID[j]}" "${A_ACWD[j]}" 2>>"$AR_WD/err") || sid=-
  [[ $AR_INT == 0 ]] || return 0
  res="$AR_WD/result.$j"
  rm -f "$res" "$res.tmp"
  ( set +e; trap '' INT HUP TERM
    ar_restart_one "${A_REC[j]}" "${sid:--}" > "$res.tmp"; mv "$res.tmp" "$res" ) 2>>"$AR_WD/err" &
  AR_JOB=$!
  while kill -0 "$AR_JOB" 2>/dev/null; do
    ar_ui_render
    sleep 0.1
  done
  # wait returns early (>128) when a trapped signal arrives; wait again then.
  while :; do
    wait "$AR_JOB" 2>/dev/null; rc=$?
    [[ $rc -gt 128 ]] && kill -0 "$AR_JOB" 2>/dev/null || break
  done
  AR_JOB=""
  IFS=$'\t' read -r tag reason cmd 2>/dev/null < "$res" || true
  case "${tag:-}" in
    ok)
      [[ "${reason:--}" != - ]] || reason="$sid"
      _ar_finish "$j" ok "resumed" "$t0" "${reason:0:8}" ;;
    fail)
      if [[ "$reason" == "state changed" ]]; then
        ar_ui_set "${A_ROW[j]}" spin "${A_WAIT[j]}" "$AR_T0"
        return 0
      fi
      _ar_finish "$j" fail "failed: $reason" "$t0"
      [[ "${cmd:--}" == - ]] || _ar_manual "$j" "$cmd" ;;
    *)
      # the job died without a result (killed outright): the agent may have
      # quit, so build its resume command here
      _ar_finish "$j" fail "failed: restart aborted" "$t0"
      cmd=""
      if [[ "${sid:--}" != - ]]; then
        cmd=$(ar_resume_cmd "${A_TYPE[j]}" "${A_ARGF[j]}" "$sid" "${A_ACWD[j]}" \
          "$(echo "${A_REC[j]}" | cut -f10)" "$(echo "${A_REC[j]}" | cut -f12)" 2>/dev/null) || cmd=""
      fi
      [[ -z "$cmd" ]] || _ar_manual "$j" "$cmd   (if it isn't running)" ;;
  esac
}

# _ar_check <j> <first poll>: look at agent j once; restart it if idle.
_ar_check() {
  local j="$1" st
  if ! kill -0 "${A_PID[j]}" 2>/dev/null; then _ar_finish "$j" skip "skipped: agent exited"; return; fi
  if [[ $2 == 1 && "${A_PLAN[j]}" == idle ]]; then
    st=idle   # ar_restart_one re-checks before sending anything
  else
    st=$(ar_state "${A_TYPE[j]}" "${A_SOCK[j]}" "${A_PANE[j]}" "${A_PID[j]}" "${A_ARGF[j]}" 2>>"$AR_WD/err") || st=""
  fi
  [[ $AR_INT == 0 ]] || return 0
  [[ "$st" == unrecognized ]] || A_UNREC[j]=0
  case "$st" in
    idle) _ar_restart "$j"; AR_STALE=1; return ;;
    prompt) _ar_finish "$j" skip "skipped: permission prompt"; return ;;
    unsent) _ar_finish "$j" skip "skipped: unsent input"; return ;;
    teammate) _ar_finish "$j" skip "skipped: teammate"; return ;;
    unlisted) _ar_finish "$j" fail "failed: not listed by claude agents"; return ;;
    unrecognized)
      A_UNREC[j]=$((A_UNREC[j] + 1))
      if [[ ${A_UNREC[j]} -ge 2 ]]; then _ar_finish "$j" skip "skipped: screen not recognized"; return; fi ;;
    "") st="busy:state unavailable" ;;
  esac
  A_WAIT[j]=$(_ar_wait_text "$st")
  ar_ui_set "${A_ROW[j]}" spin "${A_WAIT[j]}"
}

# _ar_plan: read the discovery into A_*, set plan states, print the plan.
# Sets AR_N (agents to restart) and AR_UPTODATE.
_ar_plan() {
  local sock pane addr folder type pid rv iv acwd scwd argf parent exact rec j st sid
  local w
  AR_N=0; AR_UPTODATE=0; AR_HAS_CLAUDE=0
  j=0
  while IFS= read -r rec; do
    IFS=$'\t' read -r sock pane addr folder type pid rv iv acwd scwd argf parent exact <<<"$rec"
    if ! ar_outdated "$rv" "$iv"; then AR_UPTODATE=$((AR_UPTODATE + 1)); continue; fi
    A_REC[j]="$rec"; A_SOCK[j]="$sock"; A_PANE[j]="$pane"; A_ADDR[j]="$addr"; A_FOLDER[j]="$folder"
    A_TYPE[j]="$type"; A_PID[j]="$pid"; A_RV[j]="$rv"; A_IV[j]="$iv"; A_ACWD[j]="$acwd"; A_ARGF[j]="$argf"
    A_EXACT[j]="$exact"
    A_UNREC[j]=0; A_PEND[j]=0
    [[ "$type" != claude ]] || AR_HAS_CLAUDE=1
    j=$((j + 1))
  done < "$AR_WD/agents.tsv"
  AR_COUNT=$j
  [[ $AR_COUNT -gt 0 ]] || return 0

  _ar_refresh
  AR_UI_W_ADDR=6; AR_UI_W_FOLDER=8; AR_UI_W_VER=16; AR_UI_W_STATE=6
  for ((j = 0; j < AR_COUNT; j++)); do
    if _ar_self "${A_SOCK[j]}" "${A_PANE[j]}"; then
      st=self
    elif [[ "${A_IV[j]}" == - ]]; then
      st="not installed"
    else
      st=$(ar_state "${A_TYPE[j]}" "${A_SOCK[j]}" "${A_PANE[j]}" "${A_PID[j]}" "${A_ARGF[j]}" 2>>"$AR_WD/err") || st=""
      st="${st:-busy:state unavailable}"
    fi
    A_PLAN[j]="$st"
    sid=$(ar_session_id "${A_TYPE[j]}" "${A_PID[j]}" "${A_ACWD[j]}" 2>>"$AR_WD/err") || sid=-
    A_SID[j]="${sid:--}"
    [[ ${#A_ADDR[j]} -le $AR_UI_W_ADDR ]] || AR_UI_W_ADDR=${#A_ADDR[j]}
    w=${#A_FOLDER[j]}; [[ $w -le 20 ]] || w=20
    [[ $w -le $AR_UI_W_FOLDER ]] || AR_UI_W_FOLDER=$w
    w=$(ar_ui_ver "${A_RV[j]}" "${A_IV[j]}"); w=${#w}
    [[ $w -le $AR_UI_W_VER ]] || AR_UI_W_VER=$w
    case "$st" in idle|busy*|unrecognized) AR_N=$((AR_N + 1)) ;; esac
    w="${st%%:*}"; w=${#w}
    [[ "$st" == self || $w -le $AR_UI_W_STATE ]] || AR_UI_W_STATE=$w
  done

  for ((j = 0; j < AR_COUNT; j++)); do
    st="${A_PLAN[j]}"
    case "$st" in busy:*) st=busy ;; esac
    ar_ui_plan_line "${A_ADDR[j]}" "${A_FOLDER[j]}" "${A_TYPE[j]}" "${A_RV[j]}" "${A_IV[j]}" "$st" "${A_SID[j]}"
  done
  [[ $AR_UPTODATE -eq 0 ]] || ar_ui_uptodate "$AR_UPTODATE"
}

# _ar_confirm: ask "Restart N agents? [Y/n]" on the terminal; exits 0 on no.
_ar_confirm() {
  local ans s=s
  [[ $AR_N != 1 ]] || s=""
  if ! (: </dev/tty) 2>/dev/null; then ar_die "not a terminal; pass -y"; fi
  printf 'Restart %d agent%s? [Y/n] ' "$AR_N" "$s" > /dev/tty
  read -r ans < /dev/tty || ans=n
  case "$ans" in
    ""|y|Y|yes|Yes|YES) ;;
    *) echo "nothing restarted"; exit 0 ;;
  esac
}

# _ar_start_rows: one UI row per outdated agent; agents that can't be restarted
# finish at once, the others start pending.
_ar_start_rows() {
  local j cmd
  for ((j = 0; j < AR_COUNT; j++)); do
    ar_ui_add "${A_ADDR[j]}" "${A_FOLDER[j]}" "${A_TYPE[j]}"
    A_ROW[j]=$AR_UI_LAST
    case "${A_PLAN[j]}" in
      self)
        _ar_finish "$j" skip "this pane, skipped"
        cmd=""
        if [[ "${A_SID[j]}" != - ]]; then
          cmd=$(ar_resume_cmd "${A_TYPE[j]}" "${A_ARGF[j]}" "${A_SID[j]}" "${A_ACWD[j]}" \
            "$(echo "${A_REC[j]}" | cut -f10)" "$(echo "${A_REC[j]}" | cut -f12)" 2>/dev/null) || cmd=""
        fi
        [[ -z "$cmd" ]] || _ar_manual "$j" "$cmd   (this pane: quit it first)" ;;
      "not installed") _ar_finish "$j" skip "skipped: ${A_TYPE[j]} not installed" ;;
      prompt) _ar_finish "$j" skip "skipped: permission prompt" ;;
      unsent) _ar_finish "$j" skip "skipped: unsent input" ;;
      teammate) _ar_finish "$j" skip "skipped: teammate" ;;
      unlisted) _ar_finish "$j" fail "failed: not listed by claude agents" ;;
      *)
        if [[ "${A_EXACT[j]}" != 1 ]]; then
          _ar_finish "$j" fail "failed: can't read exact arguments"; continue
        fi
        A_PEND[j]=1
        A_WAIT[j]=$(_ar_wait_text "${A_PLAN[j]}")
        ar_ui_set "${A_ROW[j]}" spin "${A_WAIT[j]}" "$AR_T0" ;;
    esac
  done
}

# _ar_pending -> number of agents still pending.
_ar_pending() {
  local j n=0
  for ((j = 0; j < AR_COUNT; j++)); do [[ ${A_PEND[j]} == 0 ]] || n=$((n + 1)); done
  echo "$n"
}

# _ar_cleanup (EXIT trap): remove the work dir, unless a restart job still runs
# in it (only possible when the shell is killed outright).
_ar_cleanup() {
  trap '' INT
  [[ -z "${AR_PS_FILE:-}" ]] || rm -f "$AR_PS_FILE"
  if [[ -n "${AR_JOB:-}" ]] && kill -0 "$AR_JOB" 2>/dev/null; then return 0; fi
  rm -rf "$AR_WD"
}

# _ar_keep_diag: after a failure, keep the diagnostics log and say where it is.
_ar_keep_diag() {
  local f
  [[ $AR_N_FAIL -gt 0 && -s "$AR_WD/err" ]] || return 0
  f="${TMPDIR:-/tmp}"; f="${f%/}/agents-restart-$(date +%Y%m%d-%H%M%S)-$$.log"
  cp "$AR_WD/err" "$f" 2>/dev/null || return 0
  printf '\n%sdiagnostics: %s%s\n' "$AR_C_DIM" "$f" "$AR_C_OFF"
}

ar_main() {
  local j first=1 poll
  ar_ui_init
  AR_WD=$(mktemp -d "${TMPDIR:-/tmp}/agents-restart.XXXXXX")
  AR_JOB=""
  trap _ar_cleanup EXIT
  A_REC=(); A_ROW=(); A_PEND=(); A_EXACT=(); AR_N_OK=0; AR_N_SKIP=0; AR_N_FAIL=0; AR_MANUAL=""; AR_INT=0

  ar_discover "$AR_WD/argv" > "$AR_WD/agents.tsv"
  ar_ui_header
  echo
  _ar_plan
  if [[ $AR_COUNT -eq 0 ]]; then echo "all agents up to date"; return 0; fi
  [[ "${AR_DRY_RUN:-0}" == 0 ]] || return 0
  [[ $AR_N -eq 0 || "${AR_YES:-0}" == 1 ]] || _ar_confirm
  echo

  # From here Ctrl+C only sets a flag: the loop stops between agents. errexit
  # is off: a Ctrl+C kills any $(...) running at that moment, and that must not
  # end the shell while a restart job is in flight.
  set +e
  trap 'AR_INT=1' INT
  ar_ui_clock; AR_T0=$AR_NOW
  _ar_start_rows
  ar_ui_render
  poll=$(_ar_env_num "${AGENTS_RESTART_POLL:-}" 3 dec)
  while [[ $AR_INT == 0 && $(_ar_pending) -gt 0 ]]; do
    _ar_refresh
    AR_STALE=0
    for ((j = 0; j < AR_COUNT && AR_INT == 0; j++)); do
      [[ ${A_PEND[j]} == 1 ]] || continue
      [[ $AR_STALE == 0 ]] || { _ar_refresh; AR_STALE=0; }
      _ar_check "$j" "$first"
      ar_ui_render
    done
    first=0
    [[ $(_ar_pending) -eq 0 ]] || _ar_pause "$poll"
  done
  for ((j = 0; j < AR_COUNT; j++)); do
    [[ ${A_PEND[j]} == 0 ]] || _ar_finish "$j" skip "not restarted (interrupted)"
  done
  trap '' INT   # nothing is left to interrupt; let the report print whole
  ar_ui_render

  echo
  ar_ui_clock
  ar_ui_summary "$AR_N_OK" "$AR_N_SKIP" "$AR_N_FAIL" $((AR_NOW - AR_T0))
  if [[ -n "$AR_MANUAL" ]]; then
    printf '\nresume by hand:\n'
    printf '%s' "$AR_MANUAL" | sed 's/^/  /'
  fi
  _ar_keep_diag
  if [[ $AR_INT == 1 ]]; then exit 130; fi
  [[ $AR_N_FAIL -eq 0 ]] || exit 1
}
