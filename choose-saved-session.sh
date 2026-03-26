#!/usr/bin/env bash
# DEPRECATED: Use pick.sh instead. Revive now handles saved session browsing
# with preview, profiles, and attach control. Kept for direct CLI use.
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TMUX_REVIVE_SCRIPT_DIR="$script_dir"
# shellcheck source=lib/parse-server-arg.sh
source "$script_dir/lib/parse-server-arg.sh"
# shellcheck source=lib/state-common.sh
source "$script_dir/lib/state-common.sh"

manifest_path=""
initial_query=""
assume_yes="false"
attach_after_restore="false"
no_attach="false"
cleanup_transient_session=""
dump_items="false"
include_archived="false"
include_archived_explicit="false"
requested_profile=""
profile_path=""
explicit_attach="false"
explicit_no_attach="false"
explicit_preview="false"

resume_session_cmd="${TMUX_REVIVE_RESUME_SESSION_CMD:-$script_dir/resume-session.sh}"
restore_state_cmd="${TMUX_REVIVE_RESTORE_STATE_CMD:-$script_dir/restore-state.sh}"

print_help() {
  cat <<'EOF'
Usage: choose-saved-session.sh [options]

Interactively choose one saved session from a snapshot and resume it.

Options:
  --help             Show this help text
  --latest           Use the latest saved manifest (default)
  --manifest PATH    Use a specific manifest path
  --query TEXT       Prefill the chooser query
  --profile NAME|PATH
                     Apply a named restore profile or explicit profile file
  --attach           Attach or switch to the restored session after restore
  --no-attach        Restore without attaching or switching
  --no-preview       Override a previewing profile and restore immediately
  --cleanup-transient-session TARGET
                     Remove a marked transient session after successful attach
  --yes              Skip collision prompt and restore what can be restored
  --dump-items       Print raw chooser rows for testing
  --include-archived Include archived saved sessions in the chooser
  --hide-archived    Hide archived saved sessions even if the profile includes them
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
    --include-archived)
      include_archived="true"
      include_archived_explicit="true"
      shift
      ;;
    --hide-archived)
      include_archived="false"
      include_archived_explicit="true"
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

if [ -n "$profile_path" ]; then
  if [ "$include_archived_explicit" != "true" ] && [ "$(tmux_revive_profile_read_bool "$profile_path" "include_archived" "false")" = "true" ]; then
    include_archived="true"
  fi
  if [ "$explicit_attach" != "true" ] && [ "$explicit_no_attach" != "true" ]; then
    if [ "$(tmux_revive_profile_read_bool "$profile_path" "attach" "false")" = "true" ]; then
      attach_after_restore="true"
      no_attach="false"
    else
      attach_after_restore="false"
      no_attach="true"
    fi
  fi
fi

if [ -z "$manifest_path" ]; then
  manifest_path="$(tmux_revive_find_latest_manifest || true)"
fi

[ -n "$manifest_path" ] || {
  printf '%s\n' 'tmux-revive: no saved snapshot found' >&2
  exit 1
}
[ -f "$manifest_path" ] || {
  printf 'tmux-revive: manifest not found: %s\n' "$manifest_path" >&2
  exit 1
}

if [ "$dump_items" != "true" ] && ! command -v fzf >/dev/null 2>&1; then
  printf '%s\n' 'tmux-revive: fzf is required for choose-saved-session.sh' >&2
  exit 1
fi

tmux_revive_fzf_colors

header_text() {
  printf '=== %s ===' "$1"
}

build_saved_session_items() {
  jq -r '
    . as $doc
    | $doc.sessions[] as $session
    | ($doc.sessions | map(select(.session_name == $session.session_name)) | length) as $name_count
    | ($session.windows | map(.window_name // "-")) as $window_names
    | ($window_names[:3] | join(", ")) as $window_preview
    | (
        if (($window_names | length) > 3)
        then ($window_preview + " +" + ((($window_names | length) - 3) | tostring))
        else $window_preview
        end
      ) as $window_summary
    | [
        $manifest,
        (
          if (($session.session_guid // "") != "")
          then "guid"
          elif $name_count == 1
          then "name"
          else "id"
          end
        ),
        (
          if (($session.session_guid // "") != "")
          then $session.session_guid
          elif $name_count == 1
          then ($session.session_name // "-")
          else ($session.session_id // "-")
          end
        ),
        (
          if (($session.session_guid // "") != "")
          then $session.session_guid
          elif (($session.session_id // "") != "")
          then "legacy:" + $session.session_id
          else "legacy"
          end
        ),
        ($session.session_name // "-"),
        ($session.tmux_session_name // $session.session_name // "-"),
        ($doc.last_updated // $doc.created_at // "-"),
        ($doc.reason // "-"),
        ($window_summary // "-"),
        (
          if (($session.session_guid // "") != "")
          then ($session.session_guid[0:8])
          elif (($session.session_id // "") != "")
          then ("legacy:" + $session.session_id)
          else "legacy"
          end
        )
      ]
    | @tsv
  ' --arg manifest "$manifest_path" "$manifest_path" | while IFS= read -r line; do
    manifest="$(printf '%s\n' "$line" | cut -f1)"
    selector_type="$(printf '%s\n' "$line" | cut -f2)"
    selector_value="$(printf '%s\n' "$line" | cut -f3)"
    selector_guid="$(printf '%s\n' "$line" | cut -f4)"
    session_name="$(printf '%s\n' "$line" | cut -f5)"
    tmux_session_name="$(printf '%s\n' "$line" | cut -f6)"
    updated_at="$(printf '%s\n' "$line" | cut -f7)"
    reason="$(printf '%s\n' "$line" | cut -f8)"
    window_summary="$(printf '%s\n' "$line" | cut -f9)"
    short_ref="$(printf '%s\n' "$line" | cut -f10)"
    [ -n "$manifest" ] || continue
    archived_state="active"
    if [ -n "$selector_guid" ] && tmux_revive_session_is_archived "$selector_guid"; then
      archived_state="archived"
      if [ "$include_archived" != "true" ]; then
        continue
      fi
    fi

    live_state="saved"
    live_badge=$'\033[38;2;158;206;106mSAVED\033[0m'
    if [ -n "$tmux_session_name" ] && tmux has-session -t "$tmux_session_name" 2>/dev/null; then
      live_state="live"
      live_badge=$'\033[38;2;224;175;104mLIVE\033[0m'
    fi

    archive_badge=""
    if [ "$archived_state" = "archived" ]; then
      archive_badge=$'  \033[38;2;187;154;247mARCHIVED\033[0m'
    fi
    display_row="$(printf '\033[38;2;187;154;247mSESSION\033[0m  %s  \033[38;2;125;207;255m[%s]\033[0m  %s  \033[38;2;125;207;255mreason=\033[0m%s  \033[38;2;125;207;255mwindows=\033[0m%s  %b%b' \
      "$session_name" "$short_ref" "$updated_at" "$reason" "$window_summary" "$live_badge" "$archive_badge")"
    if [ "$tmux_session_name" != "$session_name" ]; then
      display_row="${display_row}  "$'\033[38;2;224;175;104m'"-> ${tmux_session_name}"$'\033[0m'
    fi

    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%b\n' \
      "$manifest" \
      "$selector_type" \
      "$selector_value" \
      "$selector_guid" \
      "$session_name" \
      "$tmux_session_name" \
      "$updated_at" \
      "$reason" \
      "$window_summary" \
      "$live_state" \
      "$display_row"
  done
}

if [ "$dump_items" = "true" ]; then
  build_saved_session_items
  exit 0
fi

snapshot_timestamp="$(jq -r '.last_updated // .created_at // "-"' "$manifest_path")"
snapshot_reason="$(jq -r '.reason // "-"' "$manifest_path")"

selection_payload="$(
  build_saved_session_items |
    fzf \
      --delimiter=$'\t' \
      --with-nth=11 \
      --prompt='resume> ' \
      --header="$(header_text "SAVED SESSIONS")"$'\n'"snapshot: ${snapshot_timestamp}  reason: ${snapshot_reason}" \
      --header-first \
      --footer='Enter: resume  Esc: close' \
      --footer-border=top \
      --preview="bash -lc 'manifest=\$1; selector_type=\$2; selector_value=\$3; restore_cmd=\$4; profile=\$5; args=(--manifest \"\$manifest\" --preview); if [ -n \"\$profile\" ]; then args+=(--profile \"\$profile\"); fi; case \"\$selector_type\" in guid) exec \"\$restore_cmd\" \"\${args[@]}\" --session-guid \"\$selector_value\" ;; id) exec \"\$restore_cmd\" \"\${args[@]}\" --session-id \"\$selector_value\" ;; *) exec \"\$restore_cmd\" \"\${args[@]}\" --session-name \"\$selector_value\" ;; esac' _ {1} {2} {3} $(printf '%q' "$restore_state_cmd") $(printf '%q' "$profile_path")" \
      --preview-window='right:60%:wrap' \
      "${TOKYO_FZF_COLORS[@]}" \
      --select-1 \
      --exit-0 \
      --query="$initial_query" \
      --layout=reverse \
      --border
)" || exit 0

[ -n "$selection_payload" ] || exit 0

selector_type="$(printf '%s\n' "$selection_payload" | cut -f2)"
selector_value="$(printf '%s\n' "$selection_payload" | cut -f3)"
[ -n "$selector_type" ] || exit 0
[ -n "$selector_value" ] || exit 0

resume_args=()
if [ -n "$manifest_path" ]; then
  resume_args+=(--manifest "$manifest_path")
fi
if [ -n "$profile_path" ]; then
  resume_args+=(--profile "$profile_path")
fi
if [ "$attach_after_restore" = "true" ]; then
  resume_args+=(--attach)
fi
if [ "$no_attach" = "true" ]; then
  resume_args+=(--no-attach)
fi
if [ -n "$cleanup_transient_session" ]; then
  resume_args+=(--cleanup-transient-session "$cleanup_transient_session")
fi
if [ "$assume_yes" = "true" ]; then
  resume_args+=(--yes)
fi
if [ "$explicit_preview" = "true" ]; then
  resume_args+=(--no-preview)
fi

case "$selector_type" in
  guid)
    exec "$resume_session_cmd" "${resume_args[@]}" --guid "$selector_value"
    ;;
  id)
    exec "$resume_session_cmd" "${resume_args[@]}" --id "$selector_value"
    ;;
  *)
    exec "$resume_session_cmd" "${resume_args[@]}" --name "$selector_value"
    ;;
esac
