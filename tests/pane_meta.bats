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

@test "pane-meta subcommands" {
  tmux new-session -d -s work
  local pane_id
  pane_id="$(tmux display-message -p -t work '#{pane_id}')"

  # show on empty pane should return {}
  local show_output
  show_output="$("$pane_meta" show "$pane_id")"
  assert_eq "{}" "$show_output" "show returns empty object for fresh pane"

  # exclude-transcript on/off/status
  "$pane_meta" exclude-transcript on "$pane_id"
  local status_output
  status_output="$("$pane_meta" exclude-transcript status "$pane_id")"
  assert_eq "true" "$status_output" "exclude-transcript status is true after on"

  "$pane_meta" exclude-transcript off "$pane_id"
  status_output="$("$pane_meta" exclude-transcript status "$pane_id")"
  assert_eq "false" "$status_output" "exclude-transcript status is false after off"

  # set-command-preview sets the preview and strategy
  "$pane_meta" set-command-preview "tail -f /var/log/syslog" "$pane_id"
  show_output="$("$pane_meta" show "$pane_id")"
  local preview strategy
  preview="$(printf '%s' "$show_output" | jq -r '.command_preview // ""')"
  strategy="$(printf '%s' "$show_output" | jq -r '.restore_strategy_override // ""')"
  assert_eq "tail -f /var/log/syslog" "$preview" "set-command-preview stores preview"
  assert_eq "manual-command" "$strategy" "set-command-preview sets strategy to manual-command"

  # clear-command-preview removes it and clears manual-command strategy
  "$pane_meta" clear-command-preview "$pane_id"
  show_output="$("$pane_meta" show "$pane_id")"
  preview="$(printf '%s' "$show_output" | jq -r '.command_preview // ""')"
  strategy="$(printf '%s' "$show_output" | jq -r '.restore_strategy_override // ""')"
  assert_eq "" "$preview" "clear-command-preview removes preview"
  assert_eq "" "$strategy" "clear-command-preview clears manual-command strategy"

  # set-restart-command sets command and strategy
  "$pane_meta" set-restart-command "python server.py" "$pane_id"
  show_output="$("$pane_meta" show "$pane_id")"
  local restart_cmd
  restart_cmd="$(printf '%s' "$show_output" | jq -r '.restart_command // ""')"
  strategy="$(printf '%s' "$show_output" | jq -r '.restore_strategy_override // ""')"
  assert_eq "python server.py" "$restart_cmd" "set-restart-command stores command"
  assert_eq "restart-command" "$strategy" "set-restart-command sets strategy"

  # clear-restart-command removes it
  "$pane_meta" clear-restart-command "$pane_id"
  show_output="$("$pane_meta" show "$pane_id")"
  restart_cmd="$(printf '%s' "$show_output" | jq -r '.restart_command // ""')"
  strategy="$(printf '%s' "$show_output" | jq -r '.restore_strategy_override // ""')"
  assert_eq "" "$restart_cmd" "clear-restart-command removes command"
  assert_eq "" "$strategy" "clear-restart-command clears restart-command strategy"

  # strategy command
  "$pane_meta" strategy shell "$pane_id"
  show_output="$("$pane_meta" show "$pane_id")"
  strategy="$(printf '%s' "$show_output" | jq -r '.restore_strategy_override // ""')"
  assert_eq "shell" "$strategy" "strategy sets override to shell"

  "$pane_meta" strategy auto "$pane_id"
  show_output="$("$pane_meta" show "$pane_id")"
  strategy="$(printf '%s' "$show_output" | jq -r '.restore_strategy_override // ""')"
  assert_eq "" "$strategy" "strategy auto removes override"
}

@test "pane-meta persists through save" {
  tmux new-session -d -s work
  local pane_id
  pane_id="$(tmux display-message -p -t work '#{pane_id}')"

  # Set restart command on a pane
  "$pane_meta" set-restart-command "make serve" "$pane_id"

  # Save and check the manifest captures the override
  "$save_state" --reason meta-test
  local manifest
  manifest="$(latest_manifest)"
  local saved_strategy
  saved_strategy="$(jq -r '.sessions[0].windows[0].panes[0].restore_strategy_override // ""' "$manifest")"
  assert_eq "restart-command" "$saved_strategy" "pane meta strategy persisted in manifest"

  local saved_restart
  saved_restart="$(jq -r '.sessions[0].windows[0].panes[0].restart_command // ""' "$manifest")"
  assert_eq "make serve" "$saved_restart" "pane meta restart command persisted in manifest"
}
