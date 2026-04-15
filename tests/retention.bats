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

@test "snapshot retention count policy" {
  now_epoch="$(date +%s)"

  unused_manifest_path="$(create_fake_snapshot_manifest "manual-old-1" "$((now_epoch - 600))" "manual-old-1" "manual")"
  unused_manifest_path="$(create_fake_snapshot_manifest "manual-old-2" "$((now_epoch - 500))" "manual-old-2" "manual")"
  unused_manifest_path="$(create_fake_snapshot_manifest "manual-newest" "$((now_epoch - 400))" "manual-newest" "manual")"
  unused_manifest_path="$(create_fake_snapshot_manifest "auto-old" "$((now_epoch - 300))" "auto-old" "auto")"
  latest_manifest_path="$(create_fake_snapshot_manifest "auto-latest" "$((now_epoch - 200))" "auto-latest" "auto" false false true)"
  keep_manifest_path="$(create_fake_snapshot_manifest "manual-kept" "$((now_epoch - 700))" "manual-kept" "manual" true false false)"
  imported_manifest_path="$(create_fake_snapshot_manifest "auto-imported" "$((now_epoch - 800))" "auto-imported" "auto" false true false)"

  output="$(
    TMUX_REVIVE_RETENTION_MANUAL_COUNT=1 \
    TMUX_REVIVE_RETENTION_AUTO_COUNT=1 \
    TMUX_REVIVE_RETENTION_MANUAL_AGE_DAYS=0 \
    TMUX_REVIVE_RETENTION_AUTO_AGE_DAYS=0 \
    "$prune_snapshots" --dry-run --print-actions
  )"

  assert_contains "$output" $'keep\tmanual\t' "retention count dry-run keep manual row"
  assert_contains "$output" "$keep_manifest_path"$'\texplicit-keep' "retention count explicit keep carve-out"
  assert_contains "$output" "$imported_manifest_path"$'\timported' "retention count imported carve-out"
  assert_contains "$output" "$latest_manifest_path"$'\tlatest' "retention count latest carve-out"
  assert_contains "$output" "manual-old-1/manifest.json"$'\tcount' "retention count prunes oldest manual snapshot"
  assert_contains "$output" "manual-old-2/manifest.json"$'\tcount' "retention count prunes second-oldest manual snapshot"
  assert_contains "$output" "auto-old/manifest.json"$'\tcount' "retention count prunes older auto snapshot"

  TMUX_REVIVE_RETENTION_MANUAL_COUNT=1 \
  TMUX_REVIVE_RETENTION_AUTO_COUNT=1 \
  TMUX_REVIVE_RETENTION_MANUAL_AGE_DAYS=0 \
  TMUX_REVIVE_RETENTION_AUTO_AGE_DAYS=0 \
  "$prune_snapshots" >/dev/null

  [ ! -d "$(dirname "$TMUX_REVIVE_STATE_ROOT/snapshots/$host_name/manual-old-1/manifest.json")" ] || fail "manual-old-1 snapshot was not pruned"
  [ ! -d "$(dirname "$TMUX_REVIVE_STATE_ROOT/snapshots/$host_name/manual-old-2/manifest.json")" ] || fail "manual-old-2 snapshot was not pruned"
  [ ! -d "$(dirname "$TMUX_REVIVE_STATE_ROOT/snapshots/$host_name/auto-old/manifest.json")" ] || fail "auto-old snapshot was not pruned"
  [ -f "$keep_manifest_path" ] || fail "kept snapshot was pruned unexpectedly"
  [ -f "$imported_manifest_path" ] || fail "imported snapshot was pruned unexpectedly"
  [ -f "$latest_manifest_path" ] || fail "latest snapshot was pruned unexpectedly"
}

@test "snapshot retention age policy" {
  now_epoch="$(date +%s)"

  old_manifest_path="$(create_fake_snapshot_manifest "manual-aged-out" "$((now_epoch - (10 * 86400)))" "manual-aged-out" "manual")"
  latest_manifest_path="$(create_fake_snapshot_manifest "manual-fresh" "$((now_epoch - 60))" "manual-fresh" "manual" false false true)"

  output="$(
    TMUX_REVIVE_RETENTION_MANUAL_COUNT=0 \
    TMUX_REVIVE_RETENTION_MANUAL_AGE_DAYS=5 \
    TMUX_REVIVE_RETENTION_AUTO_COUNT=0 \
    TMUX_REVIVE_RETENTION_AUTO_AGE_DAYS=5 \
    "$prune_snapshots" --dry-run --print-actions
  )"

  assert_contains "$output" "$old_manifest_path"$'\tage' "retention age prunes old manual snapshot"
  assert_contains "$output" "$latest_manifest_path"$'\tlatest' "retention age keeps latest snapshot"

  TMUX_REVIVE_RETENTION_MANUAL_COUNT=0 \
  TMUX_REVIVE_RETENTION_MANUAL_AGE_DAYS=5 \
  TMUX_REVIVE_RETENTION_AUTO_COUNT=0 \
  TMUX_REVIVE_RETENTION_AUTO_AGE_DAYS=5 \
  "$prune_snapshots" >/dev/null

  [ ! -f "$old_manifest_path" ] || fail "aged-out snapshot was not pruned"
  [ -f "$latest_manifest_path" ] || fail "fresh latest snapshot was pruned unexpectedly"
}

@test "snapshot retention OR logic" {
  now_epoch="$(date +%s)"

  # Create snapshots: recent (within age) but exceeding count limit
  # With OR logic, count-exceeded alone should trigger pruning
  unused_manifest_path="$(create_fake_snapshot_manifest "auto-recent-1" "$((now_epoch - 120))" "auto-recent-1" "auto")"
  unused_manifest_path="$(create_fake_snapshot_manifest "auto-recent-2" "$((now_epoch - 100))" "auto-recent-2" "auto")"
  latest_manifest_path="$(create_fake_snapshot_manifest "auto-recent-3" "$((now_epoch - 60))" "auto-recent-3" "auto" false false true)"

  # COUNT=1 AGE_DAYS=1: count is exceeded (3 > 1) but all are within age (< 1 day)
  # Under OR logic: should prune because count is exceeded
  output="$(
    TMUX_REVIVE_RETENTION_AUTO_COUNT=1 \
    TMUX_REVIVE_RETENTION_AUTO_AGE_DAYS=1 \
    TMUX_REVIVE_RETENTION_MANUAL_COUNT=1 \
    TMUX_REVIVE_RETENTION_MANUAL_AGE_DAYS=1 \
    "$prune_snapshots" --dry-run --print-actions
  )"

  assert_contains "$output" "auto-recent-1/manifest.json"$'\tcount' "retention OR logic prunes recent snapshot exceeding count"
  assert_contains "$output" "$latest_manifest_path"$'\tlatest' "retention OR logic keeps latest snapshot"

  # Now add an old snapshot that exceeds BOTH limits
  old_manifest_path="$(create_fake_snapshot_manifest "auto-old" "$((now_epoch - (3 * 86400)))" "auto-old" "auto")"

  # COUNT=2 AGE_DAYS=1: old snapshot exceeds age (3 days > 1) and count is exceeded (4 > 2)
  output="$(
    TMUX_REVIVE_RETENTION_AUTO_COUNT=2 \
    TMUX_REVIVE_RETENTION_AUTO_AGE_DAYS=1 \
    TMUX_REVIVE_RETENTION_MANUAL_COUNT=2 \
    TMUX_REVIVE_RETENTION_MANUAL_AGE_DAYS=1 \
    "$prune_snapshots" --dry-run --print-actions
  )"

  assert_contains "$output" "$old_manifest_path"$'\tage-and-count' "retention OR logic prunes old snapshot exceeding both limits"
}

@test "save state applies retention policy" {
  now_epoch="$(date +%s)"
  old_manifest_path="$(create_fake_snapshot_manifest "manual-before-save" "$((now_epoch - 600))" "manual-before-save" "manual" false false true)"
  prune_wrapper_log="$case_root/prune-wrapper.log"
  prune_wrapper="$case_root/prune-wrapper.sh"

  cat >"$prune_wrapper" <<EOF
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "\$*" >"$prune_wrapper_log"
exec bash "$prune_snapshots" "\$@"
EOF
  chmod +x "$prune_wrapper"

  tmux new-session -d -s work
  tmux set-option -g @tmux-revive-retention-enabled on
  tmux set-option -g @tmux-revive-retention-manual-count 1
  tmux set-option -g @tmux-revive-retention-manual-age-days 0
  tmux set-option -g @tmux-revive-retention-auto-count 10
  tmux set-option -g @tmux-revive-retention-auto-age-days 0

  TMUX_REVIVE_PRUNE_SNAPSHOTS_CMD="$prune_wrapper" "$save_state" --reason retention-integration

  new_latest_manifest="$(latest_manifest)"
  [ -f "$new_latest_manifest" ] || fail "save-state retention integration did not produce a latest manifest"
  [ "$new_latest_manifest" != "$old_manifest_path" ] || fail "save-state retention integration did not publish a new manifest"
  # Prune now runs in the background — wait for it to complete
  wait_for_file "$prune_wrapper_log" || fail "save-state retention integration did not call prune wrapper"
  wait_for_path_missing "$old_manifest_path" || fail "save-state retention integration did not prune the old manifest"
  manifest_count="$(find "$TMUX_REVIVE_STATE_ROOT/snapshots/$host_name" -type f -name manifest.json | wc -l | tr -d ' ')"
  assert_eq "1" "$manifest_count" "save-state retention integration manifest count"
  assert_eq "manual" "$(jq -r '.save_mode' "$new_latest_manifest")" "save-state retention integration save mode"
}

@test "retention boundary values" {
  tmux new-session -d -s work

  # Create several snapshots
  for i in 1 2 3; do
    "$save_state" --reason "retention-boundary-$i"
    sleep 1
  done

  snapshots_root="$(tmux_revive_snapshots_root)"
  count_before="$(find "$snapshots_root" -name manifest.json | wc -l | tr -d ' ')"
  [ "$count_before" -ge 3 ] || fail "not enough snapshots created for retention test"

  # Set retention to keep only 2 manual snapshots (disable age limit so
  # count-only pruning triggers on these fresh snapshots)
  export TMUX_REVIVE_RETENTION_MANUAL_COUNT=2
  export TMUX_REVIVE_RETENTION_MANUAL_AGE_DAYS=0
  "$save_state" --reason "retention-trigger"

  # Prune runs async — wait for it to take effect
  local attempts=0
  while [ "$attempts" -lt 50 ]; do
    count_after="$(find "$snapshots_root" -name manifest.json | wc -l | tr -d ' ')"
    [ "$count_after" -ge "$count_before" ] || break
    sleep 0.2
    attempts=$((attempts + 1))
  done
  count_after="$(find "$snapshots_root" -name manifest.json | wc -l | tr -d ' ')"
  [ "$count_after" -le "$count_before" ] || fail "retention policy did not prune (before=$count_before after=$count_after)"
  unset TMUX_REVIVE_RETENTION_MANUAL_COUNT TMUX_REVIVE_RETENTION_MANUAL_AGE_DAYS
}

@test "retention zero limits" {
  tmux new-session -d -s work

  for i in 1 2 3 4; do
    "$save_state" --reason "zero-limit-$i"
    sleep 1
  done

  snapshots_root="$(tmux_revive_snapshots_root)"
  count_before="$(find "$snapshots_root" -name manifest.json | wc -l | tr -d ' ')"
  [ "$count_before" -ge 4 ] || fail "not enough snapshots created"

  # Both limits zero = keep everything
  export TMUX_REVIVE_RETENTION_MANUAL_COUNT=0
  export TMUX_REVIVE_RETENTION_MANUAL_AGE_DAYS=0
  "$save_state" --reason "zero-both-trigger"
  sleep 1
  count_after="$(find "$snapshots_root" -name manifest.json | wc -l | tr -d ' ')"
  [ "$count_after" -ge "$count_before" ] || fail "both=0 should keep all (before=$count_before after=$count_after)"

  # Count-only zero (age non-zero but all snapshots are fresh) = keep everything
  export TMUX_REVIVE_RETENTION_MANUAL_COUNT=0
  export TMUX_REVIVE_RETENTION_MANUAL_AGE_DAYS=1
  "$save_state" --reason "zero-count-trigger"
  sleep 1
  count_after2="$(find "$snapshots_root" -name manifest.json | wc -l | tr -d ' ')"
  [ "$count_after2" -ge "$count_after" ] || fail "count=0 should not prune fresh snapshots (before=$count_after after=$count_after2)"

  # Age-only zero, count non-zero = prune by count only
  export TMUX_REVIVE_RETENTION_MANUAL_COUNT=2
  export TMUX_REVIVE_RETENTION_MANUAL_AGE_DAYS=0
  "$save_state" --reason "zero-age-trigger"
  # Wait for async prune to complete
  local attempts=0
  while [ "$attempts" -lt 50 ]; do
    count_after3="$(find "$snapshots_root" -name manifest.json | wc -l | tr -d ' ')"
    [ "$count_after3" -gt 3 ] || break
    sleep 0.2
    attempts=$((attempts + 1))
  done
  count_after3="$(find "$snapshots_root" -name manifest.json | wc -l | tr -d ' ')"
  [ "$count_after3" -le 3 ] || fail "age=0 count=2 should prune to ~2 kept (got $count_after3)"

  unset TMUX_REVIVE_RETENTION_MANUAL_COUNT TMUX_REVIVE_RETENTION_MANUAL_AGE_DAYS
}

@test "prune does not block save completion" {
  now_epoch="$(date +%s)"
  create_fake_snapshot_manifest "manual-old" "$((now_epoch - 600))" "manual-old" "manual" false false true

  prune_wrapper_log="$case_root/prune-wrapper.log"
  prune_wrapper="$case_root/prune-wrapper.sh"

  # Slow prune wrapper that sleeps to simulate heavy prune work
  cat >"$prune_wrapper" <<EOF
#!/usr/bin/env bash
set -euo pipefail
printf 'started\n' >"$prune_wrapper_log"
sleep 2
printf 'done\n' >>"$prune_wrapper_log"
EOF
  chmod +x "$prune_wrapper"

  tmux new-session -d -s work
  tmux set-option -g @tmux-revive-retention-enabled on

  start_time="$(date +%s)"
  TMUX_REVIVE_PRUNE_SNAPSHOTS_CMD="$prune_wrapper" "$save_state" --reason prune-async-test
  end_time="$(date +%s)"

  elapsed=$((end_time - start_time))
  # Save should return well before the 2s sleep in the prune wrapper
  [ "$elapsed" -lt 2 ] || fail "save blocked on prune (took ${elapsed}s, expected <2s)"

  # Prune should still start in the background
  wait_for_file "$prune_wrapper_log" || fail "prune wrapper was not called"
  assert_contains "$(head -1 "$prune_wrapper_log")" "started" "prune wrapper started"
}

@test "retention count-only prune with both limits configured" {
  now_epoch="$(date +%s)"

  # 5 auto snapshots, all within age (< 1 day), but count=2 should prune the excess
  for i in 1 2 3 4; do
    create_fake_snapshot_manifest "auto-s$i" "$((now_epoch - (500 - i * 100)))" "auto-s$i" "auto"
  done
  create_fake_snapshot_manifest "auto-s5" "$((now_epoch - 10))" "auto-s5" "auto" false false true

  output="$(
    TMUX_REVIVE_RETENTION_AUTO_COUNT=2 \
    TMUX_REVIVE_RETENTION_AUTO_AGE_DAYS=14 \
    TMUX_REVIVE_RETENTION_MANUAL_COUNT=100 \
    TMUX_REVIVE_RETENTION_MANUAL_AGE_DAYS=0 \
    "$prune_snapshots" --dry-run --print-actions
  )"

  # With OR logic, count=2 should prune the 3 oldest even though age (14d) isn't exceeded
  prune_count="$(printf '%s\n' "$output" | grep -c $'^prune\t' || true)"
  [ "$prune_count" -ge 2 ] || fail "expected at least 2 pruned snapshots, got $prune_count; output: $output"
}
