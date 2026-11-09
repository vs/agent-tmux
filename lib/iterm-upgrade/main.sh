# iterm-upgrade flow: plan, confirm, detach, quit, upgrade, relaunch,
# reattach. Sourced after app.sh; bash 3.2 compatible.
#
# State file rows ($IU_STATE): sock<TAB>session<TAB>mode<TAB>role, where role
# is "hotkey" (iterm-tmux brings it back when the hotkey is pressed) or
# "window" (reopened in a new iTerm window).

# iu_reattach_rows <state file> -> reattaches every row and prints one line
# each. Sets IU_HOTKEY_WAITING to the hotkey session, if any. 1 if any failed.
iu_reattach_rows() {
  local sock sess mode role rc=0 label
  IU_HOTKEY_WAITING=""
  while IFS="$IU_TAB" read -r sock sess mode role; do
    [[ -n "$sess" ]] || continue
    label="$sess"
    [[ "$sock" == "-" ]] || label="$sess (tmux -L $sock)"
    if ! iu_has_session "$sock" "$sess"; then
      echo "  gone      $label: the session no longer exists"
    elif iu_attached "$sock" "$sess"; then
      echo "  ok        $label: attached"
    elif [[ "$role" == hotkey ]]; then
      echo "  hotkey    $label: press your iTerm hotkey to bring it back"
      IU_HOTKEY_WAITING="$sess"
    elif ! iu_open_window "$sock" "$sess" "$mode"; then
      echo "  FAILED    $label: could not open an iTerm window; run: $(iu_attach_cmd "$sock" "$sess" "$mode")"
      rc=1
    elif iu_wait 10 iu_attached "$sock" "$sess"; then
      echo "  ok        $label: reopened in a new window"
    else
      echo "  FAILED    $label: the window didn't attach; run: $(iu_attach_cmd "$sock" "$sess" "$mode")"
      rc=1
    fi
  done < "$1"
  return $rc
}

# iu_finish -> brings iTerm back and reattaches the saved sessions. Runs after
# the clients were detached, whatever happened in between.
iu_finish() {
  local rc=0 msg
  IU_PENDING=0
  trap - INT TERM
  echo "Starting iTerm2…"
  if ! iu_launch; then
    echo "iterm-upgrade: error: iTerm2 didn't start; open it, then run: iterm-upgrade --reattach" >&2
    iu_notify "iTerm2 didn't start. Open it, then run iterm-upgrade --reattach."
    return 1
  fi
  echo "Reattaching:"
  iu_reattach_rows "$IU_STATE" || rc=1
  if [[ $rc == 0 ]]; then msg="iTerm2 is back"; else msg="iTerm2 is back, but some sessions didn't reattach"; fi
  [[ -z "$IU_HOTKEY_WAITING" ]] || msg="$msg. Press your hotkey for session $IU_HOTKEY_WAITING."
  iu_notify "$msg"
  return $rc
}

# iu_confirm <question> -> 0 on yes. Needs a terminal unless -y.
iu_confirm() {
  [[ "$IU_YES" == 1 ]] && return 0
  [[ -t 0 ]] || iu_die "not a terminal; pass -y to go ahead without asking"
  local ans
  read -r -p "$1 [y/N] " ans || return 1
  [[ "$ans" == y || "$ans" == Y || "$ans" == yes ]]
}

# _iu_exit -> on any exit after the clients were detached that didn't bring
# iTerm back (an unexpected error), bring it back now.
_iu_exit() {
  local rc=$?
  if [[ "${IU_PENDING:-0}" == 1 ]]; then
    IU_PENDING=0
    echo "iterm-upgrade: error: stopped early; bringing iTerm2 back…" >&2
    set +e
    iu_finish
    rc=1
  fi
  rm -rf "$IU_TMP"
  exit $rc
}

iu_main() {
  IU_DIR=$(iu_dir)
  mkdir -p "$IU_DIR"
  IU_STATE="$IU_DIR/state"
  IU_LOG="$IU_DIR/last.log"
  IU_TMP=$(mktemp -d "${TMPDIR:-/tmp}/iterm-upgrade.XXXXXX")
  IU_PENDING=0
  trap _iu_exit EXIT
  command -v tmux >/dev/null 2>&1 || iu_die "tmux not found"

  if [[ "$IU_REATTACH" == 1 ]]; then
    [[ -s "$IU_STATE" ]] || iu_die "nothing saved to reattach ($IU_STATE)"
    : > "$IU_LOG"
    iu_finish
    return
  fi

  iu_ps_snapshot
  if [[ "$(iu_where $$)" == iterm ]]; then
    iu_die "run it from a tmux pane (it keeps running there while iTerm restarts) or from outside iTerm; a plain iTerm tab closes with iTerm"
  fi

  local cur target="" running=0
  cur=$(iu_app_version)
  [[ -n "$cur" ]] || iu_die "iTerm2 not found at $(iu_app) (set ITERM_UPGRADE_APP)"
  if [[ "$IU_UPGRADE" == 1 ]]; then
    iu_brew_managed || iu_die "iTerm2 isn't installed with Homebrew; update it from iTerm2 › Check for Updates, or pass --no-upgrade to only restart it"
    if [[ "$IU_DRY_RUN" == 0 ]]; then
      echo "Checking Homebrew for a new iTerm2…"
      brew update --quiet >/dev/null 2>&1 </dev/null || iu_warn "brew update failed; using the formulae it already has"
    fi
    target=$(iu_brew_version)
    [[ -n "$target" ]] || iu_die "can't read the iterm2 cask version from brew"
    if ! iu_version_lt "$cur" "$target"; then
      echo "iTerm2 $cur is up to date (Homebrew has $target). --no-upgrade restarts it anyway."
      return 0
    fi
  fi
  ! iu_running || running=1

  local snap="$IU_TMP/snap" rows="$IU_TMP/rows" hotkey="" wrapper=0 strays sock sess mode client role n
  : > "$snap"; : > "$rows"
  if [[ $running == 1 ]]; then
    iu_snapshot > "$snap"
    if [[ -s "$snap" ]]; then
      hotkey=$(iu_hotkey_session "$snap")
      if [[ -n "$hotkey" ]] && iu_wrapper_installed; then wrapper=1; fi
    fi
  fi
  while IFS="$IU_TAB" read -r sock sess mode client; do
    role=window
    [[ $wrapper == 1 && "$sock" == "-" && "$sess" == "$hotkey" ]] && role=hotkey
    printf '%s\t%s\t%s\t%s\n' "$sock" "$sess" "$mode" "$role" >> "$rows"
  done < "$snap"
  strays=$(iu_stray_agents)

  # --- plan ---
  if [[ -n "$target" ]]; then
    echo "iTerm2 $cur → $target (Homebrew)"
  else
    echo "iTerm2 $cur: restart only"
  fi
  if [[ $running == 0 ]]; then
    echo "iTerm2 isn't running: nothing to reattach."
  elif [[ ! -s "$rows" ]]; then
    echo "No tmux sessions are attached in iTerm: nothing to reattach."
  else
    echo "After the restart:"
    while IFS="$IU_TAB" read -r sock sess mode role; do
      n=$(iu_windows "$sock" "$sess")
      [[ "$sock" == "-" ]] || sess="$sess (tmux -L $sock)"
      if [[ "$role" == hotkey ]]; then
        printf '  %-14s %3s window(s)  back in the hotkey window when you press the hotkey\n' "$sess" "$n"
      else
        printf '  %-14s %3s window(s)  reopened in a new iTerm window\n' "$sess" "$n"
      fi
    done < "$rows"
  fi
  if [[ -n "$hotkey" && $wrapper == 0 ]]; then
    echo "  (your hotkey profile runs a bare \`tmux -CC\`, so session $hotkey gets a normal window;"
    echo "   run install.sh to have the hotkey bring it back instead)"
  fi
  local detached
  detached=$(iu_detached_sessions | awk -F'\t' '{ printf "%s%s", sep, ($1 == "-" ? $2 : $2 " (-L " $1 ")"); sep = ", " }')
  [[ -z "$detached" ]] || echo "Not attached now, left as they are: $detached"
  if [[ -n "$strays" ]]; then
    echo "Agents outside tmux; quitting iTerm ends them:"
    while IFS="$IU_TAB" read -r n mode; do
      echo "  $mode (pid $n)"
    done <<<"$strays"
  fi

  if [[ "$IU_DRY_RUN" == 1 ]]; then
    echo "Dry run: nothing changed."
    return 0
  fi
  if [[ -n "$strays" && "$IU_YES" == 1 ]]; then
    iu_die "agents are running outside tmux (listed above); close them or run without -y to confirm"
  fi
  iu_confirm "Quit iTerm2${target:+, upgrade it} and reattach?" || { echo "Cancelled."; return 1; }

  # --- point of no return: from here on, iTerm always comes back ---
  cp "$rows" "$IU_STATE"
  {
    echo "iterm-upgrade $(date '+%Y-%m-%d %H:%M:%S'): $cur -> ${target:-restart}"
    sed 's/^/state: /' "$IU_STATE"
  } > "$IU_LOG"
  if [[ -n "$hotkey" && $wrapper == 1 ]]; then
    mkdir -p "$(dirname "$(iu_hotkey_state)")"
    printf '%s\n' "$hotkey" > "$(iu_hotkey_state)"
  fi
  IU_PENDING=1
  trap 'echo; echo "Interrupted: bringing iTerm2 back…"; IU_PENDING=0; iu_finish; exit 130' INT TERM
  [[ $running == 0 ]] || echo "Detaching iTerm from tmux and quitting it (your agents keep running)…"
  while IFS="$IU_TAB" read -r sock sess mode client; do
    ar_tmux "$sock" detach-client -t "$client" 2>/dev/null </dev/null || true
  done < "$snap"

  local rc=0
  if ! iu_quit; then
    echo "iterm-upgrade: error: iTerm2 didn't quit; skipping the upgrade" >&2
    iu_finish || true
    return 1
  fi
  if [[ -n "$target" ]]; then
    echo "Upgrading iTerm2 to ${target}…"
    if iu_upgrade "$target"; then
      echo "iTerm2 upgraded: $cur → $target"
    else
      echo "iterm-upgrade: error: iTerm2 is still $(iu_app_version); see $IU_LOG" >&2
      rc=1
    fi
  fi
  iu_finish || rc=1
  return $rc
}
