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

@test "revive groups current session first" {
  tmux new-session -d -s alpha
  alpha_window_index="$(tmux list-windows -t alpha -F '#{window_index}' | head -n 1)"
  tmux rename-window -t "alpha:$alpha_window_index" "alpha-main"
  alpha_pane="$(nth_pane_id alpha 1)"
  tmux select-pane -t "$alpha_pane" -T "alpha-pane"

  tmux new-session -d -s beta
  beta_window_index="$(tmux list-windows -t beta -F '#{window_index}' | head -n 1)"
  tmux rename-window -t "beta:$beta_window_index" "beta-main"
  beta_pane="$(nth_pane_id beta 1)"
  tmux select-pane -t "$beta_pane" -T "beta-pane"
  tmux new-window -d -t beta: -n "beta-extra"

  beta_session_id="$(tmux display-message -p -t beta '#{session_id}')"
  output="$(
    TMUX_REVIVE_PICK_CURRENT_SESSION_ID="$beta_session_id" \
    TMUX_REVIVE_PICK_CURRENT_SESSION_NAME="beta" \
    "$tmux_revive_dir/pick.sh" --dump-items-raw
  )"

  line1="$(printf '%s\n' "$output" | sed -n '1p')"
  line2="$(printf '%s\n' "$output" | sed -n '2p')"
  current_header_line="$(printf '%s\n' "$output" | awk -F '\t' '$1 == "header" && $6 == "CURRENT SESSION" { print NR; exit }')"
  other_header_line="$(printf '%s\n' "$output" | awk -F '\t' '$1 == "header" && $6 == "OTHER SESSIONS" { print NR; exit }')"
  beta_session_line="$(printf '%s\n' "$output" | awk -F '\t' -v id="$beta_session_id" '$1 == "live" && $2 == "session" && $3 == id && $4 == "beta" && $5 == "beta" { print NR; exit }')"
  alpha_session_line="$(printf '%s\n' "$output" | awk -F '\t' '$1 == "live" && $2 == "session" && $4 == "alpha" && $5 == "alpha" { print NR; exit }')"

  assert_eq $'header\theader\t\t\t\tCURRENT SESSION' "$line1" "revive current header first"
  assert_contains "$line2" $'live\tsession\t'"$beta_session_id"$'\tbeta\tbeta\t' "revive current session row second"
  assert_eq "1" "$current_header_line" "revive current header line number"
  [ -n "$other_header_line" ] || fail "revive other sessions header missing"
  [ -n "$beta_session_line" ] || fail "revive current session row missing"
  [ -n "$alpha_session_line" ] || fail "revive other session row missing"
  [ "$beta_session_line" -lt "$other_header_line" ] || fail "revive current session should appear before other sessions header"
  [ "$other_header_line" -lt "$alpha_session_line" ] || fail "revive other session should appear after other sessions header"
  assert_contains "$output" $'live\twindow\t' "revive window row present"
  assert_contains "$output" $'live\tpane\t' "revive pane row present"
}

@test "revive header rows are ignored and live actions still work" {
  tmux new-session -d -s alpha
  tmux new-session -d -s beta

  beta_session_id="$(tmux display-message -p -t beta '#{session_id}')"
  items="$(
    TMUX_REVIVE_PICK_CURRENT_SESSION_ID="$beta_session_id" \
    TMUX_REVIVE_PICK_CURRENT_SESSION_NAME="beta" \
    "$tmux_revive_dir/pick.sh" --dump-items
  )"
  header_row="$(printf '%s\n' "$items" | awk -F '\t' '$1 == "header" { print; exit }')"
  beta_row="$(printf '%s\n' "$items" | awk -F '\t' '$1 == "live" && $2 == "session" && $4 == "beta" { print; exit }')"
  [ -n "$header_row" ] || fail "revive header row missing for action test"
  [ -n "$beta_row" ] || fail "revive beta session row missing for action test"

  setup_fake_fzf_sequence \
    "$(printf '\nenter\n%s\n' "$header_row")" \
    "$(printf '\nenter\n%s\n' "$beta_row")"

  rm -f "$TMUX_TEST_SWITCH_LOG"
  TMUX_REVIVE_PICK_CURRENT_SESSION_ID="$beta_session_id" \
  TMUX_REVIVE_PICK_CURRENT_SESSION_NAME="beta" \
  "$tmux_revive_dir/pick.sh"

  wait_for_file "$TMUX_TEST_SWITCH_LOG" || fail "revive did not switch after live row selection"
  switch_log="$(cat "$TMUX_TEST_SWITCH_LOG")"
  assert_contains "$switch_log" "switch-client -t $beta_session_id" "revive live row action target"
}

@test "revive includes saved sessions section" {
  tmux new-session -d -s alpha
  tmux new-session -d -s beta
  beta_window_index="$(tmux list-windows -t beta -F '#{window_index}' | head -n 1)"
  tmux rename-window -t "beta:$beta_window_index" "beta-main"
  tmux new-window -d -t beta: -n "beta-logs"
  "$save_state" --reason revive-saved-sessions
  tmux kill-session -t beta

  alpha_session_id="$(tmux display-message -p -t alpha '#{session_id}')"
  output="$(
    TMUX_REVIVE_PICK_CURRENT_SESSION_ID="$alpha_session_id" \
    TMUX_REVIVE_PICK_CURRENT_SESSION_NAME="alpha" \
    "$tmux_revive_dir/pick.sh" --dump-items-raw
  )"

  saved_header_line="$(printf '%s\n' "$output" | awk -F '\t' '$1 == "header" && $6 == "SAVED SESSIONS" { print NR; exit }')"
  saved_row_line="$(printf '%s\n' "$output" | awk -F '\t' '$1 == "saved" && $4 == "beta" { print NR; exit }')"
  [ -n "$saved_header_line" ] || fail "revive saved sessions header missing"
  [ -n "$saved_row_line" ] || fail "revive saved session row missing"
  [ "$saved_header_line" -lt "$saved_row_line" ] || fail "revive saved session row should appear after saved header"
  assert_contains "$output" $'saved\tguid\t' "revive saved session uses guid selector"
  assert_contains "$output" "beta-main, beta-logs" "revive saved session row includes window summary"
}

@test "revive saved rows resume via resume-session" {
  tmux new-session -d -s alpha
  tmux new-session -d -s beta
  "$save_state" --reason revive-saved-row-resume
  tmux kill-session -t beta

  alpha_session_id="$(tmux display-message -p -t alpha '#{session_id}')"
  items="$(
    TMUX_REVIVE_PICK_CURRENT_SESSION_ID="$alpha_session_id" \
    TMUX_REVIVE_PICK_CURRENT_SESSION_NAME="alpha" \
    "$tmux_revive_dir/pick.sh" --dump-items
  )"
  saved_row="$(printf '%s\n' "$items" | awk -F '\t' '$1 == "saved" && $4 == "beta" { print; exit }')"
  [ -n "$saved_row" ] || fail "revive saved row missing for resume test"

  setup_fake_fzf_sequence "$(printf '\nenter\n%s\n' "$saved_row")"
  resume_log="$case_root/resume.log"
  resume_stub="$case_root/resume-session-stub.sh"
  cat >"$resume_stub" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >"$resume_log"
exit 0
EOF
  chmod +x "$resume_stub"

  rm -f "$TMUX_TEST_SWITCH_LOG"
  TMUX_REVIVE_PICK_CURRENT_SESSION_ID="$alpha_session_id" \
  TMUX_REVIVE_PICK_CURRENT_SESSION_NAME="alpha" \
  TMUX_REVIVE_RESUME_SESSION_CMD="$resume_stub" \
  "$tmux_revive_dir/pick.sh"

  wait_for_file "$resume_log" || fail "revive saved row did not call resume-session"
  resume_args="$(cat "$resume_log")"
  assert_contains "$resume_args" "--guid" "revive saved row resume selector"
  assert_contains "$resume_args" "--yes" "revive saved row resume auto-confirm"
  [ ! -f "$TMUX_TEST_SWITCH_LOG" ] || fail "revive saved row should not switch live client directly"
}
