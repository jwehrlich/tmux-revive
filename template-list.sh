#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/state-common.sh
source "$script_dir/lib/state-common.sh"

usage() {
  cat >&2 <<EOF
Usage: template-list.sh [options]

List available templates.

Options:
  --json       Output as JSON array
  -h, --help   Show this help

Output columns (default): NAME  SESSIONS  DESCRIPTION  UPDATED_AT
EOF
}

output_json="false"

while [ $# -gt 0 ]; do
  case "$1" in
    --json)
      output_json="true"
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      printf 'template-list.sh: unknown option: %s\n' "$1" >&2
      usage
      exit 1
      ;;
  esac
done

templates_dir="$(tmux_revive_templates_root)"

if [ ! -d "$templates_dir" ]; then
  if [ "$output_json" = "true" ]; then
    printf '[]\n'
  else
    printf 'No templates directory found.\n' >&2
  fi
  exit 0
fi

# Collect template info
declare -a json_entries=()
declare -a rows=()

shopt -s nullglob
template_files=("$templates_dir"/*.yaml)
shopt -u nullglob

if [ ${#template_files[@]} -eq 0 ]; then
  if [ "$output_json" = "true" ]; then
    printf '[]\n'
  else
    printf 'No templates found in %s\n' "$templates_dir" >&2
  fi
  exit 0
fi

for f in "${template_files[@]}"; do
  name="$(basename "$f" .yaml)"

  # Extract fields with yq (graceful fallback on parse errors)
  description="$(yq -r '.description // "-"' "$f" 2>/dev/null || printf '-')"
  updated_at="$(yq -r '.updated_at // "-"' "$f" 2>/dev/null || printf '-')"
  session_count="$(yq '.sessions | length' "$f" 2>/dev/null || printf '0')"

  if [ "$output_json" = "true" ]; then
    json_entries+=("$(jq -n \
      --arg name "$name" \
      --arg description "$description" \
      --arg updated_at "$updated_at" \
      --argjson sessions "$session_count" \
      '{name: $name, description: $description, sessions: $sessions, updated_at: $updated_at}')")
  else
    rows+=("$(printf '%s\t%s\t%s\t%s' "$name" "$session_count" "$description" "$updated_at")")
  fi
done

if [ "$output_json" = "true" ]; then
  printf '%s\n' "${json_entries[@]}" | jq -s '.'
else
  printf '%-20s %-10s %-30s %s\n' "NAME" "SESSIONS" "DESCRIPTION" "UPDATED_AT"
  for row in "${rows[@]}"; do
    IFS=$'\t' read -r r_name r_sessions r_desc r_updated <<< "$row"
    printf '%-20s %-10s %-30s %s\n' "$r_name" "$r_sessions" "$r_desc" "$r_updated"
  done
fi
