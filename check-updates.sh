#!/usr/bin/env bash
# check-updates.sh — Check for upstream updates to tmux-revive.
#
# Usage:
#   check-updates.sh [--interactive]
#
# Compares local HEAD to origin/<default-branch>. When updates are found,
# writes an "update-available" flag file in the runtime directory. Skips
# the network fetch when the flag already exists (unless local HEAD has
# changed, indicating an external upgrade).
#
# --interactive  Show result via tmux display-message (for manage mode).
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/state-common.sh
source "$script_dir/lib/state-common.sh"

# ── Options ──────────────────────────────────────────────────────────
interactive=false
for arg in "$@"; do
  case "$arg" in
    --interactive) interactive=true ;;
  esac
done

plugin_dir="$script_dir"

# ── Guard: not a git repo or no origin remote ────────────────────────
if ! git -C "$plugin_dir" rev-parse --git-dir >/dev/null 2>&1; then
  $interactive && tmux display-message "tmux-revive: not a git repository, cannot check for updates" 2>/dev/null || true
  exit 0
fi
if ! git -C "$plugin_dir" remote get-url origin >/dev/null 2>&1; then
  $interactive && tmux display-message "tmux-revive: no 'origin' remote configured" 2>/dev/null || true
  exit 0
fi

# ── Runtime paths ────────────────────────────────────────────────────
runtime_dir="$(tmux_revive_runtime_dir 2>/dev/null || printf '%s' "$plugin_dir/.tmp")"
mkdir -p "$runtime_dir"
flag_file="$runtime_dir/update-available"
last_check_file="$runtime_dir/last-update-check"
lock_dir="$runtime_dir/update-check.lock"

# ── Concurrency lock ────────────────────────────────────────────────
if ! mkdir "$lock_dir" 2>/dev/null; then
  # Another check is running
  $interactive && tmux display-message "tmux-revive: update check already in progress" 2>/dev/null || true
  exit 0
fi
trap 'rm -rf "$lock_dir"' EXIT

# ── Stale flag revalidation ──────────────────────────────────────────
# If the update-available flag exists but local HEAD has moved (manual
# upgrade or plugin manager), the flag is stale — clear it.
if [ -f "$flag_file" ]; then
  stored_local_sha="$(grep '^local_sha=' "$flag_file" 2>/dev/null | cut -d= -f2 || true)"
  current_sha="$(git -C "$plugin_dir" rev-parse HEAD 2>/dev/null || true)"
  if [ -n "$stored_local_sha" ] && [ -n "$current_sha" ] && [ "$stored_local_sha" != "$current_sha" ]; then
    # HEAD moved — someone upgraded externally, clear stale flag
    rm -f "$flag_file"
  else
    # Flag is still valid — skip network fetch
    if $interactive; then
      behind_count="$(grep '^behind_count=' "$flag_file" 2>/dev/null | cut -d= -f2 || printf '?')"
      tmux display-message "tmux-revive: update available ($behind_count commit(s) behind) — press U to upgrade" 2>/dev/null || true
    fi
    date +%s >"$last_check_file"
    exit 0
  fi
fi

# ── Detect default branch ───────────────────────────────────────────
_detect_default_branch() {
  local ref
  # Try symbolic-ref first (no network needed after fetch)
  ref="$(git -C "$plugin_dir" symbolic-ref refs/remotes/origin/HEAD 2>/dev/null || true)"
  if [ -n "$ref" ]; then
    printf '%s\n' "${ref##refs/remotes/origin/}"
    return 0
  fi
  # Fallback: check common branch names
  for candidate in main master; do
    if git -C "$plugin_dir" rev-parse --verify "origin/$candidate" >/dev/null 2>&1; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done
  return 1
}

# ── Fetch ────────────────────────────────────────────────────────────
export GIT_TERMINAL_PROMPT=0
if ! git -C "$plugin_dir" fetch --quiet origin 2>/dev/null; then
  $interactive && tmux display-message "tmux-revive: fetch failed (network error?)" 2>/dev/null || true
  date +%s >"$last_check_file"
  exit 0
fi

# ── Compare ──────────────────────────────────────────────────────────
default_branch="$(_detect_default_branch)" || {
  $interactive && tmux display-message "tmux-revive: cannot detect default branch" 2>/dev/null || true
  date +%s >"$last_check_file"
  exit 0
}

local_sha="$(git -C "$plugin_dir" rev-parse HEAD 2>/dev/null || true)"
remote_sha="$(git -C "$plugin_dir" rev-parse "origin/$default_branch" 2>/dev/null || true)"

if [ -z "$local_sha" ] || [ -z "$remote_sha" ]; then
  $interactive && tmux display-message "tmux-revive: cannot determine revision" 2>/dev/null || true
  date +%s >"$last_check_file"
  exit 0
fi

if [ "$local_sha" = "$remote_sha" ]; then
  # Up to date
  rm -f "$flag_file"
  date +%s >"$last_check_file"
  $interactive && tmux display-message "tmux-revive: up to date" 2>/dev/null || true
  exit 0
fi

# Use rev-list to determine ahead/behind
counts="$(git -C "$plugin_dir" rev-list --left-right --count "HEAD...origin/$default_branch" 2>/dev/null || printf '0\t0')"
ahead="$(printf '%s' "$counts" | cut -f1)"
behind="$(printf '%s' "$counts" | cut -f2)"

if [ "$behind" -gt 0 ] 2>/dev/null; then
  # Updates available
  cat >"$flag_file" <<EOF
local_sha=$local_sha
remote_sha=$remote_sha
default_branch=$default_branch
behind_count=$behind
ahead_count=$ahead
check_timestamp=$(date +%s)
EOF
  date +%s >"$last_check_file"
  if $interactive; then
    if [ "${ahead:-0}" -gt 0 ] 2>/dev/null; then
      tmux display-message "tmux-revive: $behind update(s) available ($ahead local commit(s) ahead) — press U to upgrade" 2>/dev/null || true
    else
      tmux display-message "tmux-revive: $behind update(s) available — press U to upgrade" 2>/dev/null || true
    fi
  fi
else
  # Ahead only or diverged with no behind — no update needed
  rm -f "$flag_file"
  date +%s >"$last_check_file"
  if $interactive; then
    if [ "${ahead:-0}" -gt 0 ] 2>/dev/null; then
      tmux display-message "tmux-revive: up to date ($ahead local commit(s) ahead of origin)" 2>/dev/null || true
    else
      tmux display-message "tmux-revive: up to date" 2>/dev/null || true
    fi
  fi
fi
