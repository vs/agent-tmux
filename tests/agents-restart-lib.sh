# Test harness for agents-restart. Source it, then call t_setup.
# Builds on swarm-lib.sh: private tmux server, panes running /bin/sh.

source "$(dirname "${BASH_SOURCE[0]}")/swarm-lib.sh"

_ar_t_base_setup=$(declare -f t_setup)
eval "_swarm_t_setup${_ar_t_base_setup#t_setup }"

t_setup() {
  _swarm_t_setup
  export AGENTS_RESTART_SOCKETS="$SWARM_TMUX_SOCKET"
  export FAKE_AGENT_LOG="$WORK/agent.log"
  export FAKE_AGENT_WORK="$WORK"
  mkdir -p "$WORK/installs" "$WORK/screen" "$WORK/agents"
  : > "$FAKE_AGENT_LOG"
  # Replace swarm's fake claude: installs are explicit via t_install_fake.
  rm -f "$WORK/bin/claude"
}

# The fake agent, one script for claude/codex/gemini. It learns its tool and
# version from its install path: <root>/installs/<tool>/<version>/<tool>.
t_fake_agent_script() {
  cat <<'FAKE'
#!/usr/bin/env bash
self="${BASH_SOURCE[0]}"
while [[ -L "$self" ]]; do
  d=$(cd "$(dirname "$self")" && pwd); self=$(readlink "$self")
  [[ "$self" == /* ]] || self="$d/$self"
done
dir=$(cd "$(dirname "$self")" && pwd)
tool=$(basename "$self")
version=$(basename "$dir")
work=${FAKE_AGENT_WORK:-$(cd "$dir/../../.." && pwd)}

if [[ "${1:-}" == "--version" ]]; then
  echo "$version (fake)"
  exit 0
fi

if [[ "$tool" == claude && "${1:-}" == agents && "${2:-}" == "--json" ]]; then
  [[ "${FAKE_AGENTS_FAIL:-0}" == 1 ]] && exit 1
  out='[]'
  for f in "$work"/agents/*; do
    [[ -e "$f" && "$f" != *.json ]] || continue
    pid=$(basename "$f")
    kill -0 "$pid" 2>/dev/null || continue
    entry=$(cat "$f")
    [[ -f "$f.json" ]] && entry=$(jq -c --argjson o "$(cat "$f.json")" '. + $o' <<<"$entry")
    out=$(jq -c --argjson e "$entry" '. + [$e]' <<<"$out")
  done
  if [[ -n "${FAKE_AGENTS_JSON:-}" && -s "$FAKE_AGENTS_JSON" ]] &&
     jq -e 'type == "array" and length > 0' "$FAKE_AGENTS_JSON" >/dev/null 2>&1; then
    out=$(jq -c --slurpfile x "$FAKE_AGENTS_JSON" '. + $x[0]' <<<"$out")
  fi
  echo "$out"
  exit 0
fi

args=""
for a in "$@"; do args="${args}${a}"$'\x1f'; done
printf '%s\t%s\n' "${args%$'\x1f'}" "$version" >> "${FAKE_AGENT_LOG:-/dev/null}"

sid=""
prev=""
for a in "$@"; do
  [[ "$prev" == --resume ]] && sid="$a"
  prev="$a"
done
pid=$$
if [[ "$tool" == claude ]]; then
  jq -nc --argjson pid "$pid" --arg cwd "$PWD" --arg sid "${sid:-fake-$pid}" \
    '{pid: $pid, cwd: $cwd, status: "idle", sessionId: $sid}' > "$work/agents/.$pid.tmp"
  mv "$work/agents/.$pid.tmp" "$work/agents/$pid"
fi

screen="$work/screen/$pid"
draw() {
  if [[ -f "$screen" ]]; then cat "$screen"; else printf '❯ '; fi
}
draw
# Redraw whenever the test rewrites the screen file (bash 3.2 has no
# fractional read -t, so a background poller does it).
(
  sig=$(cksum < "$screen" 2>/dev/null || true)
  while kill -0 "$pid" 2>/dev/null; do
    cur=$(cksum < "$screen" 2>/dev/null || true)
    if [[ "$cur" != "$sig" ]]; then
      sig="$cur"
      printf '\033[2J\033[H'
      cat "$screen" 2>/dev/null
    fi
    sleep 0.2
  done
) &
poller=$!
trap '[[ "$tool" == claude ]] && rm -f "$work/agents/$pid" "$work/agents/$pid.json"; rm -f "$screen"; kill "$poller" 2>/dev/null' EXIT

# HANG: ignore quits from now on. SLOW: take 2 s to exit after a quit.
# An accepted quit is logged to $work/quits.log as "<pid> <TAB> <word>".
hang=0
slow=0
quitword=/quit
[[ "$tool" == claude ]] && quitword=/exit
while IFS= read -r line; do
  case "$line" in
    HANG) hang=1 ;;
    SLOW) slow=1 ;;
    "$quitword")
      if [[ $hang == 0 ]]; then
        printf '%s\t%s\n' "$pid" "$line" >> "$work/quits.log"
        [[ $slow == 0 ]] || sleep 2
        exit 0
      fi
      ;;
  esac
done
FAKE
}

# t_install_fake <tool> <version>
t_install_fake() {
  local d="$WORK/installs/$1/$2"
  mkdir -p "$d"
  t_fake_agent_script > "$d/$1"
  chmod +x "$d/$1"
}

# t_use_version <tool> <version>: make <tool> on PATH the given install.
t_use_version() {
  ln -sfn "$WORK/installs/$1/$2/$1" "$WORK/bin/$1"
}

# t_agent_set <pid> <json-object>: override fields in the fake's agents --json entry.
t_agent_set() {
  echo "$2" > "$WORK/agents/.$1.tmp" && mv "$WORK/agents/.$1.tmp" "$WORK/agents/$1.json"
}

# An empty, recognizable Claude input box (rule, prompt, rule, footer). The
# fake's default screen ("❯ ") reads as unrecognized.
T_RULE=$(printf '─%.0s' $(seq 1 40))
T_CLAUDE_IDLE=$(printf '%s\n❯ \n%s\n  ⏵⏵ auto mode on (shift+tab to cycle)\n' "$T_RULE" "$T_RULE")

# t_setscreen <pid> <text>: what the fake agent <pid> draws (redrawn within 0.2 s).
t_setscreen() { printf '%s' "$2" > "$WORK/screen/$1"; }
