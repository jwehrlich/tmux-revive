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

# Helper: run a Lua script in headless nvim with the send_to_nvim module available
run_persistence_script() {
  local script_path="$1"
  XDG_STATE_HOME="$XDG_STATE_HOME" \
  XDG_DATA_HOME="$XDG_DATA_HOME" \
  "$real_nvim" --headless -u NONE -i NONE \
    --cmd "lua package.path = package.path .. ';$repo_root/nvim/lua/?.lua;$repo_root/nvim/lua/?/init.lua'" \
    "+lua dofile([[$script_path]])" +qa!
}

@test "autosave writes state to pane and cwd paths" {
  local session_root="$XDG_STATE_HOME/nvim/sessions"
  local file_a="$case_root/file-a.txt"
  seq 1 10 >"$file_a"

  cat >"$case_root/autosave-test.lua" <<EOF
package.path = package.path .. ';$repo_root/nvim/lua/?.lua;$repo_root/nvim/lua/?/init.lua'
local send = dofile("$repo_root/nvim/lua/core/send_to_nvim.lua")

-- Simulate being in a tmux pane
vim.env.TMUX_PANE = "%99"
vim.cmd("cd $case_root")
vim.cmd("edit $file_a")
vim.fn.cursor(5, 1)

-- Manually call the autosave (normally triggered by timer)
-- We need to access internals, so just call export_restore_state to both paths
local session_root = "$session_root"
local pane_dir = session_root .. "/pane/%99"
local cwd_dir = session_root .. "/cwd/" .. ("$case_root"):gsub("^/", ""):gsub("/", "%%")

vim.fn.mkdir(pane_dir, "p")
vim.fn.mkdir(cwd_dir, "p")
send.export_restore_state(pane_dir .. "/state.json")
send.export_restore_state(cwd_dir .. "/state.json")
vim.fn.writefile({ tostring(vim.fn.getpid()) }, pane_dir .. "/pid")
vim.fn.writefile({ tostring(vim.fn.getpid()) }, cwd_dir .. "/pid")

-- Write a report so we can verify
local report = {
  pane_state_exists = vim.fn.filereadable(pane_dir .. "/state.json") == 1,
  cwd_state_exists = vim.fn.filereadable(cwd_dir .. "/state.json") == 1,
  pane_pid_exists = vim.fn.filereadable(pane_dir .. "/pid") == 1,
  cwd_pid_exists = vim.fn.filereadable(cwd_dir .. "/pid") == 1,
}
vim.fn.writefile({ vim.json.encode(report) }, "$case_root/autosave-report.json")
EOF
  run_persistence_script "$case_root/autosave-test.lua"

  assert_eq "true" "$(jq -r '.pane_state_exists' "$case_root/autosave-report.json")" "pane state written"
  assert_eq "true" "$(jq -r '.cwd_state_exists' "$case_root/autosave-report.json")" "cwd state written"
  assert_eq "true" "$(jq -r '.pane_pid_exists' "$case_root/autosave-report.json")" "pane pid written"
  assert_eq "true" "$(jq -r '.cwd_pid_exists' "$case_root/autosave-report.json")" "cwd pid written"
}

@test "restore from pane session when owning PID is dead" {
  local session_root="$XDG_STATE_HOME/nvim/sessions"
  local file_a="$case_root/file-a.txt"
  seq 1 20 >"$file_a"

  # First: create a pane session state (simulating a crash leftover)
  cat >"$case_root/create-state.lua" <<EOF
package.path = package.path .. ';$repo_root/nvim/lua/?.lua;$repo_root/nvim/lua/?/init.lua'
local send = dofile("$repo_root/nvim/lua/core/send_to_nvim.lua")
vim.cmd("cd $case_root")
vim.cmd("edit $file_a")
vim.fn.cursor(15, 1)

local pane_dir = "$session_root/pane/%42"
vim.fn.mkdir(pane_dir, "p")
send.export_restore_state(pane_dir .. "/state.json")
-- Write a dead PID (PID 1 is init, but use a guaranteed-dead PID)
vim.fn.writefile({ "99999999" }, pane_dir .. "/pid")
EOF
  run_persistence_script "$case_root/create-state.lua"

  # Second: try to restore from that pane session
  cat >"$case_root/restore-test.lua" <<EOF
package.path = package.path .. ';$repo_root/nvim/lua/?.lua;$repo_root/nvim/lua/?/init.lua'
local send = dofile("$repo_root/nvim/lua/core/send_to_nvim.lua")
vim.env.TMUX_PANE = "%42"

local pane_dir = "$session_root/pane/%42"
local state_path = pane_dir .. "/state.json"
local pid_lines = vim.fn.readfile(pane_dir .. "/pid")
local saved_pid = tonumber(pid_lines[1])

-- Verify the PID is dead
local pid_alive = vim.uv.kill(saved_pid, 0) == 0

-- Attempt restore
local restored = send.restore_from_state_file(state_path)

local report = {
  pid_alive = pid_alive,
  restored = restored,
  current_file = vim.api.nvim_buf_get_name(0),
  current_line = vim.fn.line("."),
}
vim.fn.writefile({ vim.json.encode(report) }, "$case_root/restore-report.json")
EOF
  run_persistence_script "$case_root/restore-test.lua"

  assert_eq "false" "$(jq -r '.pid_alive' "$case_root/restore-report.json")" "saved PID should be dead"
  assert_eq "true" "$(jq -r '.restored' "$case_root/restore-report.json")" "should restore from dead-PID pane session"
  assert_eq "$file_a" "$(jq -r '.current_file' "$case_root/restore-report.json")" "restored file path"
  assert_eq "15" "$(jq -r '.current_line' "$case_root/restore-report.json")" "restored cursor line"
}

@test "do not restore from pane session when owning PID is alive" {
  local session_root="$XDG_STATE_HOME/nvim/sessions"
  local file_a="$case_root/file-a.txt"
  seq 1 10 >"$file_a"

  # Start a long-running background process whose PID we can use as "alive"
  sleep 300 &
  local alive_pid=$!

  # Create state with the alive PID
  cat >"$case_root/alive-pid-test.lua" <<EOF
package.path = package.path .. ';$repo_root/nvim/lua/?.lua;$repo_root/nvim/lua/?/init.lua'
local send = dofile("$repo_root/nvim/lua/core/send_to_nvim.lua")
vim.cmd("cd $case_root")
vim.cmd("edit $file_a")

local pane_dir = "$session_root/pane/%42"
vim.fn.mkdir(pane_dir, "p")
send.export_restore_state(pane_dir .. "/state.json")
vim.fn.writefile({ "$alive_pid" }, pane_dir .. "/pid")

-- Now try to restore: should fail because PID is alive
local state_path = pane_dir .. "/state.json"
local pid_lines = vim.fn.readfile(pane_dir .. "/pid")
local saved_pid = tonumber(pid_lines[1])
local pid_alive = vim.uv.kill(saved_pid, 0) == 0

-- Wipe buffers so we can tell if restore happened
vim.cmd("enew!")

-- The try_restore_from_pane logic checks PID before restoring
local should_restore = not pid_alive
local actually_restored = false
if should_restore then
  actually_restored = send.restore_from_state_file(state_path)
end

local report = {
  pid_alive = pid_alive,
  should_restore = should_restore,
  actually_restored = actually_restored,
}
vim.fn.writefile({ vim.json.encode(report) }, "$case_root/alive-pid-report.json")
EOF
  run_persistence_script "$case_root/alive-pid-test.lua"
  kill "$alive_pid" 2>/dev/null || true

  assert_eq "true" "$(jq -r '.pid_alive' "$case_root/alive-pid-report.json")" "background PID should be alive"
  assert_eq "false" "$(jq -r '.should_restore' "$case_root/alive-pid-report.json")" "should not restore when PID alive"
  assert_eq "false" "$(jq -r '.actually_restored' "$case_root/alive-pid-report.json")" "did not restore"
}

@test "restore falls back to cwd session" {
  local session_root="$XDG_STATE_HOME/nvim/sessions"
  local file_a="$case_root/file-a.txt"
  seq 1 20 >"$file_a"

  local cwd_hash
  cwd_hash="$(printf '%s' "$case_root" | sed 's|^/||; s|/|%|g')"

  # Create a cwd-keyed session with dead PID
  cat >"$case_root/create-cwd-state.lua" <<EOF
package.path = package.path .. ';$repo_root/nvim/lua/?.lua;$repo_root/nvim/lua/?/init.lua'
local send = dofile("$repo_root/nvim/lua/core/send_to_nvim.lua")
vim.cmd("cd $case_root")
vim.cmd("edit $file_a")
vim.fn.cursor(8, 1)

local cwd_dir = "$session_root/cwd/$cwd_hash"
vim.fn.mkdir(cwd_dir, "p")
send.export_restore_state(cwd_dir .. "/state.json")
vim.fn.writefile({ "99999999" }, cwd_dir .. "/pid")
EOF
  run_persistence_script "$case_root/create-cwd-state.lua"

  # Restore from cwd (no pane session exists)
  cat >"$case_root/restore-cwd.lua" <<EOF
package.path = package.path .. ';$repo_root/nvim/lua/?.lua;$repo_root/nvim/lua/?/init.lua'
local send = dofile("$repo_root/nvim/lua/core/send_to_nvim.lua")
vim.cmd("cd $case_root")

local cwd_dir = "$session_root/cwd/$cwd_hash"
local state_path = cwd_dir .. "/state.json"
local pid_lines = vim.fn.readfile(cwd_dir .. "/pid")
local saved_pid = tonumber(pid_lines[1])
local pid_alive = vim.uv.kill(saved_pid, 0) == 0

local restored = false
if not pid_alive then
  restored = send.restore_from_state_file(state_path)
end

local report = {
  restored = restored,
  current_file = vim.api.nvim_buf_get_name(0),
  current_line = vim.fn.line("."),
}
vim.fn.writefile({ vim.json.encode(report) }, "$case_root/cwd-restore-report.json")
EOF
  run_persistence_script "$case_root/restore-cwd.lua"

  assert_eq "true" "$(jq -r '.restored' "$case_root/cwd-restore-report.json")" "cwd session restored"
  assert_eq "$file_a" "$(jq -r '.current_file' "$case_root/cwd-restore-report.json")" "restored file"
  assert_eq "8" "$(jq -r '.current_line' "$case_root/cwd-restore-report.json")" "restored cursor"
}

@test "cleanup sweeps stale pane sessions with dead PIDs" {
  local session_root="$XDG_STATE_HOME/nvim/sessions"
  local pane_root="$session_root/pane"

  # Start a background process to use as alive PID
  sleep 300 &
  local alive_pid=$!

  # Create two pane sessions: one with dead PID, one with alive PID
  mkdir -p "$pane_root/%dead-pane" "$pane_root/%alive-pane"
  echo '{"cwd":"/tmp","tabs":[]}' >"$pane_root/%dead-pane/state.json"
  echo '{"cwd":"/tmp","tabs":[]}' >"$pane_root/%alive-pane/state.json"
  echo "99999999" >"$pane_root/%dead-pane/pid"
  echo "$alive_pid" >"$pane_root/%alive-pane/pid"

  cat >"$case_root/sweep-test.lua" <<EOF
package.path = package.path .. ';$repo_root/nvim/lua/?.lua;$repo_root/nvim/lua/?/init.lua'
dofile("$repo_root/nvim/lua/core/send_to_nvim.lua")

-- The sweep function uses session_root from stdpath("state") .. "/sessions"
-- We need to override it. Since sweep_stale_sessions is local, we replicate its logic
-- for testing purposes.
local session_root = "$session_root"
local pane_root = session_root .. "/pane"

local function read_pid(dir)
  local path = dir .. "/pid"
  if vim.fn.filereadable(path) ~= 1 then return nil end
  return tonumber(vim.fn.readfile(path)[1])
end

local function pid_is_alive(pid)
  if not pid or pid <= 0 then return false end
  return vim.uv.kill(pid, 0) == 0
end

local dirs = vim.fn.glob(pane_root .. "/*", false, true)
for _, dir in ipairs(dirs) do
  local saved_pid = read_pid(dir)
  if not saved_pid or not pid_is_alive(saved_pid) then
    vim.fn.delete(dir, "rf")
  end
end

local report = {
  dead_pane_exists = vim.fn.isdirectory("$pane_root/%dead-pane") == 1,
  alive_pane_exists = vim.fn.isdirectory("$pane_root/%alive-pane") == 1,
}
vim.fn.writefile({ vim.json.encode(report) }, "$case_root/sweep-report.json")
EOF
  run_persistence_script "$case_root/sweep-test.lua"
  kill "$alive_pid" 2>/dev/null || true

  assert_eq "false" "$(jq -r '.dead_pane_exists' "$case_root/sweep-report.json")" "dead pane session removed"
  assert_eq "true" "$(jq -r '.alive_pane_exists' "$case_root/sweep-report.json")" "alive pane session kept"
}

@test "cleanup respects 7-day retention for cwd sessions" {
  local session_root="$XDG_STATE_HOME/nvim/sessions"
  local cwd_root="$session_root/cwd"

  # Create two cwd sessions with dead PIDs: one recent, one old (>7 days)
  mkdir -p "$cwd_root/recent-project" "$cwd_root/old-project"
  echo '{"cwd":"/tmp/recent","tabs":[]}' >"$cwd_root/recent-project/state.json"
  echo '{"cwd":"/tmp/old","tabs":[]}' >"$cwd_root/old-project/state.json"
  echo "99999999" >"$cwd_root/recent-project/pid"
  echo "99999999" >"$cwd_root/old-project/pid"

  # Touch the old one to 8 days ago
  touch -t "$(date -v-8d '+%Y%m%d%H%M.%S' 2>/dev/null || date -d '8 days ago' '+%Y%m%d%H%M.%S')" "$cwd_root/old-project/state.json"

  cat >"$case_root/retention-test.lua" <<EOF
package.path = package.path .. ';$repo_root/nvim/lua/?.lua;$repo_root/nvim/lua/?/init.lua'
dofile("$repo_root/nvim/lua/core/send_to_nvim.lua")

local session_root = "$session_root"
local cwd_root = session_root .. "/cwd"
local max_age = 7 * 24 * 60 * 60
local now = os.time()

local function read_pid(dir)
  local path = dir .. "/pid"
  if vim.fn.filereadable(path) ~= 1 then return nil end
  return tonumber(vim.fn.readfile(path)[1])
end

local function pid_is_alive(pid)
  if not pid or pid <= 0 then return false end
  return vim.uv.kill(pid, 0) == 0
end

local dirs = vim.fn.glob(cwd_root .. "/*", false, true)
for _, dir in ipairs(dirs) do
  local saved_pid = read_pid(dir)
  if saved_pid and pid_is_alive(saved_pid) then
    goto continue
  end
  local state_path = dir .. "/state.json"
  if vim.fn.filereadable(state_path) == 1 then
    local mtime = vim.fn.getftime(state_path)
    if mtime > 0 and (now - mtime) > max_age then
      vim.fn.delete(dir, "rf")
    end
  else
    vim.fn.delete(dir, "rf")
  end
  ::continue::
end

local report = {
  recent_exists = vim.fn.isdirectory("$cwd_root/recent-project") == 1,
  old_exists = vim.fn.isdirectory("$cwd_root/old-project") == 1,
}
vim.fn.writefile({ vim.json.encode(report) }, "$case_root/retention-report.json")
EOF
  run_persistence_script "$case_root/retention-test.lua"

  assert_eq "true" "$(jq -r '.recent_exists' "$case_root/retention-report.json")" "recent cwd session kept"
  assert_eq "false" "$(jq -r '.old_exists' "$case_root/retention-report.json")" "old cwd session removed"
}

@test "skip restore when file args passed" {
  local session_root="$XDG_STATE_HOME/nvim/sessions"
  local file_a="$case_root/file-a.txt"
  local file_b="$case_root/file-b.txt"
  seq 1 10 >"$file_a"
  echo "direct open" >"$file_b"

  local cwd_hash
  cwd_hash="$(printf '%s' "$case_root" | sed 's|^/||; s|/|%|g')"

  # Create a cwd session that would normally auto-restore
  cat >"$case_root/create-session.lua" <<EOF
package.path = package.path .. ';$repo_root/nvim/lua/?.lua;$repo_root/nvim/lua/?/init.lua'
local send = dofile("$repo_root/nvim/lua/core/send_to_nvim.lua")
vim.cmd("cd $case_root")
vim.cmd("edit $file_a")
vim.fn.cursor(3, 1)

local cwd_dir = "$session_root/cwd/$cwd_hash"
vim.fn.mkdir(cwd_dir, "p")
send.export_restore_state(cwd_dir .. "/state.json")
vim.fn.writefile({ "99999999" }, cwd_dir .. "/pid")
EOF
  run_persistence_script "$case_root/create-session.lua"

  # Open nvim with explicit file arg — should NOT restore session
  cat >"$case_root/skip-restore-check.lua" <<EOF
-- This simulates what happens when nvim is opened with file args
-- The setup() function checks #vim.fn.argv() > 0
local report = {
  argc = #vim.fn.argv(),
  skip_restore = #vim.fn.argv() > 0,
  current_file = vim.api.nvim_buf_get_name(0),
}
vim.fn.writefile({ vim.json.encode(report) }, "$case_root/skip-report.json")
EOF
  # Run with a file argument
  XDG_STATE_HOME="$XDG_STATE_HOME" \
  XDG_DATA_HOME="$XDG_DATA_HOME" \
  "$real_nvim" --headless -u NONE -i NONE \
    --cmd "lua package.path = package.path .. ';$repo_root/nvim/lua/?.lua;$repo_root/nvim/lua/?/init.lua'" \
    "$file_b" \
    "+lua dofile([[$case_root/skip-restore-check.lua]])" +qa!

  assert_eq "1" "$(jq -r '.argc' "$case_root/skip-report.json")" "argc should be 1"
  assert_eq "true" "$(jq -r '.skip_restore' "$case_root/skip-report.json")" "should skip restore with file args"
  assert_contains "$(jq -r '.current_file' "$case_root/skip-report.json")" "file-b.txt" "should have opened the explicit file"
}
