#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/parse-server-arg.sh
source "$script_dir/lib/parse-server-arg.sh"
# shellcheck source=lib/state-common.sh
source "$script_dir/lib/state-common.sh"

bundle_path=""

print_help() {
  cat <<'EOF'
Usage: import-snapshot.sh --bundle PATH

Import one tmux-revive snapshot bundle into the local snapshot store.

Options:
  --help         Show this help text
  --bundle PATH  Import a specific tar.gz bundle
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --help|-h)
      print_help
      exit 0
      ;;
    --bundle)
      bundle_path="${2:-}"
      shift 2
      ;;
    --server)
      export TMUX_REVIVE_TMUX_SERVER="${2:?--server requires a name}"
      shift 2
      ;;
    *)
      printf 'Unknown argument: %s\n' "$1" >&2
      exit 1
      ;;
  esac
done

[ -n "$bundle_path" ] || {
  printf '%s\n' 'tmux-revive: --bundle is required' >&2
  exit 1
}
[ -f "$bundle_path" ] || {
  printf 'tmux-revive: bundle not found: %s\n' "$bundle_path" >&2
  exit 1
}

tmp_dir="$(mktemp -d "${TMPDIR:-/tmp}/tmux-revive-import.XXXXXX")"
cleanup() {
  rm -rf "$tmp_dir" >/dev/null 2>&1 || true
}
trap cleanup EXIT

tar -xzf "$bundle_path" -C "$tmp_dir" || {
  printf 'tmux-revive: failed to extract bundle: %s\n' "$bundle_path" >&2; exit 1
}
manifest_path="$(find "$tmp_dir" -type f -name manifest.json | head -n 1)"
[ -n "$manifest_path" ] || {
  printf 'tmux-revive: bundle did not contain a manifest: %s\n' "$bundle_path" >&2
  exit 1
}
# Validate extracted files stay inside tmp_dir (path traversal protection)
case "$manifest_path" in
  "$tmp_dir"/*) ;;
  *) printf 'tmux-revive: path traversal detected in bundle: %s\n' "$manifest_path" >&2; exit 1 ;;
esac
[ -f "$manifest_path" ] || {
  printf 'tmux-revive: extracted manifest not found: %s\n' "$manifest_path" >&2
  exit 1
}

source_snapshot_dir="$(dirname "$manifest_path")"
snapshot_root="$(tmux_revive_snapshots_root)"
timestamp="$(date -u +%Y-%m-%dT%H-%M-%SZ)"
bundle_name="$(basename "$bundle_path")"
import_dir="$snapshot_root/imported-${timestamp}-$$"
imported_manifest="$import_dir/manifest.json"

mkdir -p "$snapshot_root"
cp -R "$source_snapshot_dir" "$import_dir" || {
  printf 'tmux-revive: failed to copy snapshot\n' >&2; exit 1
}

manifest_tmp="${imported_manifest}.tmp.$$"
jq \
  --arg imported_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --arg bundle_name "$bundle_name" \
  --arg imported_host "$(tmux_revive_host)" \
  '
    .imported = true
    | .source = ((.source // {}) + {
        imported: true,
        bundle_name: $bundle_name,
        imported_at: $imported_at,
        imported_host: $imported_host,
        original_host: (.host // ""),
        original_created_at: (.created_at // "")
      })
  ' "$imported_manifest" >"$manifest_tmp" || {
  printf 'tmux-revive: failed to update manifest metadata\n' >&2
  rm -f "$manifest_tmp"; exit 1
}
mv "$manifest_tmp" "$imported_manifest"

printf '%s\n' "$imported_manifest"
