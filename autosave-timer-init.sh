#!/usr/bin/env bash
# autosave-timer-init.sh — Start a self-rescheduling autosave timer using
# tmux run-shell -d (requires tmux 3.2+). This decouples autosave from
# status-right interpolation, so theme plugins that overwrite status-right
# no longer break autosave silently.
#
# Called once at tmux init (e.g., from .tmux.conf):
#   run-shell '/path/to/tmux-revive/autosave-timer-init.sh "#{socket_path}"'
#
# The timer reads @tmux-revive-autosave and @tmux-revive-autosave-interval
# from the tmux server on each tick, so changes take effect at the next cycle.
set -euo pipefail

if [ $# -gt 0 ] && [ -n "${1:-}" ] && [ "${1#--}" = "$1" ]; then
  export TMUX_REVIVE_SOCKET_PATH="$1"
  shift
fi

while [ $# -gt 0 ]; do
  case "$1" in
    --socket-path)
      export TMUX_REVIVE_SOCKET_PATH="${2:-}"
      shift 2
      ;;
    --server)
      export TMUX_REVIVE_TMUX_SERVER="${2:?--server requires a name}"
      shift 2
      ;;
    *)
      shift
      ;;
  esac
done

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Detect tmux version — need 3.2+ for run-shell -d
tmux_version="$(tmux -V 2>/dev/null | sed 's/[^0-9.]//g')"
major="${tmux_version%%.*}"
minor="${tmux_version#*.}"
minor="${minor%%.*}"

if [ "${major:-0}" -lt 3 ] || { [ "${major:-0}" -eq 3 ] && [ "${minor:-0}" -lt 2 ]; }; then
  # tmux < 3.2: fall back to status-right driven autosave (no-op here)
  exit 0
fi

# Prevent duplicate timers — use a tmux global option as a guard
already_running="$(tmux show-option -gqv '@tmux-revive-timer-active' 2>/dev/null || printf '')"
if [ "$already_running" = "1" ]; then
  exit 0
fi
tmux set-option -gq '@tmux-revive-timer-active' '1' 2>/dev/null || true

# Build the socket args for the timer script
socket_args=""
if [ -n "${TMUX_REVIVE_SOCKET_PATH:-}" ]; then
  socket_args="TMUX_REVIVE_SOCKET_PATH='${TMUX_REVIVE_SOCKET_PATH}'"
fi
if [ -n "${TMUX_REVIVE_TMUX_SERVER:-}" ]; then
  socket_args="${socket_args:+$socket_args }TMUX_REVIVE_TMUX_SERVER='${TMUX_REVIVE_TMUX_SERVER}'"
fi

# Schedule the first tick
interval="$(tmux show-option -gqv '@tmux-revive-autosave-interval' 2>/dev/null || printf '900')"
case "$interval" in ''|*[!0-9]*) interval=900 ;; esac

tmux run-shell -b -d "$interval" \
  "${socket_args:+env $socket_args }'$script_dir/autosave-timer-tick.sh'"
