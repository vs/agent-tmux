#!/usr/bin/env bash
# Tests for argument resolution (`swarm _resolve`).
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/swarm-lib.sh"
t_setup

mkdir -p "$HOME/workspace/"{assup,code,tmux,my.proj,"with space"} "$WORK/x/other"
cat > "$SWARM_CONFIG" <<CONF
root ~/workspace
project tmux-agent ~/workspace/tmux
group work assup code tmux-agent
group all work ot
group ot code
group loop1 loop2
group loop2 loop1
CONF
r() { swarm _resolve "$@"; }
names() { cut -f1 | tr '\n' ' ' | sed 's/ $//'; }
expect_eq "root lookup"   "assup	$HOME/workspace/assup"  "$(r assup)"
expect_eq "project line"  "tmux-agent	$HOME/workspace/tmux" "$(r tmux-agent)"
expect_eq "group order"   "assup code tmux-agent" "$(r work | names)"
expect_eq "nested + dedupe" "assup code tmux-agent" "$(r all | names)"
expect_eq "path arg"      "code	$HOME/workspace/code"   "$(cd "$HOME/workspace" && r ./code)"
expect_eq "dot sanitized" "my-proj	$HOME/workspace/my.proj" "$(r my.proj)"
expect_eq "space in path" "with-space	$HOME/workspace/with space" "$(r "$HOME/workspace/with space")"
expect_eq "tilde path"    "assup	$HOME/workspace/assup"  "$(r '~/workspace/assup/')"
expect_eq "dot arg"       "code	$HOME/workspace/code"   "$(cd "$HOME/workspace/code" && r .)"
expect "cycle"     1 "group cycle: loop1 -> loop2 -> loop1" swarm _resolve loop1
expect "not found prints nothing" 1 "cannot resolve 'nope' (tried: group, project, $HOME/workspace/nope, path)" swarm _resolve assup nope
expect_eq "not found: no stdout" "" "$(swarm _resolve assup nope 2>/dev/null)"
expect "bare name is not a path" 1 "cannot resolve 'other' (tried: group, project, $HOME/workspace/other, path)" bash -c "cd '$WORK/x' && SWARM_CONFIG=/nonexistent swarm _resolve other"
expect "name clash" 1 "name 'code' is used by both $HOME/workspace/code and $WORK/x/code; add a project line" bash -c "mkdir -p '$WORK/x/code'; swarm _resolve code '$WORK/x/code'"

printf 'root ~/workspace\nroot %s\n' "$WORK/x" > "$SWARM_CONFIG"
expect_eq "second root" "other	$WORK/x/other" "$(r other)"
expect "all roots listed" 1 "(tried: group, project, $HOME/workspace/nope, $WORK/x/nope, path)" swarm _resolve nope
t_done
