#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/state-common.sh
source "$script_dir/lib/state-common.sh"

usage() {
  cat >&2 <<EOF
Usage: template-edit.sh --name <name>

Open a template in \$EDITOR for editing. After the editor exits, the
template is validated. If validation fails, you can re-open the editor
to fix errors or abort.

Options:
  --name <name>    Template name (required)
  -h, --help       Show this help
EOF
}

template_name=""

while [ $# -gt 0 ]; do
  case "$1" in
    --name)
      template_name="${2:?--name requires a value}"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      printf 'template-edit.sh: unknown option: %s\n' "$1" >&2
      usage
      exit 1
      ;;
  esac
done

if [ -z "$template_name" ]; then
  printf 'template-edit.sh: --name is required\n' >&2
  usage
  exit 1
fi

templates_dir="$(tmux_revive_templates_root)"
template_file="${templates_dir}/${template_name}.yaml"

if [ ! -f "$template_file" ]; then
  printf 'template-edit.sh: template not found: %s\n' "$template_file" >&2
  exit 1
fi

editor="${EDITOR:-${VISUAL:-vi}}"

# Capture checksum before editing to detect changes
checksum_before="$(cksum "$template_file")"

while true; do
  "$editor" "$template_file"

  # Check if file was actually modified
  checksum_after="$(cksum "$template_file")"
  if [ "$checksum_after" = "$checksum_before" ]; then
    printf 'No changes made.\n'
    exit 0
  fi

  # Validate
  if "$script_dir/template-validate.sh" --file "$template_file"; then
    # Update the updated_at timestamp
    now_iso="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    yq -i ".updated_at = \"$now_iso\"" "$template_file"
    printf 'Template updated successfully.\n'
    exit 0
  fi

  # Validation failed — prompt to re-edit
  printf '\nTemplate has validation errors.\n' >&2
  printf 'Re-open editor to fix? [Y/n] ' >&2
  read -r answer </dev/tty 2>/dev/null || answer="n"
  case "$answer" in
    n|N|no|No|NO)
      printf 'Aborted. Template may be in an invalid state.\n' >&2
      exit 1
      ;;
  esac
  # Loop back to editor
done
