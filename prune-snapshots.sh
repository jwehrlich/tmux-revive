#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/parse-server-arg.sh
source "$script_dir/lib/parse-server-arg.sh"
# shellcheck source=lib/state-common.sh
source "$script_dir/lib/state-common.sh"

dry_run="false"
print_actions="false"
action_log_path="${TMUX_REVIVE_RETENTION_ACTION_LOG:-}"

print_help() {
  cat <<'EOF'
Usage: prune-snapshots.sh [options]

Prune old tmux-revive snapshots according to retention policy.

Options:
  --help           Show this help text
  --dry-run        Do not delete anything
  --print-actions  Print keep/prune decisions
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --help|-h)
      print_help
      exit 0
      ;;
    --dry-run)
      dry_run="true"
      shift
      ;;
    --print-actions)
      print_actions="true"
      shift
      ;;
    --server)
      export TMUX_REVIVE_TMUX_SERVER="${2:?--server requires a name}"
      shift 2
      ;;
    *)
      printf 'Unknown argument: %s\n' "$1" >&2
      exit 1
      ;;
  esac
done

sanitize_nonnegative_int() {
  local value="${1:-0}"
  local fallback="${2:-0}"
  case "$value" in
    ''|*[!0-9]*)
      printf '%s\n' "$fallback"
      ;;
    *)
      printf '%s\n' "$value"
      ;;
  esac
}

snapshot_epoch_for_manifest() {
  local manifest_path="$1"
  local epoch=""

  epoch="$(jq -r '.last_updated_epoch // .created_at_epoch // 0' "$manifest_path" 2>/dev/null || printf '0')"
  case "$epoch" in
    ''|*[!0-9]*)
      epoch=0
      ;;
  esac
  if [ "$epoch" -gt 0 ]; then
    printf '%s\n' "$epoch"
    return 0
  fi

  stat -c '%Y' "$manifest_path" 2>/dev/null || stat -f '%m' "$manifest_path" 2>/dev/null || printf '0\n'
}

snapshot_class_for_manifest() {
  local manifest_path="$1"
  jq -r '
    if ((.save_mode // .retention_class // "") != "")
    then (.save_mode // .retention_class)
    elif ((.reason // "") | test("^(client-detached|queued)$"))
    then "auto"
    else "manual"
    end
  ' "$manifest_path" 2>/dev/null || printf 'manual\n'
}

snapshot_keep_flag_for_manifest() {
  local manifest_path="$1"
  jq -r '(.keep // .retention.keep // false)' "$manifest_path" 2>/dev/null || printf 'false\n'
}

snapshot_imported_flag_for_manifest() {
  local manifest_path="$1"
  jq -r '(.imported // .source.imported // false)' "$manifest_path" 2>/dev/null || printf 'false\n'
}

# Read all four retention-relevant fields from a manifest in one jq call.
# Output: tab-separated  epoch \t class \t keep \t imported
snapshot_retention_fields() {
  local manifest_path="$1"
  local result
  result="$(jq -r '[
    (.last_updated_epoch // .created_at_epoch // 0 | tostring),
    (if ((.save_mode // .retention_class // "") != "")
     then (.save_mode // .retention_class)
     elif ((.reason // "") | test("^(client-detached|queued)$"))
     then "auto"
     else "manual"
     end),
    (.keep // .retention.keep // false | tostring),
    (.imported // .source.imported // false | tostring)
  ] | join("\t")' "$manifest_path" 2>/dev/null || printf '0\tmanual\tfalse\tfalse')"
  printf '%s\n' "$result"
}

emit_action() {
  local action="$1"
  local snapshot_class="$2"
  local epoch="$3"
  local manifest_path="$4"
  local reason="$5"

  if [ -n "$action_log_path" ]; then
    mkdir -p "$(dirname "$action_log_path")"
    printf '%s\t%s\t%s\t%s\t%s\n' "$action" "$snapshot_class" "$epoch" "$manifest_path" "$reason" >>"$action_log_path"
  fi
  [ "$print_actions" = "true" ] || return 0
  printf '%s\t%s\t%s\t%s\t%s\n' "$action" "$snapshot_class" "$epoch" "$manifest_path" "$reason"
}

retention_enabled="$(tmux_revive_get_env_or_global_option "TMUX_REVIVE_RETENTION_ENABLED" "$(tmux_revive_retention_enabled_option)" "on")"
if ! tmux_revive_option_enabled "$retention_enabled"; then
  exit 0
fi

auto_count_limit="$(sanitize_nonnegative_int "$(tmux_revive_get_env_or_global_option "TMUX_REVIVE_RETENTION_AUTO_COUNT" "$(tmux_revive_retention_auto_count_option)" "20")" "20")"
manual_count_limit="$(sanitize_nonnegative_int "$(tmux_revive_get_env_or_global_option "TMUX_REVIVE_RETENTION_MANUAL_COUNT" "$(tmux_revive_retention_manual_count_option)" "60")" "60")"
auto_age_days="$(sanitize_nonnegative_int "$(tmux_revive_get_env_or_global_option "TMUX_REVIVE_RETENTION_AUTO_AGE_DAYS" "$(tmux_revive_retention_auto_age_days_option)" "14")" "14")"
manual_age_days="$(sanitize_nonnegative_int "$(tmux_revive_get_env_or_global_option "TMUX_REVIVE_RETENTION_MANUAL_AGE_DAYS" "$(tmux_revive_retention_manual_age_days_option)" "90")" "90")"

snapshots_root="$(tmux_revive_snapshots_root)"
[ -d "$snapshots_root" ] || exit 0

latest_manifest="$(tmux_revive_find_latest_manifest || true)"
now_epoch="$(date +%s)"

manifest_rows="$(
  find "$snapshots_root" -type f -name manifest.json -print0 \
  | xargs -0 -P 4 -I{} sh -c '
    _epoch="$(jq -r "[
      (.last_updated_epoch // .created_at_epoch // 0 | tostring),
      (if ((.save_mode // .retention_class // \"\") != \"\")
       then (.save_mode // .retention_class)
       elif ((.reason // \"\") | test(\"^(client-detached|queued)$\"))
       then \"auto\"
       else \"manual\"
       end),
      (.keep // .retention.keep // false | tostring),
      (.imported // .source.imported // false | tostring)
    ] | join(\"\t\")" "$1" 2>/dev/null || printf "0\tmanual\tfalse\tfalse")"
    printf "%s\t%s\n" "$_epoch" "$1"
  ' _ {} \
  | while IFS=$'\t' read -r epoch snapshot_class keep_flag imported_flag manifest_path; do
    case "$epoch" in ''|*[!0-9]*) epoch=0 ;; esac
    if [ "$epoch" -le 0 ]; then
      epoch="$(stat -c '%Y' "$manifest_path" 2>/dev/null || stat -f '%m' "$manifest_path" 2>/dev/null || printf '0')"
    fi
    printf '%s\t%s\t%s\t%s\t%s\n' "$epoch" "$snapshot_class" "$keep_flag" "$imported_flag" "$manifest_path"
  done | sort -t $'\t' -k1,1nr -k5,5r
)"

[ -n "$manifest_rows" ] || exit 0

manual_kept=0
auto_kept=0

while IFS=$'\t' read -r epoch snapshot_class keep_flag imported_flag manifest_path; do
  [ -n "${manifest_path:-}" ] || continue
  snapshot_dir="$(dirname "$manifest_path")"
  case "$snapshot_class" in
    auto)
      count_limit="$auto_count_limit"
      age_days="$auto_age_days"
      kept_count="$auto_kept"
      ;;
    *)
      snapshot_class="manual"
      count_limit="$manual_count_limit"
      age_days="$manual_age_days"
      kept_count="$manual_kept"
      ;;
  esac
  action="keep"
  action_reason="retained"

  if [ -n "$latest_manifest" ] && [ "$manifest_path" = "$latest_manifest" ]; then
    action_reason="latest"
    if [ "$snapshot_class" = "auto" ]; then
      auto_kept=$((auto_kept + 1))
    else
      manual_kept=$((manual_kept + 1))
    fi
  elif [ "$keep_flag" = "true" ]; then
    action_reason="explicit-keep"
  elif [ "$imported_flag" = "true" ]; then
    action_reason="imported"
  else
    age_exceeded="false"
    count_exceeded="false"
    age_seconds=$(( now_epoch - epoch ))
    [ "$age_seconds" -lt 0 ] && age_seconds=0
    if [ "$age_days" -gt 0 ] && [ "$epoch" -gt 0 ] && [ "$age_seconds" -gt $((age_days * 86400)) ]; then
      age_exceeded="true"
    fi
    if [ "$count_limit" -gt 0 ] && [ "$kept_count" -ge "$count_limit" ]; then
      count_exceeded="true"
    fi

    # Prune when ANY active limit says the snapshot should go.
    # A zero limit means "don't limit by this dimension".
    # When both limits are active: prune if either exceeded (OR).
    # When only one limit is active: prune if that one is exceeded.
    should_prune="false"
    if [ "$age_exceeded" = "true" ] || [ "$count_exceeded" = "true" ]; then
      should_prune="true"
    fi

    if [ "$should_prune" = "true" ]; then
      action="prune"
      if [ "$age_exceeded" = "true" ] && [ "$count_exceeded" = "true" ]; then
        action_reason="age-and-count"
      elif [ "$age_exceeded" = "true" ]; then
        action_reason="age"
      else
        action_reason="count"
      fi
    else
      if [ "$snapshot_class" = "auto" ]; then
        auto_kept=$((auto_kept + 1))
      else
        manual_kept=$((manual_kept + 1))
      fi
    fi
  fi

  emit_action "$action" "$snapshot_class" "$epoch" "$manifest_path" "$action_reason"
  if [ "$action" = "prune" ] && [ "$dry_run" != "true" ]; then
    rm -rf "$snapshot_dir"
  fi
done <<<"$manifest_rows"
