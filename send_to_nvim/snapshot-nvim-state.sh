#!/usr/bin/env bash
set -euo pipefail

pane_id="${1:-}"
snapshot_dir="${2:-}"

[ -n "$pane_id" ] || exit 1
[ -n "$snapshot_dir" ] || exit 1

registry_root="${TMUX_SEND_TO_NVIM_STATE_DIR:-$HOME/.tmux/tmp/sessions/registry}"
session_id="$(tmux display-message -p -t "$pane_id" '#{session_id}')"
entry_path=""

if [ -d "$registry_root/$session_id" ]; then
  entry_path="$(find "$registry_root/$session_id" -maxdepth 1 -type f -name "${pane_id}-*.json" | head -n 1)"
fi

[ -n "$entry_path" ] || exit 1

server="$(jq -r '.server // ""' "$entry_path")"
[ -n "$server" ] || exit 1

mkdir -p "$snapshot_dir"
snapshot_file="$snapshot_dir/meta.json"
# Escape all Lua string special sequences (backslash, quotes, and control chars)
escaped_snapshot_file="$(printf '%s' "$snapshot_file" | sed 's/\\/\\\\/g; s/"/\\"/g; s/\t/\\t/g')"

# Timeout the RPC call — an unresponsive nvim server must not block the save
nvim_timeout="${TMUX_MANAGE_NVIM_SNAPSHOT_TIMEOUT:-5}"
nvim --server "$server" --remote-expr \
  "luaeval(\"require('core.send_to_nvim').export_restore_state(_A)\", \"$escaped_snapshot_file\")" >/dev/null &
nvim_pid=$!
elapsed=0
while kill -0 "$nvim_pid" 2>/dev/null; do
  if [ "$elapsed" -ge "$nvim_timeout" ]; then
    # SIGKILL, not SIGTERM: a client blocked in a --remote-expr RPC against a
    # wedged nvim server ignores SIGTERM, so plain `kill` leaks the process.
    kill -9 "$nvim_pid" 2>/dev/null
    wait "$nvim_pid" 2>/dev/null || true
    exit 1
  fi
  sleep 1
  elapsed=$((elapsed + 1))
done
wait "$nvim_pid" || exit 1

[ -s "$snapshot_file" ] || exit 1

printf '%s\n' "$snapshot_file"
