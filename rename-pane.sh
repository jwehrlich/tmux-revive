#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
current="$(tmux display-message -p '#T')"
tmux command-prompt -I "$current" -p "Rename pane title:" "select-pane -T '%%' \; run-shell -b '$script_dir/save-state.sh --auto --reason rename-pane'"
