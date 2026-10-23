#!/usr/bin/env bash
# Tests for skills/codex-review/codex-review.sh. Runs in a detached tmux
# session against a fake `codex` that echoes what is typed into it.
set -euo pipefail

REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
SCRIPT="$REPO/skills/codex-review/codex-review.sh"
SESSION="codex-review-test-$$"
WORK=$(mktemp -d)
export PATH="$REPO/bin:$PATH"

cleanup() { tmux kill-session -t "$SESSION" 2>/dev/null || true; rm -rf "$WORK"; }
trap cleanup EXIT

failures=0
pass() { echo "ok   $1"; }
fail() { echo "FAIL $1"; echo "$2" | sed 's/^/     /'; failures=$((failures + 1)); }

# expect <name> <exit code> <output substring> <dir> <cmd...>
expect() {
  local name="$1" want_code="$2" want_out="$3" dir="$4"; shift 4
  local out code=0
  out=$(cd "$dir" && TMUX_PANE="$caller" "$@" 2>&1) || code=$?
  if [[ "$code" == "$want_code" && "$out" == *"$want_out"* ]]; then
    pass "$name"
  else
    fail "$name" "exit $code (want $want_code), output:
$out"
  fi
}

# A binary named `codex` that echoes each line it reads.
mkdir -p "$WORK/bin"
printf '#include <stdio.h>\nint main(void){char b[8192];while(fgets(b,sizeof b,stdin)){printf("GOT: %%s",b);fflush(stdout);}return 0;}\n' > "$WORK/fake.c"
cc -o "$WORK/bin/codex" "$WORK/fake.c"

repo="$WORK/repo"
mkdir -p "$repo" "$WORK/nogit"
git -C "$repo" init -q -b main
git -C "$repo" -c user.name=t -c user.email=t@t commit -q --allow-empty -m init

tmux new-session -d -s "$SESSION" -c "$repo" -x 200 -y 50
caller=$(tmux display -t "$SESSION" -p '#{pane_id}')

expect "no codex in window" 1 "no Codex session running" "$repo" "$SCRIPT"

codex=$(tmux split-window -d -t "$SESSION" -c "$repo" -P -F '#{pane_id}' "$WORK/bin/codex")
sleep 0.3

expect "not a git repo" 1 "is not inside a git repository" "$WORK/nogit" "$SCRIPT"
expect "clean main" 1 "nothing to review" "$repo" "$SCRIPT"

git -C "$repo" switch -q -c feat
echo x > "$repo/a.txt"
git -C "$repo" add a.txt
git -C "$repo" -c user.name=t -c user.email=t@t commit -q -m feat
expect "branch ahead of main" 0 "changes on branch feat" "$repo" \
  env CODEX_REVIEW_DRY_RUN=1 "$SCRIPT" check error handling
expect "extra focus is passed on" 0 "Additional focus: check error handling." "$repo" \
  env CODEX_REVIEW_DRY_RUN=1 "$SCRIPT" check error handling

echo y > "$repo/b.txt"
expect "uncommitted changes win" 0 "the uncommitted changes" "$repo" \
  env CODEX_REVIEW_DRY_RUN=1 "$SCRIPT"

expect "sends to codex" 0 "sent to Codex pane $codex" "$repo" "$SCRIPT"
sleep 0.3
if tmux capture-pane -t "$codex" -p -J | grep -q '^GOT: \[tmux-bridge from:'; then
  pass "codex received and submitted the request"
else
  fail "codex received and submitted the request" "$(tmux capture-pane -t "$codex" -p -J)"
fi

tmux split-window -d -t "$SESSION" -c "$repo" "$WORK/bin/codex"
sleep 0.3
expect "two codex panes" 1 "expected one Codex session in this window, found 2" "$repo" "$SCRIPT"

[[ $failures -eq 0 ]] || { echo "$failures failed"; exit 1; }
echo "all passed"
