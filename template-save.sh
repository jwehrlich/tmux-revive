#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/parse-server-arg.sh
source "$script_dir/lib/parse-server-arg.sh"
# shellcheck source=lib/state-common.sh
source "$script_dir/lib/state-common.sh"

usage() {
  cat >&2 <<EOF
Usage: template-save.sh --name <name> [options]

Save live tmux session(s) as a YAML template.

Options:
  --name <name>           Template name (required)
  --sessions <s1,s2,...>  Comma-separated session names to capture
                          (default: current session only)
  --description <text>    Template description
  --force                 Overwrite existing template
  --server <name>         Target a specific tmux server
  -h, --help              Show this help

Examples:
  template-save.sh --name my-workspace
  template-save.sh --name fullstack --sessions frontend,backend
  template-save.sh --name dev --description "Dev environment"
EOF
}

template_name=""
sessions_arg=""
description=""
force="false"

while [ $# -gt 0 ]; do
  case "$1" in
    --name)
      template_name="${2:?--name requires a value}"
      shift 2
      ;;
    --sessions)
      sessions_arg="${2:?--sessions requires a value}"
      shift 2
      ;;
    --description)
      description="${2:?--description requires a value}"
      shift 2
      ;;
    --force)
      force="true"
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
      printf 'template-save.sh: unknown option: %s\n' "$1" >&2
      usage
      exit 1
      ;;
  esac
done

if [ -z "$template_name" ]; then
  printf 'template-save.sh: --name is required\n' >&2
  usage
  exit 1
fi

tmux_revive_require_yq || exit 1

# Resolve output path
templates_dir="$(tmux_revive_templates_root)"
mkdir -p "$templates_dir"
output_file="${templates_dir}/${template_name}.yaml"

if [ -f "$output_file" ] && [ "$force" != "true" ]; then
  printf 'template-save.sh: template already exists: %s\nUse --force to overwrite.\n' "$output_file" >&2
  exit 1
fi

# Determine which sessions to capture
declare -a session_names=()

if [ -n "$sessions_arg" ]; then
  IFS=',' read -ra session_names <<< "$sessions_arg"
else
  # Default: current session
  current="$(tmux display-message -p '#S' 2>/dev/null || true)"
  if [ -z "$current" ]; then
    printf 'template-save.sh: no current tmux session found\n' >&2
    exit 1
  fi
  session_names=("$current")
fi

# Validate all sessions exist
for s in "${session_names[@]}"; do
  if ! tmux has-session -t "=$s" 2>/dev/null; then
    printf 'template-save.sh: session not found: %s\n' "$s" >&2
    exit 1
  fi
done

# Capture process table once for command detection
process_table="$(tmux_revive_process_table || true)"

# Normalize path: replace $HOME prefix with ~
normalize_path() {
  local p="$1"
  if [ "$p" = "$HOME" ]; then
    printf '~\n'
  elif [[ "$p" == "$HOME/"* ]]; then
    printf '~/%s\n' "${p#"$HOME/"}"
  else
    printf '%s\n' "$p"
  fi
}

# Build JSON structure from live tmux state
sessions_json="[]"

for session_name in "${session_names[@]}"; do
  windows_json="[]"

  while IFS=$'\t' read -r window_index window_name window_layout; do
    panes_json="[]"

    while IFS=$'\t' read -r pane_id pane_index pane_cwd pane_command pane_pid; do
      # Capture full command line (not just process name)
      local_cmd=""
      if ! tmux_revive_command_is_shell "$pane_command"; then
        local_cmd="$(tmux_revive_capture_pane_command_preview "$process_table" "$pane_pid" "$pane_command" "" || true)"
      fi

      norm_cwd="$(normalize_path "$pane_cwd")"

      pane_json="$(jq -n \
        --arg cwd "$norm_cwd" \
        --arg command "$local_cmd" \
        'if $command != "" then {cwd: $cwd, command: $command} else {cwd: $cwd} end')"

      panes_json="$(printf '%s' "$panes_json" | jq --argjson pane "$pane_json" '. + [$pane]')"

    done < <(tmux list-panes -t "=$session_name:$window_index" \
      -F $'#{pane_id}\t#{pane_index}\t#{pane_current_path}\t#{pane_current_command}\t#{pane_pid}')

    window_json="$(jq -n \
      --arg name "$window_name" \
      --arg layout "$window_layout" \
      --argjson panes "$panes_json" \
      '{name: $name, layout: $layout, panes: $panes}')"

    windows_json="$(printf '%s' "$windows_json" | jq --argjson w "$window_json" '. + [$w]')"

  done < <(tmux list-windows -t "=$session_name" \
    -F $'#{window_index}\t#{window_name}\t#{window_layout}')

  session_json="$(jq -n \
    --arg name "$session_name" \
    --argjson windows "$windows_json" \
    '{name: $name, windows: $windows}')"

  sessions_json="$(printf '%s' "$sessions_json" | jq --argjson s "$session_json" '. + [$s]')"
done

# Build the complete template JSON
now_iso="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

template_json="$(jq -n \
  --arg name "$template_name" \
  --arg description "$description" \
  --arg updated_at "$now_iso" \
  --argjson sessions "$sessions_json" \
  '{name: $name, description: $description, updated_at: $updated_at, sessions: $sessions}')"

# Convert JSON → YAML and write
printf '%s' "$template_json" | yq -P '.' > "$output_file"

printf 'Template saved: %s\n' "$output_file"

# Log a hint about raw layout strings
has_raw_layout="$(printf '%s' "$template_json" | jq '[.sessions[].windows[].layout] | map(select(. != "" and (test("^[a-z-]+$") | not))) | length')"
if [ "$has_raw_layout" -gt 0 ]; then
  printf 'Hint: template contains raw tmux layout strings (embed terminal dimensions).\n' >&2
  printf '  For portability, consider replacing them with named layouts:\n' >&2
  printf '  even-horizontal, even-vertical, main-horizontal, main-vertical, tiled\n' >&2
fi
