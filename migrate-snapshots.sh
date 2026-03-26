#!/usr/bin/env bash
set -euo pipefail

# Migrate pre-GUID snapshot manifests by injecting session_guid fields.
# After migration, legacy selectors (--session-id) are no longer needed
# for these snapshots.

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TMUX_REVIVE_SCRIPT_DIR="$script_dir"
# shellcheck source=lib/parse-server-arg.sh
source "$script_dir/lib/parse-server-arg.sh"
# shellcheck source=lib/state-common.sh
source "$script_dir/lib/state-common.sh"

dry_run="false"
verbose="false"

while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run)
      dry_run="true"
      shift
      ;;
    --verbose)
      verbose="true"
      shift
      ;;
    --server)
      export TMUX_REVIVE_TMUX_SERVER="${2:?--server requires a name}"
      shift 2
      ;;
    --help|-h)
      cat <<'EOF'
Usage: migrate-snapshots.sh [options]

Migrate pre-GUID snapshot manifests by injecting session_guid fields.

Options:
  --dry-run    Show what would be changed without modifying files
  --verbose    Print details for each manifest processed
  --server     Target a named tmux server
  --help       Show this help text
EOF
      exit 0
      ;;
    *)
      printf 'Unknown argument: %s\n' "$1" >&2
      exit 1
      ;;
  esac
done

snapshots_root="$(tmux_revive_snapshots_root)"
if [ ! -d "$snapshots_root" ]; then
  printf 'No snapshots directory found at %s\n' "$snapshots_root"
  exit 0
fi

migrated=0
skipped=0
errors=0

while IFS= read -r manifest; do
  [ -f "$manifest" ] || continue

  # Check if any session is missing a GUID
  needs_migration="$(jq '[.sessions[]? | select((.session_guid // "") == "")] | length > 0' "$manifest" 2>/dev/null || echo "false")"
  if [ "$needs_migration" != "true" ]; then
    skipped=$((skipped + 1))
    [ "$verbose" = "true" ] && printf 'skip (all GUIDs present): %s\n' "$manifest"
    continue
  fi

  if [ "$dry_run" = "true" ]; then
    session_count="$(jq '[.sessions[]? | select((.session_guid // "") == "")] | length' "$manifest" 2>/dev/null || echo "?")"
    printf 'would migrate: %s (%s sessions without GUIDs)\n' "$manifest" "$session_count"
    migrated=$((migrated + 1))
    continue
  fi

  # Inject GUIDs one session at a time
  tmp_path="${manifest}.tmp.$$"
  cp "$manifest" "$tmp_path"
  ok="true"
  session_count="$(jq '.sessions | length' "$tmp_path" 2>/dev/null)" || { rm -f "$tmp_path"; errors=$((errors + 1)); continue; }
  for ((idx = 0; idx < session_count; idx++)); do
    existing="$(jq -r ".sessions[$idx].session_guid // \"\"" "$tmp_path")"
    [ -z "$existing" ] || continue
    guid="$(tmux_revive_generate_guid)"
    if ! jq --arg guid "$guid" --argjson idx "$idx" '.sessions[$idx].session_guid = $guid' "$tmp_path" >"${tmp_path}.new" 2>/dev/null; then
      ok="false"
      break
    fi
    mv "${tmp_path}.new" "$tmp_path"
  done
  if [ "$ok" = "true" ]; then
    mv "$tmp_path" "$manifest" || { rm -f "$tmp_path"; errors=$((errors + 1)); continue; }
    migrated=$((migrated + 1))
    [ "$verbose" = "true" ] && printf 'migrated: %s\n' "$manifest"
  else
    rm -f "$tmp_path" "${tmp_path}.new" 2>/dev/null
    errors=$((errors + 1))
    printf 'error migrating: %s\n' "$manifest" >&2
  fi
done < <(find "$snapshots_root" -name manifest.json -type f | sort)

printf 'Migration complete: %d migrated, %d skipped, %d errors\n' "$migrated" "$skipped" "$errors"
