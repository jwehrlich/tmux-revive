#!/usr/bin/env bash
set -euo pipefail

if [ "$(uname -s)" != "Darwin" ]; then
  printf 'launchd-runner: this script is macOS-only\n' >&2
  exit 1
fi

# Runner script invoked by launchd.
# Starts a tmux server and triggers session restore.

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
tmux_revive_dir="$(cd "$script_dir/.." && pwd)"

tmux_bin="$(command -v tmux 2>/dev/null || printf '/opt/homebrew/bin/tmux')"
[ -x "$tmux_bin" ] || { printf 'tmux not found\n' >&2; exit 1; }

# If tmux server is already running, do nothing
if "$tmux_bin" list-sessions >/dev/null 2>&1; then
  printf 'tmux server already running, skipping auto-start\n'
  exit 0
fi

# Start a detached tmux session
"$tmux_bin" new-session -d -s _launchd_init 2>/dev/null || true

# The after-new-session hook (if configured in .tmux.conf) will handle
# the restore popup. If not, we trigger restore directly.
if [ -x "$tmux_revive_dir/maybe-show-startup-popup.sh" ]; then
  "$tmux_revive_dir/maybe-show-startup-popup.sh" 2>/dev/null || true
fi

# Optionally open a terminal window so the user sees their restored sessions
terminal_app="${TMUX_REVIVE_TERMINAL_APP:-}"
if [ -z "$terminal_app" ]; then
  # Check if the option was persisted in tmux
  terminal_app="$("$tmux_bin" show-option -gqv '@tmux-revive-terminal-app' 2>/dev/null || printf '')"
fi
if [ -n "$terminal_app" ]; then
  open_terminal="$tmux_revive_dir/system/open-terminal.sh"
  if [ -x "$open_terminal" ]; then
    "$open_terminal" --app "$terminal_app" 2>/dev/null || true
  fi
fi

printf 'tmux-revive: launchd auto-start complete at %s\n' "$(date)"
