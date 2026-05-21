#!/usr/bin/env bash
set -euo pipefail

snapshot_file="${1:-}"
[ -n "$snapshot_file" ] || exit 1

TMUX_NVIM_RESTORE_STATE="$snapshot_file" exec nvim
