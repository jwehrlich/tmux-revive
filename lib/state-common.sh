#!/usr/bin/env bash
# This file must be sourced, not executed directly (uses return at file scope).

if [ -z "${TMUX:-}" ] && [ -n "${TMUX_REVIVE_SOCKET_PATH:-}" ] && [ "${TMUX_REVIVE_SOCKET_PATH#/}" != "$TMUX_REVIVE_SOCKET_PATH" ]; then
  export TMUX="${TMUX_REVIVE_SOCKET_PATH},0,0"
fi

# Auto-detect named server from socket path when TMUX_REVIVE_TMUX_SERVER
# is not explicitly set. Keybindings pass TMUX_REVIVE_SOCKET_PATH but not
# --server, so we derive the server name from the socket basename. The
# default socket (named "default") is excluded — it needs no -L flag.
# Only use paths that look like real socket paths (must start with /).
if [ -z "${TMUX_REVIVE_TMUX_SERVER:-}" ]; then
  _socket_path=""
  if [ -n "${TMUX_REVIVE_SOCKET_PATH:-}" ] && [ "${TMUX_REVIVE_SOCKET_PATH#/}" != "$TMUX_REVIVE_SOCKET_PATH" ]; then
    _socket_path="$TMUX_REVIVE_SOCKET_PATH"
  elif [ -n "${TMUX:-}" ]; then
    _socket_path="${TMUX%%,*}"
  fi
  if [ -n "$_socket_path" ]; then
    _socket_name="$(basename "$_socket_path")"
    if [ "$_socket_name" != "default" ] && [ -n "$_socket_name" ]; then
      export TMUX_REVIVE_TMUX_SERVER="$_socket_name"
    fi
  fi
  unset _socket_path _socket_name
fi

if [ -n "${TMUX_REVIVE_TMUX_SERVER:-}" ]; then
  export TMUX_REVIVE_TMUX_SERVER
  tmux() { command tmux -L "$TMUX_REVIVE_TMUX_SERVER" "$@"; }
fi

command -v jq >/dev/null 2>&1 || {
  printf 'tmux-revive: jq is required but not found in PATH\n' >&2
  return 1
}

tmux_revive_require_yq() {
  command -v yq >/dev/null 2>&1 || {
    printf 'tmux-revive: yq (v4+) is required but not found in PATH\n' >&2
    printf '  Install: brew install yq  (or)  go install github.com/mikefarah/yq/v4@latest\n' >&2
    return 1
  }
}

tmux_revive_state_root() {
  if [ -n "${TMUX_REVIVE_STATE_ROOT:-}" ]; then
    printf '%s\n' "$TMUX_REVIVE_STATE_ROOT"
    return 0
  fi
  # XDG-aware default: prefer ~/.config/tmux/data when that layout is in use,
  # otherwise fall back to the traditional ~/.tmux/data directory.
  if [ -d "$HOME/.config/tmux" ] && [ ! -d "$HOME/.tmux" ]; then
    printf '%s\n' "${XDG_DATA_HOME:-$HOME/.config/tmux}/data"
  else
    printf '%s\n' "$HOME/.tmux/data"
  fi
}

tmux_revive_host() {
  hostname -s 2>/dev/null || hostname 2>/dev/null || printf 'unknown'
}

tmux_revive_registry_root() {
  printf '%s/registry\n' "$(tmux_revive_state_root)"
}

tmux_revive_snapshots_root() {
  local base
  base="$(printf '%s/snapshots/%s' "$(tmux_revive_state_root)" "$(tmux_revive_host)")"
  if [ -n "${TMUX_REVIVE_TMUX_SERVER:-}" ]; then
    printf '%s/%s\n' "$base" "$TMUX_REVIVE_TMUX_SERVER"
  else
    printf '%s\n' "$base"
  fi
}

tmux_revive_templates_root() {
  printf '%s/templates\n' "$(tmux_revive_state_root)"
}

tmux_revive_pane_meta_root() {
  local base
  base="$(printf '%s/pane-meta' "$(tmux_revive_state_root)")"
  if [ -n "${TMUX_REVIVE_TMUX_SERVER:-}" ]; then
    printf '%s/%s\n' "$base" "$TMUX_REVIVE_TMUX_SERVER"
  else
    printf '%s\n' "$base"
  fi
}

tmux_revive_runtime_root() {
  printf '%s/runtime\n' "$(tmux_revive_state_root)"
}

tmux_revive_restore_logs_root() {
  local base
  base="$(printf '%s/logs' "$(tmux_revive_runtime_root)")"
  if [ -n "${TMUX_REVIVE_TMUX_SERVER:-}" ]; then
    printf '%s/%s\n' "$base" "$TMUX_REVIVE_TMUX_SERVER"
  else
    printf '%s\n' "$base"
  fi
}

tmux_revive_session_index_path() {
  printf '%s/session-index.json\n' "$(tmux_revive_state_root)"
}

tmux_revive_install_root() {
  if [ -n "${TMUX_REVIVE_SCRIPT_DIR:-}" ]; then
    printf '%s\n' "$TMUX_REVIVE_SCRIPT_DIR"
    return 0
  fi
  cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd
}

tmux_revive_profiles_root() {
  if [ -n "${TMUX_REVIVE_PROFILE_DIR:-}" ]; then
    printf '%s\n' "$TMUX_REVIVE_PROFILE_DIR"
    return 0
  fi
  printf '%s/profiles\n' "$(tmux_revive_install_root)"
}

tmux_revive_socket_key() {
  if [ -n "${TMUX_REVIVE_TMUX_SERVER:-}" ]; then
    printf '%s\n' "$TMUX_REVIVE_TMUX_SERVER"
    return 0
  fi
  local socket_path
  if [ -n "${TMUX_REVIVE_SOCKET_PATH:-}" ]; then
    socket_path="$TMUX_REVIVE_SOCKET_PATH"
  elif [ -n "${TMUX:-}" ]; then
    socket_path="${TMUX%%,*}"
  fi
  if [ -z "${socket_path:-}" ]; then
    socket_path="$(tmux display-message -p '#{socket_path}' 2>/dev/null || printf 'default')"
  fi
  printf '%s\n' "$socket_path" | tr '/: ' '___'
}

tmux_revive_runtime_dir() {
  printf '%s/%s\n' "$(tmux_revive_runtime_root)" "$(tmux_revive_socket_key)"
}

tmux_revive_truncate_log() {
  local log_path="$1"
  local max_lines="${2:-200}"
  [ -f "$log_path" ] || return 0
  local line_count
  line_count="$(wc -l < "$log_path")"
  if [ "$line_count" -gt "$max_lines" ]; then
    local tmp="${log_path}.tmp.$$"
    tail -n "$max_lines" "$log_path" >"$tmp" && mv "$tmp" "$log_path" || rm -f "$tmp"
  fi
}

tmux_revive_session_guid_option() {
  printf '%s\n' "@tmux-revive-session-guid"
}

tmux_revive_session_label_option() {
  printf '%s\n' "@tmux-revive-session-label"
}

tmux_revive_startup_restore_option() {
  printf '%s\n' "@tmux-revive-startup-restore"
}

tmux_revive_default_profile_option() {
  printf '%s\n' "@tmux-revive-default-profile"
}

tmux_revive_pre_save_hook_option() {
  printf '%s\n' "@tmux-revive-pre-save-hook"
}

tmux_revive_post_save_hook_option() {
  printf '%s\n' "@tmux-revive-post-save-hook"
}

tmux_revive_pre_restore_hook_option() {
  printf '%s\n' "@tmux-revive-pre-restore-hook"
}

tmux_revive_post_restore_hook_option() {
  printf '%s\n' "@tmux-revive-post-restore-hook"
}

tmux_revive_save_lock_timeout_option() {
  printf '%s\n' "@tmux-revive-save-lock-timeout"
}

tmux_revive_retention_enabled_option() {
  printf '%s\n' "@tmux-revive-retention-enabled"
}

tmux_revive_retention_auto_count_option() {
  printf '%s\n' "@tmux-revive-retention-auto-count"
}

tmux_revive_retention_manual_count_option() {
  printf '%s\n' "@tmux-revive-retention-manual-count"
}

tmux_revive_retention_auto_age_days_option() {
  printf '%s\n' "@tmux-revive-retention-auto-age-days"
}

tmux_revive_retention_manual_age_days_option() {
  printf '%s\n' "@tmux-revive-retention-manual-age-days"
}

tmux_revive_get_global_option() {
  local option_name="$1"
  local default_value="${2:-}"
  local result=""
  result="$(tmux show-option -gqv "$option_name" 2>/dev/null || printf '')"
  if [ -n "$result" ]; then
    printf '%s\n' "$result"
  else
    printf '%s\n' "$default_value"
  fi
}

tmux_revive_get_env_or_global_option() {
  local env_name="$1"
  local option_name="$2"
  local default_value="${3:-}"
  local env_value=""

  env_value="${!env_name-}"
  if [ -n "$env_value" ]; then
    printf '%s\n' "$env_value"
    return 0
  fi

  tmux_revive_get_global_option "$option_name" "$default_value"
}

tmux_revive_startup_restore_mode() {
  local option_name option_value profile_path
  option_name="$(tmux_revive_startup_restore_option)"
  option_value="$(tmux_revive_get_global_option "$option_name" "prompt")"
  if profile_path="$(tmux_revive_profile_path "" 2>/dev/null)"; then
    tmux_revive_profile_read_string "$profile_path" "startup_mode" "$option_value"
    return 0
  fi
  printf '%s\n' "$option_value"
}

tmux_revive_default_profile_name() {
  tmux_revive_get_env_or_global_option "TMUX_REVIVE_DEFAULT_PROFILE" "$(tmux_revive_default_profile_option)" ""
}

tmux_revive_option_enabled() {
  local value="${1:-}"
  case "$value" in
    1|on|ON|true|TRUE|yes|YES|enabled|ENABLED)
      return 0
      ;;
  esac
  return 1
}

tmux_revive_run_hook() {
  local env_name="$1"
  local option_name="$2"
  shift || true
  local hook_command=""

  shift || true
  hook_command="$(tmux_revive_get_env_or_global_option "$env_name" "$option_name" "")"
  [ -n "$hook_command" ] || return 0

  local hook_log
  hook_log="$(tmux_revive_runtime_dir)/hook-errors.log"
  mkdir -p "$(dirname "$hook_log")" 2>/dev/null || true
  local hook_exit=0
  env "$@" sh -c "$hook_command" >/dev/null 2>>"$hook_log" || hook_exit=$?
  if [ "$hook_exit" -ne 0 ]; then
    printf '[%s] hook failed (exit %s): %s\n' "$(date +%Y-%m-%dT%H:%M:%S)" "$hook_exit" "$hook_command" >>"$hook_log"
    tmux_revive_truncate_log "$hook_log" 200
    return 1
  fi
}

tmux_revive_generate_guid() {
  if command -v uuidgen >/dev/null 2>&1; then
    uuidgen | tr '[:upper:]' '[:lower:]'
    return 0
  fi

  if command -v openssl >/dev/null 2>&1; then
    openssl rand -hex 16 | sed -E 's/^(.{8})(.{4})(.{4})(.{4})(.{12})$/\1-\2-\3-\4-\5/'
    return 0
  fi

  if [ -r /dev/urandom ]; then
    od -An -tx1 -N16 /dev/urandom | tr -d ' \n' | sed -E 's/^(.{8})(.{4})(.{4})(.{4})(.{12})$/\1-\2-\3-\4-\5/'
    return 0
  fi
  printf '%(%s)T-%s\n' -1 "$RANDOM$RANDOM"
}

tmux_revive_get_session_guid() {
  local target="$1"
  tmux show-options -qv -t "$target" "$(tmux_revive_session_guid_option)" 2>/dev/null || true
}

tmux_revive_set_session_guid() {
  local target="$1"
  local session_guid="$2"
  [ -n "$session_guid" ] || return 0
  tmux set-option -q -t "$target" "$(tmux_revive_session_guid_option)" "$session_guid"
}

tmux_revive_ensure_session_guid() {
  local target="$1"
  local session_guid
  session_guid="$(tmux_revive_get_session_guid "$target")"
  if [ -z "$session_guid" ]; then
    session_guid="$(tmux_revive_generate_guid)"
    tmux_revive_set_session_guid "$target" "$session_guid"
  fi

  printf '%s\n' "$session_guid"
}

tmux_revive_get_session_label() {
  local target="$1"
  tmux show-options -qv -t "$target" "$(tmux_revive_session_label_option)" 2>/dev/null || true
}

tmux_revive_set_session_label() {
  local target="$1"
  local session_label="$2"
  [ -n "$session_label" ] || return 0
  tmux set-option -q -t "$target" "$(tmux_revive_session_label_option)" "$session_label"
}

tmux_revive_session_label_or_name() {
  local target="$1"
  local fallback_name="${2:-}"
  local session_label
  session_label="$(tmux_revive_get_session_label "$target")"
  if [ -n "$session_label" ]; then
    printf '%s\n' "$session_label"
  else
    printf '%s\n' "$fallback_name"
  fi
}

tmux_revive_normalize_session_name_for_tmux() {
  local raw_name="${1:-}"
  local normalized
  normalized="$(printf '%s\n' "$raw_name" | tr '[:space:]:/' '-' | LC_ALL=C sed -E 's/[^[:alnum:]_.-]+/-/g; s/^-+//; s/-+$//; s/-+/-/g')"
  if [ -z "$normalized" ]; then
    normalized="session"
  fi
  printf '%s\n' "$normalized"
}

tmux_revive_default_tmux_session_name() {
  local session_label="${1:-session}"
  local session_guid="${2:-}"
  local normalized_label short_guid
  normalized_label="$(tmux_revive_normalize_session_name_for_tmux "$session_label")"
  short_guid="$(printf '%s\n' "$session_guid" | tr -d '-' | cut -c1-8)"
  if [ -z "$short_guid" ]; then
    short_guid="$(tmux_revive_generate_guid | tr -d '-' | cut -c1-8)"
  fi
  printf '%s.%s\n' "$normalized_label" "$short_guid"
}

tmux_revive_latest_path() {
  printf '%s/latest.json\n' "$(tmux_revive_snapshots_root)"
}

tmux_revive_pending_save_path() {
  printf '%s/pending-save\n' "$(tmux_revive_runtime_dir)"
}

tmux_revive_last_auto_save_path() {
  printf '%s/last-auto-save\n' "$(tmux_revive_runtime_dir)"
}

tmux_revive_last_save_notice_path() {
  printf '%s/last-save-notice.json\n' "$(tmux_revive_runtime_dir)"
}

tmux_revive_startup_popup_dismissed_path() {
  printf '%s/startup-popup-dismissed\n' "$(tmux_revive_runtime_dir)"
}

tmux_revive_restore_prompt_shown_path() {
  printf '%s/startup-popup-shown\n' "$(tmux_revive_runtime_dir)"
}

tmux_revive_last_prompted_manifest_path() {
  printf '%s/last-prompted-manifest\n' "$(tmux_revive_runtime_dir)"
}

tmux_revive_restore_prompt_suppressed_path() {
  printf '%s/restore-prompt-suppressed\n' "$(tmux_revive_runtime_dir)"
}

tmux_revive_latest_restore_report_path() {
  printf '%s/latest-restore-report.json\n' "$(tmux_revive_restore_logs_root)"
}

tmux_revive_transient_session_option() {
  printf '%s\n' "@tmux-revive-transient-session"
}

tmux_revive_resolve_pane_id() {
  local pane_id="${1:-}"
  if [ -n "$pane_id" ]; then
    printf '%s\n' "$pane_id"
    return 0
  fi

  tmux display-message -p '#{pane_id}'
}

tmux_revive_pane_meta_path() {
  local pane_id
  pane_id="$(tmux_revive_resolve_pane_id "${1:-}")"
  printf '%s/%s.json\n' "$(tmux_revive_pane_meta_root)" "$pane_id"
}

tmux_revive_read_json_bool() {
  local path="$1"
  local key="$2"
  if [ ! -f "$path" ]; then
    printf 'false\n'
    return 0
  fi

  jq -r --arg key "$key" '.[$key] // false' "$path"
}

tmux_revive_read_json_string() {
  local path="$1"
  local key="$2"
  if [ ! -f "$path" ]; then
    printf '\n'
    return 0
  fi

  jq -r --arg key "$key" '.[$key] // ""' "$path"
}

tmux_revive_write_json_file() {
  local path="$1"
  local tmp_path
  tmp_path="${path}.tmp.$$"
  mkdir -p "$(dirname "$path")"
  cat >"$tmp_path" || { rm -f "$tmp_path"; return 1; }
  mv "$tmp_path" "$path" || { rm -f "$tmp_path"; return 1; }
}

tmux_revive_mark_runtime_flag() {
  local path="$1"
  mkdir -p "$(dirname "$path")"
  : >"$path"
}

tmux_revive_clear_runtime_flag() {
  local path="$1"
  rm -f "$path"
}

tmux_revive_has_runtime_flag() {
  local path="$1"
  [ -f "$path" ]
}

tmux_revive_find_latest_manifest() {
  local latest_path
  latest_path="$(tmux_revive_latest_path)"
  if [ ! -f "$latest_path" ]; then
    return 1
  fi

  jq -r '.manifest_path // ""' "$latest_path"
}

tmux_revive_read_runtime_value() {
  local path="$1"
  [ -f "$path" ] || return 1
  cat "$path"
}

tmux_revive_write_runtime_value() {
  local path="$1"
  local value="${2:-}"
  mkdir -p "$(dirname "$path")"
  printf '%s\n' "$value" >"$path"
}

tmux_revive_resolve_profile_path() {
  local profile_ref="${1:-}"
  local profiles_root candidate

  [ -n "$profile_ref" ] || return 1
  if [ -f "$profile_ref" ]; then
    printf '%s\n' "$profile_ref"
    return 0
  fi

  profiles_root="$(tmux_revive_profiles_root)"
  candidate="$profiles_root/$profile_ref.json"
  if [ -f "$candidate" ]; then
    printf '%s\n' "$candidate"
    return 0
  fi

  candidate="$profiles_root/$profile_ref"
  if [ -f "$candidate" ]; then
    printf '%s\n' "$candidate"
    return 0
  fi

  return 1
}

tmux_revive_profile_path() {
  local requested_profile="${1:-}"
  local effective_profile="${requested_profile:-}"

  if [ -z "$effective_profile" ]; then
    effective_profile="$(tmux_revive_default_profile_name)"
  fi

  [ -n "$effective_profile" ] || return 1
  tmux_revive_resolve_profile_path "$effective_profile"
}

tmux_revive_profile_read_string() {
  local profile_path="${1:-}"
  local key="${2:-}"
  local default_value="${3:-}"
  [ -n "$profile_path" ] || {
    printf '%s\n' "$default_value"
    return 0
  }
  [ -f "$profile_path" ] || {
    printf '%s\n' "$default_value"
    return 0
  }
  jq -r --arg key "$key" --arg default_value "$default_value" '.[$key] // $default_value' "$profile_path" 2>/dev/null || printf '%s\n' "$default_value"
}

tmux_revive_profile_read_bool() {
  local profile_path="${1:-}"
  local key="${2:-}"
  local default_value="${3:-false}"
  local value
  value="$(tmux_revive_profile_read_string "$profile_path" "$key" "$default_value")"
  if tmux_revive_option_enabled "$value"; then
    printf 'true\n'
  else
    printf 'false\n'
  fi
}

tmux_revive_session_is_archived() {
  local session_guid="${1:-}"
  local index_path archived_value
  [ -n "$session_guid" ] || return 1
  index_path="$(tmux_revive_session_index_path)"
  [ -f "$index_path" ] || return 1
  archived_value="$(jq -r --arg guid "$session_guid" '.sessions[$guid].archived // false' "$index_path" 2>/dev/null || printf 'false')"
  [ "$archived_value" = "true" ]
}

tmux_revive_set_session_archived() {
  local session_guid="${1:-}"
  local archived_value="${2:-true}"
  local index_path tmp_path archived_at

  [ -n "$session_guid" ] || return 1
  index_path="$(tmux_revive_session_index_path)"
  tmp_path="${index_path}.tmp.$$"
  archived_at=""
  if [ "$archived_value" = "true" ]; then
    archived_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  fi

  mkdir -p "$(dirname "$index_path")"
  [ ! -f "$index_path" ] || cp -f "$index_path" "${index_path}.bak" 2>/dev/null || true
  if [ -f "$index_path" ]; then
    jq \
      --arg guid "$session_guid" \
      --arg archived_value "$archived_value" \
      --arg archived_at "$archived_at" \
      '
        .sessions = (.sessions // {})
        | .sessions[$guid] = ((.sessions[$guid] // {}) + { archived: ($archived_value == "true") })
        | if $archived_value == "true"
          then .sessions[$guid].archived_at = $archived_at
          else .sessions[$guid] |= del(.archived_at)
          end
      ' "$index_path" >"$tmp_path" || { rm -f "$tmp_path"; return 1; }
  else
    jq -n \
      --arg guid "$session_guid" \
      --arg archived_value "$archived_value" \
      --arg archived_at "$archived_at" \
      '{
        sessions: {
          ($guid): (
            if $archived_value == "true"
            then { archived: true, archived_at: $archived_at }
            else { archived: false }
            end
          )
        }
      }' >"$tmp_path" || { rm -f "$tmp_path"; return 1; }
  fi
  mv "$tmp_path" "$index_path" || { rm -f "$tmp_path"; return 1; }
}

tmux_revive_mark_transient_session() {
  local target="$1"
  [ -n "$target" ] || return 0
  tmux set-option -q -t "$target" "$(tmux_revive_transient_session_option)" "1"
}

tmux_revive_clear_transient_session_marker() {
  local target="$1"
  [ -n "$target" ] || return 0
  tmux set-option -qu -t "$target" "$(tmux_revive_transient_session_option)" >/dev/null 2>&1 || true
}

tmux_revive_session_is_transient() {
  local target="$1"
  local value
  [ -n "$target" ] || return 1
  value="$(tmux show-options -qv -t "$target" "$(tmux_revive_transient_session_option)" 2>/dev/null || true)"
  [ "$value" = "1" ]
}

tmux_revive_shell_name() {
  local shell_bin="${1:-${SHELL:-/bin/sh}}"
  basename "$shell_bin"
}

tmux_revive_shell_supports_wrapper() {
  case "$(tmux_revive_shell_name "${1:-}")" in
    zsh|bash)
      return 0
      ;;
  esac

  return 1
}

tmux_revive_shell_history_file() {
  local shell_bin="${1:-${SHELL:-/bin/sh}}"

  case "$(tmux_revive_shell_name "$shell_bin")" in
    zsh)
      printf '%s\n' "${TMUX_REVIVE_ZSH_HISTFILE:-${ZDOTDIR:-$HOME}/.zsh_history}"
      ;;
    bash)
      printf '%s\n' "${TMUX_REVIVE_BASH_HISTFILE:-$HOME/.bash_history}"
      ;;
    *)
      return 1
      ;;
  esac
}

tmux_revive_command_is_shell() {
  local command="${1:-}"

  case "$command" in
    zsh|bash|sh|fish)
      return 0
      ;;
  esac

  return 1
}

tmux_revive_process_table() {
  ps -Ao pid=,ppid=,comm=,args= 2>/dev/null || return 1
}

tmux_revive_capture_running_command() {
  local process_table="${1:-}"
  local pane_pid="${2:-}"
  local pane_command="${3:-}"

  [ -n "$process_table" ] || return 1
  [ -n "$pane_pid" ] || return 1
  [ -n "$pane_command" ] || return 1
  tmux_revive_command_is_shell "$pane_command" && return 1

  awk -v pane_pid="$pane_pid" -v target="$pane_command" '
    {
      pid = $1
      ppid = $2
      comm = $3
      $1 = ""
      $2 = ""
      $3 = ""
      sub(/^[[:space:]]+/, "", $0)
      args = $0

      if (pid == "" || comm == "") {
        next
      }

      parent_by_pid[pid] = ppid
      comm_by_pid[pid] = comm
      args_by_pid[pid] = args
    }
    END {
      best = ""
      best_depth = -1
      best_len = -1

      for (pid in comm_by_pid) {
        if (comm_by_pid[pid] != target) {
          continue
        }

        depth = 0
        current = pid
        found = 0
        while (current != "") {
          if (current == pane_pid) {
            found = 1
            break
          }
          current = parent_by_pid[current]
          depth++
          if (depth > 200) {
            break
          }
        }

        if (!found) {
          continue
        }

        candidate = args_by_pid[pid]
        if (candidate == "") {
          continue
        }

        candidate_len = length(candidate)
        if (best == "" || depth > best_depth || (depth == best_depth && candidate_len > best_len)) {
          best = candidate
          best_depth = depth
          best_len = candidate_len
        }
      }

      if (best != "") {
        print best
      }
    }
  ' <<< "$process_table"
}

tmux_revive_capture_pane_command_preview() {
  local process_table="${1:-}"
  local pane_pid="${2:-}"
  local pane_command="${3:-}"
  local existing_preview="${4:-}"

  if [ -n "$existing_preview" ]; then
    printf '%s\n' "$existing_preview"
    return 0
  fi

  tmux_revive_capture_running_command "$process_table" "$pane_pid" "$pane_command"
}

tmux_revive_command_is_restartable() {
  local command="${1:-}"
  local cmd1="" cmd2="" cmd3="" rest=""

  [ -n "$command" ] || return 1
  read -r cmd1 cmd2 cmd3 rest <<<"$command"

  case "$cmd1" in
    tail)
      case "$command" in
        "tail -f "*|"tail -F "*|"tail -n "*' -f '*|"tail -n "*' -F '*|"tail --lines "*' -f '*|"tail --lines "*' -F '*)
          return 0
          ;;
      esac
      return 1
      ;;
    make|just)
      return 0
      ;;
    npm|pnpm)
      [ "$cmd2" = "run" ]
      return
      ;;
    yarn)
      if [ "$cmd2" = "run" ]; then
        return 0
      fi
      [ -n "$cmd2" ] && [ "${cmd2#-}" = "$cmd2" ]
      return
      ;;
    uv|cargo|go)
      [ "$cmd2" = "run" ]
      return
      ;;
    docker-compose)
      [ "$cmd2" = "up" ]
      return
      ;;
    docker)
      [ "$cmd2" = "compose" ] && [ "$cmd3" = "up" ]
      return
      ;;
    python|python3)
      [ "$cmd2" = "-m" ] && [ "$cmd3" = "http.server" ]
      return
      ;;
  esac

  # Check user-configured restartable commands (space-separated entries)
  # Supported formats:
  #   command_name         — exact first-word match
  #   ~substring           — match if substring appears anywhere in the full command
  #   ~substring->replacement    — substring match, restore with replacement command
  #   ~substring->replacement *  — substring match, restore with replacement + original args
  local user_commands
  user_commands="$(tmux show-option -gqv '@tmux-revive-restartable-commands' 2>/dev/null || printf '')"
  if [ -n "$user_commands" ]; then
    local user_cmd
    for user_cmd in $user_commands; do
      local match_part="${user_cmd%%->*}"
      if [[ "$match_part" == ~* ]]; then
        # Substring match: ~ prefix
        local pattern="${match_part#\~}"
        [[ "$command" == *"$pattern"* ]] && return 0
      else
        # Exact first-word match (original behavior)
        [ "$cmd1" = "$match_part" ] && return 0
      fi
    done
  fi

  return 1
}

# Resolve the restart command for user-configured entries with -> replacement.
# Returns the replacement command on stdout, or the original command if no
# replacement pattern matches.
tmux_revive_resolve_restart_command() {
  local command="${1:-}"
  [ -n "$command" ] || return 0

  local user_commands
  user_commands="$(tmux show-option -gqv '@tmux-revive-restartable-commands' 2>/dev/null || printf '')"
  [ -n "$user_commands" ] || { printf '%s' "$command"; return 0; }

  local cmd1=""
  read -r cmd1 _ <<<"$command"

  local user_cmd
  for user_cmd in $user_commands; do
    [[ "$user_cmd" == *"->"* ]] || continue
    local match_part="${user_cmd%%->*}"
    local replace_part="${user_cmd#*->}"
    local matched="false"

    if [[ "$match_part" == ~* ]]; then
      local pattern="${match_part#\~}"
      [[ "$command" == *"$pattern"* ]] && matched="true"
    else
      [ "$cmd1" = "$match_part" ] && matched="true"
    fi

    if [ "$matched" = "true" ]; then
      if [[ "$replace_part" == *" *" ]]; then
        # Argument preservation: extract args after the matched pattern
        local args=""
        if [[ "$match_part" == ~* ]]; then
          local pattern="${match_part#\~}"
          args="$(printf '%s' "$command" | sed "s,^.*${pattern}[^ ]* *,,")"
        else
          args="${command#"$cmd1" }"
          [ "$args" != "$command" ] || args=""
        fi
        replace_part="${replace_part% \*}"
        if [ -n "$args" ]; then
          printf '%s %s' "$replace_part" "$args"
        else
          printf '%s' "$replace_part"
        fi
      else
        printf '%s' "$replace_part"
      fi
      return 0
    fi
  done

  printf '%s' "$command"
}

tmux_revive_tail_target_path() {
  local command="${1:-}"
  local parts=()
  local last_part=""

  [ -n "$command" ] || return 1
  read -r -a parts <<<"$command"
  [ "${#parts[@]}" -gt 0 ] || return 1
  [ "${parts[0]}" = "tail" ] || return 1
  tmux_revive_command_is_restartable "$command" || return 1

  last_part="${parts[${#parts[@]}-1]}"
  [ -n "$last_part" ] || return 1
  printf '%s\n' "$last_part"
}

tmux_revive_classify_restore_strategy() {
  local pane_command="${1:-}"
  local command_preview="${2:-}"
  local restart_command="${3:-}"
  local nvim_state_ref="${4:-}"
  local transcript_excluded="${5:-false}"

  if [ -n "$nvim_state_ref" ]; then
    printf 'nvim\n'
  elif [ -n "$restart_command" ]; then
    printf 'restart-command\n'
  elif ! tmux_revive_command_is_shell "$pane_command" && [ -n "$command_preview" ] && tmux_revive_command_is_restartable "$command_preview"; then
    printf 'restart-command\n'
  elif [ -n "$command_preview" ]; then
    printf 'manual-command\n'
  elif [ "$transcript_excluded" = "true" ]; then
    printf 'shell\n'
  else
    printf 'shell\n'
  fi
}

tmux_revive_fzf_colors() {
  TOKYO_FZF_COLORS=(
    "--ansi"
    "--color=bg:#1a1b26"
    "--color=bg+:#292e42"
    "--color=fg:#c0caf5"
    "--color=fg+:#c0caf5"
    "--color=hl:#7aa2f7"
    "--color=hl+:#7dcfff"
    "--color=info:#737aa2"
    "--color=border:#565f89"
    "--color=prompt:#7aa2f7"
    "--color=pointer:#7dcfff"
    "--color=marker:#9ece6a"
    "--color=spinner:#7dcfff"
    "--color=header:#bb9af7"
    "--color=gutter:#1a1b26"
  )
}
