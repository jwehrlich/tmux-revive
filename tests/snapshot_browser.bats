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

@test "snapshot browser dump items" {
  tmux new-session -d -s alpha
  "$save_state" --reason first-snapshot
  sleep 1
  tmux new-session -d -s beta
  "$save_state" --reason second-snapshot

  output="$("$choose_snapshot" --dump-items)"
  line_count="$(printf '%s\n' "$output" | awk 'NF > 0 { count++ } END { print count + 0 }')"
  first_line="$(printf '%s\n' "$output" | sed -n '1p')"

  assert_eq "2" "$line_count" "snapshot browser dump line count"
  assert_contains "$output" "first-snapshot" "snapshot browser includes first snapshot"
  assert_contains "$output" "second-snapshot" "snapshot browser includes second snapshot"
  assert_contains "$first_line" "second-snapshot" "snapshot browser sorts newest snapshot first"
}

@test "snapshot browser delegates to saved session chooser" {
  tmux new-session -d -s alpha
  "$save_state" --reason browser-session-delegate

  browser_stub="$case_root/browser-choose-session.sh"
  browser_log="$case_root/browser-choose-session.log"
  cat >"$browser_stub" <<EOF
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "\$*" >"$browser_log"
EOF
  chmod +x "$browser_stub"

  selection="$("$choose_snapshot" --dump-items | sed -n '1p')"
  setup_fake_fzf_sequence "$(printf 'alpha\nenter\n%s\n' "$selection")"

  TMUX_REVIVE_CHOOSE_SAVED_SESSION_CMD="$browser_stub" \
  "$choose_snapshot" --yes

  wait_for_file "$browser_log" || fail "snapshot browser did not delegate to saved-session chooser"
  browser_args="$(cat "$browser_log")"
  assert_contains "$browser_args" "--manifest" "snapshot browser session delegate manifest arg"
  assert_contains "$browser_args" "--yes" "snapshot browser session delegate yes arg"
  assert_contains "$browser_args" "--query alpha" "snapshot browser session delegate query arg"
}

@test "snapshot browser delegates restore all" {
  tmux new-session -d -s alpha
  "$save_state" --reason browser-restore-all

  browser_stub="$case_root/browser-restore-all.sh"
  browser_log="$case_root/browser-restore-all.log"
  cat >"$browser_stub" <<EOF
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "\$*" >"$browser_log"
EOF
  chmod +x "$browser_stub"

  selection="$("$choose_snapshot" --dump-items | sed -n '1p')"
  setup_fake_fzf_sequence "$(printf '\nctrl-a\n%s\n' "$selection")"

  TMUX_REVIVE_RESTORE_STATE_CMD="$browser_stub" \
  "$choose_snapshot" --yes --attach

  wait_for_file "$browser_log" || fail "snapshot browser did not delegate to restore-state"
  browser_args="$(cat "$browser_log")"
  assert_contains "$browser_args" "--manifest" "snapshot browser restore-all manifest arg"
  assert_contains "$browser_args" "--yes" "snapshot browser restore-all yes arg"
  assert_contains "$browser_args" "--attach" "snapshot browser restore-all attach arg"
}

@test "snapshot browser configures preview pane" {
  tmux new-session -d -s alpha
  "$save_state" --reason snapshot-browser-preview

  args_log="$case_root/fzf-args.log"
  export TMUX_TEST_FZF_ARGS_LOG="$args_log"
  selection="$("$choose_snapshot" --dump-items | sed -n '1p')"
  setup_fake_fzf_sequence "$(printf '\nenter\n%s\n' "$selection")"

  browser_stub="$case_root/browser-preview-session.sh"
  cat >"$browser_stub" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
  chmod +x "$browser_stub"

  TMUX_REVIVE_CHOOSE_SAVED_SESSION_CMD="$browser_stub" "$choose_snapshot" --yes

  wait_for_file "$args_log" || fail "snapshot browser preview args log missing"
  args_contents="$(cat "$args_log")"
  assert_contains "$args_contents" "--preview=" "snapshot browser configures fzf preview"
  assert_contains "$args_contents" "--preview-window=right:60%:wrap" "snapshot browser preview window"
  unset TMUX_TEST_FZF_ARGS_LOG
}

@test "saved session chooser configures preview pane" {
  tmux new-session -d -s alpha
  "$save_state" --reason saved-session-preview

  args_log="$case_root/fzf-args.log"
  export TMUX_TEST_FZF_ARGS_LOG="$args_log"
  manifest="$(latest_manifest)"
  selection_payload="$("$tmux_revive_dir/choose-saved-session.sh" --manifest "$manifest" --dump-items | sed -n '1p')"
  setup_fake_fzf_sequence "$(printf '\nenter\n%s\n' "$selection_payload")"

  "$tmux_revive_dir/choose-saved-session.sh" --manifest "$manifest" --yes >/dev/null 2>&1 || true

  wait_for_file "$args_log" || fail "saved-session chooser preview args log missing"
  args_contents="$(cat "$args_log")"
  assert_contains "$args_contents" "--preview=" "saved-session chooser configures fzf preview"
  assert_contains "$args_contents" "--preview-window=right:60%:wrap" "saved-session chooser preview window"
  unset TMUX_TEST_FZF_ARGS_LOG
}

@test "saved session chooser rich metadata" {
  tmux new-session -d -s alpha -n main
  tmux new-window -d -t alpha -n logs
  tmux new-window -d -t alpha -n tests
  tmux new-window -d -t alpha -n docs
  tmux new-session -d -s beta -n dev
  "$save_state" --reason chooser-rich-meta
  manifest="$(latest_manifest)"
  tmux kill-session -t beta

  chooser_rows="$("$tmux_revive_dir/choose-saved-session.sh" --manifest "$manifest" --dump-items)"

  assert_contains "$chooser_rows" "chooser-rich-meta" "saved-session chooser includes snapshot reason"
  assert_contains "$chooser_rows" "main, logs, tests +1" "saved-session chooser includes first window summary"
  assert_contains "$chooser_rows" $'\tlive\t' "saved-session chooser marks live sessions"
  assert_contains "$chooser_rows" $'\tsaved\t' "saved-session chooser marks saved sessions"
  assert_contains "$chooser_rows" "LIVE" "saved-session chooser display includes LIVE badge"
  assert_contains "$chooser_rows" "SAVED" "saved-session chooser display includes SAVED badge"
}

@test "snapshot bundle export import roundtrip" {
  tmux new-session -d -s work
  "$save_state" --reason bundle-export
  manifest="$(latest_manifest)"
  bundle_path="$case_root/work-snapshot.tar.gz"

  exported_bundle="$("$export_snapshot" --manifest "$manifest" --output "$bundle_path")"
  assert_eq "$bundle_path" "$exported_bundle" "snapshot bundle export path"
  [ -f "$bundle_path" ] || fail "snapshot bundle export did not create bundle"

  tmux kill-server
  rm -rf "$TMUX_REVIVE_STATE_ROOT"
  mkdir -p "$TMUX_REVIVE_STATE_ROOT"

  imported_manifest="$("$import_snapshot" --bundle "$bundle_path")"
  [ -f "$imported_manifest" ] || fail "snapshot bundle import did not create manifest"
  assert_eq "true" "$(jq -r '.imported // false' "$imported_manifest")" "snapshot bundle imported flag"
  assert_eq "true" "$(jq -r '.source.imported // false' "$imported_manifest")" "snapshot bundle source imported flag"
  assert_contains "$(jq -r '.source.bundle_name // ""' "$imported_manifest")" "work-snapshot.tar.gz" "snapshot bundle source bundle name"

  "$restore_state" --manifest "$imported_manifest" --session-name work --yes >/dev/null
  wait_for_session work || fail "snapshot bundle imported manifest did not restore"
}

@test "imported snapshot missing path message" {
  tmux new-session -d -s work
  "$save_state" --reason import-missing-path
  manifest="$(latest_manifest)"
  bundle_path="$case_root/missing-path.tar.gz"
  "$export_snapshot" --manifest "$manifest" --output "$bundle_path" >/dev/null

  tmux kill-server
  rm -rf "$TMUX_REVIVE_STATE_ROOT"
  mkdir -p "$TMUX_REVIVE_STATE_ROOT"

  imported_manifest="$("$import_snapshot" --bundle "$bundle_path")"
  [ -f "$imported_manifest" ] || fail "import did not create manifest"

  # Tamper with the manifest to point transcript path to a nonexistent file
  fake_path="/nonexistent/imported/machine/transcript.txt"
  manifest_tmp="${imported_manifest}.tmp"
  jq --arg fp "$fake_path" \
    '.sessions[0].windows[0].panes[0].path_to_history_dump = $fp' \
    "$imported_manifest" >"$manifest_tmp"
  mv "$manifest_tmp" "$imported_manifest"

  tmux new-session -d -s bootstrap
  "$restore_state" --manifest "$imported_manifest" --session-name work --yes >/dev/null
  wait_for_session work || fail "imported snapshot with missing path did not restore"

  sleep 1
  pane_content="$(tmux capture-pane -t work -p 2>/dev/null || true)"
  assert_contains "$pane_content" "could not load" "missing path message shown in restored pane"
  assert_contains "$pane_content" "$fake_path" "missing path includes the target path"
}

@test "snapshot browser hides imported by default" {
  tmux new-session -d -s work
  "$save_state" --reason imported-visibility
  manifest="$(latest_manifest)"
  bundle_path="$case_root/imported-only.tar.gz"
  "$export_snapshot" --manifest "$manifest" --output "$bundle_path" >/dev/null

  rm -rf "$TMUX_REVIVE_STATE_ROOT"
  mkdir -p "$TMUX_REVIVE_STATE_ROOT"
  imported_manifest="$("$import_snapshot" --bundle "$bundle_path")"

  default_rows="$("$choose_snapshot" --dump-items)"
  include_rows="$("$choose_snapshot" --dump-items --include-imported)"

  [ -z "$default_rows" ] || fail "snapshot browser should hide imported snapshots by default"
  assert_contains "$include_rows" "$imported_manifest" "snapshot browser include-imported shows imported manifest"
  assert_contains "$include_rows" "imported" "snapshot browser include-imported marks imported snapshots"
}

@test "archive session hides default choosers" {
  tmux new-session -d -s work
  "$save_state" --reason archive-session
  manifest="$(latest_manifest)"
  guid="$(session_guid_for "$manifest" "work")"
  [ -n "$guid" ] || fail "archive-session test missing guid"

  archive_output="$("$archive_session" --session-guid "$guid")"
  assert_contains "$archive_output" $'archived\t' "archive-session archive output"
  status_output="$("$archive_session" --session-guid "$guid" --status)"
  assert_contains "$status_output" $'archived\t' "archive-session status output"

  chooser_default="$("$tmux_revive_dir/choose-saved-session.sh" --manifest "$manifest" --dump-items)"
  chooser_included="$("$tmux_revive_dir/choose-saved-session.sh" --manifest "$manifest" --dump-items --include-archived)"
  [ -z "$chooser_default" ] || fail "archived session should be hidden from default chooser"
  assert_contains "$chooser_included" "work" "archived session shown when include-archived is used"

  pick_default="$("$tmux_revive_dir/pick.sh" --dump-items-raw)"
  pick_included="$(
    TMUX_REVIVE_PICK_INCLUDE_ARCHIVED=true \
    "$tmux_revive_dir/pick.sh" --dump-items-raw
  )"
  assert_not_contains "$pick_default" $'saved\tguid\t'"$guid" "archived session hidden from default revive saved rows"
  assert_contains "$pick_included" $'saved\tguid\t'"$guid" "archived session shown in revive when include archived is enabled"

  unarchive_output="$("$archive_session" --session-guid "$guid" --unarchive)"
  assert_contains "$unarchive_output" $'active\t' "archive-session unarchive output"
}

@test "archived sessions do not trigger startup prompt" {
  tmux new-session -d -s work
  "$save_state" --reason archived-startup
  manifest="$(latest_manifest)"
  guid="$(session_guid_for "$manifest" "work")"
  [ -n "$guid" ] || fail "archived startup test missing guid"
  "$archive_session" --session-guid "$guid" >/dev/null

  tmux kill-server
  tmux new-session -d -s bootstrap
  tmux set-option -g @tmux-revive-startup-restore prompt
  rm -f "$TMUX_TEST_DISPLAY_POPUP_LOG"

  "$startup_restore" --client-tty test-tty

  [ ! -f "$TMUX_TEST_DISPLAY_POPUP_LOG" ] || fail "archived session should not trigger startup prompt"
}
