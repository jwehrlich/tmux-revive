#!/usr/bin/env bash
# clear-save-lock.sh — Manually force-clear a stuck save lock.
#
# Use when autosave appears stuck or tmux is unresponsive due to a
# hung save process. The autosave watchdog normally handles stale
# locks automatically, but this command provides an immediate escape.
#
# Usage:
#   bash ~/.tmux/plugins/tmux-revive/clear-save-lock.sh [--server NAME]
#   # Or via tmux:
#   tmux run-shell '~/.tmux/plugins/tmux-revive/clear-save-lock.sh'
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

while [ $# -gt 0 ]; do
  case "$1" in
    --server)
      export TMUX_REVIVE_TMUX_SERVER="${2:?--server requires a name}"
      shift 2
      ;;
    *)
      shift
      ;;
  esac
done

# shellcheck source=lib/state-common.sh
source "$script_dir/lib/state-common.sh"

runtime_dir="$(tmux_revive_runtime_dir)"
lock_dir="$runtime_dir/save.lock"
lock_meta_path="$lock_dir/meta.json"
save_log_path="$runtime_dir/save-activity.log"

if [ ! -d "$lock_dir" ]; then
  printf 'tmux-revive: no save lock found (nothing to clear)\n'
  tmux display-message "tmux-revive: no save lock found" 2>/dev/null || true
  exit 0
fi

# Show lock info before clearing
if [ -f "$lock_meta_path" ]; then
  pid="$(jq -r '.pid // "unknown"' "$lock_meta_path" 2>/dev/null || printf 'unknown')"
  started_at="$(jq -r '.started_at // 0' "$lock_meta_path" 2>/dev/null || printf '0')"
  case "$started_at" in ''|*[!0-9]*) started_at=0 ;; esac
  if [ "$started_at" -gt 0 ]; then
    now="$(date +%s)"
    age=$((now - started_at))
    printf 'tmux-revive: clearing save lock (pid=%s, held for %ss)\n' "$pid" "$age"
  else
    printf 'tmux-revive: clearing save lock (pid=%s)\n' "$pid"
  fi
else
  printf 'tmux-revive: clearing save lock (no metadata)\n'
fi

rm -rf "$lock_dir"

printf '[%s] FORCE-CLEAR save lock removed manually\n' \
  "$(date +%Y-%m-%dT%H:%M:%S)" \
  >>"$save_log_path" 2>/dev/null || true

printf 'tmux-revive: save lock cleared\n'
tmux display-message "tmux-revive: save lock cleared ✓" 2>/dev/null || true
