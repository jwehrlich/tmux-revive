#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/state-common.sh
source "$script_dir/lib/state-common.sh"

usage() {
  cat >&2 <<EOF
Usage: template-validate.sh --name <name> | --file <path>

Validate a template YAML file for structural correctness.

Options:
  --name <name>    Validate template by name (looked up in templates root)
  --file <path>    Validate template at a specific file path
  --quiet          Suppress warnings, only report errors (exit code only)

Exit codes:
  0  Valid template
  1  Invalid template (errors found)
EOF
}

template_name=""
template_file=""
quiet="false"

while [ $# -gt 0 ]; do
  case "$1" in
    --name)
      template_name="${2:?--name requires a value}"
      shift 2
      ;;
    --file)
      template_file="${2:?--file requires a value}"
      shift 2
      ;;
    --quiet)
      quiet="true"
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      printf 'template-validate.sh: unknown option: %s\n' "$1" >&2
      usage
      exit 1
      ;;
  esac
done

# Resolve the template file path
if [ -n "$template_name" ] && [ -n "$template_file" ]; then
  printf 'template-validate.sh: specify --name or --file, not both\n' >&2
  exit 1
fi

if [ -n "$template_name" ]; then
  template_file="$(tmux_revive_templates_root)/${template_name}.yaml"
fi

if [ -z "$template_file" ]; then
  printf 'template-validate.sh: --name or --file is required\n' >&2
  usage
  exit 1
fi

if [ ! -f "$template_file" ]; then
  printf 'template-validate.sh: file not found: %s\n' "$template_file" >&2
  exit 1
fi

tmux_revive_require_yq || exit 1

errors=0
warnings=0

error() {
  printf 'ERROR: %s\n' "$1" >&2
  errors=$((errors + 1))
}

warn() {
  [ "$quiet" = "true" ] && return
  printf 'WARN:  %s\n' "$1" >&2
  warnings=$((warnings + 1))
}

# Check YAML is parseable
if ! yq '.' "$template_file" >/dev/null 2>&1; then
  error "YAML is not parseable: $template_file"
  # Can't continue if YAML is broken
  exit 1
fi

# Convert to JSON once for all checks
template_json="$(yq -o=json '.' "$template_file")"

# Required root fields
for field in name sessions; do
  if ! printf '%s' "$template_json" | jq -e ".$field" >/dev/null 2>&1; then
    error "missing required root field: $field"
  fi
done

# Sessions must be a non-empty array
session_count="$(printf '%s' "$template_json" | jq '.sessions | length' 2>/dev/null || printf '0')"
if [ "$session_count" -eq 0 ]; then
  error "sessions array is empty or missing"
fi

# Validate variables section (optional)
has_variables="$(printf '%s' "$template_json" | jq '.variables != null and (.variables | type == "object")' 2>/dev/null || printf 'false')"
if [ "$has_variables" = "true" ]; then
  while IFS= read -r vname; do
    [ -n "$vname" ] || continue
    vprompt="$(printf '%s' "$template_json" | jq -r ".variables[\"$vname\"].prompt // empty")"
    if [ -z "$vprompt" ]; then
      error "variables.$vname: missing required field: prompt"
    fi
  done < <(printf '%s' "$template_json" | jq -r '.variables | keys[]' 2>/dev/null)

  # Warn about {{var}} references in body that don't match a declared variable
  declared_vars="$(printf '%s' "$template_json" | jq -r '.variables | keys[]' 2>/dev/null || true)"
  body_refs="$(printf '%s' "$template_json" | jq -r '
    [.sessions[].windows[].panes[] | (.cwd // ""), (.command // "")] |
    map(select(test("\\{\\{[^}]+\\}\\}"))) |
    map(capture("\\{\\{(?<name>[^}]+)\\}\\}").name) | unique | .[]
  ' 2>/dev/null || true)"
  for ref in $body_refs; do
    if ! printf '%s\n' $declared_vars | grep -qx "$ref"; then
      warn "{{$ref}} referenced in template body but not declared in variables section"
    fi
  done
fi

# Validate each session
for ((s=0; s<session_count; s++)); do
  session_name="$(printf '%s' "$template_json" | jq -r ".sessions[$s].name // empty")"
  if [ -z "$session_name" ]; then
    error "sessions[$s]: missing required field: name"
    continue
  fi

  window_count="$(printf '%s' "$template_json" | jq ".sessions[$s].windows | length" 2>/dev/null || printf '0')"
  if [ "$window_count" -eq 0 ]; then
    error "sessions[$s] ($session_name): windows array is empty or missing"
    continue
  fi

  for ((w=0; w<window_count; w++)); do
    window_name="$(printf '%s' "$template_json" | jq -r ".sessions[$s].windows[$w].name // empty")"
    if [ -z "$window_name" ]; then
      error "sessions[$s].windows[$w] ($session_name): missing required field: name"
      continue
    fi

    pane_count="$(printf '%s' "$template_json" | jq ".sessions[$s].windows[$w].panes | length" 2>/dev/null || printf '0')"
    if [ "$pane_count" -eq 0 ]; then
      error "sessions[$s].windows[$w] ($session_name/$window_name): panes array is empty or missing"
      continue
    fi

    # Check each pane's cwd exists (after ~ expansion; YAML bare ~ is null)
    # Skip paths containing {{var}} placeholders (resolved at apply time)
    for ((p=0; p<pane_count; p++)); do
      pane_cwd="$(printf '%s' "$template_json" | jq -r ".sessions[$s].windows[$w].panes[$p].cwd // empty")"
      if [ -n "$pane_cwd" ] && [ "$pane_cwd" != "null" ]; then
        if [[ "$pane_cwd" == *"{{"*"}}"* ]]; then
          continue
        fi
        expanded_cwd="${pane_cwd/#\~/$HOME}"
        if [ ! -d "$expanded_cwd" ]; then
          warn "sessions[$s].windows[$w].panes[$p] ($session_name/$window_name): cwd does not exist: $pane_cwd"
        fi
      fi
    done
  done
done

if [ "$errors" -gt 0 ]; then
  [ "$quiet" = "false" ] && printf '\nValidation failed: %d error(s), %d warning(s)\n' "$errors" "$warnings" >&2
  exit 1
fi

if [ "$quiet" = "false" ] && [ "$warnings" -gt 0 ]; then
  printf '\nValidation passed with %d warning(s)\n' "$warnings" >&2
fi

exit 0
