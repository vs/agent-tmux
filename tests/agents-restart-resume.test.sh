#!/usr/bin/env bash
# Tests for agents-restart resume command building.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/agents-restart-lib.sh"
t_setup
cd "$T_REPO"
source lib/agents-restart/common.sh
source lib/agents-restart/discover.sh
source lib/agents-restart/sessions.sh
source lib/agents-restart/resume.sh

NEW=11111111-2222-3333-4444-555555555555
AF="$WORK/argv"

# resume_words <type> <cwd-agent> <cwd-shell> <parent> <argv...> -> words[] (round-tripped through eval)
resume_words() {
  local type="$1" ac="$2" sc="$3" pp="$4"; shift 4
  printf '%s\0' "$@" > "$AF"
  CMD=$(ar_resume_cmd "$type" "$AF" "$NEW" "$ac" "$sc" "$pp")
  words=()
  # a `cd .. &&` prefix is not a word list; the cwd tests compare CMD directly
  [[ "$CMD" == "cd "* ]] || eval "words=($CMD)"
}
# check <name> <type> <argv-string-with-|-separators> <expected words...>
check() {
  local name="$1" type="$2" args="$3"; shift 3
  local IFS='|' a; a=($args); unset IFS
  resume_words "$type" /w /w - "${a[@]}"
  local got want
  got=$(printf '[%s]' "${words[@]}"); want=$(printf '[%s]' "$@")
  expect_eq "$name" "$want" "$got"
}

# --- claude ---
resume_words claude /w /w - claude --name x --settings '{"a": 1}' --resume old
expect_eq "claude keeps flags, replaces --resume" "[claude][--name][x][--settings][{\"a\": 1}][--resume][$NEW]" "$(printf '[%s]' "${words[@]}")"
expect_eq "claude settings survives quoting" "claude --name x --settings \\{\\\"a\\\":\\ 1\\} --resume $NEW" "$CMD"
check "claude drops initial prompt" claude 'claude|fix the tests' claude --resume "$NEW"
resume_words claude /w /w - claude --model opus --append-system-prompt "be brief"
expect_eq "claude keeps values" "[claude][--model][opus][--append-system-prompt][be brief][--resume][$NEW]" "$(printf '[%s]' "${words[@]}")"
check "claude upgrading path, -c" claude '/x/2.1.317.upgrading/claude|-c' claude --resume "$NEW"
check "claude --continue --fork-session --session-id" claude 'claude|--continue|--fork-session|--session-id|abc|--model|m' claude --model m --resume "$NEW"
check "claude --resume=old" claude 'claude|--resume=old|--name|n' claude --name n --resume "$NEW"
check "claude -r old prompt" claude 'claude|-r|old|-c' claude --resume "$NEW"
check "claude -- drops rest" claude 'claude|--model|m|--|--weird|x' claude --model m --resume "$NEW"
check "claude flag value starting with dash" claude 'claude|--append-system-prompt|-x|hello' claude --append-system-prompt -x --resume "$NEW"
check "claude --name=v kept" claude 'claude|--name=x y|hi' claude '--name=x y' --resume "$NEW"
check "claude variadic tools kept" claude 'claude|--allowedTools|Bash|Read|--model|m' claude --allowedTools Bash Read --model m --resume "$NEW"
check "claude optional --debug filter kept" claude 'claude|--debug|api|--model|m' claude --debug api --model m --resume "$NEW"
check "claude --debug alone then flag" claude 'claude|--debug|--model|m' claude --debug --model m --resume "$NEW"
check "claude drops --from-pr value" claude 'claude|--from-pr|12|--model|m' claude --model m --resume "$NEW"
check "claude drops --worktree" claude 'claude|-w|feat|--model|m' claude --model m --resume "$NEW"
check "claude bool flags kept" claude 'claude|--dangerously-skip-permissions|--verbose|do it' claude --dangerously-skip-permissions --verbose --resume "$NEW"
check "claude interpreted (node)" claude 'node|/x/claude.js|--name|n|p' claude --name n --resume "$NEW"
check "claude interpreted (bash)" claude 'bash|/x/claude|-c' claude --resume "$NEW"

check "claude drops --cloud with value" claude 'claude|--cloud|desc|--model|m' claude --model m --resume "$NEW"
check "claude drops --cloud without value" claude 'claude|--cloud|--model|m' claude --model m --resume "$NEW"
check "claude drops --cloud=x" claude 'claude|--cloud=x|--model|m' claude --model m --resume "$NEW"
check "claude drops --bg --background --desktop" claude 'claude|--bg|--background|--desktop|--model|m' claude --model m --resume "$NEW"

# --- codex ---
check "codex node script" codex 'node|/x/codex.js|-m|o3|do X' codex resume -m o3 "$NEW"
check "codex resume --last" codex 'codex|resume|--last' codex resume "$NEW"
check "codex resume <id> --all" codex 'codex|resume|aaaa|--all|-s|read-only' codex resume -s read-only "$NEW"
check "codex fork" codex 'codex|fork|--last' codex resume "$NEW"
check "codex global opts before subcommand" codex 'codex|-a|never|resume|zzz|-m|o3' codex resume -a never -m o3 "$NEW"
check "codex -c key=value" codex 'codex|-c|model="x y"|--search|hi' codex resume -c 'model="x y"' --search "$NEW"
check "codex -C kept with value" codex 'codex|-C|/a b|prompt' codex resume -C '/a b' "$NEW"
check "codex --cd=dir kept" codex 'codex|--cd=/q|prompt' codex resume --cd=/q "$NEW"
check "codex -- drops rest" codex 'codex|-m|o|--|x' codex resume -m o "$NEW"
check "codex trailing -i variadic: -- before id" codex 'codex|-i|a.png|b.png' codex resume -i a.png b.png -- "$NEW"
check "codex trailing -i with no values: -- before id" codex 'codex|-m|o|-i' codex resume -m o -i -- "$NEW"
check "codex drops --include-non-interactive" codex 'codex|resume|--include-non-interactive|x' codex resume "$NEW"

# --- gemini ---
check "gemini node, -r latest" gemini 'node|/x/gemini|-r|latest|-m|pro' gemini -m pro --resume "$NEW"
check "gemini drops prompts" gemini 'gemini|-p|hi|-i|there|--session-id|abc|-y|query' gemini -y --resume "$NEW"
check "gemini --resume=latest" gemini 'gemini|--resume=latest|--approval-mode|yolo' gemini --approval-mode yolo --resume "$NEW"
check "gemini variadic array" gemini 'gemini|--include-directories|a|b|-m|x' gemini --include-directories a b -m x --resume "$NEW"
check "gemini drops --session-file value" gemini 'gemini|--session-file|f.json|-m|x' gemini -m x --resume "$NEW"
check "gemini drops --session-file=x" gemini 'gemini|--session-file=f.json|-m|x' gemini -m x --resume "$NEW"
check "gemini -- drops rest" gemini 'gemini|-m|x|--|q' gemini -m x --resume "$NEW"

# --- env -u from a launcher script ---
mkdir -p "$WORK/run"
# A real parent whose argv is "bash <launcher>". It sleeps, then exits before
# reaching the (never executed) launcher lines.
mk_parent() {  # mk_parent <name> <launcher lines>
  local f="$WORK/run/par-$1.sh"
  printf '#!/usr/bin/env bash\nsleep 30\nexit 0\n%s\n' "$2" > "$f"
  bash "$f" >/dev/null 2>&1 &
  echo $!
}
p1=$(mk_parent x "env -u CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS claude --name x-main --settings \\{\\\"a\\\":\\ 1\\}")
p2=$(mk_parent plain "claude --name p")
p3=$(mk_parent two "env -u A -u B claude --name p")
p4=$(mk_parent other "env -u NOPE codex --name p
claude --name q")
p5=$(mk_parent fallback "env -u FIRST claude --name a
rc=\$?
env -u SECOND claude --name b")
sleep 0.3
resume_words claude /w /w "$p1" claude --name x-main --settings '{"a": 1}'
expect_eq "launcher env -u prefix" "[env][-u][CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS][claude][--name][x-main][--settings][{\"a\": 1}][--resume][$NEW]" "$(printf '[%s]' "${words[@]}")"
resume_words claude /w /w "$p2" claude --name p
expect_eq "launcher without env: no prefix" "[claude][--name][p][--resume][$NEW]" "$(printf '[%s]' "${words[@]}")"
resume_words claude /w /w "$p3" claude --name p
expect_eq "launcher multiple -u" "[env][-u][A][-u][B][claude][--name][p][--resume][$NEW]" "$(printf '[%s]' "${words[@]}")"
resume_words claude /w /w "$p4" claude --name q
expect_eq "launcher: other tool's env line ignored" "[claude][--name][q][--resume][$NEW]" "$(printf '[%s]' "${words[@]}")"
resume_words claude /w /w "$p5" claude --name a
expect_eq "launcher: first tool line wins" "[env][-u][FIRST][claude][--name][a][--resume][$NEW]" "$(printf '[%s]' "${words[@]}")"
resume_words claude /w /w 99999999 claude --name a
expect_eq "missing parent: no prefix" "[claude][--name][a][--resume][$NEW]" "$(printf '[%s]' "${words[@]}")"
resume_words claude /w /w - claude --name a
expect_eq "parent '-': no prefix" "[claude][--name][a][--resume][$NEW]" "$(printf '[%s]' "${words[@]}")"
kill $p1 $p2 $p3 $p4 $p5 2>/dev/null || true
pkill -f "$WORK/run/par-" 2>/dev/null || true

# --- cwd ---
resume_words claude "/a b" /c - claude --name x
expect_eq "cwd differs: cd prefix" "cd /a\\ b && claude --name x --resume $NEW" "$CMD"
resume_words claude /a /a - claude --name x
expect_eq "same cwd: no cd" "claude --name x --resume $NEW" "$CMD"
resume_words claude "/a b" /c - claude -c
expect_eq "cd and rest round-trip" "cd /a\\ b && claude --resume $NEW" "$CMD"
p6=$(mk_parent cd "env -u Z claude --name x")
sleep 0.2
resume_words claude "/a b" /c "$p6" claude --name x
expect_eq "cd then env" "cd /a\\ b && env -u Z claude --name x --resume $NEW" "$CMD"
kill $p6 2>/dev/null || true

# --- failures ---
expect "unreadable argv fails" 1 "" ar_resume_cmd claude "$WORK/nonexistent" "$NEW" /w /w -
: > "$AF"
expect "empty argv fails" 1 "" ar_resume_cmd claude "$AF" "$NEW" /w /w -
expect "unknown type fails" 1 "" ar_resume_cmd vim "$AF" "$NEW" /w /w -

t_done
