#!/usr/bin/env bash
set -euo pipefail

# Diagnostic tool that checks whether autosave is functioning correctly.
# Usage: autosave-health.sh [--socket-path PATH] [--server NAME]

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
# shellcheck source=lib/state-common.sh
source "$script_dir/lib/state-common.sh"

issues=0
warnings=0

ok() { printf '  ✓ %s\n' "$1"; }
warn() { printf '  ⚠ %s\n' "$1"; warnings=$((warnings + 1)); }
err() { printf '  ✗ %s\n' "$1"; issues=$((issues + 1)); }

printf 'tmux-revive autosave health check\n'
printf '==================================\n\n'

# 1. Check tmux server is running
printf 'tmux server:\n'
if tmux list-sessions >/dev/null 2>&1; then
  session_count="$(tmux list-sessions 2>/dev/null | wc -l | tr -d ' ')"
  ok "server running ($session_count session(s))"
else
  err "tmux server not reachable"
  printf '\nResult: %d issue(s), %d warning(s)\n' "$issues" "$warnings"
  exit 1
fi

# 2. Check autosave enabled
printf '\nautosave config:\n'
autosave_enabled="$(tmux show-option -gqv '@tmux-revive-autosave' 2>/dev/null || printf 'on')"
if [ "$autosave_enabled" = "off" ]; then
  warn "autosave is disabled (@tmux-revive-autosave = off)"
else
  ok "autosave enabled"
fi

interval="$(tmux show-option -gqv '@tmux-revive-autosave-interval' 2>/dev/null || printf '900')"
case "$interval" in ''|*[!0-9]*) interval=900 ;; esac
ok "interval: ${interval}s ($(( interval / 60 ))m)"

# 3. Check timer vs status-right mode
printf '\nautosave mechanism:\n'
timer_active="$(tmux show-option -gqv '@tmux-revive-timer-active' 2>/dev/null || printf '')"
if [ "$timer_active" = "1" ]; then
  timer_last_tick="$(tmux show-option -gqv '@tmux-revive-timer-last-tick' 2>/dev/null || printf '')"
  case "$timer_last_tick" in ''|*[!0-9]*) timer_last_tick=0 ;; esac
  now="$(date +%s)"
  stale_threshold=$((interval * 2 + 60))
  if [ "$timer_last_tick" -gt 0 ] && [ $((now - timer_last_tick)) -gt "$stale_threshold" ]; then
    err "hook-based timer guard is set but heartbeat is stale (last tick $(( now - timer_last_tick ))s ago, threshold ${stale_threshold}s)"
    warn "the timer chain may have died — status-right fallback should recover on next tick"
  elif [ "$timer_last_tick" -gt 0 ]; then
    ok "hook-based timer active (last tick $(( now - timer_last_tick ))s ago)"
  else
    ok "hook-based timer active (no heartbeat yet — recently started)"
  fi
else
  # Check status-right contains autosave-tick.sh
  status_right="$(tmux show-option -gqv 'status-right' 2>/dev/null || printf '')"
  if printf '%s' "$status_right" | grep -q 'autosave-tick\.sh'; then
    ok "status-right contains autosave-tick.sh"
  else
    err "autosave-tick.sh NOT found in status-right — autosave is not running"
    warn "a theme plugin may have overwritten status-right after tmux-revive loaded"
  fi
fi

# 4. Check last auto-save timestamp
printf '\nlast auto-save:\n'
runtime_dir="$(tmux_revive_runtime_dir)"
last_auto="$(tmux show-option -gqv '@tmux-revive-last-auto-save' 2>/dev/null || printf '')"
case "$last_auto" in ''|*[!0-9]*) last_auto="" ;; esac

if [ -z "$last_auto" ]; then
  last_auto_path="$(tmux_revive_last_auto_save_path)"
  if [ -f "$last_auto_path" ]; then
    last_auto="$(cat "$last_auto_path" 2>/dev/null || printf '')"
    case "$last_auto" in ''|*[!0-9]*) last_auto="" ;; esac
  fi
fi

if [ -n "$last_auto" ] && [ "$last_auto" -gt 0 ] 2>/dev/null; then
  now="$(date +%s)"
  age=$((now - last_auto))
  if [ "$age" -lt 0 ]; then age=0; fi

  if [ "$age" -le $((interval * 3)) ]; then
    ok "last auto-save: ${age}s ago (healthy)"
  elif [ "$age" -le $((interval * 10)) ]; then
    warn "last auto-save: ${age}s ago ($(( age / 60 ))m — may be stale)"
  else
    err "last auto-save: ${age}s ago ($(( age / 60 ))m — likely broken)"
  fi
else
  warn "no auto-save timestamp found (first run or server just started)"
fi

# 5. Check for stale save lock
printf '\nsave lock:\n'
lock_dir="$runtime_dir/save.lock"
if [ -d "$lock_dir" ]; then
  lock_meta="$lock_dir/meta.json"
  if [ -f "$lock_meta" ]; then
    lock_pid="$(jq -r '.pid // 0' "$lock_meta" 2>/dev/null || printf '0')"
    lock_started="$(jq -r '.started_at // 0' "$lock_meta" 2>/dev/null || printf '0')"
    case "$lock_pid" in ''|*[!0-9]*) lock_pid=0 ;; esac
    case "$lock_started" in ''|*[!0-9]*) lock_started=0 ;; esac

    if [ "$lock_pid" -gt 0 ] && kill -0 "$lock_pid" 2>/dev/null; then
      ok "save lock held by PID $lock_pid (active)"
    else
      now="$(date +%s)"
      lock_age=$(( now - lock_started ))
      [ "$lock_age" -lt 0 ] && lock_age=0
      err "stale save lock (PID $lock_pid not running, age ${lock_age}s)"
      warn "remove $lock_dir to clear the stale lock"
    fi
  else
    warn "lock directory exists but no metadata — possibly corrupted"
  fi
else
  ok "no save lock held"
fi

# 6. Check latest snapshot exists
printf '\nlatest snapshot:\n'
latest_link="$(tmux_revive_state_root)/latest"
if [ -L "$latest_link" ] || [ -f "$latest_link" ]; then
  latest_target="$(readlink "$latest_link" 2>/dev/null || cat "$latest_link" 2>/dev/null || true)"
  if [ -n "$latest_target" ]; then
    manifest="$latest_target/manifest.json"
    if [ -f "$manifest" ]; then
      snap_time="$(jq -r '.saved_at // ""' "$manifest" 2>/dev/null || true)"
      ok "latest snapshot: $snap_time"
    else
      warn "latest link exists but manifest not found"
    fi
  else
    warn "latest link exists but target is empty"
  fi
else
  warn "no latest snapshot link found"
fi

# Summary
printf '\n==================================\n'
if [ "$issues" -eq 0 ] && [ "$warnings" -eq 0 ]; then
  printf 'Result: all checks passed\n'
elif [ "$issues" -eq 0 ]; then
  printf 'Result: %d warning(s), no critical issues\n' "$warnings"
else
  printf 'Result: %d issue(s), %d warning(s)\n' "$issues" "$warnings"
fi
