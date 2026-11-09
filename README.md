# agent-tmux

Let Claude Code and Codex agents running in panes of the same tmux window
talk to each other, and ask Codex for a review with one command.

| Part | What it does |
|---|---|
| `bin/tmux-bridge` | CLI to read, type into, and message other panes (vendored from [smux](https://github.com/ShawnPana/smux)). |
| `skills/smux` | Skill for Claude Code and Codex that teaches the `tmux-bridge` protocol (vendored from smux). |
| `skills/codex-review` | Claude Code skill: `/agent-tmux:codex-review [extra focus]` asks the Codex session in the same window to review your changes. |
| `bin/swarm` | CLI that runs a swarm of Claude sessions as iTerm tabs, one tab per project, over tmux. |
| `bin/swarm-iterm.py` | iTerm2 Python API helper: places tabs, detects the hotkey window, opens windows, and reads and sets hotkey profile commands. |
| `lib/swarm/` | Shell modules behind `swarm` (config, open, delegate, layout, status, watch). |
| `skills/swarm` | Claude Code skill that teaches an orchestrator to use `swarm delegate`. |
| `bin/agents-restart` | CLI that restarts upgraded Claude, Codex and Gemini agents in their tmux panes, resuming the same conversation. |
| `bin/agents-restart-argv` | Python helper for `agents-restart` that prints a process's exact argv (NUL-separated), so arguments with spaces or quotes survive into the resume command. |
| `lib/agents-restart/` | Shell modules behind `agents-restart` (discovery, state, session ids, restart flow, live UI). |
| `bin/iterm-upgrade` | CLI that upgrades iTerm2 with Homebrew, restarts it, and reattaches the tmux sessions it showed, so every agent comes back in its window, tab and pane. |
| `lib/iterm-upgrade/` | Shell modules behind `iterm-upgrade` (snapshot, app control, flow). |
| `raycast/agents-restart.sh` | Raycast script command, **Restart Agents**: runs `agents-restart -y` and shows its colored output. |
| `raycast/iterm-upgrade.sh` | Raycast script command, **Upgrade iTerm2**: runs `iterm-upgrade -y` (or a dry run, a plain restart, or a reattach) and shows its output. |
| `config/swarm.conf.example` | Starter swarm config, copied to `~/.agent-tmux/swarm.conf` by `install.sh`. |
| `config/tmux.conf` | Shows pane labels (`tmux-bridge name`) in pane borders, and re-tiles swarm tabs when panes split or close. |
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
- links `config/tmux.conf` to `~/.agent-tmux/tmux.conf` and adds `source-file -q ~/.agent-tmux/tmux.conf` to `~/.tmux.conf`, unless a line already sources that path. The line names no repo path, so a dotfiles repo can carry it (`-q`: no error where agent-tmux isn't installed). A `source-file "<repo>/config/tmux.conf"` line from an earlier version is swapped for it in place (backup under `~/.agent-tmux/backups`);
- links `bin/swarm` into `~/.local/bin` and copies `config/swarm.conf.example` to `~/.agent-tmux/swarm.conf` if you have none (never overwritten);
- links `bin/agents-restart` into `~/.local/bin`;
- links `bin/iterm-upgrade` into `~/.local/bin`, and changes any iTerm hotkey profile whose command is a bare `tmux -CC` to `tmux -CC new-session -A -s main`, renaming the session the hotkey window shows to `main` (see [The hotkey window](#the-hotkey-window); through the iTerm API, so iTerm must be open; the old command is saved in `~/.agent-tmux/backups/<timestamp>/iterm-profiles.tsv`; `AGENT_TMUX_HOTKEY_SESSION` picks another name, `AGENT_TMUX_SKIP_ITERM=1` skips it);
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

Without `--own-window`, tabs go into the tmux session shown in your iTerm hotkey window (or the one named by `set session` in the config). Run from a tab with a single plain pane, the first new project takes that tab instead (your pane becomes its shell and is moved into the project directory), and the rest go into the same session. Projects already open are selected, not duplicated.

Config lives in `~/.agent-tmux/swarm.conf` (line-based; `swarm config` prints what it parsed and any errors):

```
root ~/workspace
project tmux-agent ~/workspace/tmux
group work assup code tmux-agent
set lt_model opus
```

Each tab is a shell on the left and the agent on the right. A main tab adds a plain `claude` of your own under the orchestrator; a lieutenant's tab adds a helper pane under the agent. `swarm layout grid` (run by an agent in its own tab) allows up to three helpers instead of one.

```sh
swarm status          # every swarm tab, its agent state and report
swarm peek <lt>       # the last lines of a lieutenant's pane
swarm close <lt>      # stop a lieutenant and close its tab
```

`install.sh` leaves `swarm close` off Claude Code's allow list, so Claude Code asks your permission whenever an agent runs it. `swarm close` itself doesn't ask: run from your own shell, it closes the tab at once.

The orchestrator delegates with `swarm delegate`, through the `swarm` skill: it starts a lieutenant in the project directory, in its own tab, and the lieutenant answers with `swarm report`. `swarm help` lists every command.

A helper's permission prompt shows up in its lieutenant's pane, not the helper's. After updating the plugin from GitHub (`claude plugin update agent-tmux@agent-tmux`), new sessions get the `swarm` skill.

## Restarting agents after an upgrade

`agents-restart` finds the Claude, Codex and Gemini agents running in your tmux panes, and restarts only those older than the installed CLI. Each agent quits and resumes in place, in the same pane and the same conversation.

```sh
agents-restart            # list outdated agents, ask, then restart them
agents-restart -y         # skip the confirmation
agents-restart --dry-run  # only list what it would do; changes nothing
agents-restart -h         # usage
```

Busy agents, background work included, are waited for; press Ctrl+C to stop waiting. It looks at the default tmux server and the one in `$SWARM_TMUX_SOCKET`.

It needs `tmux`, `jq` and `python3` (to read each agent's exact command line). Without a working `python3`, agents are still listed, but each one fails with `can't read exact arguments` and keeps running untouched.

Skipped (nothing is touched): an agent at a permission prompt or with unsent input, teammate panes, panes whose screen it doesn't recognize, a CLI that isn't installed, an agent that exited while it waited, and the pane you run it from (its resume command is printed instead).

Failed (the agent keeps running and nothing is typed): no session id (for example two Codex or Gemini sessions in the same folder, `codex resume --last`, or `codex -C`), a Claude agent missing from `claude agents`, a pane with no shell to return to, or a command-line flag it doesn't know (`unknown flag <f>`: it can't tell whether the flag takes a value, so it won't guess the resume command). If a failure comes after the agent quit, a resume command is printed for you to paste. When anything failed, the path of a diagnostics log is printed.

Gemini support was built from the Gemini 0.67 source and hasn't yet been checked against a live signed-in Gemini.

Claude's vim mode isn't detected: a Claude left in vim NORMAL mode reads `/exit` as vim keys, so it may not quit, or may leave stray text in its input box.

Output is plain (no colors, spinners or redraws) when stdout isn't a terminal or `NO_COLOR` is set. `CLICOLOR_FORCE=1` keeps the colors without a terminal, still with no redraws.

### From Raycast

`raycast/agents-restart.sh` is a Raycast script command, **Restart Agents**, that runs `agents-restart -y` and shows its output, in color, in Raycast's full-output view. To add it, open Raycast Settings → Script Commands → Add Script Directory and choose this repo's `raycast/` folder (if the command doesn't show up, run Reload Script Directories). Rows appear as each agent finishes; there are no live spinners. Closing the view stops waiting for busy agents; a restart already under way still completes.

The script sets up `PATH` itself (Raycast starts scripts with a bare one): `~/.local/bin`, Homebrew, and mise's tools via `mise env`, so it finds the same `claude`, `codex` and `gemini` as your shell.

## Upgrading iTerm2 without losing agents

Agents in tmux outlive iTerm: the tmux server keeps running when iTerm quits. What gets lost is the view, since a restarted iTerm doesn't reattach its tmux sessions, and a hotkey profile running a bare `tmux -CC` opens a fresh, empty session. `iterm-upgrade` handles the whole round trip:

```sh
iterm-upgrade               # show the plan, ask, then upgrade and reattach
iterm-upgrade -y            # skip the confirmation
iterm-upgrade --no-upgrade  # only restart iTerm2 and reattach
iterm-upgrade --dry-run     # only show the plan; changes nothing
iterm-upgrade --reattach    # reattach what the last run saved (if something went wrong)
```

1. Checks Homebrew for a newer `iterm2` cask (`brew update`); if the installed app is already that version or newer, it stops there.
2. Records every tmux session iTerm has attached: `-CC` integration clients, and plain `tmux attach` clients running in iTerm tabs, on the default server and on `$SWARM_TMUX_SOCKET`. Detached sessions are listed and left as they are.
3. Detaches those clients (iTerm closes their windows; the tmux windows and their agents keep running), then quits iTerm2. If iTerm is still running 30 seconds later (an unanswered quit dialog), it gets a SIGTERM.
4. Upgrades the app while it isn't running. If your mise config declares it in `mise bootstrap` (`"brew-cask:iterm2" = "latest"`), it runs `mise bootstrap packages upgrade brew-cask:iterm2` first, from `$HOME` so the global config applies. mise upgrades a self-updating cask like iTerm2 only while the app is closed, and leaves a cask that Homebrew installed (`managed_by: homebrew`, as with `[bootstrap.brew] homebrew_metadata = true`) to Homebrew. Then, or without mise, it runs `brew upgrade --cask --greedy iterm2`, and `brew reinstall --cask iterm2` if the app on disk is still the old version (brew can record an upgrade it couldn't apply). The output goes to `~/.agent-tmux/iterm-upgrade/last.log`, and with mise, the run ends with what `mise bootstrap packages status` reports for iterm2.
5. Starts iTerm2 and reopens each session in a new window (`tmux -CC attach`), with all its tabs and panes. The hotkey window's session isn't reopened: press your hotkey and its profile reattaches it. A macOS notification says when iTerm is back.

Once the clients are detached, iTerm always comes back, even if the upgrade fails or you press Ctrl+C.

Run it from a tmux pane, which keeps running while iTerm is down; you'll find its output there after reattaching. Running it from outside iTerm, for example from Raycast, also works. A plain iTerm tab is refused, because it closes with iTerm. Agents running in plain iTerm tabs, outside tmux, end when iTerm quits: they're listed before you confirm, and `-y` refuses to go on while there are any.

It needs iTerm2 installed with Homebrew, directly or through mise (`--no-upgrade` works either way), `tmux`, `jq`, and the iTerm helper venv for opening windows (without it, it falls back to AppleScript).

### From Raycast

`raycast/iterm-upgrade.sh` is a Raycast script command, **Upgrade iTerm2**. It's in the same `raycast/` folder as Restart Agents, so once that folder is a script directory (Raycast Settings → Script Commands → Add Script Directory; run Reload Script Directories if it doesn't show up), it's there. Its optional dropdown picks **Upgrade** (the default: `iterm-upgrade -y`), **Dry run**, **Restart only** (`--no-upgrade`) or **Reattach** (`--reattach`).

Raycast runs outside iTerm, so its output view stays up through the restart and shows Homebrew's progress live. Running the command is the confirmation (Raycast has no terminal to ask in), but it still refuses while agents run outside tmux. The first run may ask to let Raycast control iTerm2: allow it. Keep the output view open until it finishes: closing it may stop the run partway. If iTerm doesn't come back, open it and run **Reattach**.

### The hotkey window

A hotkey profile running a bare `tmux -CC` starts a new session every time it opens, so after an iTerm restart the session it showed stays detached, out of view. `install.sh` changes its command to `tmux -CC new-session -A -s main`: it attaches the session named `main`, creating it the first time, and the session the hotkey shows when you install is renamed to `main`. After an upgrade, a crash or an in-app (Sparkle) update, the hotkey brings that session back.

The command needs nothing but tmux, no file from this repo, so iTerm prefs kept in a dotfiles repo still work on a new machine before agent-tmux is installed. `iterm-upgrade` treats the hotkey's session as the hotkey's when the profile names it this way (`new-session -A -s <name>` or `new -s <name> -A`).

Earlier versions pointed the profile at a `~/.local/bin/iterm-tmux` wrapper; `install.sh` replaces that command too, and removes the link.

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
