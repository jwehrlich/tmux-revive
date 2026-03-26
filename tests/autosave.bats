setup() {
  load test_helper/common-setup
  load test_helper/assertions
  load test_helper/wait-helpers
  load test_helper/data-helpers
  load test_helper/fake-wrappers
  _common_setup
  _setup_case
}

teardown() {
  _teardown_case
}

@test "autosave skips save when interval has not elapsed" {
  tmux new-session -d -s work
  runtime_dir="$(tmux_revive_runtime_dir)"
  latest_path="$(tmux_revive_latest_path)"
  mkdir -p "$runtime_dir"

  tmux set-option -g @tmux-revive-autosave on
  tmux set-option -g @tmux-revive-autosave-interval 900
  date +%s >"$runtime_dir/last-auto-save"
  "$autosave_tick"
  [ ! -f "$latest_path" ] || fail "autosave tick ran before interval elapsed"
}

@test "autosave saves when interval has elapsed" {
  tmux new-session -d -s work
  runtime_dir="$(tmux_revive_runtime_dir)"
  latest_path="$(tmux_revive_latest_path)"
  mkdir -p "$runtime_dir"

  tmux set-option -g @tmux-revive-autosave on
  tmux set-option -g @tmux-revive-autosave-interval 900
  printf '0\n' >"$runtime_dir/last-auto-save"
  "$autosave_tick"
  wait_for_file "$latest_path" || fail "autosave tick did not save after interval elapsed"
}

@test "autosave does not save when disabled" {
  tmux new-session -d -s work
  runtime_dir="$(tmux_revive_runtime_dir)"
  latest_path="$(tmux_revive_latest_path)"
  mkdir -p "$runtime_dir"

  printf '0\n' >"$runtime_dir/last-auto-save"
  tmux set-option -g @tmux-revive-autosave off
  "$autosave_tick"
  [ ! -f "$latest_path" ] || fail "autosave tick saved while disabled"
}

@test "statusline save notice uses tmux socket env" {
  tmux new-session -d -s work
  socket_path="$(tmux display-message -p '#{socket_path}')"
  tmux_env="${socket_path},123,0"

  # Save with the same socket context that autosave-tick will use, so the
  # save notice file lands in the server-specific runtime directory.
  # Auto-detection derives server name from socket basename (e.g. bats-autosave-4).
  server_name="$(basename "$socket_path")"
  TMUX_REVIVE_SOCKET_PATH="$socket_path" "$save_state" --reason manual-statusline
  notice_output="$("$autosave_tick" --socket-path "$socket_path")"
  assert_contains "$notice_output" "💾 saved" "statusline manual save notice"

  runtime_dir="$(TMUX_REVIVE_TMUX_SERVER="$server_name" tmux_revive_runtime_dir)"
  latest_path="$(TMUX_REVIVE_TMUX_SERVER="$server_name" tmux_revive_latest_path)"
  last_save_notice_path="$(TMUX_REVIVE_TMUX_SERVER="$server_name" tmux_revive_last_save_notice_path)"
  mkdir -p "$runtime_dir"
  jq '.saved_at = 0' "$last_save_notice_path" >"$last_save_notice_path.tmp"
  mv "$last_save_notice_path.tmp" "$last_save_notice_path"
  printf '0\n' >"$runtime_dir/last-auto-save"
  tmux set-option -gq '@tmux-revive-last-auto-save' '0' 2>/dev/null || true
  "$autosave_tick" --socket-path "$socket_path" >/dev/null
  wait_for_file "$latest_path" || fail "statusline autosave notice test did not produce latest snapshot"
  wait_for_jq_value "$last_save_notice_path" 'select(.status == "done") | .mode // ""' "auto" 60 0.25 || fail "statusline autosave notice test did not record auto save notice"
  auto_notice_output="$("$autosave_tick" --socket-path "$socket_path")"
  assert_contains "$auto_notice_output" "💾 auto-saved" "statusline autosave notice"
}

@test "autosave timer init sets guard and controls tick behavior" {
  local autosave_timer_init="$tmux_revive_dir/autosave-timer-init.sh"
  local autosave_timer_tick="$tmux_revive_dir/autosave-timer-tick.sh"

  tmux new-session -d -s work
  tmux set-option -g @tmux-revive-autosave-interval 5

  # Timer should set the guard option
  "$autosave_timer_init"
  timer_active="$(tmux show-option -gqv '@tmux-revive-timer-active' 2>/dev/null || printf '')"
  assert_eq "1" "$timer_active" "timer-active guard set after init"

  # Running init again should be a no-op (guard prevents duplicate)
  "$autosave_timer_init"
  timer_active="$(tmux show-option -gqv '@tmux-revive-timer-active' 2>/dev/null || printf '')"
  assert_eq "1" "$timer_active" "timer-active guard still set"

  # autosave-tick.sh should skip save trigger when timer is active
  runtime_dir="$(tmux_revive_runtime_dir)"
  latest_path="$(tmux_revive_latest_path)"
  mkdir -p "$runtime_dir"
  printf '0\n' >"$runtime_dir/last-auto-save"
  tmux set-option -g @tmux-revive-autosave on
  tmux set-option -g @tmux-revive-autosave-interval 1
  "$autosave_tick"
  sleep 1
  [ ! -f "$latest_path" ] || fail "autosave-tick should skip save when timer is active"

  # Clear the timer guard — autosave-tick should save again
  tmux set-option -gu '@tmux-revive-timer-active' 2>/dev/null || true
  printf '0\n' >"$runtime_dir/last-auto-save"
  tmux set-option -gq '@tmux-revive-last-auto-save' '0' 2>/dev/null || true
  "$autosave_tick"
  wait_for_file "$latest_path" || fail "autosave-tick should save when timer is not active"
}
