#!/usr/bin/env bash
set -euo pipefail

# Remove the tmux-revive systemd user service.

unit_path="$HOME/.config/systemd/user/tmux-revive.service"

if ! systemctl --user is-enabled tmux-revive.service >/dev/null 2>&1; then
  printf 'tmux-revive: systemd service not enabled\n'
  exit 0
fi

systemctl --user stop tmux-revive.service 2>/dev/null || true
systemctl --user disable tmux-revive.service 2>/dev/null || true
rm -f "$unit_path"
systemctl --user daemon-reload

printf 'tmux-revive: systemd service removed\n'
