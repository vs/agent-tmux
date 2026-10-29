# agent-tmux

Let Claude Code and Codex agents running in panes of the same tmux window
talk to each other, and ask Codex for a review with one command.

| Part | What it does |
|---|---|
| `bin/tmux-bridge` | CLI to read, type into, and message other panes (vendored from [smux](https://github.com/ShawnPana/smux)). |
| `skills/smux` | Skill for Claude Code and Codex that teaches the `tmux-bridge` protocol (vendored from smux). |
| `skills/codex-review` | Claude Code skill: `/agent-tmux:codex-review [extra focus]` asks the Codex session in the same window to review your changes. |
| `bin/swarm` | CLI that runs a swarm of Claude sessions as iTerm tabs, one tab per project, over tmux. |
| `bin/swarm-iterm.py` | iTerm2 Python API helper: places tabs and detects the hotkey window. |
| `lib/swarm/` | Shell modules behind `swarm` (config, open, delegate, layout, status, watch). |
| `skills/swarm` | Claude Code skill that teaches an orchestrator to use `swarm delegate`. |
| `config/swarm.conf.example` | Starter swarm config, copied to `~/.agent-tmux/swarm.conf` by `install.sh`. |
| `config/tmux.conf` | Shows pane labels (`tmux-bridge name`) in pane borders. |
| `.claude-plugin/` | Makes the repo a Claude Code plugin and its own marketplace. |
| `install.sh` | Sets up what the plugin can't (Codex, tmux, permissions). Safe to re-run. |

## Install

Claude Code, as a plugin (provides both skills, and puts `bin/` on the Bash tool's `PATH`):

```sh
claude plugin marketplace add vs/agent-tmux
claude plugin install agent-tmux@agent-tmux
```

Then, for Codex and tmux:

```sh
./install.sh
```

It needs `tmux` (3.2+) and `jq`, and:

- links `bin/tmux-bridge` into `~/.local/bin` (must be on `PATH`; Codex needs it there);
- links `skills/smux` into `~/.codex/skills`;
- removes `~/.claude/skills/{smux,codex-review}` links left by earlier versions, which would duplicate the plugin's skills;
- adds `source-file <repo>/config/tmux.conf` to `~/.tmux.conf`;
- links `bin/swarm` into `~/.local/bin` and copies `config/swarm.conf.example` to `~/.agent-tmux/swarm.conf` if you have none (never overwritten);
- creates `~/.agent-tmux/venv` with the `iterm2` package for tab placement (a failure only warns; `AGENT_TMUX_SKIP_VENV=1` skips it);
- allows `Bash(tmux-bridge:*)` and `Bash(swarm <open|delegate|status|peek|report|watch|layout|config>:*)` in `~/.claude/settings.json`, but not `swarm close`, so killing a running lieutenant always asks;
- adds `prefix_rule(pattern=["tmux-bridge"], decision="allow")` to `~/.codex/rules/default.rules`, so Codex runs `tmux-bridge` without asking and outside its sandbox (which can't reach the tmux socket).

Anything real it would replace is moved to `~/.agent-tmux/backups/<timestamp>/` first; settings files it edits get a `*.bak-<timestamp>` copy next to them. Restart Codex afterwards; it loads skills and rules at startup.

## Swarm

`swarm` runs Claude Code sessions as a swarm: one iTerm tab per project, each backed by a tmux window. A project's main tab holds an orchestrator session; the orchestrator hands work to lieutenants (more Claude sessions) in their own tabs, and a watcher flags stalled or unreported ones.

```sh
swarm work                  # open every project in the group "work"
swarm assup tmux-agent      # projects, groups or paths, in the order given
swarm open --own-window work   # the only way to get a new iTerm window
```

Without `--own-window`, tabs go into your current iTerm window. Projects already open are selected, not duplicated.

Config lives in `~/.agent-tmux/swarm.conf` (line-based; `swarm config` prints what it parsed and any errors):

```
root ~/workspace
project tmux-agent ~/workspace/tmux
group work assup code tmux-agent
set lt_model opus
```

Each tab is a shell on the left and the agent on the right; a lieutenant's tab adds a helper pane under the agent. `swarm layout grid` (run by an agent in its own tab) allows up to three helpers instead of one.

```sh
swarm status          # every swarm tab, its agent state and report
swarm peek <lt>       # the last lines of a lieutenant's pane
swarm close <lt>      # stop a lieutenant and close its tab (asks first)
```

The orchestrator delegates with `swarm delegate`, through the `swarm` skill: it starts a lieutenant in the project directory, in its own tab, and the lieutenant answers with `swarm report`. Run `swarm help` for the rest.

## /agent-tmux:codex-review

Run in Claude Code, in a tmux window that has exactly one Codex pane:

```
/agent-tmux:codex-review
/agent-tmux:codex-review focus on error handling
```

1. Finds the Codex pane in the current window (any pane whose process tree runs `codex`). Exits with an error if there is none or more than one.
2. Picks what to review: uncommitted changes (staged, unstaged, untracked) if any; otherwise the current branch against its base (`origin/HEAD`, else `main`/`master`); otherwise exits with "nothing to review".
3. Types a read-only review request into Codex, waits until it shows up, and submits it.
4. Codex sends the review back into the calling pane as a `[tmux-bridge from:...]` message.

`CODEX_REVIEW_DRY_RUN=1` prints the request instead of sending it.

## Tests

```sh
for t in tests/*.test.sh; do "$t"; done
```

Each runs on a private tmux server or temp `HOME` with fake `codex`, `claude` and iTerm helpers (`codex-review` needs `cc`). They don't touch your other sessions or settings.

## License

MIT: see `LICENSE`.

`bin/tmux-bridge` and `skills/smux/SKILL.md` are from [ShawnPana/smux](https://github.com/ShawnPana/smux) at commit `84734364206403a2e51b601d3ad8c85464fcdd17`, MIT licensed: see `licenses/smux-LICENSE`.
