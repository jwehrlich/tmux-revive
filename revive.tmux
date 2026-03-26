#!/usr/bin/env bash
# tmux-revive plugin entry point (TPM-compatible)

CURRENT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"

source "$CURRENT_DIR/lib/state-common.sh"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

get_tmux_option() {
  local option="$1"
  local default_value="$2"
  local value
  value="$(tmux show-option -gqv "$option" 2>/dev/null || true)"
  if [ -n "$value" ]; then
    printf '%s' "$value"
  else
    printf '%s' "$default_value"
  fi
}

# ---------------------------------------------------------------------------
# Read user configuration
# ---------------------------------------------------------------------------

autosave="$(get_tmux_option "@tmux-revive-autosave" "on")"
autosave_interval="$(get_tmux_option "@tmux-revive-autosave-interval" "900")"
startup_restore="$(get_tmux_option "@tmux-revive-startup-restore" "prompt")"
save_key="$(get_tmux_option "@tmux-revive-save-key" "S")"
restore_key="$(get_tmux_option "@tmux-revive-restore-key" "R")"
manage_key="$(get_tmux_option "@tmux-revive-manage-key" "m")"

# Retention
tmux set-option -gq "@tmux-revive-retention-enabled" \
  "$(get_tmux_option "@tmux-revive-retention-enabled" "on")"
tmux set-option -gq "@tmux-revive-retention-auto-count" \
  "$(get_tmux_option "@tmux-revive-retention-auto-count" "20")"
tmux set-option -gq "@tmux-revive-retention-manual-count" \
  "$(get_tmux_option "@tmux-revive-retention-manual-count" "60")"
tmux set-option -gq "@tmux-revive-retention-auto-age-days" \
  "$(get_tmux_option "@tmux-revive-retention-auto-age-days" "14")"
tmux set-option -gq "@tmux-revive-retention-manual-age-days" \
  "$(get_tmux_option "@tmux-revive-retention-manual-age-days" "90")"

# ---------------------------------------------------------------------------
# Data directory — resolve once, propagate to all child scripts
# ---------------------------------------------------------------------------

# User override via tmux option; empty string → auto-detect in state-common.sh
data_dir="$(get_tmux_option "@tmux-revive-data-dir" "")"
if [ -z "$data_dir" ]; then
  data_dir="$(tmux_revive_state_root)"
fi
# Expand ~ and $HOME so tmux run-shell commands get an absolute path
data_dir="${data_dir/#\~/$HOME}"

export TMUX_REVIVE_STATE_ROOT="$data_dir"
tmux set-environment -g TMUX_REVIVE_STATE_ROOT "$data_dir"

# Migrate from legacy ~/.tmux/tmp/sessions if it exists and new dir is empty
_legacy_dir="$HOME/.tmux/tmp/sessions"
if [ -d "$_legacy_dir" ] && [ "$data_dir" != "$_legacy_dir" ] && [ ! -d "$data_dir/snapshots" ]; then
  if [ -d "$_legacy_dir/snapshots" ] || [ -d "$_legacy_dir/templates" ]; then
    mkdir -p "$data_dir"
    cp -a "$_legacy_dir"/. "$data_dir"/ 2>/dev/null || true
    tmux display-message "tmux-revive: migrated data from $_legacy_dir → $data_dir" 2>/dev/null || true
  fi
fi
unset _legacy_dir

# Env prefix for all run-shell invocations
_E="TMUX_REVIVE_SOCKET_PATH=#{socket_path} TMUX_REVIVE_STATE_ROOT='$data_dir'"

# ---------------------------------------------------------------------------
# Register keybindings
# ---------------------------------------------------------------------------

# Manual save & restore
tmux bind-key "$save_key" run-shell -b \
  "$_E '$CURRENT_DIR/save-state.sh' --reason manual"
tmux bind-key "$restore_key" run-shell -b \
  "$_E '$CURRENT_DIR/restore-state.sh' --latest --yes"

# Manage mode key table
tmux bind-key "$manage_key" switch-client -T revive

tmux bind-key -T revive m display-popup -E -w 80% -h 70% \
  "$_E '$CURRENT_DIR/pick.sh'"
tmux bind-key -T revive t choose-tree -Zw
tmux bind-key -T revive r display-popup -E -w 80% -h 70% \
  "$_E '$CURRENT_DIR/pick.sh'"
tmux bind-key -T revive b display-popup -E -w 80% -h 70% \
  "$_E '$CURRENT_DIR/pick.sh' --show-snapshots"
tmux bind-key -T revive l run-shell \
  "$_E '$CURRENT_DIR/set-session-label.sh'"
tmux bind-key -T revive s run-shell -b \
  "$_E '$CURRENT_DIR/save-state.sh' --reason manage-mode"
tmux bind-key -T revive R run-shell -b \
  "$_E '$CURRENT_DIR/restore-state.sh' --latest --yes"
tmux bind-key -T revive q switch-client -T root
tmux bind-key -T revive Escape switch-client -T root

tmux bind-key -T revive '?' display-menu -T "tmux-revive" \
  "Revive picker"        m "display-popup -E -w 80% -h 70% '$_E $CURRENT_DIR/pick.sh'" \
  "Tree chooser"          t "choose-tree -Zw" \
  "Browse snapshots"      b "display-popup -E -w 80% -h 70% '$_E $CURRENT_DIR/pick.sh --show-snapshots'" \
  "Set session label"     l "run-shell '$_E $CURRENT_DIR/set-session-label.sh'" \
  "Save"                  s "run-shell -b '$_E $CURRENT_DIR/save-state.sh --reason manage-mode'" \
  "Restore latest"        R "run-shell -b '$_E $CURRENT_DIR/restore-state.sh --latest --yes'" \
  "" \
  "Close"                 q ""

# ---------------------------------------------------------------------------
# Hooks
# ---------------------------------------------------------------------------

tmux set-hook -g client-attached \
  "run-shell -b '$_E \"$CURRENT_DIR/maybe-show-startup-popup.sh\" #{client_tty}'"

tmux set-hook -g after-new-session[0] \
  "run-shell '$CURRENT_DIR/fill-session-gap.sh #{q:session_id}'"

tmux set-hook -g after-new-session[1] \
  "run-shell -b '$_E \"$CURRENT_DIR/maybe-show-startup-popup.sh\" --context new-session --session-target #{q:session_id} --client-tty #{client_tty}'"

tmux set-hook -g client-detached \
  "run-shell -b '$_E \"$CURRENT_DIR/save-state.sh\" --auto --reason client-detached'"

tmux set-hook -g session-closed \
  "run-shell -b '$_E \"$CURRENT_DIR/save-state.sh\" --auto --reason session-closed'"

# ---------------------------------------------------------------------------
# Autosave timer
# ---------------------------------------------------------------------------

if [ "$autosave" = "on" ]; then
  "$CURRENT_DIR/autosave-timer-init.sh" "#{socket_path}" &
fi

# ---------------------------------------------------------------------------
# Store plugin metadata for other tools to reference
# ---------------------------------------------------------------------------

tmux set-option -gq "@tmux-revive-script-dir" "$CURRENT_DIR"
tmux set-option -gq "@tmux-revive-data-dir" "$data_dir"
