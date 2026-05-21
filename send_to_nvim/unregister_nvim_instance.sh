#!/usr/bin/env sh
set -eu

pane_id="${1:-}"
nvim_pid="${2:-}"

[ -n "$pane_id" ] || exit 1
[ -n "$nvim_pid" ] || exit 1

registry_root="${TMUX_SEND_TO_NVIM_STATE_DIR:-$HOME/.tmux/tmp/sessions/registry}"
target_name="$pane_id-$nvim_pid.json"

session_id="$(tmux display-message -p -t "$pane_id" '#{session_id}' 2>/dev/null || true)"

if [ -n "$session_id" ] && [ -f "$registry_root/$session_id/$target_name" ]; then
  rm -f "$registry_root/$session_id/$target_name"
  exit 0
fi

find "$registry_root" -type f -name "$target_name" -delete 2>/dev/null || true
