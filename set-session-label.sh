#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/state-common.sh
source "$script_dir/lib/state-common.sh"

current_session_id="$(tmux display-message -p '#{session_id}')"
current_tmux_name="$(tmux display-message -p '#S')"
current_label="$(tmux_revive_session_label_or_name "$current_session_id" "$current_tmux_name")"

tmux command-prompt -I "$current_label" -p "Set session label:" "set-option -q @tmux-revive-session-label '%%' \; run-shell -b '$script_dir/save-state.sh --auto --reason set-session-label'"
