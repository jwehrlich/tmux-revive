#!/usr/bin/env sh
set -eu

pane_id="${1:-}"
server="${2:-}"
nvim_pid="${3:-}"
cwd="${4:-}"

[ -n "$pane_id" ] || exit 1
[ -n "$server" ] || exit 1
[ -n "$nvim_pid" ] || exit 1
[ -n "$cwd" ] || exit 1

registry_root="${TMUX_SEND_TO_NVIM_STATE_DIR:-$HOME/.tmux/tmp/sessions/registry}"
session_id="$(tmux display-message -p -t "$pane_id" '#{session_id}')"
window_id="$(tmux display-message -p -t "$pane_id" '#{window_id}')"
last_active_epoch="$(date +%s)"

[ -n "$session_id" ] || exit 1
[ -n "$window_id" ] || exit 1

session_dir="$registry_root/$session_id"
entry_path="$session_dir/$pane_id-$nvim_pid.json"
tmp_path="$session_dir/.tmp.$pane_id-$nvim_pid.$$"

mkdir -p "$session_dir"

jq -n \
  --arg session_id "$session_id" \
  --arg window_id "$window_id" \
  --arg pane_id "$pane_id" \
  --arg nvim_pid "$nvim_pid" \
  --arg server "$server" \
  --arg cwd "$cwd" \
  --argjson last_active_epoch "$last_active_epoch" \
  '{
    session_id: $session_id,
    window_id: $window_id,
    pane_id: $pane_id,
    nvim_pid: $nvim_pid,
    server: $server,
    cwd: $cwd,
    last_active_epoch: $last_active_epoch
  }' >"$tmp_path"

mv "$tmp_path" "$entry_path"
