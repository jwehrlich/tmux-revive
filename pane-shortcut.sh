#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/parse-server-arg.sh
source "$script_dir/lib/parse-server-arg.sh"
# shellcheck source=lib/state-common.sh
source "$script_dir/lib/state-common.sh"

# ---------------------------------------------------------------------------
# Pane Shortcuts — numbered bookmarks (0–9) that jump to a specific pane.
#
# Storage: $runtime_dir/pane-shortcuts.json
# Format:
#   { "0": { "session_guid": "...", "window_index": N, "pane_index": N }, ... }
#
# Shortcuts are per-server (runtime dir is scoped by socket key) and survive
# save/restore via the manifest's pane_shortcuts field.
# ---------------------------------------------------------------------------

action=""
slot=""
pane_id=""
manifest_path=""
client_tty=""

while [ $# -gt 0 ]; do
  case "$1" in
    --set)
      action="set"
      slot="${2:?--set requires a slot number (0-9)}"
      shift 2
      ;;
    --jump)
      action="jump"
      slot="${2:?--jump requires a slot number (0-9)}"
      shift 2
      ;;
    --list)
      action="list"
      shift
      ;;
    --clear)
      action="clear"
      slot="${2:?--clear requires a slot number (0-9)}"
      shift 2
      ;;
    --load-from-manifest)
      action="load"
      manifest_path="${2:?--load-from-manifest requires a manifest path}"
      shift 2
      ;;
    --toggle-carousel)
      action="toggle-carousel"
      shift
      ;;
    --carousel-tick)
      action="carousel-tick"
      shift
      ;;
    --pane-id)
      pane_id="${2:?--pane-id requires a pane id}"
      shift 2
      ;;
    --client-tty)
      client_tty="${2:?--client-tty requires a tty path}"
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
  printf 'pane-shortcut: no action specified (--set, --jump, --list, --clear, --load-from-manifest, --toggle-carousel, --carousel-tick)\n' >&2
  exit 1
fi

shortcut_slots="0 1 2 3 4 5 6 7 8 9"

# Validate slot is 0-9 when required
validate_slot() {
  case "$slot" in
    [0-9]) ;;
    *)
      printf 'pane-shortcut: slot must be 0-9, got: %s\n' "$slot" >&2
      exit 1
      ;;
  esac
}

require_client_tty() {
  if [ -z "$client_tty" ]; then
    printf 'pane-shortcut: --client-tty is required for %s\n' "$action" >&2
    exit 1
  fi
}

runtime_dir="$(tmux_revive_runtime_dir)"
shortcuts_path="$runtime_dir/pane-shortcuts.json"
carousel_state_path="$runtime_dir/pane-shortcut-carousel.json"

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

read_carousel_state() {
  if [ -f "$carousel_state_path" ]; then
    jq '.' "$carousel_state_path" 2>/dev/null || printf '{}\n'
  else
    printf '{}\n'
  fi
}

write_carousel_state() {
  mkdir -p "$runtime_dir"
  jq '.' | tmux_revive_write_json_file "$carousel_state_path"
}

carousel_client_active() {
  local client_key="$1"
  read_carousel_state | jq -e --arg client "$client_key" 'has($client)' >/dev/null 2>&1
}

carousel_client_last_slot() {
  local client_key="$1"
  read_carousel_state | jq -r --arg client "$client_key" '.[$client].last_slot // ""'
}

carousel_write_client_state() {
  local client_key="$1"
  local last_slot="${2:-}"
  read_carousel_state |
    jq --arg client "$client_key" --arg last_slot "$last_slot" \
      '.[$client] = { last_slot: $last_slot }' |
    write_carousel_state
}

carousel_clear_client_state() {
  local client_key="$1"
  read_carousel_state |
    jq --arg client "$client_key" 'del(.[$client])' |
    write_carousel_state
}

carousel_interval() {
  local interval
  interval="$(tmux_revive_get_global_option '@tmux-revive-shortcut-carousel-interval' '10')"
  case "$interval" in
    ''|*[!0-9]*)
      interval=10
      ;;
  esac
  if [ "$interval" -lt 1 ]; then
    interval=10
  fi
  printf '%s\n' "$interval"
}

carousel_display_message() {
  local client_key="$1"
  local message="$2"
  if [ -n "$client_key" ]; then
    tmux display-message -c "$client_key" "$message" 2>/dev/null || true
  else
    tmux display-message "$message" 2>/dev/null || true
  fi
}

carousel_env_prefix() {
  local prefix=""
  if [ -n "${TMUX_REVIVE_SOCKET_PATH:-}" ]; then
    prefix="${prefix} TMUX_REVIVE_SOCKET_PATH=$(printf '%q' "$TMUX_REVIVE_SOCKET_PATH")"
  fi
  if [ -n "${TMUX_REVIVE_TMUX_SERVER:-}" ]; then
    prefix="${prefix} TMUX_REVIVE_TMUX_SERVER=$(printf '%q' "$TMUX_REVIVE_TMUX_SERVER")"
  fi
  if [ -n "${TMUX_REVIVE_STATE_ROOT:-}" ]; then
    prefix="${prefix} TMUX_REVIVE_STATE_ROOT=$(printf '%q' "$TMUX_REVIVE_STATE_ROOT")"
  fi
  prefix="${prefix# }"
  if [ -n "$prefix" ]; then
    printf 'env %s ' "$prefix"
  fi
}

schedule_carousel_tick() {
  local client_key="$1"
  local delay="${2:-}"
  local env_prefix command

  if [ -z "$delay" ]; then
    delay="$(carousel_interval)"
  fi

  env_prefix="$(carousel_env_prefix)"
  command="${env_prefix}$(printf '%q' "$script_dir/pane-shortcut.sh") --carousel-tick --client-tty $(printf '%q' "$client_key")"
  tmux run-shell -b -d "$delay" "$command" 2>/dev/null || true
}

carousel_client_exists() {
  local client_key="$1"
  tmux list-clients -F '#{client_tty}' 2>/dev/null | grep -Fx -- "$client_key" >/dev/null 2>&1
}

resolve_shortcut_entry() {
  local entry="$1"
  local target_guid target_widx target_pidx
  local target_session_id target_session_name target

  target_guid="$(printf '%s\n' "$entry" | jq -r '.session_guid')"
  target_widx="$(printf '%s\n' "$entry" | jq -r '.window_index')"
  target_pidx="$(printf '%s\n' "$entry" | jq -r '.pane_index')"

  target_session_id="$(resolve_guid_to_session "$target_guid")" || return 1
  target_session_name="$(tmux display-message -t "$target_session_id" -p '#S' 2>/dev/null || true)"
  [ -n "$target_session_name" ] || return 1

  if ! tmux list-panes -t "${target_session_id}:${target_widx}" -F '#{pane_index}' 2>/dev/null | grep -Fx -- "$target_pidx" >/dev/null 2>&1; then
    return 1
  fi

  target="${target_session_name}:${target_widx}.${target_pidx}"

  printf '%s\t%s\t%s\t%s\t%s\n' \
    "$target_session_id" "$target_session_name" "$target_widx" "$target_pidx" "$target"
}

read_shortcut_slot_entry() {
  local slot_key="$1"
  read_shortcuts | jq -c --arg slot "$slot_key" '.[$slot] // empty'
}

resolve_shortcut_slot_record() {
  local slot_key="$1"
  local entry resolved
  local target_session_id target_session_name target_widx target_pidx target

  entry="$(read_shortcut_slot_entry "$slot_key")"
  [ -n "$entry" ] || return 1

  resolved="$(resolve_shortcut_entry "$entry")" || return 1
  IFS=$'\t' read -r target_session_id target_session_name target_widx target_pidx target <<EOF
$resolved
EOF
  printf '%s\t%s\t%s:%s.%s\n' "$slot_key" "$target" "$target_session_name" "$target_widx" "$target_pidx"
}

ordered_shortcut_slots_after() {
  local after_slot="${1:-}"
  local found_after="false"
  local ordered=""
  local s

  if [ -z "$after_slot" ]; then
    printf '%s\n' "$shortcut_slots"
    return 0
  fi

  for s in $shortcut_slots; do
    if [ "$found_after" = "true" ]; then
      ordered="${ordered:+$ordered }$s"
    fi
    if [ "$s" = "$after_slot" ]; then
      found_after="true"
    fi
  done

  if [ "$found_after" != "true" ]; then
    printf '%s\n' "$shortcut_slots"
    return 0
  fi

  for s in $shortcut_slots; do
    if [ "$s" = "$after_slot" ]; then
      break
    fi
    ordered="${ordered:+$ordered }$s"
  done

  printf '%s\n' "$ordered"
}

select_next_carousel_shortcut() {
  local last_slot="$1"
  local slot record

  for slot in $(ordered_shortcut_slots_after "$last_slot"); do
    record="$(resolve_shortcut_slot_record "$slot")" || continue
    printf '%s\n' "$record"
    return 0
  done

  return 1
}

carousel_switch_to_single_record() {
  local client_key="$1"
  local record="$2"
  local next_slot remainder next_target next_display

  next_slot="${record%%	*}"
  remainder="${record#*	}"
  next_target="${remainder%%	*}"
  next_display="${remainder#*	}"

  if tmux switch-client -c "$client_key" -t "$next_target" 2>/dev/null; then
    carousel_write_client_state "$client_key" "$next_slot"
    return 0
  fi

  return 1
}

carousel_switch_to_record() {
  local client_key="$1"
  local record="$2"
  local current_slot slot next_record

  if carousel_switch_to_single_record "$client_key" "$record"; then
    return 0
  fi

  current_slot="${record%%	*}"
  for slot in $(ordered_shortcut_slots_after "$current_slot"); do
    next_record="$(resolve_shortcut_slot_record "$slot")" || continue
    carousel_switch_to_single_record "$client_key" "$next_record" && return 0
  done

  return 1
}

reschedule_carousel_if_active() {
  local client_key="$1"
  if carousel_client_active "$client_key" && carousel_client_exists "$client_key"; then
    schedule_carousel_tick "$client_key"
  fi
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
    for s in $shortcut_slots; do
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
    for s in $shortcut_slots; do
      entry="$(printf '%s\n' "$manifest_shortcuts" | jq -r --arg slot "$s" '.[$slot] // empty')"
      [ -n "$entry" ] || continue
      guid="$(printf '%s\n' "$entry" | jq -r '.session_guid')"
      if resolve_guid_to_session "$guid" >/dev/null 2>&1; then
        filtered="$(printf '%s\n' "$filtered" | jq --arg slot "$s" --argjson entry "$entry" '.[$slot] = $entry')"
      fi
    done

    printf '%s\n' "$filtered" | write_shortcuts
    ;;

  toggle-carousel)
    require_client_tty
    if carousel_client_active "$client_tty"; then
      carousel_clear_client_state "$client_tty"
      carousel_display_message "$client_tty" "Shortcut carousel stopped"
      exit 0
    fi

    next_record="$(select_next_carousel_shortcut "")" || {
      carousel_display_message "$client_tty" "Shortcut carousel: no live shortcuts"
      exit 0
    }

    carousel_write_client_state "$client_tty" ""
    if carousel_switch_to_record "$client_tty" "$next_record"; then
      schedule_carousel_tick "$client_tty"
      carousel_display_message "$client_tty" "Shortcut carousel started"
    else
      carousel_clear_client_state "$client_tty"
      carousel_display_message "$client_tty" "Shortcut carousel: no live shortcuts"
    fi
    ;;

  carousel-tick)
    require_client_tty
    trap 'reschedule_carousel_if_active "$client_tty"' EXIT

    if ! carousel_client_active "$client_tty"; then
      exit 0
    fi

    if ! carousel_client_exists "$client_tty"; then
      carousel_clear_client_state "$client_tty"
      exit 0
    fi

    last_slot="$(carousel_client_last_slot "$client_tty")"
    next_record="$(select_next_carousel_shortcut "$last_slot")" || {
      carousel_clear_client_state "$client_tty"
      carousel_display_message "$client_tty" "Shortcut carousel stopped: no live shortcuts"
      exit 0
    }

    if ! carousel_switch_to_record "$client_tty" "$next_record"; then
      if ! carousel_client_exists "$client_tty"; then
        carousel_clear_client_state "$client_tty"
      else
        carousel_clear_client_state "$client_tty"
        carousel_display_message "$client_tty" "Shortcut carousel stopped: no live shortcuts"
      fi
    fi
    ;;
esac
