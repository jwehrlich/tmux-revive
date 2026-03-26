#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/parse-server-arg.sh
source "$script_dir/lib/parse-server-arg.sh"
# shellcheck source=lib/state-common.sh
source "$script_dir/lib/state-common.sh"

usage() {
  cat <<'EOF'
Usage:
  pane-meta.sh exclude-transcript on [pane_id]
  pane-meta.sh exclude-transcript off [pane_id]
  pane-meta.sh exclude-transcript status [pane_id]
  pane-meta.sh strategy <auto|shell|history_only|manual-command|restart-command> [pane_id]
  pane-meta.sh set-command-preview <command> [pane_id]
  pane-meta.sh clear-command-preview [pane_id]
  pane-meta.sh set-restart-command <command> [pane_id]
  pane-meta.sh clear-restart-command [pane_id]
  pane-meta.sh show [pane_id]
EOF
}

update_meta() {
  local pane_id="$1"
  shift
  local path tmp_path

  path="$(tmux_revive_pane_meta_path "$pane_id")"
  tmp_path="${path}.tmp.$$"
  mkdir -p "$(dirname "$path")"

  if [ -f "$path" ]; then
    jq "$@" "$path" >"$tmp_path" || { rm -f "$tmp_path"; return 1; }
  else
    jq -n "$@" >"$tmp_path" || { rm -f "$tmp_path"; return 1; }
  fi

  mv "$tmp_path" "$path" || { rm -f "$tmp_path"; return 1; }
}

cmd="${1:-}"
[ -n "$cmd" ] || {
  usage >&2
  exit 1
}
shift

case "$cmd" in
  exclude-transcript)
    action="${1:-}"
    pane_id="${2:-}"
    pane_id="$(tmux_revive_resolve_pane_id "$pane_id")"
    case "$action" in
      on)
        update_meta "$pane_id" '.transcript_excluded = true'
        ;;
      off)
        update_meta "$pane_id" '.transcript_excluded = false'
        ;;
      status)
        tmux_revive_read_json_bool "$(tmux_revive_pane_meta_path "$pane_id")" "transcript_excluded"
        ;;
      *)
        usage >&2
        exit 1
        ;;
    esac
    ;;
  strategy)
    strategy="${1:-}"
    pane_id="${2:-}"
    pane_id="$(tmux_revive_resolve_pane_id "$pane_id")"
    case "$strategy" in
      auto)
        update_meta "$pane_id" 'del(.restore_strategy_override)'
        ;;
      shell|history_only|manual-command|restart-command)
        update_meta "$pane_id" --arg value "$strategy" '.restore_strategy_override = $value'
        ;;
      *)
        usage >&2
        exit 1
        ;;
    esac
    ;;
  set-command-preview)
    preview="${1:-}"
    pane_id="${2:-}"
    [ -n "$preview" ] || {
      usage >&2
      exit 1
    }
    pane_id="$(tmux_revive_resolve_pane_id "$pane_id")"
    update_meta "$pane_id" --arg value "$preview" '.command_preview = $value | .command_capture_source = "helper" | .restore_strategy_override = "manual-command"'
    ;;
  clear-command-preview)
    pane_id="${1:-}"
    pane_id="$(tmux_revive_resolve_pane_id "$pane_id")"
    update_meta "$pane_id" 'del(.command_preview, .command_capture_source) | if .restore_strategy_override == "manual-command" then del(.restore_strategy_override) else . end'
    ;;
  set-restart-command)
    restart_command="${1:-}"
    pane_id="${2:-}"
    [ -n "$restart_command" ] || {
      usage >&2
      exit 1
    }
    pane_id="$(tmux_revive_resolve_pane_id "$pane_id")"
    update_meta "$pane_id" --arg value "$restart_command" '.restart_command = $value | .restart_command_source = "explicit" | .restore_strategy_override = "restart-command"'
    ;;
  clear-restart-command)
    pane_id="${1:-}"
    pane_id="$(tmux_revive_resolve_pane_id "$pane_id")"
    update_meta "$pane_id" 'del(.restart_command, .restart_command_source) | if .restore_strategy_override == "restart-command" then del(.restore_strategy_override) else . end'
    ;;
  show)
    pane_id="${1:-}"
    pane_id="$(tmux_revive_resolve_pane_id "$pane_id")"
    path="$(tmux_revive_pane_meta_path "$pane_id")"
    if [ -f "$path" ]; then
      cat "$path"
    else
      jq -n '{}'
    fi
    ;;
  *)
    usage >&2
    exit 1
    ;;
esac
