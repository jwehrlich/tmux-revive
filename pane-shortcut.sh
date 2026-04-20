#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/parse-server-arg.sh
source "$script_dir/lib/parse-server-arg.sh"
# shellcheck source=lib/state-common.sh
source "$script_dir/lib/state-common.sh"

# ---------------------------------------------------------------------------
# Pane Shortcuts — numbered bookmarks (1–9) that jump to a specific pane.
#
# Storage: $runtime_dir/pane-shortcuts.json
# Format:
#   { "1": { "session_guid": "...", "window_index": N, "pane_index": N }, ... }
#
# Shortcuts are per-server (runtime dir is scoped by socket key) and survive
# save/restore via the manifest's pane_shortcuts field.
# ---------------------------------------------------------------------------

action=""
slot=""
pane_id=""
manifest_path=""

while [ $# -gt 0 ]; do
  case "$1" in
    --set)
      action="set"
      slot="${2:?--set requires a slot number (1-9)}"
      shift 2
      ;;
    --jump)
      action="jump"
      slot="${2:?--jump requires a slot number (1-9)}"
      shift 2
      ;;
    --list)
      action="list"
      shift
      ;;
    --clear)
      action="clear"
      slot="${2:?--clear requires a slot number (1-9)}"
      shift 2
      ;;
    --load-from-manifest)
      action="load"
      manifest_path="${2:?--load-from-manifest requires a manifest path}"
      shift 2
      ;;
    --pane-id)
      pane_id="${2:?--pane-id requires a pane id}"
      shift 2
      ;;
    --server)
      export TMUX_REVIVE_TMUX_SERVER="${2:?--server requires a name}"
      shift 2
      ;;
    *)
      printf 'pane-shortcut: unknown argument: %s\n' "$1" >&2
      exit 1
      ;;
  esac
done

if [ -z "$action" ]; then
  printf 'pane-shortcut: no action specified (--set, --jump, --list, --clear, --load-from-manifest)\n' >&2
  exit 1
fi

# Validate slot is 1-9 when required
validate_slot() {
  case "$slot" in
    [1-9]) ;;
    *)
      printf 'pane-shortcut: slot must be 1-9, got: %s\n' "$slot" >&2
      exit 1
      ;;
  esac
}

runtime_dir="$(tmux_revive_runtime_dir)"
shortcuts_path="$runtime_dir/pane-shortcuts.json"

read_shortcuts() {
  if [ -f "$shortcuts_path" ]; then
    jq '.' "$shortcuts_path" 2>/dev/null || printf '{}\n'
  else
    printf '{}\n'
  fi
}

write_shortcuts() {
  mkdir -p "$runtime_dir"
  jq '.' | tmux_revive_write_json_file "$shortcuts_path"
}

# Resolve a GUID to the current tmux session name.
# Returns the session_id (e.g. $1) on stdout, or fails silently.
resolve_guid_to_session() {
  local target_guid="$1"
  local sid sguid
  while IFS=$'\t' read -r sid sguid; do
    if [ "$sguid" = "$target_guid" ]; then
      printf '%s\n' "$sid"
      return 0
    fi
  done < <(
    tmux list-sessions -F '#{session_id}' 2>/dev/null | while read -r _sid; do
      _guid="$(tmux show-options -qv -t "$_sid" "@tmux-revive-session-guid" 2>/dev/null || true)"
      printf '%s\t%s\n' "$_sid" "$_guid"
    done
  )
  return 1
}

# ---------------------------------------------------------------------------
# Actions
# ---------------------------------------------------------------------------

case "$action" in
  set)
    validate_slot
    if [ -z "$pane_id" ]; then
      printf 'pane-shortcut: --set requires --pane-id\n' >&2
      exit 1
    fi

    # Resolve pane to its coordinates
    session_id="$(tmux display-message -t "$pane_id" -p '#{session_id}' 2>/dev/null)" || {
      printf 'pane-shortcut: cannot resolve pane %s\n' "$pane_id" >&2
      exit 1
    }
    window_index="$(tmux display-message -t "$pane_id" -p '#{window_index}' 2>/dev/null)" || {
      printf 'pane-shortcut: cannot resolve window for pane %s\n' "$pane_id" >&2
      exit 1
    }
    pane_index="$(tmux display-message -t "$pane_id" -p '#{pane_index}' 2>/dev/null)" || {
      printf 'pane-shortcut: cannot resolve pane index for %s\n' "$pane_id" >&2
      exit 1
    }

    # Ensure the session has a GUID
    session_guid="$(tmux_revive_ensure_session_guid "$session_id")"

    # Read current shortcuts, update, write back
    shortcuts="$(read_shortcuts)"
    printf '%s\n' "$shortcuts" |
      jq --arg slot "$slot" \
         --arg guid "$session_guid" \
         --argjson widx "${window_index}" \
         --argjson pidx "${pane_index}" \
         '.[$slot] = { session_guid: $guid, window_index: $widx, pane_index: $pidx }' |
      write_shortcuts

    # Friendly feedback
    session_name="$(tmux display-message -t "$pane_id" -p '#S' 2>/dev/null || printf '?')"
    tmux display-message "Shortcut $slot → ${session_name}:${window_index}.${pane_index}" 2>/dev/null || true
    ;;

  jump)
    validate_slot
    shortcuts="$(read_shortcuts)"
    entry="$(printf '%s\n' "$shortcuts" | jq -r --arg slot "$slot" '.[$slot] // empty')"
    if [ -z "$entry" ]; then
      # Slot not bound — silent no-op
      exit 0
    fi

    target_guid="$(printf '%s\n' "$entry" | jq -r '.session_guid')"
    target_widx="$(printf '%s\n' "$entry" | jq -r '.window_index')"
    target_pidx="$(printf '%s\n' "$entry" | jq -r '.pane_index')"

    # Resolve GUID to live session
    target_session_id="$(resolve_guid_to_session "$target_guid")" || {
      tmux display-message "Shortcut $slot: session no longer exists" 2>/dev/null || true
      exit 0
    }

    # Get session name for the target
    target_session_name="$(tmux display-message -t "$target_session_id" -p '#S' 2>/dev/null || true)"
    if [ -z "$target_session_name" ]; then
      tmux display-message "Shortcut $slot: session no longer exists" 2>/dev/null || true
      exit 0
    fi

    target="${target_session_name}:${target_widx}.${target_pidx}"
    if ! tmux switch-client -t "$target" 2>/dev/null; then
      tmux display-message "Shortcut $slot: target ${target} not found" 2>/dev/null || true
    fi
    ;;

  list)
    shortcuts="$(read_shortcuts)"
    if [ "$shortcuts" = "{}" ] || [ -z "$shortcuts" ]; then
      printf 'No pane shortcuts set.\n'
      exit 0
    fi

    printf 'Pane shortcuts:\n'
    for s in 1 2 3 4 5 6 7 8 9; do
      entry="$(printf '%s\n' "$shortcuts" | jq -r --arg slot "$s" '.[$slot] // empty')"
      [ -n "$entry" ] || continue
      guid="$(printf '%s\n' "$entry" | jq -r '.session_guid')"
      widx="$(printf '%s\n' "$entry" | jq -r '.window_index')"
      pidx="$(printf '%s\n' "$entry" | jq -r '.pane_index')"
      # Try to resolve for display
      session_name="?"
      if sid="$(resolve_guid_to_session "$guid" 2>/dev/null)"; then
        session_name="$(tmux display-message -t "$sid" -p '#S' 2>/dev/null || printf '?')"
      fi
      printf '  %s → %s:%s.%s\n' "$s" "$session_name" "$widx" "$pidx"
    done
    ;;

  clear)
    validate_slot
    shortcuts="$(read_shortcuts)"
    printf '%s\n' "$shortcuts" |
      jq --arg slot "$slot" 'del(.[$slot])' |
      write_shortcuts
    tmux display-message "Shortcut $slot cleared" 2>/dev/null || true
    ;;

  load)
    if [ ! -f "$manifest_path" ]; then
      printf 'pane-shortcut: manifest not found: %s\n' "$manifest_path" >&2
      exit 1
    fi

    manifest_shortcuts="$(jq -r '.pane_shortcuts // {}' "$manifest_path" 2>/dev/null || printf '{}')"
    if [ "$manifest_shortcuts" = "{}" ] || [ -z "$manifest_shortcuts" ] || [ "$manifest_shortcuts" = "null" ]; then
      exit 0
    fi

    # Filter to only shortcuts whose GUID matches a live session
    filtered="{}"
    for s in 1 2 3 4 5 6 7 8 9; do
      entry="$(printf '%s\n' "$manifest_shortcuts" | jq -r --arg slot "$s" '.[$slot] // empty')"
      [ -n "$entry" ] || continue
      guid="$(printf '%s\n' "$entry" | jq -r '.session_guid')"
      if resolve_guid_to_session "$guid" >/dev/null 2>&1; then
        filtered="$(printf '%s\n' "$filtered" | jq --arg slot "$s" --argjson entry "$entry" '.[$slot] = $entry')"
      fi
    done

    printf '%s\n' "$filtered" | write_shortcuts
    ;;
esac
