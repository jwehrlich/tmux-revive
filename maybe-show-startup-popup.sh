#!/usr/bin/env bash
set -euo pipefail

client_tty=""
context="startup"
transient_session=""

if [ $# -gt 0 ] && [ "${1#--}" = "$1" ]; then
  client_tty="${1:-}"
  shift || true
fi

while [ $# -gt 0 ]; do
  case "$1" in
    --client-tty)
      client_tty="${2:-}"
      shift 2
      ;;
    --context)
      context="${2:-startup}"
      shift 2
      ;;
    --transient-session|--session-target)
      transient_session="${2:-}"
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
TMUX_REVIVE_SCRIPT_DIR="$script_dir"
# shellcheck source=lib/state-common.sh
source "$script_dir/lib/state-common.sh"
profile_path="$(tmux_revive_profile_path "" 2>/dev/null || true)"
include_archived="false"
if [ -n "$profile_path" ] && [ "$(tmux_revive_profile_read_bool "$profile_path" "include_archived" "false")" = "true" ]; then
  include_archived="true"
fi

startup_mode="$(tmux_revive_startup_restore_mode)"
case "$startup_mode" in
  ""|prompt|PROMPT)
    startup_mode="prompt"
    ;;
  auto|AUTO|on|ON|yes|YES)
    startup_mode="auto"
    ;;
  off|OFF|disabled|DISABLED|no|NO)
    startup_mode="off"
    ;;
  *)
    startup_mode="prompt"
    ;;
esac

[ "$startup_mode" != "off" ] || exit 0

# Optional delay to let plugins and config finish loading before restore runs.
# Only applies on startup context (not new-session).
if [ "$context" = "startup" ] && [ -z "${TMUX_REVIVE_DELAY_APPLIED:-}" ]; then
  restore_delay="$(tmux show-option -gqv "@tmux-revive-restore-delay" 2>/dev/null || true)"
  if [ -n "$restore_delay" ] && [ "$restore_delay" -gt 0 ] 2>/dev/null; then
    # Re-invoke via run-shell -d to avoid blocking the tmux server queue (tmux 3.2+)
    _relaunch_args="TMUX_REVIVE_DELAY_APPLIED=1"
    [ -n "${TMUX_REVIVE_TMUX_SERVER:-}" ] && _relaunch_args="$_relaunch_args TMUX_REVIVE_TMUX_SERVER='$TMUX_REVIVE_TMUX_SERVER'"
    _relaunch_cmd="$_relaunch_args '$script_dir/maybe-show-startup-popup.sh'"
    [ -n "$client_tty" ] && _relaunch_cmd="$_relaunch_cmd --client-tty '$client_tty'"
    _relaunch_cmd="$_relaunch_cmd --context startup"
    [ -n "$transient_session" ] && _relaunch_cmd="$_relaunch_cmd --transient-session '$transient_session'"
    if tmux run-shell -b -d "$restore_delay" "$_relaunch_cmd" 2>/dev/null; then
      exit 0
    fi
    # Fallback for tmux < 3.2: blocking sleep
    sleep "$restore_delay"
  fi
fi

# Emergency brake: if the user creates this file, skip restore entirely
[ ! -f "$HOME/.tmux_revive_no_restore" ] || exit 0

manifest_path="$(tmux_revive_find_latest_manifest || true)"
[ -n "$manifest_path" ] || exit 0
[ -f "$manifest_path" ] || exit 0

# Resolve transient session names to exclude from "already live" checks.
# On new-session: the freshly created session (e.g. $0 named "0") shadows a saved session.
# On startup: all existing sessions are auto-created defaults, not user-restored sessions.
# Uses newline-delimited string for bash 3.2 compat (no associative arrays).
_transient_names=""
if [ "$context" = "new-session" ] && [ -n "$transient_session" ]; then
  _tn="$(tmux display-message -p -t "$transient_session" '#{session_name}' 2>/dev/null || true)"
  [ -z "$_tn" ] || _transient_names="$_tn"
elif [ "$context" = "startup" ]; then
  _transient_names="$(tmux list-sessions -F '#{session_name}' 2>/dev/null || true)"
fi

_is_transient_name() {
  local name="$1"
  printf '%s\n' "$_transient_names" | grep -qxF "$name"
}

has_restorable_sessions="false"
while IFS= read -r session_json; do
  [ -n "$session_json" ] || continue
  session_name="$(printf '%s\n' "$session_json" | jq -r '.session_name // ""')"
  tmux_session_name="$(printf '%s\n' "$session_json" | jq -r '.tmux_session_name // .session_name // ""')"
  session_group="$(printf '%s\n' "$session_json" | jq -r '.session_group // ""')"
  session_guid="$(printf '%s\n' "$session_json" | jq -r '.session_guid // ""')"
  [ -n "$session_name" ] || continue
  [ -z "$session_group" ] || continue
  if [ "$include_archived" != "true" ] && [ -n "$session_guid" ] && tmux_revive_session_is_archived "$session_guid"; then
    continue
  fi
  [ -n "$tmux_session_name" ] || tmux_session_name="$session_name"
  if tmux has-session -t "$tmux_session_name" 2>/dev/null; then
    # Transient sessions (auto-created defaults) shouldn't count as the saved session being live
    if _is_transient_name "$tmux_session_name"; then
      has_restorable_sessions="true"
      break
    fi
    continue
  fi
  has_restorable_sessions="true"
  break
done < <(jq -c '.sessions[]?' "$manifest_path")

[ "$has_restorable_sessions" = "true" ] || exit 0

last_prompted_path="$(tmux_revive_last_prompted_manifest_path)"
last_prompted_manifest="$(tmux_revive_read_runtime_value "$last_prompted_path" 2>/dev/null || true)"
suppress_path="$(tmux_revive_restore_prompt_suppressed_path)"

# For new-session context, always prompt if there are non-running saved sessions.
# For startup/client-attached, respect the suppress/already-prompted guards.
if [ "$context" != "new-session" ]; then
  if [ -f "$suppress_path" ]; then
    # Atomic claim: rename the suppress file so only one instance proceeds.
    # If mv fails, another instance already claimed it — honour the suppression.
    if ! mv "$suppress_path" "${suppress_path}.claimed.$$" 2>/dev/null; then
      exit 0
    fi
    # Clean up claimed file on any exit to prevent orphans
    trap 'rm -f "${suppress_path}.claimed.$$"' EXIT
    if [ "$last_prompted_manifest" = "$manifest_path" ]; then
      exit 0
    fi
    rm -f "$(tmux_revive_restore_prompt_shown_path)"
  fi
  if [ "$last_prompted_manifest" = "$manifest_path" ]; then
    exit 0
  fi
fi

if [ "$startup_mode" = "auto" ]; then
  # Guard: skip auto-restore if another tmux server is already running
  # (prevents duplicate sessions when multiple default servers start simultaneously)
  if [ -z "${TMUX_REVIVE_TMUX_SERVER:-}" ]; then
    # Guard: skip auto-restore if we are the default-socket server and
    # another default-socket server already exists. Named-socket servers
    # (-L) are unaffected because they manage separate session namespaces.
    _own_socket="$(tmux display-message -p '#{socket_path}' 2>/dev/null || true)"
    _default_socket="/tmp/tmux-$(id -u)/default"
    # Canonicalize both paths — /tmp may be a symlink (e.g. macOS /tmp -> /private/tmp)
    # and tmux may return either form
    _own_socket="$(cd "$(dirname "$_own_socket")" 2>/dev/null && pwd -P)/$(basename "$_own_socket")" 2>/dev/null || _own_socket="$_own_socket"
    _default_socket="$(cd "$(dirname "$_default_socket")" 2>/dev/null && pwd -P)/$(basename "$_default_socket")" 2>/dev/null || _default_socket="$_default_socket"
    if [ "$_own_socket" = "$_default_socket" ] && [ -S "$_default_socket" ]; then
      _default_pid="$(tmux -S "$_default_socket" display-message -p '#{pid}' 2>/dev/null || true)"
      _own_pid="$(tmux display-message -p '#{pid}' 2>/dev/null || true)"
      if [ -n "$_default_pid" ] && [ -n "$_own_pid" ] && [ "$_default_pid" != "$_own_pid" ]; then
        exit 0
      fi
    fi
  fi
  restore_args=(--latest --yes)
  if [ -n "$client_tty" ]; then
    restore_args+=(--report-client-tty "$client_tty")
  fi
  tmux_revive_write_runtime_value "$last_prompted_path" "$manifest_path"
  tmux display-message "tmux-revive: startup auto-restore running" >/dev/null 2>&1 || true
  if [ "$context" = "new-session" ] && [ -n "$transient_session" ]; then
    tmux_revive_mark_transient_session "$transient_session"
    restore_args+=(--cleanup-transient-session "$transient_session")
  else
    :
  fi
  "$script_dir/restore-state.sh" "${restore_args[@]}"
  exit 0
fi

[ -n "$client_tty" ] || exit 0
tmux_revive_write_runtime_value "$last_prompted_path" "$manifest_path"
tmux_revive_mark_runtime_flag "$(tmux_revive_restore_prompt_shown_path)"
if [ "$context" = "new-session" ] && [ -n "$transient_session" ]; then
  tmux_revive_mark_transient_session "$transient_session"
fi
pick_cmd="$script_dir/pick.sh --context $(printf '%q' "$context") --manifest $(printf '%q' "$manifest_path")"
if [ -n "$transient_session" ]; then
  pick_cmd="$pick_cmd --transient-session $(printf '%q' "$transient_session")"
fi
tmux display-popup -t "$client_tty" -w 60% -h 50% -E "$pick_cmd" || true
