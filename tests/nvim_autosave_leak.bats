#!/usr/bin/env bats
#
# Regression tests for the nvim autosave memory leak.
#
# Background: the autosave timer used a repeating libuv timer that called
# vim.schedule() every interval unconditionally. When the main loop was wedged
# (a hit-enter prompt on an unattended background pane), those scheduled events
# piled onto the multiqueue without bound — growing to >10 GB per nvim.
#
# The fix has three parts, each exercised here:
#   1. Adaptive pacing  (next_autosave_ms): back off proportional to save cost,
#      clamped to [min, max]; bounds, env override.
#   2. Trigger removal   (clamp_restore_summary): restore warning is a single
#      bounded line so it can never raise the hit-enter prompt.
#   3. Self-rearming timer (start_autosave_timer): the next cycle is armed only
#      after the previous save runs, so the queue can never pile up; pcall keeps
#      the loop alive across a crashing save.

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

# Run a Lua body in headless nvim with the module loaded as `send`, its test
# hooks as `T`, and a report table `R` that is written to report.json on exit.
run_lua() {
  local body="$1"
  cat >"$case_root/script.lua" <<EOF
package.path = package.path .. ';$repo_root/nvim/lua/?.lua;$repo_root/nvim/lua/?/init.lua'
local send = dofile("$repo_root/nvim/lua/core/send_to_nvim.lua")
local T = send.__test
local R = {}
$body
vim.fn.writefile({ vim.json.encode(R) }, "$case_root/report.json")
EOF
  "$real_nvim" --headless -u NONE -i NONE \
    "+lua dofile([[$case_root/script.lua]])" +qa!
}

report() { jq -r "$1" "$case_root/report.json"; }

# ---------------------------------------------------------------------------
# 1. Adaptive pacing: next_autosave_ms (defaults: min 60s, max 600s, ×50)
# ---------------------------------------------------------------------------
@test "pacing: cheap save is clamped up to the floor" {
  run_lua 'R.tiny = T.next_autosave_ms(10); R.floor_boundary = T.next_autosave_ms(1200)'
  assert_eq "60000" "$(report .tiny)"          "10ms save -> 60s floor"
  assert_eq "60000" "$(report .floor_boundary)" "1200ms*50 == 60s"
}

@test "pacing: mid-cost save scales proportionally (x50)" {
  run_lua 'R.mid = T.next_autosave_ms(2000); R.bigger = T.next_autosave_ms(6000)'
  assert_eq "100000" "$(report .mid)"    "2000ms -> 100s"
  assert_eq "300000" "$(report .bigger)" "6000ms -> 300s"
}

@test "pacing: expensive save is clamped to the ceiling" {
  run_lua 'R.at = T.next_autosave_ms(12000); R.over = T.next_autosave_ms(60000)'
  assert_eq "600000" "$(report .at)"   "12000ms*50 == 600s ceiling"
  assert_eq "600000" "$(report .over)" "huge save clamped to 600s"
}

@test "pacing: zero/negative durations fall back to the floor" {
  run_lua 'R.zero = T.next_autosave_ms(0); R.neg = T.next_autosave_ms(-5)'
  assert_eq "60000" "$(report .zero)" "0ms -> floor"
  assert_eq "60000" "$(report .neg)"  "negative -> floor"
}

@test "pacing: env vars override the clamp bounds" {
  export TMUX_MANAGE_NVIM_AUTOSAVE_MIN_SECS=2
  export TMUX_MANAGE_NVIM_AUTOSAVE_MAX_SECS=10
  run_lua 'R.lo = T.next_autosave_ms(10); R.mid = T.next_autosave_ms(100); R.hi = T.next_autosave_ms(500)'
  assert_eq "2000"  "$(report .lo)"  "clamped up to new 2s floor"
  assert_eq "5000"  "$(report .mid)" "100ms*50 == 5s, within bounds"
  assert_eq "10000" "$(report .hi)"  "clamped down to new 10s ceiling"
}

# ---------------------------------------------------------------------------
# 2. Config parsing: env_secs
# ---------------------------------------------------------------------------
@test "env_secs: returns default when unset, blank, zero, negative, or non-numeric" {
  run_lua '
    R.unset = T.env_secs("TMUX_MANAGE_TEST_UNSET", 7)
    vim.env.TMUX_MANAGE_TEST_X = "";    R.blank = T.env_secs("TMUX_MANAGE_TEST_X", 7)
    vim.env.TMUX_MANAGE_TEST_X = "0";   R.zero  = T.env_secs("TMUX_MANAGE_TEST_X", 7)
    vim.env.TMUX_MANAGE_TEST_X = "-3";  R.neg   = T.env_secs("TMUX_MANAGE_TEST_X", 7)
    vim.env.TMUX_MANAGE_TEST_X = "abc"; R.nan   = T.env_secs("TMUX_MANAGE_TEST_X", 7)
    vim.env.TMUX_MANAGE_TEST_X = "12";  R.ok    = T.env_secs("TMUX_MANAGE_TEST_X", 7)
  '
  assert_eq "7"  "$(report .unset)" "unset -> default"
  assert_eq "7"  "$(report .blank)" "blank -> default"
  assert_eq "7"  "$(report .zero)"  "zero -> default"
  assert_eq "7"  "$(report .neg)"   "negative -> default"
  assert_eq "7"  "$(report .nan)"   "non-numeric -> default"
  assert_eq "12" "$(report .ok)"    "valid -> value"
}

# ---------------------------------------------------------------------------
# 3. Trigger removal: clamp_restore_summary stays a single bounded line
# ---------------------------------------------------------------------------
@test "summary: short message is a single line starting with the prefix" {
  run_lua '
    local s = T.clamp_restore_summary({ "a", "b" }, 80)
    R.starts_ok  = s:match("^send_to_nvim:") ~= nil
    R.has_newline = s:find("\n") ~= nil
  '
  assert_eq "true"  "$(report .starts_ok)"  "starts with prefix"
  assert_eq "false" "$(report .has_newline)" "single line"
}

@test "summary: pathologically long message is truncated at max_len with ellipsis" {
  run_lua '
    local long = {}
    for i = 1, 50 do long[i] = "detail-message-number-" .. i end  -- ~1200 chars
    local s = T.clamp_restore_summary(long, 120)
    R.len          = #s
    R.under_cap    = #s <= 120
    R.has_ellipsis = s:sub(-3) == "..."
    R.has_newline  = s:find("\n") ~= nil
  '
  assert_eq "120"   "$(report .len)"         "truncated to exactly max_len"
  assert_eq "true"  "$(report .under_cap)"   "result within max_len"
  assert_eq "true"  "$(report .has_ellipsis)" "truncated with ellipsis"
  assert_eq "false" "$(report .has_newline)" "still single line"
}

@test "summary: default max_len preserves realistic detail (quickfix, loclist)" {
  run_lua '
    local s = T.clamp_restore_summary({
      "1 dirty buffer(s) were present at snapshot time and were not restored",
      "not restored: quickfix list (3 entries), 1 location list window(s)",
    })   -- no explicit max_len -> default 300
    R.has_quickfix = s:find("quickfix list") ~= nil
    R.has_dirty    = s:find("dirty buffer") ~= nil
    R.has_newline  = s:find("\n") ~= nil
  '
  assert_eq "true"  "$(report .has_quickfix)" "default cap keeps quickfix detail"
  assert_eq "true"  "$(report .has_dirty)"    "default cap keeps dirty-buffer detail"
  assert_eq "false" "$(report .has_newline)"  "single line"
}

@test "summary: embedded newlines and runs of whitespace are collapsed" {
  run_lua '
    local s = T.clamp_restore_summary({ "line one\nline two", "x\t\ty" }, 200)
    R.has_newline = s:find("\n") ~= nil
    R.has_tab     = s:find("\t") ~= nil
  '
  assert_eq "false" "$(report .has_newline)" "newlines collapsed"
  assert_eq "false" "$(report .has_tab)"     "tabs collapsed"
}

@test "summary: max_len argument bounds the result length" {
  run_lua '
    local long = {}
    for i = 1, 50 do long[i] = "msg-" .. i end
    R.default_ok = #T.clamp_restore_summary(long, nil) <= 300
    R.small_ok   = #T.clamp_restore_summary(long, 50)  <= 50
  '
  assert_eq "true" "$(report .default_ok)" "nil max_len -> 300 default"
  assert_eq "true" "$(report .small_ok)"   "explicit max_len honored"
}

# ---------------------------------------------------------------------------
# 4. Self-rearming timer behavior (uses a 1s floor for fast cycles)
# ---------------------------------------------------------------------------
@test "timer: a save that throws does not kill the loop (pcall + re-arm)" {
  export TMUX_MANAGE_NVIM_AUTOSAVE_MIN_SECS=1
  run_lua '
    local count = 0
    T.start_autosave_timer(function()
      count = count + 1
      error("boom")          -- every save throws
    end)
    vim.wait(3500)           -- ~3 one-second cycles
    T.stop_autosave_timer()
    R.count = count
  '
  # Without pcall + unconditional re-arm, the first throw would stop autosave
  # forever and count would be 1. We expect it to keep firing.
  local count; count="$(report .count)"
  [ "$count" -ge 2 ] || fail "expected >=2 runs despite errors, got $count"
}

@test "timer: never runs a second save while one is in flight (no pile-up)" {
  export TMUX_MANAGE_NVIM_AUTOSAVE_MIN_SECS=1
  run_lua '
    local started, in_flight, reentered = 0, false, false
    T.start_autosave_timer(function()
      started = started + 1
      if in_flight then reentered = true; return end  -- early-out avoids deep nesting on regression
      in_flight = true
      vim.wait(1200)         -- hold the "save" open across the next timer interval
      in_flight = false
    end)
    vim.wait(2800)
    T.stop_autosave_timer()
    R.started   = started
    R.reentered = reentered
  '
  # A repeating timer (the old bug) would fire again at ~2s and run a second
  # save reentrantly during the 1.2s hold. The self-rearming timer must not.
  assert_eq "false" "$(report .reentered)" "no reentrant/stacked save"
  local started; started="$(report .started)"
  [ "$started" -ge 1 ] || fail "timer should have fired at least once, got $started"
}

@test "timer: stop before the first fire prevents any save" {
  export TMUX_MANAGE_NVIM_AUTOSAVE_MIN_SECS=1
  run_lua '
    local count = 0
    T.start_autosave_timer(function() count = count + 1 end)
    T.stop_autosave_timer()  -- stop immediately, before the 1s fire
    vim.wait(2500)
    R.count = count
  '
  assert_eq "0" "$(report .count)" "stopped timer never fires"
}

@test "timer: sustained operation stays serialized over many cycles (soak)" {
  export TMUX_MANAGE_NVIM_AUTOSAVE_MIN_SECS=1
  run_lua '
    local runs, in_flight, reentered = 0, false, false
    T.start_autosave_timer(function()
      runs = runs + 1
      if in_flight then reentered = true; return end
      in_flight = true
      in_flight = false   -- trivial, fast "save"
    end)
    vim.wait(4500)         -- ~4 one-second cycles
    T.stop_autosave_timer()
    R.runs = runs
    R.reentered = reentered
  '
  local runs; runs="$(report .runs)"
  [ "$runs" -ge 3 ] || fail "expected sustained firing (>=3 cycles), got $runs"
  assert_eq "false" "$(report .reentered)" "serialized across many cycles"
}

@test "timer: a failed save is logged to TMUX_MANAGE_NVIM_LOG when set" {
  export TMUX_MANAGE_NVIM_AUTOSAVE_MIN_SECS=1
  export TMUX_MANAGE_NVIM_LOG="$case_root/nvim-debug.log"
  run_lua '
    T.start_autosave_timer(function() error("kaboom") end)
    vim.wait(1500)
    T.stop_autosave_timer()
    R.done = true
  '
  [ -f "$TMUX_MANAGE_NVIM_LOG" ] || fail "debug log should be created on failure"
  grep -q "autosave run failed" "$TMUX_MANAGE_NVIM_LOG" || fail "failure not logged"
  grep -q "kaboom" "$TMUX_MANAGE_NVIM_LOG" || fail "error detail not logged"
}
