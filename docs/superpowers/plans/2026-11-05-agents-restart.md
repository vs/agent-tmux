# agents-restart Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A `agents-restart` command that restarts every *upgraded* Claude Code, Codex and Gemini CLI agent in its own tmux pane, resuming the same conversation, waiting for busy agents and skipping ones that can't be restarted safely.

**Architecture:** A bash entrypoint `bin/agents-restart` sources focused modules in `lib/agents-restart/`: discovery (panes, processes, versions), state (per-agent busy/idle/skip, session IDs), resume-command building, the single-pane restart, and a small terminal UI. A stdlib-only Python helper reads a process's exact argv. Tests drive a private tmux server with fake agent binaries, in the style of `tests/swarm-*.test.sh`.

**Tech Stack:** bash 3.2, tmux 3.2+, jq, `ps`/`lsof` (macOS), `/usr/bin/env python3` (stdlib only) for argv.

**Spec:** `docs/superpowers/specs/2026-11-05-agents-restart-design.md`

## Global Constraints

- bash 3.2 compatible (no associative arrays, no `${var,,}`, no `mapfile`), `set -euo pipefail` in the entrypoint, like `bin/swarm`.
- Dependencies: `tmux`, `jq`, `ps`, `lsof`; `python3` only for exact argv (Task 1 fallback when missing).
- Only agents whose running version differs from the installed version are touched. Unknown running version counts as outdated and is shown as `version unknown`.
- Never interrupt a busy agent; "busy" includes background shells, subagents, monitors, `/loop`/wake-ups and live teammates. No timeout on waiting.
- Skip and report: permission prompt (`skipped: permission prompt`), unsent input (`skipped: unsent input`), teammate panes (`skipped: teammate`), the caller's own pane (`this pane, skipped`).
- Never force-kill, never close a pane, never type into a pane whose shell isn't in the foreground.
- **Never quit an agent unless its resume command is fully built** (session ID known, argv read). Missing either → `failed: <reason>`, agent left running.
- Quit keys: `/exit` Enter (Claude), `/quit` Enter (Codex, Gemini). Exit timeout 15 s, start-confirm timeout 20 s. No force kill on timeout.
- Scope: default tmux server plus `$SWARM_TMUX_SOCKET` if set; never scan `/tmp/tmux-<uid>/`.
- Flags: `-y`, `--dry-run`, `-h`/`--help`. Output: green ✓, yellow –, red ✗, dim pane address / session ID / duration; spinner + elapsed on in-progress lines; plain lines with no color/spinner/redraw when stdout isn't a TTY or `NO_COLOR` is set. Short session IDs are 8 chars. Summary: `agents-restart ✓ N restarted · N skipped · N failed   <elapsed>`. A failed restart prints its manual resume command under the summary.
- Every module function is prefixed `ar_`; internal helpers `_ar_`. Empty TSV fields are written as `-` (tab-IFS `read` collapses empty fields; see `lib/swarm/agents.sh`).

## Review Focus

- Claude's input box shows a dim placeholder (`❯ Try "refactor Navigation.tsx"`, SGR `\e[2m`) when empty. It must read as empty, not as unsent input; otherwise every idle Claude gets skipped. Test in Task 3.
- Ctrl+C while a restart is mid-flight (quit sent, resume not yet typed) must finish that pane's restart before exiting; waiting panes end as `– not restarted (interrupted)`. Test in Task 7.
- An agent whose session ID can't be determined must not be quit (`failed: no session id`). Test in Task 6.
- A positional initial prompt in the original argv (`claude "fix the tests"`, `codex "do X"`) must not be re-sent on resume. Test in Task 5.
- Arguments containing spaces or quotes (`--append-system-prompt "be brief"`, `--settings '{"a": 1}'`) must survive exactly into the resume command. Tests in Tasks 1 and 5.

---

### Task 1: Scaffold, exact argv helper, test harness

**Files:**
- Create: `bin/agents-restart`, `bin/agents-restart-argv`, `lib/agents-restart/common.sh`
- Create: `tests/agents-restart-lib.sh`, `tests/agents-restart-cli.test.sh`
- Modify: `install.sh:44-45` (add `link "$REPO/bin/agents-restart" "$HOME/.local/bin/agents-restart"`), `tests/install.test.sh` (assert the link)

**Interfaces:**
- Produces:
  - `bin/agents-restart` resolves symlinks to the repo root like `bin/swarm`, sources `lib/agents-restart/*.sh`, parses flags into `AR_YES=0|1`, `AR_DRY_RUN=0|1`, calls `ar_main` (defined in Task 7; until then a stub that exits 0). Unknown flag → usage on stderr, exit 2.
  - `ar_die <msg>` → `agents-restart: error: <msg>` on stderr, exit 1. `ar_warn <msg>`.
  - `ar_sockets` → one socket per line, `-` = default server. `AGENTS_RESTART_SOCKETS` (space-separated, `-` allowed) overrides; otherwise `-` plus `$SWARM_TMUX_SOCKET` if set.
  - `ar_tmux <sock> <args...>` → `tmux` or `tmux -L <sock>`.
  - `bin/agents-restart-argv <pid>` → the process's exact argv, NUL-separated, via `sysctl KERN_PROCARGS2` through `ctypes` (macOS). Exit 1 if the process is gone.
  - `ar_argv <pid> <outfile>` → writes NUL-separated argv to `<outfile>`; returns 0 exact, 2 approximate (python3 missing → whitespace split of `ps -o args=`), 1 gone.
  - Test harness `tests/agents-restart-lib.sh`: sources `tests/swarm-lib.sh` (reuse `t_setup`, `t_session`, `t_wait`, `expect`, `expect_eq`, `t_done`), exports `AGENTS_RESTART_SOCKETS="$SWARM_TMUX_SOCKET"`, and provides `t_install_fake <tool> <version>` which creates `$WORK/installs/<tool>/<version>/<tool>` (a copy of a fake agent script) and `t_use_version <tool> <version>` which points `$WORK/bin/<tool>` at it (symlink). The fake agent: `--version` prints `<version> (fake)`; `agents --json` (claude) cats `$FAKE_AGENTS_JSON`; otherwise appends its argv (`\x1f`-joined) plus version to `$FAKE_AGENT_LOG`, prints `❯ ` and loops reading stdin lines; on `/exit` or `/quit` it exits 0; a line `HANG` makes it ignore later quits. Its screen can be replaced by the test writing `$WORK/screen/<pid>` (the fake redraws when the file changes, polling every 0.2 s).

- [ ] **Step 1: Write the failing tests** in `tests/agents-restart-cli.test.sh`:
  - `expect "help" 0 "usage: agents-restart" agents-restart --help`
  - `expect "bad flag" 2 "usage: agents-restart" agents-restart --nope`
  - `expect_eq "sockets default" "-" "$(env -u SWARM_TMUX_SOCKET -u AGENTS_RESTART_SOCKETS bash -c 'source lib/agents-restart/common.sh; ar_sockets')"`
  - `expect_eq "sockets with swarm" $'-\nfoo' ...` with `SWARM_TMUX_SOCKET=foo`.
  - argv exactness: start `python3 -c 'import time; time.sleep(30)' "a b" '{"k": 1}' &`, then `ar_argv $! f` returns 0 and `tr '\0' '\n' < f | tail -2` equals the two lines `a b` and `{"k": 1}`.
  - gone process: `ar_argv 999999 f` returns 1.
- [ ] **Step 2: Run** `bash tests/agents-restart-cli.test.sh` → FAIL (command not found).
- [ ] **Step 3: Implement** the files above. `install.sh` link goes right after the `swarm` link.
- [ ] **Step 4: Run** `bash tests/agents-restart-cli.test.sh && bash tests/install.test.sh` → `all passed` for both.
- [ ] **Step 5: Commit** `feat(agents-restart): Add command skeleton, exact argv helper and test harness`

### Task 2: Discovery — panes, agent processes, versions

**Files:**
- Create: `lib/agents-restart/discover.sh`
- Test: `tests/agents-restart-discover.test.sh`

**Interfaces:**
- Consumes: `ar_sockets`, `ar_tmux`, `ar_argv`.
- Produces:
  - `ar_panes` → TSV `sock pane_id addr pane_pid shell_cwd` for every pane on every socket; `addr` is `#{session_name}:#{window_index}.#{pane_index}`.
  - `ar_ps_snapshot` → fills `$AR_PS_FILE` with `pid ppid args` (`ps -A -o pid=,ppid=,args=`); call once per discovery and once per poll cycle.
  - `ar_agent_in_pane <pane_pid>` → `pid<TAB>type` of the **topmost** descendant that is an agent, or nothing. An agent process is one whose argv0 basename is `claude|codex|gemini`, or whose argv0 basename is an interpreter (`node`, `bash`, `sh`, `python*`) and argv1 basename is `claude|codex|gemini` (optionally with `.js`/`.mjs`). Topmost wins, so Codex's npm wrapper is chosen over its native child and Claude's own subprocesses are ignored.
  - `ar_running_path <pid>` → realpath of the running program: argv1 for interpreted agents, else the first `txt` entry of `lsof -p <pid> -a -d txt -Fn`. May point at a deleted/renamed file (that's fine).
  - `ar_version_from_path <path>` → the last `[0-9]+\.[0-9]+\.[0-9]+` path component match (`.../2.1.317.upgrading/claude` → `2.1.317`), or empty.
  - `ar_running_version <pid>` → `ar_version_from_path`, else `<running_path> --version` parsed for semver if the file still exists, else empty.
  - `ar_installed_version <type>` → semver from `<type> --version` using the caller's `PATH`; cached per type for the run; empty if the command is missing.
  - `ar_discover <workdir>` → one record per agent pane on stdout, TSV:
    `sock pane addr folder type pid running_ver installed_ver agent_cwd shell_cwd argv_file parent_pid argv_exact`
    `folder` = basename of `agent_cwd`; `agent_cwd` from `lsof -p <pid> -a -d cwd -Fn`; `argv_file` = `<workdir>/<pane_id>.argv`; `argv_exact` = `1|0`; unknown version → `-`.
  - `ar_outdated <running_ver> <installed_ver>` → 0 when `running_ver` is `-` or differs from `installed_ver`.

- [ ] **Step 1: Write the failing tests** (private tmux server, fakes from Task 1): install claude `1.0.0` and `2.0.0`, start one pane running `$WORK/installs/claude/1.0.0/claude`, one running `claude` (→ 2.0.0 via `t_use_version claude 2.0.0`), one plain shell, one gemini `0.5.0` started through `bash $WORK/installs/gemini/0.5.0/gemini`. Assert:
  - `expect_eq "three agents found" 3 "$(ar_discover $WORK/d | wc -l | tr -d ' ')"`
  - the 1.0.0 record has `running_ver=1.0.0`, `installed_ver=2.0.0`, and `ar_outdated` → 0; the 2.0.0 record `ar_outdated` → 1.
  - `expect_eq "version from upgrading path" 2.1.317 "$(ar_version_from_path /x/claude-code@latest/2.1.317.upgrading/claude)"`
  - `expect_eq "no version in path" "" "$(ar_version_from_path /usr/local/bin/claude)"`
  - plain-shell pane yields no record; `folder` equals the pane's directory basename.
- [ ] **Step 2: Run** `bash tests/agents-restart-discover.test.sh` → FAIL.
- [ ] **Step 3: Implement** `lib/agents-restart/discover.sh`. Process-tree walk uses the snapshot file only (no `ps` per pane).
- [ ] **Step 4: Live check (read-only):** `bash -c 'source lib/agents-restart/common.sh; source lib/agents-restart/discover.sh; ar_discover $(mktemp -d)'` on the real machine lists the real Claude panes with versions; the two Homebrew-cask Claudes show their cask paths' versions. Record anything surprising in the task report.
- [ ] **Step 5: Run** the test → `all passed`. **Commit** `feat(agents-restart): Discover agent panes and their running versions`

### Task 3: Claude state and session ID

**Files:**
- Create: `lib/agents-restart/state.sh`
- Test: `tests/agents-restart-state.test.sh`

**Interfaces:**
- Consumes: Task 2 records, `ar_tmux`, `$AR_PS_FILE`.
- Produces:
  - `ar_claude_refresh` → sets `AR_CLAUDE_TSV` (`pid status waitingFor sessionId`, `-` for null) from `claude agents --json`; call once per poll cycle.
  - `ar_screen <sock> <pane>` → `capture-pane -e -p` output, trailing blank lines trimmed.
  - `ar_input_text <screen>` → the text after `❯ ` on the input line (the `❯` line between the two `────` rules nearest the bottom), with **dim (`\e[2m`…) runs removed** and escapes stripped, whitespace-trimmed.
  - `ar_claude_background <screen>` → a short description such as `1 shell` / `2 background tasks`, or empty. Matches the footer segment after `·` on the lines below the input box: `[0-9]+ (shell|shells|background task|background tasks|agent|agents|monitor|monitors|teammate|teammates)`. Live check in Step 4 confirms/extends the nouns.
  - `ar_is_teammate <argv_file>` → 0 when argv contains `--agent-id` or `--team-name`.
  - `ar_has_teammates <sock> <pane> <pid>` → 0 when another Claude in the same tmux window is a teammate (`ar_is_teammate`) — teammates of this lead live in its window.
  - `ar_session_id claude <pid>` → `sessionId` from `AR_CLAUDE_TSV`, or `-`.
  - `ar_state claude <sock> <pane> <pid> <argv_file>` → one of `teammate`, `prompt` (status `waiting` or `waitingFor` ≠ `-`), `busy` (status `busy`), `busy:<what>` (background work or `busy:teammates`), `unsent`, `idle` — checked in that order.

- [ ] **Step 1: Write the failing tests** using fixture screens (strings with real escape codes) and a fake `FAKE_AGENTS_JSON` keyed by fake pids:
  - placeholder: `printf '\e[39m❯ \e[2mTry\e[0m \e[2m"refactor"\e[0m'` between two `────` rules → `ar_input_text` = `""`, state `idle`.
  - real draft `❯ fix the tests` → `ar_input_text` = `fix the tests`, state `unsent`.
  - footer `  ⏵⏵ auto mode on · 1 shell` → `ar_claude_background` = `1 shell`, state `busy:1 shell`.
  - json `status: busy` → `busy`; `waitingFor: "approve"` → `prompt`; status `waiting` → `prompt`.
  - argv with `--agent-id helper-a@s --team-name t` → `teammate`; a lead in a window that also has such a pane → `busy:teammates`.
  - `ar_session_id claude <pid>` returns the json `sessionId`; unknown pid → `-`.
- [ ] **Step 2: Run** `bash tests/agents-restart-state.test.sh` → FAIL.
- [ ] **Step 3: Implement** the Claude part of `lib/agents-restart/state.sh`.
- [ ] **Step 4: Live check (read-only, in your own Claude pane):** start a background shell (`sleep 60 &` via a backgrounded tool command) and, if possible, a background subagent and a Monitor; capture the footer with `tmux capture-pane -p -t "$TMUX_PANE"`, and check `claude agents --json` status for each. Extend the noun list from what you see; note whether `status` already turns `busy` (then the footer check is a backstop). Seen on 2026-11-05: `⏵⏵ auto mode on · 1 shell` with `status: busy`.
- [ ] **Step 5: Run** the test → `all passed`. **Commit** `feat(agents-restart): Read Claude agent state, background work and session IDs`

### Task 4: Codex and Gemini state and session ID

**Files:**
- Modify: `lib/agents-restart/state.sh`
- Test: `tests/agents-restart-state.test.sh` (add cases)

**Interfaces:**
- Produces:
  - `ar_session_id codex <pid>` → the UUID from the rollout file the process has open: `lsof -p <pid> -Fn` entries matching `/sessions/.*/rollout-.*-([0-9a-f-]{36})\.jsonl$` (Codex home is `${CODEX_HOME:-$HOME/.codex}`); else `-`.
  - `ar_session_id gemini <pid> <agent_cwd>` → the resume argument value for Gemini (see Step 4), or `-`.
  - `ar_state codex|gemini <sock> <pane> <pid> <argv_file>` → `prompt` | `busy` | `unsent` | `idle` from the screen: busy while the footer shows `esc to interrupt` (either CLI); prompt on the approval patterns from `swarm_pane_state` in `lib/swarm/status.sh` plus each CLI's own approval prompt seen live; unsent when the input line has non-dim text.

- [ ] **Step 1: Write the failing tests** with fixture screens and a fake process holding a file open (`exec 3>$WORK/codex/sessions/2026/11/05/rollout-2026-11-05T10-00-00-019b8601-9767-7a90-86f1-d14b21a74e7e.jsonl; sleep 30`): `ar_session_id codex` → `019b8601-9767-7a90-86f1-d14b21a74e7e`; screen with `esc to interrupt` → `busy`; idle screen → `idle`.
- [ ] **Step 2: Run** → FAIL.
- [ ] **Step 3: Implement** the Codex part.
- [ ] **Step 4: Live check with real Codex and Gemini** in a scratch tmux window (`tmux new-window -d`), never in the user's panes: start each, send one short message, then record (a) the idle, busy and approval-prompt screens, (b) whether Codex keeps the rollout open (lsof) and whether `codex resume <uuid>` reopens it, (c) where Gemini 0.67 writes the live session (`~/.gemini/tmp/<hash>/chats/session-*.json`, the `sessionId` field), and whether `gemini --resume <sessionId>` works. Implement `ar_session_id gemini`: if `--resume` accepts the ID, return it; otherwise return the index from `gemini --list-sessions` (run in `agent_cwd`) whose entry matches that session file; if neither can be determined, return `latest` and set `AR_WARN_<pane>` so the plan line shows `resume: latest`. Close the scratch window afterwards.
- [ ] **Step 5: Implement** the Gemini part and fixture tests for what Step 4 found. **Run** → `all passed`. **Commit** `feat(agents-restart): Read Codex and Gemini state and session IDs`

### Task 5: Resume command

**Files:**
- Create: `lib/agents-restart/resume.sh`
- Test: `tests/agents-restart-resume.test.sh`

**Interfaces:**
- Consumes: record fields `type argv_file agent_cwd shell_cwd parent_pid`, a session ID.
- Produces: `ar_resume_cmd <type> <argv_file> <sid> <agent_cwd> <shell_cwd> <parent_pid>` → one shell command line, every word `printf %q`-quoted.
  - argv0 is replaced by the bare tool name (`claude`, `codex`, `gemini`), so the shell resolves the newly installed version; for interpreted agents argv0+argv1 become the tool name.
  - **claude:** drop `--resume/-r <v>`, `--resume=<v>`, `--continue/-c`, `--session-id <v>`, `--fork-session`, and positional args (an arg not starting with `-` that doesn't follow a value-taking flag; value-taking flags = those shown with `<value>` in `claude --help`, kept as a list in `resume.sh`); append `--resume <sid>`.
  - **codex:** result is `codex resume <kept options> <sid>`: drop subcommand words `resume`/`fork`, `--last`, `--all`, and positionals (value flags from `codex --help` / `codex resume --help`).
  - **gemini:** drop `--resume/-r <v>`, `--prompt/-p <v>`, `--prompt-interactive/-i <v>`, `--session-id <v>`, positionals; append `--resume <sid>`.
  - If the parent process is `bash|sh <script>` and the script's command line for this tool starts with `env -u VAR [-u VAR...]` (swarm launchers do), prefix those `env -u` words.
  - If `agent_cwd` ≠ `shell_cwd`, prefix `cd <agent_cwd> && `.

- [ ] **Step 1: Write the failing tests** (argv files written with `printf '%s\0' ...`):
  - `claude --name x --settings '{"a": 1}' --resume old` → `claude --name x --settings \{\"a\":\ 1\} --resume NEW` (assert by `eval`-ing the result into an array and comparing words, not the quoting).
  - `claude "fix the tests"` → `claude --resume NEW` (positional dropped).
  - `claude --model opus --append-system-prompt "be brief"` → keeps both values intact.
  - `/x/2.1.317.upgrading/claude -c` → `claude --resume NEW`.
  - `node /x/codex.js -m o3 "do X"` → `codex resume -m o3 NEW`; `codex resume --last` → `codex resume NEW`.
  - `node /x/gemini -r latest -m pro` → `gemini -m pro --resume NEW`.
  - a parent `bash $WORK/run/x.sh` whose script line is `env -u CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS claude --name x-main` → result starts `env -u CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS claude`.
  - differing cwd → starts `cd /a\ b && `.
- [ ] **Step 2: Run** `bash tests/agents-restart-resume.test.sh` → FAIL.
- [ ] **Step 3: Implement** `lib/agents-restart/resume.sh`.
- [ ] **Step 4: Run** → `all passed`. **Commit** `feat(agents-restart): Build resume commands that keep the original flags`

### Task 6: Restart one pane

**Files:**
- Create: `lib/agents-restart/restart.sh`
- Test: `tests/agents-restart-restart.test.sh`

**Interfaces:**
- Consumes: `ar_state`, `ar_session_id`, `ar_resume_cmd`, `ar_tmux`, `ar_ps_snapshot`, `ar_agent_in_pane`.
- Produces: `ar_restart_one <record> <sid>` → prints exactly one line: `ok<TAB><new_sid or ->` or `fail<TAB><reason><TAB><resume_cmd or ->`. Steps:
  1. Precheck: `sid` ≠ `-` else `fail no session id`; argv file readable else `fail can't read arguments`; build the resume command first; re-run `ar_state` → must be `idle` else `fail state changed` (caller treats it as "not ready", see Task 7).
  2. `send-keys -l /exit|/quit` then `send-keys Enter`.
  3. Wait up to `${AGENTS_RESTART_EXIT_TIMEOUT:-15}` s until the agent pid is gone **and** the pane's shell owns the foreground (`ps -o tpgid=` of `pane_pid` equals `pane_pid`, as in `swarm_pane_idle`). Agent still alive → `fail didn't exit within 15s` (nothing more sent). Agent gone but shell not in foreground → `fail shell not at prompt`, resume command included, nothing typed.
  4. `send-keys -l <resume_cmd>` then `Enter`.
  5. Wait up to `${AGENTS_RESTART_START_TIMEOUT:-20}` s for a new agent process in the pane (`ar_agent_in_pane`); for Claude also wait until that pid appears in `claude agents --json` and report its `sessionId` (it can differ from the old one — the spec's "session ID reappears" is checked as "the new process is listed", my call). Timeout → `fail didn't come back`, resume command included.

- [ ] **Step 1: Write the failing tests** with fake agents in a private tmux server (panes run `/bin/sh` as shell):
  - idle fake claude 1.0.0 → `ok`; `$FAKE_AGENT_LOG` gets a new line with version `2.0.0` and `--resume <sid>`.
  - `sid=-` → `fail no session id` and the fake is still running (pid alive), nothing typed (log unchanged).
  - fake sent `HANG` first → `fail didn't exit within 15s` with `AGENTS_RESTART_EXIT_TIMEOUT=2`; pid still alive.
  - pane where the agent was started as `sh -c 'claude; read x'` (foreground stays `sh` reading) → `fail shell not at prompt`; nothing typed after `/exit`.
- [ ] **Step 2: Run** `bash tests/agents-restart-restart.test.sh` → FAIL.
- [ ] **Step 3: Implement** `lib/agents-restart/restart.sh`.
- [ ] **Step 4: Run** → `all passed`. **Commit** `feat(agents-restart): Quit and resume one agent pane safely`

### Task 7: UI and main flow

**Files:**
- Create: `lib/agents-restart/ui.sh`, `lib/agents-restart/main.sh`
- Modify: `bin/agents-restart` (drop the `ar_main` stub)
- Test: `tests/agents-restart-main.test.sh`

**Interfaces:**
- Consumes: everything above.
- Produces:
  - `ar_ui_init` → sets `AR_FANCY=1` when `[[ -t 1 ]]` and `NO_COLOR` is unset, else 0; color vars empty when not fancy.
  - `ar_ui_header` → `agents-restart  claude X · codex Y · gemini Z` (only installed tools).
  - `ar_ui_plan_line <addr> <folder> <type> <old> <new> <state> <sid>` (old `-` renders `version unknown`, else `old → new`); `ar_ui_uptodate <n>` → dim `N agents up to date, left alone`.
  - Live region: `ar_ui_set <i> <mark> <text>` stores line i; `ar_ui_render` redraws the in-progress lines in place (cursor-up + `\e[2K`), spinner frames `⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏`, elapsed `2.1s` / `1m12s`; a finished line is printed once above the live region and never redrawn. Not fancy → print only finished lines.
  - `ar_main` flow, matching the spec's Flow and Output sections: discover → filter outdated → assign initial states (self pane via `$TMUX_PANE` + matching `#{socket_path}` against `$TMUX` → `this pane, skipped`) → header + plan lines + up-to-date count → nothing outdated: print `all agents up to date`, exit 0 → `--dry-run`: exit 0 → confirm `Restart N agents? [Y/n]` read from `/dev/tty` (no tty and no `-y` → `ar_die "not a terminal; pass -y"`) → loop every `${AGENTS_RESTART_POLL:-3}` s: refresh snapshot and Claude json, restart idle agents one at a time, skip those that turned `prompt`/`unsent`, keep `busy*` waiting with `waiting: <what>` (`waiting for turn to end` for plain busy) → summary + manual resume commands for failures.
  - Exit codes: 0 when nothing failed, 1 when any failed, 130 on Ctrl+C.
  - Ctrl+C: a `trap` sets a flag; the loop finishes any restart already past step 2 of `ar_restart_one`, marks remaining waiting agents `– not restarted (interrupted)`, prints the summary, exits 130.

- [ ] **Step 1: Write the failing tests** (`NO_COLOR=1`, `AGENTS_RESTART_POLL=1`, fakes):
  - two outdated idle claudes + one up-to-date → `agents-restart -y` exits 0, output has two `✓` lines, `1 agent up to date, left alone` (singular for 1), summary `✓ 2 restarted · 0 skipped · 0 failed`; the up-to-date fake's log has no new line.
  - an agent with unknown running version → its plan line says `version unknown` and it is restarted.
  - nothing outdated → `all agents up to date`, exit 0.
  - `--dry-run` → plan printed, fake logs unchanged.
  - busy fake (json `busy`): the test flips it to `idle` after 2 s; the run ends with a `✓` line for it and exit 0, and the fake's log shows no quit before the flip (log line timestamps).
  - prompt fake → `– … skipped: permission prompt`, exit 0.
  - a run with one forced failure (`HANG`, exit timeout 2) → exit 1 and the manual resume command printed under the summary.
  - `TMUX_PANE` set to an outdated agent's pane → `this pane, skipped`, its fake untouched.
  - Ctrl+C: start `agents-restart -y` in the background with one busy fake, send `SIGINT` after 1 s → exit 130, `not restarted (interrupted)`, fake untouched. Mid-flight case: with `AGENTS_RESTART_START_TIMEOUT=5` and a fake whose restart is slow, send SIGINT right after the log shows the quit → the resume line still appears in `$FAKE_AGENT_LOG`.
- [ ] **Step 2: Run** `bash tests/agents-restart-main.test.sh` → FAIL.
- [ ] **Step 3: Implement** `ui.sh` and `main.sh`.
- [ ] **Step 4: Run** all tests: `for t in tests/*.test.sh; do bash "$t" || exit 1; done` → every file `all passed`.
- [ ] **Step 5: Visual check:** run the main test scenario in a scratch tmux window with a real TTY (no `NO_COLOR`) and capture with `tmux capture-pane -e -p`; confirm colors, spinner redraw and frozen lines look like the spec's example. **Commit** `feat(agents-restart): Add the restart flow with a live terminal UI`

### Task 8: Docs and live dry run

**Files:**
- Modify: `README.md` (parts table row for `bin/agents-restart`; a short `## Restarting agents after an upgrade` section with the three flags and what gets skipped; the `install.sh` bullet list gains the new link)

- [ ] **Step 1: Write** the README changes.
- [ ] **Step 2: Live dry run:** `agents-restart --dry-run` on the real machine. Expected: every real agent either listed as outdated (with `old → new`) or counted as up to date; the caller's pane shows `this pane, skipped` if run from an agent. Paste the output into the task report. **Do not run without `--dry-run`**; the first real run is the user's call.
- [ ] **Step 3: Commit** `docs(agents-restart): Document restarting agents after an upgrade`
