#!/usr/bin/env bash
# template-export.sh — export a template as a .tar.gz bundle
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/state-common.sh
source "$script_dir/lib/state-common.sh"

usage() {
  cat >&2 <<EOF
Usage: template-export.sh --name <template> [--output <path>]

Export a template as a portable .tar.gz bundle.

Options:
  --name <name>      Template name (required)
  --output <path>    Output file path (default: ./<name>.tmux-template.tar.gz)
  -h, --help         Show this help
EOF
}

template_name=""
output_path=""

while [ $# -gt 0 ]; do
  case "$1" in
    --name)   template_name="${2:?--name requires a value}"; shift 2 ;;
    --output) output_path="${2:?--output requires a path}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) printf 'template-export: unknown argument: %s\n' "$1" >&2; exit 1 ;;
  esac
done

if [ -z "$template_name" ]; then
  printf 'template-export: --name is required\n' >&2
  usage
  exit 1
fi

templates_root="$(tmux_revive_templates_root)"
template_file="$templates_root/${template_name}.yaml"

if [ ! -f "$template_file" ]; then
  printf 'template-export: template "%s" not found at %s\n' "$template_name" "$template_file" >&2
  exit 1
fi

# Validate before exporting
if ! "$script_dir/template-validate.sh" --file "$template_file" --quiet 2>/dev/null; then
  printf 'template-export: template "%s" has validation errors\n' "$template_name" >&2
  "$script_dir/template-validate.sh" --file "$template_file" >&2 || true
  exit 1
fi

if [ -z "$output_path" ]; then
  output_path="./${template_name}.tmux-template.tar.gz"
fi

# Create tar.gz from the template file
# Use -C to strip the directory path, archive just the yaml file
tar -czf "$output_path" -C "$templates_root" "${template_name}.yaml"

printf 'Exported template "%s" → %s\n' "$template_name" "$output_path" >&2
