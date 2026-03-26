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

# ── Phase 0: Preview ─────────────────────────────────────────────────

@test "preview-item.sh exits 0 for header rows" {
  run "$tmux_revive_dir/preview-item.sh" header header "" "" "" "" ""
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "preview-item.sh exits 0 for nav rows" {
  run "$tmux_revive_dir/preview-item.sh" nav back "" "" "" "" ""
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "preview-item.sh shows windows for live session" {
  tmux new-session -d -s work
  session_id="$(tmux display-message -p -t work '#{session_id}')"
  run "$tmux_revive_dir/preview-item.sh" live session "$session_id" work work "" ""
  [ "$status" -eq 0 ]
  assert_contains "$output" "panes" "preview shows pane count for live session"
}

@test "preview-item.sh shows panes for live window" {
  tmux new-session -d -s work
  window_id="$(tmux list-windows -t work -F '#{window_id}' | head -1)"
  run "$tmux_revive_dir/preview-item.sh" live window "$window_id" work "work:1" "" ""
  [ "$status" -eq 0 ]
  assert_contains "$output" ":" "preview shows pane info for live window"
}

@test "preview-item.sh captures pane content" {
  tmux new-session -d -s work
  pane_id="$(tmux list-panes -t work -F '#{pane_id}' | head -1)"
  run "$tmux_revive_dir/preview-item.sh" live pane "$pane_id" work "work:1.1" "" ""
  [ "$status" -eq 0 ]
}

@test "preview-item.sh shows saved session preview" {
  tmux new-session -d -s work
  "$save_state" --reason preview-saved-test
  manifest="$(latest_manifest)"
  guid="$(session_guid_for "$manifest" "work")"

  run "$tmux_revive_dir/preview-item.sh" saved guid "$guid" work "$guid" "$manifest" "$restore_state"
  [ "$status" -eq 0 ]
  [ -n "$output" ]
}

@test "preview-item.sh handles stale session gracefully" {
  run "$tmux_revive_dir/preview-item.sh" live session "\$999" gone gone "" ""
  [ "$status" -eq 0 ]
  assert_contains "$output" "no longer exists" "preview reports stale session"
}

@test "preview-item.sh shows snapshot preview" {
  tmux new-session -d -s work
  "$save_state" --reason snapshot-preview-test
  manifest="$(latest_manifest)"

  run "$tmux_revive_dir/preview-item.sh" snapshot manifest "$manifest" "manual" "1" "" "$restore_state"
  [ "$status" -eq 0 ]
  [ -n "$output" ]
}

@test "revive fzf invocation includes preview flags" {
  tmux new-session -d -s alpha
  "$save_state" --reason preview-fzf-test

  alpha_session_id="$(tmux display-message -p -t alpha '#{session_id}')"
  items="$(
    TMUX_REVIVE_PICK_CURRENT_SESSION_ID="$alpha_session_id" \
    TMUX_REVIVE_PICK_CURRENT_SESSION_NAME="alpha" \
    "$tmux_revive_dir/pick.sh" --dump-items
  )"
  saved_row="$(printf '%s\n' "$items" | awk -F '\t' '$1 == "saved" { print; exit }')"
  [ -n "$saved_row" ] || fail "no saved row for preview fzf test"

  # Use fake fzf to capture args
  setup_fake_fzf_sequence "$(printf '\nenter\n%s\n' "$saved_row")"
  export TMUX_TEST_FZF_ARGS_LOG="$case_root/fzf-args.log"
  resume_stub="$case_root/resume-stub.sh"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$resume_stub"
  chmod +x "$resume_stub"

  TMUX_REVIVE_PICK_CURRENT_SESSION_ID="$alpha_session_id" \
  TMUX_REVIVE_PICK_CURRENT_SESSION_NAME="alpha" \
  TMUX_REVIVE_RESUME_SESSION_CMD="$resume_stub" \
  "$tmux_revive_dir/pick.sh"

  fzf_args="$(cat "$TMUX_TEST_FZF_ARGS_LOG")"
  assert_contains "$fzf_args" "--preview" "fzf invocation includes --preview"
  assert_contains "$fzf_args" "preview-item.sh" "fzf preview references preview-item.sh"
  assert_contains "$fzf_args" "--preview-window" "fzf invocation includes --preview-window"
}

# ── Phase 0.5: Flag Forwarding ───────────────────────────────────────

@test "resume_saved_item forwards --manifest to resume-session" {
  tmux new-session -d -s alpha
  tmux new-session -d -s beta
  "$save_state" --reason flag-forward-manifest

  tmux kill-session -t beta
  manifest="$(latest_manifest)"
  alpha_session_id="$(tmux display-message -p -t alpha '#{session_id}')"
  items="$(
    TMUX_REVIVE_PICK_CURRENT_SESSION_ID="$alpha_session_id" \
    TMUX_REVIVE_PICK_CURRENT_SESSION_NAME="alpha" \
    "$tmux_revive_dir/pick.sh" --manifest "$manifest" --dump-items
  )"
  saved_row="$(printf '%s\n' "$items" | awk -F '\t' '$1 == "saved" && $4 == "beta" { print; exit }')"
  [ -n "$saved_row" ] || fail "no saved row for flag forward test"

  setup_fake_fzf_sequence "$(printf '\nenter\n%s\n' "$saved_row")"
  resume_log="$case_root/resume-args.log"
  resume_stub="$case_root/resume-stub.sh"
  cat >"$resume_stub" <<STUB
#!/usr/bin/env bash
printf '%s\n' "\$*" >"$resume_log"
exit 0
STUB
  chmod +x "$resume_stub"

  TMUX_REVIVE_PICK_CURRENT_SESSION_ID="$alpha_session_id" \
  TMUX_REVIVE_PICK_CURRENT_SESSION_NAME="alpha" \
  TMUX_REVIVE_RESUME_SESSION_CMD="$resume_stub" \
  "$tmux_revive_dir/pick.sh" --manifest "$manifest"

  wait_for_file "$resume_log" || fail "resume-session was not called"
  resume_args="$(cat "$resume_log")"
  assert_contains "$resume_args" "--manifest" "resume-session gets --manifest"
  assert_contains "$resume_args" "$manifest" "resume-session gets correct manifest path"
  assert_contains "$resume_args" "--yes" "resume-session gets --yes"
}

@test "resume_saved_item forwards --attach" {
  tmux new-session -d -s alpha
  tmux new-session -d -s beta
  "$save_state" --reason flag-forward-attach
  tmux kill-session -t beta

  alpha_session_id="$(tmux display-message -p -t alpha '#{session_id}')"
  items="$(
    TMUX_REVIVE_PICK_CURRENT_SESSION_ID="$alpha_session_id" \
    TMUX_REVIVE_PICK_CURRENT_SESSION_NAME="alpha" \
    "$tmux_revive_dir/pick.sh" --dump-items
  )"
  saved_row="$(printf '%s\n' "$items" | awk -F '\t' '$1 == "saved" && $4 == "beta" { print; exit }')"
  [ -n "$saved_row" ] || fail "no saved row"

  setup_fake_fzf_sequence "$(printf '\nenter\n%s\n' "$saved_row")"
  resume_log="$case_root/resume-args.log"
  resume_stub="$case_root/resume-stub.sh"
  cat >"$resume_stub" <<STUB
#!/usr/bin/env bash
printf '%s\n' "\$*" >"$resume_log"
exit 0
STUB
  chmod +x "$resume_stub"

  TMUX_REVIVE_PICK_CURRENT_SESSION_ID="$alpha_session_id" \
  TMUX_REVIVE_PICK_CURRENT_SESSION_NAME="alpha" \
  TMUX_REVIVE_RESUME_SESSION_CMD="$resume_stub" \
  "$tmux_revive_dir/pick.sh" --attach

  wait_for_file "$resume_log" || fail "resume-session was not called"
  resume_args="$(cat "$resume_log")"
  assert_contains "$resume_args" "--attach" "resume-session gets --attach"
}

@test "resume_saved_item forwards --no-attach" {
  tmux new-session -d -s alpha
  tmux new-session -d -s beta
  "$save_state" --reason flag-forward-no-attach
  tmux kill-session -t beta

  alpha_session_id="$(tmux display-message -p -t alpha '#{session_id}')"
  items="$(
    TMUX_REVIVE_PICK_CURRENT_SESSION_ID="$alpha_session_id" \
    TMUX_REVIVE_PICK_CURRENT_SESSION_NAME="alpha" \
    "$tmux_revive_dir/pick.sh" --dump-items
  )"
  saved_row="$(printf '%s\n' "$items" | awk -F '\t' '$1 == "saved" && $4 == "beta" { print; exit }')"
  [ -n "$saved_row" ] || fail "no saved row"

  setup_fake_fzf_sequence "$(printf '\nenter\n%s\n' "$saved_row")"
  resume_log="$case_root/resume-args.log"
  resume_stub="$case_root/resume-stub.sh"
  cat >"$resume_stub" <<STUB
#!/usr/bin/env bash
printf '%s\n' "\$*" >"$resume_log"
exit 0
STUB
  chmod +x "$resume_stub"

  TMUX_REVIVE_PICK_CURRENT_SESSION_ID="$alpha_session_id" \
  TMUX_REVIVE_PICK_CURRENT_SESSION_NAME="alpha" \
  TMUX_REVIVE_RESUME_SESSION_CMD="$resume_stub" \
  "$tmux_revive_dir/pick.sh" --no-attach

  wait_for_file "$resume_log" || fail "resume-session was not called"
  resume_args="$(cat "$resume_log")"
  assert_contains "$resume_args" "--no-attach" "resume-session gets --no-attach"
}

@test "pick.sh --query prefills fzf search" {
  tmux new-session -d -s alpha

  alpha_session_id="$(tmux display-message -p -t alpha '#{session_id}')"

  # fzf returns empty (Esc) — we just want to verify args
  setup_fake_fzf_sequence "$(printf '\n\n\n')"
  export TMUX_TEST_FZF_ARGS_LOG="$case_root/fzf-args.log"

  TMUX_REVIVE_PICK_CURRENT_SESSION_ID="$alpha_session_id" \
  TMUX_REVIVE_PICK_CURRENT_SESSION_NAME="alpha" \
  "$tmux_revive_dir/pick.sh" --query "test-query" || true

  fzf_args="$(cat "$TMUX_TEST_FZF_ARGS_LOG")"
  assert_contains "$fzf_args" "--query=test-query" "fzf receives --query"
}

# ── Phase 1: Snapshot Browsing ────────────────────────────────────────

@test "snapshots are hidden by default in dump-items-raw" {
  tmux new-session -d -s alpha
  "$save_state" --reason snapshot-hidden-test

  alpha_session_id="$(tmux display-message -p -t alpha '#{session_id}')"
  output="$(
    TMUX_REVIVE_PICK_CURRENT_SESSION_ID="$alpha_session_id" \
    TMUX_REVIVE_PICK_CURRENT_SESSION_NAME="alpha" \
    "$tmux_revive_dir/pick.sh" --dump-items-raw
  )"
  snapshot_count="$(printf '%s\n' "$output" | awk -F '\t' '$1 == "snapshot"' | wc -l | tr -d ' ')"
  assert_eq "0" "$snapshot_count" "snapshots hidden by default"
}

@test "snapshots appear with --show-snapshots" {
  tmux new-session -d -s alpha
  "$save_state" --reason snapshot-show-test

  alpha_session_id="$(tmux display-message -p -t alpha '#{session_id}')"
  output="$(
    TMUX_REVIVE_PICK_SHOW_SNAPSHOTS=true \
    TMUX_REVIVE_PICK_CURRENT_SESSION_ID="$alpha_session_id" \
    TMUX_REVIVE_PICK_CURRENT_SESSION_NAME="alpha" \
    "$tmux_revive_dir/pick.sh" --show-snapshots --dump-items-raw
  )"
  snapshot_header="$(printf '%s\n' "$output" | awk -F '\t' '$1 == "header" && $6 == "SNAPSHOTS"')"
  snapshot_rows="$(printf '%s\n' "$output" | awk -F '\t' '$1 == "snapshot"' | wc -l | tr -d ' ')"
  [ -n "$snapshot_header" ] || fail "SNAPSHOTS header missing with --show-snapshots"
  [ "$snapshot_rows" -gt 0 ] || fail "no snapshot rows with --show-snapshots"
}

@test "snapshot row contains manifest path and metadata" {
  tmux new-session -d -s alpha
  "$save_state" --reason snapshot-meta-test
  manifest="$(latest_manifest)"

  alpha_session_id="$(tmux display-message -p -t alpha '#{session_id}')"
  output="$(
    TMUX_REVIVE_PICK_CURRENT_SESSION_ID="$alpha_session_id" \
    TMUX_REVIVE_PICK_CURRENT_SESSION_NAME="alpha" \
    "$tmux_revive_dir/pick.sh" --show-snapshots --dump-items-raw
  )"
  snapshot_row="$(printf '%s\n' "$output" | awk -F '\t' '$1 == "snapshot" { print; exit }')"
  [ -n "$snapshot_row" ] || fail "no snapshot row"

  # Field 3 = manifest path (id field)
  row_manifest="$(printf '%s\n' "$snapshot_row" | cut -f3)"
  assert_eq "$manifest" "$row_manifest" "snapshot row contains correct manifest path"

  # Field 4 = reason (session_name field, repurposed)
  row_reason="$(printf '%s\n' "$snapshot_row" | cut -f4)"
  assert_eq "snapshot-meta-test" "$row_reason" "snapshot row contains reason"
}

@test "back-nav row appears when viewing non-latest snapshot" {
  tmux new-session -d -s alpha
  "$save_state" --reason snap-old
  old_manifest="$(latest_manifest)"
  sleep 1
  "$save_state" --reason snap-new
  new_manifest="$(latest_manifest)"

  alpha_session_id="$(tmux display-message -p -t alpha '#{session_id}')"
  output="$(
    TMUX_REVIVE_PICK_CURRENT_SESSION_ID="$alpha_session_id" \
    TMUX_REVIVE_PICK_CURRENT_SESSION_NAME="alpha" \
    TMUX_REVIVE_PICK_MANIFEST_PATH="$old_manifest" \
    "$tmux_revive_dir/pick.sh" --manifest "$old_manifest" --dump-items-raw
  )"
  nav_row="$(printf '%s\n' "$output" | awk -F '\t' '$1 == "nav" && $2 == "back"')"
  [ -n "$nav_row" ] || fail "back-nav row missing when viewing old snapshot"
}

@test "no back-nav row when viewing latest snapshot" {
  tmux new-session -d -s alpha
  "$save_state" --reason snap-latest

  alpha_session_id="$(tmux display-message -p -t alpha '#{session_id}')"
  output="$(
    TMUX_REVIVE_PICK_CURRENT_SESSION_ID="$alpha_session_id" \
    TMUX_REVIVE_PICK_CURRENT_SESSION_NAME="alpha" \
    "$tmux_revive_dir/pick.sh" --dump-items-raw
  )"
  nav_count="$(printf '%s\n' "$output" | awk -F '\t' '$1 == "nav"' | wc -l | tr -d ' ')"
  assert_eq "0" "$nav_count" "no nav rows for latest snapshot"
}

@test "ctrl-a restore-all invokes restore-state" {
  tmux new-session -d -s alpha
  tmux new-session -d -s beta
  "$save_state" --reason ctrl-a-test
  tmux kill-session -t beta

  alpha_session_id="$(tmux display-message -p -t alpha '#{session_id}')"
  items="$(
    TMUX_REVIVE_PICK_CURRENT_SESSION_ID="$alpha_session_id" \
    TMUX_REVIVE_PICK_CURRENT_SESSION_NAME="alpha" \
    "$tmux_revive_dir/pick.sh" --dump-items
  )"
  saved_row="$(printf '%s\n' "$items" | awk -F '\t' '$1 == "saved" { print; exit }')"
  [ -n "$saved_row" ] || fail "no saved row for ctrl-a test"

  setup_fake_fzf_sequence "$(printf '\nctrl-a\n%s\n' "$saved_row")"
  restore_log="$case_root/restore-args.log"
  restore_stub="$case_root/restore-stub.sh"
  cat >"$restore_stub" <<STUB
#!/usr/bin/env bash
printf '%s\n' "\$*" >"$restore_log"
exit 0
STUB
  chmod +x "$restore_stub"

  TMUX_REVIVE_PICK_CURRENT_SESSION_ID="$alpha_session_id" \
  TMUX_REVIVE_PICK_CURRENT_SESSION_NAME="alpha" \
  TMUX_REVIVE_RESTORE_STATE_CMD="$restore_stub" \
  "$tmux_revive_dir/pick.sh"

  wait_for_file "$restore_log" || fail "ctrl-a did not invoke restore-state"
  restore_args="$(cat "$restore_log")"
  assert_contains "$restore_args" "--yes" "ctrl-a passes --yes"
}

# ── Phase 2: Startup Mode ────────────────────────────────────────────

@test "startup mode shows only saved sessions" {
  tmux new-session -d -s work
  "$save_state" --reason startup-mode-test
  tmux kill-session -t work
  tmux new-session -d -s bootstrap

  manifest="$(latest_manifest)"
  output="$(
    "$tmux_revive_dir/pick.sh" --context startup --manifest "$manifest" --dump-items-raw
  )"

  # Should have saved sessions but no live tree
  live_count="$(printf '%s\n' "$output" | awk -F '\t' '$1 == "live"' | wc -l | tr -d ' ')"
  saved_count="$(printf '%s\n' "$output" | awk -F '\t' '$1 == "saved"' | wc -l | tr -d ' ')"
  assert_eq "0" "$live_count" "startup mode has no live rows"
  [ "$saved_count" -gt 0 ] || fail "startup mode has no saved rows"
}

@test "startup mode defaults to --attach in resume" {
  tmux new-session -d -s work
  "$save_state" --reason startup-attach-default
  tmux kill-session -t work
  tmux new-session -d -s bootstrap

  manifest="$(latest_manifest)"
  items="$(
    "$tmux_revive_dir/pick.sh" --context startup --manifest "$manifest" --dump-items
  )"
  saved_row="$(printf '%s\n' "$items" | awk -F '\t' '$1 == "saved" { print; exit }')"
  [ -n "$saved_row" ] || fail "no saved row in startup mode"

  setup_fake_fzf_sequence "$(printf '\nenter\n%s\n' "$saved_row")"
  resume_log="$case_root/resume-args.log"
  resume_stub="$case_root/resume-stub.sh"
  cat >"$resume_stub" <<STUB
#!/usr/bin/env bash
printf '%s\n' "\$*" >"$resume_log"
exit 0
STUB
  chmod +x "$resume_stub"

  TMUX_REVIVE_RESUME_SESSION_CMD="$resume_stub" \
  "$tmux_revive_dir/pick.sh" --context startup --manifest "$manifest"

  wait_for_file "$resume_log" || fail "resume-session not called in startup mode"
  resume_args="$(cat "$resume_log")"
  assert_contains "$resume_args" "--attach" "startup mode defaults to --attach"
}

@test "startup mode dismiss sets suppress flag" {
  tmux new-session -d -s work
  "$save_state" --reason startup-dismiss-test
  tmux kill-session -t work
  tmux new-session -d -s bootstrap

  manifest="$(latest_manifest)"
  dismissed_path="$(tmux_revive_restore_prompt_suppressed_path)"
  rm -f "$dismissed_path"

  # Create a fake fzf that exits 130 (Esc dismiss)
  setup_fake_fzf_sequence "unused"
  rm -f "$case_root/fzf-sequence/"*.txt
  # With no queue files, fake fzf exits 1, which pick.sh treats as dismiss

  "$tmux_revive_dir/pick.sh" --context startup --manifest "$manifest" || true

  [ -f "$dismissed_path" ] || fail "dismiss flag not set in startup mode"
}

@test "new-session context dismiss does not set suppress flag" {
  tmux new-session -d -s work
  "$save_state" --reason new-session-dismiss-test
  tmux kill-session -t work
  tmux new-session -d -s bootstrap

  manifest="$(latest_manifest)"
  dismissed_path="$(tmux_revive_restore_prompt_suppressed_path)"
  rm -f "$dismissed_path"

  setup_fake_fzf_sequence ""

  "$tmux_revive_dir/pick.sh" --context new-session --manifest "$manifest" || true

  [ ! -f "$dismissed_path" ] || fail "new-session context should not set dismiss flag"
}

@test "startup mode fzf has select-1 and exit-0" {
  tmux new-session -d -s work
  "$save_state" --reason startup-select1-test
  tmux kill-session -t work
  tmux new-session -d -s bootstrap

  manifest="$(latest_manifest)"

  # Verify the fzf args include --select-1 and --exit-0
  items="$(
    "$tmux_revive_dir/pick.sh" --context startup --manifest "$manifest" --dump-items
  )"
  saved_row="$(printf '%s\n' "$items" | awk -F '\t' '$1 == "saved" { print; exit }')"
  [ -n "$saved_row" ] || fail "no saved row"

  setup_fake_fzf_sequence "$(printf '\nenter\n%s\n' "$saved_row")"
  export TMUX_TEST_FZF_ARGS_LOG="$case_root/fzf-args.log"
  resume_log="$case_root/resume-args.log"
  resume_stub="$case_root/resume-stub.sh"
  cat >"$resume_stub" <<STUB
#!/usr/bin/env bash
printf '%s\n' "\$*" >"$resume_log"
exit 0
STUB
  chmod +x "$resume_stub"

  TMUX_REVIVE_RESUME_SESSION_CMD="$resume_stub" \
  "$tmux_revive_dir/pick.sh" --context startup --manifest "$manifest"

  wait_for_file "$resume_log" || fail "startup mode did not auto-resume"
  fzf_args="$(cat "$TMUX_TEST_FZF_ARGS_LOG")"
  assert_contains "$fzf_args" "--select-1" "startup mode has --select-1"
  assert_contains "$fzf_args" "--exit-0" "startup mode has --exit-0"
}

@test "maybe-show-startup-popup launches pick.sh" {
  tmux new-session -d -s work
  "$save_state" --reason popup-launches-pick
  tmux kill-server
  tmux new-session -d -s bootstrap
  tmux set-option -g @tmux-revive-startup-restore prompt
  rm -f "$TMUX_TEST_DISPLAY_POPUP_LOG"

  "$startup_restore" --client-tty test-tty

  wait_for_file "$TMUX_TEST_DISPLAY_POPUP_LOG" || fail "startup did not open popup"
  popup_cmd="$(cat "$TMUX_TEST_DISPLAY_POPUP_LOG")"
  assert_contains "$popup_cmd" "pick.sh" "popup launches pick.sh"
  assert_contains "$popup_cmd" "--context" "popup passes --context"
}

@test "startup context shows popup when saved session 0 collides with default" {
  # Saved session named "0" should still be restorable on startup even though
  # the fresh tmux server auto-creates a default session also named "0".
  tmux new-session -d  # creates default session "0"
  "$save_state" --reason startup-zero-collision
  tmux kill-server

  # Fresh start — new default session "0"
  tmux new-session -d -s bootstrap
  tmux set-option -g @tmux-revive-startup-restore prompt
  rm -f "$TMUX_TEST_DISPLAY_POPUP_LOG"

  "$startup_restore" --client-tty test-tty

  wait_for_file "$TMUX_TEST_DISPLAY_POPUP_LOG" || fail "startup popup did not appear when saved session 0 collides with default"
  popup_cmd="$(cat "$TMUX_TEST_DISPLAY_POPUP_LOG")"
  assert_contains "$popup_cmd" "pick.sh" "startup collision popup launches pick.sh"
}

@test "startup context shows popup when only saved session matches running session" {
  # Even when the only saved session has the same name as the only running session,
  # startup context should still prompt (the running session is transient).
  tmux new-session -d -s work
  "$save_state" --reason startup-same-name
  tmux kill-server

  tmux new-session -d -s work  # same name as saved
  tmux set-option -g @tmux-revive-startup-restore prompt
  rm -f "$TMUX_TEST_DISPLAY_POPUP_LOG"

  "$startup_restore" --client-tty test-tty

  wait_for_file "$TMUX_TEST_DISPLAY_POPUP_LOG" || fail "startup popup did not appear when saved session name matches running session"
}

# ── Phase 3: Session Labels ──────────────────────────────────────────

@test "session label appears in revive output" {
  tmux new-session -d -s work
  tmux set-option -t work -q @tmux-revive-session-label "my-project"

  session_id="$(tmux display-message -p -t work '#{session_id}')"
  output="$(
    TMUX_REVIVE_PICK_CURRENT_SESSION_ID="$session_id" \
    TMUX_REVIVE_PICK_CURRENT_SESSION_NAME="work" \
    "$tmux_revive_dir/pick.sh" --dump-items-raw
  )"
  session_row="$(printf '%s\n' "$output" | awk -F '\t' '$1 == "live" && $2 == "session" && $4 == "work" { print; exit }')"
  [ -n "$session_row" ] || fail "session row missing"
  assert_contains "$session_row" "label: my-project" "session label appears in tree"
}

@test "session label same as name is not shown" {
  tmux new-session -d -s work
  tmux set-option -t work -q @tmux-revive-session-label "work"

  session_id="$(tmux display-message -p -t work '#{session_id}')"
  output="$(
    TMUX_REVIVE_PICK_CURRENT_SESSION_ID="$session_id" \
    TMUX_REVIVE_PICK_CURRENT_SESSION_NAME="work" \
    "$tmux_revive_dir/pick.sh" --dump-items-raw
  )"
  session_row="$(printf '%s\n' "$output" | awk -F '\t' '$1 == "live" && $2 == "session" && $4 == "work" { print; exit }')"
  assert_not_contains "$session_row" "label:" "label matching session name is hidden"
}

# ── Server Isolation ─────────────────────────────────────────────────

@test "auto-detect server name from TMUX variable" {
  output="$(
    TMUX="/private/tmp/tmux-501/my-named-server,123,0" \
    TMUX_REVIVE_TMUX_SERVER="" \
    TMUX_REVIVE_SOCKET_PATH="" \
    bash -c 'source "'"$tmux_revive_dir"'/lib/state-common.sh" 2>/dev/null; printf "%s\n" "${TMUX_REVIVE_TMUX_SERVER:-}"'
  )"
  assert_eq "my-named-server" "$output" "server name auto-detected from TMUX"
}

@test "no server name for default socket" {
  output="$(
    TMUX="/private/tmp/tmux-501/default,123,0" \
    TMUX_REVIVE_TMUX_SERVER="" \
    TMUX_REVIVE_SOCKET_PATH="" \
    bash -c 'source "'"$tmux_revive_dir"'/lib/state-common.sh" 2>/dev/null; printf "%s\n" "${TMUX_REVIVE_TMUX_SERVER:-UNSET}"'
  )"
  assert_eq "UNSET" "$output" "no server name for default socket"
}

@test "literal socket_path format variable is ignored" {
  output="$(
    TMUX="/private/tmp/tmux-501/default,123,0" \
    TMUX_REVIVE_TMUX_SERVER="" \
    TMUX_REVIVE_SOCKET_PATH='#{socket_path}' \
    bash -c 'source "'"$tmux_revive_dir"'/lib/state-common.sh" 2>/dev/null; printf "%s\n" "${TMUX_REVIVE_TMUX_SERVER:-UNSET}"'
  )"
  assert_eq "UNSET" "$output" "literal #{socket_path} does not set server name"
}

@test "literal socket_path falls back to TMUX for named server" {
  output="$(
    TMUX="/private/tmp/tmux-501/my-server,123,0" \
    TMUX_REVIVE_TMUX_SERVER="" \
    TMUX_REVIVE_SOCKET_PATH='#{socket_path}' \
    bash -c 'source "'"$tmux_revive_dir"'/lib/state-common.sh" 2>/dev/null; printf "%s\n" "${TMUX_REVIVE_TMUX_SERVER:-UNSET}"'
  )"
  assert_eq "my-server" "$output" "falls back to TMUX when socket_path is literal"
}

@test "explicit TMUX_REVIVE_TMUX_SERVER takes precedence" {
  output="$(
    TMUX="/private/tmp/tmux-501/other-server,123,0" \
    TMUX_REVIVE_TMUX_SERVER="explicit" \
    TMUX_REVIVE_SOCKET_PATH="/private/tmp/tmux-501/another" \
    bash -c 'source "'"$tmux_revive_dir"'/lib/state-common.sh" 2>/dev/null; printf "%s\n" "${TMUX_REVIVE_TMUX_SERVER:-UNSET}"'
  )"
  assert_eq "explicit" "$output" "explicit server takes precedence"
}

@test "TMUX_REVIVE_SOCKET_PATH with real path sets server" {
  output="$(
    TMUX="" \
    TMUX_REVIVE_TMUX_SERVER="" \
    TMUX_REVIVE_SOCKET_PATH="/private/tmp/tmux-501/my-real-server" \
    bash -c 'source "'"$tmux_revive_dir"'/lib/state-common.sh" 2>/dev/null; printf "%s\n" "${TMUX_REVIVE_TMUX_SERVER:-UNSET}"'
  )"
  assert_eq "my-real-server" "$output" "real socket path sets server name"
}

# ── CLI Argument Parsing ─────────────────────────────────────────────

@test "pick.sh rejects unknown arguments" {
  run "$tmux_revive_dir/pick.sh" --bogus-flag
  [ "$status" -ne 0 ]
}

@test "pick.sh --transient-session is alias for --cleanup-transient-session" {
  tmux new-session -d -s alpha
  tmux new-session -d -s beta
  "$save_state" --reason transient-alias-test
  tmux kill-session -t beta

  alpha_session_id="$(tmux display-message -p -t alpha '#{session_id}')"
  items="$(
    TMUX_REVIVE_PICK_CURRENT_SESSION_ID="$alpha_session_id" \
    TMUX_REVIVE_PICK_CURRENT_SESSION_NAME="alpha" \
    "$tmux_revive_dir/pick.sh" --dump-items
  )"
  saved_row="$(printf '%s\n' "$items" | awk -F '\t' '$1 == "saved" && $4 == "beta" { print; exit }')"
  [ -n "$saved_row" ] || fail "no saved row"

  setup_fake_fzf_sequence "$(printf '\nenter\n%s\n' "$saved_row")"
  resume_log="$case_root/resume-args.log"
  resume_stub="$case_root/resume-stub.sh"
  cat >"$resume_stub" <<STUB
#!/usr/bin/env bash
printf '%s\n' "\$*" >"$resume_log"
exit 0
STUB
  chmod +x "$resume_stub"

  TMUX_REVIVE_PICK_CURRENT_SESSION_ID="$alpha_session_id" \
  TMUX_REVIVE_PICK_CURRENT_SESSION_NAME="alpha" \
  TMUX_REVIVE_RESUME_SESSION_CMD="$resume_stub" \
  "$tmux_revive_dir/pick.sh" --transient-session test-session

  wait_for_file "$resume_log" || fail "resume not called"
  resume_args="$(cat "$resume_log")"
  assert_contains "$resume_args" "--cleanup-transient-session" "transient forwarded as cleanup"
  assert_contains "$resume_args" "test-session" "transient session target forwarded"
}

# ── End-to-End Restoration via Revive ────────────────────────────────

@test "revive end-to-end restore via saved row" {
  tmux new-session -d -s alpha
  tmux new-session -d -s beta -c /tmp
  "$save_state" --reason e2e-restore

  tmux kill-session -t beta
  manifest="$(latest_manifest)"
  alpha_session_id="$(tmux display-message -p -t alpha '#{session_id}')"
  items="$(
    TMUX_REVIVE_PICK_CURRENT_SESSION_ID="$alpha_session_id" \
    TMUX_REVIVE_PICK_CURRENT_SESSION_NAME="alpha" \
    "$tmux_revive_dir/pick.sh" --dump-items
  )"
  saved_row="$(printf '%s\n' "$items" | awk -F '\t' '$1 == "saved" && $4 == "beta" { print; exit }')"
  [ -n "$saved_row" ] || fail "no saved beta row for e2e test"

  setup_fake_fzf_sequence "$(printf '\nenter\n%s\n' "$saved_row")"

  TMUX_REVIVE_PICK_CURRENT_SESSION_ID="$alpha_session_id" \
  TMUX_REVIVE_PICK_CURRENT_SESSION_NAME="alpha" \
  "$tmux_revive_dir/pick.sh" --no-attach

  wait_for_session beta || fail "beta session was not restored via revive"
}

@test "revive ctrl-a restores all sessions" {
  tmux new-session -d -s alpha
  tmux new-session -d -s beta
  "$save_state" --reason e2e-restore-all

  tmux kill-session -t beta
  alpha_session_id="$(tmux display-message -p -t alpha '#{session_id}')"
  items="$(
    TMUX_REVIVE_PICK_CURRENT_SESSION_ID="$alpha_session_id" \
    TMUX_REVIVE_PICK_CURRENT_SESSION_NAME="alpha" \
    "$tmux_revive_dir/pick.sh" --dump-items
  )"
  # Select any row (ctrl-a works regardless of selection)
  any_row="$(printf '%s\n' "$items" | awk -F '\t' '$1 == "live" && $2 == "session" { print; exit }')"
  [ -n "$any_row" ] || fail "no row for ctrl-a test"

  setup_fake_fzf_sequence "$(printf '\nctrl-a\n%s\n' "$any_row")"

  TMUX_REVIVE_PICK_CURRENT_SESSION_ID="$alpha_session_id" \
  TMUX_REVIVE_PICK_CURRENT_SESSION_NAME="alpha" \
  "$tmux_revive_dir/pick.sh" --no-attach || true

  wait_for_session beta || fail "beta session was not restored via ctrl-a"
}
