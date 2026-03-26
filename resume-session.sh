#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TMUX_REVIVE_SCRIPT_DIR="$script_dir"
# shellcheck source=lib/parse-server-arg.sh
source "$script_dir/lib/parse-server-arg.sh"
# shellcheck source=lib/state-common.sh
source "$script_dir/lib/state-common.sh"

selector=""
selector_mode="auto"
manifest_path=""
assume_yes="false"
list_only="false"
attach_after_restore="false"
no_attach="false"
explicit_attach="false"
explicit_no_attach="false"
requested_profile=""
profile_path=""
preview_explicit="false"
cleanup_transient_session=""

print_help() {
  cat <<'EOF'
Usage: resume-session.sh [options] [selector]

Resume one saved tmux session from the latest snapshot by GUID, session label, or legacy session id.

Options:
  --help             Show this help text
  --list             Show sessions from the latest saved manifest
  --latest           Use the latest saved manifest (default)
  --manifest PATH    Use a specific manifest path
  --guid GUID        Resume by durable session GUID
  --name NAME        Resume by human-readable session label
  --id ID            Resume by legacy tmux session ID from the snapshot
  --selector VALUE   Resume by GUID, label, or legacy id, auto-detected
  --profile NAME|PATH
                     Apply a named restore profile or explicit profile file
  --attach           Attach or switch to the restored session after restore
  --no-attach        Restore without attaching or switching
  --no-preview       Override a previewing profile and restore immediately
  --cleanup-transient-session TARGET
                     Remove a marked transient session after successful attach
  --yes              Skip collision prompt and restore what can be restored

Notes:
  - If run outside tmux, this helper attaches automatically after restore.
  - If run inside tmux, restore-state.sh will switch the current client to the restored session.
  - Auto-detection treats UUID-like values as GUIDs, values starting with '$' or 'legacy:' as legacy ids, and everything else as labels.

Examples:
  resume-session.sh --list
  resume-session.sh 123e4567-e89b-12d3-a456-426614174000
  resume-session.sh work
  resume-session.sh '$1'
  resume-session.sh --manifest /path/to/manifest.json --guid 123e4567-e89b-12d3-a456-426614174000
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --help|-h)
      print_help
      exit 0
      ;;
    --list)
      list_only="true"
      shift
      ;;
    --latest)
      shift
      ;;
    --manifest)
      manifest_path="${2:-}"
      shift 2
      ;;
    --guid)
      selector="${2:-}"
      selector_mode="guid"
      shift 2
      ;;
    --name)
      selector="${2:-}"
      selector_mode="name"
      shift 2
      ;;
    --id)
      selector="${2:-}"
      selector_mode="id"
      shift 2
      ;;
    --selector)
      selector="${2:-}"
      selector_mode="auto"
      shift 2
      ;;
    --profile)
      requested_profile="${2:-}"
      shift 2
      ;;
    --attach)
      attach_after_restore="true"
      no_attach="false"
      explicit_attach="true"
      explicit_no_attach="false"
      shift
      ;;
    --no-attach)
      no_attach="true"
      attach_after_restore="false"
      explicit_no_attach="true"
      explicit_attach="false"
      shift
      ;;
    --no-preview)
      preview_explicit="true"
      shift
      ;;
    --cleanup-transient-session)
      cleanup_transient_session="${2:-}"
      shift 2
      ;;
    --yes)
      assume_yes="true"
      shift
      ;;
    --server)
      export TMUX_REVIVE_TMUX_SERVER="${2:?--server requires a name}"
      shift 2
      ;;
    --*)
      printf 'Unknown argument: %s\n' "$1" >&2
      exit 1
      ;;
    *)
      if [ -n "$selector" ]; then
        printf 'resume-session.sh: unexpected extra argument: %s\n' "$1" >&2
        exit 1
      fi
      selector="$1"
      selector_mode="auto"
      shift
      ;;
  esac
done

if profile_path="$(tmux_revive_profile_path "$requested_profile" 2>/dev/null)"; then
  :
elif [ -n "$requested_profile" ] || [ -n "$(tmux_revive_default_profile_name)" ]; then
  printf 'tmux-revive: profile not found: %s\n' "${requested_profile:-$(tmux_revive_default_profile_name)}" >&2
  exit 1
fi

restore_args=()

if [ "$list_only" = "true" ]; then
  restore_args+=(--list)
  if [ -n "$manifest_path" ]; then
    restore_args+=(--manifest "$manifest_path")
  fi
  if [ -n "$profile_path" ]; then
    restore_args+=(--profile "$profile_path")
  fi
  exec "$script_dir/restore-state.sh" "${restore_args[@]}"
fi

if [ -z "$selector" ]; then
  printf '%s\n' 'resume-session.sh: provide a session GUID, label, or legacy id, or use --list' >&2
  exit 1
fi

if [ -n "$manifest_path" ]; then
  restore_args+=(--manifest "$manifest_path")
fi

if [ -n "$profile_path" ]; then
  restore_args+=(--profile "$profile_path")
fi

if [ "$assume_yes" = "true" ]; then
  restore_args+=(--yes)
fi

if [ "$attach_after_restore" = "true" ]; then
  restore_args+=(--attach)
elif [ "$no_attach" = "true" ]; then
  restore_args+=(--no-attach)
elif [ -n "$profile_path" ]; then
  if [ "$(tmux_revive_profile_read_bool "$profile_path" "attach" "false")" = "true" ]; then
    restore_args+=(--attach)
  else
    restore_args+=(--no-attach)
  fi
elif [ -z "${TMUX:-}" ]; then
  restore_args+=(--attach)
fi

if [ -n "$cleanup_transient_session" ]; then
  restore_args+=(--cleanup-transient-session "$cleanup_transient_session")
fi

if [ "$preview_explicit" = "true" ]; then
  restore_args+=(--no-preview)
fi

if [ "$selector_mode" = "auto" ]; then
  if printf '%s\n' "$selector" | grep -Eq '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'; then
    selector_mode="guid"
  elif printf '%s\n' "$selector" | grep -Eq '^legacy:'; then
    selector_mode="id"
    selector="${selector#legacy:}"
  elif printf '%s\n' "$selector" | grep -Eq '^\$[0-9]+$'; then
    selector_mode="id"
  else
    selector_mode="name"
  fi
fi

case "$selector_mode" in
  guid)
    restore_args+=(--session-guid "$selector")
    ;;
  id)
    restore_args+=(--session-id "$selector")
    ;;
  name)
    restore_args+=(--session-name "$selector")
    ;;
  *)
    printf 'resume-session.sh: unsupported selector mode: %s\n' "$selector_mode" >&2
    exit 1
    ;;
esac

exec "$script_dir/restore-state.sh" "${restore_args[@]}"
