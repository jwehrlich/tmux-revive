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

@test "startup restore mode" {
  tmux new-session -d -s work
  "$save_state" --reason test-startup-auto

  tmux kill-server
  tmux new-session -d -s bootstrap
  tmux set-option -g @tmux-revive-startup-restore auto
  "$startup_restore"

  wait_for_session work || fail "work session did not restore in startup auto mode"
}

@test "startup restore off mode" {
  tmux new-session -d -s work
  "$save_state" --reason test-startup-off

  tmux kill-server
  tmux new-session -d -s bootstrap
  tmux set-option -g @tmux-revive-startup-restore off
  "$startup_restore"

  if tmux has-session -t work 2>/dev/null; then
    fail "startup off mode restored a session unexpectedly"
  fi
}

@test "startup prompt dismiss" {
  tmux new-session -d -s work
  "$save_state" --reason test-startup-prompt

  tmux kill-server
  tmux new-session -d -s bootstrap
  dismissed_path="$(tmux_revive_restore_prompt_suppressed_path)"
  shown_path="$(tmux_revive_restore_prompt_shown_path)"
  rm -f "$dismissed_path" "$shown_path"
  printf 'n\n' | "$startup_popup" >/dev/null

  wait_for_file "$dismissed_path" || fail "startup prompt dismiss flag was not created"
  if tmux has-session -t work 2>/dev/null; then
    fail "startup prompt dismiss restored a session unexpectedly"
  fi
}

@test "startup prompt reappears for newer snapshot" {
  tmux new-session -d -s work
  "$save_state" --reason test-startup-prompt-first
  first_manifest="$(latest_manifest)"

  tmux kill-server
  tmux new-session -d -s bootstrap
  tmux set-option -g @tmux-revive-startup-restore prompt
  rm -f "$TMUX_TEST_DISPLAY_POPUP_LOG"
  export TMUX_TEST_POPUP_EXECUTE=1
  setup_fake_fzf_auto_first ""  # dismiss

  "$startup_restore" --client-tty test-tty
  wait_for_file "$TMUX_TEST_DISPLAY_POPUP_LOG" || fail "startup prompt did not open popup for first manifest"
  first_popup_count="$(wc -l <"$TMUX_TEST_DISPLAY_POPUP_LOG" | tr -d ' ')"
  assert_eq "1" "$first_popup_count" "first startup prompt popup count"

  "$startup_restore" --client-tty test-tty
  same_manifest_popup_count="$(wc -l <"$TMUX_TEST_DISPLAY_POPUP_LOG" | tr -d ' ')"
  assert_eq "1" "$same_manifest_popup_count" "same manifest should not re-prompt"

  sleep 1
  tmux new-session -d -s newer
  "$save_state" --reason test-startup-prompt-second
  second_manifest="$(latest_manifest)"
  [ "$second_manifest" != "$first_manifest" ] || fail "second save did not produce a newer manifest path"
  tmux kill-session -t newer

  setup_fake_fzf_auto_first ""  # dismiss again
  "$startup_restore" --client-tty test-tty
  newer_manifest_popup_count="$(wc -l <"$TMUX_TEST_DISPLAY_POPUP_LOG" | tr -d ' ')"
  assert_eq "2" "$newer_manifest_popup_count" "newer snapshot should trigger a fresh prompt"

  unset TMUX_TEST_POPUP_EXECUTE
}

@test "startup prompt without tty does not consume prompt" {
  tmux new-session -d -s work
  "$save_state" --reason test-startup-prompt-without-tty

  tmux kill-server
  tmux new-session -d -s bootstrap
  tmux set-option -g @tmux-revive-startup-restore prompt
  dismissed_path="$(tmux_revive_restore_prompt_suppressed_path)"
  shown_path="$(tmux_revive_restore_prompt_shown_path)"
  rm -f "$dismissed_path" "$shown_path"

  # No client_tty → script exits early at line 190 without showing popup
  "$startup_restore"

  [ ! -f "$shown_path" ] || fail "prompt startup restore without tty consumed the shown flag unexpectedly"
  [ ! -f "$dismissed_path" ] || fail "prompt startup restore without tty created dismiss flag unexpectedly"
  if tmux has-session -t work 2>/dev/null; then
    fail "prompt startup restore without tty restored a session unexpectedly"
  fi
}

@test "new session prompt attach replaces transient session" {
  tmux new-session -d -s work
  "$save_state" --reason test-new-session-prompt

  tmux kill-server
  tmux new-session -d -s bootstrap
  tmux set-option -g @tmux-revive-startup-restore prompt
  tmux new-session -d -s scratch
  transient_session_id="$(tmux display-message -p -t scratch '#{session_id}')"

  rm -f "$TMUX_TEST_DISPLAY_POPUP_LOG" "$TMUX_TEST_ATTACH_LOG"
  export TMUX_TEST_POPUP_EXECUTE=1
  setup_fake_fzf_auto_first "ctrl-a"  # restore all

  "$startup_restore" --context new-session --session-target "$transient_session_id" --client-tty test-tty

  wait_for_file "$TMUX_TEST_DISPLAY_POPUP_LOG" || fail "new-session prompt did not open popup"
  wait_for_file "$TMUX_TEST_ATTACH_LOG" || fail "attach log was not created for new-session prompt attach"
  wait_for_session work || fail "saved session did not restore from new-session prompt"
  if tmux has-session -t "$transient_session_id" 2>/dev/null; then
    fail "transient blank session was not removed after attach restore"
  fi

  attach_log_contents="$(cat "$TMUX_TEST_ATTACH_LOG")"
  assert_contains "$attach_log_contents" "attach-session -t =work" "new-session prompt attach target"

  unset TMUX_TEST_POPUP_EXECUTE
}

@test "fresh tmux restore prompt name collision" {
  # Simulates: user has a saved default session "0", starts fresh tmux (also "0"),
  # the popup should appear because the transient session shadows the saved name.

  # Step 1: create the default-named session and save it
  tmux new-session -d  # creates session "0"
  "$save_state" --reason fresh-tmux-collision

  # Capture the saved session's GUID for verification
  saved_guid="$(jq -r '.sessions[0].session_guid' "$(latest_manifest)")"
  [ -n "$saved_guid" ] || fail "name-collision: saved session has no GUID"

  # Step 2: kill everything -- clean slate
  tmux kill-server

  # Step 3: start fresh tmux (creates default session "0" again -- name collision)
  tmux new-session -d  # session "0"
  tmux set-option -g @tmux-revive-startup-restore prompt
  transient_session_id="$(tmux display-message -p -t 0 '#{session_id}')"

  # Verify transient session has no GUID (it's a fresh blank session)
  transient_guid="$(tmux_revive_get_session_guid 0)"
  [ -z "$transient_guid" ] || fail "name-collision: fresh transient session should not have a GUID"

  rm -f "$TMUX_TEST_DISPLAY_POPUP_LOG" "$TMUX_TEST_ATTACH_LOG"
  export TMUX_TEST_POPUP_EXECUTE=1
  setup_fake_fzf_auto_first "ctrl-a"  # restore all

  # The after-new-session hook would call this:
  "$startup_restore" --context new-session --session-target "$transient_session_id" --client-tty test-tty

  wait_for_file "$TMUX_TEST_DISPLAY_POPUP_LOG" || fail "name-collision: popup did not appear"
  wait_for_file "$TMUX_TEST_ATTACH_LOG" || fail "name-collision: attach log not created"

  # Session "0" should exist and be the RESTORED one (with the saved GUID)
  tmux has-session -t 0 2>/dev/null || fail "name-collision: session 0 not found after restore"
  restored_guid="$(tmux_revive_get_session_guid 0)"
  assert_eq "$saved_guid" "$restored_guid" "name-collision: session 0 should have the saved GUID"

  unset TMUX_TEST_POPUP_EXECUTE
}

@test "fresh tmux restore prompt no collision" {
  # Simulates: user has a saved session "mywork", starts fresh tmux (session "0"),
  # the popup should appear, restore creates "mywork" and replaces transient "0".

  # Step 1: create a named session and save it
  tmux new-session -d -s mywork
  "$save_state" --reason fresh-tmux-no-collision

  # Step 2: kill everything -- clean slate
  tmux kill-server

  # Step 3: start fresh tmux (creates default session "0" -- no name collision)
  tmux new-session -d  # session "0"
  tmux set-option -g @tmux-revive-startup-restore prompt
  transient_session_id="$(tmux display-message -p -t 0 '#{session_id}')"

  rm -f "$TMUX_TEST_DISPLAY_POPUP_LOG" "$TMUX_TEST_ATTACH_LOG"
  export TMUX_TEST_POPUP_EXECUTE=1
  setup_fake_fzf_auto_first "ctrl-a"  # restore all

  "$startup_restore" --context new-session --session-target "$transient_session_id" --client-tty test-tty

  wait_for_file "$TMUX_TEST_DISPLAY_POPUP_LOG" || fail "no-collision: popup did not appear"
  wait_for_file "$TMUX_TEST_ATTACH_LOG" || fail "no-collision: attach log not created"
  wait_for_session mywork || fail "no-collision: restored session mywork not found"

  # Transient session should have been killed
  if tmux has-session -t "$transient_session_id" 2>/dev/null; then
    fail "no-collision: transient session was not removed after restore"
  fi

  attach_log_contents="$(cat "$TMUX_TEST_ATTACH_LOG")"
  assert_contains "$attach_log_contents" "attach-session -t =mywork" "no-collision attach target"

  unset TMUX_TEST_POPUP_EXECUTE
}

@test "fresh tmux restore prompt reappears" {
  # After dismissing, creating another new session should show the popup again
  # (new-session context does not suppress for server lifetime).

  tmux new-session -d -s mywork
  "$save_state" --reason fresh-tmux-reappears

  tmux kill-server
  tmux new-session -d  # session "0"
  tmux set-option -g @tmux-revive-startup-restore prompt
  transient1_id="$(tmux display-message -p -t 0 '#{session_id}')"

  rm -f "$TMUX_TEST_DISPLAY_POPUP_LOG"
  export TMUX_TEST_POPUP_EXECUTE=1
  setup_fake_fzf_auto_first ""  # dismiss

  "$startup_restore" --context new-session --session-target "$transient1_id" --client-tty test-tty

  wait_for_file "$TMUX_TEST_DISPLAY_POPUP_LOG" || fail "reappears: first popup did not appear"
  first_popup_count="$(wc -l <"$TMUX_TEST_DISPLAY_POPUP_LOG" | tr -d ' ')"
  assert_eq "1" "$first_popup_count" "reappears: first popup count"

  # mywork should NOT have been restored (we dismissed)
  if tmux has-session -t mywork 2>/dev/null; then
    fail "reappears: dismiss should not have restored mywork"
  fi

  # Suppress flag should NOT exist for new-session context
  suppress_path="$(tmux_revive_restore_prompt_suppressed_path)"
  if [ -f "$suppress_path" ]; then
    fail "reappears: dismiss in new-session context should not write suppress flag"
  fi

  # Simulate creating another new session -- popup should appear again
  tmux new-session -d -s scratch
  transient2_id="$(tmux display-message -p -t scratch '#{session_id}')"
  setup_fake_fzf_auto_first "ctrl-a"  # this time restore

  "$startup_restore" --context new-session --session-target "$transient2_id" --client-tty test-tty

  second_popup_count="$(wc -l <"$TMUX_TEST_DISPLAY_POPUP_LOG" | tr -d ' ')"
  assert_eq "2" "$second_popup_count" "reappears: second popup should appear after dismiss"
  wait_for_session mywork || fail "reappears: mywork not restored on second prompt"

  unset TMUX_TEST_POPUP_EXECUTE
}
