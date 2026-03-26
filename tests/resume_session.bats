setup() {
  load test_helper/common-setup
  load test_helper/assertions
  load test_helper/data-helpers
  load test_helper/fake-wrappers
  _common_setup
  _setup_case
}

teardown() {
  _teardown_case
}

@test "resume session by name auto-detection" {
  tmux new-session -d -s work
  "$save_state" --reason resume-test
  tmux kill-session -t work

  "$resume_session" --no-attach --yes work 2>/dev/null || true
  tmux has-session -t "=work" 2>/dev/null || fail "resume by name should restore work session"
}

@test "resume session by GUID" {
  tmux new-session -d -s work
  "$save_state" --reason resume-test
  tmux kill-session -t work

  local manifest
  manifest="$(latest_manifest)"
  local guid
  guid="$(jq -r '.sessions[0].session_guid // ""' "$manifest")"
  [ -n "$guid" ] || fail "manifest should have session GUID"

  "$resume_session" --no-attach --yes "$guid" 2>/dev/null || true
  tmux has-session -t "=work" 2>/dev/null || fail "resume by GUID should restore work session"
}

@test "resume session by legacy id" {
  tmux new-session -d -s work
  "$save_state" --reason resume-test
  tmux kill-session -t work

  local manifest
  manifest="$(latest_manifest)"
  local session_id
  session_id="$(jq -r '.sessions[0].session_id // ""' "$manifest")"
  if [ -z "$session_id" ]; then
    skip "manifest does not contain session_id"
  fi

  "$resume_session" --no-attach --yes --id "$session_id" 2>/dev/null || true
  tmux has-session -t "=work" 2>/dev/null || fail "resume by legacy id should restore work session"
}

@test "resume session --list shows saved sessions" {
  tmux new-session -d -s alpha
  tmux new-session -d -s beta
  "$save_state" --reason resume-list-test

  local list_output
  list_output="$("$resume_session" --list 2>&1)"
  assert_contains "$list_output" "alpha" "resume --list shows alpha"
  assert_contains "$list_output" "beta" "resume --list shows beta"
}
