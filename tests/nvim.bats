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

@test "nvim snapshot and direct restore" {
  sample_dir="$(cd "$case_root" && pwd -P)"
  file_a="$sample_dir/file-a.txt"
  file_b="$sample_dir/file-b.txt"
  file_c="$sample_dir/file-c.txt"
  nvim_socket="$case_root/headless-nvim.sock"
  restore_report="$case_root/restore-report.json"

  seq 1 20 >"$file_a"
  seq 101 120 >"$file_b"
  seq 201 220 >"$file_c"

  tmux new-session -d -s work
  pane_id="$(tmux list-panes -t work -F '#{pane_id}' | head -n 1)"
  "$real_nvim" --headless -u NONE -i NONE \
    --cmd "lua package.path = package.path .. ';$repo_root/nvim/lua/?.lua;$repo_root/nvim/lua/?/init.lua'" \
    --listen "$nvim_socket" "$file_a" >/dev/null 2>&1 &
  nvim_pid=$!

  wait_for_nvim_expr "$nvim_socket" 'expand("%:p")' "$file_a" || fail "headless nvim did not open first file in time"
  nvim --server "$nvim_socket" --remote-expr "execute('call cursor(12,1)')" >/dev/null
  wait_for_nvim_expr "$nvim_socket" 'line(".")' "12" || fail "headless nvim did not move first cursor to line 12"
  nvim --server "$nvim_socket" --remote-expr "execute('vsplit $file_b | call cursor(7,1)')" >/dev/null
  wait_for_nvim_expr "$nvim_socket" 'expand("%:p")' "$file_b" || fail "headless nvim did not open split file in time"
  wait_for_nvim_expr "$nvim_socket" 'line(".")' "7" || fail "headless nvim did not move split cursor to line 7"
  nvim --server "$nvim_socket" --remote-expr "execute('tabnew $file_c | call cursor(5,1)')" >/dev/null
  wait_for_nvim_expr "$nvim_socket" 'tabpagenr()' "2" || fail "headless nvim did not create second tab"
  wait_for_nvim_expr "$nvim_socket" 'expand("%:p")' "$file_c" || fail "headless nvim did not open second tab file in time"
  wait_for_nvim_expr "$nvim_socket" 'line(".")' "5" || fail "headless nvim did not move second tab cursor to line 5"

  "$repo_root/tmux/send_to_nvim/register_nvim_instance.sh" "$pane_id" "$nvim_socket" "$nvim_pid" "$(dirname "$file_a")"
  "$save_state" --reason test-nvim-restore
  manifest="$(latest_manifest)"
  nvim_state_ref="$(jq -r '.sessions[0].windows[0].panes[0].nvim_state_ref' "$manifest")"
  [ -f "$nvim_state_ref" ] || fail "nvim state file was not written"
  session_file="$(jq -r '.session_file // ""' "$nvim_state_ref")"
  resolved_session_file="$(dirname "$nvim_state_ref")/session.vim"

  tab_count="$(jq '.tabs | length' "$nvim_state_ref")"
  current_tab="$(jq -r '.current_tab' "$nvim_state_ref")"
  first_layout_kind="$(jq -r '.tabs[0].layout.kind // ""' "$nvim_state_ref")"
  first_win_count="$(jq -r '.tabs[0].wins | length' "$nvim_state_ref")"
  first_tab_a_line="$(jq -r --arg path "$file_a" '.tabs[0].wins[] | select(.path == $path) | .cursor[0]' "$nvim_state_ref")"
  first_tab_b_line="$(jq -r --arg path "$file_b" '.tabs[0].wins[] | select(.path == $path) | .cursor[0]' "$nvim_state_ref")"
  second_path="$(jq -r '.tabs[1].wins[0].path // ""' "$nvim_state_ref")"
  second_line="$(jq -r '.tabs[1].wins[0].cursor[0] // 0' "$nvim_state_ref")"

  assert_eq "2" "$tab_count" "saved nvim tab count"
  assert_eq "2" "$current_tab" "saved nvim current tab"
  assert_eq "row" "$first_layout_kind" "saved first tab layout kind"
  assert_eq "2" "$first_win_count" "saved first tab window count"
  assert_eq "12" "$first_tab_a_line" "saved first tab file-a line"
  assert_eq "7" "$first_tab_b_line" "saved first tab file-b line"
  [ -n "$session_file" ] || fail "nvim session file path was not recorded"
  [ -f "$resolved_session_file" ] || fail "nvim session file was not written"
  assert_eq "$file_c" "$second_path" "saved second tab file path"
  assert_eq "5" "$second_line" "saved second tab file line"

  kill "$nvim_pid" >/dev/null 2>&1 || true
  if ! wait_for_pid_exit "$nvim_pid" 20 0.1; then
    kill -9 "$nvim_pid" >/dev/null 2>&1 || true
    wait_for_pid_exit "$nvim_pid" 20 0.1 || true
  fi
  rm -f "$XDG_STATE_HOME/nvim/swap/"* 2>/dev/null || true

  cat >"$case_root/restore-check.lua" <<EOF
package.path = package.path .. ';$repo_root/nvim/lua/?.lua;$repo_root/nvim/lua/?/init.lua'
local send = dofile("$repo_root/nvim/lua/core/send_to_nvim.lua")
assert(send.restore_from_state_file("$nvim_state_ref"))
local tabs = {}
for index, tab in ipairs(vim.api.nvim_list_tabpages()) do
  local wins = {}
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(tab)) do
    local buf = vim.api.nvim_win_get_buf(win)
    table.insert(wins, {
      path = vim.api.nvim_buf_get_name(buf),
      line = vim.api.nvim_win_get_cursor(win)[1],
    })
  end
  tabs[index] = {
    layout_kind = (vim.fn.winlayout(index)[1] or ""),
    win_count = #wins,
    wins = wins,
  }
end
local report = {
  current_tab = vim.fn.tabpagenr(),
  tab_count = #vim.api.nvim_list_tabpages(),
  current_path = vim.api.nvim_buf_get_name(0),
  current_line = vim.fn.line("."),
  tabs = tabs,
}
vim.fn.writefile({ vim.json.encode(report) }, "$restore_report")
EOF
  run_headless_nvim_script "$case_root/restore-check.lua"

  restored_current_tab="$(jq -r '.current_tab' "$restore_report")"
  restored_tab_count="$(jq -r '.tab_count' "$restore_report")"
  restored_current_path="$(jq -r '.current_path' "$restore_report")"
  restored_current_line="$(jq -r '.current_line' "$restore_report")"
  restored_tab1_layout_kind="$(jq -r '.tabs[0].layout_kind // ""' "$restore_report")"
  restored_tab1_win_count="$(jq -r '.tabs[0].win_count // 0' "$restore_report")"
  restored_tab1_a_line="$(jq -r --arg path "$file_a" '.tabs[0].wins[] | select(.path == $path) | .line' "$restore_report")"
  restored_tab1_b_line="$(jq -r --arg path "$file_b" '.tabs[0].wins[] | select(.path == $path) | .line' "$restore_report")"
  restored_tab2_path="$(jq -r '.tabs[1].wins[0].path // ""' "$restore_report")"
  restored_tab2_line="$(jq -r '.tabs[1].wins[0].line // 0' "$restore_report")"

  assert_eq "2" "$restored_tab_count" "restored tab count"
  assert_eq "2" "$restored_current_tab" "restored current tab"
  assert_eq "$file_c" "$restored_current_path" "restored current path"
  assert_eq "5" "$restored_current_line" "restored current line"
  assert_eq "row" "$restored_tab1_layout_kind" "restored first tab layout kind"
  assert_eq "2" "$restored_tab1_win_count" "restored first tab window count"
  assert_eq "12" "$restored_tab1_a_line" "restored tab1 file-a line"
  assert_eq "7" "$restored_tab1_b_line" "restored tab1 file-b line"
  assert_eq "$file_c" "$restored_tab2_path" "restored tab2 path"
  assert_eq "5" "$restored_tab2_line" "restored tab2 line"
}

@test "nvim restore via tmux restore" {
  sample_dir="$(cd "$case_root" && pwd -P)"
  file_a="$sample_dir/file-a.txt"
  file_b="$sample_dir/file-b.txt"
  file_c="$sample_dir/file-c.txt"
  nvim_socket="$case_root/headless-nvim.sock"
  zdotdir="$case_root/zdotdir"
  save_test_shell_env
  setup_test_zsh_env "$zdotdir"

  seq 1 20 >"$file_a"
  seq 101 120 >"$file_b"
  seq 201 220 >"$file_c"

  tmux new-session -d -s work
  pane_id="$(tmux list-panes -t work -F '#{pane_id}' | head -n 1)"
  "$real_nvim" --headless -u NONE -i NONE \
    --cmd "lua package.path = package.path .. ';$repo_root/nvim/lua/?.lua;$repo_root/nvim/lua/?/init.lua'" \
    --listen "$nvim_socket" "$file_a" >/dev/null 2>&1 &
  nvim_pid=$!

  wait_for_nvim_expr "$nvim_socket" 'expand("%:p")' "$file_a" || fail "headless nvim did not open first file in time"
  nvim --server "$nvim_socket" --remote-expr "execute('call cursor(12,1)')" >/dev/null
  wait_for_nvim_expr "$nvim_socket" 'line(".")' "12" || fail "headless nvim did not move first cursor to line 12"
  nvim --server "$nvim_socket" --remote-expr "execute('vsplit $file_b | call cursor(7,1)')" >/dev/null
  wait_for_nvim_expr "$nvim_socket" 'expand("%:p")' "$file_b" || fail "headless nvim did not open split file in time"
  wait_for_nvim_expr "$nvim_socket" 'line(".")' "7" || fail "headless nvim did not move split cursor to line 7"
  nvim --server "$nvim_socket" --remote-expr "execute('tabnew $file_c | call cursor(5,1)')" >/dev/null
  wait_for_nvim_expr "$nvim_socket" 'tabpagenr()' "2" || fail "headless nvim did not create second tab"
  wait_for_nvim_expr "$nvim_socket" 'expand("%:p")' "$file_c" || fail "headless nvim did not open second tab file in time"
  wait_for_nvim_expr "$nvim_socket" 'line(".")' "5" || fail "headless nvim did not move second tab cursor to line 5"

  "$repo_root/tmux/send_to_nvim/register_nvim_instance.sh" "$pane_id" "$nvim_socket" "$nvim_pid" "$(dirname "$file_a")"
  "$save_state" --reason test-nvim-tmux-restore
  rm -f "$TMUX_TEST_NVIM_RESTORE_LOG"

  kill "$nvim_pid" >/dev/null 2>&1 || true
  if ! wait_for_pid_exit "$nvim_pid" 20 0.1; then
    kill -9 "$nvim_pid" >/dev/null 2>&1 || true
    wait_for_pid_exit "$nvim_pid" 20 0.1 || true
  fi
  rm -f "$XDG_STATE_HOME/nvim/swap/"* 2>/dev/null || true

  tmux kill-server
  "$restore_state" --session-name work --yes >/dev/null

  wait_for_file "$TMUX_TEST_NVIM_RESTORE_LOG" 60 0.25 || fail "tmux restore did not relaunch nvim with restore state"
  restored_tab_count="$(jq -r '.tab_count' "$TMUX_TEST_NVIM_RESTORE_LOG")"
  restored_current_tab="$(jq -r '.current_tab' "$TMUX_TEST_NVIM_RESTORE_LOG")"
  restored_current_path="$(jq -r '.current_path' "$TMUX_TEST_NVIM_RESTORE_LOG")"
  restored_current_line="$(jq -r '.current_line' "$TMUX_TEST_NVIM_RESTORE_LOG")"
  restored_session_file="$(jq -r '.session_file // ""' "$TMUX_TEST_NVIM_RESTORE_LOG")"
  restored_first_tab_a_line="$(jq -r '.first_tab_a_line // 0' "$TMUX_TEST_NVIM_RESTORE_LOG")"
  restored_first_tab_b_line="$(jq -r '.first_tab_b_line // 0' "$TMUX_TEST_NVIM_RESTORE_LOG")"
  restored_first_tab_layout_kind="$(jq -r '.first_tab_layout_kind // ""' "$TMUX_TEST_NVIM_RESTORE_LOG")"
  restored_first_tab_win_count="$(jq -r '.first_tab_win_count // 0' "$TMUX_TEST_NVIM_RESTORE_LOG")"

  assert_eq "2" "$restored_tab_count" "tmux-restored nvim tab count"
  assert_eq "2" "$restored_current_tab" "tmux-restored nvim current tab"
  assert_eq "$file_c" "$restored_current_path" "tmux-restored nvim current path"
  assert_eq "5" "$restored_current_line" "tmux-restored nvim current line"
  [ -n "$restored_session_file" ] || fail "tmux-restored nvim state did not include session file"
  assert_eq "12" "$restored_first_tab_a_line" "tmux-restored nvim first tab file-a line"
  assert_eq "7" "$restored_first_tab_b_line" "tmux-restored nvim first tab file-b line"
  assert_eq "row" "$restored_first_tab_layout_kind" "tmux-restored nvim first tab layout kind"
  assert_eq "2" "$restored_first_tab_win_count" "tmux-restored nvim first tab window count"

  restore_test_shell_env
}

@test "nvim persistence policy" {
  file_path="$case_root/persist.txt"
  echo "one" >"$file_path"
  report_path="$case_root/persist-report.json"

  cat >"$case_root/persist-check.lua" <<EOF
package.path = package.path .. ';$repo_root/nvim/lua/?.lua;$repo_root/nvim/lua/?/init.lua'
dofile("$repo_root/nvim/lua/core/options.lua")
dofile("$repo_root/nvim/lua/core/autocmds.lua")
vim.cmd("edit $file_path")
vim.api.nvim_buf_set_lines(0, 0, -1, false, { "insert-leave-save" })
vim.api.nvim_exec_autocmds("InsertLeave", { buffer = 0 })
vim.wait(1000, function()
  local lines = vim.fn.readfile("$file_path")
  return lines[1] == "insert-leave-save"
end, 50)
vim.api.nvim_buf_set_lines(0, 0, -1, false, { "text-changed-save" })
vim.api.nvim_exec_autocmds("TextChanged", { buffer = 0 })
vim.wait(2500, function()
  local lines = vim.fn.readfile("$file_path")
  return lines[1] == "text-changed-save"
end, 50)
local report = {
  swapfile = vim.o.swapfile,
  undofile = vim.o.undofile,
  undodir = vim.o.undodir,
  directory = vim.o.directory,
  saved_line = vim.fn.readfile("$file_path")[1],
}
vim.fn.writefile({ vim.json.encode(report) }, "$report_path")
EOF
  run_headless_nvim_script "$case_root/persist-check.lua"

  assert_eq "true" "$(jq -r '.swapfile' "$report_path")" "swapfile option"
  assert_eq "true" "$(jq -r '.undofile' "$report_path")" "undofile option"
  assert_contains "$(jq -r '.undodir' "$report_path")" "/undo" "undodir path"
  assert_contains "$(jq -r '.directory' "$report_path")" "/swap" "swap directory path"
  assert_eq "text-changed-save" "$(jq -r '.saved_line' "$report_path")" "autosaved file contents"
}

@test "nvim unsupported metadata" {
  file_path="$case_root/unsupported.txt"
  export_path="$case_root/unsupported-meta.json"
  notify_path="$case_root/restore-notify.txt"
  echo "one" >"$file_path"

  cat >"$case_root/unsupported-check.lua" <<EOF
package.path = package.path .. ';$repo_root/nvim/lua/?.lua;$repo_root/nvim/lua/?/init.lua'
local send = dofile("$repo_root/nvim/lua/core/send_to_nvim.lua")
vim.cmd("edit $file_path")
vim.api.nvim_buf_set_lines(0, 0, -1, false, { "dirty-change" })
vim.fn.setqflist({ { filename = "$file_path", lnum = 1, text = "qf" } })
vim.fn.setloclist(0, { { filename = "$file_path", lnum = 1, text = "loc" } })
vim.cmd("enew")
vim.bo.buftype = "nofile"
vim.bo.buflisted = true
send.export_restore_state("$export_path")
vim.notify = function(msg, level)
  vim.fn.writefile({ msg }, "$notify_path")
end
send.restore_from_state_file("$export_path")
vim.wait(1000, function()
  return vim.fn.filereadable("$notify_path") == 1
end, 50)
EOF
  run_headless_nvim_script "$case_root/unsupported-check.lua"

  dirty_count="$(jq '.dirty_buffers | length' "$export_path")"
  special_count="$(jq '.unsupported.special_buffers | length' "$export_path")"
  quickfix_size="$(jq -r '.unsupported.quickfix_size' "$export_path")"
  loclist_count="$(jq '.unsupported.loclist_windows | length' "$export_path")"
  notify_message="$(cat "$notify_path")"

  [ "$dirty_count" -gt 0 ] || fail "dirty buffers were not recorded"
  [ "$special_count" -gt 0 ] || fail "special buffers were not recorded"
  [ "$quickfix_size" -gt 0 ] || fail "quickfix size was not recorded"
  [ "$loclist_count" -gt 0 ] || fail "location list windows were not recorded"
  assert_contains "$notify_message" "restored file-backed state only" "unsupported state warning prefix"
  assert_contains "$notify_message" "dirty buffer" "unsupported state warning dirty buffers"
  assert_contains "$notify_message" "quickfix list" "unsupported state warning quickfix"
}
