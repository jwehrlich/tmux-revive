# Common setup for all bats test files.
# Usage: load test_helper/common-setup

_common_setup() {
  repo_root="$(cd "$(dirname "${BATS_TEST_FILENAME}")/.." && pwd)"
  tmux_revive_dir="$repo_root"
  save_state="$tmux_revive_dir/save-state.sh"
  restore_state="$tmux_revive_dir/restore-state.sh"
  startup_restore="$tmux_revive_dir/maybe-show-startup-popup.sh"
  startup_popup="$tmux_revive_dir/startup-restore-popup.sh"
  autosave_tick="$tmux_revive_dir/autosave-tick.sh"
  pane_meta="$tmux_revive_dir/pane-meta.sh"
  choose_snapshot="$tmux_revive_dir/choose-snapshot.sh"
  choose_saved_session="$tmux_revive_dir/choose-saved-session.sh"
  resume_session="$tmux_revive_dir/resume-session.sh"
  prune_snapshots="$tmux_revive_dir/prune-snapshots.sh"
  export_snapshot="$tmux_revive_dir/export-snapshot.sh"
  import_snapshot="$tmux_revive_dir/import-snapshot.sh"
  archive_session="$tmux_revive_dir/archive-session.sh"
  migrate_script="$tmux_revive_dir/migrate-snapshots.sh"

  # Clean server isolation state before sourcing state-common.sh to prevent
  # leakage between tests (e.g. TMUX_REVIVE_TMUX_SERVER from server_flag.bats
  # contaminating save.bats). Also remove the tmux() wrapper function that
  # state-common.sh may have defined in a prior test.
  unset TMUX_REVIVE_TMUX_SERVER
  unset TMUX_REVIVE_SOCKET_PATH
  unset TMUX
  unset -f tmux 2>/dev/null || true

  # shellcheck source=../../lib/state-common.sh
  source "$tmux_revive_dir/lib/state-common.sh"

  real_tmux="$(command -v tmux)"
  real_nvim="$(command -v nvim)"
  original_path="$PATH"
  test_base="${TMUX_REVIVE_TEST_BASE:-$repo_root/.tmp/tmux-revive-tests}"
  host_name="$(hostname -s 2>/dev/null || hostname)"
  mkdir -p "$test_base"
}

_setup_case() {
  # Derive a unique case name from the bats test name
  local name
  name="$(printf '%s' "$BATS_TEST_DESCRIPTION" | tr ' ' '-' | tr '[:upper:]' '[:lower:]' | tr -cd 'a-z0-9_-')"

  # Kill previous tmux server if any
  if [ -n "${socket_name:-}" ]; then
    "$real_tmux" -L "$socket_name" kill-server >/dev/null 2>&1 || true
  fi

  # Unique socket: combines filename and test number for parallel safety
  local file_base="${BATS_TEST_FILENAME##*/}"
  file_base="${file_base%.bats}"
  socket_name="bats-${file_base}-${BATS_TEST_NUMBER}"

  case_root="$test_base/$name"

  "$real_tmux" -L "$socket_name" kill-server >/dev/null 2>&1 || true

  if command -v pgrep >/dev/null 2>&1; then
    while IFS= read -r stale_pid; do
      [ -n "$stale_pid" ] || continue
      kill "$stale_pid" >/dev/null 2>&1 || true
      sleep 0.1
      kill -9 "$stale_pid" >/dev/null 2>&1 || true
    done < <(pgrep -f "$case_root" || true)
  fi

  rm -rf "$case_root"
  mkdir -p "$case_root/bin"

  export TMUX_REVIVE_STATE_ROOT="$case_root/state"
  export TMUX_SEND_TO_NVIM_STATE_DIR="$TMUX_REVIVE_STATE_ROOT/registry"
  export XDG_STATE_HOME="$case_root/xdg-state"
  export XDG_DATA_HOME="$case_root/xdg-data"
  export TMUX_TEST_ATTACH_LOG="$case_root/attach.log"
  export TMUX_TEST_SWITCH_LOG="$case_root/switch.log"
  export TMUX_TEST_DISPLAY_POPUP_LOG="$case_root/display-popup.log"
  export TMUX_TEST_COMMAND_LOG="$case_root/tmux-command.log"
  export TMUX_TEST_NVIM_RESTORE_LOG="$case_root/restored-nvim.txt"
  export PATH="$case_root/bin:$original_path"
  unset TMUX_REVIVE_PROFILE_DIR
  unset TMUX_REVIVE_DEFAULT_PROFILE
  unset TMUX_REVIVE_TMUX_SERVER
  unset TMUX_REVIVE_SOCKET_PATH
  unset -f tmux 2>/dev/null || true
  hash -r
  unset TMUX

  _create_tmux_wrapper
  _create_nvim_wrapper

  # Start server and apply global options. start-server may exit immediately
  # without sessions, so retry the set-option calls to handle the race.
  tmux start-server >/dev/null 2>&1 || true
  tmux set-option -g base-index 1 >/dev/null 2>&1 || true
  tmux setw -g pane-base-index 1 >/dev/null 2>&1 || true
  tmux set-option -g renumber-windows on >/dev/null 2>&1 || true
  tmux set-window-option -g automatic-rename on >/dev/null 2>&1 || true
}

_teardown_case() {
  if [ -n "${socket_name:-}" ]; then
    "$real_tmux" -L "$socket_name" kill-server >/dev/null 2>&1 || true
  fi
}
