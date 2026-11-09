# The iTerm2 app for iterm-upgrade: versions, quit, Homebrew upgrade, launch,
# and opening windows. Sourced after common.sh; bash 3.2 compatible.

iu_running() { pgrep -x iTerm2 >/dev/null 2>&1; }
iu_not_running() { ! iu_running; }

# iu_app_version -> the installed app's version, or nothing.
iu_app_version() {
  plutil -extract CFBundleShortVersionString raw -o - "$(iu_app)/Contents/Info.plist" 2>/dev/null || true
}

# iu_version_lt <a> <b> -> 0 when version a is older than b.
iu_version_lt() {
  [[ "$1" != "$2" && "$(printf '%s\n%s\n' "$1" "$2" | sort -V | head -n 1)" == "$1" ]]
}

iu_brew_managed() {
  command -v brew >/dev/null 2>&1 && brew list --cask iterm2 >/dev/null 2>&1 </dev/null
}

# iu_brew_version -> the iterm2 cask's current version ("3.7.7,build" -> "3.7.7").
iu_brew_version() {
  brew info --cask --json=v2 iterm2 2>/dev/null </dev/null |
    jq -r '.casks[0].version // empty' 2>/dev/null | sed 's/,.*//' || true
}

# iu_quit -> asks iTerm2 to quit and waits; if it is still up after
# ITERM_UPGRADE_QUIT_TIMEOUT seconds (a quit dialog nobody answered), sends
# SIGTERM. 1 when it won't go.
iu_quit() {
  local t="${ITERM_UPGRADE_QUIT_TIMEOUT:-30}" osa
  iu_running || return 0
  # In the background: a quit dialog blocks the Apple event until answered.
  osascript -e "tell application id \"$IU_BUNDLE\" to quit" >/dev/null 2>&1 </dev/null &
  osa=$!
  if ! iu_wait "$t" iu_not_running; then
    iu_log "iTerm2 still running after ${t}s; sending SIGTERM"
    pkill -TERM -x iTerm2 2>/dev/null || true
    iu_wait 15 iu_not_running || { kill "$osa" 2>/dev/null; return 1; }
  fi
  kill "$osa" 2>/dev/null || true
  wait "$osa" 2>/dev/null || true
  return 0
}

# _iu_brew <args...> -> runs brew, output indented on screen and in the log.
# SUDO_ASKPASS=/usr/bin/false: a password prompt fails at once instead of
# hanging in a pane nobody can see while iTerm is down.
_iu_brew() {
  iu_log "== brew $*"
  SUDO_ASKPASS=/usr/bin/false HOMEBREW_NO_AUTO_UPDATE=1 brew "$@" </dev/null 2>&1 |
    tee -a "$IU_LOG" | sed 's/^/    /'
}

# iu_upgrade <version> -> upgrades the app with Homebrew; 0 when it ends up at
# <version>. brew can record a cask as upgraded while the app on disk stays
# old (it was in use, or macOS blocked the move), so a mismatch gets a
# reinstall.
iu_upgrade() {
  local want="$1"
  _iu_brew upgrade --cask --greedy iterm2 || true
  [[ "$(iu_app_version)" == "$want" ]] && return 0
  _iu_brew reinstall --cask iterm2 || true
  [[ "$(iu_app_version)" == "$want" ]]
}

# iu_launch -> starts iTerm2 if needed and waits for its API (or, without
# the API, for the process). 1 when it doesn't come up.
iu_launch() {
  iu_running || open -b "$IU_BUNDLE" >/dev/null 2>&1 </dev/null || open -a "$(iu_app)" >/dev/null 2>&1 </dev/null || true
  iu_wait 30 iu_running || return 1
  local end=$((SECONDS + 20))
  until ITERM_UPGRADE_API_TIMEOUT=3 iu_iterm ping >/dev/null; do
    if [[ $SECONDS -ge $end ]]; then
      iu_log "iTerm API not answering; continuing without it"
      sleep 2
      return 0
    fi
    sleep 0.5
  done
  return 0
}

# iu_attach_cmd <sock> <session> <mode> -> the command that reattaches it.
iu_attach_cmd() {
  local sock="$1" sess="$2" mode="$3" cmd
  cmd=$(command -v tmux)
  [[ "$sock" == "-" ]] || cmd="$cmd -L $(printf '%q' "$sock")"
  [[ "$mode" != cc ]] || cmd="$cmd -CC"
  echo "$cmd attach-session -t $(printf '%q' "=$sess")"
}

# iu_open_window <sock> <session> <mode> -> a new iTerm window running the
# attach command in place of a shell: through the Python API, else (unless
# the API's window attached after all) AppleScript.
iu_open_window() {
  local cmd esc
  cmd=$(iu_attach_cmd "$1" "$2" "$3")
  iu_iterm attach-window --command "$cmd" >/dev/null && return 0
  ! iu_wait 3 iu_attached "$1" "$2" || return 0
  esc=${cmd//\\/\\\\}; esc=${esc//\"/\\\"}
  osascript -e "tell application id \"$IU_BUNDLE\" to create window with default profile command \"$esc\"" \
    >/dev/null 2>&1 </dev/null
}

# iu_notify <message> -> a macOS notification (best effort): whoever started
# the upgrade may not see the pane it ran in until they reattach.
iu_notify() {
  [[ "${ITERM_UPGRADE_NOTIFY:-1}" == 1 ]] || return 0
  local m=${1//\\/\\\\}; m=${m//\"/\\\"}
  osascript -e "display notification \"$m\" with title \"iterm-upgrade\"" >/dev/null 2>&1 </dev/null || true
}
