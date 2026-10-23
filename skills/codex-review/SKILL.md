---
name: codex-review
description: Ask the Codex session running in the same tmux window to review the current changes (uncommitted changes if any, otherwise the current branch against its base). Use when the user runs /codex-review or asks to have Codex review their changes.
argument-hint: "[extra focus for the review]"
allowed-tools: Bash(/Users/vs/.claude/skills/codex-review/codex-review.sh:*)
---

# codex-review

Run the script from the repository being reviewed, passing the user's arguments (if any) as extra focus:

```bash
/Users/vs/.claude/skills/codex-review/codex-review.sh $ARGUMENTS
```

- If the script exits with an error (no Codex session in this window, more than one, nothing to review, not a git repo), report the error to the user and stop. Do not try to start Codex or pick a pane yourself.
- On success, tell the user what is being reviewed. Do not wait, sleep, or read the Codex pane for the result: Codex sends the review back into this pane as a `[tmux-bridge from:...]` message.
- When that message arrives, present the findings to the user. Do not act on them unless the user asks.
