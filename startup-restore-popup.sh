#!/usr/bin/env bash
# DEPRECATED: Use pick.sh --context startup instead.
# Kept for backward compatibility with direct CLI invocations.
set -euo pipefail

client_tty=""
context="startup"
manifest_path=""
transient_session=""
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TMUX_REVIVE_SCRIPT_DIR="$script_dir"
# shellcheck source=lib/parse-server-arg.sh
source "$script_dir/lib/parse-server-arg.sh"
# shellcheck source=lib/state-common.sh
source "$script_dir/lib/state-common.sh"
profile_path="$(tmux_revive_profile_path "" 2>/dev/null || true)"
include_archived="false"
if [ -n "$profile_path" ] && [ "$(tmux_revive_profile_read_bool "$profile_path" "include_archived" "false")" = "true" ]; then
  include_archived="true"
fi

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
    --manifest)
      manifest_path="${2:-}"
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

[ -n "$manifest_path" ] || manifest_path="$(tmux_revive_find_latest_manifest || true)"
[ -n "$manifest_path" ] || {
  printf '%s\n' 'No snapshot available.'
  exit 0
}

created_at="$(jq -r '.last_updated // .created_at // ""' "$manifest_path")"
session_lines="$(
  jq -c '.sessions[]' "$manifest_path" | while IFS= read -r session_json; do
    session_name="$(printf '%s\n' "$session_json" | jq -r '.session_name // ""')"
    session_guid="$(printf '%s\n' "$session_json" | jq -r '.session_guid // ""')"
    session_group="$(printf '%s\n' "$session_json" | jq -r '.session_group // ""')"
    tmux_session_name="$(printf '%s\n' "$session_json" | jq -r '.tmux_session_name // .session_name // ""')"
    [ -n "$session_name" ] || continue
    [ -z "$session_group" ] || continue
    if [ "$include_archived" != "true" ] && [ -n "$session_guid" ] && tmux_revive_session_is_archived "$session_guid"; then
      continue
    fi
    short_guid="$(printf '%s\n' "${session_guid:--}" | cut -c1-8)"
    line="- ${session_name} [${short_guid}]"
    if [ "$tmux_session_name" != "$session_name" ]; then
      line="${line} -> ${tmux_session_name}"
    fi
    [ -n "$tmux_session_name" ] || tmux_session_name="$session_name"
    if tmux has-session -t "$tmux_session_name" 2>/dev/null; then
      line="${line} (already live)"
    fi
    printf '%s\n' "$line"
  done
)"

printf '%s\n' 'tmux-revive startup restore'
printf '%s\n' ''
if [ "$context" = "new-session" ] && [ -n "$transient_session" ]; then
  printf '%s\n' 'A saved snapshot exists and this new session looks replaceable.'
  printf '%s\n' 'Choosing an attach action will replace the temporary blank session.'
  printf '%s\n' ''
else
  printf '%s\n' 'Saved sessions are available to restore.'
  printf '%s\n' ''
fi
printf 'Snapshot: %s\n' "$created_at"
printf '%s\n' 'Sessions:'
if [ -n "$session_lines" ]; then
  printf '%s\n' "$session_lines"
else
  printf '%s\n' '- none'
fi
printf '%s\n' ''
printf '%s\n' 'Actions:'
printf '%s\n' '  [A] Restore all and attach'
printf '%s\n' '  [a] Restore all without attaching'
printf '%s\n' '  [S] Choose one session and attach'
printf '%s\n' '  [s] Choose one session without attaching'
printf '%s\n' '  [p] Preview restore plan'
if [ "$context" = "new-session" ]; then
  printf '%s\n' '  [n] Skip (will ask again on next new session)'
else
  printf '%s\n' '  [n] Dismiss for this tmux server lifetime'
fi
printf '%s\n' ''

clear_transient_if_needed() {
  [ -n "$transient_session" ] || return 0
  tmux_revive_clear_transient_session_marker "$transient_session"
}

while :; do
  printf '%s' 'Select action [A/a/S/s/p/N]: '
  if ! IFS= read -r answer; then
    clear_transient_if_needed
    break
  fi

  case "$answer" in
    A|all|ALL)
      if [ -n "$transient_session" ]; then
        "$script_dir/restore-state.sh" --manifest "$manifest_path" --yes --attach --cleanup-transient-session "$transient_session"
      else
        "$script_dir/restore-state.sh" --manifest "$manifest_path" --yes --attach
      fi
      break
      ;;
    a|y|Y|yes|YES)
      clear_transient_if_needed
      "$script_dir/restore-state.sh" --manifest "$manifest_path" --yes --no-attach
      break
      ;;
    S|select|SELECT)
      if [ -n "$transient_session" ]; then
        "$script_dir/choose-saved-session.sh" --manifest "$manifest_path" --yes --attach --cleanup-transient-session "$transient_session"
      else
        "$script_dir/choose-saved-session.sh" --manifest "$manifest_path" --yes --attach
      fi
      break
      ;;
    s)
      clear_transient_if_needed
      "$script_dir/choose-saved-session.sh" --manifest "$manifest_path" --yes --no-attach
      break
      ;;
    p|P|preview|PREVIEW)
      printf '\n'
      "$script_dir/restore-state.sh" --manifest "$manifest_path" --preview
      printf '\nPress Enter to return to the restore dialog...'
      IFS= read -r _
      printf '\n'
      ;;
    *)
      clear_transient_if_needed
      if [ "$context" != "new-session" ]; then
        tmux_revive_mark_runtime_flag "$(tmux_revive_restore_prompt_suppressed_path)"
        printf '%s\n' ''
        printf '%s\n' 'Dismissed for this tmux server lifetime.'
      else
        printf '%s\n' ''
        printf '%s\n' 'Skipped. Will prompt again on next new session.'
      fi
      break
      ;;
  esac
done
