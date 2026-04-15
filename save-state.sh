#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/parse-server-arg.sh
source "$script_dir/lib/parse-server-arg.sh"
# shellcheck source=lib/state-common.sh
source "$script_dir/lib/state-common.sh"

auto_mode="false"
reason="manual"
created_at_epoch="$(date +%s)"

while [ $# -gt 0 ]; do
  case "$1" in
    --auto)
      auto_mode="true"
      shift
      ;;
    --reason)
      reason="${2:?--reason requires a value}"
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

runtime_dir="$(tmux_revive_runtime_dir)"
lock_dir="$runtime_dir/save.lock"
lock_meta_path="$lock_dir/meta.json"
pending_path="$(tmux_revive_pending_save_path)"
last_auto_path="$(tmux_revive_last_auto_save_path)"
last_save_notice_path="$(tmux_revive_last_save_notice_path)"

mkdir -p "$runtime_dir"

save_lock_timeout="$(tmux_revive_get_global_option "$(tmux_revive_save_lock_timeout_option)" "120")"
case "$save_lock_timeout" in
  ''|*[!0-9]*)
    save_lock_timeout=120
    ;;
esac

save_lock_is_stale() {
  local now started_at pid

  [ -d "$lock_dir" ] || return 1
  [ -f "$lock_meta_path" ] || return 0

  started_at="$(jq -r '.started_at // 0' "$lock_meta_path" 2>/dev/null || printf '0')"
  pid="$(jq -r '.pid // 0' "$lock_meta_path" 2>/dev/null || printf '0')"
  case "$started_at" in
    ''|*[!0-9]*)
      return 0
      ;;
  esac
  case "$pid" in
    ''|*[!0-9]*)
      return 0
      ;;
  esac

  if ! kill -0 "$pid" >/dev/null 2>&1; then
    return 0
  fi

  now="$(date +%s)"
  [ $((now - started_at)) -gt "$save_lock_timeout" ]
}

write_save_lock_meta() {
  local started_at="$1"
  jq -cn --argjson pid "$$" --argjson started_at "$started_at" '{ pid: $pid, started_at: $started_at }' >"$lock_meta_path"
}

acquire_save_lock() {
  local started_at

  if mkdir "$lock_dir" 2>/dev/null; then
    started_at="$(date +%s)"
    write_save_lock_meta "$started_at"
    return 0
  fi

  if save_lock_is_stale; then
    # Atomic rename to prevent two stale-lock recoveries from both succeeding
    if mv "$lock_dir" "$lock_dir.stale.$$" 2>/dev/null; then
      rm -rf "$lock_dir.stale.$$"
      if mkdir "$lock_dir" 2>/dev/null; then
        started_at="$(date +%s)"
        write_save_lock_meta "$started_at"
        return 0
      fi
    fi
    return 1
  fi

  return 1
}

queue_pending_auto_save() {
  : >"$pending_path"
}

publish_latest_snapshot() {
  jq -cn \
    --arg created_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --arg manifest_path "$manifest_path" \
    --arg snapshot_path "$snapshot_dir" \
    '{
      created_at: $created_at,
      manifest_path: $manifest_path,
      snapshot_path: $snapshot_path
    }' >"${latest_path}.tmp.$$"
  mv "${latest_path}.tmp.$$" "$latest_path" || { rm -f "${latest_path}.tmp.$$"; return 1; }
}

update_last_auto_save_marker() {
  if [ "$auto_mode" = "true" ]; then
    local ts
    ts="$(date +%s)"
    printf '%s\n' "$ts" >"$last_auto_path"
    tmux set-option -gq '@tmux-revive-last-auto-save' "$ts" 2>/dev/null || true
  fi
}

write_last_save_notice() {
  jq -cn \
    --arg reason "$reason" \
    --arg mode "$([ "$auto_mode" = "true" ] && printf 'auto' || printf 'manual')" \
    --arg saved_at "$(date +%s)" \
    '{
      status: "done",
      reason: $reason,
      mode: $mode,
      saved_at: ($saved_at | tonumber)
    }' >"${last_save_notice_path}.tmp.$$"
  mv "${last_save_notice_path}.tmp.$$" "$last_save_notice_path" || { rm -f "${last_save_notice_path}.tmp.$$"; return 1; }
  rm -f "${last_save_notice_path%.json}-spin"
}

refresh_tmux_statusline() {
  tmux refresh-client -S >/dev/null 2>&1 || true
}

notify_manual_save_success() {
  [ "$auto_mode" = "true" ] && return 0
  tmux display-message "tmux-revive: saved snapshot" >/dev/null 2>&1 || true
}

prune_snapshots_if_enabled() {
  local prune_snapshots_cmd="${TMUX_REVIVE_PRUNE_SNAPSHOTS_CMD:-$script_dir/prune-snapshots.sh}"
  env \
    "TMUX_REVIVE_STATE_ROOT=${TMUX_REVIVE_STATE_ROOT-}" \
    "TMUX_REVIVE_RETENTION_ENABLED=${TMUX_REVIVE_RETENTION_ENABLED-}" \
    "TMUX_REVIVE_RETENTION_AUTO_COUNT=${TMUX_REVIVE_RETENTION_AUTO_COUNT-}" \
    "TMUX_REVIVE_RETENTION_MANUAL_COUNT=${TMUX_REVIVE_RETENTION_MANUAL_COUNT-}" \
    "TMUX_REVIVE_RETENTION_AUTO_AGE_DAYS=${TMUX_REVIVE_RETENTION_AUTO_AGE_DAYS-}" \
    "TMUX_REVIVE_RETENTION_MANUAL_AGE_DAYS=${TMUX_REVIVE_RETENTION_MANUAL_AGE_DAYS-}" \
    "TMUX_REVIVE_RETENTION_ACTION_LOG=${TMUX_REVIVE_RETENTION_ACTION_LOG-}" \
    bash "$prune_snapshots_cmd" >/dev/null 2>&1 || true
}

run_queued_auto_save_if_needed() {
  if [ -f "$pending_path" ]; then
    rm -f "$pending_path"
    if ! "$0" --auto --reason queued >/dev/null 2>&1; then
      local _err_log
      _err_log="$(tmux_revive_runtime_dir)/save-errors.log"
      printf '[%s] queued auto-save failed\n' "$(date +%Y-%m-%dT%H:%M:%S)" \
        >>"$_err_log" 2>/dev/null || true
      tmux_revive_truncate_log "$_err_log" 200
    fi
  fi
}

if ! acquire_save_lock; then
  if [ "$auto_mode" = "true" ]; then
    queue_pending_auto_save
    exit 0
  else
    tmux display-message "tmux-revive: save in progress, try again shortly" 2>/dev/null || true
    printf 'tmux-revive: could not acquire save lock\n' >&2
    exit 1
  fi
fi

cleanup() {
  rm -rf "$lock_dir"
  # Remove incomplete snapshot tmp dir if the save did not finish
  if [ -n "${tmp_dir:-}" ] && [ -d "${tmp_dir:-}" ] && [ ! -f "${tmp_dir}/manifest.json" ]; then
    rm -rf "$tmp_dir"
  fi
  # Clear the "saving" indicator on failure (successful saves overwrite it)
  if [ -f "$last_save_notice_path" ]; then
    local status
    status="$(jq -r '.status // ""' "$last_save_notice_path" 2>/dev/null || printf '')"
    if [ "$status" = "saving" ]; then
      rm -f "$last_save_notice_path"
    fi
  fi
}
trap cleanup EXIT

write_saving_indicator() {
  jq -cn \
    --arg mode "$([ "$auto_mode" = "true" ] && printf 'auto' || printf 'manual')" \
    --arg started_at "$(date +%s)" \
    '{
      status: "saving",
      mode: $mode,
      started_at: ($started_at | tonumber)
    }' >"${last_save_notice_path}.tmp.$$"
  mv "${last_save_notice_path}.tmp.$$" "$last_save_notice_path" || { rm -f "${last_save_notice_path}.tmp.$$"; return 1; }
  tmux refresh-client -S >/dev/null 2>&1 || true
}

write_saving_indicator

host="$(tmux_revive_host)"
snapshots_root="$(tmux_revive_snapshots_root)"
timestamp="$(date -u +%Y-%m-%dT%H-%M-%SZ)"
created_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
# Append PID to guarantee uniqueness on same-second saves
snapshot_id="${timestamp}-$$"
tmp_dir="$snapshots_root/.${snapshot_id}.tmp"
snapshot_dir="$snapshots_root/$snapshot_id"
manifest_path="$snapshot_dir/manifest.json"
latest_path="$(tmux_revive_latest_path)"

mkdir -p "$tmp_dir/panes" "$tmp_dir/nvim" "$snapshots_root" || {
  printf 'tmux-revive: failed to create snapshot directories\n' >&2
  exit 1
}

run_save_hook() {
  local option_name="$1"
  local env_name="$2"
  tmux_revive_run_hook "$env_name" "$option_name" \
    "TMUX_REVIVE_HOOK_EVENT=save" \
    "TMUX_REVIVE_HOOK_REASON=$reason" \
    "TMUX_REVIVE_HOOK_AUTO=$auto_mode" \
    "TMUX_REVIVE_HOOK_RUNTIME_DIR=$runtime_dir" \
    "TMUX_REVIVE_HOOK_SNAPSHOT_DIR=$snapshot_dir" \
    "TMUX_REVIVE_HOOK_MANIFEST_PATH=$manifest_path"
}

run_save_hook "$(tmux_revive_pre_save_hook_option)" "TMUX_REVIVE_PRE_SAVE_HOOK" || true

json_bool() {
  if [ "${1:-false}" = "true" ]; then
    printf 'true'
  else
    printf 'false'
  fi
}

sweep_stale_nvim_registry() {
  local registry_root
  registry_root="${TMUX_SEND_TO_NVIM_STATE_DIR:-$(tmux_revive_registry_root)}"
  [ -d "$registry_root" ] || return 0
  local entry nvim_pid
  for entry in "$registry_root"/*/*.json; do
    [ -f "$entry" ] || continue
    nvim_pid="$(jq -r '.nvim_pid // ""' "$entry" 2>/dev/null)" || continue
    [ -n "$nvim_pid" ] || continue
    if ! kill -0 "$nvim_pid" 2>/dev/null; then
      rm -f "$entry"
    fi
  done
  # Remove empty session directories
  find "$registry_root" -mindepth 1 -maxdepth 1 -type d -empty -delete 2>/dev/null || true
}

nvim_registry_cwd_for_pane() {
  local session_id="$1"
  local pane_id="$2"
  local registry_root entry_path

  [ -n "$session_id" ] || return 1
  [ -n "$pane_id" ] || return 1

  registry_root="${TMUX_SEND_TO_NVIM_STATE_DIR:-$(tmux_revive_registry_root)}"
  [ -d "$registry_root/$session_id" ] || return 1

  entry_path="$(find "$registry_root/$session_id" -maxdepth 1 -type f -name "${pane_id}-*.json" | head -n 1)"
  [ -n "$entry_path" ] || return 1
  [ -f "$entry_path" ] || return 1

  jq -r '.cwd // ""' "$entry_path"
}

to_snapshot_path() {
  local path="$1"
  if [[ "$path" == "$tmp_dir"* ]]; then
    printf '%s\n' "${path/#$tmp_dir/$snapshot_dir}"
  else
    printf '%s\n' "$path"
  fi
}

build_pane_snapshot() {
  local session_id="$1"
  local pane_id="$2"
  local pane_index="$3"
  local pane_title="$4"
  local pane_cwd="$5"
  local pane_command="$6"
  local pane_width="$7"
  local pane_height="$8"
  local pane_pid="$9"

  local meta_path transcript_excluded history_path history_capture_path
  local command_preview command_capture_source restart_command restart_command_source
  local restore_strategy_override captured_running_command
  local nvim_state_ref restore_strategy nvim_registry_cwd

  meta_path="$(tmux_revive_pane_meta_path "$pane_id")"

  # Bulk-read all pane meta fields in a single jq call (unit-separator delimited)
  local _bulk_sep=$'\x1f'
  local _bulk_meta
  _bulk_meta="$(tmux_revive_read_pane_meta_bulk "$meta_path")"
  IFS="$_bulk_sep" read -r transcript_excluded command_preview command_capture_source restart_command restart_command_source restore_strategy_override <<< "$_bulk_meta"

  history_path=""

  if [ "$transcript_excluded" != "true" ]; then
    history_capture_path="$tmp_dir/panes/${pane_id}.history.txt"
    history_path="$(to_snapshot_path "$history_capture_path")"
    tmux capture-pane -p -S "-${_cached_capture_lines}" -t "$pane_id" >"$history_capture_path" || true
  fi

  captured_running_command="$(tmux_revive_capture_pane_command_preview "$process_table" "$pane_pid" "$pane_command" "$command_preview" || true)"
  if [ -z "$command_preview" ] && [ -n "$captured_running_command" ]; then
    command_preview="$captured_running_command"
    command_capture_source="process-tree"
  elif [ -z "$command_preview" ] && [ -n "$pane_command" ] && ! tmux_revive_command_is_shell "$pane_command"; then
    # Fallback: use pane_current_command when process-tree walker found nothing
    command_preview="$pane_command"
    command_capture_source="pane-command-fallback"
  fi

  nvim_state_ref=""
  local pane_nvim_capture="$tmp_dir/nvim-state-path-${pane_id}.txt"
  if "$script_dir/../tmux/send_to_nvim/snapshot-nvim-state.sh" "$pane_id" "$tmp_dir/nvim/$pane_id" >"$pane_nvim_capture" 2>/dev/null; then
    nvim_state_ref="$(to_snapshot_path "$(cat "$pane_nvim_capture")")"
    rm -f "$pane_nvim_capture"
    nvim_registry_cwd="$(nvim_registry_cwd_for_pane "$session_id" "$pane_id" || true)"
    if [ -n "$nvim_registry_cwd" ]; then
      pane_cwd="$nvim_registry_cwd"
    fi
  fi

  restore_strategy="$(tmux_revive_classify_restore_strategy "$pane_command" "$command_preview" "$restart_command" "$nvim_state_ref" "$transcript_excluded")"
  if [ "$restore_strategy" = "restart-command" ] && [ -z "$restart_command" ] && [ -n "$command_preview" ]; then
    restart_command="$command_preview"
    [ -n "$restart_command_source" ] || restart_command_source="${command_capture_source:-command_preview}"
  fi

  case "$restore_strategy_override" in
    ""|auto)
      ;;
    shell|history_only|manual-command|restart-command)
      restore_strategy="$restore_strategy_override"
      ;;
    *)
      ;;
  esac

  # Capture per-pane option overrides in a single tmux call + single jq call
  local _all_pane_opts pane_options_json="{}"
  _all_pane_opts="$(tmux show-options -p -t "$pane_id" 2>/dev/null || true)"
  if [ -n "$_all_pane_opts" ]; then
    local _popt_pairs="" _popt_key _popt_val
    for _popt_key in pane-border-status pane-border-format pane-border-style remain-on-exit allow-rename; do
      while IFS= read -r _popt_val; do
        _popt_val="${_popt_val#"$_popt_key "}"
        _popt_pairs="${_popt_pairs:+${_popt_pairs},}$(printf '"%s":"%s"' "$_popt_key" "$_popt_val")"
      done <<< "$(printf '%s\n' "$_all_pane_opts" | grep "^${_popt_key} " || true)"
    done
    if [ -n "$_popt_pairs" ]; then
      pane_options_json="{${_popt_pairs}}"
    fi
  fi

  jq -cn \
    --arg pane_index "$pane_index" \
    --arg pane_id_at_save "$pane_id" \
    --arg pane_title "$pane_title" \
    --arg cwd "$pane_cwd" \
    --arg current_command "$pane_command" \
    --argjson captured_layout_width "${pane_width:-0}" \
    --argjson captured_layout_height "${pane_height:-0}" \
    --arg path_to_history_dump "$history_path" \
    --arg restore_strategy "$restore_strategy" \
    --arg nvim_state_ref "$nvim_state_ref" \
    --arg command_preview "$command_preview" \
    --arg command_capture_source "$command_capture_source" \
    --arg restart_command "$restart_command" \
    --arg restart_command_source "$restart_command_source" \
    --arg restore_strategy_override "$restore_strategy_override" \
    --argjson transcript_excluded "$(json_bool "$transcript_excluded")" \
    --argjson pane_options "$pane_options_json" \
    '{
      pane_index: ($pane_index | tonumber),
      pane_id_at_save: $pane_id_at_save,
      pane_title: $pane_title,
      cwd: $cwd,
      current_command: $current_command,
      captured_layout_width: $captured_layout_width,
      captured_layout_height: $captured_layout_height,
      path_to_history_dump: $path_to_history_dump,
      restore_strategy: $restore_strategy,
      nvim_state_ref: $nvim_state_ref,
      command_preview: $command_preview,
      command_capture_source: $command_capture_source,
      restart_command: $restart_command,
      restart_command_source: $restart_command_source,
      restore_strategy_override: $restore_strategy_override,
      transcript_excluded: $transcript_excluded,
      pane_options: $pane_options
    }'
}

build_window_snapshot() {
  local session_id="$1"
  local tmux_session_name="$2"
  local window_index="$3"
  local window_name="$4"
  local window_layout="$5"
  local window_active_pane="$6"
  local is_zoomed="${7:-false}"
  local automatic_rename="${8:-}"
  local window_options_json="${9:-"{}"}"

  local panes_json pane_json
  local pane_id pane_index pane_title pane_cwd pane_command pane_width pane_height pane_is_active pane_pid

  local _panes_ndjson=""
  local _detected_active_pane=""
  while IFS=$'\t' read -r pane_id pane_index pane_title pane_cwd pane_command pane_width pane_height pane_is_active pane_pid; do
    [ -n "$pane_id" ] || continue
    if [ "$pane_is_active" = "1" ]; then
      _detected_active_pane="$pane_index"
    fi
    pane_json="$(build_pane_snapshot "$session_id" "$pane_id" "$pane_index" "$pane_title" "$pane_cwd" "$pane_command" "$pane_width" "$pane_height" "$pane_pid")"
    _panes_ndjson="${_panes_ndjson:+${_panes_ndjson}
}${pane_json}"
  done < <(tmux list-panes -t "$tmux_session_name:$window_index" -F $'#{pane_id}\t#{pane_index}\t#{pane_title}\t#{pane_current_path}\t#{pane_current_command}\t#{pane_width}\t#{pane_height}\t#{?pane_active,1,0}\t#{pane_pid}')
  panes_json="$(printf '%s\n' "$_panes_ndjson" | jq -s '.')"
  if [ -n "$_detected_active_pane" ]; then
    window_active_pane="$_detected_active_pane"
  fi

  jq -cn \
    --argjson window_index "${window_index:-0}" \
    --arg window_name "$window_name" \
    --arg layout "$window_layout" \
    --argjson active_pane_index "${window_active_pane:-0}" \
    --argjson is_zoomed "$is_zoomed" \
    --arg automatic_rename "$automatic_rename" \
    --argjson window_options "$window_options_json" \
    --argjson panes "$panes_json" \
    '{
      window_index: $window_index,
      window_name: $window_name,
      layout: $layout,
      active_pane_index: $active_pane_index,
      is_zoomed: $is_zoomed,
      automatic_rename: $automatic_rename,
      window_options: $window_options,
      panes: $panes
    }'
}

build_session_snapshot() {
  local session_id="$1"
  local tmux_session_name="$2"
  local session_group="$3"
  local session_guid="$4"
  local session_name="$5"
  local active_window_index="$6"

  local windows_json window_json
  local window_index window_name window_layout window_active_pane

  local _windows_ndjson=""
  while IFS=$'\t' read -r window_index window_name window_layout window_active_pane window_flags; do
    [ -n "$window_index" ] || continue
    local is_zoomed="false"
    [[ "${window_flags:-}" == *Z* ]] && is_zoomed="true"
    local auto_rename
    auto_rename="$(tmux show-window-option -v -t "$tmux_session_name:$window_index" automatic-rename 2>/dev/null || printf '')"
    # Capture per-window options in a single tmux call
    local _wopts_json="{}" _all_wopts
    _all_wopts="$(tmux show-window-options -t "$tmux_session_name:$window_index" 2>/dev/null || true)"
    if [ -n "$_all_wopts" ]; then
      local _wopt_pairs="" _wopt_name _wopt_val
      for _wopt_name in monitor-activity monitor-silence synchronize-panes; do
        while IFS= read -r _wopt_val; do
          _wopt_val="${_wopt_val#"$_wopt_name "}"
          _wopt_pairs="${_wopt_pairs:+${_wopt_pairs},}$(printf '"%s":"%s"' "$_wopt_name" "$_wopt_val")"
        done <<< "$(printf '%s\n' "$_all_wopts" | grep "^${_wopt_name} " || true)"
      done
      if [ -n "$_wopt_pairs" ]; then
        _wopts_json="{${_wopt_pairs}}"
      fi
    fi
    window_json="$(build_window_snapshot "$session_id" "$tmux_session_name" "$window_index" "$window_name" "$window_layout" "$window_active_pane" "$is_zoomed" "$auto_rename" "$_wopts_json")"
    _windows_ndjson="${_windows_ndjson:+${_windows_ndjson}
}${window_json}"
  done < <(tmux list-windows -t "$tmux_session_name" -F $'#{window_index}\t#{window_name}\t#{window_layout}\t#{pane_index}\t#{window_flags}')
  windows_json="$(printf '%s\n' "$_windows_ndjson" | jq -s '.')"

  jq -cn \
    --arg session_id "$session_id" \
    --arg session_guid "$session_guid" \
    --arg session_name "$session_name" \
    --arg tmux_session_name "$tmux_session_name" \
    --arg session_group "$session_group" \
    --argjson active_window_index "${active_window_index:-0}" \
    --argjson windows "$windows_json" \
    '{
      session_id: $session_id,
      session_guid: $session_guid,
      session_name: $session_name,
      tmux_session_name: $tmux_session_name,
      session_group: $session_group,
      active_window_index: $active_window_index,
      windows: $windows
    }'
}

active_session_id="$(tmux display-message -p '#{session_id}' 2>/dev/null || tmux list-sessions -F '#{session_id}' | head -n 1)"
active_session_name="$(tmux display-message -p '#S' 2>/dev/null || tmux list-sessions -F '#{session_name}' | head -n 1)"
active_session_guid=""
active_session_order=1
session_order=0
_sessions_ndjson=""
# Cache global option once instead of reading per-pane
_cached_capture_lines="$(tmux_revive_get_global_option '@tmux-revive-capture-lines' '499')"
case "$_cached_capture_lines" in ''|*[!0-9]*) _cached_capture_lines=499 ;; esac
# Cache restartable-commands option so it's not read per-pane via tmux IPC
_cached_restartable_commands="$(tmux show-option -gqv '@tmux-revive-restartable-commands' 2>/dev/null || printf '')"
process_table="$(tmux_revive_process_table || true)"

while IFS=$'\t' read -r session_id tmux_session_name session_group; do
  [ -n "$tmux_session_name" ] || continue
  session_order=$((session_order + 1))
  session_guid="$(tmux_revive_ensure_session_guid "$session_id")"
  session_name="$(tmux_revive_session_label_or_name "$session_id" "$tmux_session_name")"

  if [ "$session_id" = "$active_session_id" ]; then
    active_session_order="$session_order"
    active_session_guid="$session_guid"
    active_session_name="$session_name"
  fi

  active_window_index="$(tmux display-message -p -t "$tmux_session_name" '#{window_index}')"
  session_json="$(build_session_snapshot "$session_id" "$tmux_session_name" "$session_group" "$session_guid" "$session_name" "$active_window_index")"
  _sessions_ndjson="${_sessions_ndjson:+${_sessions_ndjson}
}${session_json}"
done < <(tmux list-sessions -F $'#{session_id}\t#{session_name}\t#{session_group}')
sessions_json="$(printf '%s\n' "$_sessions_ndjson" | jq -s '.')"

# Save paste buffers if enabled
paste_buffers_json="[]"
save_paste_buffers="$(tmux_revive_get_global_option '@tmux-revive-save-paste-buffers' 'off')"
if [ "$save_paste_buffers" = "on" ]; then
  paste_buffer_max="$(tmux_revive_get_global_option '@tmux-revive-paste-buffer-max' '10')"
  case "$paste_buffer_max" in ''|*[!0-9]*) paste_buffer_max=10 ;; esac
  paste_dir="$tmp_dir/paste-buffers"
  mkdir -p "$paste_dir"
  buf_index=0
  while IFS=$'\t' read -r buf_name buf_size; do
    [ -n "$buf_name" ] || continue
    [ "$buf_index" -lt "$paste_buffer_max" ] || break
    buf_file="$paste_dir/$buf_index"
    if tmux save-buffer -b "$buf_name" "$buf_file" 2>/dev/null; then
      paste_buffers_json="$(jq -cn --argjson arr "$paste_buffers_json" \
        --arg name "$buf_name" --argjson size "${buf_size:-0}" --argjson index "$buf_index" \
        '$arr + [{ name: $name, size: $size, file_index: $index }]')"
      buf_index=$((buf_index + 1))
    fi
  done < <(tmux list-buffers -F $'#{buffer_name}\t#{buffer_size}' 2>/dev/null || true)
fi

jq -cn \
  --arg snapshot_version "1" \
  --arg created_at "$created_at" \
  --argjson created_at_epoch "$created_at_epoch" \
  --arg last_updated "$created_at" \
  --argjson last_updated_epoch "$created_at_epoch" \
  --arg host "$host" \
  --arg os "$(uname -s)" \
  --arg tmux_version "$(tmux -V)" \
  --arg active_session_guid "$active_session_guid" \
  --arg active_session_name "$active_session_name" \
  --argjson active_session_order "$active_session_order" \
  --arg reason "$reason" \
  --arg save_mode "$([ "$auto_mode" = "true" ] && printf 'auto' || printf 'manual')" \
  --argjson sessions "$sessions_json" \
  --argjson paste_buffers "$paste_buffers_json" \
  '{
    snapshot_version: $snapshot_version,
    created_at: $created_at,
    created_at_epoch: $created_at_epoch,
    last_updated: $last_updated,
    last_updated_epoch: $last_updated_epoch,
    host: $host,
    os: $os,
    tmux_version: $tmux_version,
    active_session_guid: $active_session_guid,
    active_session_name: $active_session_name,
    active_session_order: $active_session_order,
    reason: $reason,
    save_mode: $save_mode,
    sessions: $sessions,
    paste_buffers: $paste_buffers
  }' >"$tmp_dir/manifest.json"

if ! mv "$tmp_dir" "$snapshot_dir"; then
  rm -rf "$tmp_dir"
  printf 'save: failed to move snapshot into place: %s -> %s\n' "$tmp_dir" "$snapshot_dir" >&2
  exit 1
fi

publish_latest_snapshot
prune_snapshots_if_enabled
update_last_auto_save_marker
write_last_save_notice
refresh_tmux_statusline
notify_manual_save_success

run_save_hook "$(tmux_revive_post_save_hook_option)" "TMUX_REVIVE_POST_SAVE_HOOK" || true

if [ "$auto_mode" = "true" ]; then
  sweep_stale_nvim_registry
fi
run_queued_auto_save_if_needed
