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

@test "restartable command allowlist matrix" {
  local approved_commands=(
    "tail -f /tmp/example.log"
    "tail -F /tmp/example.log"
    "tail -n 20 -f /tmp/example.log"
    "tail -n 20 -F /tmp/example.log"
    "tail --lines 20 -f /tmp/example.log"
    "tail --lines 20 -F /tmp/example.log"
    "make dev"
    "just dev"
    "npm run dev"
    "pnpm run dev"
    "yarn run dev"
    "yarn dev"
    "uv run app.py"
    "cargo run --bin app"
    "go run ."
    "docker-compose up api"
    "docker compose up api"
    "python -m http.server"
    "python3 -m http.server"
  )
  local rejected_commands=(
    "tail /tmp/example.log"
    "npm test"
    "pnpm dev"
    "yarn --version"
    "uv sync"
    "cargo test"
    "go test ./..."
    "docker-compose logs api"
    "docker compose logs api"
    "python app.py"
    "python3 script.py"
  )
  local command

  for command in "${approved_commands[@]}"; do
    tmux_revive_command_is_restartable "$command" || fail "approved command was not restartable: $command"
  done

  for command in "${rejected_commands[@]}"; do
    if tmux_revive_command_is_restartable "$command"; then
      fail "rejected command was restartable unexpectedly: $command"
    fi
  done
}

@test "restart command allowlist" {
  output_path="$case_root/restart-proof.txt"
  makefile="$case_root/Makefile"
  cat >"$makefile" <<EOF
restart-proof:
	@echo restarted > $output_path
EOF

  tmux new-session -d -s work
  pane_id="$(tmux list-panes -t work -F '#{pane_id}' | head -n 1)"
  "$pane_meta" set-restart-command "make -f $makefile restart-proof" "$pane_id"
  "$save_state" --reason test-restart-allowlist

  tmux kill-server
  "$restore_state" --session-name work --yes >/dev/null

  wait_for_file "$output_path" 40 0.25 || fail "allowlisted restart command did not run"
  assert_eq "restarted" "$(cat "$output_path")" "allowlisted restart output"
}

@test "restart command preview fallback" {
  output_path="$case_root/should-not-exist.txt"
  tmux new-session -d -s work
  pane_id="$(tmux list-panes -t work -F '#{pane_id}' | head -n 1)"
  "$pane_meta" set-restart-command "echo nope > $output_path" "$pane_id"
  "$save_state" --reason test-restart-preview

  tmux kill-server
  "$restore_state" --session-name work --yes >/dev/null
  restored_pane="$(tmux list-panes -t work -F '#{pane_id}' | head -n 1)"
  pane_capture="$(tmux capture-pane -p -S -40 -t "$restored_pane")"

  [ ! -f "$output_path" ] || fail "disallowed restart command executed unexpectedly"
  assert_contains "$pane_capture" "echo nope >" "disallowed restart preloaded command prefix"
  assert_contains "$pane_capture" "should-not-e" "disallowed restart preloaded command target"
}

@test "tail restart from preview" {
  log_path="$case_root/tail.log"
  printf 'before\n' >"$log_path"

  tmux new-session -d -s work
  pane_id="$(tmux list-panes -t work -F '#{pane_id}' | head -n 1)"
  tmux send-keys -t "$pane_id" "tail -f $(printf '%q' "$log_path")" C-m
  wait_for_pane_command "$pane_id" tail 60 0.25 || fail "tail did not start before save"
  "$pane_meta" set-command-preview "tail -f $log_path" "$pane_id"
  "$pane_meta" strategy auto "$pane_id"
  "$save_state" --reason test-tail-restart

  tmux kill-server
  "$restore_state" --session-name work --yes >/dev/null

  restored_pane="$(tmux list-panes -t work -F '#{pane_id}' | head -n 1)"
  printf 'after\n' >>"$log_path"
  wait_for_pane_text "$restored_pane" "after" 60 0.25 || fail "tail output did not resume after restore"
  pane_capture="$(tmux capture-pane -p -S -40 -t "$restored_pane")"
  assert_contains "$pane_capture" "after" "tail restart output"
}

@test "auto capture tail restart" {
  mkdir -p "$case_root/src"
  log_path="$case_root/src/backtrace.txt"
  printf 'seed\n' >"$log_path"

  tmux new-session -d -s work -c "$case_root/src"
  pane_id="$(tmux list-panes -t work -F '#{pane_id}' | head -n 1)"
  tmux send-keys -t "$pane_id" "tail -f $(printf '%q' "$log_path")" C-m
  wait_for_pane_command "$pane_id" tail 60 0.25 || fail "tail did not start before auto-capture save"
  for i in $(seq 1 30); do
    printf 'stream-%02d\n' "$i" >>"$log_path"
  done
  sleep 1
  "$save_state" --reason test-auto-capture-tail

  manifest="$(latest_manifest)"
  saved_preview="$(jq -r '.sessions[] | select(.session_name == "work") | .windows[0].panes[0].command_preview // ""' "$manifest")"
  saved_restart="$(jq -r '.sessions[] | select(.session_name == "work") | .windows[0].panes[0].restart_command // ""' "$manifest")"
  assert_eq "tail -f $log_path" "$saved_preview" "auto-captured tail command preview"
  assert_eq "tail -f $log_path" "$saved_restart" "auto-captured tail restart command"

  tmux kill-server
  "$restore_state" --session-name work --yes >/dev/null

  restored_pane="$(tmux list-panes -t work -F '#{pane_id}' | head -n 1)"
  pane_capture="$(tmux capture-pane -p -S -80 -t "$restored_pane")"
  assert_contains "$pane_capture" "stream-05" "saved transcript context visible after restore"

  printf 'after\n' >>"$log_path"
  wait_for_pane_text "$restored_pane" "after" 60 0.25 || fail "auto-captured tail output did not resume after restore"
  pane_capture="$(tmux capture-pane -p -S -80 -t "$restored_pane")"
  assert_contains "$pane_capture" "after" "auto-captured tail output after restore"
}

@test "interrupt restored tail returns to shell" {
  mkdir -p "$case_root/src"
  log_path="$case_root/src/backtrace.txt"
  expected_shell="$(basename "${SHELL:-/bin/sh}")"
  printf 'before\n' >"$log_path"

  tmux new-session -d -s work -c "$case_root/src"
  pane_id="$(tmux list-panes -t work -F '#{pane_id}' | head -n 1)"
  tmux send-keys -t "$pane_id" "tail -f $(printf '%q' "$log_path")" C-m
  wait_for_pane_command "$pane_id" tail 60 0.25 || fail "tail did not start before save for interrupt test"
  "$save_state" --reason test-interrupt-restored-tail

  tmux kill-server
  "$restore_state" --session-name work --yes >/dev/null

  restored_pane="$(tmux list-panes -t work -F '#{pane_id}' | head -n 1)"
  printf 'probe-before-interrupt\n' >>"$log_path"
  wait_for_pane_text "$restored_pane" "probe-before-interrupt" 60 0.25 || fail "restored tail output did not resume before interrupt"
  tmux send-keys -t "$restored_pane" C-c
  wait_for_pane_command "$restored_pane" "$expected_shell" 60 0.25 || fail "restored pane did not return to shell after interrupt"

  remaining_panes="$(tmux list-panes -t work -F '#{pane_id}')"
  assert_contains "$remaining_panes" "$restored_pane" "restored pane still exists after interrupt"
}

@test "restored autorun command not added to zsh history" {
  zdotdir="$case_root/zdotdir"
  history_probe="$case_root/history-probe.txt"
  save_test_shell_env
  mkdir -p "$case_root/src"
  setup_test_zsh_env "$zdotdir" ': 1700000000:0;echo seeded-history'

  log_path="$case_root/src/backtrace.txt"
  printf 'before\n' >"$log_path"

  tmux new-session -d -s work -c "$case_root/src"
  pane_id="$(tmux list-panes -t work -F '#{pane_id}' | head -n 1)"
  tmux send-keys -t "$pane_id" " tail -f $(printf '%q' "$log_path")" C-m
  wait_for_pane_command "$pane_id" tail 60 0.25 || fail "tail did not start before save for history suppression test"
  "$save_state" --reason test-restored-autorun-history-suppression

  tmux kill-server
  "$restore_state" --session-name work --yes >/dev/null

  restored_pane="$(tmux list-panes -t work -F '#{pane_id}' | head -n 1)"
  printf 'probe-before-history-check\n' >>"$log_path"
  wait_for_pane_text "$restored_pane" "probe-before-history-check" 60 0.25 || fail "restored tail output did not resume before history suppression check"
  tmux send-keys -t "$restored_pane" C-c
  wait_for_pane_command "$restored_pane" zsh 60 0.25 || fail "restored pane did not return to zsh before history check"
  tmux send-keys -t "$restored_pane" "fc -ln 1 > $(printf '%q' "$history_probe")" C-m
  wait_for_file "$history_probe" 60 0.25 || fail "history probe file was not created"

  history_contents="$(cat "$history_probe")"
  assert_contains "$history_contents" "echo seeded-history" "seeded zsh history remains available after interrupt"
  assert_not_contains "$history_contents" "tail -f $log_path" "restore auto-run command not added to zsh history"

  restore_test_shell_env
}

@test "restored nvim command not added to zsh history" {
  sample_dir="$(cd "$case_root" && pwd -P)"
  file_a="$sample_dir/file-a.txt"
  nvim_socket="$case_root/headless-nvim.sock"
  history_probe="$case_root/nvim-history-probe.txt"
  zdotdir="$case_root/zdotdir"
  save_test_shell_env
  setup_test_zsh_env "$zdotdir" ': 1700000000:0;echo seeded-history'

  seq 1 20 >"$file_a"

  tmux new-session -d -s work
  pane_id="$(tmux list-panes -t work -F '#{pane_id}' | head -n 1)"
  "$real_nvim" --headless -u NONE -i NONE \
    --cmd "lua package.path = package.path .. ';$repo_root/nvim/lua/?.lua;$repo_root/nvim/lua/?/init.lua'" \
    --listen "$nvim_socket" "$file_a" >/dev/null 2>&1 &
  nvim_pid=$!

  wait_for_nvim_expr "$nvim_socket" 'expand("%:p")' "$file_a" || fail "headless nvim did not open file in time for history test"
  nvim --server "$nvim_socket" --remote-expr "execute('call cursor(12,1)')" >/dev/null
  wait_for_nvim_expr "$nvim_socket" 'line(".")' "12" || fail "headless nvim did not move cursor in time for history test"

  "$repo_root/tmux/send_to_nvim/register_nvim_instance.sh" "$pane_id" "$nvim_socket" "$nvim_pid" "$(dirname "$file_a")"
  "$save_state" --reason test-restored-nvim-history
  rm -f "$TMUX_TEST_NVIM_RESTORE_LOG"

  kill "$nvim_pid" >/dev/null 2>&1 || true
  if ! wait_for_pid_exit "$nvim_pid" 20 0.1; then
    kill -9 "$nvim_pid" >/dev/null 2>&1 || true
    wait_for_pid_exit "$nvim_pid" 20 0.1 || true
  fi

  tmux kill-server
  "$restore_state" --session-name work --yes >/dev/null

  wait_for_file "$TMUX_TEST_NVIM_RESTORE_LOG" 60 0.25 || fail "restored nvim did not launch for history test"
  restored_pane="$(tmux list-panes -t work -F '#{pane_id}' | head -n 1)"
  wait_for_pane_command "$restored_pane" zsh 60 0.25 || fail "restored nvim pane did not return to zsh after shim exit"
  tmux send-keys -t "$restored_pane" "fc -ln 1 > $(printf '%q' "$history_probe")" C-m
  wait_for_file "$history_probe" 60 0.25 || fail "nvim history probe file was not created"

  history_contents="$(cat "$history_probe")"
  assert_contains "$history_contents" "echo seeded-history" "seeded zsh history remains available after nvim restore"
  assert_not_contains "$history_contents" "TMUX_NVIM_RESTORE_STATE=" "nvim restore env command not added to zsh history"
  assert_not_contains "$history_contents" "nvim" "nvim restore command not added to zsh history"

  restore_test_shell_env
}

@test "reference only messages" {
  tmux new-session -d -s work
  tmux split-window -d -t work
  manual_pane="$(nth_pane_id work 1)"
  history_pane="$(nth_pane_id work 2)"
  tmux send-keys -t "$manual_pane" 'echo manual transcript line' C-m
  tmux send-keys -t "$history_pane" 'echo history transcript line' C-m
  sleep 1
  "$pane_meta" set-command-preview 'npm run dev' "$manual_pane"
  "$pane_meta" strategy history_only "$history_pane"
  "$save_state" --reason test-reference-only

  tmux kill-server
  "$restore_state" --session-name work --yes >/dev/null
  sleep 1
  session_capture="$(tmux list-panes -t work -F '#{pane_id}' | while read -r restored_pane; do tmux capture-pane -p -S -60 -t "$restored_pane"; printf '\n===pane===\n'; done)"

  assert_contains "$session_capture" "history transcript line" "history-only transcript text"
}

@test "shell pane does not preload unrelated command" {
  tmux new-session -d -s work
  pane_id="$(tmux list-panes -t work -F '#{pane_id}' | head -n 1)"
  tmux send-keys -t "$pane_id" 'printf "context-only\n"' C-m
  sleep 1
  "$save_state" --reason test-shell-no-preload

  tmux kill-server
  "$restore_state" --session-name work --yes >/dev/null

  restored_pane="$(tmux list-panes -t work -F '#{pane_id}' | head -n 1)"
  wait_for_pane_text "$restored_pane" "context-only" 60 0.25 || fail "shell pane transcript was not replayed after restore"
  pane_capture="$(tmux capture-pane -p -S -40 -t "$restored_pane")"
  assert_contains "$pane_capture" "context-only" "shell pane transcript restored"
  case "$pane_capture" in
    *"Press Enter to run it"*|*"npm run dev"*|*"tail -f "*|*"echo nope > "*)
      fail "shell-only pane preloaded an unrelated command unexpectedly"
      ;;
  esac
}

@test "mixed non-nvim pane restore behavior" {
  approved_log="$case_root/approved.log"
  printf 'before\n' >"$approved_log"

  tmux new-session -d -s work
  tmux split-window -d -t work
  tmux split-window -d -t work

  approved_pane="$(nth_pane_id work 1)"
  unapproved_pane="$(nth_pane_id work 2)"
  blank_pane="$(nth_pane_id work 3)"

  tmux send-keys -t "$approved_pane" "tail -f $(printf '%q' "$approved_log")" C-m
  wait_for_pane_command "$approved_pane" tail 60 0.25 || fail "approved pane did not start tail before save"
  "$pane_meta" set-command-preview "tail -f $approved_log" "$approved_pane"
  "$pane_meta" strategy auto "$approved_pane"

  tmux send-keys -t "$unapproved_pane" 'printf "manual pane context\n"' C-m
  sleep 1
  "$pane_meta" set-command-preview 'python app.py' "$unapproved_pane"
  "$pane_meta" strategy auto "$unapproved_pane"

  tmux send-keys -t "$blank_pane" 'printf "blank pane context\n"' C-m
  sleep 1

  "$save_state" --reason test-mixed-non-nvim-pane-restore

  tmux kill-server
  "$restore_state" --session-name work --yes >/dev/null

  restored_approved="$(nth_pane_id work 1)"
  restored_unapproved="$(nth_pane_id work 2)"
  restored_blank="$(nth_pane_id work 3)"

  printf 'after\n' >>"$approved_log"
  wait_for_pane_text "$restored_approved" "after" 60 0.25 || fail "approved pane tail output did not resume after restore"

  approved_capture="$(tmux capture-pane -p -S -60 -t "$restored_approved")"
  unapproved_capture="$(tmux capture-pane -p -S -60 -t "$restored_unapproved")"
  blank_capture="$(tmux capture-pane -p -S -60 -t "$restored_blank")"

  assert_contains "$approved_capture" "after" "approved pane tail output after restore"
  assert_contains "$unapproved_capture" "manual pane context" "unapproved pane transcript restored"
  assert_contains "$unapproved_capture" "python app.py" "unapproved pane command preloaded"
  assert_not_contains "$blank_capture" "python app.py" "blank pane does not inherit unapproved command"
  assert_not_contains "$blank_capture" "tail -f " "blank pane does not inherit approved command"
  assert_contains "$blank_capture" "blank pane context" "blank pane transcript restored"
}

@test "auto capture mixed running and blank panes" {
  mkdir -p "$case_root/src"
  approved_log="$case_root/src/backtrace.txt"
  printf 'before\n' >"$approved_log"

  tmux new-session -d -s work -c "$case_root/src"
  tmux split-window -d -t work
  tmux split-window -d -t work

  approved_pane="$(nth_pane_id work 1)"
  unapproved_pane="$(nth_pane_id work 2)"
  blank_pane="$(nth_pane_id work 3)"

  tmux send-keys -t "$approved_pane" "tail -f $(printf '%q' "$approved_log")" C-m
  wait_for_pane_command "$approved_pane" tail 60 0.25 || fail "approved pane did not start tail before save"

  tmux send-keys -t "$unapproved_pane" "sleep 1000" C-m
  wait_for_pane_command "$unapproved_pane" sleep 60 0.25 || fail "unapproved pane did not start sleep before save"

  tmux send-keys -t "$blank_pane" 'printf "blank pane context\n"' C-m
  sleep 1

  "$save_state" --reason test-auto-capture-mixed

  manifest="$(latest_manifest)"
  approved_saved_preview="$(jq -r '.sessions[] | select(.session_name == "work") | .windows[0].panes[] | select(.current_command == "tail") | .command_preview // ""' "$manifest" | head -n 1)"
  unapproved_saved_preview="$(jq -r '.sessions[] | select(.session_name == "work") | .windows[0].panes[] | select(.current_command == "sleep") | .command_preview // ""' "$manifest" | head -n 1)"
  blank_saved_preview="$(jq -r '.sessions[] | select(.session_name == "work") | .windows[0].panes[] | select(.current_command != "tail" and .current_command != "sleep") | .command_preview // ""' "$manifest" | head -n 1)"
  assert_eq "tail -f $approved_log" "$approved_saved_preview" "approved pane exact command captured"
  assert_eq "sleep 1000" "$unapproved_saved_preview" "unapproved pane exact command captured"
  assert_eq "" "$blank_saved_preview" "blank pane saved without command preview"

  tmux kill-server
  "$restore_state" --session-name work --yes >/dev/null

  restored_approved="$(nth_pane_id work 1)"
  restored_unapproved="$(nth_pane_id work 2)"
  restored_blank="$(nth_pane_id work 3)"

  printf 'after\n' >>"$approved_log"
  wait_for_pane_text "$restored_approved" "after" 60 0.25 || fail "approved auto-captured tail output did not resume after restore"
  wait_for_pane_command "$restored_unapproved" zsh 60 0.25 || fail "unapproved pane did not return to zsh after restore"
  wait_for_pane_command "$restored_blank" zsh 60 0.25 || fail "blank pane did not return to zsh after restore"

  approved_capture="$(tmux capture-pane -p -S -60 -t "$restored_approved")"
  unapproved_capture="$(tmux capture-pane -p -S -60 -t "$restored_unapproved")"
  blank_capture="$(tmux capture-pane -p -S -60 -t "$restored_blank")"
  unapproved_current_command="$(tmux display-message -p -t "$restored_unapproved" '#{pane_current_command}')"
  blank_current_command="$(tmux display-message -p -t "$restored_blank" '#{pane_current_command}')"

  assert_contains "$approved_capture" "after" "approved auto-captured tail output after restore"
  assert_contains "$unapproved_capture" "sleep 1000" "unapproved running command preloaded exactly"
  assert_eq "zsh" "$unapproved_current_command" "unapproved pane did not auto-run exact command"
  assert_contains "$blank_capture" "blank pane context" "blank pane transcript restored"
  assert_not_contains "$blank_capture" "sleep 1000" "blank pane does not inherit unapproved command"
  assert_not_contains "$blank_capture" "tail -f " "blank pane does not inherit approved command"
  assert_eq "zsh" "$blank_current_command" "blank pane restored to shell"
}
