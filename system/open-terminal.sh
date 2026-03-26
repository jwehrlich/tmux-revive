#!/usr/bin/env bash
set -euo pipefail

if [ "$(uname -s)" != "Darwin" ]; then
  printf 'open-terminal: this script is macOS-only\n' >&2
  exit 1
fi

# Open a terminal application on macOS and run tmux inside it.
# Usage: open-terminal.sh [--app terminal|iterm2|kitty|alacritty] [--fullscreen]
#
# If --app is omitted, reads @tmux-revive-terminal-app tmux option,
# then falls back to $TMUX_REVIVE_TERMINAL_APP, then auto-detects.

app=""
fullscreen=""

while [ $# -gt 0 ]; do
  case "$1" in
    --app) app="${2:?--app requires a value}"; shift 2 ;;
    --fullscreen) fullscreen=1; shift ;;
    *) shift ;;
  esac
done

# Try tmux option, then env var, then auto-detect
if [ -z "$app" ]; then
  app="$(tmux show-option -gqv '@tmux-revive-terminal-app' 2>/dev/null || printf '')"
fi
if [ -z "$app" ]; then
  app="${TMUX_REVIVE_TERMINAL_APP:-}"
fi
if [ -z "$app" ]; then
  # Auto-detect: prefer iTerm2 > Kitty > Alacritty > Terminal.app
  if [ -d "/Applications/iTerm.app" ]; then
    app="iterm2"
  elif [ -d "/Applications/kitty.app" ]; then
    app="kitty"
  elif [ -d "/Applications/Alacritty.app" ]; then
    app="alacritty"
  else
    app="terminal"
  fi
fi

# Normalize app name
case "$app" in
  iterm|iterm2|iTerm|iTerm2) app="iterm2" ;;
  kitty|Kitty) app="kitty" ;;
  alacritty|Alacritty) app="alacritty" ;;
  terminal|Terminal|Terminal.app) app="terminal" ;;
  *)
    printf 'open-terminal: unknown terminal app: %s\n' "$app" >&2
    printf 'Supported: terminal, iterm2, kitty, alacritty\n' >&2
    exit 1
    ;;
esac

open_terminal() {
  case "$app" in
    terminal)
      osascript <<'APPLESCRIPT'
tell application "Terminal"
  if not (exists window 1) then reopen
  activate
  set winID to id of window 1
  do script "tmux" in window id winID
end tell
APPLESCRIPT
      ;;
    iterm2)
      osascript <<'APPLESCRIPT'
tell application "iTerm"
  activate
  try
    set _win to current window
  on error
    create window with default profile
    set _win to current window
  end try
  tell current session of _win
    write text "tmux"
  end tell
end tell
APPLESCRIPT
      ;;
    kitty)
      if command -v kitty >/dev/null 2>&1; then
        kitty @ launch --type=os-window -- tmux 2>/dev/null \
          || kitty --single-instance -e tmux 2>/dev/null \
          || osascript -e 'tell application "kitty" to activate' -e 'delay 0.5' -e 'tell application "System Events" to tell process "kitty" to keystroke "tmux" & return'
      else
        open -a kitty --args -e tmux
      fi
      return 0
      ;;
      ;;
    alacritty)
      osascript <<'APPLESCRIPT'
tell application "Alacritty"
  activate
  delay 0.5
  tell application "System Events" to tell process "Alacritty"
    set frontmost to true
    keystroke "tmux"
    key code 36
  end tell
end tell
APPLESCRIPT
      ;;
  esac
}

fullscreen_terminal() {
  case "$app" in
    terminal)
      osascript <<'APPLESCRIPT'
tell application "Terminal"
  delay 1
  activate
  delay 0.1
  tell application "System Events"
    keystroke "f" using {control down, command down}
  end tell
end tell
APPLESCRIPT
      ;;
    iterm2)
      osascript <<'APPLESCRIPT'
tell application "iTerm"
  delay 1
  activate
  delay 0.1
  tell application "System Events"
    key code 36 using {command down}
  end tell
end tell
APPLESCRIPT
      ;;
    kitty|alacritty)
      local app_name
      case "$app" in
        kitty) app_name="kitty" ;;
        alacritty) app_name="Alacritty" ;;
      esac
      osascript <<APPLESCRIPT
tell application "$app_name"
  activate
  delay 0.5
  tell application "System Events" to tell process "$app_name"
    if front window exists then
      tell front window
        set value of attribute "AXFullScreen" to true
      end tell
    end if
  end tell
end tell
APPLESCRIPT
      ;;
  esac
}

open_terminal
if [ "$fullscreen" = "1" ]; then
  fullscreen_terminal
fi
