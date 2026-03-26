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

@test "restore preserves pane cwd" {
  mkdir -p "$case_root/desired" "$case_root/wrong"
  desired_dir="$(cd "$case_root/desired" && pwd -P)"
  wrong_dir="$(cd "$case_root/wrong" && pwd -P)"
  old_working_dir="${WORKING_DIR-__TMUX_REVIVE_UNSET__}"
  export WORKING_DIR="$wrong_dir"
  export SHELL="${SHELL:-$(command -v zsh || printf '/bin/zsh')}"

  tmux new-session -d -s work -c "$desired_dir"
  restored_pane="$(tmux list-panes -t work -F '#{pane_id}' | head -n 1)"
  tmux send-keys -t "$restored_pane" "cd $(printf '%q' "$desired_dir")" C-m
  wait_for_pane_path "$restored_pane" "$desired_dir" 60 0.25 || fail "test setup did not converge to desired cwd before save"
  "$save_state" --reason test-pane-cwd

  tmux kill-server
  "$restore_state" --session-name work --yes >/dev/null

  restored_pane="$(tmux list-panes -t work -F '#{pane_id}' | head -n 1)"
  wait_for_pane_path "$restored_pane" "$desired_dir" 60 0.25 || fail "restored pane cwd did not converge to saved path"
  restored_path="$(tmux display-message -p -t "$restored_pane" '#{pane_current_path}')"
  assert_eq "$desired_dir" "$restored_path" "restored pane cwd"
  if [ "$old_working_dir" = "__TMUX_REVIVE_UNSET__" ]; then
    unset WORKING_DIR
  else
    export WORKING_DIR="$old_working_dir"
  fi
}

@test "restore preserves window names" {
  tmux new-session -d -s work
  tmux set-window-option -g automatic-rename on
  window1_index="$(tmux list-windows -t work -F '#{window_index}' | head -n 1)"
  tmux rename-window -t "work:$window1_index" "editor"
  window2_index="$(tmux new-window -d -P -F '#{window_index}' -t work: -n "logs")"
  window1_pane="$(tmux list-panes -t "work:$window1_index" -F '#{pane_id}' | head -n 1)"
  window2_pane="$(tmux list-panes -t "work:$window2_index" -F '#{pane_id}' | head -n 1)"
  tmux send-keys -t "$window1_pane" 'printf "editor pane\n"' C-m
  tmux send-keys -t "$window2_pane" 'printf "logs pane\n"' C-m
  sleep 1

  "$save_state" --reason test-window-name-stability
  tmux kill-server
  "$restore_state" --session-name work --yes >/dev/null
  sleep 1

  window_names="$(tmux list-windows -t work -F '#{window_index}:#{window_name}')"
  assert_contains "$window_names" ":editor" "restored first window name"
  assert_contains "$window_names" ":logs" "restored second window name"

  # rename-window causes tmux to set automatic-rename off per-window;
  # the save captures that truthfully, and restore applies it back
  auto_rename_values="$(tmux list-windows -t work -F '#{window_index}:#{automatic-rename}')"
  off_auto_rename_count="$(printf '%s\n' "$auto_rename_values" | awk -F ':' '$2 == "0" { count++ } END { print count + 0 }')"
  assert_eq "2" "$off_auto_rename_count" "renamed windows preserve automatic-rename off"
}

@test "restore preserves explicit auto rename off" {
  tmux new-session -d -s work
  tmux set-window-option -g automatic-rename on
  window1_index="$(tmux list-windows -t work -F '#{window_index}' | head -n 1)"
  tmux rename-window -t "work:$window1_index" "pinned"
  # rename-window implicitly sets automatic-rename off; confirm it's captured
  window2_index="$(tmux new-window -d -P -F '#{window_index}' -t work:)"
  # Window 2 created without -n, so automatic-rename stays at global default (on)
  # with no per-window override — save captures empty, restore uses setw -u
  sleep 1

  "$save_state" --reason test-auto-rename-explicit
  tmux kill-server
  "$restore_state" --session-name work --yes >/dev/null
  # Simulate user's tmux.conf setting the global default (test runs with -f /dev/null)
  tmux set-window-option -g automatic-rename on
  sleep 1

  window_names="$(tmux list-windows -t work -F '#{window_index}:#{window_name}')"
  assert_contains "$window_names" ":pinned" "restored pinned window name"

  # Window 1 (renamed) should have automatic-rename off (saved from manifest)
  # Window 2 (no rename) should inherit global automatic-rename on after setw -u
  auto_rename_values="$(tmux list-windows -t work -F '#{window_index}:#{automatic-rename}')"
  first_auto_rename="$(printf '%s\n' "$auto_rename_values" | head -n 1 | awk -F ':' '{ print $2 }')"
  second_auto_rename="$(printf '%s\n' "$auto_rename_values" | tail -n 1 | awk -F ':' '{ print $2 }')"
  assert_eq "0" "$first_auto_rename" "renamed window keeps automatic-rename off"
  assert_eq "1" "$second_auto_rename" "unrenamed window inherits global automatic-rename on"
}

@test "restore preserves window options" {
  tmux new-session -d -s work
  window1_index="$(tmux list-windows -t work -F '#{window_index}' | head -n 1)"
  tmux setw -t "work:$window1_index" monitor-activity on
  tmux setw -t "work:$window1_index" synchronize-panes on
  window2_index="$(tmux new-window -d -P -F '#{window_index}' -t work:)"
  tmux setw -t "work:$window2_index" monitor-silence 30
  sleep 1

  "$save_state" --reason test-window-options
  tmux kill-server
  "$restore_state" --session-name work --yes >/dev/null
  sleep 1

  w1_monitor="$(tmux show-window-option -v -t "work:0" monitor-activity 2>/dev/null || true)"
  w1_sync="$(tmux show-window-option -v -t "work:0" synchronize-panes 2>/dev/null || true)"
  w2_silence="$(tmux show-window-option -v -t "work:1" monitor-silence 2>/dev/null || true)"
  assert_eq "on" "$w1_monitor" "window 1 monitor-activity preserved"
  assert_eq "on" "$w1_sync" "window 1 synchronize-panes preserved"
  assert_eq "30" "$w2_silence" "window 2 monitor-silence preserved"
}

@test "multi pane distinct cwds restore" {
  mkdir -p "$case_root/dir-a" "$case_root/dir-b" "$case_root/dir-c"
  dir_a="$(cd "$case_root/dir-a" && pwd -P)"
  dir_b="$(cd "$case_root/dir-b" && pwd -P)"
  dir_c="$(cd "$case_root/dir-c" && pwd -P)"

  tmux new-session -d -s work -c "$dir_a"
  tmux split-window -d -t work -c "$dir_b"
  tmux split-window -d -t work -c "$dir_c"
  # Let shells initialize before sending cd commands
  sleep 1

  pane_a="$(nth_pane_id work 1)"
  pane_b="$(nth_pane_id work 2)"
  pane_c="$(nth_pane_id work 3)"

  tmux send-keys -t "$pane_a" "cd $(printf '%q' "$dir_a")" C-m
  tmux send-keys -t "$pane_b" "cd $(printf '%q' "$dir_b")" C-m
  tmux send-keys -t "$pane_c" "cd $(printf '%q' "$dir_c")" C-m
  wait_for_pane_path "$pane_a" "$dir_a" 80 0.25 || fail "pane_a did not converge to dir_a before save"
  wait_for_pane_path "$pane_b" "$dir_b" 80 0.25 || fail "pane_b did not converge to dir_b before save"
  wait_for_pane_path "$pane_c" "$dir_c" 80 0.25 || fail "pane_c did not converge to dir_c before save"

  tmux send-keys -t "$pane_a" 'printf "pane-a\n"' C-m
  tmux send-keys -t "$pane_b" 'printf "pane-b\n"' C-m
  tmux send-keys -t "$pane_c" 'printf "pane-c\n"' C-m
  sleep 1

  "$save_state" --reason test-multi-pane-distinct-cwds

  tmux kill-server
  "$restore_state" --session-name work --yes >/dev/null

  wait_for_pane_path "$(nth_pane_id work 1)" "$dir_a" 80 0.25 || fail "restored pane_a cwd did not converge to dir_a"
  wait_for_pane_path "$(nth_pane_id work 2)" "$dir_b" 80 0.25 || fail "restored pane_b cwd did not converge to dir_b"
  wait_for_pane_path "$(nth_pane_id work 3)" "$dir_c" 80 0.25 || fail "restored pane_c cwd did not converge to dir_c"
  pane_paths="$(tmux list-panes -t work -F '#{pane_current_path}' | sort)"
  assert_contains "$pane_paths" "$dir_a" "restored pane paths include dir_a"
  assert_contains "$pane_paths" "$dir_b" "restored pane paths include dir_b"
  assert_contains "$pane_paths" "$dir_c" "restored pane paths include dir_c"
}

@test "restore tolerates missing pane cwds" {
  mkdir -p "$case_root/dir-a" "$case_root/dir-b" "$case_root/dir-c"
  dir_a="$(cd "$case_root/dir-a" && pwd -P)"
  dir_b="$(cd "$case_root/dir-b" && pwd -P)"
  dir_c="$(cd "$case_root/dir-c" && pwd -P)"

  tmux new-session -d -s work -c "$dir_a"
  tmux split-window -d -t work -c "$dir_b"
  tmux new-window -d -t work -n extra -c "$dir_c"

  "$save_state" --reason test-missing-pane-cwds
  rm -rf "$dir_b" "$dir_c"

  tmux kill-server
  "$restore_state" --session-name work --yes >/dev/null

  wait_for_session work || fail "session did not restore when pane cwd paths were missing"
  window_count="$(tmux list-windows -t work | wc -l | tr -d ' ')"
  window_summary="$(tmux list-windows -t work -F '#{window_panes}:#{window_name}')"
  assert_eq "2" "$window_count" "window count preserved with missing cwd paths"
  assert_contains "$window_summary" "2:" "restored split window preserved with missing cwd paths"
  assert_contains "$window_summary" "1:extra" "restored extra window preserved with missing cwd paths"
}

@test "two window layout restore scenario" {
  zdotdir="$case_root/zdotdir"
  save_test_shell_env
  session_name="layout-check"
  src_root="$case_root/src"
  start_dir="$src_root/start"
  tail_dir="$src_root/logs"
  nvim_dir="$src_root/editor"
  ls_dir="$src_root/listing"
  start_file="$start_dir/start.txt"
  tail_file="$tail_dir/backtrace.log"
  other_file="$nvim_dir/other.txt"
  nvim_socket_one="$case_root/window1-pane1.sock"
  nvim_socket_two="$case_root/window2-pane1.sock"

  mkdir -p "$start_dir" "$tail_dir" "$nvim_dir" "$ls_dir"
  setup_test_zsh_env "$zdotdir" ': 1700000000:0;echo two-window-layout-history'
  seq 1 25 >"$start_file"
  printf 'tail-seed\n' >"$tail_file"
  seq 101 125 >"$other_file"
  printf 'alpha.txt\nbeta.txt\n' >"$ls_dir/alpha.txt"
  printf 'listing fixture\n' >"$ls_dir/beta.txt"

  tmux new-session -d -s "$session_name" -c "$start_dir"
  window1_index="$(tmux list-windows -t "$session_name" -F '#{window_index}' | head -n 1)"
  tmux rename-window -t "$session_name:$window1_index" "editor-and-tail"
  tmux split-window -d -v -t "$session_name:$window1_index" -c "$tail_dir"

  window2_index="$(tmux new-window -d -P -F '#{window_index}' -t "$session_name:" -n "editor-and-ls" -c "$nvim_dir")"
  tmux split-window -d -h -t "$session_name:$window2_index" -c "$ls_dir"

  window1_pane1="$(nth_pane_id "$session_name:$window1_index" 1)"
  window1_pane2="$(nth_pane_id "$session_name:$window1_index" 2)"
  window2_pane1="$(nth_pane_id "$session_name:$window2_index" 1)"
  window2_pane2="$(nth_pane_id "$session_name:$window2_index" 2)"

  "$real_nvim" --headless -u NONE -i NONE \
    --cmd "lua package.path = package.path .. ';$repo_root/nvim/lua/?.lua;$repo_root/nvim/lua/?/init.lua'" \
    --listen "$nvim_socket_one" "$start_file" >/dev/null 2>&1 &
  nvim_pid_one=$!
  wait_for_nvim_expr "$nvim_socket_one" 'expand("%:p")' "$start_file" || fail "window1 pane1 nvim did not open start file"
  nvim --server "$nvim_socket_one" --remote-expr "execute('call cursor(9,1)')" >/dev/null
  wait_for_nvim_expr "$nvim_socket_one" 'line(".")' "9" || fail "window1 pane1 nvim did not move to line 9"
  "$repo_root/tmux/send_to_nvim/register_nvim_instance.sh" "$window1_pane1" "$nvim_socket_one" "$nvim_pid_one" "$start_dir"

  "$real_nvim" --headless -u NONE -i NONE \
    --cmd "lua package.path = package.path .. ';$repo_root/nvim/lua/?.lua;$repo_root/nvim/lua/?/init.lua'" \
    --listen "$nvim_socket_two" "$other_file" >/dev/null 2>&1 &
  nvim_pid_two=$!
  wait_for_nvim_expr "$nvim_socket_two" 'expand("%:p")' "$other_file" || fail "window2 pane1 nvim did not open other file"
  nvim --server "$nvim_socket_two" --remote-expr "execute('call cursor(6,1)')" >/dev/null
  wait_for_nvim_expr "$nvim_socket_two" 'line(".")' "6" || fail "window2 pane1 nvim did not move to line 6"
  "$repo_root/tmux/send_to_nvim/register_nvim_instance.sh" "$window2_pane1" "$nvim_socket_two" "$nvim_pid_two" "$nvim_dir"

  tmux send-keys -t "$window1_pane2" "cd $(printf '%q' "$tail_dir") && tail -f $(printf '%q' "$tail_file")" C-m
  wait_for_pane_command "$window1_pane2" tail 60 0.25 || fail "window1 pane2 did not start tail before save"
  for i in $(seq 1 10); do
    printf 'tail-stream-%02d\n' "$i" >>"$tail_file"
  done

  tmux send-keys -t "$window2_pane2" "cd $(printf '%q' "$ls_dir") && ls" C-m
  sleep 1

  "$save_state" --reason test-two-window-layout-restore-scenario

  kill "$nvim_pid_one" >/dev/null 2>&1 || true
  kill "$nvim_pid_two" >/dev/null 2>&1 || true
  wait_for_pid_exit "$nvim_pid_one" 20 0.1 || true
  wait_for_pid_exit "$nvim_pid_two" 20 0.1 || true

  tmux kill-server
  rm -f "$TMUX_TEST_ATTACH_LOG" "$TMUX_TEST_SWITCH_LOG" "$TMUX_TEST_NVIM_RESTORE_LOG"
  "$restore_state" --session-name "$session_name" --attach --yes >/dev/null

  wait_for_file "$TMUX_TEST_ATTACH_LOG" || fail "attach log was not created for two-window layout scenario"
  attach_cmd="$(cat "$TMUX_TEST_ATTACH_LOG")"
  assert_contains "$attach_cmd" "attach-session -t =$session_name" "two-window layout attach target"
  wait_for_session "$session_name" || fail "session $session_name did not restore in two-window layout scenario"

  window_summary="$(tmux list-windows -t "$session_name" -F 'window=#{window_index} panes=#{window_panes} name=#{window_name}')"
  assert_contains "$window_summary" "panes=2 name=editor-and-tail" "window 1 restored with 2 panes"
  assert_contains "$window_summary" "panes=2 name=editor-and-ls" "window 2 restored with 2 panes"

  restored_w1p1="$(nth_pane_id "$session_name:$window1_index" 1)"
  restored_w1p2="$(nth_pane_id "$session_name:$window1_index" 2)"
  restored_w2p1="$(nth_pane_id "$session_name:$window2_index" 1)"
  restored_w2p2="$(nth_pane_id "$session_name:$window2_index" 2)"

  wait_for_file "$TMUX_TEST_NVIM_RESTORE_LOG" 60 0.25 || fail "nvim restore log was not produced in two-window layout scenario"
  wait_for_pane_text "$restored_w2p2" "alpha.txt" 60 0.25 || fail "window2 pane2 ls output was not restored"

  assert_eq "$start_dir" "$(tmux display-message -p -t "$restored_w1p1" '#{pane_current_path}')" "window1 pane1 cwd"
  assert_eq "$tail_dir" "$(tmux display-message -p -t "$restored_w1p2" '#{pane_current_path}')" "window1 pane2 cwd"
  assert_eq "$nvim_dir" "$(tmux display-message -p -t "$restored_w2p1" '#{pane_current_path}')" "window2 pane1 cwd"
  assert_eq "$ls_dir" "$(tmux display-message -p -t "$restored_w2p2" '#{pane_current_path}')" "window2 pane2 cwd"

  w1p1_left="$(tmux display-message -p -t "$restored_w1p1" '#{pane_left}')"
  w1p2_left="$(tmux display-message -p -t "$restored_w1p2" '#{pane_left}')"
  w1p1_top="$(tmux display-message -p -t "$restored_w1p1" '#{pane_top}')"
  w1p2_top="$(tmux display-message -p -t "$restored_w1p2" '#{pane_top}')"
  assert_eq "$w1p1_left" "$w1p2_left" "window1 vertical split keeps panes in same column"
  [ "$w1p1_top" != "$w1p2_top" ] || fail "window1 vertical split should stack panes top/bottom"

  w2p1_left="$(tmux display-message -p -t "$restored_w2p1" '#{pane_left}')"
  w2p2_left="$(tmux display-message -p -t "$restored_w2p2" '#{pane_left}')"
  w2p1_top="$(tmux display-message -p -t "$restored_w2p1" '#{pane_top}')"
  w2p2_top="$(tmux display-message -p -t "$restored_w2p2" '#{pane_top}')"
  assert_eq "$w2p1_top" "$w2p2_top" "window2 horizontal split keeps panes on same row"
  [ "$w2p1_left" != "$w2p2_left" ] || fail "window2 horizontal split should place panes side-by-side"

  printf 'tail-after\n' >>"$tail_file"
  sleep 1
  assert_contains "$(tmux capture-pane -p -S -80 -t "$restored_w1p2")" "tail-after" "window1 pane2 resumed tail output"

  restore_test_shell_env
}

@test "three window mixed restore scenario" {
  zdotdir="$case_root/zdotdir"
  save_test_shell_env
  session_name="37"
  src_root="$case_root/src"
  dir_alpha="$src_root/alpha"
  dir_beta="$src_root/beta"
  dir_gamma="$src_root/gamma"
  dir_delta="$src_root/delta"
  file_alpha="$dir_alpha/alpha.txt"
  file_beta="$dir_beta/beta.log"
  file_gamma="$dir_gamma/gamma.txt"
  file_delta="$dir_delta/delta.log"
  nvim_socket_one="$case_root/window1-pane1.sock"
  nvim_socket_two="$case_root/window2-pane1.sock"

  mkdir -p "$dir_alpha" "$dir_beta" "$dir_gamma" "$dir_delta"
  setup_test_zsh_env "$zdotdir" ': 1700000000:0;echo mixed-session-history'
  seq 1 30 >"$file_alpha"
  printf 'beta-seed\n' >"$file_beta"
  seq 101 130 >"$file_gamma"
  printf 'delta-seed\n' >"$file_delta"

  tmux new-session -d -s "$session_name" -c "$src_root"
  window1_index="$(tmux list-windows -t "$session_name" -F '#{window_index}' | head -n 1)"
  tmux rename-window -t "$session_name:$window1_index" "window-1"
  tmux split-window -d -t "$session_name:$window1_index" -c "$dir_beta"

  window2_index="$(tmux new-window -d -P -F '#{window_index}' -t "$session_name:" -n "window-2" -c "$src_root")"
  tmux split-window -d -t "$session_name:$window2_index" -c "$dir_gamma"
  tmux select-layout -t "$session_name:$window2_index" even-vertical >/dev/null 2>&1 || true

  window3_index="$(tmux new-window -d -P -F '#{window_index}' -t "$session_name:" -n "window-3" -c "$dir_delta")"

  window1_pane1="$(nth_pane_id "$session_name:$window1_index" 1)"
  window1_pane2="$(nth_pane_id "$session_name:$window1_index" 2)"
  window2_pane1="$(nth_pane_id "$session_name:$window2_index" 1)"
  window2_pane2="$(nth_pane_id "$session_name:$window2_index" 2)"
  window3_pane1="$(nth_pane_id "$session_name:$window3_index" 1)"

  "$real_nvim" --headless -u NONE -i NONE \
    --cmd "lua package.path = package.path .. ';$repo_root/nvim/lua/?.lua;$repo_root/nvim/lua/?/init.lua'" \
    --listen "$nvim_socket_one" "$file_alpha" >/dev/null 2>&1 &
  nvim_pid_one=$!
  wait_for_nvim_expr "$nvim_socket_one" 'expand("%:p")' "$file_alpha" || fail "window1 pane1 nvim did not open alpha file"
  nvim --server "$nvim_socket_one" --remote-expr "execute('call cursor(12,1)')" >/dev/null
  wait_for_nvim_expr "$nvim_socket_one" 'line(".")' "12" || fail "window1 pane1 nvim did not move to line 12"
  "$repo_root/tmux/send_to_nvim/register_nvim_instance.sh" "$window1_pane1" "$nvim_socket_one" "$nvim_pid_one" "$dir_alpha"

  "$real_nvim" --headless -u NONE -i NONE \
    --cmd "lua package.path = package.path .. ';$repo_root/nvim/lua/?.lua;$repo_root/nvim/lua/?/init.lua'" \
    --listen "$nvim_socket_two" "$file_gamma" >/dev/null 2>&1 &
  nvim_pid_two=$!
  wait_for_nvim_expr "$nvim_socket_two" 'expand("%:p")' "$file_gamma" || fail "window2 pane1 nvim did not open gamma file"
  nvim --server "$nvim_socket_two" --remote-expr "execute('call cursor(7,1)')" >/dev/null
  wait_for_nvim_expr "$nvim_socket_two" 'line(".")' "7" || fail "window2 pane1 nvim did not move to line 7"
  "$repo_root/tmux/send_to_nvim/register_nvim_instance.sh" "$window2_pane1" "$nvim_socket_two" "$nvim_pid_two" "$dir_gamma"

  tmux send-keys -t "$window1_pane2" "cd $(printf '%q' "$dir_beta") && tail -f $(printf '%q' "$file_beta")" C-m
  wait_for_pane_command "$window1_pane2" tail 60 0.25 || fail "window1 pane2 did not start tail before save"
  for i in $(seq 1 15); do
    printf 'beta-stream-%02d\n' "$i" >>"$file_beta"
  done

  tmux send-keys -t "$window2_pane2" "cd $(printf '%q' "$dir_gamma") && ls" C-m
  sleep 1

  tmux send-keys -t "$window3_pane1" "cd $(printf '%q' "$dir_delta") && tail -f $(printf '%q' "$file_delta")" C-m
  wait_for_pane_command "$window3_pane1" tail 60 0.25 || fail "window3 pane1 did not start tail before save"
  for i in $(seq 1 12); do
    printf 'delta-stream-%02d\n' "$i" >>"$file_delta"
  done
  sleep 1

  "$save_state" --reason test-three-window-mixed-restore-scenario

  kill "$nvim_pid_one" >/dev/null 2>&1 || true
  kill "$nvim_pid_two" >/dev/null 2>&1 || true
  wait_for_pid_exit "$nvim_pid_one" 20 0.1 || true
  wait_for_pid_exit "$nvim_pid_two" 20 0.1 || true

  tmux kill-server
  rm -f "$TMUX_TEST_ATTACH_LOG" "$TMUX_TEST_SWITCH_LOG" "$TMUX_TEST_NVIM_RESTORE_LOG"
  "$restore_state" --session-name "$session_name" --attach --yes >/dev/null

  wait_for_file "$TMUX_TEST_ATTACH_LOG" || fail "attach log was not created for mixed restore scenario"
  attach_cmd="$(cat "$TMUX_TEST_ATTACH_LOG")"
  assert_contains "$attach_cmd" "attach-session -t =$session_name" "mixed restore attach target"
  wait_for_session "$session_name" || fail "session $session_name did not restore in mixed scenario"

  window_summary="$(tmux list-windows -t "$session_name" -F 'window=#{window_index} panes=#{window_panes} name=#{window_name}')"
  assert_contains "$window_summary" "panes=2 name=window-1" "window 1 restored with 2 panes"
  assert_contains "$window_summary" "panes=2 name=window-2" "window 2 restored with 2 panes"
  assert_contains "$window_summary" "panes=1 name=window-3" "window 3 restored with 1 pane"

  restored_w1p1="$(nth_pane_id "$session_name:$window1_index" 1)"
  restored_w1p2="$(nth_pane_id "$session_name:$window1_index" 2)"
  restored_w2p1="$(nth_pane_id "$session_name:$window2_index" 1)"
  restored_w2p2="$(nth_pane_id "$session_name:$window2_index" 2)"
  restored_w3p1="$(nth_pane_id "$session_name:$window3_index" 1)"

  wait_for_pane_text "$restored_w2p2" "$(basename "$file_gamma")" 60 0.25 || fail "window2 pane2 ls output was not restored"
  wait_for_file "$TMUX_TEST_NVIM_RESTORE_LOG" 60 0.25 || fail "nvim restore log was not produced in mixed scenario"

  assert_eq "$dir_alpha" "$(tmux display-message -p -t "$restored_w1p1" '#{pane_current_path}')" "window1 pane1 cwd"
  assert_eq "$dir_beta" "$(tmux display-message -p -t "$restored_w1p2" '#{pane_current_path}')" "window1 pane2 cwd"
  assert_eq "$dir_gamma" "$(tmux display-message -p -t "$restored_w2p1" '#{pane_current_path}')" "window2 pane1 cwd"
  assert_eq "$dir_gamma" "$(tmux display-message -p -t "$restored_w2p2" '#{pane_current_path}')" "window2 pane2 cwd"
  assert_eq "$dir_delta" "$(tmux display-message -p -t "$restored_w3p1" '#{pane_current_path}')" "window3 pane1 cwd"

  printf 'beta-after\n' >>"$file_beta"
  printf 'delta-after\n' >>"$file_delta"
  sleep 1
  assert_contains "$(tmux capture-pane -p -S -80 -t "$restored_w1p2")" "beta-after" "window1 pane2 resumed tail output"
  assert_contains "$(tmux capture-pane -p -S -80 -t "$restored_w3p1")" "delta-after" "window3 pane1 resumed tail output"

  restore_test_shell_env
}
