#!/usr/bin/env bash
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
      printf 'Unknown argument: %s\n' "$1" >&2
      exit 1
      ;;
  esac
done

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/state-common.sh
source "$script_dir/lib/state-common.sh"

autosave_enabled="$(tmux show-option -gqv '@tmux-revive-autosave' 2>/dev/null || printf 'on')"
[ "$autosave_enabled" = "off" ] && exit 0

interval="$(tmux show-option -gqv '@tmux-revive-autosave-interval' 2>/dev/null || printf '900')"
case "$interval" in
  ''|*[!0-9]*)
    interval=900
    ;;
esac

last_auto_path="$(tmux_revive_last_auto_save_path)"
last_save_notice_path="$(tmux_revive_last_save_notice_path)"
last_auto=0
# Prefer tmux option (single IPC call, no file I/O) with file fallback
last_auto="$(tmux show-option -gqv '@tmux-revive-last-auto-save' 2>/dev/null || printf '')"
case "$last_auto" in ''|*[!0-9]*) last_auto="" ;; esac
if [ -z "$last_auto" ]; then
  if [ -f "$last_auto_path" ]; then
    last_auto="$(cat "$last_auto_path" 2>/dev/null || printf '0')"
  else
    # First run after server start — seed timestamp to delay first auto-save
    last_auto="$(date +%s)"
    mkdir -p "$(dirname "$last_auto_path")"
    printf '%s\n' "$last_auto" >"$last_auto_path"
    tmux set-option -gq '@tmux-revive-last-auto-save' "$last_auto" 2>/dev/null || true
  fi
fi
case "$last_auto" in ''|*[!0-9]*) last_auto=0 ;; esac

notice_duration="$(tmux show-option -gqv '@tmux-revive-save-notice-duration' 2>/dev/null || printf '15')"
case "$notice_duration" in
  ''|*[!0-9]*)
    notice_duration=15
    ;;
esac

now="$(date +%s)"
if [ -f "$last_save_notice_path" ]; then
  notice_status="$(jq -r '.status // "done"' "$last_save_notice_path" 2>/dev/null || printf 'done')"

  # Show spinner while save is in progress
  if [ "$notice_status" = "saving" ]; then
    started_at="$(jq -r '.started_at // 0' "$last_save_notice_path" 2>/dev/null || printf '0')"
    case "$started_at" in ''|*[!0-9]*) started_at=0 ;; esac
    # Clear stale saving indicator (save crashed without cleanup)
    if [ "$started_at" -gt 0 ] && [ $((now - started_at)) -gt 120 ]; then
      rm -f "$last_save_notice_path" "${last_save_notice_path%.json}-spin"
    else
      spinner=(⠋ ⠙ ⠹ ⠸ ⠼ ⠴ ⠦ ⠧ ⠇ ⠏)
      spin_counter_path="${last_save_notice_path%.json}-spin"
      spin_idx=0
      if [ -f "$spin_counter_path" ]; then
        spin_idx="$(cat "$spin_counter_path" 2>/dev/null || printf '0')"
        case "$spin_idx" in ''|*[!0-9]*) spin_idx=0 ;; esac
      fi
      printf '%s\n' "$(( (spin_idx + 1) % 10 ))" >"$spin_counter_path"
      saving_style="$(tmux show-option -gqv '@tmux-revive-status-style' 2>/dev/null || printf '')"
      saving_label="$(printf ' 💾 %s saving' "${spinner[$spin_idx]}")"
      if [ -n "$saving_style" ]; then
        printf '#[%s]%s#[default]' "$saving_style" "$saving_label"
      else
        printf '%s' "$saving_label"
      fi
    fi
    exit 0
  fi

  saved_at="$(jq -r '.saved_at // 0' "$last_save_notice_path" 2>/dev/null || printf '0')"
  save_mode="$(jq -r '.mode // ""' "$last_save_notice_path" 2>/dev/null || printf '')"

  case "$saved_at" in
    ''|*[!0-9]*)
      saved_at=0
      ;;
  esac

  if [ $((now - saved_at)) -le "$notice_duration" ]; then
    status_style="$(tmux show-option -gqv '@tmux-revive-status-style' 2>/dev/null || printf '')"
    if [ "$save_mode" = "auto" ]; then
      label=' 💾 auto-saved'
    else
      label=' 💾 saved'
    fi
    if [ -n "$status_style" ]; then
      printf '#[%s]%s#[default]' "$status_style" "$label"
    else
      printf '%s' "$label"
    fi
    exit 0
  fi
fi

# If the hook-based timer is active (tmux 3.2+), skip the status-right
# save trigger — autosave-timer-tick.sh handles scheduling instead.
# But if the heartbeat is stale (timer died), clear the guard and fall back.
timer_active="$(tmux show-option -gqv '@tmux-revive-timer-active' 2>/dev/null || printf '')"
if [ "$timer_active" = "1" ]; then
  timer_last_tick="$(tmux show-option -gqv '@tmux-revive-timer-last-tick' 2>/dev/null || printf '')"
  case "$timer_last_tick" in ''|*[!0-9]*) timer_last_tick=0 ;; esac
  stale_threshold=$((interval * 2 + 60))
  if [ "$timer_last_tick" -gt 0 ] && [ $((now - timer_last_tick)) -gt "$stale_threshold" ]; then
    # Timer is dead — clear the guard and fall through to status-right save
    tmux set-option -gq '@tmux-revive-timer-active' '' 2>/dev/null || true
  else
    exit 0
  fi
fi

# Watchdog: auto-clear stale save locks to prevent permanent deadlocks
tmux_revive_check_stale_save_lock --clear || true

if [ $((now - last_auto)) -lt "$interval" ]; then
  exit 0
fi

("$script_dir/save-state.sh" --auto --reason autosave-tick >/dev/null 2>&1 || true) &
exit 0
