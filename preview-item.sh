#!/usr/bin/env bash
# preview-item.sh — fzf preview dispatcher for Revive (pick.sh)
#
# Called by fzf --preview with positional args extracted from TSV fields:
#   $1 = row_kind   (header, live, saved)
#   $2 = kind        (session, window, pane, guid, name, id)
#   $3 = id          (tmux target for live; selector value for saved)
#   $4 = session_name
#   $5 = resource_id
#   $6 = manifest_path
#   $7 = restore_state_cmd
set -euo pipefail

row_kind="${1:-}"
kind="${2:-}"
id="${3:-}"
session_name="${4:-}"
resource_id="${5:-}"
manifest_path="${6:-}"
restore_state_cmd="${7:-}"

# Headers and nav rows have no preview content
if [ "$row_kind" = "header" ] || [ "$row_kind" = "nav" ] || [ -z "$row_kind" ]; then
  exit 0
fi

# ── Template items ────────────────────────────────────────────────────
if [ "$row_kind" = "template" ]; then
  # id=template_name, session_name=description, resource_id=session_count
  script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  # shellcheck source=lib/state-common.sh
  source "$script_dir/lib/state-common.sh"
  tpl_file="$(tmux_revive_templates_root)/${id}.yaml"
  if [ -f "$tpl_file" ]; then
    printf '\033[1;38;2;224;175;104mTemplate: %s\033[0m\n' "$id"
    [ -n "$session_name" ] && printf '\033[38;2;125;207;255m%s\033[0m\n' "$session_name"
    printf '\n'
    if command -v yq >/dev/null 2>&1; then
      yq -C '.' "$tpl_file" 2>/dev/null || cat "$tpl_file"
    else
      printf '\033[33m(yq not installed — showing raw YAML)\033[0m\n\n'
      cat "$tpl_file"
    fi
  else
    printf 'Template file not found: %s\n' "$tpl_file"
  fi
  exit 0
fi

# ── Snapshot items ────────────────────────────────────────────────────
if [ "$row_kind" = "snapshot" ]; then
  # id=manifest_path, session_name=reason, resource_id=session_count
  snapshot_manifest="$id"
  if [ -n "$snapshot_manifest" ] && [ -f "$snapshot_manifest" ] && [ -n "$restore_state_cmd" ]; then
    "$restore_state_cmd" --manifest "$snapshot_manifest" --preview 2>/dev/null \
      || printf 'Preview unavailable for this snapshot.\n'
  else
    printf 'No manifest available for preview.\n'
  fi
  exit 0
fi

# ── Live items ────────────────────────────────────────────────────────
if [ "$row_kind" = "live" ]; then
  case "$kind" in
    session)
      printf '\033[1;38;2;187;154;247mSession: %s\033[0m\n\n' "$session_name"
      tmux list-windows -t "$id" \
        -F '#{window_index}: #{window_name}  (#{window_panes} panes)' 2>/dev/null \
        || printf 'Session no longer exists.\n'
      ;;
    window)
      printf '\033[1;38;2;122;162;247mWindow: %s\033[0m\n\n' "$resource_id"
      tmux list-panes -t "$id" \
        -F '#{pane_index}: #{pane_current_command}  #{pane_current_path}' 2>/dev/null \
        || printf 'Window no longer exists.\n'
      ;;
    pane)
      printf '\033[1;38;2;125;207;255mPane: %s\033[0m\n\n' "$resource_id"
      tmux capture-pane -t "$id" -p -e 2>/dev/null | tail -50 \
        || printf 'Pane no longer exists.\n'
      ;;
    *)
      printf 'Unknown live kind: %s\n' "$kind"
      ;;
  esac
  exit 0
fi

# ── Saved items ───────────────────────────────────────────────────────
if [ "$row_kind" = "saved" ]; then
  if [ -z "$manifest_path" ] || [ -z "$restore_state_cmd" ]; then
    printf 'No manifest available for preview.\n'
    exit 0
  fi

  args=(--manifest "$manifest_path" --preview)
  case "$kind" in
    guid) args+=(--session-guid "$id") ;;
    id)   args+=(--session-id "$id") ;;
    name) args+=(--session-name "$id") ;;
    *)
      printf 'Unknown saved kind: %s\n' "$kind"
      exit 0
      ;;
  esac

  "$restore_state_cmd" "${args[@]}" 2>/dev/null \
    || printf 'Preview unavailable for this saved session.\n'
  exit 0
fi

# ── Fallback ──────────────────────────────────────────────────────────
printf 'No preview for row_kind=%s\n' "$row_kind"
