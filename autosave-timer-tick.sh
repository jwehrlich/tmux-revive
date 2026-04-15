#!/usr/bin/env bash
# autosave-timer-tick.sh — Single tick of the hook-based autosave timer.
# Performs the save if due, then reschedules itself via run-shell -d.
# This script is invoked by tmux's run-shell -d mechanism, NOT by status-right.
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/state-common.sh
source "$script_dir/lib/state-common.sh"

_reschedule() {
  local interval
  interval="$(tmux show-option -gqv '@tmux-revive-autosave-interval' 2>/dev/null || printf '900')"
  case "$interval" in ''|*[!0-9]*) interval=900 ;; esac

  local socket_args=""
  if [ -n "${TMUX_REVIVE_SOCKET_PATH:-}" ]; then
    socket_args="TMUX_REVIVE_SOCKET_PATH='${TMUX_REVIVE_SOCKET_PATH}'"
  fi
  if [ -n "${TMUX_REVIVE_TMUX_SERVER:-}" ]; then
    socket_args="${socket_args:+$socket_args }TMUX_REVIVE_TMUX_SERVER='${TMUX_REVIVE_TMUX_SERVER}'"
  fi

  tmux run-shell -b -d "$interval" \
    "${socket_args:+env $socket_args }'$script_dir/autosave-timer-tick.sh'" 2>/dev/null || true
}

# Ensure timer chain survives crashes: reschedule on any exit (H2)
trap '_reschedule' EXIT

# Write heartbeat timestamp for health monitoring (H1)
tmux set-option -gq '@tmux-revive-timer-last-tick' "$(date +%s)" 2>/dev/null || true

# ── Periodic update check (runs regardless of autosave setting) ──────
_check_updates_enabled="$(tmux show-option -gqv '@tmux-revive-check-updates' 2>/dev/null || printf 'on')"
if [ "$_check_updates_enabled" != "off" ]; then
  _runtime_dir="$(tmux_revive_runtime_dir 2>/dev/null || true)"
  if [ -n "$_runtime_dir" ]; then
    _last_check_file="$_runtime_dir/last-update-check"
    _check_interval="$(tmux show-option -gqv '@tmux-revive-check-updates-interval' 2>/dev/null || printf '86400')"
    case "$_check_interval" in ''|*[!0-9]*) _check_interval=86400 ;; esac
    _last_check="$(cat "$_last_check_file" 2>/dev/null || printf '0')"
    case "$_last_check" in ''|*[!0-9]*) _last_check=0 ;; esac
    _now="$(date +%s)"
    if [ $((_now - _last_check)) -ge "$_check_interval" ]; then
      ("$script_dir/check-updates.sh" >/dev/null 2>&1 || true) &
    fi
  fi
fi

# Check if autosave is enabled
autosave_enabled="$(tmux show-option -gqv '@tmux-revive-autosave' 2>/dev/null || printf 'on')"
if [ "$autosave_enabled" = "off" ]; then
  # EXIT trap handles rescheduling so we pick up config changes
  exit 0
fi

# Watchdog: auto-clear stale save locks to prevent permanent deadlocks
tmux_revive_check_stale_save_lock --clear || true

# Check timing
last_auto_path="$(tmux_revive_last_auto_save_path)"
last_auto="$(tmux show-option -gqv '@tmux-revive-last-auto-save' 2>/dev/null || printf '')"
case "$last_auto" in ''|*[!0-9]*) last_auto="" ;; esac
if [ -z "$last_auto" ]; then
  if [ -f "$last_auto_path" ]; then
    last_auto="$(cat "$last_auto_path" 2>/dev/null || printf '0')"
  else
    last_auto="$(date +%s)"
    printf '%s\n' "$last_auto" >"$last_auto_path"
    tmux set-option -gq '@tmux-revive-last-auto-save' "$last_auto" 2>/dev/null || true
  fi
fi
case "$last_auto" in ''|*[!0-9]*) last_auto=0 ;; esac

interval="$(tmux show-option -gqv '@tmux-revive-autosave-interval' 2>/dev/null || printf '900')"
case "$interval" in ''|*[!0-9]*) interval=900 ;; esac

now="$(date +%s)"
if [ $((now - last_auto)) -ge "$interval" ]; then
  ("$script_dir/save-state.sh" --auto --reason autosave-timer >/dev/null 2>&1 || true) &
fi

# _reschedule runs via the EXIT trap — no explicit call needed
