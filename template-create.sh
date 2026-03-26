#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/state-common.sh
source "$script_dir/lib/state-common.sh"

usage() {
  cat >&2 <<EOF
Usage: template-create.sh --name <name> [--blank | --from-snapshot <path>]

Create a new template.

Modes:
  --blank                  Create a scaffolded example template
  --from-snapshot <path>   Create from a snapshot manifest

Options:
  --name <name>            Template name (required)
  --description <text>     Template description
  --force                  Overwrite existing template
  --edit                   Open in \$EDITOR after creation
  -h, --help               Show this help

Examples:
  template-create.sh --name my-workspace --blank
  template-create.sh --name my-workspace --blank --edit
  template-create.sh --name from-snap --from-snapshot ~/.tmux/data/snapshots/host/2026-01-01/manifest.json
EOF
}

template_name=""
mode=""
snapshot_path=""
description=""
force="false"
do_edit="false"

while [ $# -gt 0 ]; do
  case "$1" in
    --name)
      template_name="${2:?--name requires a value}"
      shift 2
      ;;
    --blank)
      mode="blank"
      shift
      ;;
    --from-snapshot)
      mode="snapshot"
      snapshot_path="${2:?--from-snapshot requires a path}"
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
    --edit)
      do_edit="true"
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      printf 'template-create.sh: unknown option: %s\n' "$1" >&2
      usage
      exit 1
      ;;
  esac
done

if [ -z "$template_name" ]; then
  printf 'template-create.sh: --name is required\n' >&2
  usage
  exit 1
fi

if [ -z "$mode" ]; then
  printf 'template-create.sh: specify --blank or --from-snapshot\n' >&2
  usage
  exit 1
fi

tmux_revive_require_yq || exit 1

templates_dir="$(tmux_revive_templates_root)"
mkdir -p "$templates_dir"
output_file="${templates_dir}/${template_name}.yaml"

if [ -f "$output_file" ] && [ "$force" != "true" ]; then
  printf 'template-create.sh: template already exists: %s\nUse --force to overwrite.\n' "$output_file" >&2
  exit 1
fi

now_iso="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

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

case "$mode" in
  blank)
    cat > "$output_file" <<YAML
# Template: ${template_name}
# Edit this file to define your workspace, then apply with:
#   apply-template.sh --name ${template_name}

name: ${template_name}
description: "${description:-TODO: describe this workspace}"
updated_at: "${now_iso}"

# Uncomment to add template variables:
# variables:
#   project_dir:
#     prompt: "Project directory"
#     default: ~/src/myproject

sessions:
  - name: main
    windows:
      - name: editor
        # layout: main-vertical
        panes:
          - cwd: ~
            command: nvim .
          - cwd: ~

      - name: shell
        panes:
          - cwd: ~

  # Uncomment to add a second session:
  # - name: services
  #   windows:
  #     - name: server
  #       panes:
  #         - cwd: ~/src/api
  #           command: npm run dev
  #           env:
  #             NODE_ENV: development
YAML
    printf 'Template created: %s\n' "$output_file"
    ;;

  snapshot)
    if [ ! -f "$snapshot_path" ]; then
      printf 'template-create.sh: snapshot manifest not found: %s\n' "$snapshot_path" >&2
      exit 1
    fi

    # Extract session/window/pane structure from snapshot manifest
    template_json="$(jq --arg name "$template_name" \
      --arg desc "$description" \
      --arg updated "$now_iso" \
      --arg home "$HOME" '
      {
        name: $name,
        description: ($desc // "Created from snapshot"),
        updated_at: $updated,
        sessions: [.sessions[] | {
          name: .session_name,
          windows: [.windows[] | {
            name: .window_name,
            layout: (.layout // ""),
            panes: [.panes[] | {
              cwd: (
                if (.cwd // "") == "" then "~"
                elif (.cwd | startswith($home + "/")) then ("~/" + (.cwd | ltrimstr($home + "/")))
                elif .cwd == $home then "~"
                else .cwd
                end
              )
            } + (
              if (.restart_command // "") != "" then {command: .restart_command}
              elif (.command_preview // "") != "" then {command: .command_preview}
              else {}
              end
            )]
          }]
        }]
      }
    ' "$snapshot_path")"

    printf '%s' "$template_json" | yq -P '.' > "$output_file"
    printf 'Template created from snapshot: %s\n' "$output_file"

    # Log layout hint
    has_raw_layout="$(printf '%s' "$template_json" | jq '[.sessions[].windows[].layout] | map(select(. != "" and (test("^[a-z-]+$") | not))) | length')"
    if [ "$has_raw_layout" -gt 0 ]; then
      printf 'Hint: template contains raw tmux layout strings.\n' >&2
      printf '  For portability, replace with: even-horizontal, even-vertical, main-horizontal, main-vertical, tiled\n' >&2
    fi
    ;;
esac

if [ "$do_edit" = "true" ]; then
  editor="${EDITOR:-${VISUAL:-vi}}"
  exec "$editor" "$output_file"
fi
