# Home-session detection. Sourced by bin/swarm; bash 3.2 compatible.

# swarm_home_session -> echoes the tmux session shown in the hotkey window.
# Order: config `session`, the hotkey window's session, the single
# control-mode client's session. Never creates anything.
swarm_home_session() {
  cfg_load
  local want id s ids cfgpath
  want=$(cfg_get session)
  if [[ "$want" != auto ]]; then
    tmx has-session -t "=$want" 2>/dev/null \
      || swarm_die "configured session '$want' does not exist"
    printf '%s\n' "$want"
    return 0
  fi

  ids=$(swarm_iterm hotkey-windows 2>/dev/null) || ids=""
  for id in $ids; do
    s=$(tmx display-message -p -t "$id" '#{session_name}' 2>/dev/null) || s=""
    if [[ -n "$s" ]]; then printf '%s\n' "$s"; return 0; fi
    break   # stale id: fall through
  done

  local list n
  list=$(tmx list-clients -F '#{client_control_mode} #{client_session}' 2>/dev/null \
    | sed -n 's/^1 //p' | sort -u) || list=""
  n=0
  [[ -z "$list" ]] || n=$(printf '%s\n' "$list" | wc -l | tr -d ' ')
  if [[ "$n" == 1 ]]; then printf '%s\n' "$list"; return 0; fi

  cfgpath="${SWARM_CONFIG:-$HOME/.agent-tmux/swarm.conf}"
  swarm_die "cannot find your hotkey window's tmux session; attach tmux in your hotkey window first (or set 'session' in $cfgpath)"
}

cmd__home() { swarm_home_session; }
