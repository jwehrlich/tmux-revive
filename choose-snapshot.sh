#!/usr/bin/env bash
# DEPRECATED: Use pick.sh --show-snapshots instead. Revive now handles
# snapshot browsing with Ctrl-b toggle. Kept for direct CLI use.
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TMUX_REVIVE_SCRIPT_DIR="$script_dir"
# shellcheck source=lib/parse-server-arg.sh
source "$script_dir/lib/parse-server-arg.sh"
# shellcheck source=lib/state-common.sh
source "$script_dir/lib/state-common.sh"

initial_query=""
assume_yes="false"
attach_after_restore="false"
no_attach="false"
cleanup_transient_session=""
dump_items="false"
include_imported="false"
requested_profile=""
profile_path=""
explicit_attach="false"
explicit_no_attach="false"
explicit_preview="false"

choose_saved_session_cmd="${TMUX_REVIVE_CHOOSE_SAVED_SESSION_CMD:-$script_dir/choose-saved-session.sh}"
restore_state_cmd="${TMUX_REVIVE_RESTORE_STATE_CMD:-$script_dir/restore-state.sh}"

print_help() {
  cat <<'EOF'
Usage: choose-snapshot.sh [options]

Interactively choose a saved snapshot, then either browse its sessions or restore it directly.

Options:
  --help             Show this help text
  --query TEXT       Prefill the chooser query
  --profile NAME|PATH
                     Apply a named restore profile or explicit profile file
  --attach           Attach or switch after restore
  --no-attach        Restore without attaching or switching
  --no-preview       Override a previewing profile and restore immediately
  --cleanup-transient-session TARGET
                     Remove a marked transient session after successful attach
  --yes              Skip collision prompt and restore what can be restored
  --dump-items       Print raw chooser rows for testing
  --include-imported Include imported snapshots in the chooser

Keys:
  Enter              Choose a snapshot, then open the saved-session chooser for it
  Ctrl-a             Restore all sessions from the selected snapshot
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --help|-h)
      print_help
      exit 0
      ;;
    --query)
      initial_query="${2:-}"
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
      explicit_preview="true"
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
    --dump-items)
      dump_items="true"
      shift
      ;;
    --include-imported)
      include_imported="true"
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

if profile_path="$(tmux_revive_profile_path "$requested_profile" 2>/dev/null)"; then
  :
elif [ -n "$requested_profile" ] || [ -n "$(tmux_revive_default_profile_name)" ]; then
  printf 'tmux-revive: profile not found: %s\n' "${requested_profile:-$(tmux_revive_default_profile_name)}" >&2
  exit 1
fi

if [ -n "$profile_path" ] && [ "$explicit_attach" != "true" ] && [ "$explicit_no_attach" != "true" ]; then
  if [ "$(tmux_revive_profile_read_bool "$profile_path" "attach" "false")" = "true" ]; then
    attach_after_restore="true"
    no_attach="false"
  else
    attach_after_restore="false"
    no_attach="true"
  fi
fi

if [ "$dump_items" != "true" ] && ! command -v fzf >/dev/null 2>&1; then
  printf '%s\n' 'tmux-revive: fzf is required for choose-snapshot.sh' >&2
  exit 1
fi

tmux_revive_fzf_colors

header_text() {
  printf '=== %s ===' "$1"
}

build_snapshot_items() {
  local snapshots_root
  snapshots_root="$(tmux_revive_snapshots_root)"
  [ -d "$snapshots_root" ] || return 0

  find "$snapshots_root" -type f -name manifest.json | sort -r | while IFS= read -r manifest_path; do
    [ -f "$manifest_path" ] || continue
    if [ "$include_imported" != "true" ] && [ "$(jq -r '(.imported // .source.imported // false)' "$manifest_path" 2>/dev/null || printf 'false')" = "true" ]; then
      continue
    fi
    jq -r --arg manifest "$manifest_path" '
      . as $doc
      | [
          $manifest,
          ($doc.last_updated // $doc.created_at // "-"),
          ($doc.reason // "-"),
          (($doc.sessions | length) | tostring),
          ($doc.active_session_name // "-"),
          (if (($doc.imported // $doc.source.imported // false)) then "imported" else "local" end),
          (
            "\u001b[38;2;187;154;247mSNAPSHOT\u001b[0m  "
            + ($doc.last_updated // $doc.created_at // "-")
            + "  \u001b[38;2;125;207;255mreason=\u001b[0m"
            + ($doc.reason // "-")
            + "  \u001b[38;2;125;207;255msessions=\u001b[0m"
            + (($doc.sessions | length) | tostring)
            + "  \u001b[38;2;125;207;255mactive=\u001b[0m"
            + ($doc.active_session_name // "-")
            + "  \u001b[38;2;125;207;255msource=\u001b[0m"
            + (if (($doc.imported // $doc.source.imported // false)) then "imported" else "local" end)
          )
        ]
      | @tsv
    ' "$manifest_path"
  done
}

if [ "$dump_items" = "true" ]; then
  build_snapshot_items
  exit 0
fi

selection_payload="$(
  build_snapshot_items |
    fzf \
      --delimiter=$'\t' \
      --with-nth=7 \
      --prompt='snapshot> ' \
      --header="$(header_text "SNAPSHOTS")" \
      --header-first \
      --footer='Enter: browse sessions  Ctrl-a: restore all  Esc: close' \
      --footer-border=top \
      --preview="bash -lc 'restore_cmd=\$1; manifest=\$2; profile=\$3; if [ -n \"\$profile\" ]; then exec \"\$restore_cmd\" --manifest \"\$manifest\" --profile \"\$profile\" --preview; fi; exec \"\$restore_cmd\" --manifest \"\$manifest\" --preview' _ $(printf '%q' "$restore_state_cmd") {1} $(printf '%q' "$profile_path")" \
      --preview-window='right:60%:wrap' \
      "${TOKYO_FZF_COLORS[@]}" \
      --expect=enter,ctrl-a \
      --print-query \
      --query="$initial_query" \
      --layout=reverse \
      --border \
      --select-1 \
      --exit-0
)" || exit 0

[ -n "$selection_payload" ] || exit 0

query="$(printf '%s\n' "$selection_payload" | sed -n '1p')"
key="$(printf '%s\n' "$selection_payload" | sed -n '2p')"
selection="$(printf '%s\n' "$selection_payload" | sed -n '3p')"
[ -n "$selection" ] || exit 0

manifest_path="$(printf '%s\n' "$selection" | cut -f1)"
[ -n "$manifest_path" ] || exit 0

forward_args=(--manifest "$manifest_path")
[ -n "$profile_path" ] && forward_args+=(--profile "$profile_path")
[ "$assume_yes" = "true" ] && forward_args+=(--yes)
[ "$attach_after_restore" = "true" ] && forward_args+=(--attach)
[ "$no_attach" = "true" ] && forward_args+=(--no-attach)
[ "$explicit_preview" = "true" ] && forward_args+=(--no-preview)
if [ -n "$cleanup_transient_session" ]; then
  forward_args+=(--cleanup-transient-session "$cleanup_transient_session")
fi

case "${key:-enter}" in
  ctrl-a)
    exec "$restore_state_cmd" "${forward_args[@]}"
    ;;
  *)
    if [ -n "$query" ]; then
      forward_args+=(--query "$query")
    fi
    exec "$choose_saved_session_cmd" "${forward_args[@]}"
    ;;
esac
