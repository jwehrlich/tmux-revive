#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TMUX_REVIVE_SCRIPT_DIR="$script_dir"
# shellcheck source=lib/parse-server-arg.sh
source "$script_dir/lib/parse-server-arg.sh"
# shellcheck source=lib/state-common.sh
source "$script_dir/lib/state-common.sh"

current_session_id_override="${TMUX_REVIVE_PICK_CURRENT_SESSION_ID:-}"
current_session_name_override="${TMUX_REVIVE_PICK_CURRENT_SESSION_NAME:-}"
pick_manifest_path_override="${TMUX_REVIVE_PICK_MANIFEST_PATH:-}"
resume_session_cmd="${TMUX_REVIVE_RESUME_SESSION_CMD:-$script_dir/resume-session.sh}"
restore_state_cmd="${TMUX_REVIVE_RESTORE_STATE_CMD:-$script_dir/restore-state.sh}"
pick_include_archived="${TMUX_REVIVE_PICK_INCLUDE_ARCHIVED:-false}"
pick_include_archived_explicit="false"
pick_attach="false"
pick_no_attach="false"
pick_explicit_attach="false"
pick_explicit_no_attach="false"
pick_no_preview="false"
pick_initial_query=""
requested_profile=""
pick_profile_path=""
pick_cleanup_transient_session=""
pick_include_imported="false"
pick_show_snapshots="false"
pick_show_templates="false"
pick_view_mode="normal"  # normal | templates | snapshots
pick_context=""

while [ $# -gt 0 ]; do
  case "$1" in
    --manifest)
      pick_manifest_path_override="${2:?--manifest requires a path}"
      shift 2
      ;;
    --profile)
      requested_profile="${2:?--profile requires a name or path}"
      shift 2
      ;;
    --attach)
      pick_attach="true"
      pick_no_attach="false"
      pick_explicit_attach="true"
      pick_explicit_no_attach="false"
      shift
      ;;
    --no-attach)
      pick_no_attach="true"
      pick_attach="false"
      pick_explicit_no_attach="true"
      pick_explicit_attach="false"
      shift
      ;;
    --no-preview)
      pick_no_preview="true"
      shift
      ;;
    --query)
      pick_initial_query="${2:-}"
      shift 2
      ;;
    --include-archived)
      pick_include_archived="true"
      pick_include_archived_explicit="true"
      shift
      ;;
    --hide-archived)
      pick_include_archived="false"
      pick_include_archived_explicit="true"
      shift
      ;;
    --cleanup-transient-session|--transient-session)
      pick_cleanup_transient_session="${2:?$1 requires a target}"
      shift 2
      ;;
    --include-imported)
      pick_include_imported="true"
      shift
      ;;
    --show-snapshots)
      pick_show_snapshots="true"
      pick_view_mode="snapshots"
      shift
      ;;
    --show-templates)
      pick_show_templates="true"
      pick_view_mode="templates"
      shift
      ;;
    --context)
      pick_context="${2:?--context requires a value (startup or new-session)}"
      shift 2
      ;;
    --server)
      export TMUX_REVIVE_TMUX_SERVER="${2:?--server requires a name}"
      shift 2
      ;;
    --dump-items-raw|--dump-items)
      # handled after function definitions below
      break
      ;;
    *)
      printf 'pick: unknown argument: %s\n' "$1" >&2
      exit 1
      ;;
  esac
done

# Resolve profile
if pick_profile_path="$(tmux_revive_profile_path "$requested_profile" 2>/dev/null)"; then
  :
elif [ -n "$requested_profile" ] || [ -n "$(tmux_revive_default_profile_name)" ]; then
  printf 'pick: profile not found: %s\n' "${requested_profile:-$(tmux_revive_default_profile_name)}" >&2
  exit 1
fi

# Apply profile settings (CLI flags take precedence)
if [ -n "$pick_profile_path" ]; then
  if [ "$pick_include_archived_explicit" != "true" ] && \
     [ "$(tmux_revive_profile_read_bool "$pick_profile_path" "include_archived" "false")" = "true" ]; then
    pick_include_archived="true"
  fi
  if [ "$pick_explicit_attach" != "true" ] && [ "$pick_explicit_no_attach" != "true" ]; then
    if [ "$(tmux_revive_profile_read_bool "$pick_profile_path" "attach" "false")" = "true" ]; then
      pick_attach="true"
      pick_no_attach="false"
    else
      pick_attach="false"
      pick_no_attach="true"
    fi
  fi
elif [ "$pick_include_archived" != "true" ]; then
  # Fallback: check default profile for include_archived (original behavior)
  local_profile="$(tmux_revive_profile_path "" 2>/dev/null || true)"
  if [ -n "$local_profile" ] && [ "$(tmux_revive_profile_read_bool "$local_profile" "include_archived" "false")" = "true" ]; then
    pick_include_archived="true"
  fi
fi

# Startup mode: default to --attach unless explicitly overridden
if [ -n "$pick_context" ] && [ "$pick_explicit_attach" != "true" ] && [ "$pick_explicit_no_attach" != "true" ]; then
  pick_attach="true"
  pick_no_attach="false"
fi

# ── Dependency checks ─────────────────────────────────────────────────
if ! command -v fzf >/dev/null 2>&1; then
  printf 'pick.sh: fzf is required but not found in PATH\n' >&2
  exit 1
fi
if ! command -v jq >/dev/null 2>&1; then
  printf 'pick.sh: jq is required but not found in PATH\n' >&2
  exit 1
fi
if [ "$pick_show_templates" = "true" ] || [ "$pick_view_mode" = "templates" ]; then
  if ! command -v yq >/dev/null 2>&1; then
    printf 'pick.sh: yq is required for templates but not found in PATH\n' >&2
    exit 1
  fi
fi


emit_header_row() {
  local label="$1"
  printf 'header\theader\t\t\t\t%s\n' "$label"
}

emit_nav_row() {
  local nav_kind="$1"
  local label="$2"
  printf 'nav\t%s\t\t\t\t%s\n' "$nav_kind" "$label"
}

show_help() {
  printf '%s\n' \
    "=== TMUX REVIVE KEYBINDINGS ===" \
    "" \
    "Navigation" \
    "  Enter     Jump to session/window/pane" \
    "  Esc       Close Revive" \
    "  ^b        Toggle snapshots view" \
    "  ^e        Toggle templates view" \
    "" \
    "Sessions" \
    "  Enter     Jump/resume/drill in" \
    "  ^a        Restore all saved sessions" \
    "  ^t        Create new session" \
    "  ^r        Rename session" \
    "  ^l        Set session label" \
    "  ^d        Delete session/snapshot" \
    "" \
    "Windows & Panes" \
    "  ^w        Create new window" \
    "  ^p        Create new pane" \
    "" \
    "Snapshots (^b view)" \
    "  Enter     Action menu (Drill In, Restore," \
    "            Export, Delete, Convert to Template)" \
    "  ^d        Delete snapshot" \
    "" \
    "Templates (^e view)" \
    "  Enter     Action menu (Launch, Edit, Delete," \
    "            Export, Rename, Duplicate)" \
    "  ^d        Delete template" |
    fzf \
      --prompt='help> ' \
      --header="$(header_text "TMUX REVIVE HELP")" \
      --header-first \
      --footer="Esc: close help" \
      --footer-border=top \
      "${TOKYO_FZF_COLORS[@]}" \
      --layout=reverse \
      --border \
      --no-info 2>/dev/null || true
}

emit_snapshot_row() {
  local manifest_path="$1"
  local reason="$2"
  local session_count="$3"
  local timestamp="$4"
  printf 'snapshot\tmanifest\t%s\t%s\t%s\t%s\n' "$manifest_path" "$reason" "$session_count" "$timestamp"
}

emit_live_row() {
  local kind="$1"
  local id="$2"
  local session_name="$3"
  local resource_id="$4"
  local resource_name="$5"
  printf 'live\t%s\t%s\t%s\t%s\t%s\n' "$kind" "$id" "$session_name" "$resource_id" "$resource_name"
}

emit_saved_row() {
  local selector_type="$1"
  local selector_value="$2"
  local session_name="$3"
  local resource_id="$4"
  local resource_name="$5"
  printf 'saved\t%s\t%s\t%s\t%s\t%s\n' "$selector_type" "$selector_value" "$session_name" "$resource_id" "$resource_name"
}

emit_template_row() {
  local template_name="$1"
  local description="$2"
  local session_count="$3"
  local updated_at="$4"
  printf 'template\ttemplate\t%s\t%s\t%s\t%s\n' "$template_name" "$description" "$session_count" "$updated_at"
}

emit_session_tree() {
  local session_id="$1"
  local session_name="$2"
  local session_windows window_rows window_row
  local window_id window_index window_name
  local pane_rows pane_row pane_id pane_index pane_title pane_command pane_label
  local session_label session_display

  session_windows="$(tmux list-windows -t "$session_id" 2>/dev/null | wc -l | tr -d '[:space:]')"
  session_display="${session_windows:-0} windows"
  session_label="$(tmux_revive_session_label_or_name "$session_id" "" 2>/dev/null || true)"
  if [ -n "$session_label" ] && [ "$session_label" != "$session_name" ]; then
    session_display="${session_display}  label: ${session_label}"
  fi
  emit_live_row "session" "$session_id" "$session_name" "$session_name" "$session_display"

  window_rows="$(tmux list-windows -t "$session_id" -F $'#{window_id}\t#{window_index}\t#{window_name}' 2>/dev/null || true)"
  while IFS=$'\t' read -r window_id window_index window_name; do
    [ -n "${window_id:-}" ] || continue
    emit_live_row "window" "$window_id" "$session_name" "${session_name}:${window_index}" "$window_name"

    pane_rows="$(tmux list-panes -t "$window_id" -F $'#{pane_id}\t#{pane_index}\t#{pane_title}\t#{pane_current_command}' 2>/dev/null || true)"
    while IFS=$'\t' read -r pane_id pane_index pane_title pane_command; do
      [ -n "${pane_id:-}" ] || continue
      pane_label="$pane_title"
      [ -n "$pane_label" ] || pane_label="$pane_command"
      emit_live_row "pane" "$pane_id" "$session_name" "${session_name}:${window_index}.${pane_index}" "$pane_label"
    done <<<"$pane_rows"
  done <<<"$window_rows"
}

emit_saved_sessions() {
  local manifest_path="$1"
  local line selector_type selector_value session_name short_ref updated_at reason tmux_session_name window_summary
  local rows=()

  [ -n "$manifest_path" ] || return 0
  [ -f "$manifest_path" ] || return 0

  while IFS= read -r line; do
    [ -n "$line" ] || continue
    rows+=("$line")
  done < <(
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
          ($session.session_name // "-"),
          (
            if (($session.session_guid // "") != "")
            then ($session.session_guid[0:8])
            elif (($session.session_id // "") != "")
            then ("legacy:" + $session.session_id)
            else "legacy"
            end
          ),
          ($doc.last_updated // $doc.created_at // "-"),
          ($doc.reason // "-"),
          ($session.tmux_session_name // $session.session_name // ""),
          ($window_summary // "-")
        ]
      | @tsv
    ' "$manifest_path"
  )

  [ "${#rows[@]}" -gt 0 ] || return 0
  emit_header_row "SAVED SESSIONS"

  for line in "${rows[@]}"; do
    selector_type="$(printf '%s\n' "$line" | cut -f1)"
    selector_value="$(printf '%s\n' "$line" | cut -f2)"
    session_name="$(printf '%s\n' "$line" | cut -f3)"
    short_ref="$(printf '%s\n' "$line" | cut -f4)"
    updated_at="$(printf '%s\n' "$line" | cut -f5)"
    reason="$(printf '%s\n' "$line" | cut -f6)"
    tmux_session_name="$(printf '%s\n' "$line" | cut -f7)"
    window_summary="$(printf '%s\n' "$line" | cut -f8)"
    if [ "$selector_type" = "guid" ] && tmux_revive_session_is_archived "$selector_value"; then
      if [ "$pick_include_archived" != "true" ]; then
        continue
      fi
      archive_state="archived"
    else
      archive_state="active"
    fi
    live_state="saved"
    if [ -n "$tmux_session_name" ] && tmux has-session -t "$tmux_session_name" 2>/dev/null; then
      live_state="live"
    fi
    emit_saved_row "$selector_type" "$selector_value" "$session_name" "$short_ref" "$updated_at | $reason | $window_summary | $live_state | $archive_state"
  done
}

emit_snapshots() {
  local snapshots_root manifest_path
  snapshots_root="$(tmux_revive_snapshots_root)"
  [ -d "$snapshots_root" ] || return 0

  local found=0
  while IFS= read -r manifest_path; do
    [ -f "$manifest_path" ] || continue
    if [ "$pick_include_imported" != "true" ] && \
       [ "$(jq -r '(.imported // .source.imported // false)' "$manifest_path" 2>/dev/null || printf 'false')" = "true" ]; then
      continue
    fi
    local timestamp reason session_count
    timestamp="$(jq -r '.last_updated // .created_at // "-"' "$manifest_path" 2>/dev/null || printf '-')"
    reason="$(jq -r '.reason // "-"' "$manifest_path" 2>/dev/null || printf '-')"
    session_count="$(jq -r '(.sessions | length) // 0' "$manifest_path" 2>/dev/null || printf '0')"
    if [ "$found" -eq 0 ]; then
      emit_header_row "SNAPSHOTS"
      found=1
    fi
    emit_snapshot_row "$manifest_path" "$reason" "$session_count" "$timestamp"
  done < <(find "$snapshots_root" -type f -name manifest.json | sort -r)
}

emit_templates() {
  local templates_root
  templates_root="$(tmux_revive_templates_root)"
  [ -d "$templates_root" ] || return 0

  local found=0
  local tpl_file tpl_name description session_count updated_at
  while IFS= read -r tpl_file; do
    [ -f "$tpl_file" ] || continue
    tpl_name="$(yq -r '.name // ""' "$tpl_file" 2>/dev/null || true)"
    [ -n "$tpl_name" ] || continue
    description="$(yq -r '.description // ""' "$tpl_file" 2>/dev/null || true)"
    session_count="$(yq -r '(.sessions | length) // 0' "$tpl_file" 2>/dev/null || printf '0')"
    updated_at="$(yq -r '.updated_at // ""' "$tpl_file" 2>/dev/null || true)"
    if [ "$found" -eq 0 ]; then
      emit_header_row "TEMPLATES"
      found=1
    fi
    emit_template_row "$tpl_name" "$description" "$session_count" "$updated_at"
  done < <(find "$templates_root" -maxdepth 1 -type f -name '*.yaml' | sort)
}

build_items_raw() {
  # Startup mode: saved sessions only (simplified view)
  if [ -n "$pick_context" ]; then
    emit_saved_sessions "$pick_manifest_path"
    return
  fi

  # Exclusive view modes: show only templates or only snapshots
  if [ "$pick_view_mode" = "templates" ]; then
    emit_templates
    return
  fi
  if [ "$pick_view_mode" = "snapshots" ]; then
    emit_snapshots
    return
  fi

  local current_session_id current_session_name session_rows session_row session_id session_name
  local other_session_count=0

  current_session_id="$current_session_id_override"
  current_session_name="$current_session_name_override"

  if [ -z "$current_session_id" ]; then
    current_session_id="$(tmux display-message -p '#{session_id}' 2>/dev/null || true)"
  fi
  if [ -z "$current_session_name" ]; then
    current_session_name="$(tmux display-message -p '#{session_name}' 2>/dev/null || true)"
  fi

  session_rows="$(tmux list-sessions -F $'#{session_id}\t#{session_name}' 2>/dev/null || true)"

  if [ -n "$current_session_id" ] && tmux has-session -t "$current_session_id" 2>/dev/null; then
    emit_header_row "CURRENT SESSION"
    emit_session_tree "$current_session_id" "${current_session_name:-$(tmux display-message -p -t "$current_session_id" '#{session_name}' 2>/dev/null || true)}"
  fi

  while IFS=$'\t' read -r session_id session_name; do
    [ -n "${session_id:-}" ] || continue
    [ "$session_id" = "$current_session_id" ] && continue
    if [ "$other_session_count" -eq 0 ]; then
      emit_header_row "OTHER SESSIONS"
    fi
    other_session_count=$((other_session_count + 1))
    emit_session_tree "$session_id" "$session_name"
  done <<<"$session_rows"

  # Back-navigation when viewing a non-latest snapshot
  local latest_manifest
  latest_manifest="$(tmux_revive_find_latest_manifest || true)"
  if [ -n "$pick_manifest_path_override" ] && [ "$pick_manifest_path" != "$latest_manifest" ]; then
    emit_nav_row "back" "← Back to latest"
  fi

  emit_saved_sessions "$pick_manifest_path"

  if [ "$pick_show_templates" = "true" ]; then
    emit_templates
  fi

  if [ "$pick_show_snapshots" = "true" ]; then
    emit_snapshots
  fi
}

build_items() {
  local row_kind kind id session_name resource_id resource_name
  local type_label type_color type_padded id_padded display_row name_colored details_colored

  while IFS=$'\t' read -r row_kind kind id session_name resource_id resource_name; do
    if [ "$row_kind" = "header" ]; then
      display_row="$(printf '%b%s%b' '\033[38;2;154;206;106m' "$resource_name" '\033[0m')"
      printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$row_kind" "$kind" "$id" "$session_name" "$resource_id" "$resource_name" "$display_row"
      continue
    fi

    if [ "$row_kind" = "nav" ]; then
      display_row="$(printf '%b%s%b' '\033[1;38;2;224;175;104m' "$resource_name" '\033[0m')"
      printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$row_kind" "$kind" "$id" "$session_name" "$resource_id" "$resource_name" "$display_row"
      continue
    fi

    if [ "$row_kind" = "snapshot" ]; then
      # session_name=reason, resource_id=session_count, resource_name=timestamp
      display_row="$(printf '%b%-10s%b  %s  %breason=%b%s  %bsessions=%b%s' \
        '\033[38;2;187;154;247m' 'SNAPSHOT' '\033[0m' \
        "$resource_name" \
        '\033[38;2;125;207;255m' '\033[0m' "$session_name" \
        '\033[38;2;125;207;255m' '\033[0m' "$resource_id")"
      printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$row_kind" "$kind" "$id" "$session_name" "$resource_id" "$resource_name" "$display_row"
      continue
    fi

    if [ "$row_kind" = "template" ]; then
      # id=template_name, session_name=description, resource_id=session_count, resource_name=updated_at
      local tpl_desc=""
      [ -n "$session_name" ] && tpl_desc="  \"$session_name\""
      display_row="$(printf '%b%-10s%b  %b%s%b  %bsessions=%b%s%s' \
        '\033[38;2;224;175;104m' 'TEMPLATE' '\033[0m' \
        '\033[1;38;2;224;175;104m' "$id" '\033[0m' \
        '\033[38;2;125;207;255m' '\033[0m' "$resource_id" \
        "$tpl_desc")"
      printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$row_kind" "$kind" "$id" "$session_name" "$resource_id" "$resource_name" "$display_row"
      continue
    fi

    case "$kind" in
      session)
        type_label="SESSION"
        type_color='\033[38;2;187;154;247m'
        ;;
      window)
        type_label="WINDOW"
        type_color='\033[38;2;122;162;247m'
        ;;
      pane)
        type_label="PANE"
        type_color='\033[38;2;125;207;255m'
        ;;
      guid|name|id)
        type_label="SAVED"
        type_color='\033[38;2;158;206;106m'
        ;;
      *)
        type_label="ITEM"
        type_color='\033[38;2;192;202;245m'
        ;;
    esac

    type_padded="$(printf '%-8s' "$type_label")"
    id_padded="$(printf '%-24s' "$resource_id")"
    if [ "$row_kind" = "saved" ]; then
      name_colored="$(printf '%b%s\033[0m' '\033[1;38;2;224;175;104m' "$session_name")"
      details_colored="$(printf '%b%s\033[0m' '\033[38;2;125;207;255m' "$resource_name")"
      display_row="$(printf '%b  %s  %s  %s' "${type_color}${type_padded}\033[0m" "$id_padded" "$name_colored" "$details_colored")"
    else
      name_colored="$(printf '%b%s\033[0m' '\033[1;38;2;224;175;104m' "$resource_name")"
      display_row="$(printf '%b  %s  %s' "${type_color}${type_padded}\033[0m" "$id_padded" "$name_colored")"
    fi
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$row_kind" "$kind" "$id" "$session_name" "$resource_id" "$resource_name" "$display_row"
  done < <(build_items_raw)
}

# Tokyo Night (night) palette from tokyonight.nvim:
tmux_revive_fzf_colors

if [ "${1:-}" = "--dump-items-raw" ]; then
  pick_manifest_path="$pick_manifest_path_override"
  if [ -z "$pick_manifest_path" ]; then
    pick_manifest_path="$(tmux_revive_find_latest_manifest || true)"
  fi
  build_items_raw
  exit 0
fi

if [ "${1:-}" = "--dump-items" ]; then
  pick_manifest_path="$pick_manifest_path_override"
  if [ -z "$pick_manifest_path" ]; then
    pick_manifest_path="$(tmux_revive_find_latest_manifest || true)"
  fi
  build_items
  exit 0
fi

header_text() {
  local title="$1"
  printf '=== %s ===' "$title"
}

prompt_input() {
  local title="$1"
  local prompt_label="$2"
  local default_value="$3"
  local footer_text="$4"
  local payload value

  payload="$(
    printf '%s\n' "$default_value" |
      fzf \
        --disabled \
        --prompt="${prompt_label}> " \
        --header="$(header_text "$title")" \
        --header-first \
        --footer="$footer_text" \
        --footer-border=top \
        "${TOKYO_FZF_COLORS[@]}" \
        --query="$default_value" \
        --print-query \
        --layout=reverse \
        --border
  )" || return 1

  value="$(printf '%s\n' "$payload" | sed -n '1p')"
  [ -n "$value" ] || return 1
  printf '%s\n' "$value"
}

confirm_delete() {
  local target_label="$1"
  local choice

  choice="$(
    printf '%s\n' "No" "Yes" |
      fzf \
        --prompt='confirm> ' \
        --header="$(header_text "TMUX REVIVE DELETE")" \
        --header-first \
        --footer="Delete ${target_label}? Enter: select  Esc: cancel" \
        --footer-border=top \
        "${TOKYO_FZF_COLORS[@]}" \
        --layout=reverse \
        --border
  )" || return 1

  [ "$choice" = "Yes" ]
}

count_panes_in_window() {
  local window_id="$1"
  local count
  if ! count="$(tmux list-panes -t "$window_id" 2>/dev/null | wc -l | tr -d '[:space:]')"; then
    count=0
  fi
  printf '%s\n' "${count:-0}"
}

count_windows_in_session() {
  local session_id="$1"
  local count
  if ! count="$(tmux list-windows -t "$session_id" 2>/dev/null | wc -l | tr -d '[:space:]')"; then
    count=0
  fi
  printf '%s\n' "${count:-0}"
}

count_sessions() {
  local count
  if ! count="$(tmux list-sessions 2>/dev/null | wc -l | tr -d '[:space:]')"; then
    count=0
  fi
  printf '%s\n' "${count:-0}"
}

session_neighbor_for_delete() {
  local target_id="$1"
  local -a sessions=()
  while IFS= read -r id; do
    sessions+=("$id")
  done < <(tmux list-sessions -F '#{session_id}' 2>/dev/null || true)

  local i
  for ((i = 0; i < ${#sessions[@]}; i++)); do
    if [ "${sessions[$i]}" = "$target_id" ]; then
      if [ $i -gt 0 ]; then
        printf '%s\n' "${sessions[$((i - 1))]}"
      elif [ $i -lt $((${#sessions[@]} - 1)) ]; then
        printf '%s\n' "${sessions[$((i + 1))]}"
      fi
      return 0
    fi
  done
}

session_id_for_target() {
  local kind="$1"
  local id="$2"

  case "$kind" in
    session)
      printf '%s\n' "$id"
      ;;
    window|pane)
      tmux display-message -p -t "$id" '#{session_id}'
      ;;
  esac
}

window_id_for_target() {
  local kind="$1"
  local id="$2"

  case "$kind" in
    session)
      tmux display-message -p -t "$id" '#{window_id}'
      ;;
    window)
      printf '%s\n' "$id"
      ;;
    pane)
      tmux display-message -p -t "$id" '#{window_id}'
      ;;
  esac
}

create_pane_in_window() {
  local window_id="$1"
  local pane_count default_name pane_title new_pane_id

  pane_count="$(count_panes_in_window "$window_id")"
  default_name="$((pane_count + 1))"
  pane_title="$(prompt_input "TMUX REVIVE CREATE PANE" "new pane title" "$default_name" "Enter: create  Esc: cancel")" || return 0

  if ! new_pane_id="$(tmux split-window -d -P -F '#{pane_id}' -t "$window_id" 2>/dev/null)"; then
    tmux display-message "Revive: failed to create pane"
    return 0
  fi
  tmux select-pane -t "$new_pane_id" -T "$pane_title" 2>/dev/null || true
  printf '%s\n' "$new_pane_id"
}

prompt_initial_pane_title() {
  local pane_id="$1"
  local default_name pane_title

  default_name="$(tmux display-message -p -t "$pane_id" '#{pane_index}' 2>/dev/null || printf '1')"
  pane_title="$(prompt_input "TMUX REVIVE CREATE PANE" "initial pane title" "$default_name" "Enter: save  Esc: keep current")" || return 0
  tmux select-pane -t "$pane_id" -T "$pane_title" 2>/dev/null || true
}

create_window_in_session() {
  local session_id="$1"
  local with_pane_title_prompt="${2:-1}"
  local window_count default_name window_name new_window_id initial_pane_id

  window_count="$(count_windows_in_session "$session_id")"
  default_name="$((window_count + 1))"
  window_name="$(prompt_input "TMUX REVIVE CREATE WINDOW" "new window name" "$default_name" "Enter: create  Esc: cancel")" || return 0

  if ! new_window_id="$(tmux new-window -d -P -F '#{window_id}' -t "$session_id" -n "$window_name" 2>/dev/null)"; then
    tmux display-message "Revive: failed to create window"
    return 0
  fi

  initial_pane_id="$(tmux display-message -p -t "$new_window_id" '#{pane_id}' 2>/dev/null || true)"
  [ -n "$initial_pane_id" ] || return 0

  if [ "$with_pane_title_prompt" = "1" ]; then
    prompt_initial_pane_title "$initial_pane_id"
  fi

  printf '%s\n' "$initial_pane_id"
}

create_session_flow() {
  local session_total default_session_name session_name window_name new_session_id new_window_id initial_pane_id

  session_total="$(count_sessions)"
  default_session_name="$((session_total + 1))"
  session_name="$(prompt_input "TMUX REVIVE CREATE SESSION" "new session name" "$default_session_name" "Enter: create  Esc: cancel")" || return 0
  window_name="$(prompt_input "TMUX REVIVE CREATE WINDOW" "new window name" "1" "Enter: create  Esc: cancel")" || return 0

  if ! new_session_id="$(tmux new-session -d -P -F '#{session_id}' -s "$session_name" -n "$window_name" 2>/dev/null)"; then
    tmux display-message "Revive: failed to create session"
    return 0
  fi

  new_window_id="$(tmux display-message -p -t "$new_session_id" '#{window_id}' 2>/dev/null || true)"
  [ -n "$new_window_id" ] || return 0
  initial_pane_id="$(tmux display-message -p -t "$new_window_id" '#{pane_id}' 2>/dev/null || true)"
  [ -n "$initial_pane_id" ] || return 0
  prompt_initial_pane_title "$initial_pane_id"

  printf '%s\n' "$initial_pane_id"
}

rename_item() {
  local kind="$1"
  local id="$2"
  local session_name="$3"
  local display_label="$4"
  local current_name="$5"
  local prompt_label old_name new_name

  case "$kind" in
    session)
      prompt_label="session"
      old_name="$session_name"
      ;;
    window)
      prompt_label="window ($display_label)"
      old_name="$current_name"
      ;;
    pane)
      prompt_label="pane title ($display_label)"
      old_name="$current_name"
      ;;
    *)
      return 0
      ;;
  esac

  new_name="$(prompt_input "TMUX REVIVE RENAME" "rename ${prompt_label}" "$old_name" "Enter: save  Esc: cancel")" || return 0

  case "$kind" in
    session)
      tmux rename-session -t "$id" -- "$new_name" 2>/dev/null || tmux display-message "Revive: failed to rename session"
      ;;
    window)
      tmux rename-window -t "$id" -- "$new_name" 2>/dev/null || tmux display-message "Revive: failed to rename window"
      ;;
    pane)
      tmux select-pane -t "$id" -T "$new_name" 2>/dev/null || tmux display-message "Revive: failed to rename pane"
      ;;
  esac
}

delete_item() {
  local kind="$1"
  local id="$2"
  local session_name="$3"
  local display_label="$4"
  local current_name="$5"
  local target_label next_session_id current_session_id

  case "$kind" in
    session)
      target_label="session ${session_name}"
      ;;
    window)
      target_label="window ${display_label} (${current_name})"
      ;;
    pane)
      target_label="pane ${display_label} (${current_name})"
      ;;
    *)
      return 0
      ;;
  esac

  confirm_delete "$target_label" || return 0

  case "$kind" in
    session)
      next_session_id="$(session_neighbor_for_delete "$id")"
      current_session_id="$(tmux display-message -p '#{session_id}' 2>/dev/null || true)"

      if [ "$current_session_id" = "$id" ] && [ -z "$next_session_id" ]; then
        tmux display-message "Revive: cannot delete the last session"
        return 0
      fi

      if [ "$current_session_id" = "$id" ] && [ -n "$next_session_id" ]; then
        tmux switch-client -t "$next_session_id" 2>/dev/null || true
      fi

      if tmux kill-session -t "$id" 2>/dev/null; then
        [ -n "$next_session_id" ] && tmux switch-client -t "$next_session_id" 2>/dev/null || true
      else
        tmux display-message "Revive: failed to delete session"
      fi
      ;;
    window)
      tmux kill-window -t "$id" 2>/dev/null || tmux display-message "Revive: failed to delete window"
      ;;
    pane)
      tmux kill-pane -t "$id" 2>/dev/null || tmux display-message "Revive: failed to delete pane"
      ;;
  esac
}

jump_to_item() {
  local kind="$1"
  local id="$2"

  case "$kind" in
    session|window|pane)
      tmux switch-client -t "$id"
      ;;
  esac
}

resume_saved_item() {
  local selector_type="$1"
  local selector_value="$2"
  local resume_args=(--yes)

  if [ -n "$pick_manifest_path" ]; then
    resume_args+=(--manifest "$pick_manifest_path")
  fi
  if [ -n "$pick_profile_path" ]; then
    resume_args+=(--profile "$pick_profile_path")
  fi
  if [ "$pick_attach" = "true" ]; then
    resume_args+=(--attach)
  elif [ "$pick_no_attach" = "true" ]; then
    resume_args+=(--no-attach)
  fi
  if [ "$pick_no_preview" = "true" ]; then
    resume_args+=(--no-preview)
  fi
  if [ -n "$pick_cleanup_transient_session" ]; then
    resume_args+=(--cleanup-transient-session "$pick_cleanup_transient_session")
  fi

  case "$selector_type" in
    guid)
      exec "$resume_session_cmd" --guid "$selector_value" "${resume_args[@]}"
      ;;
    id)
      exec "$resume_session_cmd" --id "$selector_value" "${resume_args[@]}"
      ;;
    name)
      exec "$resume_session_cmd" --name "$selector_value" "${resume_args[@]}"
      ;;
  esac
}

query="$pick_initial_query"
while :; do
  pick_manifest_path="$pick_manifest_path_override"
  if [ -z "$pick_manifest_path" ]; then
    pick_manifest_path="$(tmux_revive_find_latest_manifest || true)"
  fi

  # Validate manifest path — clear it if file no longer exists
  if [ -n "$pick_manifest_path" ] && [ ! -f "$pick_manifest_path" ]; then
    pick_manifest_path=""
    pick_manifest_path_override=""
  fi

  fzf_args=(
    --delimiter=$'\t'
    --with-nth=7
    --print-query
    --query="$query"
    --layout=reverse
    --border
  )

  # Check if saved sessions exist for context-aware footer
  has_saved="false"
  if [ -n "$pick_manifest_path" ] && [ -f "$pick_manifest_path" ]; then
    saved_count="$(jq '[.sessions[]?] | length' "$pick_manifest_path" 2>/dev/null || echo 0)"
    [ "$saved_count" -gt 0 ] && has_saved="true"
  fi

  # Check if templates exist for context-aware footer
  has_templates="false"
  tpl_root="$(tmux_revive_templates_root)"
  if [ -d "$tpl_root" ] && [ -n "$(find "$tpl_root" -maxdepth 1 -name '*.yaml' -print -quit 2>/dev/null)" ]; then
    has_templates="true"
  fi

  if [ -n "$pick_context" ]; then
    # Startup mode: compact, no preview, context-aware text
    if [ "$pick_context" = "new-session" ]; then
      fzf_args+=(--header="$(header_text "Saved sessions available — this session will be replaced")")
    else
      fzf_args+=(--header="$(header_text "Saved sessions available — pick to restore")")
    fi
    fzf_args+=(
      --header-first
      --prompt='restore> '
      --footer='Enter: resume  Ctrl-a: restore all  Esc: dismiss'
      --footer-border=top
      --expect=enter,ctrl-a
      --select-1
      --exit-0
    )
  else
    # Normal Revive mode: full UI with preview
    # Build context-aware multi-line footer.
    # Line 1: actions for the selected item (fits in the ~40% left of preview).
    # Line 2: create/manage actions.
    # Restore keys only shown when saved sessions exist.
    # Footer lines ≤50 chars each.
    footer_lines=""
    pick_header="TMUX REVIVE"
    pick_prompt="manage> "
    if [ "$pick_view_mode" = "templates" ]; then
      pick_header="TMUX REVIVE — TEMPLATES"
      pick_prompt="templates> "
      footer_lines="Enter: select  ^e: back  ^b: snapshots  ?: help  Esc: close"
    elif [ "$pick_view_mode" = "snapshots" ]; then
      pick_header="TMUX REVIVE — SNAPSHOTS"
      pick_prompt="snapshots> "
      footer_lines="Enter: drill in  ^b: back  ^e: templates  ?: help  Esc: close"
    elif [ "$has_saved" = "true" ]; then
      footer_lines="Enter: jump/resume  ^a: restore all  ^r: rename  ^l: label"
      footer_lines="$footer_lines"$'\n'"^t: +session  ^w: +window  ^p: +pane  ^d: delete"
      footer_lines="$footer_lines"$'\n'"^b: snapshots  ^e: templates  ?: help  Esc: close"
    else
      footer_lines="Enter: jump  ^r: rename  ^l: label"
      footer_lines="$footer_lines"$'\n'"^t: +session  ^w: +window  ^p: +pane  ^d: delete"
      footer_lines="$footer_lines"$'\n'"^b: snapshots  ^e: templates  ?: help  Esc: close"
    fi

    fzf_args+=(
      --header="$(header_text "$pick_header")"
      --header-first
      --prompt="$pick_prompt"
      --footer="$footer_lines"
      --footer-border=top
      --preview="$script_dir/preview-item.sh {1} {2} {3} {4} {5} $(printf '%q' "$pick_manifest_path") $(printf '%q' "$restore_state_cmd")"
      --preview-window='right:60%:wrap'
      --expect=enter,ctrl-a,ctrl-b,ctrl-e,ctrl-l,ctrl-r,ctrl-p,ctrl-w,ctrl-t,ctrl-d,?
    )
  fi

  fzf_args+=("${TOKYO_FZF_COLORS[@]}")

  # Use process substitution instead of a pipe so that:
  # 1) fzf opens immediately with chrome (header/footer/prompt) visible
  # 2) Items stream in progressively — no blank screen
  # 3) fzf's exit code is captured directly (pipefail + SIGPIPE on
  #    build_items can't corrupt it, unlike `build_items | fzf`)
  selection_payload="$(
    fzf "${fzf_args[@]}" < <(build_items)
  )" && fzf_exit=0 || fzf_exit=$?
  if [ "$fzf_exit" -eq 130 ] || [ "$fzf_exit" -eq 1 ]; then
    # User cancelled (Esc) or no match
    if [ "$pick_context" = "startup" ]; then
      tmux_revive_mark_runtime_flag "$(tmux_revive_restore_prompt_suppressed_path)"
    fi
    exit 0
  elif [ "$fzf_exit" -ne 0 ]; then
    printf 'pick: fzf error (exit %d)\n' "$fzf_exit" >&2
    exit 1
  fi

  query="$(printf '%s\n' "$selection_payload" | sed -n '1p')"
  key="$(printf '%s\n' "$selection_payload" | sed -n '2p')"
  selection="$(printf '%s\n' "$selection_payload" | sed -n '3p')"

  if [ -z "$selection" ]; then
    case "${key:-}" in
      ctrl-t)
        new_pane_id="$(create_session_flow)"
        if [ -n "$new_pane_id" ]; then
          jump_to_item pane "$new_pane_id"
          exit 0
        fi
        continue
        ;;
      ctrl-b)
        if [ "$pick_view_mode" = "snapshots" ]; then
          pick_view_mode="normal"
        else
          pick_view_mode="snapshots"
        fi
        continue
        ;;
      ctrl-e)
        if [ "$pick_view_mode" = "templates" ]; then
          pick_view_mode="normal"
        else
          pick_view_mode="templates"
        fi
        continue
        ;;
      '?')
        show_help
        continue
        ;;
      *)
        exit 0
        ;;
    esac
  fi

  row_kind="$(printf '%s\n' "$selection" | cut -f1)"
  kind="$(printf '%s\n' "$selection" | cut -f2)"
  id="$(printf '%s\n' "$selection" | cut -f3)"
  session_name="$(printf '%s\n' "$selection" | cut -f4)"
  display_label="$(printf '%s\n' "$selection" | cut -f5)"
  current_name="$(printf '%s\n' "$selection" | cut -f6)"

  # Global key handlers (work regardless of row selection)
  if [ "${key:-}" = "ctrl-b" ]; then
    if [ "$pick_view_mode" = "snapshots" ]; then
      pick_view_mode="normal"
    else
      pick_view_mode="snapshots"
    fi
    continue
  fi

  if [ "${key:-}" = "ctrl-e" ]; then
    if [ "$pick_view_mode" = "templates" ]; then
      pick_view_mode="normal"
    else
      pick_view_mode="templates"
    fi
    continue
  fi

  # ? help — show keybinding cheat sheet
  if [ "${key:-}" = "?" ]; then
    show_help
    continue
  fi

  if [ "${key:-}" = "ctrl-a" ]; then
    restore_all_args=(--yes)
    if [ -n "$pick_manifest_path" ]; then
      restore_all_args+=(--manifest "$pick_manifest_path")
    fi
    if [ -n "$pick_profile_path" ]; then
      restore_all_args+=(--profile "$pick_profile_path")
    fi
    if [ "$pick_attach" = "true" ]; then
      restore_all_args+=(--attach)
    elif [ "$pick_no_attach" = "true" ]; then
      restore_all_args+=(--no-attach)
    fi
    if [ "$pick_no_preview" = "true" ]; then
      restore_all_args+=(--no-preview)
    fi
    if [ -n "$pick_cleanup_transient_session" ]; then
      restore_all_args+=(--cleanup-transient-session "$pick_cleanup_transient_session")
    fi
    exec "$restore_state_cmd" "${restore_all_args[@]}"
    exit 1  # exec should not return
  fi

  if [ "$row_kind" = "header" ]; then
    continue
  fi

  # Nav row: back to latest
  if [ "$row_kind" = "nav" ]; then
    if [ "$kind" = "back" ]; then
      pick_manifest_path_override=""
      query=""
    fi
    continue
  fi

  # Snapshot row
  if [ "$row_kind" = "snapshot" ]; then
    case "${key:-enter}" in
      enter|"")
        # Show action menu for snapshot
        snap_action="$(
          printf '%s\n' "Drill In" "Restore" "Export" "Delete" "Convert to Template" |
            fzf \
              --prompt='action> ' \
              --header="$(header_text "SNAPSHOT: $display_label")" \
              --header-first \
              --footer="Enter: select  Esc: cancel" \
              --footer-border=top \
              "${TOKYO_FZF_COLORS[@]}" \
              --layout=reverse \
              --border \
              --no-info
        )" || { continue; }
        case "$snap_action" in
          "Drill In")
            pick_manifest_path_override="$id"
            query=""
            ;;
          "Restore")
            restore_snap_args=(--manifest "$id" --yes)
            if [ "$pick_attach" = "true" ]; then
              restore_snap_args+=(--attach)
            elif [ "$pick_no_attach" = "true" ]; then
              restore_snap_args+=(--no-attach)
            fi
            exec "$restore_state_cmd" "${restore_snap_args[@]}"
            exit 1
            ;;
          "Export")
            "$script_dir/export-snapshot.sh" --manifest "$id" 2>&1 || true
            printf '\nPress Enter to continue...'
            read -r _ </dev/tty 2>/dev/null || read -r _ 2>/dev/null || true
            ;;
          "Delete")
            snap_dir="$(dirname "$id")"
            if [ -d "$snap_dir" ]; then
              printf 'Delete snapshot %s? [y/N] ' "$display_label"
              if [ -t 0 ]; then
                read -r snap_del_answer </dev/tty || snap_del_answer="n"
              else
                read -r snap_del_answer 2>/dev/null || snap_del_answer="n"
              fi
              if [ "$snap_del_answer" = "y" ] || [ "$snap_del_answer" = "Y" ]; then
                rm -rf "$snap_dir"
                printf 'Snapshot deleted.\n'
              fi
            fi
            ;;
          "Convert to Template")
            # Derive default name from snapshot reason or timestamp
            snap_reason="$(jq -r '.reason // empty' "$id" 2>/dev/null || true)"
            snap_default_name=""
            if [ -n "$snap_reason" ]; then
              # Sanitize reason: lowercase, replace spaces/special chars with hyphens
              snap_default_name="$(printf '%s' "$snap_reason" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9._-]/-/g; s/--*/-/g; s/^-//; s/-$//')"
            fi
            if [ -z "$snap_default_name" ]; then
              snap_default_name="from-snapshot-$(date +%Y%m%d)"
            fi

            printf '\n'
            if [ -t 0 ]; then
              read -r -p "Template name [$snap_default_name]: " snap_tpl_name </dev/tty || true
            else
              read -r snap_tpl_name 2>/dev/null || true
            fi
            snap_tpl_name="${snap_tpl_name:-$snap_default_name}"

            if "$script_dir/template-create.sh" --from-snapshot "$id" --name "$snap_tpl_name" 2>&1; then
              printf 'Created template: %s\n' "$snap_tpl_name"
              if [ -t 0 ]; then
                printf 'Edit template to replace raw layouts with named layouts? [Y/n] '
                read -r snap_edit_answer </dev/tty || snap_edit_answer="n"
              else
                read -r snap_edit_answer 2>/dev/null || snap_edit_answer="n"
              fi
              if [ "${snap_edit_answer:-Y}" != "n" ] && [ "${snap_edit_answer:-Y}" != "N" ]; then
                "$script_dir/template-edit.sh" --name "$snap_tpl_name" 2>&1 || true
              fi
            else
              printf 'Failed to create template from snapshot.\n' >&2
            fi
            ;;
        esac
        ;;
      ctrl-d)
        snap_dir="$(dirname "$id")"
        if [ -d "$snap_dir" ]; then
          printf 'Delete snapshot %s? [y/N] ' "$display_label"
          if [ -t 0 ]; then
            read -r snap_del_answer </dev/tty || snap_del_answer="n"
          else
            read -r snap_del_answer 2>/dev/null || snap_del_answer="n"
          fi
          if [ "$snap_del_answer" = "y" ] || [ "$snap_del_answer" = "Y" ]; then
            rm -rf "$snap_dir"
            printf 'Snapshot deleted.\n'
          fi
        fi
        ;;
      *)
        continue
        ;;
    esac
    continue
  fi

  if [ "$row_kind" = "saved" ]; then
    case "${key:-enter}" in
      enter|"")
        resume_saved_item "$kind" "$id"
        exit 1  # exec in resume_saved_item should not return
        ;;
      *)
        continue
        ;;
    esac
  fi

  # Template row
  if [ "$row_kind" = "template" ]; then
    case "${key:-enter}" in
      enter|"")
        # Show action menu for template
        tpl_action="$(
          printf '%s\n' "Launch" "Edit" "Delete" "Export" "Rename" "Duplicate" |
            fzf \
              --prompt='action> ' \
              --header="$(header_text "TEMPLATE: $id")" \
              --header-first \
              --footer="Enter: select  Esc: cancel" \
              --footer-border=top \
              "${TOKYO_FZF_COLORS[@]}" \
              --layout=reverse \
              --border \
              --no-info
        )" || { continue; }
        case "$tpl_action" in
          Launch)
            exec "$script_dir/apply-template.sh" --name "$id"
            exit 1
            ;;
          Edit)
            "$script_dir/template-edit.sh" --name "$id" 2>&1 || true
            ;;
          Delete)
            "$script_dir/template-delete.sh" --name "$id" 2>&1 || true
            ;;
          Export)
            "$script_dir/template-export.sh" --name "$id" 2>&1 || true
            printf '\nPress Enter to continue...'
            read -r _ </dev/tty 2>/dev/null || read -r _ 2>/dev/null || true
            ;;
          Rename)
            printf 'New name for template "%s": ' "$id"
            if [ -t 0 ]; then
              read -r tpl_new_name </dev/tty || tpl_new_name=""
            else
              read -r tpl_new_name 2>/dev/null || tpl_new_name=""
            fi
            if [ -n "$tpl_new_name" ]; then
              tpl_root="$(tmux_revive_templates_root)"
              old_file="$tpl_root/${id}.yaml"
              new_file="$tpl_root/${tpl_new_name}.yaml"
              if [ -f "$new_file" ]; then
                printf 'Template "%s" already exists.\n' "$tpl_new_name" >&2
              elif [ -f "$old_file" ]; then
                mv "$old_file" "$new_file"
                yq -i ".name = \"$tpl_new_name\"" "$new_file" 2>/dev/null || true
                yq -i ".updated_at = \"$(date -u +%Y-%m-%dT%H:%M:%SZ)\"" "$new_file" 2>/dev/null || true
                printf 'Renamed "%s" → "%s"\n' "$id" "$tpl_new_name"
              fi
            fi
            ;;
          Duplicate)
            printf 'Name for duplicate of "%s": ' "$id"
            if [ -t 0 ]; then
              read -r tpl_dup_name </dev/tty || tpl_dup_name=""
            else
              read -r tpl_dup_name 2>/dev/null || tpl_dup_name=""
            fi
            if [ -n "$tpl_dup_name" ]; then
              tpl_root="$(tmux_revive_templates_root)"
              src_file="$tpl_root/${id}.yaml"
              dup_file="$tpl_root/${tpl_dup_name}.yaml"
              if [ -f "$dup_file" ]; then
                printf 'Template "%s" already exists.\n' "$tpl_dup_name" >&2
              elif [ -f "$src_file" ]; then
                cp "$src_file" "$dup_file"
                yq -i ".name = \"$tpl_dup_name\"" "$dup_file" 2>/dev/null || true
                yq -i ".updated_at = \"$(date -u +%Y-%m-%dT%H:%M:%SZ)\"" "$dup_file" 2>/dev/null || true
                printf 'Duplicated "%s" → "%s"\n' "$id" "$tpl_dup_name"
              fi
            fi
            ;;
        esac
        ;;
      ctrl-d)
        "$script_dir/template-delete.sh" --name "$id" 2>&1 || true
        ;;
      *)
        continue
        ;;
    esac
    continue
  fi

  case "${key:-enter}" in
    ctrl-r)
      rename_item "$kind" "$id" "$session_name" "$display_label" "$current_name"
      ;;
    ctrl-p)
      window_id="$(window_id_for_target "$kind" "$id" 2>/dev/null || true)"
      if [ -n "$window_id" ]; then
        new_pane_id="$(create_pane_in_window "$window_id")"
        if [ -n "$new_pane_id" ]; then
          jump_to_item pane "$new_pane_id"
          exit 0
        fi
      fi
      ;;
    ctrl-w)
      session_id="$(session_id_for_target "$kind" "$id" 2>/dev/null || true)"
      if [ -n "$session_id" ]; then
        new_pane_id="$(create_window_in_session "$session_id" 1)"
        if [ -n "$new_pane_id" ]; then
          jump_to_item pane "$new_pane_id"
          exit 0
        fi
      fi
      ;;
    ctrl-t)
      new_pane_id="$(create_session_flow)"
      if [ -n "$new_pane_id" ]; then
        jump_to_item pane "$new_pane_id"
        exit 0
      fi
      ;;
    ctrl-l)
      if [ "$kind" = "session" ]; then
        target_session_id="$(session_id_for_target "$kind" "$id" 2>/dev/null || true)"
        if [ -n "$target_session_id" ]; then
          target_session_name="$(tmux display-message -p -t "$target_session_id" '#S' 2>/dev/null || true)"
          current_label="$(tmux_revive_session_label_or_name "$target_session_id" "$target_session_name" 2>/dev/null || true)"
          new_label="$(prompt_input "SET SESSION LABEL" "label" "${current_label:-$target_session_name}" "Enter: set label  Esc: cancel")" || true
          if [ -n "$new_label" ]; then
            tmux set-option -t "$target_session_id" -q @tmux-revive-session-label "$new_label" 2>/dev/null || true
            "$script_dir/save-state.sh" --auto --reason set-session-label 2>/dev/null &
          fi
        fi
      fi
      ;;
    ctrl-d)
      if [ "$kind" = "session" ]; then
        delete_item "$kind" "$id" "$session_name" "$display_label" "$current_name"
        exit 0
      else
        delete_item "$kind" "$id" "$session_name" "$display_label" "$current_name"
      fi
      ;;
    enter|"")
      jump_to_item "$kind" "$id"
      exit 0
      ;;
  esac
done
