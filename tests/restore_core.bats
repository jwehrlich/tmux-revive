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

@test "restore by guid" {
  tmux new-session -d -s work
  "$save_state" --reason test-guid
  local manifest guid
  manifest="$(latest_manifest)"
  guid="$(session_guid_for "$manifest" "work")"
  [ -n "$guid" ] || fail "missing session guid in manifest"

  tmux kill-server
  "$restore_state" --session-guid "$guid" --yes >/dev/null

  wait_for_session work || fail "work session did not restore by guid"
  local restored_guid
  restored_guid="$(tmux show-options -qv -t work @tmux-revive-session-guid)"
  assert_eq "$guid" "$restored_guid" "restored guid"
}

@test "restore by session name" {
  tmux new-session -d -s work
  "$save_state" --reason test-name

  tmux kill-server
  rm -f "$TMUX_TEST_SWITCH_LOG"
  "$restore_state" --session-name work --yes >/dev/null

  wait_for_session work || fail "work session did not restore by session name"
  [ ! -f "$TMUX_TEST_SWITCH_LOG" ] || fail "restore-by-session-name switched a tmux client unexpectedly"
}

@test "restore by session name falls back to older snapshot" {
  tmux new-session -d -s work
  tmux send-keys -t work "printf 'work-snapshot\n'" C-m
  sleep 1
  "$save_state" --reason original-work
  local original_manifest
  original_manifest="$(latest_manifest)"
  [ -f "$original_manifest" ] || fail "original work manifest missing"

  tmux kill-session -t work
  tmux new-session -d -s bootstrap
  sleep 1
  "$save_state" --auto --reason autosave-tick >/dev/null

  local newer_manifest newer_sessions
  newer_manifest="$(latest_manifest)"
  [ -f "$newer_manifest" ] || fail "newer bootstrap manifest missing"
  [ "$newer_manifest" != "$original_manifest" ] || fail "latest manifest did not advance to newer snapshot"
  newer_sessions="$(jq -r '.sessions[].session_name' "$newer_manifest")"
  assert_not_contains "$newer_sessions" "work" "newer latest snapshot should not contain work"
  [ -f "$original_manifest" ] || fail "original work manifest disappeared before restore"

  rm -f "$TMUX_TEST_ATTACH_LOG" "$TMUX_TEST_SWITCH_LOG"
  "$restore_state" --session-name work --attach --yes >/dev/null

  wait_for_session work || fail "work session did not restore from older snapshot fallback"
  wait_for_file "$TMUX_TEST_ATTACH_LOG" || fail "attach log missing for older snapshot fallback restore"
  local attach_cmd
  attach_cmd="$(cat "$TMUX_TEST_ATTACH_LOG")"
  assert_contains "$attach_cmd" "attach-session -t =work" "older snapshot fallback attach target"
}

@test "mixed collision restore" {
  tmux new-session -d -s alpha
  tmux new-session -d -s beta
  "$save_state" --reason test-collision

  tmux kill-server
  tmux new-session -d -s beta

  local output
  output="$("$restore_state" --yes 2>&1)"
  wait_for_session alpha || fail "alpha session did not restore during collision test"
  wait_for_session beta || fail "beta session missing during collision test"

  assert_contains "$output" "skipped" "collision summary"
  assert_contains "$output" "beta" "collision session name in summary"
}

@test "partial snapshot restore with existing session" {
  tmux new-session -d -s alpha
  tmux split-window -d -t alpha
  tmux new-window -d -t alpha: -n "alpha-logs"

  tmux new-session -d -s beta
  tmux new-window -d -t beta: -n "beta-extra"

  tmux new-session -d -s gamma
  tmux split-window -d -t gamma

  "$save_state" --reason test-partial-snapshot-restore

  tmux kill-server

  tmux new-session -d -s beta
  local beta_live_summary_before
  beta_live_summary_before="$(tmux list-windows -t beta -F '#{window_index}:#{window_panes}:#{window_name}')"

  local output
  output="$("$restore_state" --yes 2>&1)"

  wait_for_session alpha || fail "alpha session did not restore during partial snapshot test"
  wait_for_session beta || fail "beta session missing during partial snapshot test"
  wait_for_session gamma || fail "gamma session did not restore during partial snapshot test"

  local alpha_summary beta_live_summary_after gamma_summary session_count
  alpha_summary="$(tmux list-windows -t alpha -F '#{window_index}:#{window_panes}:#{window_name}')"
  beta_live_summary_after="$(tmux list-windows -t beta -F '#{window_index}:#{window_panes}:#{window_name}')"
  gamma_summary="$(tmux list-windows -t gamma -F '#{window_index}:#{window_panes}:#{window_name}')"
  session_count="$(tmux list-sessions | wc -l | tr -d ' ')"

  assert_contains "$output" "restored 2 session(s)" "partial restore restored-count summary"
  assert_contains "$output" "skipped" "partial restore skip summary"
  assert_contains "$output" "beta" "partial restore skipped session name"
  assert_eq "$beta_live_summary_before" "$beta_live_summary_after" "existing beta session remained unchanged"
  assert_contains "$alpha_summary" ":2:" "alpha restored pane count"
  assert_contains "$alpha_summary" "alpha-logs" "alpha second window restored"
  assert_contains "$gamma_summary" ":2:" "gamma pane count restored"
  assert_eq "3" "$session_count" "partial restore session count"
}

@test "restore is idempotent" {
  tmux new-session -d -s work
  local session_target first_pane
  session_target="$(tmux list-sessions -F '#{session_id}' | head -n 1)"
  first_pane="$(tmux list-panes -t work -F '#{pane_id}' | head -n 1)"
  tmux split-window -d -t "$first_pane"
  local pane_one pane_two logs_window_target logs_pane
  pane_one="$(nth_pane_id work 1)"
  pane_two="$(nth_pane_id work 2)"
  logs_window_target="$(tmux new-window -d -P -F '#{window_id}' -t "${session_target}:" -n "logs")"
  logs_pane="$(tmux list-panes -t "$logs_window_target" -F '#{pane_id}' | head -n 1)"
  tmux send-keys -t "$pane_one" 'printf "pane-one\n"' C-m
  tmux send-keys -t "$pane_two" 'printf "pane-two\n"' C-m
  tmux send-keys -t "$logs_pane" 'printf "window-two\n"' C-m
  sleep 1
  "$save_state" --reason test-idempotent-restore

  tmux kill-server
  "$restore_state" --session-name work --yes >/dev/null

  # Disable automatic-rename so window names stay stable between captures
  tmux set-option -g automatic-rename off

  local first_window_summary second_restore_output second_window_summary
  first_window_summary="$(tmux list-windows -t work -F '#{window_index}:#{window_panes}:#{window_name}')"
  second_restore_output="$("$restore_state" --session-name work --yes 2>&1)"
  second_window_summary="$(tmux list-windows -t work -F '#{window_index}:#{window_panes}:#{window_name}')"

  assert_contains "$second_restore_output" "restored 0 session(s)" "idempotent restore summary"
  assert_contains "$second_restore_output" "skipped existing sessions" "idempotent restore skip notice"
  assert_eq "$first_window_summary" "$second_window_summary" "idempotent restore window summary"
}

@test "attach" {
  tmux new-session -d -s work
  "$save_state" --reason test-attach

  tmux kill-server
  rm -f "$TMUX_TEST_ATTACH_LOG"
  rm -f "$TMUX_TEST_SWITCH_LOG"
  "$restore_state" --session-name work --attach --yes >/dev/null

  wait_for_file "$TMUX_TEST_ATTACH_LOG" || fail "attach log was not created"
  local attach_cmd
  attach_cmd="$(cat "$TMUX_TEST_ATTACH_LOG")"
  assert_contains "$attach_cmd" "attach-session -t =work" "attach target"
  [ ! -f "$TMUX_TEST_SWITCH_LOG" ] || fail "attach restore switched another tmux client unexpectedly"
}

@test "grouped sessions are restored" {
  tmux new-session -d -s base
  tmux new-session -d -t base -s grouped
  "$save_state" --reason grouped-session-test

  tmux kill-server
  local output
  output="$("$restore_state" --yes 2>&1 || true)"

  if ! tmux has-session -t base 2>/dev/null; then
    fail "base session was not restored"
  fi
  if ! tmux has-session -t grouped 2>/dev/null; then
    fail "grouped session was not restored"
  fi
  # Verify grouped session shares windows with base
  local base_windows grouped_windows
  base_windows="$(tmux list-windows -t base -F '#{window_id}' | sort)"
  grouped_windows="$(tmux list-windows -t grouped -F '#{window_id}' | sort)"
  if [ "$base_windows" != "$grouped_windows" ]; then
    fail "grouped session does not share windows with base (base: $base_windows, grouped: $grouped_windows)"
  fi
}
