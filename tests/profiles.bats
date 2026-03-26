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

@test "named restore profile controls preview and CLI flags override profile" {
  mkdir -p "$case_root/profiles"
  export TMUX_REVIVE_PROFILE_DIR="$case_root/profiles"
  cat >"$case_root/profiles/ci.json" <<'EOF'
{
  "name": "ci",
  "attach": true,
  "preview": true,
  "include_archived": false,
  "startup_mode": "prompt"
}
EOF

  tmux new-session -d -s work
  "$save_state" --reason named-profile

  tmux kill-server
  preview_output="$("$restore_state" --profile ci --session-name work --yes)"
  assert_contains "$preview_output" "tmux-revive restore preview" "profile preview enabled by default"
  if tmux has-session -t work 2>/dev/null; then
    fail "profile preview should not restore the session"
  fi

  rm -f "$TMUX_TEST_ATTACH_LOG"
  "$restore_state" --profile ci --session-name work --yes --no-preview --no-attach >/dev/null
  wait_for_session work || fail "profile restore did not restore work session"
  [ ! -f "$TMUX_TEST_ATTACH_LOG" ] || fail "no-attach CLI should override profile attach"
}

@test "default profile controls startup mode to auto-restore" {
  mkdir -p "$case_root/profiles"
  export TMUX_REVIVE_PROFILE_DIR="$case_root/profiles"
  export TMUX_REVIVE_DEFAULT_PROFILE="all"
  cat >"$case_root/profiles/all.json" <<'EOF'
{
  "name": "all",
  "attach": true,
  "preview": false,
  "include_archived": true,
  "startup_mode": "auto"
}
EOF

  tmux new-session -d -s work
  "$save_state" --reason profile-startup-auto

  tmux kill-server
  tmux new-session -d -s bootstrap
  tmux set-option -g @tmux-revive-startup-restore prompt
  "$startup_restore"

  wait_for_session work || fail "default profile startup_mode=auto did not restore work session"
}

@test "profile with include_archived shows archived sessions and hide-archived overrides" {
  mkdir -p "$case_root/profiles"
  export TMUX_REVIVE_PROFILE_DIR="$case_root/profiles"
  cat >"$case_root/profiles/archive-view.json" <<'EOF'
{
  "name": "archive-view",
  "attach": false,
  "preview": false,
  "include_archived": true,
  "startup_mode": "prompt"
}
EOF

  tmux new-session -d -s work
  "$save_state" --reason profile-archived
  manifest="$(latest_manifest)"
  guid="$(jq -r '.sessions[0].session_guid' "$manifest")"
  [ -n "$guid" ] || fail "profile archived test missing guid"
  "$archive_session" --session-guid "$guid" >/dev/null

  hidden_items="$("$choose_saved_session" --manifest "$manifest" --dump-items)"
  [ -z "$hidden_items" ] || fail "archived session should be hidden by default"

  visible_items="$("$choose_saved_session" --manifest "$manifest" --dump-items --profile archive-view)"
  assert_contains "$visible_items" "work" "profile include_archived should show archived session"

  hidden_again="$("$choose_saved_session" --manifest "$manifest" --dump-items --profile archive-view --hide-archived)"
  [ -z "$hidden_again" ] || fail "hide-archived should override profile include_archived"
}
