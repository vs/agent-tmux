# Swarm: a visible tree of Claude Code sessions in iTerm

Date: 2026-10-28. Status: draft for approval.

## Why

Big tasks get delegated by my main Claude Code session (the *orchestrator*) to
*lieutenants*, which run their own helpers. I want the whole tree to be
visible where I already work, in iTerm through tmux's control mode, so I can
watch progress and read results by moving through tabs and panes. Asking a
status command is the backup, not the main way to look.

## Goals

- By default, everything goes into **the iTerm window I always use**: my
  hotkey window, opened with a double Ctrl press, which is the `-CC` window
  of tmux session `0`. Swarm adds tabs to it and never opens another iTerm
  window by default. Each project has a main tab running its orchestrator,
  then one tab per lieutenant. A project's tabs sit next to each other, and
  my own tabs stay where they are.
- A project goes into its own iTerm window only when I ask for that explicitly.
- When the orchestrator delegates, a new tab opens with a lieutenant in it.
- **A lieutenant's tab starts simple (your decision):** a big pane on the
  left half with a plain shell for me (to start a docker container, run
  commands and so on), and the right half split top and bottom: the
  lieutenant on top, its worker below. That's 3 panes, matching SDD's one
  helper at a time.
- **A more complex setup is opt-in.** The orchestrator, at delegation, or
  the lieutenant itself, when it needs parallel helpers, can switch the tab
  to a grid with up to 3 helpers.
- When a lieutenant runs superpowers:subagent-driven-development (SDD), SDD's
  implementer and reviewer subagents show up as panes in its tab, without
  changing SDD.
- Every pane is labeled with who is in it.
- The orchestrator notices a stuck lieutenant and quietly nudges or
  redirects it.
- It's installed once per user account, with nothing added to project repos.
- `tmux-bridge`, `smux` and `codex-review` keep working.

## Non-goals

- Keeping a finished helper's pane open. Helper panes close when the helper
  shuts down (after about 20–30 s with SDD). The lieutenant's own pane is the
  record: it says what each helper did and what came back. Commits are the
  other record.
- Answering or reporting permission prompts. When any agent stops at a
  prompt, I find it and answer it in that pane myself. The orchestrator never
  answers a prompt for me and doesn't tell me about it. (A 30-second
  escalation to the main tab was considered and dropped.)
- Reporting stuck agents to me. The orchestrator handles them quietly. I see
  their state when I look, or when I ask.
- Closing tabs automatically. Tabs stay open until I close them, including
  after a lieutenant finishes and after the orchestrator exits.
- Saving money by using weaker models. Pick models the way SDD does: the
  cheapest one that does the job well, and stronger ones where judgment
  matters.

## Anti-goals (failure even if it "works")

- A lieutenant tab that fills up with unlabeled `general-purpose` panes I
  can't tell apart.
- The orchestrator approving prompts or getting around my `ask` rules (`rm`,
  `rmdir`, `mv`, `chmod`, `chown`, `sudo`).
- Agent-teams behavior leaking into the orchestrator, so that its own
  subagents become panes in the main tab.
- An iTerm window popping up when I didn't ask for one.
- Swarm moving, renaming, re-laying out or closing my own (untagged) tabs
  and panes, or hooks and settings that change how they behave.
- Anything written into project repos.

## Environment

macOS. iTerm2 3.7.6 with tmux integration (`-CC`). tmux 3.8 (Homebrew,
`/opt/homebrew/bin/tmux`). Claude Code 2.1.311. `it2` at
`/Applications/iTerm.app/Contents/Resources/utilities/it2`. My default
permission mode is `auto`, and my user settings have the `ask` rules listed
above.

## Verified facts

Facts 1–9 come from the first spike. Facts 10–22 were tested on 2026-10-28
in a scratch tmux session.

1. Agent teams can't express the tree: teammates can't spawn teammates, and a
   session has only one team. The orchestrator–lieutenant link is not a team.
2. Sessions started with `claude --name <name>` message each other by name
   with `SendMessage` and are discovered with `ListAgents`. Delivery wakes an
   idle session. `ListAgents` shows each session's tmux location. A chain
   from orchestrator to lieutenant to pane worker and back worked.
   Messages are held for approval across permission classes (bypass vs.
   other modes), unless the receiver runs with
   `--settings '{"crossSessionInbound":"accept"}'`.
3. `CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1 claude --name <lt> --teammate-mode tmux ...`
   in a tmux window turns every subagent the lieutenant names into a
   teammate pane in that window. SDD needs no changes.
4. Teammates don't appear in `claude agents --json` or `ListAgents`. The team
   config under `~/.claude/teams/` is runtime state; never edit it.
5. `claude agents --json` gives each live session's `name`, `cwd`, `status`
   (`busy`, `waiting`, `idle`), `waitingFor`, `pid` and `sessionId`.
6. Window numbers shift when windows close. Address things by name, window
   ID (`@N`) or pane ID (`%N`).
7. iTerm shows only tmux sessions that have an attached `-CC` client.
8. Claude Code rate-limits message bursts and loops.
9. `ask` rules fire even in bypass mode. Cleanup steps like `rm` will stop a
   lieutenant at a prompt.
10. **Folder trust is a non-issue for lieutenants.** Claude Code shows "Do
    you trust this folder?" in a folder it hasn't seen before. A lieutenant
    starts in the project folder, which is already trusted, and a `git
    worktree` of an already-trusted repo, even one outside the repo,
    starts with no prompt either. That covers worktrees superpowers
    creates. Trust is stored as
    `projects["<path>"].hasTrustDialogAccepted` in `~/.claude.json`. Don't
    edit that file: running sessions write it all the time.
11. **Claude Code re-lays out teammate panes after every split.** Each spawn
    runs `split-window`, then its own `select-layout` and `resize-pane`,
    giving a lead at about 30% width with helpers stacked on the right. A
    re-tile run synchronously from a split hook gets overwritten.
12. **A re-tile run about 0.6 s after the split holds.** Started in the
    background from the hook, `select-layout tiled` produced a 2×2 with lead
    plus 3 helpers. That layout lasted the helpers' whole lifetime (about
    45 s), and Claude Code didn't fight it.
13. **Helper names are in the pane's process args.** The teammate process is
    `claude --agent-id helper-a@session-… --agent-name helper-a --team-name …
    --agent-type general-purpose --permission-mode auto --model haiku`.
    Pane titles show only the agent type. `ps -o args= -p <pane_pid>` gives
    the name. Setting the pane option `@name` shows it in the border through
    the existing `pane-border-format`.
14. **The model SDD asks for is honored, and so is the permission mode.**
    `--model haiku` showed up in the process args, and the teammate reported
    `claude-haiku-5-5`. Teammates inherit the lead's permission mode.
15. **Claude Code sets its own window options on the lieutenant window:**
    `pane-border-status top`, `pane-border-style`, `automatic-rename off`.
16. **`set-hook -w` doesn't make command hooks window-scoped.**
    `after-split-window` and `after-kill-pane` set with `-w` act on the whole
    session. Hooks fire for every window in the session. Only `pane-*`
    hooks are truly per-window. Teammate panes are closed with `kill-pane`
    (`pane-exited` didn't fire), and in `after-kill-pane`,
    `#{window_id}` is the session's *current* window, not the window the
    pane was in. Targeting `session:name` once landed on the wrong window;
    target by `@id`.
17. **`run-shell` from a hook has a bare `PATH`** (`/usr/bin:/bin:/usr/sbin:/sbin:<iTerm utilities>`).
    Homebrew's `tmux` isn't on it.
18. **Opening a new iTerm window for a tmux session works with `it2`:**
    `it2 window new` (prints `Created new window: <id>`), then
    `it2 session run --session <session id> "tmux -CC attach -t <s>"`. It
    attached as a second control client while session `0` stayed attached.
    `it2 window new --command …` was ignored and gave a plain shell. The
    plain-shell "gateway" window stays open after attaching.
19. **Tab order in iTerm:** a tmux window created live while attached, with
    `new-window -a -t <id>` or a plain `new-window`, shows up as a new tab *at
    the end* of the iTerm window, whatever its tmux index. After a detach and
    reattach, iTerm orders tabs by tmux index. A window moved with
    `move-window` disappeared from iTerm and never came back. Never
    use `move-window` or `swap-window` on attached swarm sessions.
20. **A lieutenant can hang after a helper's pane closes.** In the spike, the
    lead waited for a shutdown confirmation that never came after the pane
    had already closed, and sat idle.
21. **Each teammate starts all enabled plugins**, including the Telegram
    plugin's server. This explains why Telegram dropped in the orchestrator
    when other sessions started.
22. **iTerm's Python API can put live tabs in tmux order.** With the `iterm2`
    pip package (in a venv; iTerm has no bundled runtime here, and the API
    connected without an auth dialog), each tab's `tmux_window_id` gives its
    tmux window (`30` = `@30`). `window.async_set_tabs([...])` reordered a
    live `-CC` window so a tab added at the end moved next to its neighbor.
    tmux's window order didn't change, the client stayed attached, and the
    moved tab stayed live: its title updated, killing another window
    worked, and new windows still appeared.
23. **The hotkey window can be found through the API.** My hotkey window
    (double Ctrl, profile `tmux`) reports `isHotkeyWindow = 1`, and its tabs'
    `tmux_window_id`s are session `0`'s windows. Session `0` is the only
    session with a control-mode client.
24. **The default 3-pane layout works and holds.** A window with a shell
    pane (index 0) and a lieutenant pane (index 1, split to the right):
    Claude Code's own layout pass already keeps the shell as the big left
    pane (at about 30%), with teammates stacked under the lead on the right.
    A delayed re-tile with `main-pane-width 50%` and
    `select-layout main-vertical` gave a shell on the left half, the
    lieutenant top-right and the worker bottom-right. It held through one
    worker, then two in parallel (stacked three high on the right), and went
    back to shell plus lieutenant, side by side, when they exited. Labels
    from `--agent-name` worked.
25. **Hook quoting:** `#{session_id}` expands to `$12`, which `sh` reads as
    a variable, so the hook passed garbage and silently did nothing. Shipped
    form: pass the unquoted `#{q:session_name}`, which tmux shell-escapes (the
    quoted `'#{session_name}'` form broke on names with `"`, `$` or backticks).

Verified in the live check (2026-10-29):

26. **Teammates inherit the lead's `--settings`.** Seen in a helper's args:
    `--settings {"crossSessionInbound":"accept","enabledPlugins":{"telegram@claude-plugins-official":false}}`.
    No Telegram process started for the lieutenant or its helpers.
27. **A teammate's permission prompt is forwarded to its lead.** The prompt is
    answered in the lieutenant's pane; the helper pane shows "Waiting for team
    lead approval"; `claude agents --json` shows the lieutenant `waiting` /
    `permission prompt`.
28. **`claude --name X --resume <id>` keeps the name `X` and the same
    sessionId.** `swarm open` on a project whose orchestrator had exited
    resumed it in place (pane idle detection via the terminal foreground
    process group works with zsh + powerlevel10k).
29. **iTerm Python API in the venv:** `hotkey-windows` returned session 0's
    windows; new tabs were appended at the end of the hotkey window and the
    user's own tabs kept their order; no iTerm window was opened.
30. **Stack and grid layouts held** with real teammate panes coming and going
    (1 helper, then 2 in parallel); labels came from `--agent-name`.
31. **The allow rule `Bash(swarm delegate:*)` does not match a compound
    command** (`echo ...; swarm delegate ...`).
32. **Quitting an orchestrator whose `swarm watch` Monitor is running** shows
    Claude Code's "stop tasks / move to background / stay" dialog.

`--own-window` was not exercised in the live check.

## Design

### Shape

```
hotkey iTerm window  =  tmux session "0"  (the home session; "swarm-<project>" in its own window with --own-window)
├─ my own tabs ...           untouched, wherever I put them
├─ tab "tmux-main"           [shell | orchestrator]   (claude --name tmux-main)
├─ tab "tmux:auth-refactor"  [shell | lieutenant / worker]   (grid on request)
├─ tab "tmux:flaky-tests"    lieutenant
├─ tab "swarm-main"          another project's orchestrator
└─ tab "swarm:docs"          ...
```

- **Names:** the orchestrator's session name is `<project>-main` (your
  decision). Lieutenant session names are `<project>-<lt>`, unique across
  projects so `SendMessage` reaches the right one. Tab names are
  `<project>-main` and `<project>:<lt>`. `main` isn't allowed as a
  lieutenant name. *(My call.)*
- **Project name:** the config `project` name if the project was opened
  by one, otherwise the basename of the git top level, or of the directory
  if it isn't a git repo. If the name is already used by a different
  directory, refuse and suggest adding a `project` line. *(My call.)*
- **Tags:** every swarm window carries tmux window options: `@swarm-project`,
  `@swarm-role` (`main` or `lieutenant`), `@swarm-name` (the lieutenant
  name), `@swarm-dir` (its working directory) and `@swarm-report` (see
  below). All lookups go through these tags and `@id`s, never tab numbers
  or names.

### `bin/swarm` (bash, same style as `tmux-bridge`)

Every subcommand prepends `/opt/homebrew/bin:/usr/local/bin` to `PATH`
(fact 17).

**`swarm open [--own-window] <name|group|path>...`**, or the shorthand
**`swarm <name|group>...`**: opens one or more projects, or goes back to
them. For example, `swarm assup code tmux-agent` opens three projects, and
`swarm work` opens my "work" group. *(Your decision: a project list and
named groups, configurable.)*
- **Resolving each argument**, in order: a group name from the config
  (expanded to its members, in the order listed); a project name from the
  config's `project` lines (`tmux-agent` → `~/workspace/tmux`); a directory
  `<root>/<name>` under each configured root (default `~/workspace`); a path
  (`.`, `~/x`, `/abs`). An argument that resolves to nothing is an error
  naming what was tried, and nothing is opened. Groups may list projects,
  paths, or other groups; cycles are an error. *(My calls.)*
- **The shorthand:** any first argument that isn't a subcommand name means
  `open`. To open a project whose name collides with a subcommand, use
  `swarm open <name>`. `swarm` with no arguments prints usage.
- Projects open in the order given, each as a main tab appended at the end.
  A project that's already open isn't duplicated; its tab is reused or
  resumed (below). After everything is open, the first project's main tab
  is selected.
- The project name is the `project` line's name when there is one,
  otherwise the directory's basename, so `tmux-agent` stays `tmux-agent`.
- **The target is the home session**, the tmux session shown in my hotkey
  window. Find it in this order:
  1. `set session` in the config, if it isn't `auto`.
  2. The session of the iTerm window with `isHotkeyWindow`, through the API
     (fact 23).
  3. The only session that has a control-mode client.

  If none of these gives exactly one attached session, **fail with a clear
  message** ("attach tmux in your hotkey window first") rather than opening a
  window. *(The order and the fail-don't-open rule are my calls.)*
- With `--own-window` (only when I ask), the target is `swarm-<project>`,
  created if it's missing, and it gets its own iTerm window (below).
- If the project already has a main tab in that session, select it. If its
  orchestrator is no longer running (no live `<project>-main` in
  `claude agents --json`), start it again in that tab with
  `--resume <last session id>`, so it keeps what it knew about running
  lieutenants. Fall back to a fresh start if the resume fails. The session
  id is kept in the window option `@swarm-session-id`. *(My call.)*
- Run (without `--own-window`) from a tab that has one pane and isn't a
  swarm tab, the first project not yet open takes that tab: it's renamed
  `<project>-main`, my pane becomes the shell pane, and the other panes are
  added to it. Swarm can't move my shell, so as it exits it types
  ` cd -- <dir> && clear` into that pane for the shell to run. Commands
  swarm types into agent panes also start with ` clear;`, so every pane
  shows only its shell or agent, not the setup. That tab's session is home for the run, so other projects go
  there too. Any other tab is left alone. *(Your request, after v0.2.0.)*
- Otherwise append a window named `<project>-main` at the end of the session,
  tag it, and give it **the same layout as a lieutenant tab** (your
  decision): a plain login shell in the project directory on the left half
  (pane index 0, labeled `shell`), and the orchestrator on the right (index 1,
  labeled `<project>-main`). Agent teams are off in the main tab, so no
  helper panes appear under the orchestrator. Below the orchestrator (index 2,
  labeled `claude`) a plain `claude` runs for me, outside the swarm; it is
  started when the tab is created and never relaunched. Start the
  orchestrator in the right pane:
  `claude --name <project>-main --settings '{"crossSessionInbound":"accept", <telegram override>}'`,
  with `CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS` explicitly unset (anti-goal),
  and `SWARM_PROJECT`/`SWARM_ROLE=main` exported in the tab's environment.
- The orchestrator pane runs a shell, and Claude is typed into it. When
  the orchestrator exits, the pane stays open at a prompt instead of
  disappearing. *(My call.)*
- **Telegram (your decision: one orchestrator owns it).** The owner is the
  project named by `set telegram_project` in the config. If that isn't
  set, the first orchestrator started while no live swarm orchestrator owns
  Telegram becomes the owner. The owner's window is tagged
  `@swarm-telegram=1`. Every other orchestrator, and every lieutenant, starts
  with the Telegram plugin turned off through `enabledPlugins` in
  `--settings`. *(Fallback rule and tag are my calls.)* A Claude session you
  run outside the swarm with Telegram on would still compete; that's outside
  this design.
- **Only with `--own-window`:** if `swarm-<project>` has no attached client,
  open an iTerm window and attach it with `-CC` (fact 18). Use `it2`, or
  osascript (`create window with default profile command …`), whichever the
  builder finds reliable for getting the new window's session id. Neither has
  been tested beyond fact 18. No other code path opens an iTerm window.
- Works from any terminal, inside or outside tmux.
- An untrusted project folder shows the trust prompt in the main tab, where
  I answer it myself. Lieutenants then inherit trust (fact 10).

**`swarm delegate <name> [--model M] [--layout stack|grid] [--brief-file F | -]`**:
run only from a main tab. It refuses unless the caller's window has
`@swarm-role=main`, because lieutenants need a named parent to report to.
The brief comes from a file or stdin, not argv, so long briefs need no
quoting. *(My call.)*
- **Workspace (your decision):** the lieutenant starts in the project
  directory, the orchestrator's working directory. Swarm never creates
  worktrees or branches. Whether to use a worktree is up to superpowers
  (SDD's own worktree step), or up to me: I say so to the orchestrator, and
  it goes in the brief. Trust is covered either way (fact 10).
- **Tab:** insert a window right after the project's last tab
  (`new-window -a -t <last @id>`). Name it `<project>:<name>` and tag it
  `@swarm-role=lieutenant`. Then run `swarm _place-tab` (below) so iTerm
  shows it next to its project's tabs right away.
- **Launch:**
  ```
  CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1 claude --name <project>-<name> \
    --teammate-mode tmux --model ${M:-opus} \
    --settings '{"crossSessionInbound":"accept", <plugin overrides>}' \
    --append-system-prompt-file <generated lieutenant prompt> \
    "<brief>"
  ```
  The lieutenant is SDD's controller, the role that needs judgment, so it
  defaults to Opus. Configurable. SDD picks the helpers' models (fact 14).
- **Plugins:** disable the Telegram plugin for the lieutenant (fact 21), via
  `enabledPlugins` in `--settings`. *Builder must verify* that teammates
  inherit this: their
  args (fact 13) don't include `--settings`. If they don't, find another
  way, or document the limitation.
- **Panes:** the window starts with a plain login shell in the project
  directory (pane index 0, labeled `shell`). The lieutenant pane is split
  to its right (index 1, labeled `<name>`). The shell is mine; agents never
  type into it. *(My call.)* `@swarm-layout` is set to `stack`, or to `grid`
  with `--layout grid`.

**`swarm status [--json] [--all]`**: grouped by project (default: the
current project when run from a swarm tab, otherwise all), then tab, then
pane. For each pane: label, role, state (`busy`, `waiting <what>`, `idle`,
`exited`; lieutenant state from `claude agents --json` matched by name,
helper state read from the screen), time in that state, report status, and
the last 3 screen lines. The tab shows the lieutenant's current directory
and git branch (from `claude agents --json`'s `cwd`).
`--json` has the same data. Time in state comes from a small state file
under `~/.agent-tmux/swarm/` that `status` and `watch` update. *(My call.)*

**`swarm peek <name|%pane> [-n lines]`**: prints a pane's screen. `name`
resolves to the lieutenant's pane in its tab, or to a helper pane by `@name`.

**`swarm report <done|blocked> "<one line>"`**: run by a lieutenant. Sets
its window's `@swarm-report` to `done: …` or `blocked: …`. This is how
`watch` tells "idle and finished" from "idle and stuck" without reading
transcripts. *(My call.)* The lieutenant also messages its parent.

**`swarm close <name>`**: kills the lieutenant's tab: its session and any
helpers still in it. It touches no files, branches or worktrees. Only I, or
the orchestrator when I ask, run this. It isn't on the allow list, so it
always asks (see Install).

**`swarm watch [--project P]`**: long-running, meant for the orchestrator's
Monitor tool. Every 15 s it checks its project's lieutenants and prints one
line per *new* condition, and nothing otherwise:
- `stalled <lt> <minutes>`: `busy` for ≥ 20 min with no new commit in the
  repo at its `cwd` (any branch, so worktrees count too) and no change in
  its pane's screen.
- `idle-unreported <lt>`: `idle` for ≥ 2 min with no `@swarm-report` set.
  This catches fact 20.
- `over-cap <lt> <n>`: more helpers than the tab's layout allows (1 for
  `stack`, 3 for `grid`).

A condition fires once, and again only after it clears and comes back.
`waiting` (a prompt) never fires: prompts are mine. All thresholds are
settings. *(Thresholds are my call.)*

**`swarm layout <stack|grid>`**: run by a lieutenant, from its own pane, to
change its tab's layout before running parallel helpers (`grid`), or to go
back (`stack`). It sets `@swarm-layout` and re-tiles. `swarm delegate
--layout grid` does the same up front. *(The command and names are my
calls.)*

**`swarm _retile-session <session name>`** (internal, called from hooks):
see below.

**`swarm _place-tab <@window>`** (internal; run after `delegate` creates a
tab): moves just that one iTerm tab so it sits right after the last tab of
its project in the window that shows it (fact 22). Every other tab keeps
its current iTerm position, including all of mine. It doesn't sort the
whole window to tmux order, because my own tabs may be arranged differently
from tmux order. It's a small Python script, `bin/swarm-place-tab.py`, run
with the venv's Python. It maps tabs to tmux windows through
`tmux_window_id` and calls `async_set_tabs` once with the current order plus
that one move. If the venv or the API isn't available, or the call fails,
it prints a warning and exits 0: the tab stays at the end, which is still
usable. It never uses `move-window` or `swap-window` (fact 19). A new
project's main tab is appended at the end and isn't moved.

**Config:** `~/.agent-tmux/swarm.conf`. It's line-based, not sourced bash:
the system bash is 3.2, which has no associative arrays, and a plain format
is easier to hand-edit. Blank lines and `#` comments are ignored, and `~` is
expanded. *(Format is my call.)*

```
# where bare project names are looked up, in order (default: ~/workspace)
root ~/workspace
root ~/workspace/sandbox

# names that don't match a directory
project tmux-agent ~/workspace/tmux

# groups: swarm work, swarm ot
group work assup code tmux-agent
group ot   opentherapy ira

# settings (defaults shown)
set session          auto     # home session; auto = detect (see open)
set lt_model         opus
set stall_min        20
set idle_min         2
set poll_sec         15
set retile_delay     0.6
set telegram_project          # unset: first orchestrator owns Telegram
set telegram_plugin  telegram@claude-plugins-official
```

A group or project name that's also a subcommand name is accepted, but it
only works through `swarm open`. `swarm config` prints the parsed config
(roots, projects, groups, settings) and any errors. *(My call.)*
`install.sh` writes a commented starter file if none exists, and never
overwrites one.

### Layout and labels: tmux hooks

In `config/tmux.conf`, already sourced by `~/.tmux.conf`:

- Global hooks `after-split-window` and `after-kill-pane` run
  `run-shell -b "~/.local/bin/swarm _retile-session #{q:session_name}"`
  (fact 25). Use a
  fixed array index, e.g. `after-split-window[90]`, so re-sourcing doesn't
  add duplicates and doesn't clobber my own hooks. They have to be global or
  session-level (fact 16).
- `_retile` checks every window in that session tagged
  `@swarm-role=main` or `lieutenant` and is a no-op for anything else (anti-goal: my
  own tabs and panes in session `0` are never re-laid out). It waits `retile_delay` (fact 12),
  then lays out by `@swarm-layout`:
  - `stack` (default, fact 24): `main-pane-width 50%`, then
    `select-layout main-vertical`. The shell takes the left half, the
    lieutenant is top-right and helpers are stacked under it.
  - `grid`: the shell keeps a left column (*my call:* a third of the
    width), and the lieutenant plus up to 3 helpers form a 2×2 on the
    right. That needs a computed layout string rather than a built-in
    layout. With fewer helpers, the right side fills as evenly as it can.

  Then it sets each helper pane's `@name` from `--agent-name` in its
  process args (fact 13). The grid layout hasn't been tested with Claude
  Code yet, but fact 12 showed a delayed custom layout holds.
- `after-kill-pane` passes no usable window (fact 16), which is why it
  re-tiles the whole session.

### Lieutenant prompt (appended system prompt)

It says:
- You are lieutenant `<name>` for project `<project>`. Your parent is
  `<project>-main`. Message it with `SendMessage`.
- You start in `<project dir>`. Use a worktree if the brief asks for one
  or superpowers calls for one; otherwise work where you are.
- For plan execution, use superpowers:subagent-driven-development. Follow
  its model selection and always set the model explicitly.
- By default, keep one helper alive at a time, which is how SDD works. If
  the work really needs parallel helpers, first run `swarm layout grid`;
  then you may keep up to 3. Run `swarm layout stack` when you're back to
  one. Shut each helper down when it's done. Never type into the `shell`
  pane; it's mine.
  If a helper's pane has closed, treat it as shut down; don't wait for a
  confirmation (fact 20).
- Keep a running account in your own pane: which task you're on, what you
  gave to which helper, and what came back. It's the record I read after
  helper panes close.
- When finished, write a final summary in your pane (what was done, branch,
  commits, anything left open), run `swarm report done "<one line>"`, and
  message your parent.
- When blocked on a decision you can't make, run `swarm report blocked
  "<question>"` and message your parent.
- Never push, merge, open PRs or delete branches without asking your parent.

### Orchestrator skill: `skills/swarm/SKILL.md`

It teaches the orchestrator:
- **When to delegate:** big, separable work, like executing a written plan or
  a self-contained feature or investigation. Keep small and conversational
  work. Delegate in parallel only when the work doesn't overlap. Two
  lieutenants in the same checkout share files, so when parallel work could
  collide, say in the briefs that each should use a worktree. If I ask for
  a worktree, put that in the brief.
- **Writing the brief:** goal, context and pointers (spec and plan paths),
  constraints, definition of done, and "use SDD for the plan". Send it
  through `swarm delegate <name> -` on stdin. Use `--layout grid` only when
  the work is meant to run parallel helpers from the start, or when I ask
  for it.
- **Checking in:** after the first delegation, start `swarm watch` through the
  Monitor tool. Never poll with sleep loops.
- **Nudging:** on `stalled` or `idle-unreported`, `swarm peek` the
  lieutenant, then send a short `SendMessage` (ask for status, point out a
  closed helper, redirect). On `over-cap`, tell it to shut helpers down. At
  most 2 nudges per condition; after that, leave it. `swarm status` shows
  the state when I look. Don't report any of this to me unless I ask.
- **Never** answer prompts in other panes, type into a lieutenant's pane
  with `tmux-bridge` keys, or close tabs unless I ask.
- **On a lieutenant's completion or blocked message:** one short line in its
  own conversation (who finished or what's blocked, and where to look).
  It's not a report I have to act on. *(My call: it reads the message in
  tab 1 anyway.)* For a blocked question, ask me.
- **When I ask "what's going on":** answer from `swarm status` and
  `swarm peek`.

### Lifecycle

- Lieutenants outlive the orchestrator. A restarted `<project>-main` gets
  their messages again because the name is the same. A message sent while
  the orchestrator is down is probably lost. The tab and `@swarm-report`
  still show the result.
- If the orchestrator exits, its pane stays at a shell prompt. Re-running
  `swarm open` on that project resumes it (see above).
- If the iTerm window closes, the tmux session survives. Reattaching it in
  my hotkey window brings everything back. `swarm open` never opens a
  window for the home session. For an `--own-window` project, `swarm open`
  reattaches its window.

### Install and tests

- `install.sh`: link `bin/swarm` into `~/.local/bin` (the tmux hooks call it
  by that path); create `~/.agent-tmux/venv` with the `iterm2` package for
  `_place-tab` (skip with a warning if `python3` is missing); and re-source
  the tmux config, which now includes the hooks. In
  `~/.claude/settings.json`, allow each subcommand separately:
  `Bash(swarm open:*)`, `delegate`, `status`, `peek`, `report`, `watch`,
  `layout`, `config`. The bare shorthand (`swarm work`) is something I type in
  my shell, so it needs no rule.
  Leave out `close`, so killing a running lieutenant always asks you.
  *(My call.)* Same idempotent,
  backup-first style as today.
- README: a swarm section.
- `tests/swarm.test.sh`, in the style of `codex-review.test.sh`, on a
  private tmux server (`tmux -L swarm-test-$$`), with fake `claude` and `it2`
  on `PATH`. The fake `claude` records its args, prints canned
  `agents --json`, and can sit in a pane with `--agent-name` args. Cover:
  `open` creates and tags a main tab per project (shell pane, then
  orchestrator pane, laid out 50/50), in the given order,
  without duplicating open ones; argument resolution (group, `project`
  line, root, path; nested groups; cycle and not-found errors that open
  nothing); config parsing, including comments, `~` and bad lines;
  the bare shorthand vs. subcommand names;
  `delegate` refuses outside a main tab, starts in the project directory,
  inserts after the project's last tab, and passes the right launch args;
  `delegate` creates the shell pane and lieutenant pane in that order;
  `_retile` gives the right `stack` and `grid` layouts for 2–5 panes, sets
  labels, and ignores
  untagged windows; `status` text and `--json`; each `watch` event fires
  once; `report`; `close` kills only its own tab; Telegram ownership goes to exactly
  one orchestrator; home-session detection (config, then hotkey window, then
  the only control-mode client, else fail without opening a window);
  `_place-tab` computes the right order from a fake tab list, moving only
  the new tab, and exits 0 when the API is missing. The `async_set_tabs` call itself
  is checked by hand. `tests/codex-review.test.sh` must still pass.

## Left to the builder

- How to find the new iTerm window's session id: `it2` or osascript
  (fact 18). Answered: iTerm API `Window.async_create` (unverified live;
  `--own-window` was not tested).
- Whether teammates inherit plugin overrides (fact 21), and the fallback if
  they don't. Answered: they inherit `--settings` (fact 26).
- Helper state detection from screen text (what a permission prompt looks
  like in a teammate pane). Answered: the prompt goes to the lieutenant's
  pane (fact 27); the status heuristic matches the helper's "Waiting for team
  lead approval" banner.
- The state-file format and the exact `status` text layout.
- The re-tile delay, if 0.6 s turns out flaky under load. Re-check with
  iTerm attached, since control-mode clients resize windows. Answered: not
  needed (fact 30).
- Whether `--resume` keeps `--name`, or has to be passed again. Answered: it
  keeps it (fact 28).
