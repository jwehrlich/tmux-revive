#!/usr/bin/env bash
# template-import.sh — import a template from a .tar.gz bundle
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/state-common.sh
source "$script_dir/lib/state-common.sh"

usage() {
  cat >&2 <<EOF
Usage: template-import.sh <bundle.tar.gz> [--force] [--name <name>]

Import a template from a portable .tar.gz bundle.

Options:
  <bundle>           Path to .tar.gz bundle (required, positional)
  --name <name>      Override template name (default: use name from YAML)
  --force            Overwrite existing template
  -h, --help         Show this help
EOF
}

bundle_path=""
override_name=""
force="false"

while [ $# -gt 0 ]; do
  case "$1" in
    --name)  override_name="${2:?--name requires a value}"; shift 2 ;;
    --force) force="true"; shift ;;
    -h|--help) usage; exit 0 ;;
    -*)      printf 'template-import: unknown option: %s\n' "$1" >&2; exit 1 ;;
    *)
      if [ -z "$bundle_path" ]; then
        bundle_path="$1"; shift
      else
        printf 'template-import: unexpected argument: %s\n' "$1" >&2; exit 1
      fi
      ;;
  esac
done

if [ -z "$bundle_path" ]; then
  printf 'template-import: bundle path is required\n' >&2
  usage
  exit 1
fi

if [ ! -f "$bundle_path" ]; then
  printf 'template-import: bundle not found: %s\n' "$bundle_path" >&2
  exit 1
fi

tmux_revive_require_yq

# Extract to a temp directory
tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT

if ! tar -xzf "$bundle_path" -C "$tmp_dir" 2>/dev/null; then
  printf 'template-import: failed to extract bundle: %s\n' "$bundle_path" >&2
  exit 1
fi

# Find the YAML file in the extracted contents
yaml_file=""
while IFS= read -r f; do
  yaml_file="$f"
  break
done < <(find "$tmp_dir" -maxdepth 1 -type f -name '*.yaml' 2>/dev/null)

if [ -z "$yaml_file" ]; then
  printf 'template-import: no .yaml file found in bundle\n' >&2
  exit 1
fi

# Validate the extracted template
if ! "$script_dir/template-validate.sh" --file "$yaml_file" --quiet 2>/dev/null; then
  printf 'template-import: imported template has validation errors:\n' >&2
  "$script_dir/template-validate.sh" --file "$yaml_file" >&2 || true
  exit 1
fi

# Determine the template name
template_name="$override_name"
if [ -z "$template_name" ]; then
  template_name="$(yq -r '.name // ""' "$yaml_file" 2>/dev/null || true)"
fi

if [ -z "$template_name" ]; then
  printf 'template-import: could not determine template name from bundle\n' >&2
  exit 1
fi

templates_root="$(tmux_revive_templates_root)"
mkdir -p "$templates_root"
dest_file="$templates_root/${template_name}.yaml"

if [ -f "$dest_file" ] && [ "$force" != "true" ]; then
  printf 'template-import: template "%s" already exists (use --force to overwrite)\n' "$template_name" >&2
  exit 1
fi

# If --name override, update the name field in the YAML
if [ -n "$override_name" ]; then
  yq -i ".name = \"$override_name\"" "$yaml_file" 2>/dev/null || true
fi

# Update updated_at timestamp
yq -i ".updated_at = \"$(date -u +%Y-%m-%dT%H:%M:%SZ)\"" "$yaml_file" 2>/dev/null || true

cp "$yaml_file" "$dest_file"
printf 'Imported template "%s" → %s\n' "$template_name" "$dest_file" >&2
