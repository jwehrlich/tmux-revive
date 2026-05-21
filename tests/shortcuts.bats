setup() {
  load test_helper/common-setup
  load test_helper/assertions
  load test_helper/wait-helpers
  load test_helper/data-helpers
  load test_helper/fake-wrappers
  _common_setup
  _setup_case
  setup_server_flag_wrapper
}

teardown() {
  _teardown_case
}

wait_for_client_tty() {
  local attempts="${1:-40}"
  local delay="${2:-0.1}"
  local i current

  for ((i = 0; i < attempts; i++)); do
    current="$(tmux list-clients -F '#{client_tty}' 2>/dev/null | head -n 1 || true)"
    if [ -n "$current" ]; then
      printf '%s\n' "$current"
      return 0
    fi
    sleep "$delay"
  done

  return 1
}

wait_for_real_client_tty() {
  local attempts="${1:-40}"
  local delay="${2:-0.1}"
  local i current

  for ((i = 0; i < attempts; i++)); do
    current="$("$real_tmux" -f /dev/null -L "$socket_name" list-clients -F '#{client_tty}' 2>/dev/null | head -n 1 || true)"
    if [ -n "$current" ]; then
      printf '%s\n' "$current"
      return 0
    fi
    sleep "$delay"
  done

  return 1
}

wait_for_real_client_session() {
  local client_tty="$1"
  local expected="$2"
  local attempts="${3:-40}"
  local delay="${4:-0.1}"
  local i current

  for ((i = 0; i < attempts; i++)); do
    current="$("$real_tmux" -f /dev/null -L "$socket_name" list-clients -F $'#{client_tty}\t#{session_name}' 2>/dev/null | awk -F $'\t' -v tty="$client_tty" '$1 == tty { print $2; exit }')"
    if [ "$current" = "$expected" ]; then
      return 0
    fi
    sleep "$delay"
  done

  return 1
}

wait_for_log_min_line_count() {
  local path="$1"
  local minimum="$2"
  local attempts="${3:-40}"
  local delay="${4:-0.1}"
  local i current

  for ((i = 0; i < attempts; i++)); do
    if [ -f "$path" ]; then
      current="$(sed '/^$/d' "$path" | wc -l | tr -d ' ')"
      if [ "$current" -ge "$minimum" ]; then
        return 0
      fi
    fi
    sleep "$delay"
  done

  return 1
}

@test "manage mode binds slot 0 and shortcut carousel menu entry" {
  tmux new-session -d -s alpha
  "$tmux_revive_dir/revive.tmux"

  bindings="$(tmux list-keys -T revive)"
  assert_contains "$bindings" 'bind-key -T revive 0' "revive binds slot 0"
  assert_contains "$bindings" "--jump 0" "revive slot 0 binding jumps to slot 0"
  assert_contains "$bindings" 'bind-key -T revive C' "revive binds carousel toggle"
  assert_contains "$bindings" "--toggle-carousel --client-tty #{q:client_tty}" "revive carousel binding passes the client tty"
  assert_contains "$bindings" 'Rotate shortcuts' "revive manage menu includes rotate shortcuts"
  assert_contains "$bindings" 'Pane shortcuts 0-9' "revive manage menu shows 0-9 shortcut range"
}

@test "manage mode slot 0 jumps to the stored pane" {
  tmux new-session -d -s alpha
  tmux new-session -d -s beta
  beta_pane="$(tmux list-panes -t beta -F '#{pane_id}' | head -n 1)"

  TMUX_REVIVE_TMUX_SERVER="$socket_name" "$tmux_revive_dir/pane-shortcut.sh" --set 0 --pane-id "$beta_pane"
  rm -f "$TMUX_TEST_SWITCH_LOG"
  TMUX_REVIVE_TMUX_SERVER="$socket_name" "$tmux_revive_dir/pane-shortcut.sh" --jump 0

  wait_for_file "$TMUX_TEST_SWITCH_LOG" 40 0.25 || fail "slot 0 did not switch the client"
  switch_log="$(cat "$TMUX_TEST_SWITCH_LOG")"
  assert_contains "$switch_log" "switch-client -t beta:" "slot 0 jump target"
}

@test "manage mode carousel rotates shortcuts and stops on second C" {
  if ! command -v expect >/dev/null 2>&1; then
    skip "expect not installed"
  fi

  tmux new-session -d -s alpha
  tmux new-session -d -s beta

  alpha_pane="$(tmux list-panes -t alpha -F '#{pane_id}' | head -n 1)"
  beta_pane="$(tmux list-panes -t beta -F '#{pane_id}' | head -n 1)"

  TMUX_REVIVE_TMUX_SERVER="$socket_name" "$tmux_revive_dir/pane-shortcut.sh" --set 0 --pane-id "$alpha_pane"
  TMUX_REVIVE_TMUX_SERVER="$socket_name" "$tmux_revive_dir/pane-shortcut.sh" --set 1 --pane-id "$beta_pane"
  tmux set-option -g @tmux-revive-shortcut-carousel-interval 100
  rm -f "$TMUX_TEST_SWITCH_LOG"

  cat >"$case_root/carousel-client.expect" <<EOF
#!/usr/bin/expect -f
set timeout 20
log_user 0
spawn $real_tmux -f /dev/null -L $socket_name attach-session -t alpha
after 5000
send "\002d"
expect eof
EOF
  chmod +x "$case_root/carousel-client.expect"
  "$case_root/carousel-client.expect" &
  client_pid=$!

  client_tty="$(wait_for_client_tty 40 0.1)" || fail "carousel test client did not attach"

  TMUX_REVIVE_TMUX_SERVER="$socket_name" "$tmux_revive_dir/pane-shortcut.sh" --toggle-carousel --client-tty "$client_tty"
  wait_for_log_min_line_count "$TMUX_TEST_SWITCH_LOG" 1 40 0.1 || fail "shortcut carousel did not start"
  TMUX_REVIVE_TMUX_SERVER="$socket_name" "$tmux_revive_dir/pane-shortcut.sh" --carousel-tick --client-tty "$client_tty"
  wait_for_log_min_line_count "$TMUX_TEST_SWITCH_LOG" 2 40 0.1 || fail "shortcut carousel did not rotate across two shortcuts"
  line_count_before_stop="$(sed '/^$/d' "$TMUX_TEST_SWITCH_LOG" | wc -l | tr -d ' ')"
  TMUX_REVIVE_TMUX_SERVER="$socket_name" "$tmux_revive_dir/pane-shortcut.sh" --toggle-carousel --client-tty "$client_tty"
  TMUX_REVIVE_TMUX_SERVER="$socket_name" "$tmux_revive_dir/pane-shortcut.sh" --carousel-tick --client-tty "$client_tty"
  line_count_after_stop="$(sed '/^$/d' "$TMUX_TEST_SWITCH_LOG" | wc -l | tr -d ' ')"
  "$real_tmux" -f /dev/null -L "$socket_name" detach-client -t "$client_tty" >/dev/null 2>&1 || true
  wait "$client_pid" || true

  switch_log="$(cat "$TMUX_TEST_SWITCH_LOG")"
  line1="$(printf '%s\n' "$switch_log" | sed -n '1p')"
  line2="$(printf '%s\n' "$switch_log" | sed -n '2p')"

  assert_contains "$line1" "switch-client -c " "carousel targets the attached client"
  assert_contains "$line1" "-t alpha:" "carousel starts at shortcut 0"
  assert_contains "$line2" "-t beta:" "carousel advances to shortcut 1"
  assert_eq "$line_count_before_stop" "$line_count_after_stop" "carousel stops after the second toggle"

  runtime_dir="$(TMUX_REVIVE_TMUX_SERVER="$socket_name" tmux_revive_runtime_dir)"
  state_path="$runtime_dir/pane-shortcut-carousel.json"
  wait_for_jq_value "$state_path" 'length' '0' 20 0.25 || fail "carousel state was not cleared after stop"
}

@test "shortcut carousel skips invalid pane targets" {
  if ! command -v expect >/dev/null 2>&1; then
    skip "expect not installed"
  fi

  tmux new-session -d -s alpha
  tmux new-session -d -s beta
  tmux new-session -d -s gamma

  alpha_pane="$(tmux list-panes -t alpha -F '#{pane_id}' | head -n 1)"
  beta_pane="$(tmux list-panes -t beta -F '#{pane_id}' | head -n 1)"
  gamma_pane="$(tmux list-panes -t gamma -F '#{pane_id}' | head -n 1)"

  PATH="$original_path" TMUX_REVIVE_TMUX_SERVER="$socket_name" "$tmux_revive_dir/pane-shortcut.sh" --set 0 --pane-id "$alpha_pane"
  PATH="$original_path" TMUX_REVIVE_TMUX_SERVER="$socket_name" "$tmux_revive_dir/pane-shortcut.sh" --set 1 --pane-id "$beta_pane"
  PATH="$original_path" TMUX_REVIVE_TMUX_SERVER="$socket_name" "$tmux_revive_dir/pane-shortcut.sh" --set 2 --pane-id "$gamma_pane"

  runtime_dir="$(TMUX_REVIVE_TMUX_SERVER="$socket_name" tmux_revive_runtime_dir)"
  shortcuts_path="$runtime_dir/pane-shortcuts.json"
  tmp_path="${shortcuts_path}.tmp"
  jq --arg slot "1" '.[$slot].pane_index = 99' "$shortcuts_path" >"$tmp_path"
  mv "$tmp_path" "$shortcuts_path"

  "$real_tmux" -f /dev/null -L "$socket_name" set-option -g @tmux-revive-shortcut-carousel-interval 100

  cat >"$case_root/carousel-skip-invalid.expect" <<EOF
#!/usr/bin/expect -f
set timeout 20
log_user 0
spawn $real_tmux -f /dev/null -L $socket_name attach-session -t alpha
after 5000
send "\002d"
expect eof
EOF
  chmod +x "$case_root/carousel-skip-invalid.expect"
  "$case_root/carousel-skip-invalid.expect" &
  client_pid=$!

  client_tty="$(wait_for_real_client_tty 40 0.1)" || fail "real carousel test client did not attach"

  PATH="$original_path" TMUX_REVIVE_TMUX_SERVER="$socket_name" \
    "$tmux_revive_dir/pane-shortcut.sh" --toggle-carousel --client-tty "$client_tty"
  PATH="$original_path" TMUX_REVIVE_TMUX_SERVER="$socket_name" \
    "$tmux_revive_dir/pane-shortcut.sh" --carousel-tick --client-tty "$client_tty"
  wait_for_real_client_session "$client_tty" "gamma" 50 0.1 || fail "carousel did not skip invalid shortcut to gamma"
  PATH="$original_path" TMUX_REVIVE_TMUX_SERVER="$socket_name" \
    "$tmux_revive_dir/pane-shortcut.sh" --toggle-carousel --client-tty "$client_tty"

  "$real_tmux" -f /dev/null -L "$socket_name" detach-client -t "$client_tty" >/dev/null 2>&1 || true
  wait "$client_pid" || true
}
