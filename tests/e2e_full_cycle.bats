setup() {
  load test_helper/common-setup
  load test_helper/assertions
  load test_helper/wait-helpers
  load test_helper/data-helpers
  load test_helper/fake-wrappers
  load test_helper/shell-env-helpers
  _common_setup
  _setup_case
  setup_server_flag_wrapper
}

teardown() {
  _teardown_case
}

# Full end-to-end cycle: save two sessions with real content (nvim, ls, tail -f),
# kill one, restore it via the Revive prompt, and verify everything comes back.
@test "full save-restore cycle via Revive with nvim, tail, and history" {
  if ! command -v expect >/dev/null 2>&1; then
    skip "expect not installed"
  fi

  zdotdir="$case_root/zdotdir"
  save_test_shell_env
  setup_test_zsh_env "$zdotdir" ': 1700000000:0;echo seeded-history'

  # ── Files for nvim and tail ──────────────────────────────────────────
  sample_dir="$(cd "$case_root" && pwd -P)/src"
  mkdir -p "$sample_dir"
  nvim_file_session0="$sample_dir/session0-notes.txt"
  nvim_file_session_foo="$sample_dir/foo-config.txt"
  tail_log="$sample_dir/app.log"

  seq 1 30 >"$nvim_file_session0"
  seq 1 20 >"$nvim_file_session_foo"
  printf 'log-line-1\nlog-line-2\nlog-line-3\n' >"$tail_log"

  # ── Step 1-2: Create default session "0" with two windows ───────────
  # Window 1: pane 1 = nvim, pane 2 = ls
  # Window 2: pane 1 = tail -f
  tmux new-session -d -c "$sample_dir"

  # Get the first window's ID (don't assume numbering)
  s0_first_window="$(tmux list-windows -t 0 -F '#{window_id}' | head -n 1)"
  session0_pane1="$(tmux list-panes -t "$s0_first_window" -F '#{pane_id}' | head -n 1)"

  # Open nvim in first pane via headless + register
  nvim_socket_0="/tmp/bats-e2e-nvim0.$$"
  "$real_nvim" --headless -u NONE -i NONE \
    --cmd "lua package.path = package.path .. ';$repo_root/nvim/lua/?.lua;$repo_root/nvim/lua/?/init.lua'" \
    --listen "$nvim_socket_0" "$nvim_file_session0" >/dev/null 2>&1 &
  nvim_pid_0=$!
  wait_for_nvim_expr "$nvim_socket_0" 'expand("%:p")' "$nvim_file_session0" || fail "nvim for session 0 did not start"
  nvim --server "$nvim_socket_0" --remote-expr "execute('call cursor(15,1)')" >/dev/null
  wait_for_nvim_expr "$nvim_socket_0" 'line(".")' "15" || fail "nvim cursor did not move to line 15"
  "$repo_root/tmux/send_to_nvim/register_nvim_instance.sh" "$session0_pane1" "$nvim_socket_0" "$nvim_pid_0" "$sample_dir"

  # Split pane and run ls
  tmux split-window -h -t "$s0_first_window" -c "$sample_dir"
  session0_pane2="$(tmux list-panes -t "$s0_first_window" -F '#{pane_id}' | tail -n 1)"
  tmux send-keys -t "$session0_pane2" "ls" C-m
  sleep 0.5

  # Create second window with tail -f
  s0_second_window="$(tmux new-window -d -P -F '#{window_id}' -t 0: -c "$sample_dir")"
  session0_w2_pane="$(tmux list-panes -t "$s0_second_window" -F '#{pane_id}' | head -n 1)"
  tmux send-keys -t "$session0_w2_pane" "tail -f $(printf '%q' "$tail_log")" C-m
  wait_for_pane_command "$session0_w2_pane" tail 60 0.25 || fail "tail -f did not start in session 0"

  # ── Step 3: Save via bind+S ─────────────────────────────────────────
  tmux bind-key S run-shell -b "TMUX_REVIVE_SOCKET_PATH=#{socket_path} $tmux_revive_dir/save-state.sh --reason manual"

  latest_path="$(TMUX_REVIVE_TMUX_SERVER="$socket_name" tmux_revive_latest_path)"
  rm -f "$latest_path"

  cat >"$case_root/save-session0.expect" <<EXPECT_EOF
#!/usr/bin/expect -f
set timeout 20
log_user 0
spawn $real_tmux -f /dev/null -L $socket_name attach-session -t 0
after 500
send "\002S"
after 2000
send "\002d"
expect eof
EXPECT_EOF
  chmod +x "$case_root/save-session0.expect"
  "$case_root/save-session0.expect"

  # ── Step 4-5: Verify session "0" saved ──────────────────────────────
  wait_for_file "$latest_path" 80 0.25 || fail "save via bind+S did not create snapshot for session 0"
  manifest_after_s0="$(TMUX_REVIVE_TMUX_SERVER="$socket_name" latest_manifest)"
  [ -n "$manifest_after_s0" ] || fail "no manifest after saving session 0"
  s0_name="$(jq -r '.sessions[] | select(.session_name == "0") | .session_name // ""' "$manifest_after_s0")"
  assert_eq "0" "$s0_name" "saved session has default name 0"

  # ── Step 6: Create session "foo" with nvim ──────────────────────────
  tmux new-session -d -s foo -c "$sample_dir"

  foo_first_window="$(tmux list-windows -t foo -F '#{window_id}' | head -n 1)"
  foo_pane="$(tmux list-panes -t "$foo_first_window" -F '#{pane_id}' | head -n 1)"

  nvim_socket_foo="/tmp/bats-e2e-nvimfoo.$$"
  "$real_nvim" --headless -u NONE -i NONE \
    --cmd "lua package.path = package.path .. ';$repo_root/nvim/lua/?.lua;$repo_root/nvim/lua/?/init.lua'" \
    --listen "$nvim_socket_foo" "$nvim_file_session_foo" >/dev/null 2>&1 &
  nvim_pid_foo=$!
  wait_for_nvim_expr "$nvim_socket_foo" 'expand("%:p")' "$nvim_file_session_foo" || fail "nvim for session foo did not start"
  nvim --server "$nvim_socket_foo" --remote-expr "execute('call cursor(10,1)')" >/dev/null
  wait_for_nvim_expr "$nvim_socket_foo" 'line(".")' "10" || fail "nvim cursor did not move to line 10 in foo"
  "$repo_root/tmux/send_to_nvim/register_nvim_instance.sh" "$foo_pane" "$nvim_socket_foo" "$nvim_pid_foo" "$sample_dir"

  # ── Step 7: Save via bind+S again ───────────────────────────────────
  rm -f "$latest_path"

  cat >"$case_root/save-foo.expect" <<EXPECT_EOF
#!/usr/bin/expect -f
set timeout 20
log_user 0
spawn $real_tmux -f /dev/null -L $socket_name attach-session -t foo
after 500
send "\002S"
after 2000
send "\002d"
expect eof
EXPECT_EOF
  chmod +x "$case_root/save-foo.expect"
  "$case_root/save-foo.expect"

  # ── Step 8-9: Verify session "foo" saved ────────────────────────────
  wait_for_file "$latest_path" 80 0.25 || fail "save via bind+S did not create snapshot for session foo"
  manifest_after_foo="$(TMUX_REVIVE_TMUX_SERVER="$socket_name" latest_manifest)"
  [ -n "$manifest_after_foo" ] || fail "no manifest after saving session foo"
  foo_name="$(jq -r '.sessions[] | select(.session_name == "foo") | .session_name // ""' "$manifest_after_foo")"
  assert_eq "foo" "$foo_name" "saved session has name foo"

  # Kill headless nvim instances (they are not needed for restore — mock nvim will be used)
  kill "$nvim_pid_0" >/dev/null 2>&1 || true
  kill "$nvim_pid_foo" >/dev/null 2>&1 || true

  # ── Step 10: Kill session "0" ───────────────────────────────────────
  tmux kill-session -t 0

  # Verify only "foo" remains
  session_list="$(tmux list-sessions -F '#{session_name}')"
  assert_contains "$session_list" "foo" "foo session still alive"
  assert_not_contains "$session_list" "0" "session 0 was killed"

  # ── Step 11: Run tmux to open a new session ─────────────────────────
  # Simulate what happens when the user runs `tmux -L <server>`:
  # - A new default session gets created (named "1" since "0" was killed but foo exists)
  # - after-new-session hook fires → maybe-show-startup-popup.sh → Revive popup
  # - User selects saved session "0" to restore it
  tmux set-option -g @tmux-revive-startup-restore prompt

  # Create the new session (simulating `tmux -L <server>`)
  tmux new-session -d -s placeholder
  transient_session_id="$(tmux display-message -p -t placeholder '#{session_id}')"

  # Set up fake fzf to select saved session "0"
  setup_fake_fzf_select_saved "0" "enter"

  rm -f "$TMUX_TEST_DISPLAY_POPUP_LOG" "$TMUX_TEST_ATTACH_LOG"
  export TMUX_TEST_POPUP_EXECUTE=1

  # ── Step 11a: Revive modal should appear ───────────────────────────
  socket_path="$(tmux display-message -p '#{socket_path}')"
  TMUX_REVIVE_SOCKET_PATH="$socket_path" "$startup_restore" --context new-session --session-target "$transient_session_id" --client-tty test-tty

  wait_for_file "$TMUX_TEST_DISPLAY_POPUP_LOG" || fail "Revive popup did not appear"
  popup_cmd="$(cat "$TMUX_TEST_DISPLAY_POPUP_LOG")"
  assert_contains "$popup_cmd" "pick.sh" "Revive popup launches pick.sh"

  # ── Step 11b-c: Session "0" should be restored ──────────────────────
  wait_for_session 0 || fail "saved session 0 was not restored via Revive"

  # ── Step 11d: Exactly 2 sessions (foo and 0) ───────────────────────
  # The transient placeholder session should have been cleaned up
  session_count="$(tmux list-sessions -F '#{session_name}' | grep -cv '^$' || true)"
  session_names="$(tmux list-sessions -F '#{session_name}' | sort)"
  assert_eq "2" "$session_count" "exactly 2 sessions after restore (got: $session_names)"

  # ── Step 11e: Validate restored session structure ───────────────────
  # Session 0 should have 2 windows
  restored_windows="$(tmux list-windows -t 0 -F '#{window_id}')"
  window_count="$(printf '%s\n' "$restored_windows" | wc -l | tr -d ' ')"
  assert_eq "2" "$window_count" "restored session 0 has 2 windows"

  restored_w1="$(printf '%s\n' "$restored_windows" | head -n 1)"
  restored_w2="$(printf '%s\n' "$restored_windows" | tail -n 1)"

  # Window 1: should have 2 panes
  w1_pane_count="$(tmux list-panes -t "$restored_w1" -F '#{pane_id}' | wc -l | tr -d ' ')"
  assert_eq "2" "$w1_pane_count" "restored window 1 has 2 panes"

  # Window 1, pane 1: mock nvim should have been invoked with restore state
  restored_w1p1="$(tmux list-panes -t "$restored_w1" -F '#{pane_id}' | head -n 1)"
  wait_for_file "$TMUX_TEST_NVIM_RESTORE_LOG" 60 0.25 || fail "nvim restore log was not created — mock nvim was not invoked"
  nvim_restore_info="$(cat "$TMUX_TEST_NVIM_RESTORE_LOG")"
  [ -n "$nvim_restore_info" ] || fail "nvim restore log is empty"

  # Window 1, pane 2: should show pane history with ls output
  restored_w1p2="$(tmux list-panes -t "$restored_w1" -F '#{pane_id}' | tail -n 1)"
  # The second pane should have history restored showing directory contents
  pane2_capture="$(tmux capture-pane -p -S -40 -t "$restored_w1p2" 2>/dev/null || true)"
  # ls output would include our source files
  assert_contains "$pane2_capture" "session0-notes.txt" "pane 2 history shows ls output with session0-notes.txt"

  # Window 2: should have 1 pane running tail
  w2_pane_count="$(tmux list-panes -t "$restored_w2" -F '#{pane_id}' | wc -l | tr -d ' ')"
  assert_eq "1" "$w2_pane_count" "restored window 2 has 1 pane"

  restored_w2p1="$(tmux list-panes -t "$restored_w2" -F '#{pane_id}' | head -n 1)"

  # Verify tail is live: append to log and check it shows up in the pane
  # (pane command shows as "bash" because start-restored-pane.sh evals tail)
  printf 'new-log-after-restore\n' >>"$tail_log"
  wait_for_pane_text "$restored_w2p1" "new-log-after-restore" 60 0.25 || fail "tail -f did not show new content after restore"

  # Verify old log content is visible (transcript history)
  tail_capture="$(tmux capture-pane -p -S -80 -t "$restored_w2p1" 2>/dev/null || true)"
  assert_contains "$tail_capture" "log-line-1" "tail pane shows pre-save log content"

  # ── Step 11f: Verify zsh history is available ───────────────────────
  # Interrupt tail (Ctrl-C) — the start-restored-pane.sh will exec into zsh
  tmux send-keys -t "$restored_w2p1" C-c
  wait_for_pane_command "$restored_w2p1" zsh 60 0.25 || fail "pane did not return to zsh after Ctrl-C"

  history_probe="$case_root/history-probe.txt"
  tmux send-keys -t "$restored_w2p1" "fc -ln 1 > $(printf '%q' "$history_probe")" C-m
  wait_for_file "$history_probe" 60 0.25 || fail "history probe file was not created"

  history_contents="$(cat "$history_probe")"
  assert_contains "$history_contents" "echo seeded-history" "zsh history available after restore"

  unset TMUX_TEST_POPUP_EXECUTE
  restore_test_shell_env
}
