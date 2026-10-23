#!/usr/bin/env bash
# codex-review — ask the single Codex session in this tmux window to review
# uncommitted changes (if any) or the current branch against its base.
# Usage: codex-review.sh [extra focus instructions...]
set -euo pipefail

die() { echo "codex-review: error: $*" >&2; exit 1; }

command -v tmux-bridge >/dev/null 2>&1 || die "tmux-bridge not found on PATH"
[[ -n "${TMUX_PANE:-}" ]] || die "not running inside tmux"

# --- Find the one Codex pane in this window ---

# A pane counts as Codex if any process under its shell is codex. The pane's
# foreground command alone is not enough: it changes while Codex runs tools.
procs=$(ps -ax -o pid=,ppid=,comm=)

pane_runs_codex() {
  awk -v root="$1" '
    { pid[NR] = $1; ppid[NR] = $2; n = split($3, parts, "/"); comm[NR] = parts[n] }
    END {
      tree[root] = 1
      do {
        grew = 0
        for (i = 1; i <= NR; i++)
          if (tree[ppid[i]] && !tree[pid[i]]) { tree[pid[i]] = 1; grew = 1 }
      } while (grew)
      for (i = 1; i <= NR; i++)
        if (tree[pid[i]] && comm[i] ~ /^codex/) exit 0
      exit 1
    }' <<<"$procs"
}

codex_panes=()
while read -r pane_id pane_pid; do
  [[ "$pane_id" == "$TMUX_PANE" ]] && continue
  if pane_runs_codex "$pane_pid"; then codex_panes+=("$pane_id"); fi
done < <(tmux list-panes -t "$TMUX_PANE" -F '#{pane_id} #{pane_pid}')

case ${#codex_panes[@]} in
  0) die "no Codex session running in this tmux window" ;;
  1) codex="${codex_panes[0]}" ;;
  *) die "expected one Codex session in this window, found ${#codex_panes[@]}: ${codex_panes[*]}" ;;
esac

# --- Decide what to review ---

repo=$(git rev-parse --show-toplevel 2>/dev/null) || die "$(pwd) is not inside a git repository"
cd "$repo"

if [[ -n "$(git status --porcelain)" ]]; then
  scope="the uncommitted changes in $repo (staged, unstaged, and untracked files: see git status, git diff HEAD, and read the untracked files)"
else
  base=""
  if ref=$(git symbolic-ref -q --short refs/remotes/origin/HEAD); then
    base="$ref"
  else
    for b in main master; do
      if git rev-parse -q --verify "refs/heads/$b" >/dev/null; then base="$b"; break; fi
    done
  fi
  [[ -n "$base" ]] || die "working tree is clean and no base branch (origin/HEAD, main, master) was found"

  branch=$(git branch --show-current)
  ahead=$(git rev-list --count "$base..HEAD")
  [[ "$ahead" -gt 0 ]] || die "nothing to review: working tree is clean and ${branch:-HEAD} has no commits ahead of $base"

  scope="the changes on branch ${branch:-HEAD (detached)} in $repo against $base ($ahead commits: see git log $base..HEAD and git diff $base...HEAD)"
fi

# --- Send the request ---

nonce="cr-$(date +%s)-$$"
msg="Please review $scope."
msg+=" Focus on correctness bugs, missing tests, and consistency with the project's design; rank findings by severity with file:line refs. Do not modify any files."
if [[ $# -gt 0 ]]; then
  msg+=" Additional focus: $*."
fi
msg+=" When done, send your review back with tmux-bridge: tmux-bridge read $TMUX_PANE, then tmux-bridge message $TMUX_PANE \"<review as a single line>\", then tmux-bridge read $TMUX_PANE, then tmux-bridge keys $TMUX_PANE Enter. ($nonce)"

if [[ -n "${CODEX_REVIEW_DRY_RUN:-}" ]]; then
  echo "codex-review: dry run, would send to $codex:"
  echo "$msg"
  exit 0
fi

tmux-bridge read "$codex" 5 >/dev/null
tmux-bridge message "$codex" "$msg"

# The Codex TUI renders typed text with a delay; wait for it before submitting.
landed=""
for _ in $(seq 1 30); do
  if tmux capture-pane -t "$codex" -p -J | grep -qF "$nonce"; then landed=1; break; fi
  sleep 0.1
done
[[ -n "$landed" ]] || die "request text did not appear in Codex pane $codex; not submitting (check that pane)"

tmux-bridge read "$codex" 5 >/dev/null
tmux-bridge keys "$codex" Enter

echo "codex-review: sent to Codex pane $codex — reviewing $scope"
echo "codex-review: the review will arrive in this pane ($TMUX_PANE) as a [tmux-bridge from:...] message"
