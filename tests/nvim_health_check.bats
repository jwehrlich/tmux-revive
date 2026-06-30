#!/usr/bin/env bats
#
# Tests for the nvim persistence watchdog (send_to_nvim/health-check.sh).
#
# Reaping policy:
#   - responsive server          -> left alone, no failure counter
#   - unresponsive for N checks   -> reaped (kill -9 + registry entry removed)
#   - a single success           -> resets the failure counter (hysteresis)
#   - dead pid (stale entry)      -> swept
#   - footprint over ceiling      -> reaped immediately (opt-in backstop)
#
# Ping and footprint probes are injected so the policy can be tested without
# real nvim servers; fake `sleep` processes stand in for live nvim pids.

setup() {
  load test_helper/common-setup
  load test_helper/assertions
  load test_helper/wait-helpers
  load test_helper/data-helpers
  load test_helper/fake-wrappers
  _common_setup
  _setup_case
  health_check="$tmux_revive_dir/send_to_nvim/health-check.sh"
  export TMUX_MANAGE_NVIM_HEALTH_DIR="$case_root/health"
  : >"$case_root/fake_pids"
}

teardown() {
  if [ -f "$case_root/fake_pids" ]; then
    while IFS= read -r p; do [ -n "$p" ] && kill -9 "$p" 2>/dev/null || true; done <"$case_root/fake_pids"
  fi
  _teardown_case
}

# Spawn a long-lived stand-in for a live nvim and echo its pid.
# fd 3 is closed (3>&-) so the background process doesn't hold bats's status fd
# open, which would hang the test run.
spawn_fake() {
  sleep 600 >/dev/null 2>&1 3>&- &
  local p=$!
  printf '%s\n' "$p" >>"$case_root/fake_pids"
  printf '%s' "$p"
}

# Write a registry entry: <name> <pid> <server>
make_entry() {
  local dir="$TMUX_SEND_TO_NVIM_STATE_DIR/s0"
  mkdir -p "$dir"
  printf '{"nvim_pid":"%s","server":"%s"}\n' "$2" "$3" >"$dir/$1-$2.json"
  printf '%s' "$dir/$1-$2.json"
}

# Install a ping stub: exits 0 (responsive) iff the server arg contains $1.
ping_stub_matching() {
  local marker="$1"
  cat >"$case_root/ping.sh" <<EOF
#!/usr/bin/env bash
case "\$1" in *$marker*) exit 0 ;; *) exit 1 ;; esac
EOF
  chmod +x "$case_root/ping.sh"
  export TMUX_MANAGE_NVIM_PING_CMD="$case_root/ping.sh"
}

alive() { kill -0 "$1" 2>/dev/null && echo yes || echo no; }

@test "watchdog: responsive server is left running and uncounted" {
  ping_stub_matching "live"
  local pid; pid="$(spawn_fake)"
  make_entry "%0" "$pid" "/tmp/live.sock" >/dev/null
  bash "$health_check"
  assert_eq "yes" "$(alive "$pid")" "responsive server stays alive"
  [ ! -f "$TMUX_MANAGE_NVIM_HEALTH_DIR/$pid.fails" ] || fail "no failure counter expected"
}

@test "watchdog: unresponsive server is reaped only after the threshold" {
  ping_stub_matching "live"            # entry server is /tmp/dead.sock -> always fails
  export TMUX_MANAGE_NVIM_HEALTH_FAILS=3
  local pid; pid="$(spawn_fake)"
  local entry; entry="$(make_entry "%0" "$pid" "/tmp/dead.sock")"

  bash "$health_check"
  assert_eq "yes" "$(alive "$pid")" "alive after 1 failure"
  assert_eq "1" "$(cat "$TMUX_MANAGE_NVIM_HEALTH_DIR/$pid.fails")" "counter=1"

  bash "$health_check"
  assert_eq "yes" "$(alive "$pid")" "alive after 2 failures"
  assert_eq "2" "$(cat "$TMUX_MANAGE_NVIM_HEALTH_DIR/$pid.fails")" "counter=2"

  bash "$health_check"
  assert_eq "no" "$(alive "$pid")" "reaped on 3rd consecutive failure"
  [ ! -f "$entry" ] || fail "registry entry should be removed on reap"
}

@test "watchdog: a successful ping resets the failure counter" {
  export TMUX_MANAGE_NVIM_HEALTH_FAILS=3
  local pid; pid="$(spawn_fake)"
  make_entry "%0" "$pid" "/tmp/flaky.sock" >/dev/null

  ping_stub_matching "nomatch"         # fail once
  bash "$health_check"
  assert_eq "1" "$(cat "$TMUX_MANAGE_NVIM_HEALTH_DIR/$pid.fails")" "counter=1 after failure"

  ping_stub_matching "flaky"           # now responsive
  bash "$health_check"
  [ ! -f "$TMUX_MANAGE_NVIM_HEALTH_DIR/$pid.fails" ] || fail "counter should reset on success"
  assert_eq "yes" "$(alive "$pid")" "stays alive after recovery"
}

@test "watchdog: stale entry with a dead pid is swept" {
  ping_stub_matching "live"
  local pid; pid="$(spawn_fake)"
  local entry; entry="$(make_entry "%0" "$pid" "/tmp/live.sock")"
  kill -9 "$pid" 2>/dev/null || true
  sleep 0.2
  bash "$health_check"
  [ ! -f "$entry" ] || fail "stale entry should be swept"
}

@test "watchdog: footprint over ceiling is reaped immediately" {
  ping_stub_matching "live"            # responsive — footprint must take precedence
  export TMUX_MANAGE_NVIM_FOOTPRINT_CEILING_MB=2048
  printf '#!/usr/bin/env bash\necho 4096\n' >"$case_root/fp.sh"; chmod +x "$case_root/fp.sh"
  export TMUX_MANAGE_NVIM_FOOTPRINT_CMD="$case_root/fp.sh"
  local pid; pid="$(spawn_fake)"
  make_entry "%0" "$pid" "/tmp/live.sock" >/dev/null
  bash "$health_check"
  assert_eq "no" "$(alive "$pid")" "reaped for exceeding footprint ceiling"
}

@test "watchdog: footprint ceiling is enabled by default" {
  ping_stub_matching "live"            # responsive — only footprint should trigger
  # Deliberately do NOT set TMUX_MANAGE_NVIM_FOOTPRINT_CEILING_MB: the default
  # (4096) must apply. A regression back to 0 (disabled) would leave it alive.
  printf '#!/usr/bin/env bash\necho 9000\n' >"$case_root/fp.sh"; chmod +x "$case_root/fp.sh"
  export TMUX_MANAGE_NVIM_FOOTPRINT_CMD="$case_root/fp.sh"
  local pid; pid="$(spawn_fake)"
  make_entry "%0" "$pid" "/tmp/live.sock" >/dev/null
  bash "$health_check"
  assert_eq "no" "$(alive "$pid")" "default ceiling reaps a 9000MB server"
}

@test "watchdog: footprint under ceiling does not reap" {
  ping_stub_matching "live"
  export TMUX_MANAGE_NVIM_FOOTPRINT_CEILING_MB=2048
  printf '#!/usr/bin/env bash\necho 100\n' >"$case_root/fp.sh"; chmod +x "$case_root/fp.sh"
  export TMUX_MANAGE_NVIM_FOOTPRINT_CMD="$case_root/fp.sh"
  local pid; pid="$(spawn_fake)"
  make_entry "%0" "$pid" "/tmp/live.sock" >/dev/null
  bash "$health_check"
  assert_eq "yes" "$(alive "$pid")" "well-behaved server stays alive"
}
