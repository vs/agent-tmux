#!/usr/bin/env bash
# Tests for iterm-upgrade. A private tmux server (TMUX_TMPDIR)
# stands in for the real one; iTerm, brew, osascript, open and pgrep are
# fakes, and iTerm's -CC clients are `tmux -C` clients fed by sleep.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/swarm-lib.sh"
t_setup
unset SWARM_TMUX_SOCKET AGENTS_RESTART_SOCKETS
REAL_TMUX=$(command -v tmux)
export TMUX_TMPDIR="$WORK/tmux"
mkdir -p "$TMUX_TMPDIR"
trap 'tmux kill-server 2>/dev/null || true; rm -rf "$WORK"' EXIT

export ITERM_UPGRADE_APP="$WORK/iTerm.app"
export ITERM_UPGRADE_DIR="$WORK/iu"
export ITERM_UPGRADE_NOTIFY=0
export ITERM_UPGRADE_PS="$WORK/ps"
export ITERM_UPGRADE_QUIT_TIMEOUT=2
export FAKE_LOG="$WORK/fake.log"
: > "$ITERM_UPGRADE_PS"

set_app_version() {
  mkdir -p "$ITERM_UPGRADE_APP/Contents"
  cat > "$ITERM_UPGRADE_APP/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict><key>CFBundleShortVersionString</key><string>$1</string></dict></plist>
EOF
}
app_version() { plutil -extract CFBundleShortVersionString raw -o - "$ITERM_UPGRADE_APP/Contents/Info.plist"; }

fake() { cat > "$WORK/bin/$1"; chmod +x "$WORK/bin/$1"; }
fake pgrep <<'EOF'
#!/usr/bin/env bash
[[ -e "$FAKE_RUNNING" ]]
EOF
fake pkill <<'EOF'
#!/usr/bin/env bash
echo "pkill $*" >> "$FAKE_LOG"
[[ "${FAKE_NOQUIT:-0}" == 1 ]] || rm -f "$FAKE_RUNNING"
EOF
fake open <<'EOF'
#!/usr/bin/env bash
echo "open $*" >> "$FAKE_LOG"
touch "$FAKE_RUNNING"
EOF
fake osascript <<'EOF'
#!/usr/bin/env bash
echo "osascript $*" >> "$FAKE_LOG"
case "$*" in
  *" to quit"*) [[ "${FAKE_NOQUIT:-0}" == 1 ]] || rm -f "$FAKE_RUNNING" ;;
  *"create window with default profile command"*)
    cmd=${2#*command \"}; cmd=${cmd%\"}; cmd=${cmd/ -CC / -C }
    (sleep 20 | eval "$cmd" >/dev/null 2>&1) & ;;
esac
EOF
fake brew <<'EOF'
#!/usr/bin/env bash
echo "brew $*" >> "$FAKE_LOG"
plist="$ITERM_UPGRADE_APP/Contents/Info.plist"
case "$1" in
  list) [[ "${FAKE_BREW_NOCASK:-0}" == 0 ]] ;;
  update) exit 0 ;;
  info) printf '{"casks":[{"version":"%s","installed":"%s"}]}\n' "$FAKE_BREW_VERSION" "$FAKE_BREW_VERSION" ;;
  upgrade|reinstall)
    [[ ",${FAKE_BREW_WORKS:-upgrade}," == *",$1,"* ]] || { echo "Error: it broke"; exit 1; }
    sed -i '' "s#<string>[^<]*</string>#<string>$FAKE_BREW_VERSION</string>#" "$plist"
    echo "iterm2 was successfully ${1}d" ;;
esac
EOF
# mise: declares iterm2 when FAKE_MISE_STATUS is set; its upgrade only
# changes the app when FAKE_MISE_UPGRADES=1 (a cask mise manages itself).
fake mise <<'EOF'
#!/usr/bin/env bash
echo "mise $* (in $PWD)" >> "$FAKE_LOG"
case "$*" in
  "bootstrap packages status --json") echo "${FAKE_MISE_STATUS:-{\}}" ;;
  "bootstrap packages upgrade --yes brew-cask:iterm2")
    if [[ "${FAKE_MISE_UPGRADES:-0}" == 1 ]]; then
      sed -i '' "s#<string>[^<]*</string>#<string>$FAKE_BREW_VERSION</string>#" "$ITERM_UPGRADE_APP/Contents/Info.plist"
    else
      echo "mise brew-cask:iterm2: installed and managed by Homebrew; leaving unchanged"
    fi ;;
esac
EOF
# iTerm helper: windows are -C clients; a hotkey window shows $FAKE_HOTKEY_IDS.
fake fake-iterm <<'EOF'
#!/usr/bin/env bash
echo "iterm $*" >> "$FAKE_LOG"
[[ "${FAKE_HANG:-}" != "$1" ]] || exec sleep 30
case "$1" in
  ping) exit "${FAKE_PING_CODE:-0}" ;;
  hotkey-windows) [[ -z "${FAKE_HOTKEY_IDS:-}" ]] || echo "$FAKE_HOTKEY_IDS" ;;
  hotkey-profiles) [[ -z "${FAKE_PROFILES:-}" ]] || printf '%s\n' "$FAKE_PROFILES" ;;
  attach-window)
    cmd=${3/ -CC / -C }
    (sleep 20 | eval "$cmd" >/dev/null 2>&1) &
    ;;
esac
EOF
export FAKE_RUNNING="$WORK/running"
export SWARM_ITERM_HELPER="$WORK/bin/fake-iterm"
HOTKEY_PROFILE=$'G1\tYes\t/opt/homebrew/bin/tmux -CC new-session -A -s main\ttmux'

session() { tmux new-session -d -s "$1" -x 80 -y 24 /bin/sh; }
cc_attach() { (sleep 20 | tmux -C attach-session -t "=$1" >/dev/null 2>&1) & t_wait 5 attached "$1"; }
attached() { [[ -n "$(tmux list-clients -t "=$1" -F x 2>/dev/null)" ]]; }
win_id() { tmux display-message -p -t "=$1:" '#{window_id}'; }
iu() { "$T_REPO/bin/iterm-upgrade" "$@" </dev/null; }

# reset: iTerm 3.7.6 running with "main" (hotkey) and "work" attached over
# -CC, "idle" detached; brew offers 3.7.7.
reset() {
  tmux kill-server 2>/dev/null || true
  sleep 0.2
  rm -rf "$ITERM_UPGRADE_DIR"
  : > "$FAKE_LOG"; : > "$ITERM_UPGRADE_PS"
  set_app_version 3.7.6
  touch "$FAKE_RUNNING"
  export FAKE_BREW_VERSION=3.7.7 FAKE_BREW_WORKS=upgrade FAKE_PROFILES="$HOTKEY_PROFILE"
  unset FAKE_NOQUIT FAKE_BREW_NOCASK FAKE_PING_CODE FAKE_MISE_STATUS FAKE_MISE_UPGRADES
  session main; session work; session idle
  tmux new-window -d -t "=main:"
  cc_attach main; cc_attach work
  FAKE_HOTKEY_IDS=$(win_id main)
  export FAKE_HOTKEY_IDS
}

# --- plan ---
reset
expect "dry run: version"        0 "iTerm2 3.7.6 → 3.7.7 (Homebrew)" iu --dry-run
out=$(iu --dry-run 2>&1)
expect_eq "dry run: hotkey row"  "1" "$(grep -c 'main .*2 window(s)  back in the hotkey window' <<<"$out")"
expect_eq "dry run: window row"  "1" "$(grep -c 'work .*1 window(s)  reopened in a new iTerm window' <<<"$out")"
expect_eq "dry run: detached"    "1" "$(grep -c 'Not attached now, left as they are: idle' <<<"$out")"
expect_eq "dry run: still running" "1" "$([[ -e "$FAKE_RUNNING" ]] && attached main && attached work && echo 1)"
expect_eq "dry run: no brew update or upgrade" "" "$(grep -E 'brew (update|upgrade)' "$FAKE_LOG" || true)"

FAKE_PROFILES=$'G1\tYes\t/opt/homebrew/bin/tmux -CC\ttmux' \
  expect "bare tmux -CC: hotkey gets a window" 0 "run install.sh to have the hotkey bring it back" iu --dry-run
FAKE_PROFILES=$'G1\tYes\ttmux -CC new-session -A -s other\ttmux' \
  expect "profile names another session" 0 "run install.sh to rename it to 'other'" iu --dry-run

expect "no terminal, no -y"  1 "pass -y" iu
expect_eq "no -y: untouched" "1" "$(attached main && attached work && echo 1)"

FAKE_BREW_VERSION=3.7.6 expect "up to date" 0 "iTerm2 3.7.6 is up to date" iu -y
FAKE_BREW_VERSION=3.7.5 expect "newer than brew's" 0 "is up to date" iu -y
FAKE_BREW_NOCASK=1 expect "not from Homebrew" 1 "isn't installed with Homebrew" iu -y

printf '%s\n' "500 1 /Applications/iTerm.app/Contents/MacOS/iTerm2" "501 500 -zsh" "502 501 claude --resume x" \
  "600 1 /opt/homebrew/bin/tmux" "601 600 -zsh" "602 601 codex" > "$ITERM_UPGRADE_PS"
expect "stray agent listed"       0 "claude (pid 502)" iu --dry-run
expect_eq "tmux agent not listed" "" "$(iu --dry-run | grep codex || true)"
expect "stray agent: -y refuses"  1 "agents are running outside tmux" iu -y
expect_eq "stray: untouched"      "1" "$(attached main && [[ -e "$FAKE_RUNNING" ]] && echo 1)"
: > "$ITERM_UPGRADE_PS"

where() {
  bash -c 'source "$1/lib/agents-restart/common.sh"; source "$1/lib/agents-restart/discover.sh"
    source "$1/lib/iterm-upgrade/common.sh"; IU_PS_FILE="$2"; iu_where "$3"' _ "$T_REPO" "$WORK/where.ps" "$1"
}
printf '%s\n' "500 1 /Applications/iTerm.app/Contents/MacOS/iTerm2" \
  "510 1 /Users/me/Library/Application Support/iTerm2/iTermServer-3.7.6 /x.socket" \
  "501 500 -zsh" "511 510 /bin/zsh" "502 501 bash ./x" "600 1 tmux" "601 600 -zsh" "602 601 bash" "700 1 sh" > "$WORK/where.ps"
expect_eq "where: under iTerm"         "iterm" "$(where 502)"
expect_eq "where: under iTermServer"   "iterm" "$(where 511)"
expect_eq "where: under tmux"          "tmux"  "$(where 602)"
expect_eq "where: elsewhere"           ""      "$(where 700)"

# --- full run ---
reset
expect "upgrade: runs" 0 "iTerm2 upgraded: 3.7.6 → 3.7.7" iu -y
expect_eq "upgrade: app upgraded"     "3.7.7" "$(app_version)"
expect_eq "upgrade: iTerm running"    "1" "$([[ -e "$FAKE_RUNNING" ]] && echo 1)"
expect_eq "upgrade: quit then open"   "quit|open" "$(grep -oE ' to quit|^open' "$FAKE_LOG" | sed 's/^ to //' | paste -sd '|' -)"
expect_eq "upgrade: work reattached"  "1" "$(t_wait 5 attached work && echo 1)"
expect_eq "upgrade: work over -CC"    "1" "$(grep -c "attach-window --command $REAL_TMUX -CC attach-session -t =work" "$FAKE_LOG")"
expect_eq "upgrade: main waits for hotkey" "0" "$(grep -c 'attach-session -t =main' "$FAKE_LOG")"
expect_eq "upgrade: idle left alone"  "" "$(tmux list-clients -t =idle 2>/dev/null)"
expect_eq "upgrade: windows survive"  "2" "$(tmux list-windows -t =main | wc -l | tr -d ' ')"
expect_eq "upgrade: state saved"      $'-\tmain\tcc\thotkey\n-\twork\tcc\twindow' "$(cat "$ITERM_UPGRADE_DIR/state")"

# --reattach: from the saved state
tmux detach-client -s work
expect "reattach: runs"            0 "work: reopened in a new window" iu --reattach
expect_eq "reattach: work back"    "1" "$(t_wait 5 attached work && echo 1)"
expect "reattach: hotkey hint"     0 "main: press your iTerm hotkey" iu --reattach
rm -f "$ITERM_UPGRADE_DIR/state"
expect "reattach: nothing saved"   1 "nothing saved to reattach" iu --reattach

# declared in mise: mise first, from $HOME; brew when mise leaves it to Homebrew
mise_status() {
  printf '{"brew-cask":{"packages":[{"package":"iterm2","state":"installed","installed_version":"%s","auto_updates":true,"managed_by":"%s"}]}}' "$1" "$2"
}
reset
FAKE_MISE_STATUS=$(mise_status 3.7.6 homebrew); export FAKE_MISE_STATUS
expect "mise: plan names it" 0 "iTerm2 3.7.6 → 3.7.7 (mise brew-cask:iterm2, homebrew-managed)" iu --dry-run
expect "mise, Homebrew-managed: falls back" 0 "mise left iterm2 to Homebrew" iu -y
expect_eq "mise, Homebrew-managed: upgraded" "3.7.7" "$(app_version)"
expect_eq "mise, Homebrew-managed: mise then brew" \
  "mise bootstrap packages upgrade --yes brew-cask:iterm2 (in $HOME)|brew upgrade --cask --greedy iterm2" \
  "$(grep -E '^(mise bootstrap packages upgrade|brew upgrade)' "$FAKE_LOG" | paste -sd '|' -)"
reset
FAKE_MISE_STATUS=$(mise_status 3.7.7 mise); export FAKE_MISE_STATUS
out=$(FAKE_MISE_UPGRADES=1 iu -y 2>&1) || true
expect_eq "mise-managed: mise upgrades it" "1" "$(grep -c 'iTerm2 upgraded: 3.7.6 → 3.7.7' <<<"$out")"
expect_eq "mise-managed: status reported" "1" "$(grep -c 'mise bootstrap packages status: iterm2 installed 3.7.7' <<<"$out")"
expect_eq "mise-managed: no brew upgrade" "" "$(grep -E '^brew (upgrade|reinstall)' "$FAKE_LOG" || true)"
unset FAKE_MISE_STATUS

reset
FAKE_BREW_WORKS=reinstall expect "stale app: reinstalled" 0 "iTerm2 upgraded: 3.7.6 → 3.7.7" iu -y
expect_eq "stale app: upgrade then reinstall" "1" "$(grep -c 'brew reinstall --cask iterm2' "$FAKE_LOG")"

reset
FAKE_BREW_WORKS=none expect "brew fails: error"  1 "iTerm2 is still 3.7.6" iu -y
expect_eq "brew fails: iTerm back"   "1" "$([[ -e "$FAKE_RUNNING" ]] && echo 1)"
expect_eq "brew fails: work back"    "1" "$(t_wait 5 attached work && echo 1)"
expect_eq "brew fails: logged"       "1" "$(grep -c 'Error: it broke' "$ITERM_UPGRADE_DIR/last.log" | awk '{print ($1 > 0)}')"

reset
expect "no-upgrade: runs"            0 "iTerm2 3.7.6: restart only" iu -y --no-upgrade
expect_eq "no-upgrade: no brew"      "" "$(grep "^brew" "$FAKE_LOG" || true)"
expect_eq "no-upgrade: work back"    "1" "$(t_wait 5 attached work && echo 1)"

reset
FAKE_PROFILES="" expect "no hotkey profile: window instead" 0 "main: reopened in a new window" iu -y --no-upgrade

reset
FAKE_NOQUIT=1 expect "won't quit: error"     1 "iTerm2 didn't quit; skipping the upgrade" iu -y
expect_eq "won't quit: SIGTERM tried"  "1" "$(grep -c '^pkill -TERM -x iTerm2' "$FAKE_LOG")"
expect_eq "won't quit: no upgrade"     "" "$(grep 'brew upgrade' "$FAKE_LOG" || true)"
expect_eq "won't quit: work back"      "1" "$(t_wait 5 attached work && echo 1)"

# a hung iTerm API: timed out, AppleScript opens the window instead
reset
FAKE_HANG=attach-window ITERM_UPGRADE_API_TIMEOUT=1 expect "hung API: runs" 0 "work: reopened in a new window" iu -y --no-upgrade
expect_eq "hung API: AppleScript window" "1" "$(grep -c "create window with default profile command \"$REAL_TMUX -CC attach-session -t =work\"" "$FAKE_LOG")"
reset
FAKE_HANG=hotkey-windows ITERM_UPGRADE_API_TIMEOUT=1 expect "hung API: plan still shown" 0 "work" iu --dry-run

reset
rm -f "$FAKE_RUNNING"
tmux detach-client -s main; tmux detach-client -s work
expect "not running: upgrades" 0 "iTerm2 isn't running: nothing to reattach" iu -y
expect_eq "not running: launched"  "1" "$([[ -e "$FAKE_RUNNING" ]] && echo 1)"
expect_eq "not running: upgraded"  "3.7.7" "$(app_version)"
t_done
