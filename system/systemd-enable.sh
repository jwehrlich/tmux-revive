#!/usr/bin/env bash
set -euo pipefail

# Install a systemd user service that starts tmux on login
# and saves sessions on shutdown.

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
tmux_revive_dir="$(cd "$script_dir/.." && pwd)"

unit_dir="$HOME/.config/systemd/user"
unit_path="$unit_dir/tmux-revive.service"

tmux_bin="$(command -v tmux 2>/dev/null || printf '/usr/bin/tmux')"
save_state="$tmux_revive_dir/save-state.sh"

if systemctl --user is-enabled tmux-revive.service >/dev/null 2>&1; then
  printf 'tmux-revive: systemd service already enabled\n'
  printf 'Run systemd-disable.sh to remove it first.\n'
  exit 1
fi

mkdir -p "$unit_dir"

cat >"$unit_path" <<EOF
[Unit]
Description=tmux-revive session auto-start
After=default.target

[Service]
Type=forking
ExecStart=${tmux_bin} new-session -d -s _systemd_init
ExecStop=${save_state} --auto --reason systemd-stop
ExecStop=${tmux_bin} kill-server
KillMode=control-group
RestartSec=2

[Install]
WantedBy=default.target
EOF

systemctl --user daemon-reload
systemctl --user enable tmux-revive.service

printf 'tmux-revive: systemd user service enabled\n'
printf 'tmux will auto-start on your next login and save on shutdown.\n'
printf 'To start now: systemctl --user start tmux-revive.service\n'
