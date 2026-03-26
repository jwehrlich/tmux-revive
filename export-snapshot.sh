#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/parse-server-arg.sh
source "$script_dir/lib/parse-server-arg.sh"
# shellcheck source=lib/state-common.sh
source "$script_dir/lib/state-common.sh"

manifest_path=""
output_path=""

print_help() {
  cat <<'EOF'
Usage: export-snapshot.sh [options]

Export one tmux-revive snapshot as a portable tar.gz bundle.

Options:
  --help           Show this help text
  --latest         Export the latest saved snapshot (default)
  --manifest PATH  Export a specific snapshot manifest
  --output PATH    Write the bundle to PATH
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --help|-h)
      print_help
      exit 0
      ;;
    --latest)
      shift
      ;;
    --manifest)
      manifest_path="${2:-}"
      shift 2
      ;;
    --output)
      output_path="${2:-}"
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

if [ -z "$manifest_path" ]; then
  manifest_path="$(tmux_revive_find_latest_manifest || true)"
fi

[ -n "$manifest_path" ] || {
  printf '%s\n' 'tmux-revive: no snapshot available to export' >&2
  exit 1
}
[ -f "$manifest_path" ] || {
  printf 'tmux-revive: manifest not found: %s\n' "$manifest_path" >&2
  exit 1
}

snapshot_dir="$(dirname "$manifest_path")"
snapshot_name="$(basename "$snapshot_dir")"

if [ -z "$output_path" ]; then
  output_path="$PWD/${snapshot_name}.tar.gz"
fi

mkdir -p "$(dirname "$output_path")"
tar -czf "$output_path" -C "$(dirname "$snapshot_dir")" -- "$snapshot_name" || {
  printf 'tmux-revive: failed to create export bundle\n' >&2
  exit 1
}
printf '%s\n' "$output_path"
