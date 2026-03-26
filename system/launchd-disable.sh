#!/usr/bin/env bash
set -euo pipefail

if [ "$(uname -s)" != "Darwin" ]; then
  printf 'launchd-disable: this script is macOS-only\n' >&2
  exit 1
fi

# Remove the tmux-revive launchd agent.

plist_name="com.tmux-revive.autostart"
plist_path="$HOME/Library/LaunchAgents/${plist_name}.plist"

if [ ! -f "$plist_path" ]; then
  printf 'tmux-revive: no launchd agent found at %s\n' "$plist_path"
  exit 0
fi

launchctl bootout "gui/$(id -u)" "$plist_path" 2>/dev/null \
  || launchctl unload "$plist_path" 2>/dev/null || true
rm -f "$plist_path"
printf 'tmux-revive: launchd agent removed\n'
