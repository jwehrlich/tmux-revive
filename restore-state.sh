#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TMUX_REVIVE_SCRIPT_DIR="$script_dir"
# shellcheck source=lib/parse-server-arg.sh
source "$script_dir/lib/parse-server-arg.sh"
# shellcheck source=lib/state-common.sh
source "$script_dir/lib/state-common.sh"

manifest_path=""
assume_yes="false"
list_manifests="false"
preview_only="false"
explicit_preview="false"
explicit_attach="false"
explicit_no_attach="false"
requested_profile=""
profile_path=""
filter_session_guid=""
filter_session_id=""
filter_session_name=""
attach_after_restore="false"
disable_attach="false"
report_client_tty=""
cleanup_transient_session=""
restore_log_root="$(tmux_revive_restore_logs_root)"
latest_restore_report_path="$(tmux_revive_latest_restore_report_path)"
restore_log_path=""
latest_restore_log_path=""
transient_cleanup_complete="false"
restore_prompt_suppressed_path="$(tmux_revive_restore_prompt_suppressed_path)"

print_help() {
  cat <<'EOF'
Usage: restore-state.sh [options]

Restore tmux sessions from a saved snapshot manifest.

Options:
  --help                 Show this help text
  --latest               Restore from the latest saved manifest (default)
  --manifest PATH        Restore from a specific manifest path
  --list                 List sessions in the latest saved manifest
  --preview              Show the restore plan and exit without restoring
  --no-preview           Override a previewing profile and restore immediately
  --profile NAME|PATH    Apply a named restore profile or explicit profile file
  --session-guid GUID    Restore only the saved session matching GUID
  --session-id ID        Restore only the saved session matching legacy tmux session ID
  --session-name NAME    Restore only the saved session matching NAME
  --attach               Attach to the restored session after restore completes
  --no-attach            Restore without attaching or switching to the restored session
  --report-client-tty TTY
                         Internal: show the restore report popup on a specific client tty
  --cleanup-transient-session TARGET
                         Remove a marked transient session after successful attach or switch
  --yes                  Skip collision prompt and restore what can be restored
  --reset-restore-prompt Clear the restore-prompt suppression so the next attach re-prompts
  --server NAME          Target a specific tmux server (equivalent to tmux -L NAME)

Notes:
  - --list only shows the latest saved manifest.
  - If --manifest is not provided, the latest saved manifest is used automatically.
  - --session-guid, --session-id, and --session-name are mutually exclusive.
  - --session-name only works when that label is unique within the selected snapshot.
  - --attach is intended for shell usage outside tmux.
  - --no-attach suppresses both tmux client switching and shell attach behavior.
  - Existing tmux sessions are never overwritten; they are skipped.

Examples:
  restore-state.sh --list
  restore-state.sh --yes
  restore-state.sh --session-name work --attach --yes
  restore-state.sh --session-name work --no-attach --yes
  restore-state.sh --session-guid 123e4567-e89b-12d3-a456-426614174000 --yes
  restore-state.sh --session-id '$1' --yes
  restore-state.sh --session-name work --yes
  restore-state.sh --manifest /path/to/manifest.json --session-guid 123e4567-e89b-12d3-a456-426614174000 --yes
EOF
}

tmux_notice() {
  local message="$1"
  printf '%s\n' "$message" >&2
  tmux display-message "$message" >/dev/null 2>&1 || true
}

cleanup_restore_runtime() {
  tmux_revive_clear_runtime_flag "$restore_prompt_suppressed_path"
  if [ -n "$cleanup_transient_session" ] && [ "$transient_cleanup_complete" != "true" ]; then
    tmux_revive_clear_transient_session_marker "$cleanup_transient_session"
  fi
}

tmux_revive_mark_runtime_flag "$restore_prompt_suppressed_path"
trap cleanup_restore_runtime EXIT

init_restore_log() {
  local timestamp
  timestamp="$(date -u +%Y-%m-%dT%H-%M-%SZ)"
  mkdir -p "$restore_log_root"
  restore_log_path="$restore_log_root/restore-${timestamp}-$$.log"
  latest_restore_log_path="$restore_log_root/latest-restore.log"
  : >"$restore_log_path"
  # Create latest-restore.log as a hardlink so both paths see the same content
  ln -f "$restore_log_path" "$latest_restore_log_path" 2>/dev/null \
    || cp "$restore_log_path" "$latest_restore_log_path" >/dev/null 2>&1 || true
}

log_restore_event() {
  local message="$1"
  [ -n "$restore_log_path" ] || return 0
  printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$message" >>"$restore_log_path"
}

format_session_ref() {
  local session_name="$1"
  local session_guid="$2"
  local tmux_session_name="$3"
  local session_id="${4:-}"
  local guid_short
  guid_short="$(printf '%s\n' "$session_guid" | tr -d '-' | cut -c1-8)"
  if [ -z "$guid_short" ]; then
    if [ -n "$session_id" ]; then
      guid_short="legacy:${session_id}"
    else
      guid_short="legacy"
    fi
  fi
  if [ -n "$tmux_session_name" ] && [ "$tmux_session_name" != "$session_name" ]; then
    printf '%s[%s]->%s\n' "$session_name" "$guid_short" "$tmux_session_name"
  else
    printf '%s[%s]\n' "$session_name" "$guid_short"
  fi
}

while [ $# -gt 0 ]; do
  case "$1" in
    --help|-h)
      print_help
      exit 0
      ;;
    --list)
      list_manifests="true"
      shift
      ;;
    --preview)
      preview_only="true"
      explicit_preview="true"
      shift
      ;;
    --no-preview)
      preview_only="false"
      explicit_preview="true"
      shift
      ;;
    --profile)
      requested_profile="${2:-}"
      shift
      if [ -z "$requested_profile" ]; then
        printf '%s\n' 'restore-state.sh: --profile requires a value' >&2
        exit 1
      fi
      shift
      ;;
    --session-guid)
      filter_session_guid="${2:?--session-guid requires a value}"
      shift 2
      ;;
    --latest)
      shift
      ;;
    --manifest)
      manifest_path="${2:-}"
      shift 2
      ;;
    --session-id)
      filter_session_id="${2:?--session-id requires a value}"
      shift 2
      ;;
    --session-name)
      filter_session_name="${2:-}"
      shift 2
      ;;
    --attach)
      attach_after_restore="true"
      disable_attach="false"
      explicit_attach="true"
      explicit_no_attach="false"
      shift
      ;;
    --no-attach)
      disable_attach="true"
      attach_after_restore="false"
      explicit_no_attach="true"
      explicit_attach="false"
      shift
      ;;
    --report-client-tty)
      report_client_tty="${2:-}"
      shift 2
      ;;
    --cleanup-transient-session)
      cleanup_transient_session="${2:-}"
      shift 2
      ;;
    --yes)
      assume_yes="true"
      shift
      ;;
    --reset-restore-prompt)
      tmux_revive_clear_runtime_flag "$restore_prompt_suppressed_path"
      tmux_revive_clear_runtime_flag "$(tmux_revive_restore_prompt_shown_path)"
      tmux_revive_clear_runtime_flag "$(tmux_revive_last_prompted_manifest_path)"
      printf 'restore prompt reset — next client attach will re-prompt\n'
      exit 0
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
  if [ "$explicit_preview" != "true" ] && [ "$(tmux_revive_profile_read_bool "$profile_path" "preview" "false")" = "true" ]; then
    preview_only="true"
  fi
  if [ "$explicit_attach" != "true" ] && [ "$explicit_no_attach" != "true" ]; then
    if [ "$(tmux_revive_profile_read_bool "$profile_path" "attach" "false")" = "true" ]; then
      attach_after_restore="true"
      disable_attach="false"
    else
      attach_after_restore="false"
      disable_attach="true"
    fi
  fi
fi

selector_count=0
[ -n "$filter_session_guid" ] && selector_count=$((selector_count + 1))
[ -n "$filter_session_id" ] && selector_count=$((selector_count + 1))
[ -n "$filter_session_name" ] && selector_count=$((selector_count + 1))
if [ "$selector_count" -gt 1 ]; then
  tmux_notice 'tmux-revive: use only one of --session-guid, --session-id, or --session-name'
  exit 1
fi

session_selector_jq='(($sguid == "") or ((.session_guid // "") == $sguid)) and (($sid == "") or ((.session_id // "") == $sid)) and (($sname == "") or (.session_name == $sname))'
manifest_has_any_guid='[.sessions[]? | select((.session_guid // "") != "")] | length > 0'

manifest_summary_line() {
  local manifest="$1"
  jq -r \
    --arg sguid "$filter_session_guid" \
    --arg sid "$filter_session_id" \
    --arg sname "$filter_session_name" \
    '. as $doc
      | $doc.sessions[]?
      | select('"$session_selector_jq"')
      | [
          (
            if ((.session_guid // "") != "")
            then .session_guid
            elif ((.session_id // "") != "")
            then "legacy:" + .session_id
            else "legacy"
            end
          ),
          .session_name,
          ($doc.last_updated // $doc.created_at // "-")
        ]
      | @tsv' \
    "$manifest"
}

print_list_table() {
  local manifest="$1"
  local header_id="SESSION_GUID"
  local header_name="SESSION_NAME"
  local header_manifest="LAST_UPDATED"
  local id_width="${#header_id}"
  local name_width="${#header_name}"
  local manifest_width="${#header_manifest}"
  local line session_id session_name last_updated
  local rows=()

  while IFS= read -r line; do
    [ -n "$line" ] || continue
    rows+=("$line")
    IFS=$'\t' read -r session_id session_name last_updated <<EOF
$line
EOF
    [ "${#session_id}" -gt "$id_width" ] && id_width="${#session_id}"
    [ "${#session_name}" -gt "$name_width" ] && name_width="${#session_name}"
    [ "${#last_updated}" -gt "$manifest_width" ] && manifest_width="${#last_updated}"
  done < <(manifest_summary_line "$manifest")

  printf "%-*s  %-*s  %s\n" "$id_width" "$header_id" "$name_width" "$header_name" "$header_manifest"

  for line in "${rows[@]}"; do
    IFS=$'\t' read -r session_id session_name last_updated <<EOF
$line
EOF
    printf "%-*s  %-*s  %s\n" "$id_width" "$session_id" "$name_width" "$session_name" "$last_updated"
  done
}

find_manifest_for_selected_session() {
  local candidate=""
  local snapshots_root

  snapshots_root="$(tmux_revive_snapshots_root)"
  [ -d "$snapshots_root" ] || return 1

  while IFS= read -r candidate; do
    [ -n "$candidate" ] || continue
    [ -f "$candidate" ] || continue
    if jq -e \
      --arg sguid "$filter_session_guid" \
      --arg sid "$filter_session_id" \
      --arg sname "$filter_session_name" \
      '[.sessions[]? | select('"$session_selector_jq"')] | length > 0' \
      "$candidate" >/dev/null 2>&1; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done < <(find "$snapshots_root" -type f -name manifest.json | sort -r)

  return 1
}

find_newest_manifest_on_disk() {
  local snapshots_root
  snapshots_root="$(tmux_revive_snapshots_root)"
  [ -d "$snapshots_root" ] || return 1
  find "$snapshots_root" -type f -name manifest.json | sort -r | head -n 1
}

json_array_from_args() {
  if [ "$#" -eq 0 ]; then
    printf '[]\n'
    return 0
  fi

  printf '%s\n' "$@" | jq -Rsc 'split("\n")[:-1]'
}

build_restore_plan_json() {
  local attach_target="$1"
  local created_at reason snapshot_host active_session_name
  local pos session_idx session_name session_guid session_id tmux_session_name session_group
  local collision_names=()
  local restorable_refs=()
  local skipped_refs=()
  local unsupported_refs=()
  local restore_refs_json='[]'
  local skipped_refs_json='[]'
  local unsupported_refs_json='[]'
  local health_warnings_json='[]'

  if [ "${existing_collisions+set}" = "set" ]; then
    collision_names=("${existing_collisions[@]}")
  fi

  created_at="$(jq -r '.last_updated // .created_at // ""' "$manifest_path")"
  reason="$(jq -r '.reason // ""' "$manifest_path")"
  snapshot_host="$(jq -r '.host // ""' "$manifest_path")"
  active_session_name="$(jq -r '.active_session_name // ""' "$manifest_path")"

  for pos in "${!session_indexes[@]}"; do
    session_idx="${session_indexes[$pos]}"
    session_name="${resolved_session_names[$pos]}"
    session_guid="${resolved_session_guids[$pos]}"
    session_id="${resolved_session_ids[$pos]}"
    tmux_session_name="${resolved_restore_names[$pos]}"
    session_group="$(jq -r ".sessions[$session_idx].session_group // \"\"" "$manifest_path")"

    if [ -n "$session_group" ] && [ "$session_group" != "$tmux_session_name" ]; then
      # Grouped session follower — will be created via new-session -t after its leader
      unsupported_refs+=("$(format_session_ref "$session_name" "$session_guid" "$tmux_session_name" "$session_id")")
    elif [ "${#collision_names[@]}" -gt 0 ] && name_in_array "$tmux_session_name" "${collision_names[@]}"; then
      skipped_refs+=("$(format_session_ref "$session_name" "$session_guid" "$tmux_session_name" "$session_id")")
    else
      restorable_refs+=("$(format_session_ref "$session_name" "$session_guid" "$tmux_session_name" "$session_id")")
    fi
  done

  if [ "${#restorable_refs[@]}" -gt 0 ]; then
    restore_refs_json="$(json_array_from_args "${restorable_refs[@]}")"
  fi
  if [ "${#skipped_refs[@]}" -gt 0 ]; then
    skipped_refs_json="$(json_array_from_args "${skipped_refs[@]}")"
  fi
  if [ "${#unsupported_refs[@]}" -gt 0 ]; then
    unsupported_refs_json="$(json_array_from_args "${unsupported_refs[@]}")"
  fi
  if [ "${#restore_health_warning_refs[@]}" -gt 0 ]; then
    health_warnings_json="$(json_array_from_args "${restore_health_warning_refs[@]}")"
  fi

  jq -n \
    --arg manifest_path "$manifest_path" \
    --arg created_at "$created_at" \
    --arg reason "$reason" \
    --arg snapshot_host "$snapshot_host" \
    --arg active_session_name "$active_session_name" \
    --arg attach_target "$attach_target" \
    --argjson restore_refs "$restore_refs_json" \
    --argjson skipped_refs "$skipped_refs_json" \
    --argjson unsupported_refs "$unsupported_refs_json" \
    --argjson health_warnings "$health_warnings_json" \
    '{
      snapshot: {
        manifest_path: $manifest_path,
        created_at: $created_at,
        reason: $reason,
        host: $snapshot_host,
        active_session_name: $active_session_name
      },
      attach_target: $attach_target,
      restore: $restore_refs,
      skipped_existing: $skipped_refs,
      grouped_issues: $unsupported_refs,
      health_warnings: $health_warnings,
      counts: {
        restore: ($restore_refs | length),
        skipped_existing: ($skipped_refs | length),
        grouped_issues: ($unsupported_refs | length),
        health_warnings: ($health_warnings | length)
      }
    }'
}

print_restore_plan_text() {
  local plan_json="$1"

  jq -r '
    def section($title; $items):
      [($title + " (" + (($items | length) | tostring) + "):")]
      + (if ($items | length) > 0 then ($items | map("- " + .)) else ["- none"] end);

    [
      "tmux-revive restore preview",
      "",
      ("Snapshot: " + (.snapshot.created_at // "-")),
      ("Reason: " + ((.snapshot.reason // "") | if . == "" then "-" else . end)),
      ("Manifest: " + (.snapshot.manifest_path // "-")),
      ("Host: " + ((.snapshot.host // "") | if . == "" then "-" else . end)),
      ("Attach target: " + ((.attach_target // "") | if . == "" then "-" else . end)),
      ""
    ]
    + section("Will restore"; .restore)
    + [""]
    + section("Will skip existing"; .skipped_existing)
    + [""]
    + section("Grouped session issues"; .grouped_issues)
    + [""]
    + section("Health warnings"; .health_warnings)
    | .[]
  ' <<<"$plan_json"
}

format_pane_ref() {
  local session_name="$1"
  local window_name="$2"
  local pane_index="$3"
  local pane_title="${4:-}"

  if [ -n "$pane_title" ]; then
    printf '%s / %s / pane %s (%s)\n' "$session_name" "$window_name" "$pane_index" "$pane_title"
  else
    printf '%s / %s / pane %s\n' "$session_name" "$window_name" "$pane_index"
  fi
}

record_restore_fallback() {
  local session_name="$1"
  local window_name="$2"
  local pane_index="$3"
  local pane_title="$4"
  local message="$5"
  restore_fallback_refs+=("$(format_pane_ref "$session_name" "$window_name" "$pane_index" "$pane_title"): $message")
}

record_restore_health_warning() {
  local message="$1"
  restore_health_warning_refs+=("$message")
}

record_restore_pane_health_warning() {
  local session_name="$1"
  local window_name="$2"
  local pane_index="$3"
  local pane_title="$4"
  local message="$5"
  record_restore_health_warning "$(format_pane_ref "$session_name" "$window_name" "$pane_index" "$pane_title"): $message"
}

collect_nvim_health_warnings() {
  local session_name="$1"
  local window_name="$2"
  local pane_index="$3"
  local pane_title="$4"
  local nvim_state_ref="$5"
  local missing_paths=()
  local path count=0 sample_text=""

  if [ -z "$nvim_state_ref" ] || [ ! -f "$nvim_state_ref" ]; then
    record_restore_pane_health_warning "$session_name" "$window_name" "$pane_index" "$pane_title" "missing Neovim state file"
    return 0
  fi

  while IFS= read -r path; do
    [ -n "$path" ] || continue
    if [ ! -e "$path" ]; then
      missing_paths+=("$path")
      count=$((count + 1))
    fi
  done < <(jq -r '.tabs[]?.wins[]?.path // empty' "$nvim_state_ref" 2>/dev/null || true)

  if [ "$count" -gt 0 ]; then
    sample_text="$(printf '%s\n' "${missing_paths[@]:0:3}" | paste -sd ', ' -)"
    record_restore_pane_health_warning "$session_name" "$window_name" "$pane_index" "$pane_title" "Neovim state references ${count} missing file(s): ${sample_text}"
  fi
}

collect_restore_health_warnings() {
  local session_idx window_idx pane_idx
  local session_name session_guid session_id tmux_session_name session_group
  local window_name pane_title pane_cwd restore_strategy nvim_state_ref restart_command command_preview tail_target

  restore_health_warning_refs=()

  if [ "$(jq -r '.host // ""' "$manifest_path")" != "$(tmux_revive_host)" ]; then
    record_restore_health_warning "snapshot host differs from current host"
  fi
  if [ "$manifest_has_guids" != "true" ]; then
    record_restore_health_warning "legacy snapshot compatibility mode is in use"
  fi

  for session_idx in "${session_indexes[@]}"; do
    session_name="$(jq -r ".sessions[$session_idx].session_name" "$manifest_path")"
    session_guid="$(jq -r ".sessions[$session_idx].session_guid // \"\"" "$manifest_path")"
    session_id="$(jq -r ".sessions[$session_idx].session_id // \"\"" "$manifest_path")"
    tmux_session_name="$(jq -r ".sessions[$session_idx].tmux_session_name // .sessions[$session_idx].session_name // \"\"" "$manifest_path")"
    session_group="$(jq -r ".sessions[$session_idx].session_group // \"\"" "$manifest_path")"

    # Skip grouped session followers — they share windows with the leader
    [ -n "$session_group" ] && [ "$session_group" != "$tmux_session_name" ] && continue

    local window_count
    window_count=$(jq ".sessions[$session_idx].windows | length" "$manifest_path" 2>/dev/null) || window_count=0
    for ((window_idx = 0; window_idx < window_count; window_idx++)); do
      window_name="$(jq -r ".sessions[$session_idx].windows[$window_idx].window_name // \"-\"" "$manifest_path")"
      local pane_count_inner
      pane_count_inner=$(jq ".sessions[$session_idx].windows[$window_idx].panes | length" "$manifest_path" 2>/dev/null) || pane_count_inner=0
      for ((pane_idx = 0; pane_idx < pane_count_inner; pane_idx++)); do
        pane_title="$(jq -r ".sessions[$session_idx].windows[$window_idx].panes[$pane_idx].pane_title // \"\"" "$manifest_path")"
        pane_cwd="$(jq -r ".sessions[$session_idx].windows[$window_idx].panes[$pane_idx].cwd // \"\"" "$manifest_path")"
        restore_strategy="$(jq -r ".sessions[$session_idx].windows[$window_idx].panes[$pane_idx].restore_strategy // \"\"" "$manifest_path")"
        nvim_state_ref="$(jq -r ".sessions[$session_idx].windows[$window_idx].panes[$pane_idx].nvim_state_ref // \"\"" "$manifest_path")"
        restart_command="$(jq -r ".sessions[$session_idx].windows[$window_idx].panes[$pane_idx].restart_command // \"\"" "$manifest_path")"
        command_preview="$(jq -r ".sessions[$session_idx].windows[$window_idx].panes[$pane_idx].command_preview // \"\"" "$manifest_path")"

        nvim_state_ref="$(resolve_snapshot_path "$nvim_state_ref")"
        if [ -n "$pane_cwd" ] && [ ! -d "$pane_cwd" ]; then
          record_restore_pane_health_warning "$session_name" "$window_name" "$pane_idx" "$pane_title" "missing cwd: $pane_cwd"
        fi

        if [ "$restore_strategy" = "nvim" ] || [ -n "$nvim_state_ref" ]; then
          collect_nvim_health_warnings "$session_name" "$window_name" "$pane_idx" "$pane_title" "$nvim_state_ref"
        fi

        tail_target=""
        if [ -n "$restart_command" ]; then
          tail_target="$(tmux_revive_tail_target_path "$restart_command" 2>/dev/null || true)"
        elif [ -n "$command_preview" ]; then
          tail_target="$(tmux_revive_tail_target_path "$command_preview" 2>/dev/null || true)"
        fi
        if [ -n "$tail_target" ] && [ ! -e "$tail_target" ]; then
          record_restore_pane_health_warning "$session_name" "$window_name" "$pane_idx" "$pane_title" "tail target is missing: $tail_target"
        fi
      done
    done
  done
}

build_restore_result_json() {
  local attach_target="$1"
  local summary="$2"
  local created_at reason snapshot_host active_session_name
  local restored_json='[]'
  local skipped_json='[]'
  local unsupported_json='[]'
  local fallbacks_json='[]'
  local health_json='[]'

  created_at="$(jq -r '.last_updated // .created_at // ""' "$manifest_path")"
  reason="$(jq -r '.reason // ""' "$manifest_path")"
  snapshot_host="$(jq -r '.host // ""' "$manifest_path")"
  active_session_name="$(jq -r '.active_session_name // ""' "$manifest_path")"

  if [ "${#restored_session_refs[@]}" -gt 0 ]; then
    restored_json="$(json_array_from_args "${restored_session_refs[@]}")"
  fi
  if [ "${#skipped_session_refs[@]}" -gt 0 ]; then
    skipped_json="$(json_array_from_args "${skipped_session_refs[@]}")"
  fi
  if [ "${#grouped_session_refs[@]}" -gt 0 ]; then
    unsupported_json="$(json_array_from_args "${grouped_session_refs[@]}")"
  fi
  if [ "${#restore_fallback_refs[@]}" -gt 0 ]; then
    fallbacks_json="$(json_array_from_args "${restore_fallback_refs[@]}")"
  fi
  if [ "${#restore_health_warning_refs[@]}" -gt 0 ]; then
    health_json="$(json_array_from_args "${restore_health_warning_refs[@]}")"
  fi

  jq -n \
    --arg manifest_path "$manifest_path" \
    --arg created_at "$created_at" \
    --arg reason "$reason" \
    --arg snapshot_host "$snapshot_host" \
    --arg active_session_name "$active_session_name" \
    --arg attach_target "$attach_target" \
    --arg log_path "$latest_restore_log_path" \
    --arg summary "$summary" \
    --argjson restore_refs "$restored_json" \
    --argjson skipped_refs "$skipped_json" \
    --argjson unsupported_refs "$unsupported_json" \
    --argjson pane_fallbacks "$fallbacks_json" \
    --argjson health_warnings "$health_json" \
    '{
      snapshot: {
        manifest_path: $manifest_path,
        created_at: $created_at,
        reason: $reason,
        host: $snapshot_host,
        active_session_name: $active_session_name
      },
      attach_target: $attach_target,
      log_path: $log_path,
      summary: $summary,
      restore: $restore_refs,
      skipped_existing: $skipped_refs,
      grouped_issues: $unsupported_refs,
      pane_fallbacks: $pane_fallbacks,
      health_warnings: $health_warnings,
      counts: {
        restore: ($restore_refs | length),
        skipped_existing: ($skipped_refs | length),
        grouped_issues: ($unsupported_refs | length),
        pane_fallbacks: ($pane_fallbacks | length),
        health_warnings: ($health_warnings | length)
      }
    }'
}

write_restore_report() {
  local report_json="$1"
  mkdir -p "$(dirname "$latest_restore_report_path")"
  printf '%s\n' "$report_json" >"$latest_restore_report_path"
}

maybe_show_restore_report_popup() {
  local report_path="$1"
  local popup_cmd
  local viewer_cmd=("$script_dir/show-restore-report.sh" --report "$report_path")

  popup_cmd="$(printf '%q ' "${viewer_cmd[@]}")"

  if [ -n "$report_client_tty" ]; then
    tmux display-popup -t "$report_client_tty" -E -w 75% -h 65% "$popup_cmd" >/dev/null 2>&1 || true
    return 0
  fi

  if [ -n "${TMUX:-}" ] && tmux display-message -p '#{client_tty}' >/dev/null 2>&1; then
    tmux display-popup -E -w 75% -h 65% "$popup_cmd" >/dev/null 2>&1 || true
  fi
}

if [ "$list_manifests" = "true" ]; then
  listed_manifest="$(tmux_revive_find_latest_manifest || true)"
  if [ -z "$listed_manifest" ]; then
    listed_manifest="$(find_newest_manifest_on_disk || true)"
  fi

  [ -n "$listed_manifest" ] || exit 0
  [ -f "$listed_manifest" ] || exit 0
  print_list_table "$listed_manifest"
  exit 0
fi

if [ -z "$manifest_path" ]; then
  manifest_path="$(tmux_revive_find_latest_manifest || true)"
  if [ -z "$manifest_path" ]; then
    manifest_path="$(find_newest_manifest_on_disk || true)"
  fi
  if [ -n "$manifest_path" ] && [ -f "$manifest_path" ] && [ "$selector_count" -gt 0 ]; then
    if ! jq -e \
      --arg sguid "$filter_session_guid" \
      --arg sid "$filter_session_id" \
      --arg sname "$filter_session_name" \
      '[.sessions[]? | select('"$session_selector_jq"')] | length > 0' \
      "$manifest_path" >/dev/null 2>&1; then
      manifest_path="$(find_manifest_for_selected_session || true)"
    fi
  elif [ "$selector_count" -gt 0 ]; then
    manifest_path="$(find_manifest_for_selected_session || true)"
  fi
fi

init_restore_log

# E3: Validate manifest schema version
if [ -n "$manifest_path" ] && [ -f "$manifest_path" ]; then
  _manifest_version="$(jq -r '.snapshot_version // ""' "$manifest_path" 2>/dev/null || printf '')"
  if [ -z "$_manifest_version" ]; then
    printf 'tmux-revive: warning: manifest has no snapshot_version field — assuming compatible\n' >&2
  elif [ "$_manifest_version" != "1" ]; then
    printf 'tmux-revive: error: unsupported manifest version "%s" (expected "1")\n' "$_manifest_version" >&2
    printf 'This snapshot was created by a newer version of tmux-revive.\n' >&2
    printf 'Please update tmux-revive and try again.\n' >&2
    exit 1
  fi
fi

is_imported_snapshot="false"
if [ -n "$manifest_path" ] && [ -f "$manifest_path" ] && jq -e '.imported == true' "$manifest_path" >/dev/null 2>&1; then
  is_imported_snapshot="true"
fi

is_template="false"
if [ -n "$manifest_path" ] && [ -f "$manifest_path" ] && jq -e '.source_type == "template"' "$manifest_path" >/dev/null 2>&1; then
  is_template="true"
fi

run_restore_hook() {
  local option_name="$1"
  local env_name="$2"
  shift || true
  shift || true
  tmux_revive_run_hook "$env_name" "$option_name" \
    "TMUX_REVIVE_HOOK_EVENT=restore" \
    "TMUX_REVIVE_HOOK_MANIFEST_PATH=$manifest_path" \
    "$@"
}

append_restore_log_path() {
  local summary="$1"
  if [ -n "$latest_restore_log_path" ]; then
    printf '%s; log: %s\n' "$summary" "$latest_restore_log_path"
  else
    printf '%s\n' "$summary"
  fi
}

run_post_restore_hook() {
  local attach_target="$1"
  local restored_count="$2"
  local report_path="$3"
  run_restore_hook "$(tmux_revive_post_restore_hook_option)" "TMUX_REVIVE_POST_RESTORE_HOOK" \
    "TMUX_REVIVE_HOOK_ATTACH_TARGET=$attach_target" \
    "TMUX_REVIVE_HOOK_RESTORED_COUNT=$restored_count" \
    "TMUX_REVIVE_HOOK_RESTORE_LOG=$latest_restore_log_path" \
    "TMUX_REVIVE_HOOK_RESTORE_REPORT=$report_path" || true
}

maybe_switch_restore_target() {
  local attach_target="$1"
  if [ "$disable_attach" != "true" ] && [ -n "${TMUX:-}" ] && tmux display-message -p '#{client_tty}' >/dev/null 2>&1; then
    tmux has-session -t "=$attach_target" >/dev/null 2>&1 && tmux switch-client -t "=$attach_target" >/dev/null 2>&1 || true
  fi
}

maybe_cleanup_transient_session() {
  local attach_target="$1"

  [ -n "$cleanup_transient_session" ] || return 0

  if ! tmux_revive_session_is_transient "$cleanup_transient_session"; then
    transient_cleanup_complete="true"
    return 0
  fi

  if [ "$cleanup_transient_session" = "$attach_target" ]; then
    tmux_revive_clear_transient_session_marker "$cleanup_transient_session"
    transient_cleanup_complete="true"
    return 0
  fi

  tmux kill-session -t "=$cleanup_transient_session" >/dev/null 2>&1 || tmux_revive_clear_transient_session_marker "$cleanup_transient_session"
  transient_cleanup_complete="true"
}

maybe_attach_restore_target() {
  local attach_target="$1"
  if [ "$disable_attach" != "true" ] && [ "$attach_after_restore" = "true" ] && [ -z "${TMUX:-}" ]; then
    exec tmux attach-session -t "=$attach_target"
  fi
}

finish_restore_success() {
  local attach_target="$1"
  local restored_count="$2"
  local summary="$3"
  local report_json report_path

  report_json="$(build_restore_result_json "$attach_target" "$summary")"
  write_restore_report "$report_json"
  report_path="$latest_restore_report_path"

  run_post_restore_hook "$attach_target" "$restored_count" "$report_path"

  # Restore pane shortcuts from the manifest
  if [ -n "$manifest_path" ] && [ -f "$manifest_path" ]; then
    "$script_dir/pane-shortcut.sh" --load-from-manifest "$manifest_path" 2>/dev/null || true
  fi

  tmux_notice "$(append_restore_log_path "$summary")"
  maybe_cleanup_transient_session "$attach_target"
  maybe_show_restore_report_popup "$report_path"
  maybe_attach_restore_target "$attach_target"
}

restore_pane_target() {
  local restored_pane_id="$1"
  local pane_cwd="$2"
  local restore_strategy="$3"
  local transcript_path="$4"
  local command_preview="$5"
  local restart_command="$6"
  local nvim_state_ref="$7"

  case "$restore_strategy" in
    nvim)
      send_nvim_restore_command "$restored_pane_id" "$pane_cwd" "$nvim_state_ref"
      ;;
    manual-command)
      restore_manual_command "$restored_pane_id" "$pane_cwd" "$transcript_path" "$command_preview" "$command_preview"
      ;;
    restart-command)
      restore_restart_command "$restored_pane_id" "$pane_cwd" "$transcript_path" "$restart_command" "$command_preview"
      ;;
    history_only)
      start_restored_shell "$restored_pane_id" "$pane_cwd" "$transcript_path" "" run ":"
      ;;
    *)
      start_restored_shell "$restored_pane_id" "$pane_cwd" "$transcript_path" "" run ":"
      ;;
  esac
}

[ -n "$manifest_path" ] || {
  tmux_notice "tmux-revive: no saved snapshot found (state root: $(tmux_revive_state_root); latest pointer: $(tmux_revive_latest_path))"
  exit 1
}
[ -f "$manifest_path" ] || {
  tmux_notice "tmux-revive: manifest not found: $manifest_path"
  exit 1
}
if ! jq empty "$manifest_path" 2>/dev/null; then
  tmux_notice "tmux-revive: manifest is corrupted or unreadable: $manifest_path"
  exit 1
fi

manifest_dir="$(dirname "$manifest_path")"
manifest_has_guids="$(jq -r "$manifest_has_any_guid" "$manifest_path")"

selected_session_name=""
selected_tmux_session_name=""
session_indexes=()
while IFS= read -r session_idx; do
  [ -n "$session_idx" ] || continue
  session_indexes+=("$session_idx")
done < <(
  jq -r \
    --arg sguid "$filter_session_guid" \
    --arg sid "$filter_session_id" \
    --arg sname "$filter_session_name" \
    ".sessions | to_entries[] | select(.value | $session_selector_jq) | .key" \
    "$manifest_path"
)

selected_session_name="$(jq -r \
  --arg sguid "$filter_session_guid" \
  --arg sid "$filter_session_id" \
  --arg sname "$filter_session_name" \
  ".sessions[] | select($session_selector_jq) | .session_name" \
  "$manifest_path" | head -n 1)"

selected_tmux_session_name="$(jq -r \
  --arg sguid "$filter_session_guid" \
  --arg sid "$filter_session_id" \
  --arg sname "$filter_session_name" \
  ".sessions[] | select($session_selector_jq) | (.tmux_session_name // .session_name)" \
  "$manifest_path" | head -n 1)"

if [ -n "$filter_session_name" ]; then
  matched_name_count="$(jq -r \
    --arg sguid "$filter_session_guid" \
    --arg sid "$filter_session_id" \
    --arg sname "$filter_session_name" \
    "[.sessions[] | select($session_selector_jq)] | length" \
    "$manifest_path")"
  if [ "${matched_name_count:-0}" -gt 1 ]; then
    if [ "$manifest_has_guids" = "true" ]; then
      tmux_notice "tmux-revive: multiple saved sessions matched session name: $filter_session_name; use --session-guid"
    else
      tmux_notice "tmux-revive: legacy snapshot has multiple sessions named $filter_session_name; use --session-id or take a fresh save"
    fi
    exit 1
  fi
fi

if [ "${#session_indexes[@]}" -eq 0 ]; then
  if [ -n "$filter_session_guid" ]; then
    if [ "$manifest_has_guids" = "true" ]; then
      tmux_notice "tmux-revive: no saved session matched session guid: $filter_session_guid"
    else
      tmux_notice 'tmux-revive: restore-by-GUID is unavailable for this legacy snapshot; take a fresh save first'
    fi
  elif [ -n "$filter_session_id" ]; then
    tmux_notice "tmux-revive: no saved session matched session id: $filter_session_id"
  elif [ -n "$filter_session_name" ]; then
    tmux_notice "tmux-revive: no saved session matched session name: $filter_session_name"
  else
    tmux_notice "tmux-revive: manifest contained no sessions: $manifest_path"
  fi
  exit 1
fi

send_shell_command() {
  local pane_target="$1"
  shift
  local command="$*"
  tmux send-keys -t "$pane_target" "$command" C-m
}

send_warning() {
  local pane_target="$1"
  local message="$2"
  local escaped
  escaped="$(printf '%q' "$message")"
  send_shell_command "$pane_target" "printf '%s\n' $escaped"
}

send_restore_status() {
  local pane_target="$1"
  local message="$2"
  send_warning "$pane_target" "tmux-revive: $message"
}

preload_shell_command() {
  local pane_target="$1"
  local command="$2"

  [ -n "$command" ] || return 0
  tmux send-keys -t "$pane_target" -l -- "$command"
}

resolve_creation_cwd() {
  local requested_cwd="${1:-}"

  if [ -n "$requested_cwd" ] && [ -d "$requested_cwd" ]; then
    printf '%s\n' "$requested_cwd"
    return 0
  fi

  if [ -n "${HOME:-}" ] && [ -d "$HOME" ]; then
    printf '%s\n' "$HOME"
    return 0
  fi

  pwd -P
}

start_restored_shell() {
  local pane_target="$1"
  local pane_cwd="$2"
  local transcript_path="$3"
  local filter_line="${4:-}"
  local start_mode="${5:-shell}"
  local command_to_run="${6:-}"
  shift 6 || true
  local shell_bin="${SHELL:-/bin/sh}"
  local command=()
  local extra_args=("$@")
  local creation_cwd=""

  transcript_path="$(resolve_snapshot_path "$transcript_path")"
  creation_cwd="$(resolve_creation_cwd "$pane_cwd")"

  command+=("$script_dir/start-restored-pane.sh")
  command+=(--mode "$start_mode")
  command+=(--cwd "$pane_cwd")
  command+=(--shell "$shell_bin")
  if [ -n "$transcript_path" ]; then
    command+=(--transcript "$transcript_path")
  fi
  if [ -n "$filter_line" ]; then
    command+=(--filter-line "$filter_line")
  fi
  if [ -n "$command_to_run" ]; then
    command+=(--command "$command_to_run")
  fi
  if [ "${#extra_args[@]}" -gt 0 ]; then
    command+=("${extra_args[@]}")
  fi

  tmux respawn-pane -k -t "$pane_target" -c "$creation_cwd" "$(printf '%q ' "${command[@]}")"
}

send_nvim_restore_command() {
  local pane_target="$1"
  local pane_cwd="$2"
  local nvim_state_ref="$3"
  local nvim_bin=""
  local nvim_command=""

  nvim_bin="$(command -v nvim 2>/dev/null || true)"
  [ -n "$nvim_bin" ] || nvim_bin="nvim"
  nvim_command="$(printf '%q' "$nvim_bin")"

  if [ -n "$nvim_state_ref" ] && [ -f "$nvim_state_ref" ]; then
    nvim_command="TMUX_NVIM_RESTORE_STATE=$(printf '%q' "$nvim_state_ref") $nvim_command"
    start_restored_shell "$pane_target" "$pane_cwd" "" "" run "$nvim_command"
  else
    start_restored_shell "$pane_target" "$pane_cwd" "" "" run "$nvim_command"
  fi
}

resolve_snapshot_path() {
  local saved_path="$1"
  local snapshot_name legacy_path

  [ -n "$saved_path" ] || {
    printf '\n'
    return 0
  }

  if [ -f "$saved_path" ]; then
    printf '%s\n' "$saved_path"
    return 0
  fi

  snapshot_name="$(basename "$manifest_dir")"
  # Escape regex metacharacters in snapshot_name before interpolating into sed
  local escaped_name
  escaped_name="$(printf '%s\n' "$snapshot_name" | sed 's/[.[\*^$()+?{|\\]/\\&/g')"
  legacy_path="$(printf '%s\n' "$saved_path" | sed -E "s#/\\.${escaped_name}\\.tmp\\.[^/]+#/${snapshot_name}#")"
  if [ "$legacy_path" != "$saved_path" ] && [ -f "$legacy_path" ]; then
    printf '%s\n' "$legacy_path"
    return 0
  fi

  printf '%s\n' "$saved_path"
}

restore_manual_command() {
  local pane_target="$1"
  local pane_cwd="$2"
  local transcript_path="$3"
  local preview="$4"
  local preview_to_load="$5"

  start_restored_shell "$pane_target" "$pane_cwd" "$transcript_path" "$preview" run ":"
  if [ -n "$preview_to_load" ]; then
    preload_shell_command "$pane_target" "$preview_to_load"
  fi
}

restore_restart_command() {
  local pane_target="$1"
  local pane_cwd="$2"
  local transcript_path="$3"
  local restart_command="$4"
  local command_preview="$5"

  if [ -n "$restart_command" ] && \
     { [ "$is_template" = "true" ] || tmux_revive_command_is_restartable "$restart_command"; }; then
    local resolved_command
    resolved_command="$(tmux_revive_resolve_restart_command "$restart_command")"
    start_restored_shell "$pane_target" "$pane_cwd" "$transcript_path" "$restart_command" run "$resolved_command"
    return 0
  fi

  restore_manual_command "$pane_target" "$pane_cwd" "$transcript_path" "${restart_command:-$command_preview}" "${restart_command:-$command_preview}"
}

create_restore_session() {
  local tmux_session_name="$1"
  local first_window_name="$2"
  local first_window_creation_cwd="$3"

  local created_session_info=""
  if ! created_session_info="$(tmux new-session -d -P -F $'#{session_id}\t#{window_index}' -s "$tmux_session_name" -n "$first_window_name" -c "$first_window_creation_cwd")"; then
    return 1
  fi

  printf '%s\n' "$created_session_info"
}

restore_saved_panes_for_window() {
  local session_idx="$1"
  local window_idx="$2"
  local tmux_session_name="$3"
  local window_index="$4"
  local window_target="$5"
  local pane_count="$6"
  local window_layout="$7"
  local active_pane_index="$8"
  local session_name="$9"
  local window_name="${10}"

  local pane_idx pane_cwd pane_creation_cwd actual_pane_count
  local restored_pane_index restored_pane_id pane_title restore_strategy transcript_path command_preview restart_command nvim_state_ref active_pane_target

  for ((pane_idx = 1; pane_idx < pane_count; pane_idx++)); do
    pane_cwd="$(jq -r ".sessions[$session_idx].windows[$window_idx].panes[$pane_idx].cwd // env.HOME" "$manifest_path")"
    pane_creation_cwd="$(resolve_creation_cwd "$pane_cwd")"
    local _split_timeout
    _split_timeout="$(tmux_revive_get_global_option '@tmux-revive-pane-restore-timeout' '30')"
    case "$_split_timeout" in ''|*[!0-9]*) _split_timeout=30 ;; esac

    # Build the tmux command with explicit server flag so that
    # subprocesses (perl alarm wrapper) target the correct server.
    local -a _tmux_split_cmd=(tmux)
    if [ -n "${TMUX_REVIVE_TMUX_SERVER:-}" ]; then
      _tmux_split_cmd=(tmux -L "$TMUX_REVIVE_TMUX_SERVER")
    fi
    _tmux_split_cmd+=(split-window -d -t "$window_target" -c "$pane_creation_cwd")

    local _split_ok=false
    if command -v perl >/dev/null 2>&1; then
      # Use perl alarm for portable timeout (exec bypasses bash functions,
      # so we must include -L in the command array explicitly)
      if perl -e 'alarm shift; exec @ARGV' "$_split_timeout" \
           "${_tmux_split_cmd[@]}" 2>/dev/null; then
        _split_ok=true
      fi
    else
      # Fallback: no timeout available, run directly
      if "${_tmux_split_cmd[@]}"; then
        _split_ok=true
      fi
    fi

    if [ "$_split_ok" = true ]; then
      log_restore_event "pane-split-ok session=$tmux_session_name window_index=$window_index pane_index=$pane_idx cwd=$pane_creation_cwd"
    else
      log_restore_event "pane-split-failed session=$tmux_session_name window_index=$window_index pane_index=$pane_idx cwd=$pane_creation_cwd"
      record_restore_fallback "$session_name" "$window_name" "$pane_idx" "" "pane split timed out or failed (cwd: $pane_creation_cwd)"
    fi
  done

  actual_pane_count="$(tmux list-panes -t "$window_target" | wc -l | tr -d ' ')"
  if [ "${actual_pane_count:-0}" -ne "$pane_count" ]; then
    log_restore_event "pane-count-mismatch session=$tmux_session_name window_index=$window_index expected=$pane_count actual=${actual_pane_count:-0}"
    local fb_idx fb_title
    for ((fb_idx = 0; fb_idx < pane_count; fb_idx++)); do
      fb_title="$(pane_field "$session_idx" "$window_idx" "$fb_idx" "pane_title" 2>/dev/null || true)"
      record_restore_fallback "$session_name" "$window_name" "$fb_idx" "${fb_title:-}" \
        "pane count mismatch ($actual_pane_count actual vs $pane_count saved)"
    done
    return 0
  else
    log_restore_event "pane-count-ok session=$tmux_session_name window_index=$window_index count=$pane_count"
  fi

  tmux select-layout -t "$window_target" "$window_layout" >/dev/null 2>&1 || true

  while IFS=$'\t' read -r restored_pane_index restored_pane_id; do
    # Extract all pane fields in a single jq call instead of 7+ separate invocations
    local _pf_title _pf_cwd _pf_strategy _pf_transcript _pf_preview _pf_restart _pf_nvim_ref _pf_pane_options
    pane_fields_batch "$session_idx" "$window_idx" "$restored_pane_index"
    pane_title="$_pf_title"
    pane_cwd="$_pf_cwd"
    restore_strategy="$_pf_strategy"
    transcript_path="$_pf_transcript"
    command_preview="$_pf_preview"
    restart_command="$_pf_restart"
    nvim_state_ref="$(resolve_snapshot_path "$_pf_nvim_ref")"

    [ -n "$pane_title" ] && tmux select-pane -t "$restored_pane_id" -T "$pane_title"

    # Restore per-pane option overrides (from batched _pf_pane_options: "key=val|key=val")
    if [ -n "$_pf_pane_options" ]; then
      local _popt_entry _popt_key _popt_val
      IFS='|' read -ra _popt_entries <<< "$_pf_pane_options"
      for _popt_entry in "${_popt_entries[@]}"; do
        _popt_key="${_popt_entry%%=*}"
        _popt_val="${_popt_entry#*=}"
        [ -n "$_popt_key" ] && [ -n "$_popt_val" ] || continue
        tmux set-option -p -t "$restored_pane_id" "$_popt_key" "$_popt_val" 2>/dev/null || true
      done
    fi

    log_restore_event "pane-restore-start session=$tmux_session_name window_index=$window_index pane_index=$restored_pane_index target=$restored_pane_id strategy=$restore_strategy cwd=$pane_cwd"

    if [ -n "$pane_cwd" ] && [ ! -d "$pane_cwd" ]; then
      record_restore_fallback "$session_name" "$window_name" "$restored_pane_index" "$pane_title" "missing cwd; started from fallback directory instead of $pane_cwd"
    fi

    case "$restore_strategy" in
      manual-command)
        record_restore_fallback "$session_name" "$window_name" "$restored_pane_index" "$pane_title" "saved command preloaded at the prompt; not auto-run"
        ;;
      restart-command)
        if [ "$is_template" = "true" ]; then
          log_restore_event "template-restart-command session=$tmux_session_name pane=$restored_pane_index command=$restart_command"
        elif [ -z "$restart_command" ] || ! tmux_revive_command_is_restartable "$restart_command"; then
          record_restore_fallback "$session_name" "$window_name" "$restored_pane_index" "$pane_title" "saved command preloaded at the prompt; not auto-run"
        elif [ "$is_imported_snapshot" = "true" ]; then
          log_restore_event "imported-restart-command session=$tmux_session_name pane=$restored_pane_index command=$restart_command"
          record_restore_fallback "$session_name" "$window_name" "$restored_pane_index" "$pane_title" "restart-command auto-run from imported snapshot: $restart_command"
        fi
        ;;
      history_only|"")
        record_restore_fallback "$session_name" "$window_name" "$restored_pane_index" "$pane_title" "transcript-only restore"
        ;;
      nvim)
        if [ -z "$nvim_state_ref" ] || [ ! -f "$nvim_state_ref" ]; then
          record_restore_fallback "$session_name" "$window_name" "$restored_pane_index" "$pane_title" "Neovim reopened without saved editor state"
        fi
        ;;
      *)
        record_restore_fallback "$session_name" "$window_name" "$restored_pane_index" "$pane_title" "transcript-only restore"
        ;;
    esac

    if ! restore_pane_target "$restored_pane_id" "$pane_cwd" "$restore_strategy" "$transcript_path" "$command_preview" "$restart_command" "$nvim_state_ref"; then
      log_restore_event "pane-restore-failed strategy=$restore_strategy session=$tmux_session_name window_index=$window_index pane_index=$restored_pane_index cwd=$pane_cwd"
    else
      log_restore_event "pane-restore-ok strategy=$restore_strategy session=$tmux_session_name window_index=$window_index pane_index=$restored_pane_index target=$restored_pane_id"
    fi
  done < <(tmux list-panes -t "$window_target" -F $'#{pane_index}\t#{pane_id}')

  active_pane_target="$(tmux list-panes -t "$window_target" -F $'#{pane_index}\t#{pane_id}' | awk -F '\t' -v idx="$active_pane_index" '$1 == idx { print $2; exit }')"
  [ -n "$active_pane_target" ] && tmux select-pane -t "$active_pane_target" >/dev/null 2>&1 || true
  tmux select-window -t "$window_target" >/dev/null 2>&1 || true
}

restore_saved_window() {
  local session_idx="$1"
  local window_idx="$2"
  local tmux_session_name="$3"
  local created_session_target="$4"
  local first_window_target="$5"
  local active_window_index="$6"
  local session_name="$7"
  RESTORE_WINDOW_ACTIVE_TARGET=""

  local window_name window_index window_layout active_pane_index pane_count first_pane_cwd first_pane_creation_cwd window_target

  window_name="$(jq -r ".sessions[$session_idx].windows[$window_idx].window_name" "$manifest_path")"
  window_index="$(jq -r ".sessions[$session_idx].windows[$window_idx].window_index" "$manifest_path")"
  window_layout="$(jq -r ".sessions[$session_idx].windows[$window_idx].layout" "$manifest_path")"
  active_pane_index="$(jq -r ".sessions[$session_idx].windows[$window_idx].active_pane_index // 0" "$manifest_path")"
  pane_count="$(jq ".sessions[$session_idx].windows[$window_idx].panes | length" "$manifest_path" 2>/dev/null)" || pane_count=0
  first_pane_cwd="$(jq -r ".sessions[$session_idx].windows[$window_idx].panes[0].cwd // env.HOME" "$manifest_path")"
  first_pane_creation_cwd="$(resolve_creation_cwd "$first_pane_cwd")"

  if [ "$window_idx" -eq 0 ]; then
    window_target="$first_window_target"
    if ! tmux rename-window -t "$window_target" "$window_name"; then
      log_restore_event "window-rename-failed session=$tmux_session_name window_index=$window_index name=$window_name"
      return 1
    fi
  else
    if ! window_target="$(tmux new-window -d -P -F '#{session_id}:#{window_index}' -t "${created_session_target}:" -n "$window_name" -c "$first_pane_creation_cwd")"; then
      log_restore_event "window-create-failed session=$tmux_session_name window_index=$window_index name=$window_name cwd=$first_pane_creation_cwd"
      return 1
    fi
  fi

  log_restore_event "window-ready session=$tmux_session_name window_index=$window_index target=$window_target panes=$pane_count"

  # Temporarily disable automatic-rename so rename-window sticks during pane creation
  tmux setw -t "$window_target" automatic-rename off
  # Re-apply the desired name in case automatic-rename already overwrote it
  # between window creation and the setw above (race condition).
  tmux rename-window -t "$window_target" "$window_name" >/dev/null 2>&1 || true

  restore_saved_panes_for_window "$session_idx" "$window_idx" "$tmux_session_name" "$window_index" "$window_target" "$pane_count" "$window_layout" "$active_pane_index" "$session_name" "$window_name"

  # Restore automatic-rename to its saved value. If it was explicitly set
  # per-window, restore that value. Otherwise, unset the per-window override
  # so the global setting (usually "on") takes effect again.
  local saved_auto_rename
  saved_auto_rename="$(jq -r ".sessions[$session_idx].windows[$window_idx].automatic_rename // \"\"" "$manifest_path")"
  if [ -n "$saved_auto_rename" ]; then
    tmux setw -t "$window_target" automatic-rename "$saved_auto_rename"
  else
    tmux setw -u -t "$window_target" automatic-rename
  fi

  # Restore per-window options (monitor-activity, monitor-silence, synchronize-panes)
  local _wopt_keys _wopt_key _wopt_val
  _wopt_keys="$(jq -r ".sessions[$session_idx].windows[$window_idx].window_options // {} | keys[]" "$manifest_path" 2>/dev/null || true)"
  if [ -n "$_wopt_keys" ]; then
    while IFS= read -r _wopt_key; do
      [ -n "$_wopt_key" ] || continue
      _wopt_val="$(jq -r --arg k "$_wopt_key" ".sessions[$session_idx].windows[$window_idx].window_options[\$k] // \"\"" "$manifest_path")"
      [ -n "$_wopt_val" ] || continue
      tmux setw -t "$window_target" "$_wopt_key" "$_wopt_val" 2>/dev/null || true
    done <<< "$_wopt_keys"
  fi

  local is_zoomed
  is_zoomed="$(jq -r ".sessions[$session_idx].windows[$window_idx].is_zoomed // false" "$manifest_path")"
  if [ "$is_zoomed" = "true" ]; then
    tmux resize-pane -Z -t "$window_target" >/dev/null 2>&1 || true
  fi

  if [ "$window_index" = "$active_window_index" ]; then
    RESTORE_WINDOW_ACTIVE_TARGET="$window_target"
  fi
}

pane_field() {
  local session_idx="$1"
  local window_idx="$2"
  local pane_index="$3"
  local field="$4"

  jq -r \
    --arg pane_index "$pane_index" \
    --arg field "$field" \
    ".sessions[$session_idx].windows[$window_idx].panes[] | select(.pane_index | tostring == \$pane_index) | .[\$field] // \"\"" \
    "$manifest_path"
}

# Extract all restore-relevant pane fields in a single jq call.
# Sets: _pf_title, _pf_cwd, _pf_strategy, _pf_transcript, _pf_preview, _pf_restart, _pf_nvim_ref, _pf_pane_options
# Uses unit separator (\x1f) instead of tab because IFS=$'\t' collapses consecutive
# tabs, losing empty fields (e.g. empty command_preview shifts restart_command).
pane_fields_batch() {
  local session_idx="$1"
  local window_idx="$2"
  local pane_index="$3"
  local _batch_line
  _batch_line="$(jq -r \
    --arg pi "$pane_index" \
    '.sessions['"$session_idx"'].windows['"$window_idx"'].panes[] | select(.pane_index | tostring == $pi) |
      [
        (.pane_title // ""),
        (.cwd // ""),
        (.restore_strategy // ""),
        (.path_to_history_dump // ""),
        (.command_preview // ""),
        (.restart_command // ""),
        (.nvim_state_ref // ""),
        ((.pane_options // {}) | to_entries | map(.key + "=" + .value) | join("|"))
      ] | join("\u001f")' \
    "$manifest_path")"
  IFS=$'\x1f' read -r _pf_title _pf_cwd _pf_strategy _pf_transcript _pf_preview _pf_restart _pf_nvim_ref _pf_pane_options <<< "$_batch_line"
}

name_in_array() {
  local needle="$1"
  shift
  local candidate
  for candidate in "$@"; do
    [ "$candidate" = "$needle" ] && return 0
  done
  return 1
}

resolve_restore_tmux_session_name() {
  local saved_tmux_session_name="$1"
  local session_name="$2"
  local session_guid="$3"
  local session_id="${4:-}"
  local candidate

  candidate="$saved_tmux_session_name"
  [ -n "$candidate" ] || candidate="$session_name"
  if [ -z "$candidate" ]; then
    if [ -n "$session_guid" ]; then
      candidate="$(tmux_revive_default_tmux_session_name "$session_name" "$session_guid")"
    else
      candidate="$(tmux_revive_normalize_session_name_for_tmux "${session_name:-session}")"
      if [ -n "$session_id" ]; then
        candidate="${candidate}.legacy$(printf '%s\n' "$session_id" | tr -cd '[:alnum:]')"
      fi
    fi
  fi

  printf '%s\n' "$candidate"
}

active_session_guid="$(jq -r '.active_session_guid // ""' "$manifest_path")"
resolved_restore_names=()
resolved_session_names=()
resolved_session_guids=()
resolved_session_ids=()
resolved_active_tmux_session_name=""
for session_idx in "${session_indexes[@]}"; do
  session_name="$(jq -r ".sessions[$session_idx].session_name" "$manifest_path")"
  session_guid="$(jq -r ".sessions[$session_idx].session_guid // \"\"" "$manifest_path")"
  session_id="$(jq -r ".sessions[$session_idx].session_id // \"\"" "$manifest_path")"
  saved_tmux_session_name="$(jq -r ".sessions[$session_idx].tmux_session_name // \"\"" "$manifest_path")"
  tmux_session_name="$(resolve_restore_tmux_session_name "$saved_tmux_session_name" "$session_name" "$session_guid" "$session_id")"

  if [ "${#resolved_restore_names[@]}" -gt 0 ] && name_in_array "$tmux_session_name" "${resolved_restore_names[@]}"; then
    if [ -n "$session_guid" ]; then
      tmux_session_name="$(tmux_revive_default_tmux_session_name "$session_name" "$session_guid")"
    else
      tmux_session_name="$(resolve_restore_tmux_session_name "" "$session_name" "$session_guid" "$session_id")"
    fi
  fi

  resolved_restore_names+=("$tmux_session_name")
  resolved_session_names+=("$session_name")
  resolved_session_guids+=("$session_guid")
  resolved_session_ids+=("$session_id")

  if [ -n "$selected_session_name" ] && [ "$session_name" = "$selected_session_name" ]; then
    selected_tmux_session_name="$tmux_session_name"
  fi
  if [ -n "$filter_session_guid" ] && [ "$session_guid" = "$filter_session_guid" ]; then
    selected_tmux_session_name="$tmux_session_name"
  fi
  if [ -n "$active_session_guid" ] && [ "$session_guid" = "$active_session_guid" ]; then
    resolved_active_tmux_session_name="$tmux_session_name"
  fi
done

# Resolve the transient session's name so we can exclude it from collision checks.
# When restoring into a new-session context, the transient session (e.g. "0") should
# not block restoring a saved session with the same name.
transient_session_name=""
if [ -n "$cleanup_transient_session" ]; then
  transient_session_name="$(tmux display-message -p -t "$cleanup_transient_session" '#{session_name}' 2>/dev/null || true)"
fi

existing_collisions=()
for tmux_session_name in "${resolved_restore_names[@]}"; do
  if tmux has-session -t "=$tmux_session_name" 2>/dev/null; then
    # The transient session we're about to replace shouldn't count as a collision
    if [ -n "$transient_session_name" ] && [ "$tmux_session_name" = "$transient_session_name" ]; then
      continue
    fi
    existing_collisions+=("$tmux_session_name")
  fi
done

active_session_name="$(jq -r '.active_session_name' "$manifest_path")"
attach_target="$active_session_name"
if [ -n "$resolved_active_tmux_session_name" ]; then
  attach_target="$resolved_active_tmux_session_name"
fi
if [ -n "$selected_tmux_session_name" ]; then
  attach_target="$selected_tmux_session_name"
fi

restore_health_warning_refs=()
collect_restore_health_warnings
restore_plan_json="$(build_restore_plan_json "$attach_target")"

if [ "$preview_only" = "true" ]; then
  print_restore_plan_text "$restore_plan_json"
  exit 0
fi

if [ "${#existing_collisions[@]}" -gt 0 ] && [ "$assume_yes" != "true" ]; then
  tmux_notice "tmux-revive: restore would collide with existing sessions: ${existing_collisions[*]}"
  exit 1
fi

if [ "$(jq -r '.host' "$manifest_path")" != "$(tmux_revive_host)" ]; then
  printf 'tmux-revive: warning: snapshot host differs from current host\n' >&2
fi

log_restore_event "manifest=$manifest_path"
run_restore_hook "$(tmux_revive_pre_restore_hook_option)" "TMUX_REVIVE_PRE_RESTORE_HOOK" \
  "TMUX_REVIVE_HOOK_SELECTOR_GUID=$filter_session_guid" \
  "TMUX_REVIVE_HOOK_SELECTOR_ID=$filter_session_id" \
  "TMUX_REVIVE_HOOK_SELECTOR_NAME=$filter_session_name" || true

# Rename the transient session out of the way if it collides with a session
# we're about to restore.  This avoids kill-session on the only live session
# which would crash the tmux server.  The stable session-id ($cleanup_transient_session)
# still tracks it for later cleanup in maybe_cleanup_transient_session().
if [ -n "$cleanup_transient_session" ] && [ -n "$transient_session_name" ] \
   && tmux_revive_session_is_transient "$cleanup_transient_session"; then
  if new_transient_name="$(tmux_revive_rename_transient_for_restore "$cleanup_transient_session" "${resolved_restore_names[@]}")"; then
    log_restore_event "transient-session-renamed from=$transient_session_name to=$new_transient_name target=$cleanup_transient_session"
    transient_session_name="$new_transient_name"
  fi
fi

restored_sessions=0
skipped_collisions=()
restored_session_refs=()
skipped_session_refs=()
grouped_session_refs=()
grouped_session_positions=()
restore_fallback_refs=()
for pos in "${!session_indexes[@]}"; do
  session_idx="${session_indexes[$pos]}"
  session_name="${resolved_session_names[$pos]}"
  session_guid="${resolved_session_guids[$pos]}"
  session_id="${resolved_session_ids[$pos]}"
  tmux_session_name="${resolved_restore_names[$pos]}"
  session_group="$(jq -r ".sessions[$session_idx].session_group // \"\"" "$manifest_path")"
  active_window_index="$(jq -r ".sessions[$session_idx].active_window_index" "$manifest_path")"
  window_count="$(jq ".sessions[$session_idx].windows | length" "$manifest_path" 2>/dev/null)" || window_count=0
  first_window_name="$(jq -r ".sessions[$session_idx].windows[0].window_name" "$manifest_path")"
  first_window_cwd="$(jq -r ".sessions[$session_idx].windows[0].panes[0].cwd // env.HOME" "$manifest_path")"
  first_window_creation_cwd="$(resolve_creation_cwd "$first_window_cwd")"

  if [ -n "$session_group" ] && [ "$session_group" != "$tmux_session_name" ]; then
    # This is a grouped session follower — defer until after primary sessions are restored
    grouped_session_positions+=("$pos")
    log_restore_event "session-group-deferred session=$tmux_session_name group=$session_group"
    continue
  fi

  if tmux has-session -t "=$tmux_session_name" 2>/dev/null; then
    # The transient session should have been renamed before the loop.
    # If a collision still exists here, skip it rather than risk killing the only session.
    skipped_collisions+=("$tmux_session_name")
    skipped_session_refs+=("$(format_session_ref "$session_name" "$session_guid" "$tmux_session_name" "$session_id")")
    continue
  fi

  if ! created_session_info="$(create_restore_session "$tmux_session_name" "$first_window_name" "$first_window_creation_cwd")"; then
    log_restore_event "session-create-failed session=$tmux_session_name cwd=$first_window_creation_cwd"
    tmux_notice "tmux-revive: failed to create session $tmux_session_name; see $latest_restore_log_path"
    continue
  fi
  IFS=$'\t' read -r created_session_target first_window_index <<<"$created_session_info"
  log_restore_event "session-created session=$tmux_session_name target=$created_session_target"
  tmux_revive_set_session_guid "$created_session_target" "$session_guid"
  tmux_revive_set_session_label "$created_session_target" "$session_name"
  restored_sessions=$((restored_sessions + 1))
  restored_session_refs+=("$(format_session_ref "$session_name" "$session_guid" "$tmux_session_name" "$session_id")")
  session_active_window_target=""
  first_window_target="${created_session_target}:${first_window_index}"

  for ((window_idx = 0; window_idx < window_count; window_idx++)); do
    if restore_saved_window "$session_idx" "$window_idx" "$tmux_session_name" "$created_session_target" "$first_window_target" "$active_window_index" "$session_name"; then
      if [ -n "${RESTORE_WINDOW_ACTIVE_TARGET:-}" ]; then
        session_active_window_target="$RESTORE_WINDOW_ACTIVE_TARGET"
      fi
    else
      :
    fi
  done

  if [ -n "$session_active_window_target" ]; then
    tmux select-window -t "$session_active_window_target" >/dev/null 2>&1 || true
  fi
done

# Second pass: create grouped sessions (they share windows with their group target)
for pos in ${grouped_session_positions[@]+"${grouped_session_positions[@]}"}; do
  session_idx="${session_indexes[$pos]}"
  session_name="${resolved_session_names[$pos]}"
  session_guid="${resolved_session_guids[$pos]}"
  session_id="${resolved_session_ids[$pos]}"
  tmux_session_name="${resolved_restore_names[$pos]}"
  session_group="$(jq -r ".sessions[$session_idx].session_group // \"\"" "$manifest_path")"

  # The group target must be a live session
  if ! tmux has-session -t "=$session_group" 2>/dev/null; then
    grouped_session_refs+=("$(format_session_ref "$session_name" "$session_guid" "$tmux_session_name" "$session_id")(target '$session_group' missing)")
    log_restore_event "session-group-target-missing session=$tmux_session_name group=$session_group"
    continue
  fi

  # Skip if this session name already exists
  if tmux has-session -t "=$tmux_session_name" 2>/dev/null; then
    skipped_collisions+=("$tmux_session_name")
    skipped_session_refs+=("$(format_session_ref "$session_name" "$session_guid" "$tmux_session_name" "$session_id")")
    log_restore_event "session-group-collision session=$tmux_session_name"
    continue
  fi

  if tmux new-session -d -t "$session_group" -s "$tmux_session_name" 2>/dev/null; then
    tmux_revive_set_session_guid "=$tmux_session_name" "$session_guid" 2>/dev/null || true
    tmux_revive_set_session_label "=$tmux_session_name" "$session_name" 2>/dev/null || true
    restored_sessions=$((restored_sessions + 1))
    restored_session_refs+=("$(format_session_ref "$session_name" "$session_guid" "$tmux_session_name" "$session_id")")
    log_restore_event "session-group-restored session=$tmux_session_name group=$session_group"
  else
    grouped_session_refs+=("$(format_session_ref "$session_name" "$session_guid" "$tmux_session_name" "$session_id")(create failed)")
    log_restore_event "session-group-create-failed session=$tmux_session_name group=$session_group"
  fi
done

if [ "${#skipped_collisions[@]}" -gt 0 ]; then
  tmux_notice "tmux-revive: skipped existing sessions: ${skipped_session_refs[*]}"
fi
if [ "${#grouped_session_refs[@]}" -gt 0 ]; then
  tmux_notice "tmux-revive: grouped session issues: ${grouped_session_refs[*]}"
fi

if [ "$restored_sessions" -eq 0 ]; then
  if [ "${#skipped_session_refs[@]}" -gt 0 ]; then
    finish_restore_success "$attach_target" "$restored_sessions" \
      "tmux-revive: restored 0 session(s); skipped existing sessions: ${skipped_session_refs[*]}"
    exit 0
  fi

  if [ "${#grouped_session_refs[@]}" -gt 0 ]; then
    tmux_notice "tmux-revive: no sessions were restored; grouped session issues: ${grouped_session_refs[*]}"
    exit 1
  fi

  tmux_notice "tmux-revive: no sessions were restored from $manifest_path"
  exit 1
fi

# Restore paste buffers if present in the snapshot
paste_buffer_count="$(jq '.paste_buffers | length' "$manifest_path" 2>/dev/null || printf '0')"
case "$paste_buffer_count" in ''|*[!0-9]*) paste_buffer_count=0 ;; esac
if [ "$paste_buffer_count" -gt 0 ]; then
  snapshot_dir="$(dirname "$manifest_path")"
  paste_dir="$snapshot_dir/paste-buffers"
  if [ -d "$paste_dir" ]; then
    for ((pb_idx = paste_buffer_count - 1; pb_idx >= 0; pb_idx--)); do
      pb_file="$paste_dir/$pb_idx"
      [ -f "$pb_file" ] || continue
      tmux load-buffer "$pb_file" 2>/dev/null || true
    done
    log_restore_event "paste-buffers-restored count=$paste_buffer_count"
  fi
fi

maybe_switch_restore_target "$attach_target"

restore_summary="tmux-revive: restored ${restored_sessions} session(s): ${restored_session_refs[*]}"
if [ "${#skipped_session_refs[@]}" -gt 0 ]; then
  restore_summary="${restore_summary}; skipped: ${skipped_session_refs[*]}"
fi
if [ "${#grouped_session_refs[@]}" -gt 0 ]; then
  restore_summary="${restore_summary}; grouped issues: ${grouped_session_refs[*]}"
fi
finish_restore_success "$attach_target" "$restored_sessions" "$restore_summary"
