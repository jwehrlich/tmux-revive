#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
current="$(tmux display-message -p '#W')"
tmux command-prompt -I "$current" -p "Rename window:" "rename-window -- '%%' \; run-shell -b '$script_dir/save-state.sh --auto --reason rename-window'"
