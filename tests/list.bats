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

@test "list saved sessions" {
  tmux new-session -d -s alpha
  tmux new-session -d -s beta
  "$save_state" --reason test-list

  output="$("$restore_state" --list)"
  line_count="$(printf '%s\n' "$output" | awk 'NF > 0 { count++ } END { print count + 0 }')"

  assert_contains "$output" "SESSION_GUID" "list header guid"
  assert_contains "$output" "SESSION_NAME" "list header name"
  assert_contains "$output" "LAST_UPDATED" "list header timestamp"
  assert_contains "$output" "alpha" "list includes alpha"
  assert_contains "$output" "beta" "list includes beta"
  assert_eq "3" "$line_count" "list line count"
}
