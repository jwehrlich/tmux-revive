#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/parse-server-arg.sh
source "$script_dir/lib/parse-server-arg.sh"
# shellcheck source=lib/state-common.sh
source "$script_dir/lib/state-common.sh"

usage() {
  cat >&2 <<EOF
Usage: apply-template.sh --name <name> [options]

Apply a template to create tmux sessions.

Options:
  --name <name>        Template name (required)
  --var key=value      Set a template variable (repeatable)
  --no-prompt          Use defaults for unset variables (no interactive prompts)
  --dry-run            Show what would be created without actually restoring
  --attach             Attach to the first created session after restore
  --server <name>      Target a specific tmux server
  -h, --help           Show this help

Examples:
  apply-template.sh --name web-dev
  apply-template.sh --name web-dev --var project=~/src/myapp --var branch=develop
  apply-template.sh --name web-dev --no-prompt
  apply-template.sh --name web-dev --dry-run
EOF
}

template_name=""
dry_run="false"
do_attach="false"
no_prompt="false"
declare -a var_override_keys=()
declare -a var_override_vals=()

while [ $# -gt 0 ]; do
  case "$1" in
    --name)
      template_name="${2:?--name requires a value}"
      shift 2
      ;;
    --var)
      var_arg="${2:?--var requires key=value}"
      var_key="${var_arg%%=*}"
      var_val="${var_arg#*=}"
      if [ "$var_key" = "$var_arg" ]; then
        printf 'apply-template.sh: --var requires key=value format: %s\n' "$var_arg" >&2
        exit 1
      fi
      var_override_keys+=("$var_key")
      var_override_vals+=("$var_val")
      shift 2
      ;;
    --no-prompt)
      no_prompt="true"
      shift
      ;;
    --dry-run)
      dry_run="true"
      shift
      ;;
    --attach)
      do_attach="true"
      shift
      ;;
    --server)
      export TMUX_REVIVE_TMUX_SERVER="${2:?--server requires a name}"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      printf 'apply-template.sh: unknown option: %s\n' "$1" >&2
      usage
      exit 1
      ;;
  esac
done

if [ -z "$template_name" ]; then
  printf 'apply-template.sh: --name is required\n' >&2
  usage
  exit 1
fi

# Step 1: Validate yq is available
tmux_revive_require_yq || exit 1

# Step 2: Locate the template
template_file="$(tmux_revive_templates_root)/${template_name}.yaml"
if [ ! -f "$template_file" ]; then
  printf 'apply-template.sh: template not found: %s\n' "$template_file" >&2
  exit 1
fi

# Step 3: Validate the template
if ! "$script_dir/template-validate.sh" --file "$template_file" --quiet; then
  printf 'apply-template.sh: template validation failed — run template-validate.sh --name %s for details\n' "$template_name" >&2
  exit 1
fi

# Step 4: Convert YAML → JSON and resolve hostname overrides
hostname="$(tmux_revive_host)"
template_json="$(yq -o=json '.' "$template_file")"

override_exists="$(printf '%s' "$template_json" | jq --arg h "$hostname" '.overrides[$h] != null' 2>/dev/null || printf 'false')"

if [ "$override_exists" = "true" ]; then
  template_json="$(printf '%s' "$template_json" | jq --arg h "$hostname" '
    .overrides[$h].sessions as $override_sessions |
    if $override_sessions then
      .sessions |= [.[] as $base_session |
        ($override_sessions | map(select(.name == $base_session.name)) | first // null) as $override_session |
        if $override_session then
          $base_session | .windows |= [
            range(length) as $wi | .[$wi] as $base_window |
            ($override_session.windows // [] | map(select(.name == $base_window.name)) | first // null) as $override_window |
            if $override_window then
              $base_window | .panes |= [
                range(length) as $pi | .[$pi] as $base_pane |
                ($override_window.panes // [] | .[$pi] // null) as $override_pane |
                if $override_pane then
                  $base_pane * $override_pane
                else
                  $base_pane
                end
              ]
            else
              $base_window
            end
          ]
        else
          $base_session
        end
      ]
    else . end
  ')"
fi

# Strip overrides section (not needed in manifest)
template_json="$(printf '%s' "$template_json" | jq 'del(.overrides)')"

# Step 5: Expand ~ → $HOME in all cwd fields (YAML bare ~ is null; ~/path is a string)
template_json="$(printf '%s' "$template_json" | jq --arg home "$HOME" '
  .sessions[].windows[].panes[] |=
    if .cwd == null then .cwd = $home
    elif (.cwd | startswith("~/")) then .cwd = ($home + "/" + .cwd[2:])
    elif .cwd == "~" then .cwd = $home
    else .
    end
')"

# Step 5b: Expand $USER and $TMUX_REVIVE_TPL_* environment variables in cwd fields
# Scoped prefix prevents accidental expansion of sensitive vars (e.g. $AWS_SECRET_KEY)
# Uses split/join for literal string replacement (no regex escaping needed)
expand_cwd_var() {
  local input="$1" var_ref="$2" var_val="$3"
  printf '%s' "$input" | jq --arg search "$var_ref" --arg replace "$var_val" '
    .sessions[].windows[].panes[] |= (.cwd |= (split($search) | join($replace)))
  '
}
template_json="$(expand_cwd_var "$template_json" '$USER' "${USER:-}")"
while IFS='=' read -r var_name var_value; do
  [ -n "$var_name" ] || continue
  template_json="$(expand_cwd_var "$template_json" "\$${var_name}" "$var_value")"
done < <(env | grep '^TMUX_REVIVE_TPL_' || true)

# Step 5c: Resolve template variables ({{var}} placeholders)
expand_template_var() {
  local input="$1" var_ref="$2" var_val="$3"
  printf '%s' "$input" | jq --arg search "{{$var_ref}}" --arg replace "$var_val" '
    .sessions[].windows[].panes[] |= (
      (.cwd |= (split($search) | join($replace))) |
      (.command |= (if . then split($search) | join($replace) else . end))
    )
  '
}

has_variables="$(printf '%s' "$template_json" | jq '.variables != null and (.variables | length) > 0' 2>/dev/null || printf 'false')"
if [ "$has_variables" = "true" ]; then
  while IFS=$'\t' read -r vname vprompt vdefault; do
    [ -n "$vname" ] || continue

    # Check --var overrides first
    resolved_val=""
    found_override="false"
    for ((vi=0; vi<${#var_override_keys[@]}; vi++)); do
      if [ "${var_override_keys[$vi]}" = "$vname" ]; then
        resolved_val="${var_override_vals[$vi]}"
        found_override="true"
        break
      fi
    done

    if [ "$found_override" = "false" ]; then
      if [ "$no_prompt" = "true" ]; then
        resolved_val="$vdefault"
      elif [ -t 0 ]; then
        printf '%s [%s]: ' "$vprompt" "$vdefault" >&2
        read -r resolved_val </dev/tty || resolved_val=""
        resolved_val="${resolved_val:-$vdefault}"
      else
        resolved_val="$vdefault"
      fi
    fi

    template_json="$(expand_template_var "$template_json" "$vname" "$resolved_val")"
  done < <(printf '%s' "$template_json" | jq -r '.variables | to_entries[] | [.key, (.value.prompt // ""), (.value.default // "")] | @tsv')
fi

# Strip variables section (not needed in manifest)
template_json="$(printf '%s' "$template_json" | jq 'del(.variables)')"

# Check for unexpanded {{...}} placeholders
unexpanded="$(printf '%s' "$template_json" | jq -r '
  [.sessions[].windows[].panes[] |
    (.cwd // ""), (.command // "")] |
  map(select(test("\\{\\{[^}]+\\}\\}"))) |
  map(capture("\\{\\{(?<name>[^}]+)\\}\\}").name) |
  unique | .[]
' 2>/dev/null || true)"
if [ -n "$unexpanded" ]; then
  printf 'apply-template.sh: unexpanded variable placeholders:\n' >&2
  printf '  {{%s}}\n' $unexpanded >&2
  printf 'Use --var to provide values or define them in the template variables section.\n' >&2
  exit 1
fi

# Step 6: Check for collisions and compute renames
resolve_collision_name() {
  local base_name="$1"
  local candidate="$base_name"

  if ! tmux has-session -t "=$candidate" 2>/dev/null; then
    printf '%s\n' "$candidate"
    return 0
  fi

  # Extract numeric suffix if present
  local stem="$base_name"
  local num=1
  if [[ "$base_name" =~ ^(.*)-([0-9]+)$ ]]; then
    stem="${BASH_REMATCH[1]}"
    num="${BASH_REMATCH[2]}"
  fi

  # Loop until we find a free name
  while true; do
    num=$((num + 1))
    candidate="${stem}-${num}"
    if ! tmux has-session -t "=$candidate" 2>/dev/null; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done
}

session_count="$(printf '%s' "$template_json" | jq '.sessions | length')"
declare -a original_names=()
declare -a resolved_names=()
any_renamed="false"

for ((i=0; i<session_count; i++)); do
  name="$(printf '%s' "$template_json" | jq -r ".sessions[$i].name")"
  original_names+=("$name")
  resolved="$(resolve_collision_name "$name")"
  resolved_names+=("$resolved")
  if [ "$name" != "$resolved" ]; then
    any_renamed="true"
  fi
done

# Step 7: Finalize manifest JSON
build_manifest() {
  local json="$1"
  local now_iso
  now_iso="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

  # Read tmux base indices so manifest pane_index values match what tmux assigns
  local base_index pane_base_index
  base_index="$(tmux show-options -gqv base-index 2>/dev/null)" || true
  base_index="${base_index:-0}"
  pane_base_index="$(tmux show-options -gqv pane-base-index 2>/dev/null)" || true
  pane_base_index="${pane_base_index:-0}"

  # Rewrite session names and build manifest structure
  local host
  host="$(tmux_revive_host)"
  json="$(printf '%s' "$json" | jq \
    --arg now "$now_iso" \
    --arg host "$host" \
    --argjson base_index "$base_index" \
    --argjson pane_base_index "$pane_base_index" '
    {
      snapshot_version: "1",
      source_type: "template",
      created_at: $now,
      host: $host,
      sessions: [.sessions[] | {
        session_name: .name,
        tmux_session_name: .name,
        session_id: "",
        session_guid: "",
        session_group: "",
        active_window_index: ((.active_window // 0) + $base_index),
        windows: [.windows | to_entries[] | .value as $w | .key as $wi | {
          window_index: ($wi + $base_index),
          window_name: $w.name,
          layout: ($w.layout // ""),
          active_pane_index: (($w.active_pane // 0) + $pane_base_index),
          is_zoomed: false,
          automatic_rename: "off",
          window_options: {},
          panes: [$w.panes | to_entries[] | .value as $p | .key as $pi | {
            pane_index: ($pi + $pane_base_index),
            pane_id_at_save: "",
            pane_title: "",
            cwd: ($p.cwd // ""),
            current_command: "",
            captured_layout_width: 0,
            captured_layout_height: 0,
            restore_strategy: (if $p.command then "restart-command" else "shell" end),
            nvim_state_ref: "",
            command_preview: ($p.command // ""),
            command_capture_source: "",
            restart_command: (
              if $p.env then
                ([$p.env | to_entries[] | "\(.key)=\(.value)"] | join(" ")) as $env_str |
                if $p.command then "env " + $env_str + " " + $p.command
                else ""
                end
              else
                ($p.command // "")
              end
            ),
            restart_command_source: (if $p.command then "template" else "" end),
            restore_strategy_override: "",
            transcript_excluded: true,
            path_to_history_dump: "",
            pane_options: {}
          }]
        }]
      }]
    }
  ')"

  # Rewrite session names with collision-resolved names and generate GUIDs
  for ((i=0; i<session_count; i++)); do
    local resolved="${resolved_names[$i]}"
    local guid
    guid="$(tmux_revive_generate_guid)"
    json="$(printf '%s' "$json" | jq \
      --argjson idx "$i" \
      --arg name "$resolved" \
      --arg guid "$guid" '
      .sessions[$idx].session_name = $name |
      .sessions[$idx].tmux_session_name = $name |
      .sessions[$idx].session_guid = $guid
    ')"
  done

  printf '%s\n' "$json"
}

manifest_json="$(build_manifest "$template_json")"

# Step 8: Dry-run output
if [ "$dry_run" = "true" ]; then
  printf 'Template: %s\n' "$template_name"
  printf 'Sessions to create:\n'
  for ((i=0; i<session_count; i++)); do
    local_orig="${original_names[$i]}"
    local_resolved="${resolved_names[$i]}"
    window_count="$(printf '%s' "$template_json" | jq ".sessions[$i].windows | length")"
    if [ "$local_orig" = "$local_resolved" ]; then
      printf '  %s  (%d windows)\n' "$local_resolved" "$window_count"
    else
      printf '  %s → %s  (%d windows)  [renamed — collision]\n' "$local_orig" "$local_resolved" "$window_count"
    fi
  done
  exit 0
fi

# Step 9: Write temp manifest
tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT
tmp_manifest="${tmp_dir}/manifest.json"
printf '%s\n' "$manifest_json" > "$tmp_manifest"

# Step 10: Call restore-state.sh
restore_args=(--manifest "$tmp_manifest" --yes)
if [ "$do_attach" = "true" ]; then
  restore_args+=(--attach)
fi

if ! "$script_dir/restore-state.sh" "${restore_args[@]}"; then
  # Step 11: Report on partial failure
  printf 'apply-template.sh: restore-state.sh exited with errors\n' >&2
  printf 'Some sessions may have been partially created. Check with: tmux list-sessions\n' >&2
  exit 1
fi

if [ "$any_renamed" = "true" ]; then
  printf 'Note: some sessions were renamed to avoid collisions:\n' >&2
  for ((i=0; i<session_count; i++)); do
    if [ "${original_names[$i]}" != "${resolved_names[$i]}" ]; then
      printf '  %s → %s\n' "${original_names[$i]}" "${resolved_names[$i]}" >&2
    fi
  done
fi
