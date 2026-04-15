#!/usr/bin/env bash
# apply-updates.sh — Apply upstream updates to tmux-revive.
#
# Uses the user's preferred stash+rebase approach:
#   1. git fetch origin
#   2. Stash local changes if any
#   3. git rebase origin/<default-branch>
#   4. Pop stash if we stashed
#
# Handles detached HEAD by checking out the default branch first.
# On failure, aborts rebase and restores working tree.
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/state-common.sh
source "$script_dir/lib/state-common.sh"

plugin_dir="$script_dir"

# ── Helpers ──────────────────────────────────────────────────────────
_msg() {
  tmux display-message "tmux-revive: $1" 2>/dev/null || true
}

_log() {
  local runtime_dir
  runtime_dir="$(tmux_revive_runtime_dir 2>/dev/null || printf '%s' "$plugin_dir/.tmp")"
  local log_file="$runtime_dir/save-activity.log"
  if [ -d "$runtime_dir" ]; then
    printf '%s UPDATE %s\n' "$(date '+%Y-%m-%dT%H:%M:%S')" "$1" >>"$log_file" 2>/dev/null || true
  fi
}

# ── Guard: not a git repo or no origin ───────────────────────────────
if ! git -C "$plugin_dir" rev-parse --git-dir >/dev/null 2>&1; then
  _msg "not a git repository, cannot update"
  exit 1
fi
if ! git -C "$plugin_dir" remote get-url origin >/dev/null 2>&1; then
  _msg "no 'origin' remote configured"
  exit 1
fi

# ── Runtime paths ────────────────────────────────────────────────────
runtime_dir="$(tmux_revive_runtime_dir 2>/dev/null || printf '%s' "$plugin_dir/.tmp")"
flag_file="$runtime_dir/update-available"

# ── Detect default branch ───────────────────────────────────────────
_detect_default_branch() {
  local ref
  ref="$(git -C "$plugin_dir" symbolic-ref refs/remotes/origin/HEAD 2>/dev/null || true)"
  if [ -n "$ref" ]; then
    printf '%s\n' "${ref##refs/remotes/origin/}"
    return 0
  fi
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
_msg "fetching updates..."
_log "FETCH-START"

if ! git -C "$plugin_dir" fetch --prune origin 2>/dev/null; then
  _msg "fetch failed (network error?)"
  _log "FETCH-FAILED"
  exit 1
fi

default_branch="$(_detect_default_branch)" || {
  _msg "cannot detect default branch"
  exit 1
}

remote_sha="$(git -C "$plugin_dir" rev-parse "origin/$default_branch" 2>/dev/null || true)"
local_sha="$(git -C "$plugin_dir" rev-parse HEAD 2>/dev/null || true)"

if [ "$local_sha" = "$remote_sha" ]; then
  _msg "already up to date"
  rm -f "$flag_file"
  _log "ALREADY-UP-TO-DATE"
  exit 0
fi

# ── Handle detached HEAD ─────────────────────────────────────────────
on_branch=true
current_branch="$(git -C "$plugin_dir" symbolic-ref --short HEAD 2>/dev/null || true)"
if [ -z "$current_branch" ]; then
  on_branch=false
  # Try to checkout the default branch
  if ! git -C "$plugin_dir" checkout "$default_branch" 2>/dev/null; then
    _msg "detached HEAD and cannot checkout $default_branch — please update manually"
    _log "DETACHED-HEAD-FAILED branch=$default_branch"
    exit 1
  fi
  current_branch="$default_branch"
  _log "CHECKOUT branch=$default_branch (was detached)"
fi

# ── Stash local changes if any ───────────────────────────────────────
stash_pop=false
if [ -n "$(git -C "$plugin_dir" status --porcelain 2>/dev/null)" ]; then
  stash_pop=true
  git -C "$plugin_dir" stash --include-untracked 2>/dev/null || {
    _msg "failed to stash local changes"
    _log "STASH-FAILED"
    exit 1
  }
  _log "STASH-SAVED"
fi

# ── Rebase ───────────────────────────────────────────────────────────
_log "REBASE-START from=$(git -C "$plugin_dir" rev-parse --short HEAD) onto=origin/$default_branch"

if ! git -C "$plugin_dir" rebase "origin/$default_branch" 2>/dev/null; then
  # Rebase conflict — abort and restore
  _log "REBASE-CONFLICT"
  git -C "$plugin_dir" rebase --abort 2>/dev/null || true
  if $stash_pop; then
    git -C "$plugin_dir" stash pop 2>/dev/null || true
    _log "STASH-RESTORED"
  fi
  _msg "rebase conflict — update aborted, please resolve manually"
  exit 1
fi

new_sha="$(git -C "$plugin_dir" rev-parse --short HEAD 2>/dev/null || true)"
_log "REBASE-DONE new_head=$new_sha"

# ── Restore stashed changes ─────────────────────────────────────────
if $stash_pop; then
  if ! git -C "$plugin_dir" stash pop 2>/dev/null; then
    _msg "updated to $new_sha but stash pop had conflicts — resolve with: cd $plugin_dir && git stash pop"
    _log "STASH-POP-CONFLICT"
    rm -f "$flag_file"
    exit 1
  fi
  _log "STASH-RESTORED"
fi

# ── Cleanup ──────────────────────────────────────────────────────────
rm -f "$flag_file"
rm -f "$runtime_dir/last-update-check"
_log "UPDATE-COMPLETE to=$new_sha"
_msg "updated to $new_sha — run: tmux source-file ~/.tmux.conf  to reload"
