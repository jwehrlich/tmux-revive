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

@test "manual save emits tmux feedback message" {
  tmux new-session -d -s work
  rm -f "$TMUX_TEST_COMMAND_LOG"

  "$save_state" --reason manual-feedback

  wait_for_file "$TMUX_TEST_COMMAND_LOG" || fail "manual save feedback test missing tmux command log"
  command_log="$(cat "$TMUX_TEST_COMMAND_LOG")"
  assert_contains "$command_log" "display-message tmux-revive: saved snapshot" "manual save emits tmux feedback message"
}

@test "bind save key triggers manual save via expect" {
  if ! command -v expect >/dev/null 2>&1; then
    skip "expect not installed"
  fi
  tmux new-session -d -s work
  # The keybinding sets TMUX_REVIVE_SOCKET_PATH=#{socket_path}. Auto-detection
  # in state-common.sh derives the server name from the socket (e.g. bats-save-4).
  # Compute latest_path from the same server context so we check the right file.
  latest_path="$(TMUX_REVIVE_TMUX_SERVER="$socket_name" tmux_revive_latest_path)"
  rm -f "$latest_path" "$TMUX_TEST_COMMAND_LOG"

  tmux bind-key S run-shell -b "TMUX_REVIVE_SOCKET_PATH=#{socket_path} $tmux_revive_dir/save-state.sh --reason manual"
  cat >"$case_root/bind-save.expect" <<EOF
#!/usr/bin/expect -f
set timeout 20
log_user 0
spawn $real_tmux -f /dev/null -L $socket_name attach-session -t work
after 500
send "\002S"
after 1500
send "\002d"
expect eof
EOF
  chmod +x "$case_root/bind-save.expect"
  "$case_root/bind-save.expect"

  wait_for_file "$latest_path" 80 0.25 || fail "bind save key did not create latest snapshot"
  wait_for_file "$TMUX_TEST_COMMAND_LOG" 80 0.25 || fail "bind save key did not emit tmux command log"
  command_log="$(cat "$TMUX_TEST_COMMAND_LOG")"
  assert_contains "$command_log" "display-message tmux-revive: saved snapshot" "bind save key emits tmux feedback message"
}

@test "save and restore hooks fire with correct payloads" {
  pre_save_log="$case_root/pre-save.log"
  post_save_log="$case_root/post-save.log"
  pre_restore_log="$case_root/pre-restore.log"
  post_restore_log="$case_root/post-restore.log"

  tmux new-session -d -s work
  tmux set-option -gq "$(tmux_revive_pre_save_hook_option)" "printf '%s|%s\n' \"\$TMUX_REVIVE_HOOK_EVENT\" \"\$TMUX_REVIVE_HOOK_REASON\" > '$pre_save_log'"
  tmux set-option -gq "$(tmux_revive_post_save_hook_option)" "printf '%s|%s|%s\n' \"\$TMUX_REVIVE_HOOK_EVENT\" \"\$TMUX_REVIVE_HOOK_REASON\" \"\$TMUX_REVIVE_HOOK_MANIFEST_PATH\" > '$post_save_log'"
  export TMUX_REVIVE_PRE_RESTORE_HOOK="printf '%s|%s\n' \"\$TMUX_REVIVE_HOOK_EVENT\" \"\$TMUX_REVIVE_HOOK_SELECTOR_NAME\" > '$pre_restore_log'"
  export TMUX_REVIVE_POST_RESTORE_HOOK="printf '%s|%s|%s\n' \"\$TMUX_REVIVE_HOOK_EVENT\" \"\$TMUX_REVIVE_HOOK_ATTACH_TARGET\" \"\$TMUX_REVIVE_HOOK_RESTORED_COUNT\" > '$post_restore_log'"

  "$save_state" --reason hooks-test
  wait_for_file "$pre_save_log" || fail "pre-save hook did not run"
  wait_for_file "$post_save_log" || fail "post-save hook did not run"
  assert_eq "save|hooks-test" "$(cat "$pre_save_log")" "pre-save hook payload"
  assert_contains "$(cat "$post_save_log")" "save|hooks-test|" "post-save hook payload"

  tmux kill-server
  "$restore_state" --session-name work --yes >/dev/null
  wait_for_file "$pre_restore_log" || fail "pre-restore hook did not run"
  wait_for_file "$post_restore_log" || fail "post-restore hook did not run"
  assert_eq "restore|work" "$(cat "$pre_restore_log")" "pre-restore hook payload"
  assert_eq "restore|work|1" "$(cat "$post_restore_log")" "post-restore hook payload"
  unset TMUX_REVIVE_PRE_RESTORE_HOOK
  unset TMUX_REVIVE_POST_RESTORE_HOOK
}

@test "pane history capture is bounded and restores correctly" {
  output_file="$case_root/large-output.txt"

  tmux new-session -d -s work
  pane_id="$(tmux list-panes -t work -F '#{pane_id}' | head -n 1)"
  for i in $(seq 1 700); do
    printf 'line-%03d\n' "$i" >>"$output_file"
  done
  tmux send-keys -t "$pane_id" "cat $(printf '%q' "$output_file")" C-m
  wait_for_pane_text "$pane_id" "line-700" 60 0.25 || fail "large output did not reach pane before save"

  "$save_state" --reason bounded-history-test
  manifest="$(latest_manifest)"
  history_dump="$(jq -r '.sessions[0].windows[0].panes[0].path_to_history_dump' "$manifest")"
  [ -f "$history_dump" ] || fail "history dump was not written"
  assert_contains "$(cat "$history_dump")" "line-700" "saved history includes newest line"
  assert_not_contains "$(cat "$history_dump")" "line-001" "saved history excludes oldest line beyond bound"

  tmux kill-server
  "$restore_state" --session-name work --yes >/dev/null

  restored_pane="$(tmux list-panes -t work -F '#{pane_id}' | head -n 1)"
  wait_for_pane_text "$restored_pane" "line-700" 60 0.25 || fail "restored pane missing newest bounded history line"
  capture="$(tmux capture-pane -p -S -520 -t "$restored_pane")"
  assert_contains "$capture" "line-700" "restored pane includes newest line"
  assert_contains "$capture" "line-250" "restored pane includes bounded middle line"
  assert_not_contains "$capture" "line-001" "restored pane excludes oldest line beyond bound"
}

@test "restore preview shows summary of sessions to restore and skip" {
  tmux new-session -d -s alpha
  tmux new-session -d -s gamma
  tmux new-session -d -s base
  tmux new-session -d -t base -s grouped
  "$save_state" --reason preview-summary
  manifest="$(latest_manifest)"

  tmux kill-server
  tmux new-session -d -s alpha

  output="$("$restore_state" --manifest "$manifest" --preview)"

  assert_contains "$output" "tmux-revive restore preview" "restore preview header"
  assert_contains "$output" "Reason: preview-summary" "restore preview reason"
  assert_contains "$output" "Manifest: $manifest" "restore preview manifest path"
  assert_contains "$output" "Will restore (2):" "restore preview restore count"
  assert_contains "$output" "gamma" "restore preview restorable session"
  assert_contains "$output" "base" "restore preview restorable group leader"
  assert_contains "$output" "Will skip existing (1):" "restore preview skipped count"
  assert_contains "$output" "alpha" "restore preview skipped session"
  assert_contains "$output" "Grouped session issues (1):" "restore preview grouped count"
  assert_contains "$output" "grouped" "restore preview grouped peer session"
}

@test "restore report summary includes restored, skipped, and fallback sections" {
  tmux new-session -d -s alpha
  tmux new-session -d -s base
  tmux new-session -d -t base -s grouped
  tmux new-session -d -s gamma
  gamma_pane="$(tmux list-panes -t gamma -F '#{pane_id}' | head -n 1)"
  "$pane_meta" set-command-preview 'python app.py' "$gamma_pane"
  "$save_state" --reason restore-report-summary

  tmux kill-session -t gamma
  tmux kill-session -t grouped
  tmux kill-session -t base

  "$restore_state" --yes >/dev/null

  report_path="$(tmux_revive_latest_restore_report_path)"
  wait_for_file "$report_path" || fail "restore report was not written"
  report_json="$(cat "$report_path")"
  report_text="$("$tmux_revive_dir/show-restore-report.sh" --report "$report_path")"

  assert_contains "$report_json" '"summary"' "restore report summary field"
  assert_contains "$report_text" "tmux-revive restore report" "restore report header"
  assert_contains "$report_text" "Restored (3):" "restore report restored section"
  assert_contains "$report_text" "gamma" "restore report restored session"
  assert_contains "$report_text" "base" "restore report restored group leader"
  assert_contains "$report_text" "grouped" "restore report restored grouped session"
  assert_contains "$report_text" "Skipped existing (1):" "restore report skipped section"
  assert_contains "$report_text" "alpha" "restore report skipped session"
  assert_contains "$report_text" "Grouped session issues (0):" "restore report grouped section"
  assert_contains "$report_text" "Pane fallbacks (2):" "restore report fallback section"
  assert_contains "$report_text" "saved command preloaded at the prompt; not auto-run" "restore report fallback detail"
}

@test "restore report popup is opened with correct arguments" {
  tmux new-session -d -s work
  "$save_state" --reason restore-report-popup
  tmux kill-server

  rm -f "$TMUX_TEST_DISPLAY_POPUP_LOG"
  "$restore_state" --session-name work --yes --report-client-tty test-tty >/dev/null

  wait_for_file "$TMUX_TEST_DISPLAY_POPUP_LOG" || fail "restore report popup was not opened"
  popup_log="$(cat "$TMUX_TEST_DISPLAY_POPUP_LOG")"
  assert_contains "$popup_log" "display-popup -t test-tty" "restore report popup client target"
  assert_contains "$popup_log" "show-restore-report.sh" "restore report popup command"
  assert_contains "$popup_log" "$(tmux_revive_latest_restore_report_path)" "restore report popup path"
}

@test "restore health warnings appear in both preview and report" {
  tmux new-session -d -s work
  tmux split-window -d -t work
  "$save_state" --reason restore-health
  manifest="$(latest_manifest)"

  fake_nvim_state="$case_root/fake-nvim-state.json"
  jq -n --arg missing_path "$case_root/missing-nvim-file.txt" '{
    cwd: "/tmp",
    current_tab: 1,
    tabs: [
      {
        index: 1,
        current_win: 1,
        wins: [
          { path: $missing_path, cursor: [3, 1] }
        ]
      }
    ]
  }' >"$fake_nvim_state"

  manifest_tmp="${manifest}.tmp"
  jq \
    --arg missing_cwd "$case_root/missing-cwd" \
    --arg missing_tail "$case_root/missing-tail.log" \
    --arg nvim_state "$fake_nvim_state" \
    '
      .sessions[0].windows[0].panes[0].cwd = $missing_cwd
      | .sessions[0].windows[0].panes[0].restore_strategy = "restart-command"
      | .sessions[0].windows[0].panes[0].restart_command = ("tail -f " + $missing_tail)
      | .sessions[0].windows[0].panes[1].restore_strategy = "nvim"
      | .sessions[0].windows[0].panes[1].nvim_state_ref = $nvim_state
    ' "$manifest" >"$manifest_tmp"
  mv "$manifest_tmp" "$manifest"

  tmux kill-server

  preview_output="$("$restore_state" --manifest "$manifest" --preview)"
  assert_contains "$preview_output" "Health warnings (" "restore health preview section"
  assert_contains "$preview_output" "missing cwd:" "restore health preview missing cwd"
  assert_contains "$preview_output" "tail target is missing:" "restore health preview missing tail target"
  assert_contains "$preview_output" "Neovim state references 1 missing file(s):" "restore health preview missing nvim target"

  "$restore_state" --manifest "$manifest" --session-name work --yes >/dev/null
  report_path="$(tmux_revive_latest_restore_report_path)"
  wait_for_file "$report_path" || fail "restore health report missing"
  report_text="$("$tmux_revive_dir/show-restore-report.sh" --report "$report_path")"
  assert_contains "$report_text" "Health warnings (" "restore health report section"
  assert_contains "$report_text" "missing cwd:" "restore health report missing cwd"
  assert_contains "$report_text" "tail target is missing:" "restore health report missing tail target"
  assert_contains "$report_text" "Neovim state references 1 missing file(s):" "restore health report missing nvim target"
}
