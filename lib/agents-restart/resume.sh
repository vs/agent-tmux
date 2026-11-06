# Resume command building for agents-restart. Sourced after common.sh; bash 3.2 compatible.

# Flag tables. Derived from the installed CLIs' --help: claude 2.1.318,
# codex-cli 0.166.0 (`codex --help` and `codex resume --help` list the same
# options, plus --last/--all/--include-non-interactive on resume), gemini 0.67.0.
#
# _ar_flag_class <type> <flag> -> one of
#   val      takes exactly one value (the next arg, even when it starts with "-"); kept
#   var      variadic (<x...>, [array], codex -i <FILE>...): takes every following
#            arg that doesn't start with "-"; kept
#   opt      optional value ([value]): takes the next arg only if it doesn't
#            start with "-" (the parser's own rule, so the original run took it
#            too); kept
#   dropval  dropped with its one value (they identify or re-send a session/prompt)
#   dropopt  dropped with its optional value
#   drop     boolean flag, dropped
#   keep     anything else (booleans, unknown flags): kept alone
# Dropped on resume: --resume/-r, --continue/-c, --session-id, --fork-session,
# prompts (-p/-i for gemini), --from-pr and --teleport (they pick another
# conversation), and --worktree/-w and --tmux (the pane already runs inside the
# worktree; repeating it would create a second one where the session isn't).
# A flag given as --flag=value is one word: kept as is, or dropped whole.
_ar_flag_class() {
  case "$1:$2" in
    claude:--resume|claude:-r|claude:--from-pr|claude:--teleport|claude:-w|claude:--worktree) echo dropopt ;;
    claude:--session-id) echo dropval ;;
    claude:--continue|claude:-c|claude:--fork-session|claude:--tmux) echo drop ;;
    claude:--agent|claude:--agents|claude:--append-system-prompt|claude:--autocompact|claude:--debug-file|\
    claude:--effort|claude:--environment|claude:--fallback-model|claude:--input-format|claude:--json-schema|\
    claude:--max-budget-usd|claude:--model|claude:-n|claude:--name|claude:--output-format|claude:--permission-mode|\
    claude:--permission-prompts|claude:--plugin-dir|claude:--plugin-url|claude:--remote-control-session-name-prefix|\
    claude:--setting-sources|claude:--settings|claude:--system-prompt|claude:--system-prompt-snapshot) echo val ;;
    claude:--add-dir|claude:--allowedTools|claude:--allowed-tools|claude:--disallowedTools|claude:--disallowed-tools|\
    claude:--betas|claude:--file|claude:--mcp-config|claude:--tools) echo var ;;
    claude:-d|claude:--debug|claude:--prompt-suggestions|claude:--remote-control|claude:--cloud) echo opt ;;

    codex:--include-non-interactive|codex:--last|codex:--all|codex:--worktree) echo drop ;;
    codex:-c|codex:--config|codex:--enable|codex:--disable|codex:--remote|codex:--remote-auth-token-env|\
    codex:-m|codex:--model|codex:--local-provider|codex:-p|codex:--profile|codex:-s|codex:--sandbox|\
    codex:-C|codex:--cd|codex:--add-dir|codex:-a|codex:--ask-for-approval) echo val ;;
    codex:-i|codex:--image) echo var ;;

    gemini:--resume|gemini:-r|gemini:--prompt|gemini:-p|gemini:--prompt-interactive|gemini:-i|gemini:--session-id|gemini:--delete-session) echo dropval ;;
    gemini:-w|gemini:--worktree) echo dropopt ;;
    gemini:-m|gemini:--model|gemini:--approval-mode|gemini:-o|gemini:--output-format|gemini:--session-file) echo val ;;
    gemini:--policy|gemini:--admin-policy|gemini:--allowed-mcp-server-names|gemini:--allowed-tools|\
    gemini:-e|gemini:--extensions|gemini:--include-directories) echo var ;;
    *) echo keep ;;
  esac
}

# _ar_launcher_env <parent_pid> <tool> -> the `env -u VAR ...` words (one per
# line) from the first command line that runs <tool> in the script the parent
# process runs (`bash|sh <script>`, as swarm launchers are). Nothing when there
# is no such parent, script or env prefix. The script is only read, never run.
_ar_launcher_env() {
  local pp="$1" tool="$2" tmp a n=0 b script="" line w
  local words=() vars=()
  [[ "$pp" =~ ^[0-9]+$ ]] || return 0
  tmp=$(mktemp "${TMPDIR:-/tmp}/agents-restart-argv.XXXXXX")
  if ar_argv "$pp" "$tmp"; then
    while IFS= read -r -d '' a; do
      n=$((n + 1))
      if [[ $n == 1 ]]; then
        b="${a##*/}"; b="${b#-}"
        [[ "$b" == bash || "$b" == sh ]] || break
      elif [[ "$a" != -* ]]; then
        script="$a"; break
      fi
    done < "$tmp"
  fi
  rm -f "$tmp"
  [[ -n "$script" && -f "$script" ]] || return 0
  while IFS= read -r line || [[ -n "$line" ]]; do
    # shellcheck disable=SC2206
    words=($line)
    [[ ${#words[@]} -gt 0 ]] || continue
    set -- "${words[@]}"
    [[ "$1" != exec ]] || shift
    vars=()
    if [[ "${1:-}" == env ]]; then
      shift
      while [[ "${1:-}" == -u && -n "${2:-}" ]]; do vars+=("$2"); shift 2; done
    fi
    w="${1:-}"; w="${w##*/}"
    if [[ "$w" == "$tool" ]]; then
      if [[ ${#vars[@]} -gt 0 ]]; then
        echo env
        for w in "${vars[@]}"; do echo -u; echo "$w"; done
      fi
      return 0
    fi
  done < "$script"
}

# ar_resume_cmd <type> <argv_file> <sid> <agent_cwd> <shell_cwd> <parent_pid>
# -> one shell command line (every word printf %q-quoted) that resumes session
# <sid> with the original flags. Returns 1 when it can't be built.
#   claude: claude <kept flags> --resume <sid>
#   codex:  codex resume <kept flags> <sid>   (`-- <sid>` after a trailing variadic -i)
#   gemini: gemini <kept flags> --resume <sid>
# argv0 (plus argv1 for node/bash/sh/python running a script) becomes the bare
# tool name so the shell picks up the new install. Positional args (initial
# prompts, and codex's subcommand/session words) and everything after `--` are
# dropped. A launcher script's `env -u VAR` prefix is kept; `cd <agent_cwd> &&`
# is prepended when the agent ran outside the shell's directory.
ar_resume_cmd() {
  local type="$1" argf="$2" sid="$3" acwd="${4:--}" scwd="${5:--}" pp="${6:--}"
  local argv=() kept=() a b0 i n flag cls lastvar=0 out="" w
  case "$type" in claude|codex|gemini) ;; *) return 1 ;; esac
  [[ -f "$argf" && -n "$sid" ]] || return 1
  while IFS= read -r -d '' a; do argv+=("$a"); done < "$argf"
  n=${#argv[@]}
  [[ $n -gt 0 ]] || return 1
  i=1
  b0="${argv[0]##*/}"; b0="${b0#-}"
  case "$b0" in node|bash|sh|python*) [[ $n -gt 1 ]] && i=2 ;; esac

  while [[ $i -lt $n ]]; do
    a="${argv[$i]}"; i=$((i + 1))
    [[ "$a" != -- ]] || break
    if [[ "$a" != -* || "$a" == - ]]; then continue; fi   # positional: dropped
    flag="$a"
    case "$a" in --*=*) flag="${a%%=*}" ;; esac
    cls=$(_ar_flag_class "$type" "$flag")
    # attached short value of a dropped flag, e.g. -rabc
    case "$type:$a" in claude:-r?*|gemini:-r?*|gemini:-p?*) cls=drop ;; esac
    lastvar=0
    if [[ "$flag" != "$a" ]]; then
      case "$cls" in drop*) ;; *) kept+=("$a") ;; esac
      continue
    fi
    case "$cls" in
      keep) kept+=("$a") ;;
      drop) ;;
      val|dropval)
        [[ "$cls" == val ]] && kept+=("$a")
        if [[ $i -lt $n ]]; then
          [[ "$cls" == val ]] && kept+=("${argv[$i]}")
          i=$((i + 1))
        fi ;;
      opt|dropopt)
        [[ "$cls" == opt ]] && kept+=("$a")
        if [[ $i -lt $n && "${argv[$i]}" != -* && "${argv[$i]}" != "" ]]; then
          [[ "$cls" == opt ]] && kept+=("${argv[$i]}")
          i=$((i + 1))
        fi ;;
      var)
        kept+=("$a"); lastvar=1
        while [[ $i -lt $n && "${argv[$i]}" != -* ]]; do kept+=("${argv[$i]}"); i=$((i + 1)); done ;;
    esac
  done

  local cmd=()
  case "$type" in
    claude) cmd=(claude ${kept[@]+"${kept[@]}"} --resume "$sid") ;;
    gemini) cmd=(gemini ${kept[@]+"${kept[@]}"} --resume "$sid") ;;
    codex)
      cmd=(codex resume ${kept[@]+"${kept[@]}"})
      # a trailing variadic option would swallow the session ID
      [[ $lastvar == 1 && ${#kept[@]} -gt 0 && "${kept[${#kept[@]}-1]}" != -* ]] && cmd+=(--)
      cmd+=("$sid") ;;
  esac

  while IFS= read -r w; do
    [[ -n "$w" ]] && out="$out$(printf '%q' "$w") "
  done < <(_ar_launcher_env "$pp" "$type")
  for w in "${cmd[@]}"; do out="$out$(printf '%q' "$w") "; done
  out="${out% }"
  if [[ "$acwd" != - && "$scwd" != - && -n "$acwd" && -n "$scwd" && "$acwd" != "$scwd" ]]; then
    out="cd $(printf '%q' "$acwd") && $out"
  fi
  printf '%s\n' "$out"
}
