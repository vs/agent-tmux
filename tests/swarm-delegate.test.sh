#!/usr/bin/env bash
# Tests for `swarm delegate`.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/swarm-lib.sh"
t_setup

t_session home
(sleep 600 | t_tmux -C attach -t home) >/dev/null 2>&1 &
ctl=$!; disown "$ctl"
sleep 0.5
export FAKE_ITERM_CODE=0

mkdir -p "$HOME/workspace"/{assup,code}
swarm assup code
win_of() { t_tmux list-windows -t home -F '#{window_id} #{window_name}' | awk -v n="$1" '$2==n{print $1}'; }
A=$(win_of assup-main)
M=$(t_tmux list-panes -t "$A" -F '#{pane_id}' | sed -n 2p)
d() { TMUX_PANE=$M swarm delegate "$@"; }
brief() { printf '%s' "$1" | d "${@:2}" -; }
U=$(t_tmux new-window -d -P -F '#{pane_id}' -t home)
nwin() { t_tmux list-windows -t home | wc -l | tr -d ' '; }
n0=$(nwin)

expect "outside main tab" 1 "must be run from a project's main tab" sh -c "echo hi | TMUX_PANE=$U swarm delegate x -"
expect "no TMUX_PANE"     1 "not inside a tmux pane" sh -c "echo hi | env -u TMUX_PANE swarm delegate x -"
expect "bad name main"    1 "invalid lieutenant name" sh -c "echo hi | TMUX_PANE=$M swarm delegate main -"
expect "bad name chars"   1 "invalid lieutenant name" sh -c "echo hi | TMUX_PANE=$M swarm delegate 'Bad_Name' -"
expect "empty brief"      1 "empty brief" sh -c "printf '' | TMUX_PANE=$M swarm delegate auth -"
expect_eq "errors create no window" "$n0" "$(nwin)"
expect_eq "errors create no run dir" "no" "$([ -e "$SWARM_STATE_DIR/run/assup-auth" ] && echo yes || echo no)"

expect_eq "no session id before delegate" "" "$(t_tmux show -wqv -t "$A" @swarm-session-id)"
printf '[{"name":"assup-main","status":"busy","sessionId":"sm1"}]' > "$FAKE_AGENTS_JSON"
expect "delegates" 0 "delegated auth in tab assup:auth (session assup-auth)" sh -c "echo 'Do the thing' | TMUX_PANE=$M swarm delegate auth -"
expect_eq "delegate records main session id" "sm1" "$(t_tmux show -wqv -t "$A" @swarm-session-id)"
printf '[{"name":"assup-main","status":"busy"}]' > "$FAKE_AGENTS_JSON"
order=$(t_tmux list-windows -t home -F '#{window_name}' | tr '\n' ' ')
expect "inserted after project's tabs" 0 "assup-main assup:auth code-main" echo "$order"
w=$(win_of assup:auth)
expect_eq "panes: shell then lt" "shell auth" "$(t_tmux list-panes -t "$w" -F '#{@name}' | tr '\n' ' ' | sed 's/ $//')"
want=$(cd -P "$HOME/workspace/assup" && pwd)
expect_eq "lt cwd is project dir" "$want" "$(t_tmux display -p -t "$w.1" '#{pane_current_path}')"
expect_eq "tags" "lieutenant auth assup $HOME/workspace/assup stack" "$(t_tmux display -p -t "$w" '#{@swarm-role} #{@swarm-name} #{@swarm-project} #{@swarm-dir} #{@swarm-layout}')"
expect_eq "focus unchanged" "$A" "$(t_tmux display -p -t home '#{window_id}')"
lt_logged() { grep -a 'assup-auth' "$FAKE_CLAUDE_LOG" | grep -aq 'Do the thing'; }
expect "lieutenant started" 0 "" t_wait 15 lt_logged
line=$(grep -a 'assup-auth' "$FAKE_CLAUDE_LOG" | grep -a 'Do the thing')
for want in "--teammate-mode"$'\x1f'"tmux" "--model"$'\x1f'"opus" '"telegram@claude-plugins-official":false' "--append-system-prompt-file"$'\x1f'"$SWARM_STATE_DIR/run/assup-auth/prompt.md" $'\x1f'"Do the thing"; do
  expect "launch arg: $want" 0 "" grep -qF -- "$want" <<<"$line"; done
run="$SWARM_STATE_DIR/run/assup-auth"
expect "agent teams on" 0 "" grep -q 'CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1' "$run/launch.sh"
expect "brief saved" 0 "Do the thing" cat "$run/brief.md"
expect "prompt names parent" 0 "assup-main" cat "$run/prompt.md"
expect "prompt names dir" 0 "$HOME/workspace/assup" cat "$run/prompt.md"
expect "prompt has no placeholders" 1 "" grep -q '{{' "$run/prompt.md"
expect "place-tab called" 0 "place-tab --new $w --project $A" cat "$FAKE_ITERM_LOG"

expect "duplicate name" 1 "lieutenant 'auth' already exists in tab assup:auth" sh -c "echo x | TMUX_PANE=$M swarm delegate auth -"

# Second lieutenant goes after the first; --model, --brief-file.
printf 'from file\n' > "$WORK/b.md"
expect "brief file + model" 0 "delegated db" env TMUX_PANE="$M" swarm delegate db --model sonnet --brief-file "$WORK/b.md"
order=$(t_tmux list-windows -t home -F '#{window_name}' | tr '\n' ' ')
expect "second after first" 0 "assup-main assup:auth assup:db code-main" echo "$order"
db_logged() { grep -a 'assup-db' "$FAKE_CLAUDE_LOG" | grep -aq 'from file'; }
expect "db started" 0 "" t_wait 15 db_logged
expect "model override" 0 "" sh -c "grep -a 'assup-db' '$FAKE_CLAUDE_LOG' | grep -qF -- $'--model\x1fsonnet'"
expect_eq "missing session id keeps the old one" "sm1" "$(t_tmux show -wqv -t "$A" @swarm-session-id)"
echo '[]' > "$FAKE_AGENTS_JSON"

# Brief survives quoting: quote, \$HOME, newline.
tricky=$'it\'s "quoted" $HOME `x`\nsecond line'
expect "tricky brief" 0 "delegated q" sh -c "printf '%s' \"\$1\" | TMUX_PANE=$M swarm delegate q -" _ "$tricky"
q_logged() { grep -aq 'second line' "$FAKE_CLAUDE_LOG"; }
expect "tricky logged" 0 "" t_wait 15 q_logged
got=$(awk 'BEGIN{RS="\n"} /assup-q/{p=1} p{print}' "$FAKE_CLAUDE_LOG" | sed 's/^.*\x1f\(it'"'"'s\)/\1/')
expect_eq "brief arrives verbatim" "$tricky" "$got"

FAKE_ITERM_CODE=3
expect "place-tab failure only warns" 0 "stays at the end" sh -c "echo x | TMUX_PANE=$M swarm delegate warn -"
FAKE_ITERM_CODE=0
expect "grid layout option" 0 "delegated par" sh -c "echo x | TMUX_PANE=$M swarm delegate par --layout grid -"
expect_eq "grid tag" "grid" "$(t_tmux show -wv -t "$(win_of assup:par)" @swarm-layout)"
t_done
