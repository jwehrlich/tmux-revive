#!/usr/bin/env bash
# Rename an auto-numbered session to the lowest available numeric name.
# Called from after-new-session hook to fill gaps (e.g. if "1" exists
# but "0" doesn't, rename the new session to "0").
#
# Usage: fill-session-gap.sh <session_id>
set -euo pipefail

session_id="${1:-}"
[ -n "$session_id" ] || exit 0

# Only act on sessions with pure-numeric names (auto-assigned by tmux)
session_name="$(tmux display-message -p -t "$session_id" '#{session_name}' 2>/dev/null || true)"
[ -n "$session_name" ] || exit 0
case "$session_name" in
  *[!0-9]*) exit 0 ;;  # not a numeric name — user named it
esac

# Collect all numeric session names
numeric_names=""
while IFS= read -r name; do
  case "$name" in
    *[!0-9]*) continue ;;
  esac
  numeric_names="${numeric_names}${name}
"
done < <(tmux list-sessions -F '#{session_name}' 2>/dev/null)

# Find the lowest available number
lowest=0
while printf '%s' "$numeric_names" | grep -qxF "$lowest"; do
  lowest=$((lowest + 1))
done

# Rename if the lowest available is less than the current name
if [ "$lowest" -lt "$session_name" ]; then
  tmux rename-session -t "$session_id" "$lowest" 2>/dev/null || true
fi
