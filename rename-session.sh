#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
current="$(tmux display-message -p '#S')"
tmux command-prompt -I "$current" -p "Rename session:" "rename-session -- '%%' \; set-option -q @tmux-revive-session-label '%%' \; run-shell -b '$script_dir/save-state.sh --auto --reason rename-session'"
