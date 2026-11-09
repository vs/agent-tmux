#!/usr/bin/env bash
# Tests for iterm-tmux on a private tmux server (TMUX_TMPDIR). A fake tmux in
# front logs -CC attaches (they need a terminal) and passes everything else to
# the real one; an attached iTerm is a `tmux -C` client fed by sleep.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/swarm-lib.sh"
t_setup
unset SWARM_TMUX_SOCKET
REAL_TMUX=$(command -v tmux)
export TMUX_TMPDIR="$WORK/tmux"
mkdir -p "$TMUX_TMPDIR"
trap 'tmux kill-server 2>/dev/null || true; rm -rf "$WORK"' EXIT
export ITERM_TMUX_STATE="$WORK/hotkey-session"
export FAKE_LOG="$WORK/fake.log"

cat > "$WORK/bin/tmux" <<EOF2
#!/usr/bin/env bash
case " \$* " in *" -CC "*) echo "CC \$*" >> "\$FAKE_LOG"; exit 0 ;; esac
exec "$REAL_TMUX" "\$@"
EOF2
chmod +x "$WORK/bin/tmux"
attached() { [[ -n "$(tmux list-clients -t "=$1" -F x 2>/dev/null)" ]]; }
cc_attach() { (sleep 20 | tmux -C attach-session -t "=$1" >/dev/null 2>&1) & t_wait 5 attached "$1"; }

: > "$FAKE_LOG"
expect "wrapper: first run" 0 "" "$T_REPO/bin/iterm-tmux"
first=$(cat "$ITERM_TMUX_STATE")
expect_eq "wrapper: new session recorded" "1" "$(tmux has-session -t "=$first" && echo 1)"
expect_eq "wrapper: attaches it" "CC -CC attach-session -t =$first" "$(cat "$FAKE_LOG")"
: > "$FAKE_LOG"
"$T_REPO/bin/iterm-tmux"
expect_eq "wrapper: reattaches a detached one" "CC -CC attach-session -t =$first" "$(cat "$FAKE_LOG")"
expect_eq "wrapper: no new session" "1" "$(tmux list-sessions | wc -l | tr -d ' ')"
cc_attach "$first"
: > "$FAKE_LOG"
"$T_REPO/bin/iterm-tmux"
second=$(cat "$ITERM_TMUX_STATE")
expect_eq "wrapper: attached elsewhere -> new session" "1" "$([[ "$second" != "$first" ]] && tmux has-session -t "=$second" && echo 1)"
expect_eq "wrapper: attaches the new one" "CC -CC attach-session -t =$second" "$(cat "$FAKE_LOG")"
echo gone > "$ITERM_TMUX_STATE"
: > "$FAKE_LOG"
"$T_REPO/bin/iterm-tmux"
expect_eq "wrapper: stale state -> new session" "1" "$(grep -c "attach-session -t =$(cat "$ITERM_TMUX_STATE")" "$FAKE_LOG")"
t_done
