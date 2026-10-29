# Config parsing for swarm. Sourced by bin/swarm; bash 3.2 compatible.
#
# Grammar (one directive per line, '#' starts a comment):
#   root <dir>
#   project <name> <dir>
#   group <name> <member>...
#   set <key> [value]

SWARM_SETTING_KEYS="session lt_model stall_min idle_min poll_sec retile_delay telegram_project telegram_plugin"

CFG_ROOTS=""
CFG_PROJECTS=""
CFG_GROUPS=""
CFG_SETTINGS=""
CFG_ERRORS=""
CFG_INVALID=""   # name<TAB>error for project/group lines rejected for their name

cfg_default() {
  case "$1" in
    session) echo auto ;;
    lt_model) echo opus ;;
    stall_min) echo 20 ;;
    idle_min) echo 2 ;;
    poll_sec) echo 15 ;;
    retile_delay) echo 0.6 ;;
    telegram_project) echo "" ;;
    telegram_plugin) echo "telegram@claude-plugins-official" ;;
  esac
}

cfg_is_key() {
  local k
  for k in $SWARM_SETTING_KEYS; do [[ "$k" == "$1" ]] && return 0; done
  return 1
}

cfg_expand() {
  local p="$1"
  if [[ "$p" == "~" || "$p" == "~/"* ]]; then p="$HOME${p#\~}"; fi
  printf '%s' "$p"
}

cfg_trim() {
  local s="$1"
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf '%s' "$s"
}

cfg_err() { CFG_ERRORS="${CFG_ERRORS}${CFG_ERRORS:+
}line $1: $2"; }

# cfg_bad_name <line> <kind> <name> -> 0 (and records the error) when the
# name has characters tmux targets or session names can't take.
cfg_bad_name() {
  [[ "$3" =~ ^[A-Za-z0-9_-]+$ ]] && return 1
  local msg="line $1: invalid $2 name '$3' (use letters, digits, - and _)"
  CFG_ERRORS="${CFG_ERRORS}${CFG_ERRORS:+
}$msg"
  CFG_INVALID="${CFG_INVALID}${CFG_INVALID:+
}$3"$'\t'"$msg"
  return 0
}

# cfg_number_ok <key> <value> -> 0 unless <key> is a numeric setting and
# <value> isn't a number of its kind (integers; retile_delay a decimal).
cfg_number_ok() {
  case "$1" in
    stall_min | idle_min | poll_sec) [[ "$2" =~ ^[0-9]+$ ]] ;;
    retile_delay) [[ "$2" =~ ^([0-9]+(\.[0-9]*)?|\.[0-9]+)$ ]] ;;
    *) return 0 ;;
  esac
}

cfg_load() {
  CFG_ROOTS="" CFG_PROJECTS="" CFG_GROUPS="" CFG_SETTINGS="" CFG_ERRORS="" CFG_INVALID=""
  local file="${SWARM_CONFIG:-$HOME/.agent-tmux/swarm.conf}"
  [[ -f "$file" ]] || return 0
  local n=0 line dir rest name path members key val tab=$'\t'
  while IFS= read -r line || [[ -n "$line" ]]; do
    n=$((n + 1))
    line=$(cfg_trim "${line%%#*}")
    [[ -n "$line" ]] || continue
    dir="${line%%[[:space:]]*}"
    rest=""
    [[ "$line" == *[[:space:]]* ]] && rest=$(cfg_trim "${line#"$dir"}")
    case "$dir" in
      root)
        if [[ -z "$rest" ]]; then cfg_err "$n" "root needs a directory"; continue; fi
        CFG_ROOTS="${CFG_ROOTS}${CFG_ROOTS:+
}$(cfg_expand "$rest")"
        ;;
      project)
        name="${rest%%[[:space:]]*}"
        path=""
        [[ "$rest" == *[[:space:]]* ]] && path=$(cfg_trim "${rest#"$name"}")
        if [[ -z "$name" || -z "$path" ]]; then cfg_err "$n" "project needs a name and a directory"; continue; fi
        if cfg_bad_name "$n" project "$name"; then continue; fi
        CFG_PROJECTS="${CFG_PROJECTS}${CFG_PROJECTS:+
}${name}${tab}$(cfg_expand "$path")"
        ;;
      group)
        name="${rest%%[[:space:]]*}"
        members=""
        [[ "$rest" == *[[:space:]]* ]] && members=$(cfg_trim "${rest#"$name"}")
        if [[ -z "$name" || -z "$members" ]]; then cfg_err "$n" "group needs a name and members"; continue; fi
        if cfg_bad_name "$n" group "$name"; then continue; fi
        CFG_GROUPS="${CFG_GROUPS}${CFG_GROUPS:+
}${name}${tab}${members}"
        ;;
      set)
        key="${rest%%[[:space:]]*}"
        val=""
        [[ "$rest" == *[[:space:]]* ]] && val=$(cfg_trim "${rest#"$key"}")
        if [[ -z "$key" ]]; then cfg_err "$n" "set needs a key"; continue; fi
        if ! cfg_is_key "$key"; then cfg_err "$n" "unknown setting '$key'"; continue; fi
        if ! cfg_number_ok "$key" "$val"; then
          cfg_err "$n" "setting '$key' must be a number"
          val=$(cfg_default "$key")   # stored, so it overrides earlier lines
        fi
        CFG_SETTINGS="${CFG_SETTINGS}${CFG_SETTINGS:+
}${key}${tab}${val}"
        ;;
      *)
        cfg_err "$n" "unknown directive '$dir'"
        ;;
    esac
  done < "$file"
}

# cfg_get <key> -> the configured value (last one wins), else the default.
cfg_get() {
  local k v found=0 val="" tab=$'\t'
  while IFS="$tab" read -r k v; do
    if [[ "$k" == "$1" ]]; then val="$v"; found=1; fi
  done <<EOT
$CFG_SETTINGS
EOT
  if [[ $found == 1 ]]; then printf '%s\n' "$val"; else cfg_default "$1"; fi
}

cmd_config() {
  cfg_load
  local r name rest k tab=$'\t'
  if [[ -n "$CFG_ROOTS" ]]; then
    while IFS= read -r r; do echo "root $r"; done <<EOT
$CFG_ROOTS
EOT
  else
    echo "root $HOME/workspace"
  fi
  if [[ -n "$CFG_PROJECTS" ]]; then
    while IFS="$tab" read -r name rest; do echo "project $name $rest"; done <<EOT
$CFG_PROJECTS
EOT
  fi
  if [[ -n "$CFG_GROUPS" ]]; then
    while IFS="$tab" read -r name rest; do echo "group $name $rest"; done <<EOT
$CFG_GROUPS
EOT
  fi
  for k in $SWARM_SETTING_KEYS; do echo "set $k $(cfg_get "$k")"; done
  if [[ -n "$CFG_ERRORS" ]]; then
    echo "$CFG_ERRORS" >&2
    return 1
  fi
}

# --- Argument resolution -----------------------------------------------------

# State for one cfg_resolve run.
_RES_OUT=""
_RES_STACK=""

# _res_dir <path> -> absolute path without trailing slash; fails if not a dir.
_res_dir() {
  local p
  p=$(cfg_expand "$1")
  [[ -d "$p" ]] || return 1
  (cd "$p" 2>/dev/null && pwd)
}

# _res_lookup <table> <name> -> the second column of the first matching row.
_res_lookup() {
  local k v tab=$'\t'
  while IFS="$tab" read -r k v; do
    if [[ "$k" == "$2" ]]; then printf '%s' "$v"; return 0; fi
  done <<EOT
$1
EOT
  return 1
}

# _res_add <name> <dir>: append, dropping repeats of a dir, rejecting name clashes.
_res_add() {
  local name="$1" dir="$2" n d tab=$'\t'
  if [[ -n "$_RES_OUT" ]]; then
    while IFS="$tab" read -r n d; do
      if [[ "$d" == "$dir" ]]; then return 0; fi
      if [[ "$n" == "$name" ]]; then
        swarm_die "name '$name' is used by both $d and $dir; add a project line"
      fi
    done <<EOT
$_RES_OUT
EOT
  fi
  _RES_OUT="${_RES_OUT}${_RES_OUT:+
}${name}${tab}${dir}"
}

_res_one() {
  local arg="$1" members m g saved dir name root roots tried="" bad
  [[ -n "$arg" ]] || swarm_die "cannot resolve ''"
  # A project or group line rejected for its name is never used.
  if bad=$(_res_lookup "$CFG_INVALID" "$arg"); then
    swarm_die "${SWARM_CONFIG:-$HOME/.agent-tmux/swarm.conf}: $bad"
  fi
  if members=$(_res_lookup "$CFG_GROUPS" "$arg"); then
    case "
$_RES_STACK
" in
      *"
$arg
"*)
        g="${_RES_STACK//$'\n'/ -> }"
        swarm_die "group cycle: ${g} -> $arg"
        ;;
    esac
    saved="$_RES_STACK"
    _RES_STACK="${_RES_STACK}${_RES_STACK:+
}$arg"
    for m in $members; do _res_one "$m"; done
    _RES_STACK="$saved"
    return 0
  fi
  if dir=$(_res_lookup "$CFG_PROJECTS" "$arg"); then
    dir=$(_res_dir "$dir") || swarm_die "project '$arg': directory does not exist: $(_res_lookup "$CFG_PROJECTS" "$arg")"
    _res_add "$arg" "$dir"
    return 0
  fi
  roots="$CFG_ROOTS"
  [[ -n "$roots" ]] || roots="$HOME/workspace"
  # Explicit paths (., .., ./x, ../x, /x, ~/x) are never looked up under a root.
  case "$arg" in
    . | .. | ./* | ../* | /* | "~"*) roots="" ;;
  esac
  while IFS= read -r root; do
    [[ -n "$root" ]] || continue
    tried="${tried}, ${root%/}/$arg"
    if dir=$(_res_dir "${root%/}/$arg"); then
      _res_add "$(swarm_sanitize "$(basename "$dir")")" "$dir"
      return 0
    fi
  done <<EOT
$roots
EOT
  tried="${tried}, path"
  if [[ "$arg" == */* || "$arg" == "~"* || "$arg" == "." ]]; then
    if dir=$(_res_dir "$arg"); then
      name=$(swarm_sanitize "$(basename "$dir")")
      _res_add "$name" "$dir"
      return 0
    fi
  fi
  swarm_die "cannot resolve '$arg' (tried: group, project${tried})"
}

# cfg_resolve <arg>... -> `name<TAB>dir` lines; nothing on stdout on failure.
cfg_resolve() {
  cfg_load
  _RES_OUT="" _RES_STACK=""
  local a
  for a in "$@"; do _res_one "$a"; done
  [[ -z "$_RES_OUT" ]] || printf '%s\n' "$_RES_OUT"
}

cmd__resolve() {
  local out
  out=$(cfg_resolve "$@") || exit 1
  [[ -z "$out" ]] || printf '%s\n' "$out"
}
