#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/parse-server-arg.sh
source "$script_dir/lib/parse-server-arg.sh"
# shellcheck source=lib/state-common.sh
source "$script_dir/lib/state-common.sh"

report_path=""

while [ $# -gt 0 ]; do
  case "$1" in
    --report)
      report_path="${2:-}"
      shift 2
      ;;
    --help|-h)
      cat <<'EOF'
Usage: show-restore-report.sh [--report PATH]

Render a tmux-revive restore report.

Options:
  --report PATH   Render a specific restore report JSON file
  --help          Show this help text

If --report is omitted, the latest restore report is used.
EOF
      exit 0
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

[ -n "$report_path" ] || report_path="$(tmux_revive_latest_restore_report_path)"
[ -f "$report_path" ] || {
  printf '%s\n' "tmux-revive: restore report not found: $report_path" >&2
  exit 1
}

jq -r '
  def section($title; $items):
    [($title + " (" + (($items | length) | tostring) + "):")]
    + (if ($items | length) > 0 then ($items | map("- " + .)) else ["- none"] end);

  [
    "tmux-revive restore report",
    "",
    ("Snapshot: " + (.snapshot.created_at // "-")),
    ("Reason: " + ((.snapshot.reason // "") | if . == "" then "-" else . end)),
    ("Manifest: " + (.snapshot.manifest_path // "-")),
    ("Host: " + ((.snapshot.host // "") | if . == "" then "-" else . end)),
    ("Attach target: " + ((.attach_target // "") | if . == "" then "-" else . end)),
    ("Log: " + ((.log_path // "") | if . == "" then "-" else . end)),
    ("Summary: " + ((.summary // "") | if . == "" then "-" else . end)),
    ""
  ]
  + section("Restored"; .restore)
  + [""]
  + section("Skipped existing"; .skipped_existing)
  + [""]
  + section("Grouped session issues"; .grouped_issues)
  + [""]
  + section("Health warnings"; .health_warnings)
  + [""]
  + section("Pane fallbacks"; .pane_fallbacks)
  | .[]
' "$report_path"
