#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/parse-server-arg.sh
source "$script_dir/lib/parse-server-arg.sh"
# shellcheck source=lib/state-common.sh
source "$script_dir/lib/state-common.sh"

manifest_path=""
session_guid=""
session_name=""
mode="archive"

print_help() {
  cat <<'EOF'
Usage: archive-session.sh [options]

Archive or unarchive a saved session by durable session GUID.

Options:
  --help                 Show this help text
  --latest               Use the latest saved manifest (default for --session-name)
  --manifest PATH        Use a specific manifest path when resolving --session-name
  --session-guid GUID    Target a specific saved session GUID
  --session-name NAME    Resolve a GUID from a saved session name
  --archive              Mark the session as archived (default)
  --unarchive            Clear the archived flag
  --status               Print archived or active for the targeted GUID
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --help|-h)
      print_help
      exit 0
      ;;
    --latest)
      shift
      ;;
    --manifest)
      manifest_path="${2:-}"
      shift 2
      ;;
    --session-guid)
      session_guid="${2:?--session-guid requires a value}"
      shift 2
      ;;
    --session-name)
      session_name="${2:-}"
      shift 2
      ;;
    --archive)
      mode="archive"
      shift
      ;;
    --unarchive)
      mode="unarchive"
      shift
      ;;
    --status)
      mode="status"
      shift
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

if [ -z "$session_guid" ]; then
  [ -n "$session_name" ] || {
    printf '%s\n' 'tmux-revive: use --session-guid or --session-name' >&2
    exit 1
  }

  if [ -z "$manifest_path" ]; then
    manifest_path="$(tmux_revive_find_latest_manifest || true)"
  fi
  [ -n "$manifest_path" ] || {
    printf '%s\n' 'tmux-revive: no saved snapshot found for session-name lookup' >&2
    exit 1
  }
  [ -f "$manifest_path" ] || {
    printf 'tmux-revive: manifest not found: %s\n' "$manifest_path" >&2
    exit 1
  }

  match_count="$(jq -r --arg name "$session_name" '[.sessions[]? | select(.session_name == $name)] | length' "$manifest_path")"
  if [ "${match_count:-0}" -gt 1 ]; then
    printf 'tmux-revive: multiple saved sessions matched session name: %s; use --session-guid\n' "$session_name" >&2
    exit 1
  fi

  session_guid="$(jq -r --arg name "$session_name" '.sessions[]? | select(.session_name == $name) | .session_guid // ""' "$manifest_path" | head -n 1)"
fi

[ -n "$session_guid" ] || {
  printf '%s\n' 'tmux-revive: could not resolve a saved session GUID' >&2
  exit 1
}

case "$mode" in
  archive)
    tmux_revive_set_session_archived "$session_guid" "true"
    printf 'archived\t%s\n' "$session_guid"
    ;;
  unarchive)
    tmux_revive_set_session_archived "$session_guid" "false"
    printf 'active\t%s\n' "$session_guid"
    ;;
  status)
    if tmux_revive_session_is_archived "$session_guid"; then
      printf 'archived\t%s\n' "$session_guid"
    else
      printf 'active\t%s\n' "$session_guid"
    fi
    ;;
esac
