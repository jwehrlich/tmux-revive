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

@test "stale save lock recovery" {
  runtime_dir="$(tmux_revive_runtime_dir)"
  lock_dir="$runtime_dir/save.lock"
  lock_meta="$lock_dir/meta.json"

  tmux new-session -d -s work
  mkdir -p "$lock_dir"
  jq -cn --argjson pid 999999 --argjson started_at 1 '{ pid: $pid, started_at: $started_at }' >"$lock_meta"

  "$save_state" --reason stale-lock-test
  manifest="$(latest_manifest)"
  [ -f "$manifest" ] || fail "save did not recover from stale lock"
}

@test "save lock contention queues followup save" {
  runtime_dir="$(tmux_revive_runtime_dir)"
  lock_dir="$runtime_dir/save.lock"
  lock_meta="$lock_dir/meta.json"
  pending_path="$(tmux_revive_pending_save_path)"

  mkdir -p "$lock_dir"
  jq -cn --argjson pid "$$" --argjson started_at "$(date +%s)" '{ pid: $pid, started_at: $started_at }' >"$lock_meta"

  # Auto saves queue a pending follow-up when lock is held
  "$save_state" --auto --reason contention-test

  [ -f "$pending_path" ] || fail "auto save lock contention did not queue a follow-up save"

  # Manual saves should fail with an error instead of silently succeeding
  rm -f "$pending_path"
  if "$save_state" --reason contention-test-manual 2>/dev/null; then
    fail "manual save should fail when lock is held"
  fi
  [ ! -f "$pending_path" ] || fail "manual save should not queue a pending save"
}

@test "stale lock corrupted metadata" {
  runtime_dir="$(tmux_revive_runtime_dir)"
  lock_dir="$runtime_dir/save.lock"
  lock_meta="$lock_dir/meta.json"

  tmux new-session -d -s work
  mkdir -p "$lock_dir"
  # Write corrupted JSON
  printf '{ broken json <<<\n' >"$lock_meta"

  "$save_state" --reason corrupted-lock-test
  manifest="$(latest_manifest)"
  [ -f "$manifest" ] || fail "save did not recover from corrupted lock metadata"
}

@test "corrupted manifest handling" {
  tmux new-session -d -s work
  "$save_state" --reason corruption-test

  manifest="$(latest_manifest)"
  [ -f "$manifest" ] || fail "manifest missing before corruption"

  # Corrupt the manifest
  printf 'not valid json{{{' >"$manifest"

  output="$("$restore_state" --yes 2>&1 || true)"
  assert_contains "$output" "corrupted or unreadable" "corrupted manifest error message"
}

@test "empty sessions manifest" {
  tmux new-session -d -s work
  "$save_state" --reason empty-test

  manifest="$(latest_manifest)"
  # Replace sessions with empty array
  jq '.sessions = []' "$manifest" >"${manifest}.tmp"
  mv "${manifest}.tmp" "$manifest"

  tmux kill-server
  output="$("$restore_state" --yes 2>&1 || true)"
  assert_contains "$output" "no sessions" "empty sessions manifest message"
}

@test "mkdir error check in save" {
  tmux new-session -d -s work

  # Verify save works normally first
  "$save_state" --reason mkdir-test
  manifest="$(latest_manifest)"
  [ -f "$manifest" ] || fail "normal save failed in mkdir test"

  # Make snapshots directory unwritable to trigger mkdir failure
  snapshots_root="$TMUX_REVIVE_STATE_ROOT/snapshots/$(hostname -s 2>/dev/null || printf 'test')"
  chmod 555 "$snapshots_root" 2>/dev/null || { return 0; }
  if "$save_state" --reason mkdir-error-test 2>/dev/null; then
    chmod 755 "$snapshots_root" 2>/dev/null || true
    fail "save should fail when snapshot directory is unwritable"
  fi
  chmod 755 "$snapshots_root" 2>/dev/null || true
}

@test "hook error logging" {
  tmux new-session -d -s work

  # Set a hook that fails
  tmux set-option -g '@tmux-revive-pre-save-hook' 'exit 1'
  output="$("$save_state" --reason hook-error-test 2>&1 || true)"

  runtime_dir="$(tmux_revive_runtime_dir)"
  hook_log="$runtime_dir/hook-errors.log"
  [ -f "$hook_log" ] || fail "hook error log was not created"
  assert_contains "$(cat "$hook_log")" "hook failed" "hook error log entry"
  # Clean up
  tmux set-option -gu '@tmux-revive-pre-save-hook' 2>/dev/null || true
}

@test "concurrent save and restore" {
  tmux new-session -d -s work
  tmux send-keys -t work 'echo hello' C-m
  sleep 1

  "$save_state" --reason concurrent-base
  tmux kill-server

  # Start restore, then immediately kick off a save in background
  "$restore_state" --session-name work --yes >/dev/null
  wait_for_session work || fail "initial restore did not create work session"

  # Run save in background while server is live
  "$save_state" --reason concurrent-during-restore &
  save_pid=$!

  # Give save a moment, then verify it completes
  wait "$save_pid" || fail "concurrent save failed while restore server was running"

  # Verify both the session and latest snapshot are intact
  tmux has-session -t work 2>/dev/null || fail "work session lost after concurrent save"
  manifest="$(latest_manifest)"
  [ -f "$manifest" ] || fail "no manifest after concurrent save"
  jq -e '.sessions | length > 0' "$manifest" >/dev/null || fail "concurrent save produced empty manifest"
}

@test "pane split failure during restore" {
  # Create a session with 3 panes and save
  tmux new-session -d -s work
  tmux split-window -d -t work
  tmux split-window -d -t work
  actual_panes="$(tmux list-panes -t work | wc -l | tr -d ' ')"
  [ "$actual_panes" -eq 3 ] || fail "expected 3 panes, got $actual_panes"
  "$save_state" --reason pane-split-test
  manifest="$(latest_manifest)"

  # Kill the session
  tmux kill-session -t work

  # Inject a split-window failure hook into the tmux wrapper
  # Replace the wrapper to fail on split-window
  cat >"$case_root/bin/tmux" <<WRAPEOF
#!/usr/bin/env bash
set -euo pipefail
if [ -n "\${TMUX_TEST_COMMAND_LOG:-}" ]; then
  printf '%s\n' "\$*" >>"\$TMUX_TEST_COMMAND_LOG"
fi
if [ "\${1:-}" = "split-window" ] && [ "\${TMUX_TEST_FAIL_SPLIT:-0}" = "1" ]; then
  exit 1
fi
if [ "\${1:-}" = "attach-session" ] && [ -n "\${TMUX_TEST_ATTACH_LOG:-}" ]; then
  printf '%s\n' "\$*" >"\$TMUX_TEST_ATTACH_LOG"
  exit 0
fi
if [ "\${1:-}" = "switch-client" ] && [ -n "\${TMUX_TEST_SWITCH_LOG:-}" ]; then
  printf '%s\n' "\$*" >>"\$TMUX_TEST_SWITCH_LOG"
  exit 0
fi
exec $real_tmux -f /dev/null -L $socket_name "\$@"
WRAPEOF
  chmod +x "$case_root/bin/tmux"

  # Restore with split-window failures enabled
  export TMUX_TEST_FAIL_SPLIT=1
  output="$("$restore_state" --manifest "$manifest" 2>&1 || true)"
  unset TMUX_TEST_FAIL_SPLIT

  # Session should still be created (first pane comes from new-session, not split-window)
  tmux has-session -t work 2>/dev/null || fail "session was not created despite split failures"

  # Should have only 1 pane (splits failed)
  restored_panes="$(tmux list-panes -t work | wc -l | tr -d ' ')"
  [ "$restored_panes" -eq 1 ] || fail "expected 1 pane (splits failed), got $restored_panes"

  # Restore log should mention pane-split-failed and pane-count-mismatch
  restore_log="$(find "$TMUX_REVIVE_STATE_ROOT" -name 'latest-restore.log' | head -1)"
  [ -f "$restore_log" ] || fail "no restore log found"
  log_content="$(cat "$restore_log")"
  assert_contains "$log_content" "pane-split-failed" "split failure logged"
  assert_contains "$log_content" "pane-count-mismatch" "pane count mismatch logged"
}

@test "export import error paths" {
  tmux new-session -d -s work
  "$save_state" --reason export-error-test

  # Test import with nonexistent file
  output="$("$import_snapshot" --bundle /nonexistent/file.tar.gz 2>&1 || true)"
  assert_contains "$output" "bundle not found" "import nonexistent file error"

  # Test export works
  manifest="$(latest_manifest)"
  export_path="$case_root/test-export.tar.gz"
  "$export_snapshot" --manifest "$manifest" --output "$export_path"
  [ -f "$export_path" ] || fail "export did not create archive"

  # Test import roundtrip
  imported_manifest="$("$import_snapshot" --bundle "$export_path")"
  [ -f "$imported_manifest" ] || fail "import did not produce manifest"
}
