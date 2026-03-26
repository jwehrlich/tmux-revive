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

@test "server flag save and restore round-trip" {
  setup_server_flag_wrapper

  tmux new-session -d -s mywork
  "$save_state" --server "$socket_name" --reason server-flag-test

  # Verify snapshot landed in the server-specific subdirectory
  server_snapshots_root="$TMUX_REVIVE_STATE_ROOT/snapshots/$host_name/$socket_name"
  [ -d "$server_snapshots_root" ] || fail "server-flag: server-specific snapshot dir not created"
  latest_path="$server_snapshots_root/latest.json"
  [ -f "$latest_path" ] || fail "server-flag: latest.json not found in server subdir"

  manifest="$(jq -r '.manifest_path' "$latest_path")"
  [ -f "$manifest" ] || fail "server-flag: manifest not found at $manifest"
  saved_name="$(jq -r '.sessions[0].session_name' "$manifest")"
  assert_eq "mywork" "$saved_name" "server-flag saved session name"

  # Now kill the server and restore with --server
  tmux kill-server
  tmux new-session -d  # default session "0"

  "$restore_state" --server "$socket_name" --yes

  tmux has-session -t mywork 2>/dev/null || fail "server-flag: restored session mywork not found"
}

@test "server flag path isolation between different servers" {
  setup_server_flag_wrapper

  alt_server="tmux-revive-path-isolation-alt"
  "$real_tmux" -L "$alt_server" kill-server >/dev/null 2>&1 || true

  # Save from server A (the test server)
  tmux new-session -d -s work
  "$save_state" --server "$socket_name" --reason isolation-a

  server_a_latest="$TMUX_REVIVE_STATE_ROOT/snapshots/$host_name/$socket_name/latest.json"
  [ -f "$server_a_latest" ] || fail "path-isolation: server-a latest.json not created"
  server_a_manifest="$(jq -r '.manifest_path' "$server_a_latest")"

  # Start a second tmux server with a session of the same name
  "$real_tmux" -L "$alt_server" new-session -d -s work
  "$save_state" --server "$alt_server" --reason isolation-b

  server_b_latest="$TMUX_REVIVE_STATE_ROOT/snapshots/$host_name/$alt_server/latest.json"
  [ -f "$server_b_latest" ] || fail "path-isolation: server-b latest.json not created"
  server_b_manifest="$(jq -r '.manifest_path' "$server_b_latest")"

  # Both should exist independently
  [ -f "$server_a_manifest" ] || fail "path-isolation: server-a manifest was overwritten"
  [ -f "$server_b_manifest" ] || fail "path-isolation: server-b manifest missing"

  # Manifests should be in different directories
  server_a_dir="$(dirname "$server_a_manifest")"
  server_b_dir="$(dirname "$server_b_manifest")"
  if [ "$server_a_dir" = "$server_b_dir" ]; then
    fail "path-isolation: both manifests are in the same directory"
  fi

  # Session GUIDs should differ (different server instances)
  server_a_guid="$(jq -r '.sessions[0].session_guid' "$server_a_manifest")"
  server_b_guid="$(jq -r '.sessions[0].session_guid' "$server_b_manifest")"
  if [ "$server_a_guid" = "$server_b_guid" ]; then
    fail "path-isolation: both servers produced the same session GUID"
  fi

  "$real_tmux" -L "$alt_server" kill-server >/dev/null 2>&1 || true
}
