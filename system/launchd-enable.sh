#!/usr/bin/env bash
set -euo pipefail

if [ "$(uname -s)" != "Darwin" ]; then
  printf 'launchd-enable: this script is macOS-only\n' >&2
  exit 1
fi

# Install a macOS launchd agent that starts tmux on login
# and restores sessions via tmux-revive.

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
tmux_revive_dir="$(cd "$script_dir/.." && pwd)"

plist_name="com.tmux-revive.autostart"
plist_path="$HOME/Library/LaunchAgents/${plist_name}.plist"
runner_path="$tmux_revive_dir/system/launchd-runner.sh"

# Escape for XML: & < > must be entity-encoded in plist strings
xml_escape() { printf '%s' "$1" | sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g'; }
plist_name_xml="$(xml_escape "$plist_name")"
runner_path_xml="$(xml_escape "$runner_path")"

if [ -f "$plist_path" ]; then
  printf 'tmux-revive: launchd agent already installed at %s\n' "$plist_path"
  printf 'Run launchd-disable.sh to remove it first.\n'
  exit 1
fi

mkdir -p "$HOME/Library/LaunchAgents"

cat >"$plist_path" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>${plist_name_xml}</string>

  <key>ProgramArguments</key>
  <array>
    <string>/bin/bash</string>
    <string>${runner_path_xml}</string>
  </array>

  <key>RunAtLoad</key>
  <true/>

  <key>StandardOutPath</key>
  <string>${HOME}/.local/share/tmux-revive/launchd.log</string>

  <key>StandardErrorPath</key>
  <string>${HOME}/.local/share/tmux-revive/launchd.log</string>
</dict>
</plist>
EOF

printf 'tmux-revive: launchd agent installed at %s\n' "$plist_path"
printf 'tmux will auto-start and restore sessions on your next login.\n'
mkdir -p "$HOME/.local/share/tmux-revive"
printf 'To start immediately: launchctl bootstrap gui/$(id -u) %s\n' "$plist_path"
