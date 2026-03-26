setup() {
  load test_helper/common-setup
  load test_helper/assertions
  load test_helper/wait-helpers
  load test_helper/data-helpers
  load test_helper/fake-wrappers
  load test_helper/shell-env-helpers
  _common_setup
  _setup_case
}

teardown() {
  _teardown_case
}

@test "special character session names survive save and restore" {
  # Session names with spaces, dashes, underscores
  tmux new-session -d -s "my work"
  tmux new-session -d -s "dev-server_v2"
  "$save_state" --reason special-char-test

  manifest="$(latest_manifest)"
  [ -f "$manifest" ] || fail "special char manifest missing"

  # Verify session names are preserved in manifest
  saved_names="$(jq -r '.sessions[].session_name' "$manifest")"
  assert_contains "$saved_names" "my work" "space in session name preserved"
  assert_contains "$saved_names" "dev-server_v2" "dash-underscore in session name preserved"

  tmux kill-server
  "$restore_state" --yes >/dev/null 2>&1 || true

  wait_for_session "my work" || fail "session with space did not restore"
  wait_for_session "dev-server_v2" || fail "session with dash-underscore did not restore"
}

@test "pane title with special chars survives save and restore" {
  tmux new-session -d -s work
  tmux select-pane -t work -T 'title with "quotes" & $dollars'
  "$save_state" --reason pane-title-test

  manifest="$(latest_manifest)"
  saved_title="$(jq -r '.sessions[0].windows[0].panes[0].pane_title' "$manifest")"
  assert_contains "$saved_title" '"quotes"' "quotes in pane title preserved"
  assert_contains "$saved_title" '$dollars' "dollar in pane title preserved"

  tmux kill-server
  "$restore_state" --yes >/dev/null 2>&1 || true
  wait_for_session work || fail "session did not restore with special pane title"
}

@test "non-bash non-zsh shell pane restores with correct cwd" {
  # Create a session with a pane running /bin/sh
  tmux new-session -d -s shtest
  test_dir="$case_root/sh-workdir"
  mkdir -p "$test_dir"

  # Build a manifest with /bin/sh as the shell
  "$save_state" --reason sh-test
  manifest="$(latest_manifest)"

  # Patch the manifest to use /bin/sh instead of the real shell
  tmp_manifest="$manifest.tmp"
  jq '(.sessions[0].windows[0].panes[0].shell) = "/bin/sh"' "$manifest" >"$tmp_manifest"
  mv "$tmp_manifest" "$manifest"

  # Also set the cwd to our test directory
  tmp_manifest="$manifest.tmp"
  jq --arg d "$test_dir" '(.sessions[0].windows[0].panes[0].cwd) = $d' "$manifest" >"$tmp_manifest"
  mv "$tmp_manifest" "$manifest"

  tmux kill-session -t shtest

  # Restore
  "$restore_state" --manifest "$manifest"
  tmux has-session -t shtest 2>/dev/null || fail "session shtest was not restored"

  # Verify the pane exists and has the correct cwd
  attempts=0
  restored_cwd=""
  while [ "$attempts" -lt 30 ]; do
    restored_cwd="$(tmux display-message -t shtest -p '#{pane_current_path}' 2>/dev/null || true)"
    [ -n "$restored_cwd" ] && break
    sleep 0.2
    attempts=$((attempts + 1))
  done
  assert_eq "$test_dir" "$restored_cwd" "non-bash/zsh shell pane cwd"
}

@test "restored zsh uses shared history file" {
  if ! command -v zsh >/dev/null 2>&1; then
    skip "zsh not installed"
  fi

  zdotdir="$case_root/zdotdir"
  history_probe="$case_root/history-probe.txt"
  save_test_shell_env
  setup_test_zsh_env "$zdotdir" ': 1700000000:0;echo from-restored-history'

  tmux new-session -d -s work
  pane_id="$(tmux list-panes -t work -F '#{pane_id}' | head -n 1)"
  tmux send-keys -t "$pane_id" 'printf "history context\n"' C-m
  sleep 1
  "$save_state" --reason test-restored-zsh-history

  tmux kill-server
  "$restore_state" --session-name work --yes >/dev/null

  restored_pane="$(tmux list-panes -t work -F '#{pane_id}' | head -n 1)"
  tmux send-keys -t "$restored_pane" "fc -ln 1 | grep -F 'echo from-restored-history' > $(printf '%q' "$history_probe")" C-m
  wait_for_file "$history_probe" 60 0.25 || fail "restored zsh did not expose shared history file"
  assert_contains "$(cat "$history_probe")" "echo from-restored-history" "restored zsh history content"

  restore_test_shell_env
}

@test "migrate-snapshots injects GUIDs and is idempotent" {
  snapshots_root="$TMUX_REVIVE_STATE_ROOT/snapshots/$host_name"

  tmux new-session -d -s work

  # Create a pre-GUID manifest (sessions without session_guid)
  snapshot_dir="$snapshots_root/2024-01-01T00-00-00Z"
  mkdir -p "$snapshot_dir"
  jq -n '{
    snapshot_version: "1",
    created_at: "2024-01-01T00:00:00Z",
    created_at_epoch: 1704067200,
    sessions: [
      { session_name: "alpha", tmux_session_name: "alpha", windows: [] },
      { session_name: "beta", tmux_session_name: "beta", session_guid: "existing-guid", windows: [] }
    ]
  }' >"$snapshot_dir/manifest.json"

  # Create a second snapshot that already has all GUIDs
  snapshot_dir2="$snapshots_root/2024-01-02T00-00-00Z"
  mkdir -p "$snapshot_dir2"
  jq -n '{
    snapshot_version: "1",
    created_at: "2024-01-02T00:00:00Z",
    created_at_epoch: 1704153600,
    sessions: [
      { session_name: "gamma", session_guid: "gamma-guid", windows: [] }
    ]
  }' >"$snapshot_dir2/manifest.json"

  # Dry-run should report without modifying
  dry_output="$("$migrate_script" --dry-run 2>&1)"
  assert_contains "$dry_output" "would migrate" "dry-run reports migration needed"
  assert_contains "$dry_output" "1 migrated" "dry-run counts one manifest"
  # Verify manifest was NOT modified
  alpha_guid="$(jq -r '.sessions[0].session_guid // ""' "$snapshot_dir/manifest.json")"
  assert_eq "" "$alpha_guid" "dry-run did not inject GUID"

  # Actual migration
  migrate_output="$("$migrate_script" --verbose 2>&1)"
  assert_contains "$migrate_output" "1 migrated" "migration migrated one manifest"
  assert_contains "$migrate_output" "1 skipped" "migration skipped already-migrated manifest"
  assert_contains "$migrate_output" "0 errors" "migration had no errors"

  # Verify GUIDs injected correctly
  alpha_guid="$(jq -r '.sessions[0].session_guid // ""' "$snapshot_dir/manifest.json")"
  beta_guid="$(jq -r '.sessions[1].session_guid // ""' "$snapshot_dir/manifest.json")"
  [ -n "$alpha_guid" ] || fail "migration did not inject GUID for alpha"
  assert_eq "existing-guid" "$beta_guid" "migration preserved existing GUID for beta"

  # Idempotency: running again should skip everything
  idempotent_output="$("$migrate_script" 2>&1)"
  assert_contains "$idempotent_output" "0 migrated" "idempotent run migrated nothing"
  assert_contains "$idempotent_output" "2 skipped" "idempotent run skipped all"

  # Verify GUID didn't change on second run
  alpha_guid_2="$(jq -r '.sessions[0].session_guid // ""' "$snapshot_dir/manifest.json")"
  assert_eq "$alpha_guid" "$alpha_guid_2" "GUID stable across idempotent runs"

  # Error recovery: corrupt a manifest — jq parse failure treated as skip
  printf 'not json' >"$snapshot_dir2/manifest.json"
  error_output="$("$migrate_script" 2>&1)"
  assert_contains "$error_output" "0 errors" "corrupt manifest did not cause error count"
}
