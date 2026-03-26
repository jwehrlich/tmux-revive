#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/state-common.sh
source "$script_dir/lib/state-common.sh"

usage() {
  cat >&2 <<EOF
Usage: template-delete.sh --name <name> [--yes]

Delete a template.

Options:
  --name <name>    Template name (required)
  --yes            Skip confirmation prompt
  -h, --help       Show this help
EOF
}

template_name=""
skip_confirm="false"

while [ $# -gt 0 ]; do
  case "$1" in
    --name)
      template_name="${2:?--name requires a value}"
      shift 2
      ;;
    --yes)
      skip_confirm="true"
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      printf 'template-delete.sh: unknown option: %s\n' "$1" >&2
      usage
      exit 1
      ;;
  esac
done

if [ -z "$template_name" ]; then
  printf 'template-delete.sh: --name is required\n' >&2
  usage
  exit 1
fi

templates_dir="$(tmux_revive_templates_root)"
template_file="${templates_dir}/${template_name}.yaml"

if [ ! -f "$template_file" ]; then
  printf 'template-delete.sh: template not found: %s\n' "$template_name" >&2
  exit 1
fi

if [ "$skip_confirm" != "true" ]; then
  printf 'Delete template "%s"? [y/N] ' "$template_name" >&2
  read -r answer 2>/dev/null || answer="n"
  case "$answer" in
    y|Y|yes|Yes|YES) ;;
    *)
      printf 'Aborted.\n' >&2
      exit 1
      ;;
  esac
fi

rm -f "$template_file"
printf 'Template deleted: %s\n' "$template_name"
