# agent-tmux

Let Claude Code and Codex agents running in panes of the same tmux window
talk to each other, and ask Codex for a review with one command.

| Part | What it does |
|---|---|
| `bin/tmux-bridge` | CLI to read, type into, and message other panes (vendored from [smux](https://github.com/ShawnPana/smux)). |
| `skills/smux` | Skill for Claude Code and Codex that teaches the `tmux-bridge` protocol (vendored from smux). |
| `skills/codex-review` | Claude Code skill: `/codex-review [extra focus]` asks the Codex session in the same window to review your changes. |
| `config/tmux.conf` | Shows pane labels (`tmux-bridge name`) in pane borders. |
| `install.sh` | Links everything into place and applies the settings below. Safe to re-run. |

## Install

```sh
./install.sh
```

It needs `tmux` (3.2+) and `jq`, and:

- links `bin/tmux-bridge` into `~/.local/bin` (must be on `PATH`);
- links `skills/smux` into `~/.claude/skills` and `~/.codex/skills`, and `skills/codex-review` into `~/.claude/skills`;
- adds `source-file <repo>/config/tmux.conf` to `~/.tmux.conf`;
- allows `Bash(tmux-bridge:*)` in `~/.claude/settings.json`;
- adds `prefix_rule(pattern=["tmux-bridge"], decision="allow")` to `~/.codex/rules/default.rules`, so Codex runs `tmux-bridge` without asking and outside its sandbox (which can't reach the tmux socket).

Anything real it would replace is moved to `~/.agent-tmux/backups/<timestamp>/` first; settings files it edits get a `*.bak-<timestamp>` copy next to them. Restart Codex afterwards; it loads skills and rules at startup.

## /codex-review

Run in Claude Code, in a tmux window that has exactly one Codex pane:

```
/codex-review
/codex-review focus on error handling
```

1. Finds the Codex pane in the current window (any pane whose process tree runs `codex`). Exits with an error if there is none or more than one.
2. Picks what to review: uncommitted changes (staged, unstaged, untracked) if any; otherwise the current branch against its base (`origin/HEAD`, else `main`/`master`); otherwise exits with "nothing to review".
3. Types a read-only review request into Codex, waits until it shows up, and submits it.
4. Codex sends the review back into the calling pane as a `[tmux-bridge from:...]` message.

`CODEX_REVIEW_DRY_RUN=1` prints the request instead of sending it.

The skill's `allowed-tools` uses the absolute path `/Users/vs/.claude/skills/codex-review/codex-review.sh`; change it if your home directory differs.

## Tests

```sh
tests/codex-review.test.sh
```

Runs every case in a detached tmux session against a fake `codex` binary (needs `cc`). It doesn't touch your other sessions.

## License

MIT: see `LICENSE`.

`bin/tmux-bridge` and `skills/smux/SKILL.md` are from [ShawnPana/smux](https://github.com/ShawnPana/smux) at commit `84734364206403a2e51b601d3ad8c85464fcdd17`, MIT licensed: see `licenses/smux-LICENSE`.
