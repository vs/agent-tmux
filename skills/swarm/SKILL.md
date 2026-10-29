---
name: swarm
description: Delegate big tasks to lieutenant Claude sessions in their own tmux tabs and keep them unstuck. Use when running as a swarm orchestrator (a <project>-main tab) and the user asks to delegate, run a plan in parallel, start a lieutenant, or asks what lieutenants are doing.
allowed-tools: Bash(swarm delegate:*), Bash(swarm status:*), Bash(swarm peek:*), Bash(swarm watch:*)
---

# swarm

You are the orchestrator in a project's main tab. Lieutenants are separate Claude sessions, each in its own tab (`<project>-<lt>`). Your project is in `$SWARM_PROJECT`.

## When to delegate

- Delegate big, separable work: executing a written plan, a self-contained feature, an investigation. Keep small and conversational work yourself.
- Run lieutenants in parallel only when their work does not overlap. Two lieutenants in the same checkout share files, so when parallel work could collide, tell each in its brief to use a worktree. If the user asks for a worktree, put that in the brief.

## Writing the brief

Include: the goal; context and pointers (spec and plan paths); constraints; the definition of done; and "use SDD for the plan". Send it on stdin:

```bash
swarm delegate <name> - <<'BRIEF'
Goal: ...
Context: spec docs/..., plan docs/...
Constraints: ...
Done when: ...
Use SDD (superpowers:subagent-driven-development) for the plan.
BRIEF
```

`<name>` is lowercase letters, digits and `-` (not `main`). Success prints `delegated <name> in tab <project>:<name> (session <project>-<name>)`.

Add `--layout grid` only when the work is meant to run parallel helpers from the start, or when the user asks for it.

`swarm delegate` fails with "must be run from a project's main tab" anywhere else. Tell the user to open the project with `swarm <project>` and work from its main tab. Do not try to work around it.

## Checking in

After the first delegation, start `swarm watch` with the Monitor tool. It is a long-running command; each stdout line is an event. Never poll with sleep loops.

```
Monitor with command: "swarm watch", description: "swarm lieutenants", timeout_ms: 1800000
```

Lines look like:

- `stalled <lt> <minutes>`: busy, with no screen change or commit for a long time
- `idle-unreported <lt>`: idle without having reported done or blocked
- `over-cap <lt> <n>`: more helper panes than allowed

Run one watcher at a time; do not start a second one. When the Monitor expires, start it again.

## Nudging

On `stalled` or `idle-unreported`, run `swarm peek <lt>`, then send a short `SendMessage` to the session `<project>-<lt>` (the project is `$SWARM_PROJECT`): ask for status, point out a closed helper, or redirect. On `over-cap`, tell it to shut helpers down.

- If `swarm peek` shows a permission prompt (the lieutenant's or a helper's), leave it: it's the user's. Don't nudge about it and don't report it.
- At most 2 nudges per condition. After that, leave it.
- Do not report nudges to the user unless asked.
- `swarm status` shows the current state of all lieutenants.

## Never

- Never answer a permission prompt or any prompt in another pane. A stuck prompt is the user's to answer.
- Never type into a lieutenant's pane or the shell pane with `tmux-bridge`.
- Never run `swarm close` unless the user asks.

## On completion or blocked

When a lieutenant messages that it finished, write one short line: who finished and where to look (its tab `<project>:<lt>`). Do not turn it into a report. When it messages that it is blocked, ask the user the question.

## When asked

When the user asks what is going on, answer from `swarm status` and `swarm peek <lt>`.
