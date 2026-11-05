# agents-restart: restart every agent in place after an upgrade

Date: 2026-11-05. Status: draft for approval.

## Why

When I upgrade Claude Code, Codex or Gemini CLI, every running session keeps
the old version until it's restarted. I usually have 3–4 iTerm tabs with 2–3
panes each, all tmux panes shown through iTerm2's tmux integration (`-CC`).
Today I restart them by hand: kill each agent, copy its resume command,
restart iTerm2, rebuild the tabs and panes, and paste each resume command back.

Restarting the agent processes in place is enough. The tabs, panes and shells
can stay as they are. One command should restart every agent on the new
version, each in its own pane, with its conversation intact.

## Goals

- One command, `agents-restart`, run from any shell after an upgrade.
- Covers every pane of every tmux session on the machine.
- Finds the panes running `claude`, `codex` or `gemini` and leaves every other
  pane alone.
- **Restarts only agents running an outdated version** (your decision). An
  agent whose running binary is the currently installed version is not
  touched, not waited for and not quit. If only Codex was upgraded, no Claude
  or Gemini is touched.
- Each agent quits cleanly and resumes **the same conversation**, in the same
  pane, folder and original command-line flags.
- **Busy agents are waited for** and restarted as soon as they're done.
  There's no timeout. Ctrl+C stops waiting, and agents already restarted stay
  restarted.
- **"Busy" includes background work** (your decision): an agent counts as
  busy while it's mid-turn *or* has anything running in the background, such
  as background shell commands, background subagents, monitors, `/loop` or
  scheduled wake-ups, or live agent-team teammates. The tool waits until all
  of it has finished, even if that takes a long time (a `/loop` may need to
  be stopped by me). The live line says what it's waiting on when that's
  known, e.g. `waiting: 2 background tasks`.
- **Agents waiting on a permission prompt are skipped and reported**, since
  they never finish on their own.
- **Agents with unsent text in their input box are skipped and reported**
  as `skipped: unsent input` (my call). Typing `/exit` would send the draft
  as a message; clearing it would lose the draft.
- **Agent-team teammate panes are skipped and reported** (my call). A
  teammate resumed on its own would lose its team, and its pane may not have
  a shell under it. The lead counts as busy while it has live teammates (see
  above), so it's restarted after they're gone.
- Nice terminal output in the spirit of mise: one line per pane, updated in
  place, a few colors, a one-line summary. Not bloated.

## Non-goals

- Restarting iTerm2 or tmux, or rebuilding windows, tabs or panes.
- Restarting the shells in panes.
- Answering permission prompts.
- Upgrading the agents. The tool only restarts them; upgrading stays a
  separate step.
- Other agent CLIs beyond these three.
- Restarting agents that are already on the installed version. There's no
  "restart everything anyway" flag (could be added later if wanted).

## Anti-goals (a failure even if it works)

- Losing a conversation: an agent quit without a correct resume command
  typed back.
- Interrupting an agent mid-turn, or killing its background work.
- Restarting an agent that wasn't upgraded.
- Sending an unsent draft as a message, or discarding it.
- Killing a pane, or force-killing an agent that won't exit.
- Typing into a pane that isn't sitting at a shell prompt (for example,
  typing a resume command into a still-running agent).
- Heavy, noisy output: boxes, banners, multi-line blocks per pane.

## Facts found on this machine

- Agents are installed via mise (`~/.local/share/mise/installs/<tool>/latest/`),
  so re-running the bare command after an upgrade picks up the new version.
  Versions at time of writing: claude 2.1.318, codex-cli 0.166.0, gemini 0.67.0.
- Every pane's root process is a login `zsh`. Agents were started from it
  (directly, or through a swarm launcher script such as
  `bash ~/.agent-tmux/swarm/run/assup-main.sh`). When an agent exits, the
  pane returns to a shell prompt.
- `claude agents --json` lists every running Claude with `pid`, `cwd`,
  `sessionId`, `name`, `status` (`busy` / `idle`) and `waitingFor` (non-null
  when stuck on a prompt). `lib/swarm/agents.sh` already reads it.
- **The live `sessionId` can differ from the `--resume` argument the process
  was started with** (seen on a resumed session). Use the live ID.
- Codex: `codex resume <SESSION_ID>` (UUID or session name). No "list running
  sessions" command was found.
- Gemini: `gemini --resume <latest|index>`; `--list-sessions` lists sessions
  for the current project. Session files live under
  `~/.gemini/tmp/<project-hash>/chats/session-<timestamp>-<id8>.json`.

## How it works (decided)

### Running it

- Scope of "every tmux session" (my call): the default tmux server plus the
  swarm server (`$SWARM_TMUX_SOCKET`, if set and different). Not every socket
  in `/tmp/tmux-<uid>/`, which holds hundreds of leftover `swarm-test-*`
  sockets.
- `bin/agents-restart` in this repo, bash 3.2 compatible like the rest. It
  needs `tmux` and `jq`, as the repo already does. No other dependencies.
- `install.sh` links it into `~/.local/bin`, the same way as `swarm`.
- Flags: `-y` skips the confirmation, `--dry-run` prints the plan and exits,
  `-h`/`--help`.
- If run from inside an agent's pane (`$TMUX_PANE` is an agent pane), that
  pane is skipped and the report tells me to restart it myself.

### Flow

1. **Discover.** List every tmux pane, its folder and its process tree. Map
   each agent process to its pane by walking parent PIDs up to `pane_pid`.
   For each agent, determine: type, running version vs. installed version,
   session ID, state (`idle`, `busy`, `prompt`, `unsent input`, `teammate`),
   the original argv, and the folder it runs in.
2. **Plan.** Print the header (installed versions) and one line per outdated
   agent pane, showing `old → new` version. Agents already up to date are not
   listed one by one; a single dim line counts them (`12 agents up to date,
   left alone`). If nothing is outdated, say so and exit 0. Otherwise ask
   `Restart N agents? [Y/n]` (skipped with `-y`; `--dry-run` stops here).
3. **Restart.** Idle outdated agents restart right away. Busy ones
   (including background work) are rechecked every few seconds and restart
   once fully idle. An agent that moves to `prompt` or gets unsent input
   while being waited on is skipped. Agents already in a skip state are
   skipped from the start.
4. **Report.** Each pane ends as restarted, skipped (with reason), or failed
   (with reason). Then one summary line.

### One restart

1. Re-check at this instant that the agent is idle with no background work
   and an empty input box.
2. Quit it the way its own UI does: `/exit` for Claude, `/quit` for Codex
   and Gemini, sent with `tmux send-keys`.
3. Wait until the agent process is gone and the pane's foreground process is
   the shell again. If it hasn't exited within ~15 s, mark it failed
   ("didn't exit within 15s") and leave it alone. No force kill.
4. Type the resume command into the pane and press Enter. The command is the
   original argv with the session ID swapped in: drop any existing
   `--resume/-r/--continue/-c` (Claude), `resume <id>`/`--last` (Codex) or
   `--resume/-r` (Gemini) arguments, then add the current session's resume
   arguments. Keep every other flag (swarm Claudes carry `--name`,
   `--settings` and so on). Prefix `cd <folder> &&` if the shell's folder
   differs from the agent's.
5. Confirm it came back: for Claude, the session ID reappears in
   `claude agents --json`; for Codex and Gemini, an agent process is running
   in the pane again. If not within ~20 s, mark it failed and print the
   resume command so I can run it by hand.

### Output

Example (colors described below):

```
agents-restart  claude 2.1.318 · codex 0.166.0 · gemini 0.67.0

  0:0.1   assup     claude  2.1.310 → 2.1.318  idle     d3cc7c38
  0:1.2   cv        claude  2.1.310 → 2.1.318  busy     5ec4d49e
  37:2.0  alpha     claude  2.1.310 → 2.1.318  prompt   c8035f45
  37:1.1  cv        codex   0.165.0 → 0.166.0  idle     7f3a91c2
  37:5.0  tmux      claude  this pane, skipped
  12 agents up to date, left alone
Restart 3 agents? [Y/n]

✓ 0:0.1   assup     claude  resumed d3cc7c38               2.1s
⠹ 0:1.2   cv        claude  waiting: 2 background tasks   1m12s
– 37:2.0  alpha     claude  skipped: permission prompt
✗ 37:1.1  cv        codex   didn't exit within 15s

agents-restart ✓ 7 restarted · 1 skipped · 1 failed   1m40s
```

- Columns: status mark, pane (`session:window.pane`), folder basename, agent
  type, state/result, short session ID (8 chars), elapsed time.
- Colors: green ✓, yellow –, red ✗; dim gray for pane addresses, session IDs
  and durations.
- Agents still in progress get a small spinner and elapsed time, redrawn in
  place. A line freezes once that agent is done.
- When stdout isn't a TTY or `NO_COLOR` is set: no colors, spinners or
  redraws; one plain line per agent as it finishes, then the summary.
- A failed restart prints its manual resume command under the summary.

## Left to the builder

- **Version detection.** Find which binary each agent process is actually
  running and compare it with what's installed now. Agents start through
  mise's `.../installs/<tool>/latest/` symlink, so argv doesn't show the
  version. Likely approach: resolve the process's executable (`lsof -p <pid>
  -a -d txt`, or the script path in argv for Node-based CLIs like Gemini)
  to its real versioned install directory and compare it with the resolved
  `latest` (or whatever `command -v <tool>` resolves to now). If the running
  version can't be determined, treat the agent as outdated and say so on its
  line (`version unknown`). Verify for all three CLIs.
- **Background-work detection for Claude.** `claude agents --json` shows
  `status` and `waitingFor`; check whether `status` already counts
  background work. If it doesn't, combine other signals: the screen footer
  (background task / teammate indicators) via `tmux capture-pane`, live child
  processes of the Claude process, and teammate panes in the same window.
  Apply the same idea to Codex and Gemini as far as their UIs expose it.
- **Unsent-input and teammate detection.** Read the input line from the
  screen; identify teammate panes (for example, Claude processes started
  with agent-team arguments, or swarm helper panes).

- **Codex session ID and busy detection.** Likely approach: find the
  rollout `.jsonl` the Codex process has open (`lsof -p`) under its sessions
  directory (`$CODEX_HOME` or `~/.codex`) and read the UUID from it; detect
  busy from the screen (the "esc to interrupt" footer) via `tmux
  capture-pane`; detect prompts the same way. Verify against a live Codex.
- **Gemini session ID and busy detection.** Verify with a live Gemini whether
  `--resume` accepts a session UUID in 0.67. If it does, find the session file
  the process writes and resume by ID. If it doesn't, resume by the index from
  `--list-sessions` that matches the session file, and fall back to `latest`
  with a warning only when that can't be determined. Busy and prompt
  detection from the screen.
- Screen-reading patterns for prompts can start from `swarm_pane_state` in
  `lib/swarm/status.sh`.
- Poll interval, exact timeouts, column widths, spinner style.
- Whether to restart idle agents one at a time or several at once, as long as
  the output stays readable.
- How to recover the original argv when the agent was started via a swarm
  launcher script (the launcher's `claude` argv is in the process table; use
  it, plus any `env -u ...` prefix the launcher applied).
- Tests in `tests/` following the existing `tests/swarm-*.test.sh` style, with
  `tmux`, `claude agents` and process lookups stubbed.
- README section and `install.sh` change.
