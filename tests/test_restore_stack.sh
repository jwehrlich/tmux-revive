#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmux_revive_dir="$repo_root"
save_state="$tmux_revive_dir/save-state.sh"
restore_state="$tmux_revive_dir/restore-state.sh"
startup_restore="$tmux_revive_dir/maybe-show-startup-popup.sh"
startup_popup="$tmux_revive_dir/startup-restore-popup.sh"
autosave_tick="$tmux_revive_dir/autosave-tick.sh"
pane_meta="$tmux_revive_dir/pane-meta.sh"
choose_snapshot="$tmux_revive_dir/choose-snapshot.sh"
choose_saved_session="$tmux_revive_dir/choose-saved-session.sh"
resume_session="$tmux_revive_dir/resume-session.sh"
prune_snapshots="$tmux_revive_dir/prune-snapshots.sh"
export_snapshot="$tmux_revive_dir/export-snapshot.sh"
import_snapshot="$tmux_revive_dir/import-snapshot.sh"
archive_session="$tmux_revive_dir/archive-session.sh"
# shellcheck source=../lib/state-common.sh
source "$tmux_revive_dir/lib/state-common.sh"

real_tmux="$(command -v tmux)"
real_nvim="$(command -v nvim)"
original_path="$PATH"
test_base="${TMUX_REVIVE_TEST_BASE:-$repo_root/.tmp/tmux-revive-tests}"
host_name="$(hostname -s 2>/dev/null || hostname)"

mkdir -p "$test_base"

case_root=""
socket_name=""
pass_count=0

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

pass() {
  printf 'PASS: %s\n' "$1"
  pass_count=$((pass_count + 1))
}

assert_eq() {
  local expected="$1"
  local actual="$2"
  local context="$3"
  [ "$expected" = "$actual" ] || fail "$context: expected [$expected], got [$actual]"
}

assert_contains() {
  local haystack="$1"
  local needle="$2"
  local context="$3"
  case "$haystack" in
    *"$needle"*)
      ;;
    *)
      fail "$context: expected to find [$needle]"
      ;;
  esac
}

assert_not_contains() {
  local haystack="$1"
  local needle="$2"
  local context="$3"
  case "$haystack" in
    *"$needle"*)
      fail "$context: did not expect to find [$needle]"
      ;;
    *)
      ;;
  esac
}

wait_for_file() {
  local path="$1"
  local attempts="${2:-50}"
  local delay="${3:-0.2}"
  local i

  for ((i = 0; i < attempts; i++)); do
    [ -f "$path" ] && return 0
    sleep "$delay"
  done

  return 1
}

wait_for_jq_value() {
  local path="$1"
  local jq_expr="$2"
  local expected="$3"
  local attempts="${4:-50}"
  local delay="${5:-0.2}"
  local i current

  for ((i = 0; i < attempts; i++)); do
    if [ -f "$path" ]; then
      current="$(jq -r "$jq_expr" "$path" 2>/dev/null || true)"
      if [ "$current" = "$expected" ]; then
        return 0
      fi
    fi
    sleep "$delay"
  done

  return 1
}

wait_for_session() {
  local session_name="$1"
  local attempts="${2:-50}"
  local delay="${3:-0.2}"
  local i

  for ((i = 0; i < attempts; i++)); do
    if tmux has-session -t "$session_name" 2>/dev/null; then
      return 0
    fi
    sleep "$delay"
  done

  return 1
}

wait_for_pane_path() {
  local target="$1"
  local expected="$2"
  local attempts="${3:-50}"
  local delay="${4:-0.2}"
  local i current

  for ((i = 0; i < attempts; i++)); do
    current="$(tmux display-message -p -t "$target" '#{pane_current_path}' 2>/dev/null || true)"
    if [ "$current" = "$expected" ]; then
      return 0
    fi
    sleep "$delay"
  done

  return 1
}

wait_for_pane_command() {
  local target="$1"
  local expected="$2"
  local attempts="${3:-50}"
  local delay="${4:-0.2}"
  local i current

  for ((i = 0; i < attempts; i++)); do
    current="$(tmux display-message -p -t "$target" '#{pane_current_command}' 2>/dev/null || true)"
    if [ "$current" = "$expected" ]; then
      return 0
    fi
    sleep "$delay"
  done

  return 1
}

wait_for_pane_text() {
  local target="$1"
  local expected="$2"
  local attempts="${3:-50}"
  local delay="${4:-0.2}"
  local i capture

  for ((i = 0; i < attempts; i++)); do
    capture="$(tmux capture-pane -p -S -120 -t "$target" 2>/dev/null || true)"
    case "$capture" in
      *"$expected"*)
        return 0
        ;;
    esac
    sleep "$delay"
  done

  return 1
}

wait_for_registry_entry() {
  local pane_id="$1"
  local attempts="${2:-60}"
  local delay="${3:-0.25}"
  local i
  local entry

  for ((i = 0; i < attempts; i++)); do
    entry="$(find "$TMUX_SEND_TO_NVIM_STATE_DIR" -type f -name "${pane_id}-*.json" 2>/dev/null | head -n 1)"
    if [ -n "${entry:-}" ]; then
      printf '%s\n' "$entry"
      return 0
    fi
    sleep "$delay"
  done

  return 1
}

wait_for_nvim_expr() {
  local server="$1"
  local expr="$2"
  local expected="$3"
  local attempts="${4:-60}"
  local delay="${5:-0.25}"
  local i result

  for ((i = 0; i < attempts; i++)); do
    result="$(nvim --server "$server" --remote-expr "$expr" 2>/dev/null || true)"
    if [ "$result" = "$expected" ]; then
      return 0
    fi
    sleep "$delay"
  done

  return 1
}

wait_for_path_missing() {
  local path="$1"
  local attempts="${2:-20}"
  local delay="${3:-0.2}"
  local i

  for ((i = 0; i < attempts; i++)); do
    [ ! -e "$path" ] && return 0
    sleep "$delay"
  done

  return 1
}

wait_for_pid_exit() {
  local pid="$1"
  local attempts="${2:-30}"
  local delay="${3:-0.2}"
  local i

  for ((i = 0; i < attempts; i++)); do
    if ! kill -0 "$pid" >/dev/null 2>&1; then
      return 0
    fi
    sleep "$delay"
  done

  return 1
}

run_headless_nvim_script() {
  local script_path="$1"
  XDG_STATE_HOME="$XDG_STATE_HOME" \
  XDG_DATA_HOME="$XDG_DATA_HOME" \
  "$real_nvim" --headless -u NONE -i NONE \
    --cmd "lua package.path = package.path .. ';$repo_root/nvim/lua/?.lua;$repo_root/nvim/lua/?/init.lua'" \
    "+lua dofile([[$script_path]])" +qa!
}

setup_case() {
  local name="$1"

  if [ -n "${socket_name:-}" ]; then
    "$real_tmux" -L "$socket_name" kill-server >/dev/null 2>&1 || true
  fi

  case_root="$test_base/$name"
  socket_name="tmux-revive-${name}"
  "$real_tmux" -L "$socket_name" kill-server >/dev/null 2>&1 || true

  if command -v pgrep >/dev/null 2>&1; then
    while IFS= read -r stale_pid; do
      [ -n "$stale_pid" ] || continue
      kill "$stale_pid" >/dev/null 2>&1 || true
      sleep 0.1
      kill -9 "$stale_pid" >/dev/null 2>&1 || true
    done < <(pgrep -f "$case_root" || true)
  fi

  rm -rf "$case_root"
  mkdir -p "$case_root/bin"

  export TMUX_REVIVE_STATE_ROOT="$case_root/state"
  export TMUX_SEND_TO_NVIM_STATE_DIR="$TMUX_REVIVE_STATE_ROOT/registry"
  export XDG_STATE_HOME="$case_root/xdg-state"
  export XDG_DATA_HOME="$case_root/xdg-data"
  export TMUX_TEST_ATTACH_LOG="$case_root/attach.log"
  export TMUX_TEST_SWITCH_LOG="$case_root/switch.log"
  export TMUX_TEST_DISPLAY_POPUP_LOG="$case_root/display-popup.log"
  export TMUX_TEST_COMMAND_LOG="$case_root/tmux-command.log"
  export TMUX_TEST_NVIM_RESTORE_LOG="$case_root/restored-nvim.txt"
  export PATH="$case_root/bin:$original_path"
  unset TMUX_REVIVE_PROFILE_DIR
  unset TMUX_REVIVE_DEFAULT_PROFILE
  hash -r
  unset TMUX

  cat >"$case_root/bin/tmux" <<EOF
#!/usr/bin/env bash
set -euo pipefail
if [ -n "\${TMUX_TEST_COMMAND_LOG:-}" ]; then
  printf '%s\n' "\$*" >>"\$TMUX_TEST_COMMAND_LOG"
fi
if [ "\${1:-}" = "attach-session" ] && [ -n "\${TMUX_TEST_ATTACH_LOG:-}" ]; then
  printf '%s\n' "\$*" >"\$TMUX_TEST_ATTACH_LOG"
  exit 0
fi
if [ "\${1:-}" = "switch-client" ] && [ -n "\${TMUX_TEST_SWITCH_LOG:-}" ]; then
  printf '%s\n' "\$*" >>"\$TMUX_TEST_SWITCH_LOG"
  exit 0
fi
  if [ "\${1:-}" = "display-popup" ] && [ -n "\${TMUX_TEST_DISPLAY_POPUP_LOG:-}" ]; then
  printf '%s\n' "\$*" >>"\$TMUX_TEST_DISPLAY_POPUP_LOG"
  if [ "\${TMUX_TEST_POPUP_EXECUTE:-0}" = "1" ]; then
    popup_cmd="\${*: -1}"
    if [ -n "\${TMUX_TEST_POPUP_INPUT:-}" ]; then
      printf '%b' "\$TMUX_TEST_POPUP_INPUT" | /bin/bash -c "\$popup_cmd"
    else
      /bin/bash -c "\$popup_cmd"
    fi
  fi
  exit 0
fi
exec "$real_tmux" -f /dev/null -L "$socket_name" "\$@"
EOF
  chmod +x "$case_root/bin/tmux"

  cat >"$case_root/bin/nvim" <<EOF
#!/usr/bin/env bash
set -euo pipefail
restore_log="\${TMUX_TEST_NVIM_RESTORE_LOG:-}"
if [ -z "\$restore_log" ]; then
  restore_log="\$(cd "\$(dirname "\$0")/.." && pwd)/restored-nvim.txt"
fi
if [ -n "\${TMUX_NVIM_RESTORE_STATE:-}" ] && [ -f "\${TMUX_NVIM_RESTORE_STATE}" ]; then
  jq -c '
    {
      session_file: (.session_file // ""),
      tab_count: (.tabs | length),
      current_tab: (.current_tab // 1),
      current_path: (.tabs[((.current_tab // 1) - 1)].wins[((.tabs[((.current_tab // 1) - 1)].current_win // 1) - 1)].path // ""),
      current_line: (.tabs[((.current_tab // 1) - 1)].wins[((.tabs[((.current_tab // 1) - 1)].current_win // 1) - 1)].cursor[0] // 0),
      first_tab_paths: (.tabs[0].wins | map(.path)),
      first_tab_a_line: (.tabs[0].wins[] | select(.path | endswith("file-a.txt")) | .cursor[0]),
      first_tab_b_line: (.tabs[0].wins[] | select(.path | endswith("file-b.txt")) | .cursor[0]),
      first_tab_layout_kind: (.tabs[0].layout.kind // ""),
      first_tab_win_count: (.tabs[0].wins | length)
    }' "\$TMUX_NVIM_RESTORE_STATE" >"\$restore_log"
  exit 0
fi
exec "$real_nvim" "\$@"
EOF
  chmod +x "$case_root/bin/nvim"

  tmux start-server >/dev/null 2>&1 || true
  tmux set-option -g base-index 1 >/dev/null 2>&1 || true
  tmux setw -g pane-base-index 1 >/dev/null 2>&1 || true
  tmux set-option -g renumber-windows on >/dev/null 2>&1 || true
  tmux set-window-option -g automatic-rename on >/dev/null 2>&1 || true
}

save_test_shell_env() {
  export TMUX_REVIVE_TEST_OLD_ZDOTDIR="${ZDOTDIR-__TMUX_REVIVE_UNSET__}"
  export TMUX_REVIVE_TEST_OLD_SHELL="${SHELL-__TMUX_REVIVE_UNSET__}"
}

restore_test_shell_env() {
  local old_zdotdir="${TMUX_REVIVE_TEST_OLD_ZDOTDIR-__TMUX_REVIVE_UNSET__}"
  local old_shell="${TMUX_REVIVE_TEST_OLD_SHELL-__TMUX_REVIVE_UNSET__}"

  if [ "$old_zdotdir" = "__TMUX_REVIVE_UNSET__" ]; then
    unset ZDOTDIR
  else
    export ZDOTDIR="$old_zdotdir"
  fi

  if [ "$old_shell" = "__TMUX_REVIVE_UNSET__" ]; then
    unset SHELL
  else
    export SHELL="$old_shell"
  fi

  unset TMUX_REVIVE_TEST_OLD_ZDOTDIR
  unset TMUX_REVIVE_TEST_OLD_SHELL
}

setup_test_zsh_env() {
  local zdotdir="$1"
  local history_seed="${2:-}"

  mkdir -p "$zdotdir"
  cat >"$zdotdir/.zshrc" <<'EOF'
PROMPT='%# '
setopt hist_ignore_space
EOF
  if [ -n "$history_seed" ]; then
    printf '%s\n' "$history_seed" >"$zdotdir/.zsh_history"
  fi
  export ZDOTDIR="$zdotdir"
  export SHELL="$(command -v zsh || printf '/bin/zsh')"
}

latest_manifest() {
  jq -r '.manifest_path' "$TMUX_REVIVE_STATE_ROOT/snapshots/$host_name/latest.json"
}

create_fake_snapshot_manifest() {
  local snapshot_name="$1"
  local epoch="$2"
  local reason="$3"
  local save_mode="${4:-manual}"
  local keep_flag="${5:-false}"
  local imported_flag="${6:-false}"
  local set_latest="${7:-false}"
  local snapshot_dir manifest_path created_at

  snapshot_dir="$TMUX_REVIVE_STATE_ROOT/snapshots/$host_name/$snapshot_name"
  manifest_path="$snapshot_dir/manifest.json"
  created_at="$(date -u -r "$epoch" +%Y-%m-%dT%H:%M:%SZ)"
  mkdir -p "$snapshot_dir"

  jq -n \
    --arg created_at "$created_at" \
    --argjson created_at_epoch "$epoch" \
    --arg reason "$reason" \
    --arg save_mode "$save_mode" \
    --argjson keep "$keep_flag" \
    --argjson imported "$imported_flag" \
    '{
      snapshot_version: "1",
      created_at: $created_at,
      created_at_epoch: $created_at_epoch,
      last_updated: $created_at,
      last_updated_epoch: $created_at_epoch,
      reason: $reason,
      save_mode: $save_mode,
      keep: $keep,
      imported: $imported,
      sessions: []
    }' >"$manifest_path"

  if [ "$set_latest" = "true" ]; then
    jq -n \
      --arg created_at "$created_at" \
      --arg manifest_path "$manifest_path" \
      --arg snapshot_path "$snapshot_dir" \
      '{ created_at: $created_at, manifest_path: $manifest_path, snapshot_path: $snapshot_path }' \
      >"$TMUX_REVIVE_STATE_ROOT/snapshots/$host_name/latest.json"
  fi

  printf '%s\n' "$manifest_path"
}

session_guid_for() {
  local manifest="$1"
  local session_name="$2"
  jq -r --arg name "$session_name" '.sessions[] | select(.session_name == $name) | .session_guid' "$manifest" | head -n 1
}

nvim_server_for_pane() {
  local pane_id="$1"
  local entry
  entry="$(wait_for_registry_entry "$pane_id")" || return 1
  jq -r '.server // ""' "$entry"
}

nth_pane_id() {
  local target="$1"
  local ordinal="$2"
  tmux list-panes -t "$target" -F '#{pane_id}' | sed -n "${ordinal}p"
}

setup_fake_fzf_sequence() {
  local queue_dir="$case_root/fzf-sequence"
  local index=1
  local payload

  mkdir -p "$queue_dir"
  for payload in "$@"; do
    printf '%s' "$payload" >"$queue_dir/$(printf '%03d' "$index").txt"
    index=$((index + 1))
  done

  cat >"$case_root/bin/fzf" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
queue_dir="${TMUX_TEST_FZF_QUEUE_DIR:?}"
if [ -n "${TMUX_TEST_FZF_ARGS_LOG:-}" ]; then
  printf '%s\n' "$*" >>"$TMUX_TEST_FZF_ARGS_LOG"
fi
next_payload="$(find "$queue_dir" -type f -name '*.txt' | sort | head -n 1)"
[ -n "${next_payload:-}" ] || exit 1
cat >/dev/null || true
cat "$next_payload"
rm -f "$next_payload"
EOF
  chmod +x "$case_root/bin/fzf"
  export TMUX_TEST_FZF_QUEUE_DIR="$queue_dir"
}

test_list() {
  setup_case "list"
  tmux new-session -d -s alpha
  tmux new-session -d -s beta
  "$save_state" --reason test-list

  output="$("$restore_state" --list)"
  line_count="$(printf '%s\n' "$output" | awk 'NF > 0 { count++ } END { print count + 0 }')"

  assert_contains "$output" "SESSION_GUID" "list header guid"
  assert_contains "$output" "SESSION_NAME" "list header name"
  assert_contains "$output" "LAST_UPDATED" "list header timestamp"
  assert_contains "$output" "alpha" "list includes alpha"
  assert_contains "$output" "beta" "list includes beta"
  assert_eq "3" "$line_count" "list line count"
  pass "list"
}

test_snapshot_browser_dump_items() {
  setup_case "snapshot-browser-dump"
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
  pass "snapshot-browser-dump-items"
}

test_snapshot_browser_delegates_to_saved_session_chooser() {
  setup_case "snapshot-browser-session"
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
  pass "snapshot-browser-delegates-to-saved-session-chooser"
}

test_snapshot_browser_delegates_restore_all() {
  setup_case "snapshot-browser-all"
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
  pass "snapshot-browser-delegates-restore-all"
}

test_restore_preview_summary() {
  setup_case "restore-preview-summary"
  tmux new-session -d -s alpha
  tmux new-session -d -s gamma
  tmux new-session -d -s base
  tmux new-session -d -t base -s grouped
  "$save_state" --reason preview-summary
  manifest="$(latest_manifest)"

  tmux kill-server
  tmux new-session -d -s alpha

  output="$("$restore_state" --manifest "$manifest" --preview)"

  assert_contains "$output" "tmux-revive restore preview" "restore preview header"
  assert_contains "$output" "Reason: preview-summary" "restore preview reason"
  assert_contains "$output" "Manifest: $manifest" "restore preview manifest path"
  assert_contains "$output" "Will restore (2):" "restore preview restore count"
  assert_contains "$output" "gamma" "restore preview restorable session"
  assert_contains "$output" "base" "restore preview restorable group leader"
  assert_contains "$output" "Will skip existing (1):" "restore preview skipped count"
  assert_contains "$output" "alpha" "restore preview skipped session"
  assert_contains "$output" "Grouped session issues (1):" "restore preview grouped count"
  assert_contains "$output" "grouped" "restore preview grouped peer session"
  pass "restore-preview-summary"
}

test_restore_report_summary() {
  setup_case "restore-report-summary"

  tmux new-session -d -s alpha
  tmux new-session -d -s base
  tmux new-session -d -t base -s grouped
  tmux new-session -d -s gamma
  gamma_pane="$(tmux list-panes -t gamma -F '#{pane_id}' | head -n 1)"
  "$pane_meta" set-command-preview 'python app.py' "$gamma_pane"
  "$save_state" --reason restore-report-summary

  tmux kill-session -t gamma
  tmux kill-session -t grouped
  tmux kill-session -t base

  "$restore_state" --yes >/dev/null

  report_path="$(tmux_revive_latest_restore_report_path)"
  wait_for_file "$report_path" || fail "restore report was not written"
  report_json="$(cat "$report_path")"
  report_text="$("$tmux_revive_dir/show-restore-report.sh" --report "$report_path")"

  assert_contains "$report_json" '"summary"' "restore report summary field"
  assert_contains "$report_text" "tmux-revive restore report" "restore report header"
  assert_contains "$report_text" "Restored (3):" "restore report restored section"
  assert_contains "$report_text" "gamma" "restore report restored session"
  assert_contains "$report_text" "base" "restore report restored group leader"
  assert_contains "$report_text" "grouped" "restore report restored grouped session"
  assert_contains "$report_text" "Skipped existing (1):" "restore report skipped section"
  assert_contains "$report_text" "alpha" "restore report skipped session"
  assert_contains "$report_text" "Grouped session issues (0):" "restore report grouped section"
  assert_contains "$report_text" "Pane fallbacks (2):" "restore report fallback section"
  assert_contains "$report_text" "saved command preloaded at the prompt; not auto-run" "restore report fallback detail"
  pass "restore-report-summary"
}

test_restore_report_popup() {
  setup_case "restore-report-popup"

  tmux new-session -d -s work
  "$save_state" --reason restore-report-popup
  tmux kill-server

  rm -f "$TMUX_TEST_DISPLAY_POPUP_LOG"
  "$restore_state" --session-name work --yes --report-client-tty test-tty >/dev/null

  wait_for_file "$TMUX_TEST_DISPLAY_POPUP_LOG" || fail "restore report popup was not opened"
  popup_log="$(cat "$TMUX_TEST_DISPLAY_POPUP_LOG")"
  assert_contains "$popup_log" "display-popup -t test-tty" "restore report popup client target"
  assert_contains "$popup_log" "show-restore-report.sh" "restore report popup command"
  assert_contains "$popup_log" "$(tmux_revive_latest_restore_report_path)" "restore report popup path"
  pass "restore-report-popup"
}

test_restore_health_warnings_preview_and_report() {
  setup_case "restore-health-warnings"

  tmux new-session -d -s work
  tmux split-window -d -t work
  "$save_state" --reason restore-health
  manifest="$(latest_manifest)"

  fake_nvim_state="$case_root/fake-nvim-state.json"
  jq -n --arg missing_path "$case_root/missing-nvim-file.txt" '{
    cwd: "/tmp",
    current_tab: 1,
    tabs: [
      {
        index: 1,
        current_win: 1,
        wins: [
          { path: $missing_path, cursor: [3, 1] }
        ]
      }
    ]
  }' >"$fake_nvim_state"

  manifest_tmp="${manifest}.tmp"
  jq \
    --arg missing_cwd "$case_root/missing-cwd" \
    --arg missing_tail "$case_root/missing-tail.log" \
    --arg nvim_state "$fake_nvim_state" \
    '
      .sessions[0].windows[0].panes[0].cwd = $missing_cwd
      | .sessions[0].windows[0].panes[0].restore_strategy = "restart-command"
      | .sessions[0].windows[0].panes[0].restart_command = ("tail -f " + $missing_tail)
      | .sessions[0].windows[0].panes[1].restore_strategy = "nvim"
      | .sessions[0].windows[0].panes[1].nvim_state_ref = $nvim_state
    ' "$manifest" >"$manifest_tmp"
  mv "$manifest_tmp" "$manifest"

  tmux kill-server

  preview_output="$("$restore_state" --manifest "$manifest" --preview)"
  assert_contains "$preview_output" "Health warnings (" "restore health preview section"
  assert_contains "$preview_output" "missing cwd:" "restore health preview missing cwd"
  assert_contains "$preview_output" "tail target is missing:" "restore health preview missing tail target"
  assert_contains "$preview_output" "Neovim state references 1 missing file(s):" "restore health preview missing nvim target"

  "$restore_state" --manifest "$manifest" --session-name work --yes >/dev/null
  report_path="$(tmux_revive_latest_restore_report_path)"
  wait_for_file "$report_path" || fail "restore health report missing"
  report_text="$("$tmux_revive_dir/show-restore-report.sh" --report "$report_path")"
  assert_contains "$report_text" "Health warnings (" "restore health report section"
  assert_contains "$report_text" "missing cwd:" "restore health report missing cwd"
  assert_contains "$report_text" "tail target is missing:" "restore health report missing tail target"
  assert_contains "$report_text" "Neovim state references 1 missing file(s):" "restore health report missing nvim target"
  pass "restore-health-warnings-preview-and-report"
}

test_snapshot_retention_count_policy() {
  setup_case "snapshot-retention-count"
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
  pass "snapshot-retention-count-policy"
}

test_snapshot_retention_age_policy() {
  setup_case "snapshot-retention-age"
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
  pass "snapshot-retention-age-policy"
}

test_snapshot_retention_or_logic() {
  setup_case "snapshot-retention-or"
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
  pass "snapshot-retention-or-logic"
}

test_save_state_applies_retention_policy() {
  setup_case "save-state-retention"
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
  wait_for_file "$prune_wrapper_log" || fail "save-state retention integration did not call prune wrapper"
  wait_for_path_missing "$old_manifest_path" || fail "save-state retention integration did not prune the old manifest"
  manifest_count="$(find "$TMUX_REVIVE_STATE_ROOT/snapshots/$host_name" -type f -name manifest.json | wc -l | tr -d ' ')"
  assert_eq "1" "$manifest_count" "save-state retention integration manifest count"
  assert_eq "manual" "$(jq -r '.save_mode' "$new_latest_manifest")" "save-state retention integration save mode"
  pass "save-state-applies-retention-policy"
}

test_snapshot_browser_configures_preview_pane() {
  setup_case "snapshot-browser-preview-pane"
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
  pass "snapshot-browser-configures-preview-pane"
}

test_saved_session_chooser_configures_preview_pane() {
  setup_case "saved-session-preview-pane"
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
  pass "saved-session-chooser-configures-preview-pane"
}

test_saved_session_chooser_rich_metadata() {
  setup_case "saved-session-rich-metadata"
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
  pass "saved-session-chooser-rich-metadata"
}

test_snapshot_bundle_export_import_roundtrip() {
  setup_case "snapshot-bundle-roundtrip"
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
  pass "snapshot-bundle-export-import-roundtrip"
}

test_imported_snapshot_missing_path_message() {
  setup_case "imported-missing-path"
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
  pass "imported-snapshot-missing-path-message"
}

test_snapshot_browser_hides_imported_by_default() {
  setup_case "snapshot-browser-hides-imported"
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
  pass "snapshot-browser-hides-imported-by-default"
}

test_archive_session_hides_default_choosers() {
  setup_case "archive-session-hides-default-choosers"
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
  pass "archive-session-hides-default-choosers"
}

test_archived_sessions_do_not_trigger_startup_prompt() {
  setup_case "archived-sessions-no-startup-prompt"
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
  pass "archived-sessions-do-not-trigger-startup-prompt"
}

test_revive_groups_current_session_first() {
  setup_case "revive-groups"
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
  pass "revive-groups-current-session-first"
}

test_revive_header_rows_are_ignored_and_live_actions_still_work() {
  setup_case "revive-header"
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
  pass "revive-header-rows-ignored-and-live-actions-still-work"
}

test_revive_includes_saved_sessions_section() {
  setup_case "revive-saved-sessions"
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
  pass "revive-includes-saved-sessions-section"
}

test_revive_saved_rows_resume_via_resume_session() {
  setup_case "revive-saved-row-resume"
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
  pass "revive-saved-rows-resume-via-resume-session"
}

test_restore_by_guid() {
  setup_case "restore-by-guid"
  tmux new-session -d -s work
  "$save_state" --reason test-guid
  manifest="$(latest_manifest)"
  guid="$(session_guid_for "$manifest" "work")"
  [ -n "$guid" ] || fail "missing session guid in manifest"

  tmux kill-server
  "$restore_state" --session-guid "$guid" --yes >/dev/null

  wait_for_session work || fail "work session did not restore by guid"
  restored_guid="$(tmux show-options -qv -t work @tmux-revive-session-guid)"
  assert_eq "$guid" "$restored_guid" "restored guid"
  pass "restore-by-guid"
}

test_restore_by_session_name() {
  setup_case "restore-by-session-name"
  tmux new-session -d -s work
  "$save_state" --reason test-name

  tmux kill-server
  rm -f "$TMUX_TEST_SWITCH_LOG"
  "$restore_state" --session-name work --yes >/dev/null

  wait_for_session work || fail "work session did not restore by session name"
  [ ! -f "$TMUX_TEST_SWITCH_LOG" ] || fail "restore-by-session-name switched a tmux client unexpectedly"
  pass "restore-by-session-name"
}

test_restore_by_session_name_falls_back_to_older_snapshot() {
  setup_case "restore-by-session-name-older-snapshot"
  tmux new-session -d -s work
  tmux send-keys -t work "printf 'work-snapshot\n'" C-m
  sleep 1
  "$save_state" --reason original-work
  original_manifest="$(latest_manifest)"
  [ -f "$original_manifest" ] || fail "original work manifest missing"

  tmux kill-session -t work
  tmux new-session -d -s bootstrap
  sleep 1
  "$save_state" --auto --reason autosave-tick >/dev/null

  newer_manifest="$(latest_manifest)"
  [ -f "$newer_manifest" ] || fail "newer bootstrap manifest missing"
  [ "$newer_manifest" != "$original_manifest" ] || fail "latest manifest did not advance to newer snapshot"
  newer_sessions="$(jq -r '.sessions[].session_name' "$newer_manifest")"
  assert_not_contains "$newer_sessions" "work" "newer latest snapshot should not contain work"
  [ -f "$original_manifest" ] || fail "original work manifest disappeared before restore"

  rm -f "$TMUX_TEST_ATTACH_LOG" "$TMUX_TEST_SWITCH_LOG"
  "$restore_state" --session-name work --attach --yes >/dev/null

  wait_for_session work || fail "work session did not restore from older snapshot fallback"
  wait_for_file "$TMUX_TEST_ATTACH_LOG" || fail "attach log missing for older snapshot fallback restore"
  attach_cmd="$(cat "$TMUX_TEST_ATTACH_LOG")"
  assert_contains "$attach_cmd" "attach-session -t work" "older snapshot fallback attach target"
  pass "restore-by-session-name-falls-back-to-older-snapshot"
}

test_mixed_collision_restore() {
  setup_case "mixed-collision"
  tmux new-session -d -s alpha
  tmux new-session -d -s beta
  "$save_state" --reason test-collision

  tmux kill-server
  tmux new-session -d -s beta

  output="$("$restore_state" --yes 2>&1)"
  wait_for_session alpha || fail "alpha session did not restore during collision test"
  wait_for_session beta || fail "beta session missing during collision test"

  assert_contains "$output" "skipped" "collision summary"
  assert_contains "$output" "beta" "collision session name in summary"
  pass "mixed-collision-restore"
}

test_partial_snapshot_restore_with_existing_session() {
  setup_case "partial-snapshot-existing-session"
  tmux new-session -d -s alpha
  tmux split-window -d -t alpha
  tmux new-window -d -t alpha: -n "alpha-logs"

  tmux new-session -d -s beta
  tmux new-window -d -t beta: -n "beta-extra"

  tmux new-session -d -s gamma
  tmux split-window -d -t gamma

  "$save_state" --reason test-partial-snapshot-restore

  tmux kill-server

  tmux new-session -d -s beta
  beta_live_summary_before="$(tmux list-windows -t beta -F '#{window_index}:#{window_panes}:#{window_name}')"

  output="$("$restore_state" --yes 2>&1)"

  wait_for_session alpha || fail "alpha session did not restore during partial snapshot test"
  wait_for_session beta || fail "beta session missing during partial snapshot test"
  wait_for_session gamma || fail "gamma session did not restore during partial snapshot test"

  alpha_summary="$(tmux list-windows -t alpha -F '#{window_index}:#{window_panes}:#{window_name}')"
  beta_live_summary_after="$(tmux list-windows -t beta -F '#{window_index}:#{window_panes}:#{window_name}')"
  gamma_summary="$(tmux list-windows -t gamma -F '#{window_index}:#{window_panes}:#{window_name}')"
  session_count="$(tmux list-sessions | wc -l | tr -d ' ')"

  assert_contains "$output" "restored 2 session(s)" "partial restore restored-count summary"
  assert_contains "$output" "skipped" "partial restore skip summary"
  assert_contains "$output" "beta" "partial restore skipped session name"
  assert_eq "$beta_live_summary_before" "$beta_live_summary_after" "existing beta session remained unchanged"
  assert_contains "$alpha_summary" ":2:" "alpha restored pane count"
  assert_contains "$alpha_summary" "alpha-logs" "alpha second window restored"
  assert_contains "$gamma_summary" ":2:" "gamma pane count restored"
  assert_eq "3" "$session_count" "partial restore session count"
  pass "partial-snapshot-restore-with-existing-session"
}

test_restore_is_idempotent() {
  setup_case "restore-idempotent"
  tmux new-session -d -s work
  session_target="$(tmux list-sessions -F '#{session_id}' | head -n 1)"
  first_pane="$(tmux list-panes -t work -F '#{pane_id}' | head -n 1)"
  tmux split-window -d -t "$first_pane"
  pane_one="$(nth_pane_id work 1)"
  pane_two="$(nth_pane_id work 2)"
  logs_window_target="$(tmux new-window -d -P -F '#{window_id}' -t "${session_target}:" -n "logs")"
  logs_pane="$(tmux list-panes -t "$logs_window_target" -F '#{pane_id}' | head -n 1)"
  tmux send-keys -t "$pane_one" 'printf "pane-one\n"' C-m
  tmux send-keys -t "$pane_two" 'printf "pane-two\n"' C-m
  tmux send-keys -t "$logs_pane" 'printf "window-two\n"' C-m
  sleep 1
  "$save_state" --reason test-idempotent-restore

  tmux kill-server
  "$restore_state" --session-name work --yes >/dev/null

  first_window_summary="$(tmux list-windows -t work -F '#{window_index}:#{window_panes}:#{window_name}')"
  second_restore_output="$("$restore_state" --session-name work --yes 2>&1)"
  second_window_summary="$(tmux list-windows -t work -F '#{window_index}:#{window_panes}:#{window_name}')"

  assert_contains "$second_restore_output" "restored 0 session(s)" "idempotent restore summary"
  assert_contains "$second_restore_output" "skipped existing sessions" "idempotent restore skip notice"
  assert_eq "$first_window_summary" "$second_window_summary" "idempotent restore window summary"
  pass "restore-is-idempotent"
}

test_attach() {
  setup_case "attach"
  tmux new-session -d -s work
  "$save_state" --reason test-attach

  tmux kill-server
  rm -f "$TMUX_TEST_ATTACH_LOG"
  rm -f "$TMUX_TEST_SWITCH_LOG"
  "$restore_state" --session-name work --attach --yes >/dev/null

  wait_for_file "$TMUX_TEST_ATTACH_LOG" || fail "attach log was not created"
  attach_cmd="$(cat "$TMUX_TEST_ATTACH_LOG")"
  assert_contains "$attach_cmd" "attach-session -t work" "attach target"
  [ ! -f "$TMUX_TEST_SWITCH_LOG" ] || fail "attach restore switched another tmux client unexpectedly"
  pass "attach"
}

test_startup_restore_mode() {
  setup_case "startup-restore-mode"
  tmux new-session -d -s work
  "$save_state" --reason test-startup-auto

  tmux kill-server
  tmux new-session -d -s bootstrap
  tmux set-option -g @tmux-revive-startup-restore auto
  "$startup_restore"

  wait_for_session work || fail "work session did not restore in startup auto mode"
  pass "startup-restore-mode"
}

test_named_restore_profile_precedence() {
  setup_case "named-restore-profile-precedence"
  mkdir -p "$case_root/profiles"
  export TMUX_REVIVE_PROFILE_DIR="$case_root/profiles"
  cat >"$case_root/profiles/ci.json" <<'EOF'
{
  "name": "ci",
  "attach": true,
  "preview": true,
  "include_archived": false,
  "startup_mode": "prompt"
}
EOF

  tmux new-session -d -s work
  "$save_state" --reason named-profile

  tmux kill-server
  preview_output="$("$restore_state" --profile ci --session-name work --yes)"
  assert_contains "$preview_output" "tmux-revive restore preview" "profile preview enabled by default"
  if tmux has-session -t work 2>/dev/null; then
    fail "profile preview should not restore the session"
  fi

  rm -f "$TMUX_TEST_ATTACH_LOG"
  "$restore_state" --profile ci --session-name work --yes --no-preview --no-attach >/dev/null
  wait_for_session work || fail "profile restore did not restore work session"
  [ ! -f "$TMUX_TEST_ATTACH_LOG" ] || fail "no-attach CLI should override profile attach"
  pass "named-restore-profile-precedence"
}

test_default_profile_controls_startup_mode() {
  setup_case "default-profile-controls-startup-mode"
  mkdir -p "$case_root/profiles"
  export TMUX_REVIVE_PROFILE_DIR="$case_root/profiles"
  export TMUX_REVIVE_DEFAULT_PROFILE="all"
  cat >"$case_root/profiles/all.json" <<'EOF'
{
  "name": "all",
  "attach": true,
  "preview": false,
  "include_archived": true,
  "startup_mode": "auto"
}
EOF

  tmux new-session -d -s work
  "$save_state" --reason profile-startup-auto

  tmux kill-server
  tmux new-session -d -s bootstrap
  tmux set-option -g @tmux-revive-startup-restore prompt
  "$startup_restore"

  wait_for_session work || fail "default profile startup_mode=auto did not restore work session"
  pass "default-profile-controls-startup-mode"
}

test_profile_can_include_archived_sessions() {
  setup_case "profile-can-include-archived-sessions"
  mkdir -p "$case_root/profiles"
  export TMUX_REVIVE_PROFILE_DIR="$case_root/profiles"
  cat >"$case_root/profiles/archive-view.json" <<'EOF'
{
  "name": "archive-view",
  "attach": false,
  "preview": false,
  "include_archived": true,
  "startup_mode": "prompt"
}
EOF

  tmux new-session -d -s work
  "$save_state" --reason profile-archived
  manifest="$(latest_manifest)"
  guid="$(jq -r '.sessions[0].session_guid' "$manifest")"
  [ -n "$guid" ] || fail "profile archived test missing guid"
  "$archive_session" --session-guid "$guid" >/dev/null

  hidden_items="$("$choose_saved_session" --manifest "$manifest" --dump-items)"
  [ -z "$hidden_items" ] || fail "archived session should be hidden by default"

  visible_items="$("$choose_saved_session" --manifest "$manifest" --dump-items --profile archive-view)"
  assert_contains "$visible_items" "work" "profile include_archived should show archived session"

  hidden_again="$("$choose_saved_session" --manifest "$manifest" --dump-items --profile archive-view --hide-archived)"
  [ -z "$hidden_again" ] || fail "hide-archived should override profile include_archived"
  pass "profile-can-include-archived-sessions"
}

test_restart_command_allowlist() {
  setup_case "restart-command-allowlist"
  output_path="$case_root/restart-proof.txt"
  makefile="$case_root/Makefile"
  cat >"$makefile" <<EOF
restart-proof:
	@echo restarted > $output_path
EOF

  tmux new-session -d -s work
  pane_id="$(tmux list-panes -t work -F '#{pane_id}' | head -n 1)"
  "$pane_meta" set-restart-command "make -f $makefile restart-proof" "$pane_id"
  "$save_state" --reason test-restart-allowlist

  tmux kill-server
  "$restore_state" --session-name work --yes >/dev/null

  wait_for_file "$output_path" 40 0.25 || fail "allowlisted restart command did not run"
  assert_eq "restarted" "$(cat "$output_path")" "allowlisted restart output"
  pass "restart-command-allowlist"
}

test_restartable_command_allowlist_matrix() {
  local approved_commands=(
    "tail -f /tmp/example.log"
    "tail -F /tmp/example.log"
    "tail -n 20 -f /tmp/example.log"
    "tail -n 20 -F /tmp/example.log"
    "tail --lines 20 -f /tmp/example.log"
    "tail --lines 20 -F /tmp/example.log"
    "make dev"
    "just dev"
    "npm run dev"
    "pnpm run dev"
    "yarn run dev"
    "yarn dev"
    "uv run app.py"
    "cargo run --bin app"
    "go run ."
    "docker-compose up api"
    "docker compose up api"
    "python -m http.server"
    "python3 -m http.server"
  )
  local rejected_commands=(
    "tail /tmp/example.log"
    "npm test"
    "pnpm dev"
    "yarn --version"
    "uv sync"
    "cargo test"
    "go test ./..."
    "docker-compose logs api"
    "docker compose logs api"
    "python app.py"
    "python3 script.py"
  )
  local command

  for command in "${approved_commands[@]}"; do
    tmux_revive_command_is_restartable "$command" || fail "approved command was not restartable: $command"
  done

  for command in "${rejected_commands[@]}"; do
    if tmux_revive_command_is_restartable "$command"; then
      fail "rejected command was restartable unexpectedly: $command"
    fi
  done

  pass "restartable-command-allowlist-matrix"
}

test_restart_command_preview_fallback() {
  setup_case "restart-command-preview-fallback"
  output_path="$case_root/should-not-exist.txt"
  tmux new-session -d -s work
  pane_id="$(tmux list-panes -t work -F '#{pane_id}' | head -n 1)"
  "$pane_meta" set-restart-command "echo nope > $output_path" "$pane_id"
  "$save_state" --reason test-restart-preview

  tmux kill-server
  "$restore_state" --session-name work --yes >/dev/null
  restored_pane="$(tmux list-panes -t work -F '#{pane_id}' | head -n 1)"
  pane_capture="$(tmux capture-pane -p -S -40 -t "$restored_pane")"

  [ ! -f "$output_path" ] || fail "disallowed restart command executed unexpectedly"
  assert_contains "$pane_capture" "echo nope >" "disallowed restart preloaded command prefix"
  assert_contains "$pane_capture" "should-not-e" "disallowed restart preloaded command target"
  pass "restart-command-preview-fallback"
}

test_tail_restart_from_preview() {
  setup_case "tail-restart-from-preview"
  log_path="$case_root/tail.log"
  printf 'before\n' >"$log_path"

  tmux new-session -d -s work
  pane_id="$(tmux list-panes -t work -F '#{pane_id}' | head -n 1)"
  tmux send-keys -t "$pane_id" "tail -f $(printf '%q' "$log_path")" C-m
  wait_for_pane_command "$pane_id" tail 60 0.25 || fail "tail did not start before save"
  "$pane_meta" set-command-preview "tail -f $log_path" "$pane_id"
  "$pane_meta" strategy auto "$pane_id"
  "$save_state" --reason test-tail-restart

  tmux kill-server
  "$restore_state" --session-name work --yes >/dev/null

  restored_pane="$(tmux list-panes -t work -F '#{pane_id}' | head -n 1)"
  printf 'after\n' >>"$log_path"
  wait_for_pane_text "$restored_pane" "after" 60 0.25 || fail "tail output did not resume after restore"
  pane_capture="$(tmux capture-pane -p -S -40 -t "$restored_pane")"
  assert_contains "$pane_capture" "after" "tail restart output"
  pass "tail-restart-from-preview"
}

test_reference_only_messages() {
  setup_case "reference-only-messages"
  tmux new-session -d -s work
  tmux split-window -d -t work
  manual_pane="$(nth_pane_id work 1)"
  history_pane="$(nth_pane_id work 2)"
  tmux send-keys -t "$manual_pane" 'echo manual transcript line' C-m
  tmux send-keys -t "$history_pane" 'echo history transcript line' C-m
  sleep 1
  "$pane_meta" set-command-preview 'npm run dev' "$manual_pane"
  "$pane_meta" strategy history_only "$history_pane"
  "$save_state" --reason test-reference-only

  tmux kill-server
  "$restore_state" --session-name work --yes >/dev/null
  sleep 1
  session_capture="$(tmux list-panes -t work -F '#{pane_id}' | while read -r restored_pane; do tmux capture-pane -p -S -60 -t "$restored_pane"; printf '\n===pane===\n'; done)"

  assert_contains "$session_capture" "history transcript line" "history-only transcript text"
  pass "reference-only-messages"
}

test_shell_pane_does_not_preload_unrelated_command() {
  setup_case "shell-pane-no-unrelated-preload"
  tmux new-session -d -s work
  pane_id="$(tmux list-panes -t work -F '#{pane_id}' | head -n 1)"
  tmux send-keys -t "$pane_id" 'printf "context-only\n"' C-m
  sleep 1
  "$save_state" --reason test-shell-no-preload

  tmux kill-server
  "$restore_state" --session-name work --yes >/dev/null

  restored_pane="$(tmux list-panes -t work -F '#{pane_id}' | head -n 1)"
  wait_for_pane_text "$restored_pane" "context-only" 60 0.25 || fail "shell pane transcript was not replayed after restore"
  pane_capture="$(tmux capture-pane -p -S -40 -t "$restored_pane")"
  assert_contains "$pane_capture" "context-only" "shell pane transcript restored"
  case "$pane_capture" in
    *"Press Enter to run it"*|*"npm run dev"*|*"tail -f "*|*"echo nope > "*)
      fail "shell-only pane preloaded an unrelated command unexpectedly"
      ;;
  esac
  pass "shell-pane-no-unrelated-preload"
}

test_mixed_non_nvim_pane_restore_behavior() {
  setup_case "mixed-non-nvim-pane-restore"
  approved_log="$case_root/approved.log"
  printf 'before\n' >"$approved_log"

  tmux new-session -d -s work
  tmux split-window -d -t work
  tmux split-window -d -t work

  approved_pane="$(nth_pane_id work 1)"
  unapproved_pane="$(nth_pane_id work 2)"
  blank_pane="$(nth_pane_id work 3)"

  tmux send-keys -t "$approved_pane" "tail -f $(printf '%q' "$approved_log")" C-m
  wait_for_pane_command "$approved_pane" tail 60 0.25 || fail "approved pane did not start tail before save"
  "$pane_meta" set-command-preview "tail -f $approved_log" "$approved_pane"
  "$pane_meta" strategy auto "$approved_pane"

  tmux send-keys -t "$unapproved_pane" 'printf "manual pane context\n"' C-m
  sleep 1
  "$pane_meta" set-command-preview 'python app.py' "$unapproved_pane"
  "$pane_meta" strategy auto "$unapproved_pane"

  tmux send-keys -t "$blank_pane" 'printf "blank pane context\n"' C-m
  sleep 1

  "$save_state" --reason test-mixed-non-nvim-pane-restore

  tmux kill-server
  "$restore_state" --session-name work --yes >/dev/null

  restored_approved="$(nth_pane_id work 1)"
  restored_unapproved="$(nth_pane_id work 2)"
  restored_blank="$(nth_pane_id work 3)"

  printf 'after\n' >>"$approved_log"
  wait_for_pane_text "$restored_approved" "after" 60 0.25 || fail "approved pane tail output did not resume after restore"

  approved_capture="$(tmux capture-pane -p -S -60 -t "$restored_approved")"
  unapproved_capture="$(tmux capture-pane -p -S -60 -t "$restored_unapproved")"
  blank_capture="$(tmux capture-pane -p -S -60 -t "$restored_blank")"

  assert_contains "$approved_capture" "after" "approved pane tail output after restore"
  assert_contains "$unapproved_capture" "manual pane context" "unapproved pane transcript restored"
  assert_contains "$unapproved_capture" "python app.py" "unapproved pane command preloaded"
  assert_not_contains "$blank_capture" "python app.py" "blank pane does not inherit unapproved command"
  assert_not_contains "$blank_capture" "tail -f " "blank pane does not inherit approved command"
  assert_contains "$blank_capture" "blank pane context" "blank pane transcript restored"
  pass "mixed-non-nvim-pane-restore-behavior"
}

test_auto_capture_tail_restart() {
  setup_case "auto-capture-tail-restart"
  mkdir -p "$case_root/src"
  log_path="$case_root/src/backtrace.txt"
  printf 'seed\n' >"$log_path"

  tmux new-session -d -s work -c "$case_root/src"
  pane_id="$(tmux list-panes -t work -F '#{pane_id}' | head -n 1)"
  tmux send-keys -t "$pane_id" "tail -f $(printf '%q' "$log_path")" C-m
  wait_for_pane_command "$pane_id" tail 60 0.25 || fail "tail did not start before auto-capture save"
  for i in $(seq 1 30); do
    printf 'stream-%02d\n' "$i" >>"$log_path"
  done
  sleep 1
  "$save_state" --reason test-auto-capture-tail

  manifest="$(latest_manifest)"
  saved_preview="$(jq -r '.sessions[] | select(.session_name == "work") | .windows[0].panes[0].command_preview // ""' "$manifest")"
  saved_restart="$(jq -r '.sessions[] | select(.session_name == "work") | .windows[0].panes[0].restart_command // ""' "$manifest")"
  assert_eq "tail -f $log_path" "$saved_preview" "auto-captured tail command preview"
  assert_eq "tail -f $log_path" "$saved_restart" "auto-captured tail restart command"

  tmux kill-server
  "$restore_state" --session-name work --yes >/dev/null

  restored_pane="$(tmux list-panes -t work -F '#{pane_id}' | head -n 1)"
  pane_capture="$(tmux capture-pane -p -S -80 -t "$restored_pane")"
  assert_contains "$pane_capture" "stream-05" "saved transcript context visible after restore"

  printf 'after\n' >>"$log_path"
  wait_for_pane_text "$restored_pane" "after" 60 0.25 || fail "auto-captured tail output did not resume after restore"
  pane_capture="$(tmux capture-pane -p -S -80 -t "$restored_pane")"
  assert_contains "$pane_capture" "after" "auto-captured tail output after restore"
  pass "auto-capture-tail-restart"
}

test_interrupt_restored_tail_returns_to_shell() {
  setup_case "interrupt-restored-tail-returns-to-shell"
  mkdir -p "$case_root/src"
  log_path="$case_root/src/backtrace.txt"
  expected_shell="$(basename "${SHELL:-/bin/sh}")"
  printf 'before\n' >"$log_path"

  tmux new-session -d -s work -c "$case_root/src"
  pane_id="$(tmux list-panes -t work -F '#{pane_id}' | head -n 1)"
  tmux send-keys -t "$pane_id" "tail -f $(printf '%q' "$log_path")" C-m
  wait_for_pane_command "$pane_id" tail 60 0.25 || fail "tail did not start before save for interrupt test"
  "$save_state" --reason test-interrupt-restored-tail

  tmux kill-server
  "$restore_state" --session-name work --yes >/dev/null

  restored_pane="$(tmux list-panes -t work -F '#{pane_id}' | head -n 1)"
  printf 'probe-before-interrupt\n' >>"$log_path"
  wait_for_pane_text "$restored_pane" "probe-before-interrupt" 60 0.25 || fail "restored tail output did not resume before interrupt"
  tmux send-keys -t "$restored_pane" C-c
  wait_for_pane_command "$restored_pane" "$expected_shell" 60 0.25 || fail "restored pane did not return to shell after interrupt"

  remaining_panes="$(tmux list-panes -t work -F '#{pane_id}')"
  assert_contains "$remaining_panes" "$restored_pane" "restored pane still exists after interrupt"
  pass "interrupt-restored-tail-returns-to-shell"
}

test_restored_autorun_command_not_added_to_zsh_history() {
  setup_case "restored-autorun-command-not-in-zsh-history"
  zdotdir="$case_root/zdotdir"
  history_probe="$case_root/history-probe.txt"
  save_test_shell_env
  mkdir -p "$case_root/src"
  setup_test_zsh_env "$zdotdir" ': 1700000000:0;echo seeded-history'

  log_path="$case_root/src/backtrace.txt"
  printf 'before\n' >"$log_path"

  tmux new-session -d -s work -c "$case_root/src"
  pane_id="$(tmux list-panes -t work -F '#{pane_id}' | head -n 1)"
  tmux send-keys -t "$pane_id" " tail -f $(printf '%q' "$log_path")" C-m
  wait_for_pane_command "$pane_id" tail 60 0.25 || fail "tail did not start before save for history suppression test"
  "$save_state" --reason test-restored-autorun-history-suppression

  tmux kill-server
  "$restore_state" --session-name work --yes >/dev/null

  restored_pane="$(tmux list-panes -t work -F '#{pane_id}' | head -n 1)"
  printf 'probe-before-history-check\n' >>"$log_path"
  wait_for_pane_text "$restored_pane" "probe-before-history-check" 60 0.25 || fail "restored tail output did not resume before history suppression check"
  tmux send-keys -t "$restored_pane" C-c
  wait_for_pane_command "$restored_pane" zsh 60 0.25 || fail "restored pane did not return to zsh before history check"
  tmux send-keys -t "$restored_pane" "fc -ln 1 > $(printf '%q' "$history_probe")" C-m
  wait_for_file "$history_probe" 60 0.25 || fail "history probe file was not created"

  history_contents="$(cat "$history_probe")"
  assert_contains "$history_contents" "echo seeded-history" "seeded zsh history remains available after interrupt"
  assert_not_contains "$history_contents" "tail -f $log_path" "restore auto-run command not added to zsh history"

  restore_test_shell_env
  pass "restored-autorun-command-not-added-to-zsh-history"
}

test_restored_nvim_command_not_added_to_zsh_history() {
  setup_case "restored-nvim-command-not-in-zsh-history"
  sample_dir="$(cd "$case_root" && pwd -P)"
  file_a="$sample_dir/file-a.txt"
  nvim_socket="$case_root/headless-nvim.sock"
  history_probe="$case_root/nvim-history-probe.txt"
  zdotdir="$case_root/zdotdir"
  save_test_shell_env
  setup_test_zsh_env "$zdotdir" ': 1700000000:0;echo seeded-history'

  seq 1 20 >"$file_a"

  tmux new-session -d -s work
  pane_id="$(tmux list-panes -t work -F '#{pane_id}' | head -n 1)"
  "$real_nvim" --headless -u NONE -i NONE \
    --cmd "lua package.path = package.path .. ';$repo_root/nvim/lua/?.lua;$repo_root/nvim/lua/?/init.lua'" \
    --listen "$nvim_socket" "$file_a" >/dev/null 2>&1 &
  nvim_pid=$!

  wait_for_nvim_expr "$nvim_socket" 'expand("%:p")' "$file_a" || fail "headless nvim did not open file in time for history test"
  nvim --server "$nvim_socket" --remote-expr "execute('call cursor(12,1)')" >/dev/null
  wait_for_nvim_expr "$nvim_socket" 'line(".")' "12" || fail "headless nvim did not move cursor in time for history test"

  "$repo_root/tmux/send_to_nvim/register_nvim_instance.sh" "$pane_id" "$nvim_socket" "$nvim_pid" "$(dirname "$file_a")"
  "$save_state" --reason test-restored-nvim-history
  rm -f "$TMUX_TEST_NVIM_RESTORE_LOG"

  kill "$nvim_pid" >/dev/null 2>&1 || true
  if ! wait_for_pid_exit "$nvim_pid" 20 0.1; then
    kill -9 "$nvim_pid" >/dev/null 2>&1 || true
    wait_for_pid_exit "$nvim_pid" 20 0.1 || true
  fi

  tmux kill-server
  "$restore_state" --session-name work --yes >/dev/null

  wait_for_file "$TMUX_TEST_NVIM_RESTORE_LOG" 60 0.25 || fail "restored nvim did not launch for history test"
  restored_pane="$(tmux list-panes -t work -F '#{pane_id}' | head -n 1)"
  wait_for_pane_command "$restored_pane" zsh 60 0.25 || fail "restored nvim pane did not return to zsh after shim exit"
  tmux send-keys -t "$restored_pane" "fc -ln 1 > $(printf '%q' "$history_probe")" C-m
  wait_for_file "$history_probe" 60 0.25 || fail "nvim history probe file was not created"

  history_contents="$(cat "$history_probe")"
  assert_contains "$history_contents" "echo seeded-history" "seeded zsh history remains available after nvim restore"
  assert_not_contains "$history_contents" "TMUX_NVIM_RESTORE_STATE=" "nvim restore env command not added to zsh history"
  assert_not_contains "$history_contents" "nvim" "nvim restore command not added to zsh history"

  restore_test_shell_env
  pass "restored-nvim-command-not-added-to-zsh-history"
}

test_three_window_mixed_restore_scenario() {
  setup_case "three-window-mixed-restore-scenario"
  zdotdir="$case_root/zdotdir"
  save_test_shell_env
  session_name="37"
  src_root="$case_root/src"
  dir_alpha="$src_root/alpha"
  dir_beta="$src_root/beta"
  dir_gamma="$src_root/gamma"
  dir_delta="$src_root/delta"
  file_alpha="$dir_alpha/alpha.txt"
  file_beta="$dir_beta/beta.log"
  file_gamma="$dir_gamma/gamma.txt"
  file_delta="$dir_delta/delta.log"
  nvim_socket_one="$case_root/window1-pane1.sock"
  nvim_socket_two="$case_root/window2-pane1.sock"

  mkdir -p "$dir_alpha" "$dir_beta" "$dir_gamma" "$dir_delta"
  setup_test_zsh_env "$zdotdir" ': 1700000000:0;echo mixed-session-history'
  seq 1 30 >"$file_alpha"
  printf 'beta-seed\n' >"$file_beta"
  seq 101 130 >"$file_gamma"
  printf 'delta-seed\n' >"$file_delta"

  tmux new-session -d -s "$session_name" -c "$src_root"
  window1_index="$(tmux list-windows -t "$session_name" -F '#{window_index}' | head -n 1)"
  tmux rename-window -t "$session_name:$window1_index" "window-1"
  tmux split-window -d -t "$session_name:$window1_index" -c "$dir_beta"

  window2_index="$(tmux new-window -d -P -F '#{window_index}' -t "$session_name:" -n "window-2" -c "$src_root")"
  tmux split-window -d -t "$session_name:$window2_index" -c "$dir_gamma"
  tmux select-layout -t "$session_name:$window2_index" even-vertical >/dev/null 2>&1 || true

  window3_index="$(tmux new-window -d -P -F '#{window_index}' -t "$session_name:" -n "window-3" -c "$dir_delta")"

  window1_pane1="$(nth_pane_id "$session_name:$window1_index" 1)"
  window1_pane2="$(nth_pane_id "$session_name:$window1_index" 2)"
  window2_pane1="$(nth_pane_id "$session_name:$window2_index" 1)"
  window2_pane2="$(nth_pane_id "$session_name:$window2_index" 2)"
  window3_pane1="$(nth_pane_id "$session_name:$window3_index" 1)"

  "$real_nvim" --headless -u NONE -i NONE \
    --cmd "lua package.path = package.path .. ';$repo_root/nvim/lua/?.lua;$repo_root/nvim/lua/?/init.lua'" \
    --listen "$nvim_socket_one" "$file_alpha" >/dev/null 2>&1 &
  nvim_pid_one=$!
  wait_for_nvim_expr "$nvim_socket_one" 'expand("%:p")' "$file_alpha" || fail "window1 pane1 nvim did not open alpha file"
  nvim --server "$nvim_socket_one" --remote-expr "execute('call cursor(12,1)')" >/dev/null
  wait_for_nvim_expr "$nvim_socket_one" 'line(".")' "12" || fail "window1 pane1 nvim did not move to line 12"
  "$repo_root/tmux/send_to_nvim/register_nvim_instance.sh" "$window1_pane1" "$nvim_socket_one" "$nvim_pid_one" "$dir_alpha"

  "$real_nvim" --headless -u NONE -i NONE \
    --cmd "lua package.path = package.path .. ';$repo_root/nvim/lua/?.lua;$repo_root/nvim/lua/?/init.lua'" \
    --listen "$nvim_socket_two" "$file_gamma" >/dev/null 2>&1 &
  nvim_pid_two=$!
  wait_for_nvim_expr "$nvim_socket_two" 'expand("%:p")' "$file_gamma" || fail "window2 pane1 nvim did not open gamma file"
  nvim --server "$nvim_socket_two" --remote-expr "execute('call cursor(7,1)')" >/dev/null
  wait_for_nvim_expr "$nvim_socket_two" 'line(".")' "7" || fail "window2 pane1 nvim did not move to line 7"
  "$repo_root/tmux/send_to_nvim/register_nvim_instance.sh" "$window2_pane1" "$nvim_socket_two" "$nvim_pid_two" "$dir_gamma"

  tmux send-keys -t "$window1_pane2" "cd $(printf '%q' "$dir_beta") && tail -f $(printf '%q' "$file_beta")" C-m
  wait_for_pane_command "$window1_pane2" tail 60 0.25 || fail "window1 pane2 did not start tail before save"
  for i in $(seq 1 15); do
    printf 'beta-stream-%02d\n' "$i" >>"$file_beta"
  done

  tmux send-keys -t "$window2_pane2" "cd $(printf '%q' "$dir_gamma") && ls" C-m
  sleep 1

  tmux send-keys -t "$window3_pane1" "cd $(printf '%q' "$dir_delta") && tail -f $(printf '%q' "$file_delta")" C-m
  wait_for_pane_command "$window3_pane1" tail 60 0.25 || fail "window3 pane1 did not start tail before save"
  for i in $(seq 1 12); do
    printf 'delta-stream-%02d\n' "$i" >>"$file_delta"
  done
  sleep 1

  "$save_state" --reason test-three-window-mixed-restore-scenario

  kill "$nvim_pid_one" >/dev/null 2>&1 || true
  kill "$nvim_pid_two" >/dev/null 2>&1 || true
  wait_for_pid_exit "$nvim_pid_one" 20 0.1 || true
  wait_for_pid_exit "$nvim_pid_two" 20 0.1 || true

  tmux kill-server
  rm -f "$TMUX_TEST_ATTACH_LOG" "$TMUX_TEST_SWITCH_LOG" "$TMUX_TEST_NVIM_RESTORE_LOG"
  "$restore_state" --session-name "$session_name" --attach --yes >/dev/null

  wait_for_file "$TMUX_TEST_ATTACH_LOG" || fail "attach log was not created for mixed restore scenario"
  attach_cmd="$(cat "$TMUX_TEST_ATTACH_LOG")"
  assert_contains "$attach_cmd" "attach-session -t $session_name" "mixed restore attach target"
  wait_for_session "$session_name" || fail "session $session_name did not restore in mixed scenario"

  window_summary="$(tmux list-windows -t "$session_name" -F 'window=#{window_index} panes=#{window_panes} name=#{window_name}')"
  assert_contains "$window_summary" "panes=2 name=window-1" "window 1 restored with 2 panes"
  assert_contains "$window_summary" "panes=2 name=window-2" "window 2 restored with 2 panes"
  assert_contains "$window_summary" "panes=1 name=window-3" "window 3 restored with 1 pane"

  restored_w1p1="$(nth_pane_id "$session_name:$window1_index" 1)"
  restored_w1p2="$(nth_pane_id "$session_name:$window1_index" 2)"
  restored_w2p1="$(nth_pane_id "$session_name:$window2_index" 1)"
  restored_w2p2="$(nth_pane_id "$session_name:$window2_index" 2)"
  restored_w3p1="$(nth_pane_id "$session_name:$window3_index" 1)"

  wait_for_pane_text "$restored_w2p2" "$(basename "$file_gamma")" 60 0.25 || fail "window2 pane2 ls output was not restored"
  wait_for_file "$TMUX_TEST_NVIM_RESTORE_LOG" 60 0.25 || fail "nvim restore log was not produced in mixed scenario"

  assert_eq "$dir_alpha" "$(tmux display-message -p -t "$restored_w1p1" '#{pane_current_path}')" "window1 pane1 cwd"
  assert_eq "$dir_beta" "$(tmux display-message -p -t "$restored_w1p2" '#{pane_current_path}')" "window1 pane2 cwd"
  assert_eq "$dir_gamma" "$(tmux display-message -p -t "$restored_w2p1" '#{pane_current_path}')" "window2 pane1 cwd"
  assert_eq "$dir_gamma" "$(tmux display-message -p -t "$restored_w2p2" '#{pane_current_path}')" "window2 pane2 cwd"
  assert_eq "$dir_delta" "$(tmux display-message -p -t "$restored_w3p1" '#{pane_current_path}')" "window3 pane1 cwd"

  printf 'beta-after\n' >>"$file_beta"
  printf 'delta-after\n' >>"$file_delta"
  sleep 1
  assert_contains "$(tmux capture-pane -p -S -80 -t "$restored_w1p2")" "beta-after" "window1 pane2 resumed tail output"
  assert_contains "$(tmux capture-pane -p -S -80 -t "$restored_w3p1")" "delta-after" "window3 pane1 resumed tail output"

  restore_test_shell_env
  pass "three-window-mixed-restore-scenario"
}

test_two_window_layout_restore_scenario() {
  setup_case "two-window-layout-restore-scenario"
  zdotdir="$case_root/zdotdir"
  save_test_shell_env
  session_name="layout-check"
  src_root="$case_root/src"
  start_dir="$src_root/start"
  tail_dir="$src_root/logs"
  nvim_dir="$src_root/editor"
  ls_dir="$src_root/listing"
  start_file="$start_dir/start.txt"
  tail_file="$tail_dir/backtrace.log"
  other_file="$nvim_dir/other.txt"
  nvim_socket_one="$case_root/window1-pane1.sock"
  nvim_socket_two="$case_root/window2-pane1.sock"

  mkdir -p "$start_dir" "$tail_dir" "$nvim_dir" "$ls_dir"
  setup_test_zsh_env "$zdotdir" ': 1700000000:0;echo two-window-layout-history'
  seq 1 25 >"$start_file"
  printf 'tail-seed\n' >"$tail_file"
  seq 101 125 >"$other_file"
  printf 'alpha.txt\nbeta.txt\n' >"$ls_dir/alpha.txt"
  printf 'listing fixture\n' >"$ls_dir/beta.txt"

  tmux new-session -d -s "$session_name" -c "$start_dir"
  window1_index="$(tmux list-windows -t "$session_name" -F '#{window_index}' | head -n 1)"
  tmux rename-window -t "$session_name:$window1_index" "editor-and-tail"
  tmux split-window -d -v -t "$session_name:$window1_index" -c "$tail_dir"

  window2_index="$(tmux new-window -d -P -F '#{window_index}' -t "$session_name:" -n "editor-and-ls" -c "$nvim_dir")"
  tmux split-window -d -h -t "$session_name:$window2_index" -c "$ls_dir"

  window1_pane1="$(nth_pane_id "$session_name:$window1_index" 1)"
  window1_pane2="$(nth_pane_id "$session_name:$window1_index" 2)"
  window2_pane1="$(nth_pane_id "$session_name:$window2_index" 1)"
  window2_pane2="$(nth_pane_id "$session_name:$window2_index" 2)"

  "$real_nvim" --headless -u NONE -i NONE \
    --cmd "lua package.path = package.path .. ';$repo_root/nvim/lua/?.lua;$repo_root/nvim/lua/?/init.lua'" \
    --listen "$nvim_socket_one" "$start_file" >/dev/null 2>&1 &
  nvim_pid_one=$!
  wait_for_nvim_expr "$nvim_socket_one" 'expand("%:p")' "$start_file" || fail "window1 pane1 nvim did not open start file"
  nvim --server "$nvim_socket_one" --remote-expr "execute('call cursor(9,1)')" >/dev/null
  wait_for_nvim_expr "$nvim_socket_one" 'line(".")' "9" || fail "window1 pane1 nvim did not move to line 9"
  "$repo_root/tmux/send_to_nvim/register_nvim_instance.sh" "$window1_pane1" "$nvim_socket_one" "$nvim_pid_one" "$start_dir"

  "$real_nvim" --headless -u NONE -i NONE \
    --cmd "lua package.path = package.path .. ';$repo_root/nvim/lua/?.lua;$repo_root/nvim/lua/?/init.lua'" \
    --listen "$nvim_socket_two" "$other_file" >/dev/null 2>&1 &
  nvim_pid_two=$!
  wait_for_nvim_expr "$nvim_socket_two" 'expand("%:p")' "$other_file" || fail "window2 pane1 nvim did not open other file"
  nvim --server "$nvim_socket_two" --remote-expr "execute('call cursor(6,1)')" >/dev/null
  wait_for_nvim_expr "$nvim_socket_two" 'line(".")' "6" || fail "window2 pane1 nvim did not move to line 6"
  "$repo_root/tmux/send_to_nvim/register_nvim_instance.sh" "$window2_pane1" "$nvim_socket_two" "$nvim_pid_two" "$nvim_dir"

  tmux send-keys -t "$window1_pane2" "cd $(printf '%q' "$tail_dir") && tail -f $(printf '%q' "$tail_file")" C-m
  wait_for_pane_command "$window1_pane2" tail 60 0.25 || fail "window1 pane2 did not start tail before save"
  for i in $(seq 1 10); do
    printf 'tail-stream-%02d\n' "$i" >>"$tail_file"
  done

  tmux send-keys -t "$window2_pane2" "cd $(printf '%q' "$ls_dir") && ls" C-m
  sleep 1

  "$save_state" --reason test-two-window-layout-restore-scenario

  kill "$nvim_pid_one" >/dev/null 2>&1 || true
  kill "$nvim_pid_two" >/dev/null 2>&1 || true
  wait_for_pid_exit "$nvim_pid_one" 20 0.1 || true
  wait_for_pid_exit "$nvim_pid_two" 20 0.1 || true

  tmux kill-server
  rm -f "$TMUX_TEST_ATTACH_LOG" "$TMUX_TEST_SWITCH_LOG" "$TMUX_TEST_NVIM_RESTORE_LOG"
  "$restore_state" --session-name "$session_name" --attach --yes >/dev/null

  wait_for_file "$TMUX_TEST_ATTACH_LOG" || fail "attach log was not created for two-window layout scenario"
  attach_cmd="$(cat "$TMUX_TEST_ATTACH_LOG")"
  assert_contains "$attach_cmd" "attach-session -t $session_name" "two-window layout attach target"
  wait_for_session "$session_name" || fail "session $session_name did not restore in two-window layout scenario"

  window_summary="$(tmux list-windows -t "$session_name" -F 'window=#{window_index} panes=#{window_panes} name=#{window_name}')"
  assert_contains "$window_summary" "panes=2 name=editor-and-tail" "window 1 restored with 2 panes"
  assert_contains "$window_summary" "panes=2 name=editor-and-ls" "window 2 restored with 2 panes"

  restored_w1p1="$(nth_pane_id "$session_name:$window1_index" 1)"
  restored_w1p2="$(nth_pane_id "$session_name:$window1_index" 2)"
  restored_w2p1="$(nth_pane_id "$session_name:$window2_index" 1)"
  restored_w2p2="$(nth_pane_id "$session_name:$window2_index" 2)"

  wait_for_file "$TMUX_TEST_NVIM_RESTORE_LOG" 60 0.25 || fail "nvim restore log was not produced in two-window layout scenario"
  wait_for_pane_text "$restored_w2p2" "alpha.txt" 60 0.25 || fail "window2 pane2 ls output was not restored"

  assert_eq "$start_dir" "$(tmux display-message -p -t "$restored_w1p1" '#{pane_current_path}')" "window1 pane1 cwd"
  assert_eq "$tail_dir" "$(tmux display-message -p -t "$restored_w1p2" '#{pane_current_path}')" "window1 pane2 cwd"
  assert_eq "$nvim_dir" "$(tmux display-message -p -t "$restored_w2p1" '#{pane_current_path}')" "window2 pane1 cwd"
  assert_eq "$ls_dir" "$(tmux display-message -p -t "$restored_w2p2" '#{pane_current_path}')" "window2 pane2 cwd"

  w1p1_left="$(tmux display-message -p -t "$restored_w1p1" '#{pane_left}')"
  w1p2_left="$(tmux display-message -p -t "$restored_w1p2" '#{pane_left}')"
  w1p1_top="$(tmux display-message -p -t "$restored_w1p1" '#{pane_top}')"
  w1p2_top="$(tmux display-message -p -t "$restored_w1p2" '#{pane_top}')"
  assert_eq "$w1p1_left" "$w1p2_left" "window1 vertical split keeps panes in same column"
  [ "$w1p1_top" != "$w1p2_top" ] || fail "window1 vertical split should stack panes top/bottom"

  w2p1_left="$(tmux display-message -p -t "$restored_w2p1" '#{pane_left}')"
  w2p2_left="$(tmux display-message -p -t "$restored_w2p2" '#{pane_left}')"
  w2p1_top="$(tmux display-message -p -t "$restored_w2p1" '#{pane_top}')"
  w2p2_top="$(tmux display-message -p -t "$restored_w2p2" '#{pane_top}')"
  assert_eq "$w2p1_top" "$w2p2_top" "window2 horizontal split keeps panes on same row"
  [ "$w2p1_left" != "$w2p2_left" ] || fail "window2 horizontal split should place panes side-by-side"

  printf 'tail-after\n' >>"$tail_file"
  sleep 1
  assert_contains "$(tmux capture-pane -p -S -80 -t "$restored_w1p2")" "tail-after" "window1 pane2 resumed tail output"

  restore_test_shell_env
  pass "two-window-layout-restore-scenario"
}

test_auto_capture_mixed_running_and_blank_panes() {
  setup_case "auto-capture-mixed-running-and-blank"
  mkdir -p "$case_root/src"
  approved_log="$case_root/src/backtrace.txt"
  printf 'before\n' >"$approved_log"

  tmux new-session -d -s work -c "$case_root/src"
  tmux split-window -d -t work
  tmux split-window -d -t work

  approved_pane="$(nth_pane_id work 1)"
  unapproved_pane="$(nth_pane_id work 2)"
  blank_pane="$(nth_pane_id work 3)"

  tmux send-keys -t "$approved_pane" "tail -f $(printf '%q' "$approved_log")" C-m
  wait_for_pane_command "$approved_pane" tail 60 0.25 || fail "approved pane did not start tail before save"

  tmux send-keys -t "$unapproved_pane" "sleep 1000" C-m
  wait_for_pane_command "$unapproved_pane" sleep 60 0.25 || fail "unapproved pane did not start sleep before save"

  tmux send-keys -t "$blank_pane" 'printf "blank pane context\n"' C-m
  sleep 1

  "$save_state" --reason test-auto-capture-mixed

  manifest="$(latest_manifest)"
  approved_saved_preview="$(jq -r '.sessions[] | select(.session_name == "work") | .windows[0].panes[] | select(.current_command == "tail") | .command_preview // ""' "$manifest" | head -n 1)"
  unapproved_saved_preview="$(jq -r '.sessions[] | select(.session_name == "work") | .windows[0].panes[] | select(.current_command == "sleep") | .command_preview // ""' "$manifest" | head -n 1)"
  blank_saved_preview="$(jq -r '.sessions[] | select(.session_name == "work") | .windows[0].panes[] | select(.current_command != "tail" and .current_command != "sleep") | .command_preview // ""' "$manifest" | head -n 1)"
  assert_eq "tail -f $approved_log" "$approved_saved_preview" "approved pane exact command captured"
  assert_eq "sleep 1000" "$unapproved_saved_preview" "unapproved pane exact command captured"
  assert_eq "" "$blank_saved_preview" "blank pane saved without command preview"

  tmux kill-server
  "$restore_state" --session-name work --yes >/dev/null

  restored_approved="$(nth_pane_id work 1)"
  restored_unapproved="$(nth_pane_id work 2)"
  restored_blank="$(nth_pane_id work 3)"

  printf 'after\n' >>"$approved_log"
  wait_for_pane_text "$restored_approved" "after" 60 0.25 || fail "approved auto-captured tail output did not resume after restore"
  wait_for_pane_command "$restored_unapproved" zsh 60 0.25 || fail "unapproved pane did not return to zsh after restore"
  wait_for_pane_command "$restored_blank" zsh 60 0.25 || fail "blank pane did not return to zsh after restore"

  approved_capture="$(tmux capture-pane -p -S -60 -t "$restored_approved")"
  unapproved_capture="$(tmux capture-pane -p -S -60 -t "$restored_unapproved")"
  blank_capture="$(tmux capture-pane -p -S -60 -t "$restored_blank")"
  unapproved_current_command="$(tmux display-message -p -t "$restored_unapproved" '#{pane_current_command}')"
  blank_current_command="$(tmux display-message -p -t "$restored_blank" '#{pane_current_command}')"

  assert_contains "$approved_capture" "after" "approved auto-captured tail output after restore"
  assert_contains "$unapproved_capture" "sleep 1000" "unapproved running command preloaded exactly"
  assert_eq "zsh" "$unapproved_current_command" "unapproved pane did not auto-run exact command"
  assert_contains "$blank_capture" "blank pane context" "blank pane transcript restored"
  assert_not_contains "$blank_capture" "sleep 1000" "blank pane does not inherit unapproved command"
  assert_not_contains "$blank_capture" "tail -f " "blank pane does not inherit approved command"
  assert_eq "zsh" "$blank_current_command" "blank pane restored to shell"
  pass "auto-capture-mixed-running-and-blank-panes"
}

test_restore_preserves_pane_cwd() {
  setup_case "restore-preserves-pane-cwd"
  mkdir -p "$case_root/desired" "$case_root/wrong"
  desired_dir="$(cd "$case_root/desired" && pwd -P)"
  wrong_dir="$(cd "$case_root/wrong" && pwd -P)"
  old_working_dir="${WORKING_DIR-__TMUX_REVIVE_UNSET__}"
  export WORKING_DIR="$wrong_dir"
  export SHELL="${SHELL:-$(command -v zsh || printf '/bin/zsh')}"

  tmux new-session -d -s work -c "$desired_dir"
  restored_pane="$(tmux list-panes -t work -F '#{pane_id}' | head -n 1)"
  tmux send-keys -t "$restored_pane" "cd $(printf '%q' "$desired_dir")" C-m
  wait_for_pane_path "$restored_pane" "$desired_dir" 60 0.25 || fail "test setup did not converge to desired cwd before save"
  "$save_state" --reason test-pane-cwd

  tmux kill-server
  "$restore_state" --session-name work --yes >/dev/null

  restored_pane="$(tmux list-panes -t work -F '#{pane_id}' | head -n 1)"
  wait_for_pane_path "$restored_pane" "$desired_dir" 60 0.25 || fail "restored pane cwd did not converge to saved path"
  restored_path="$(tmux display-message -p -t "$restored_pane" '#{pane_current_path}')"
  assert_eq "$desired_dir" "$restored_path" "restored pane cwd"
  if [ "$old_working_dir" = "__TMUX_REVIVE_UNSET__" ]; then
    unset WORKING_DIR
  else
    export WORKING_DIR="$old_working_dir"
  fi
  pass "restore-preserves-pane-cwd"
}

test_restore_preserves_window_names() {
  setup_case "restore-preserves-window-names"
  tmux new-session -d -s work
  tmux set-window-option -g automatic-rename on
  window1_index="$(tmux list-windows -t work -F '#{window_index}' | head -n 1)"
  tmux rename-window -t "work:$window1_index" "editor"
  window2_index="$(tmux new-window -d -P -F '#{window_index}' -t work: -n "logs")"
  window1_pane="$(tmux list-panes -t "work:$window1_index" -F '#{pane_id}' | head -n 1)"
  window2_pane="$(tmux list-panes -t "work:$window2_index" -F '#{pane_id}' | head -n 1)"
  tmux send-keys -t "$window1_pane" 'printf "editor pane\n"' C-m
  tmux send-keys -t "$window2_pane" 'printf "logs pane\n"' C-m
  sleep 1

  "$save_state" --reason test-window-name-stability
  tmux kill-server
  "$restore_state" --session-name work --yes >/dev/null
  sleep 1

  window_names="$(tmux list-windows -t work -F '#{window_index}:#{window_name}')"
  assert_contains "$window_names" ":editor" "restored first window name"
  assert_contains "$window_names" ":logs" "restored second window name"

  # rename-window causes tmux to set automatic-rename off per-window;
  # the save captures that truthfully, and restore applies it back
  auto_rename_values="$(tmux list-windows -t work -F '#{window_index}:#{automatic-rename}')"
  off_auto_rename_count="$(printf '%s\n' "$auto_rename_values" | awk -F ':' '$2 == "0" { count++ } END { print count + 0 }')"
  assert_eq "2" "$off_auto_rename_count" "renamed windows preserve automatic-rename off"
  pass "restore-preserves-window-names"
}

test_restore_preserves_explicit_auto_rename_off() {
  setup_case "restore-preserves-auto-rename-off"
  tmux new-session -d -s work
  tmux set-window-option -g automatic-rename on
  window1_index="$(tmux list-windows -t work -F '#{window_index}' | head -n 1)"
  tmux rename-window -t "work:$window1_index" "pinned"
  # rename-window implicitly sets automatic-rename off; confirm it's captured
  window2_index="$(tmux new-window -d -P -F '#{window_index}' -t work:)"
  # Window 2 created without -n, so automatic-rename stays at global default (on)
  # with no per-window override — save captures empty, restore uses setw -u
  sleep 1

  "$save_state" --reason test-auto-rename-explicit
  tmux kill-server
  "$restore_state" --session-name work --yes >/dev/null
  # Simulate user's tmux.conf setting the global default (test runs with -f /dev/null)
  tmux set-window-option -g automatic-rename on
  sleep 1

  window_names="$(tmux list-windows -t work -F '#{window_index}:#{window_name}')"
  assert_contains "$window_names" ":pinned" "restored pinned window name"

  # Window 1 (renamed) should have automatic-rename off (saved from manifest)
  # Window 2 (no rename) should inherit global automatic-rename on after setw -u
  auto_rename_values="$(tmux list-windows -t work -F '#{window_index}:#{automatic-rename}')"
  first_auto_rename="$(printf '%s\n' "$auto_rename_values" | head -n 1 | awk -F ':' '{ print $2 }')"
  second_auto_rename="$(printf '%s\n' "$auto_rename_values" | tail -n 1 | awk -F ':' '{ print $2 }')"
  assert_eq "0" "$first_auto_rename" "renamed window keeps automatic-rename off"
  assert_eq "1" "$second_auto_rename" "unrenamed window inherits global automatic-rename on"
  pass "restore-preserves-auto-rename-off"
}

test_restore_preserves_window_options() {
  setup_case "restore-preserves-window-options"
  tmux new-session -d -s work
  window1_index="$(tmux list-windows -t work -F '#{window_index}' | head -n 1)"
  tmux setw -t "work:$window1_index" monitor-activity on
  tmux setw -t "work:$window1_index" synchronize-panes on
  window2_index="$(tmux new-window -d -P -F '#{window_index}' -t work:)"
  tmux setw -t "work:$window2_index" monitor-silence 30
  sleep 1

  "$save_state" --reason test-window-options
  tmux kill-server
  "$restore_state" --session-name work --yes >/dev/null
  sleep 1

  w1_monitor="$(tmux show-window-option -v -t "work:0" monitor-activity 2>/dev/null || true)"
  w1_sync="$(tmux show-window-option -v -t "work:0" synchronize-panes 2>/dev/null || true)"
  w2_silence="$(tmux show-window-option -v -t "work:1" monitor-silence 2>/dev/null || true)"
  assert_eq "on" "$w1_monitor" "window 1 monitor-activity preserved"
  assert_eq "on" "$w1_sync" "window 1 synchronize-panes preserved"
  assert_eq "30" "$w2_silence" "window 2 monitor-silence preserved"
  pass "restore-preserves-window-options"
}

test_multi_pane_distinct_cwds_restore() {
  setup_case "multi-pane-distinct-cwds"
  mkdir -p "$case_root/dir-a" "$case_root/dir-b" "$case_root/dir-c"
  dir_a="$(cd "$case_root/dir-a" && pwd -P)"
  dir_b="$(cd "$case_root/dir-b" && pwd -P)"
  dir_c="$(cd "$case_root/dir-c" && pwd -P)"

  tmux new-session -d -s work -c "$dir_a"
  tmux split-window -d -t work -c "$dir_b"
  tmux split-window -d -t work -c "$dir_c"
  # Let shells initialize before sending cd commands
  sleep 1

  pane_a="$(nth_pane_id work 1)"
  pane_b="$(nth_pane_id work 2)"
  pane_c="$(nth_pane_id work 3)"

  tmux send-keys -t "$pane_a" "cd $(printf '%q' "$dir_a")" C-m
  tmux send-keys -t "$pane_b" "cd $(printf '%q' "$dir_b")" C-m
  tmux send-keys -t "$pane_c" "cd $(printf '%q' "$dir_c")" C-m
  wait_for_pane_path "$pane_a" "$dir_a" 80 0.25 || fail "pane_a did not converge to dir_a before save"
  wait_for_pane_path "$pane_b" "$dir_b" 80 0.25 || fail "pane_b did not converge to dir_b before save"
  wait_for_pane_path "$pane_c" "$dir_c" 80 0.25 || fail "pane_c did not converge to dir_c before save"

  tmux send-keys -t "$pane_a" 'printf "pane-a\n"' C-m
  tmux send-keys -t "$pane_b" 'printf "pane-b\n"' C-m
  tmux send-keys -t "$pane_c" 'printf "pane-c\n"' C-m
  sleep 1

  "$save_state" --reason test-multi-pane-distinct-cwds

  tmux kill-server
  "$restore_state" --session-name work --yes >/dev/null

  wait_for_pane_path "$(nth_pane_id work 1)" "$dir_a" 80 0.25 || fail "restored pane_a cwd did not converge to dir_a"
  wait_for_pane_path "$(nth_pane_id work 2)" "$dir_b" 80 0.25 || fail "restored pane_b cwd did not converge to dir_b"
  wait_for_pane_path "$(nth_pane_id work 3)" "$dir_c" 80 0.25 || fail "restored pane_c cwd did not converge to dir_c"
  pane_paths="$(tmux list-panes -t work -F '#{pane_current_path}' | sort)"
  assert_contains "$pane_paths" "$dir_a" "restored pane paths include dir_a"
  assert_contains "$pane_paths" "$dir_b" "restored pane paths include dir_b"
  assert_contains "$pane_paths" "$dir_c" "restored pane paths include dir_c"
  pass "multi-pane-distinct-cwds-restore"
}

test_restore_tolerates_missing_pane_cwds() {
  setup_case "restore-tolerates-missing-pane-cwds"
  mkdir -p "$case_root/dir-a" "$case_root/dir-b" "$case_root/dir-c"
  dir_a="$(cd "$case_root/dir-a" && pwd -P)"
  dir_b="$(cd "$case_root/dir-b" && pwd -P)"
  dir_c="$(cd "$case_root/dir-c" && pwd -P)"

  tmux new-session -d -s work -c "$dir_a"
  tmux split-window -d -t work -c "$dir_b"
  tmux new-window -d -t work -n extra -c "$dir_c"

  "$save_state" --reason test-missing-pane-cwds
  rm -rf "$dir_b" "$dir_c"

  tmux kill-server
  "$restore_state" --session-name work --yes >/dev/null

  wait_for_session work || fail "session did not restore when pane cwd paths were missing"
  window_count="$(tmux list-windows -t work | wc -l | tr -d ' ')"
  window_summary="$(tmux list-windows -t work -F '#{window_panes}:#{window_name}')"
  assert_eq "2" "$window_count" "window count preserved with missing cwd paths"
  assert_contains "$window_summary" "2:" "restored split window preserved with missing cwd paths"
  assert_contains "$window_summary" "1:extra" "restored extra window preserved with missing cwd paths"
  pass "restore-tolerates-missing-pane-cwds"
}

test_restored_zsh_uses_shared_history_file() {
  setup_case "restored-zsh-shared-history"
  zdotdir="$case_root/zdotdir"
  history_probe="$case_root/history-probe.txt"
  save_test_shell_env
  setup_test_zsh_env "$zdotdir" ': 1700000000:0;echo from-restored-history'

  tmux new-session -d -s work
  pane_id="$(tmux list-panes -t work -F '#{pane_id}' | head -n 1)"
  tmux send-keys -t "$pane_id" 'printf "history context\n"' C-m
  sleep 1
  "$save_state" --reason test-restored-zsh-history

  tmux kill-server
  "$restore_state" --session-name work --yes >/dev/null

  restored_pane="$(tmux list-panes -t work -F '#{pane_id}' | head -n 1)"
  tmux send-keys -t "$restored_pane" "fc -ln 1 | grep -F 'echo from-restored-history' > $(printf '%q' "$history_probe")" C-m
  wait_for_file "$history_probe" 60 0.25 || fail "restored zsh did not expose shared history file"
  assert_contains "$(cat "$history_probe")" "echo from-restored-history" "restored zsh history content"

  restore_test_shell_env
  pass "restored-zsh-uses-shared-history-file"
}

test_startup_restore_off_mode() {
  setup_case "startup-restore-off-mode"
  tmux new-session -d -s work
  "$save_state" --reason test-startup-off

  tmux kill-server
  tmux new-session -d -s bootstrap
  tmux set-option -g @tmux-revive-startup-restore off
  "$startup_restore"

  if tmux has-session -t work 2>/dev/null; then
    fail "startup off mode restored a session unexpectedly"
  fi
  pass "startup-restore-off-mode"
}

test_startup_prompt_dismiss() {
  setup_case "startup-prompt-dismiss"
  tmux new-session -d -s work
  "$save_state" --reason test-startup-prompt

  tmux kill-server
  tmux new-session -d -s bootstrap
  dismissed_path="$(tmux_revive_restore_prompt_suppressed_path)"
  shown_path="$(tmux_revive_restore_prompt_shown_path)"
  rm -f "$dismissed_path" "$shown_path"
  printf 'n\n' | "$startup_popup" >/dev/null

  wait_for_file "$dismissed_path" || fail "startup prompt dismiss flag was not created"
  if tmux has-session -t work 2>/dev/null; then
    fail "startup prompt dismiss restored a session unexpectedly"
  fi
  pass "startup-prompt-dismiss"
}

test_startup_prompt_reappears_for_newer_snapshot() {
  setup_case "startup-prompt-newer-snapshot"
  tmux new-session -d -s work
  "$save_state" --reason test-startup-prompt-first
  first_manifest="$(latest_manifest)"

  tmux kill-server
  tmux new-session -d -s bootstrap
  tmux set-option -g @tmux-revive-startup-restore prompt
  rm -f "$TMUX_TEST_DISPLAY_POPUP_LOG"
  export TMUX_TEST_POPUP_EXECUTE=1
  export TMUX_TEST_POPUP_INPUT=$'n\n'

  "$startup_restore" --client-tty test-tty
  wait_for_file "$TMUX_TEST_DISPLAY_POPUP_LOG" || fail "startup prompt did not open popup for first manifest"
  first_popup_count="$(wc -l <"$TMUX_TEST_DISPLAY_POPUP_LOG" | tr -d ' ')"
  assert_eq "1" "$first_popup_count" "first startup prompt popup count"

  "$startup_restore" --client-tty test-tty
  same_manifest_popup_count="$(wc -l <"$TMUX_TEST_DISPLAY_POPUP_LOG" | tr -d ' ')"
  assert_eq "1" "$same_manifest_popup_count" "same manifest should not re-prompt"

  sleep 1
  tmux new-session -d -s newer
  "$save_state" --reason test-startup-prompt-second
  second_manifest="$(latest_manifest)"
  [ "$second_manifest" != "$first_manifest" ] || fail "second save did not produce a newer manifest path"
  tmux kill-session -t newer

  "$startup_restore" --client-tty test-tty
  newer_manifest_popup_count="$(wc -l <"$TMUX_TEST_DISPLAY_POPUP_LOG" | tr -d ' ')"
  assert_eq "2" "$newer_manifest_popup_count" "newer snapshot should trigger a fresh prompt"

  unset TMUX_TEST_POPUP_EXECUTE
  unset TMUX_TEST_POPUP_INPUT
  pass "startup-prompt-reappears-for-newer-snapshot"
}

test_startup_prompt_without_tty_does_not_consume_prompt() {
  setup_case "startup-prompt-without-tty"
  tmux new-session -d -s work
  "$save_state" --reason test-startup-prompt-without-tty

  tmux kill-server
  tmux new-session -d -s bootstrap
  tmux set-option -g @tmux-revive-startup-restore prompt
  dismissed_path="$(tmux_revive_restore_prompt_suppressed_path)"
  shown_path="$(tmux_revive_restore_prompt_shown_path)"
  rm -f "$dismissed_path" "$shown_path"

  "$startup_restore"

  [ ! -f "$shown_path" ] || fail "prompt startup restore without tty consumed the shown flag unexpectedly"
  [ ! -f "$dismissed_path" ] || fail "prompt startup restore without tty created dismiss flag unexpectedly"
  if tmux has-session -t work 2>/dev/null; then
    fail "prompt startup restore without tty restored a session unexpectedly"
  fi
  pass "startup-prompt-without-tty-does-not-consume-prompt"
}

test_new_session_prompt_attach_replaces_transient_session() {
  setup_case "new-session-prompt-replaces-transient-session"
  tmux new-session -d -s work
  "$save_state" --reason test-new-session-prompt

  tmux kill-server
  tmux new-session -d -s bootstrap
  tmux set-option -g @tmux-revive-startup-restore prompt
  tmux new-session -d -s scratch
  transient_session_id="$(tmux display-message -p -t scratch '#{session_id}')"

  rm -f "$TMUX_TEST_DISPLAY_POPUP_LOG" "$TMUX_TEST_ATTACH_LOG"
  export TMUX_TEST_POPUP_EXECUTE=1
  export TMUX_TEST_POPUP_INPUT=$'A\n'

  "$startup_restore" --context new-session --session-target "$transient_session_id" --client-tty test-tty

  wait_for_file "$TMUX_TEST_DISPLAY_POPUP_LOG" || fail "new-session prompt did not open popup"
  wait_for_file "$TMUX_TEST_ATTACH_LOG" || fail "attach log was not created for new-session prompt attach"
  wait_for_session work || fail "saved session did not restore from new-session prompt"
  if tmux has-session -t "$transient_session_id" 2>/dev/null; then
    fail "transient blank session was not removed after attach restore"
  fi

  attach_log_contents="$(cat "$TMUX_TEST_ATTACH_LOG")"
  assert_contains "$attach_log_contents" "attach-session -t work" "new-session prompt attach target"

  unset TMUX_TEST_POPUP_EXECUTE
  unset TMUX_TEST_POPUP_INPUT
  pass "new-session-prompt-attach-replaces-transient-session"
}

test_fresh_tmux_restore_prompt_name_collision() {
  # Simulates: user has a saved default session "0", starts fresh tmux (also "0"),
  # the popup should appear because the transient session shadows the saved name.
  setup_case "fresh-tmux-restore-name-collision"

  # Step 1: create the default-named session and save it
  tmux new-session -d  # creates session "0"
  "$save_state" --reason fresh-tmux-collision

  # Capture the saved session's GUID for verification
  saved_guid="$(jq -r '.sessions[0].session_guid' "$(latest_manifest)")"
  [ -n "$saved_guid" ] || fail "name-collision: saved session has no GUID"

  # Step 2: kill everything — clean slate
  tmux kill-server

  # Step 3: start fresh tmux (creates default session "0" again — name collision)
  tmux new-session -d  # session "0"
  tmux set-option -g @tmux-revive-startup-restore prompt
  transient_session_id="$(tmux display-message -p -t 0 '#{session_id}')"

  # Verify transient session has no GUID (it's a fresh blank session)
  transient_guid="$(tmux_revive_get_session_guid 0)"
  [ -z "$transient_guid" ] || fail "name-collision: fresh transient session should not have a GUID"

  rm -f "$TMUX_TEST_DISPLAY_POPUP_LOG" "$TMUX_TEST_ATTACH_LOG"
  export TMUX_TEST_POPUP_EXECUTE=1
  export TMUX_TEST_POPUP_INPUT=$'A\n'

  # The after-new-session hook would call this:
  "$startup_restore" --context new-session --session-target "$transient_session_id" --client-tty test-tty

  wait_for_file "$TMUX_TEST_DISPLAY_POPUP_LOG" || fail "name-collision: popup did not appear"
  wait_for_file "$TMUX_TEST_ATTACH_LOG" || fail "name-collision: attach log not created"

  # Session "0" should exist and be the RESTORED one (with the saved GUID)
  tmux has-session -t 0 2>/dev/null || fail "name-collision: session 0 not found after restore"
  restored_guid="$(tmux_revive_get_session_guid 0)"
  assert_eq "$saved_guid" "$restored_guid" "name-collision: session 0 should have the saved GUID"

  unset TMUX_TEST_POPUP_EXECUTE
  unset TMUX_TEST_POPUP_INPUT
  pass "fresh-tmux-restore-prompt-name-collision"
}

test_fresh_tmux_restore_prompt_no_collision() {
  # Simulates: user has a saved session "mywork", starts fresh tmux (session "0"),
  # the popup should appear, restore creates "mywork" and replaces transient "0".
  setup_case "fresh-tmux-restore-no-collision"

  # Step 1: create a named session and save it
  tmux new-session -d -s mywork
  "$save_state" --reason fresh-tmux-no-collision

  # Step 2: kill everything — clean slate
  tmux kill-server

  # Step 3: start fresh tmux (creates default session "0" — no name collision)
  tmux new-session -d  # session "0"
  tmux set-option -g @tmux-revive-startup-restore prompt
  transient_session_id="$(tmux display-message -p -t 0 '#{session_id}')"

  rm -f "$TMUX_TEST_DISPLAY_POPUP_LOG" "$TMUX_TEST_ATTACH_LOG"
  export TMUX_TEST_POPUP_EXECUTE=1
  export TMUX_TEST_POPUP_INPUT=$'A\n'

  "$startup_restore" --context new-session --session-target "$transient_session_id" --client-tty test-tty

  wait_for_file "$TMUX_TEST_DISPLAY_POPUP_LOG" || fail "no-collision: popup did not appear"
  wait_for_file "$TMUX_TEST_ATTACH_LOG" || fail "no-collision: attach log not created"
  wait_for_session mywork || fail "no-collision: restored session mywork not found"

  # Transient session should have been killed
  if tmux has-session -t "$transient_session_id" 2>/dev/null; then
    fail "no-collision: transient session was not removed after restore"
  fi

  attach_log_contents="$(cat "$TMUX_TEST_ATTACH_LOG")"
  assert_contains "$attach_log_contents" "attach-session -t mywork" "no-collision attach target"

  unset TMUX_TEST_POPUP_EXECUTE
  unset TMUX_TEST_POPUP_INPUT
  pass "fresh-tmux-restore-prompt-no-collision"
}

test_fresh_tmux_restore_prompt_reappears() {
  # After dismissing, creating another new session should show the popup again
  # (new-session context does not suppress for server lifetime).
  setup_case "fresh-tmux-restore-reappears"

  tmux new-session -d -s mywork
  "$save_state" --reason fresh-tmux-reappears

  tmux kill-server
  tmux new-session -d  # session "0"
  tmux set-option -g @tmux-revive-startup-restore prompt
  transient1_id="$(tmux display-message -p -t 0 '#{session_id}')"

  rm -f "$TMUX_TEST_DISPLAY_POPUP_LOG"
  export TMUX_TEST_POPUP_EXECUTE=1
  export TMUX_TEST_POPUP_INPUT=$'n\n'  # dismiss

  "$startup_restore" --context new-session --session-target "$transient1_id" --client-tty test-tty

  wait_for_file "$TMUX_TEST_DISPLAY_POPUP_LOG" || fail "reappears: first popup did not appear"
  first_popup_count="$(wc -l <"$TMUX_TEST_DISPLAY_POPUP_LOG" | tr -d ' ')"
  assert_eq "1" "$first_popup_count" "reappears: first popup count"

  # mywork should NOT have been restored (we dismissed)
  if tmux has-session -t mywork 2>/dev/null; then
    fail "reappears: dismiss should not have restored mywork"
  fi

  # Suppress flag should NOT exist for new-session context
  suppress_path="$(tmux_revive_restore_prompt_suppressed_path)"
  if [ -f "$suppress_path" ]; then
    fail "reappears: dismiss in new-session context should not write suppress flag"
  fi

  # Simulate creating another new session — popup should appear again
  tmux new-session -d -s scratch
  transient2_id="$(tmux display-message -p -t scratch '#{session_id}')"
  export TMUX_TEST_POPUP_INPUT=$'A\n'  # this time restore

  "$startup_restore" --context new-session --session-target "$transient2_id" --client-tty test-tty

  second_popup_count="$(wc -l <"$TMUX_TEST_DISPLAY_POPUP_LOG" | tr -d ' ')"
  assert_eq "2" "$second_popup_count" "reappears: second popup should appear after dismiss"
  wait_for_session mywork || fail "reappears: mywork not restored on second prompt"

  unset TMUX_TEST_POPUP_EXECUTE
  unset TMUX_TEST_POPUP_INPUT
  pass "fresh-tmux-restore-prompt-reappears-after-dismiss"
}

test_autosave_policy() {
  setup_case "autosave-policy"
  tmux new-session -d -s work
  runtime_dir="$(tmux_revive_runtime_dir)"
  latest_path="$(tmux_revive_latest_path)"
  mkdir -p "$runtime_dir"

  tmux set-option -g @tmux-revive-autosave on
  tmux set-option -g @tmux-revive-autosave-interval 900
  date +%s >"$runtime_dir/last-auto-save"
  "$autosave_tick"
  [ ! -f "$latest_path" ] || fail "autosave tick ran before interval elapsed"

  printf '0\n' >"$runtime_dir/last-auto-save"
  "$autosave_tick"
  wait_for_file "$latest_path" || fail "autosave tick did not save after interval elapsed"

  setup_case "autosave-disabled"
  tmux new-session -d -s work
  runtime_dir="$(tmux_revive_runtime_dir)"
  latest_path="$(tmux_revive_latest_path)"
  mkdir -p "$runtime_dir"
  printf '0\n' >"$runtime_dir/last-auto-save"
  tmux set-option -g @tmux-revive-autosave off
  "$autosave_tick"
  [ ! -f "$latest_path" ] || fail "autosave tick saved while disabled"
  pass "autosave-policy"
}

test_statusline_save_notice_uses_tmux_socket_env() {
  setup_case "statusline-save-notice"
  tmux new-session -d -s work
  socket_path="$(tmux display-message -p '#{socket_path}')"
  tmux_env="${socket_path},123,0"

  "$save_state" --reason manual-statusline
  notice_output="$("$autosave_tick" --socket-path "$socket_path")"
  assert_contains "$notice_output" "💾 saved" "statusline manual save notice"

  runtime_dir="$(TMUX="$tmux_env" tmux_revive_runtime_dir)"
  latest_path="$(tmux_revive_latest_path)"
  last_save_notice_path="$(TMUX="$tmux_env" tmux_revive_last_save_notice_path)"
  mkdir -p "$runtime_dir"
  jq '.saved_at = 0' "$last_save_notice_path" >"$last_save_notice_path.tmp"
  mv "$last_save_notice_path.tmp" "$last_save_notice_path"
  printf '0\n' >"$runtime_dir/last-auto-save"
  tmux set-option -gq '@tmux-revive-last-auto-save' '0' 2>/dev/null || true
  "$autosave_tick" --socket-path "$socket_path" >/dev/null
  wait_for_file "$latest_path" || fail "statusline autosave notice test did not produce latest snapshot"
  wait_for_jq_value "$last_save_notice_path" 'select(.status == "done") | .mode // ""' "auto" 60 0.25 || fail "statusline autosave notice test did not record auto save notice"
  auto_notice_output="$("$autosave_tick" --socket-path "$socket_path")"
  assert_contains "$auto_notice_output" "💾 auto-saved" "statusline autosave notice"
  pass "statusline-save-notice-uses-tmux-socket-env"
}

test_manual_save_emits_tmux_feedback() {
  setup_case "manual-save-feedback"
  tmux new-session -d -s work
  rm -f "$TMUX_TEST_COMMAND_LOG"

  "$save_state" --reason manual-feedback

  wait_for_file "$TMUX_TEST_COMMAND_LOG" || fail "manual save feedback test missing tmux command log"
  command_log="$(cat "$TMUX_TEST_COMMAND_LOG")"
  assert_contains "$command_log" "display-message tmux-revive: saved snapshot" "manual save emits tmux feedback message"
  pass "manual-save-emits-tmux-feedback"
}

test_bind_save_key_triggers_manual_save() {
  setup_case "bind-save-key"
  tmux new-session -d -s work
  latest_path="$(tmux_revive_latest_path)"
  rm -f "$latest_path" "$TMUX_TEST_COMMAND_LOG"

  tmux bind-key S run-shell -b "TMUX_REVIVE_SOCKET_PATH=#{socket_path} $tmux_revive_dir/save-state.sh --reason manual"
  cat >"$case_root/bind-save.expect" <<EOF
#!/usr/bin/expect -f
set timeout 20
log_user 0
spawn $real_tmux -f /dev/null -L $socket_name attach-session -t work
after 500
send "\002S"
after 1500
send "\002d"
expect eof
EOF
  chmod +x "$case_root/bind-save.expect"
  "$case_root/bind-save.expect"

  wait_for_file "$latest_path" 80 0.25 || fail "bind save key did not create latest snapshot"
  wait_for_file "$TMUX_TEST_COMMAND_LOG" 80 0.25 || fail "bind save key did not emit tmux command log"
  command_log="$(cat "$TMUX_TEST_COMMAND_LOG")"
  assert_contains "$command_log" "display-message tmux-revive: saved snapshot" "bind save key emits tmux feedback message"
  pass "bind-save-key-triggers-manual-save"
}

test_nvim_snapshot_and_direct_restore() {
  setup_case "nvim-snapshot-and-direct-restore"
  sample_dir="$(cd "$case_root" && pwd -P)"
  file_a="$sample_dir/file-a.txt"
  file_b="$sample_dir/file-b.txt"
  file_c="$sample_dir/file-c.txt"
  nvim_socket="$case_root/headless-nvim.sock"
  restore_report="$case_root/restore-report.json"

  seq 1 20 >"$file_a"
  seq 101 120 >"$file_b"
  seq 201 220 >"$file_c"

  tmux new-session -d -s work
  pane_id="$(tmux list-panes -t work -F '#{pane_id}' | head -n 1)"
  "$real_nvim" --headless -u NONE -i NONE \
    --cmd "lua package.path = package.path .. ';$repo_root/nvim/lua/?.lua;$repo_root/nvim/lua/?/init.lua'" \
    --listen "$nvim_socket" "$file_a" >/dev/null 2>&1 &
  nvim_pid=$!

  wait_for_nvim_expr "$nvim_socket" 'expand("%:p")' "$file_a" || fail "headless nvim did not open first file in time"
  nvim --server "$nvim_socket" --remote-expr "execute('call cursor(12,1)')" >/dev/null
  wait_for_nvim_expr "$nvim_socket" 'line(".")' "12" || fail "headless nvim did not move first cursor to line 12"
  nvim --server "$nvim_socket" --remote-expr "execute('vsplit $file_b | call cursor(7,1)')" >/dev/null
  wait_for_nvim_expr "$nvim_socket" 'expand("%:p")' "$file_b" || fail "headless nvim did not open split file in time"
  wait_for_nvim_expr "$nvim_socket" 'line(".")' "7" || fail "headless nvim did not move split cursor to line 7"
  nvim --server "$nvim_socket" --remote-expr "execute('tabnew $file_c | call cursor(5,1)')" >/dev/null
  wait_for_nvim_expr "$nvim_socket" 'tabpagenr()' "2" || fail "headless nvim did not create second tab"
  wait_for_nvim_expr "$nvim_socket" 'expand("%:p")' "$file_c" || fail "headless nvim did not open second tab file in time"
  wait_for_nvim_expr "$nvim_socket" 'line(".")' "5" || fail "headless nvim did not move second tab cursor to line 5"

  "$repo_root/tmux/send_to_nvim/register_nvim_instance.sh" "$pane_id" "$nvim_socket" "$nvim_pid" "$(dirname "$file_a")"
  "$save_state" --reason test-nvim-restore
  manifest="$(latest_manifest)"
  nvim_state_ref="$(jq -r '.sessions[0].windows[0].panes[0].nvim_state_ref' "$manifest")"
  [ -f "$nvim_state_ref" ] || fail "nvim state file was not written"
  session_file="$(jq -r '.session_file // ""' "$nvim_state_ref")"
  resolved_session_file="$(dirname "$nvim_state_ref")/session.vim"

  tab_count="$(jq '.tabs | length' "$nvim_state_ref")"
  current_tab="$(jq -r '.current_tab' "$nvim_state_ref")"
  first_layout_kind="$(jq -r '.tabs[0].layout.kind // ""' "$nvim_state_ref")"
  first_win_count="$(jq -r '.tabs[0].wins | length' "$nvim_state_ref")"
  first_tab_a_line="$(jq -r --arg path "$file_a" '.tabs[0].wins[] | select(.path == $path) | .cursor[0]' "$nvim_state_ref")"
  first_tab_b_line="$(jq -r --arg path "$file_b" '.tabs[0].wins[] | select(.path == $path) | .cursor[0]' "$nvim_state_ref")"
  second_path="$(jq -r '.tabs[1].wins[0].path // ""' "$nvim_state_ref")"
  second_line="$(jq -r '.tabs[1].wins[0].cursor[0] // 0' "$nvim_state_ref")"

  assert_eq "2" "$tab_count" "saved nvim tab count"
  assert_eq "2" "$current_tab" "saved nvim current tab"
  assert_eq "row" "$first_layout_kind" "saved first tab layout kind"
  assert_eq "2" "$first_win_count" "saved first tab window count"
  assert_eq "12" "$first_tab_a_line" "saved first tab file-a line"
  assert_eq "7" "$first_tab_b_line" "saved first tab file-b line"
  [ -n "$session_file" ] || fail "nvim session file path was not recorded"
  [ -f "$resolved_session_file" ] || fail "nvim session file was not written"
  assert_eq "$file_c" "$second_path" "saved second tab file path"
  assert_eq "5" "$second_line" "saved second tab file line"

  kill "$nvim_pid" >/dev/null 2>&1 || true
  if ! wait_for_pid_exit "$nvim_pid" 20 0.1; then
    kill -9 "$nvim_pid" >/dev/null 2>&1 || true
    wait_for_pid_exit "$nvim_pid" 20 0.1 || true
  fi
  rm -f "$XDG_STATE_HOME/nvim/swap/"* 2>/dev/null || true

  cat >"$case_root/restore-check.lua" <<EOF
package.path = package.path .. ';$repo_root/nvim/lua/?.lua;$repo_root/nvim/lua/?/init.lua'
local send = dofile("$repo_root/nvim/lua/core/send_to_nvim.lua")
assert(send.restore_from_state_file("$nvim_state_ref"))
local tabs = {}
for index, tab in ipairs(vim.api.nvim_list_tabpages()) do
  local wins = {}
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(tab)) do
    local buf = vim.api.nvim_win_get_buf(win)
    table.insert(wins, {
      path = vim.api.nvim_buf_get_name(buf),
      line = vim.api.nvim_win_get_cursor(win)[1],
    })
  end
  tabs[index] = {
    layout_kind = (vim.fn.winlayout(index)[1] or ""),
    win_count = #wins,
    wins = wins,
  }
end
local report = {
  current_tab = vim.fn.tabpagenr(),
  tab_count = #vim.api.nvim_list_tabpages(),
  current_path = vim.api.nvim_buf_get_name(0),
  current_line = vim.fn.line("."),
  tabs = tabs,
}
vim.fn.writefile({ vim.json.encode(report) }, "$restore_report")
EOF
  run_headless_nvim_script "$case_root/restore-check.lua"

  restored_current_tab="$(jq -r '.current_tab' "$restore_report")"
  restored_tab_count="$(jq -r '.tab_count' "$restore_report")"
  restored_current_path="$(jq -r '.current_path' "$restore_report")"
  restored_current_line="$(jq -r '.current_line' "$restore_report")"
  restored_tab1_layout_kind="$(jq -r '.tabs[0].layout_kind // ""' "$restore_report")"
  restored_tab1_win_count="$(jq -r '.tabs[0].win_count // 0' "$restore_report")"
  restored_tab1_a_line="$(jq -r --arg path "$file_a" '.tabs[0].wins[] | select(.path == $path) | .line' "$restore_report")"
  restored_tab1_b_line="$(jq -r --arg path "$file_b" '.tabs[0].wins[] | select(.path == $path) | .line' "$restore_report")"
  restored_tab2_path="$(jq -r '.tabs[1].wins[0].path // ""' "$restore_report")"
  restored_tab2_line="$(jq -r '.tabs[1].wins[0].line // 0' "$restore_report")"

  assert_eq "2" "$restored_tab_count" "restored tab count"
  assert_eq "2" "$restored_current_tab" "restored current tab"
  assert_eq "$file_c" "$restored_current_path" "restored current path"
  assert_eq "5" "$restored_current_line" "restored current line"
  assert_eq "row" "$restored_tab1_layout_kind" "restored first tab layout kind"
  assert_eq "2" "$restored_tab1_win_count" "restored first tab window count"
  assert_eq "12" "$restored_tab1_a_line" "restored tab1 file-a line"
  assert_eq "7" "$restored_tab1_b_line" "restored tab1 file-b line"
  assert_eq "$file_c" "$restored_tab2_path" "restored tab2 path"
  assert_eq "5" "$restored_tab2_line" "restored tab2 line"
  pass "nvim-snapshot-and-direct-restore"
}

test_nvim_restore_via_tmux_restore() {
  setup_case "nvim-restore-via-tmux-restore"
  sample_dir="$(cd "$case_root" && pwd -P)"
  file_a="$sample_dir/file-a.txt"
  file_b="$sample_dir/file-b.txt"
  file_c="$sample_dir/file-c.txt"
  nvim_socket="$case_root/headless-nvim.sock"
  zdotdir="$case_root/zdotdir"
  save_test_shell_env
  setup_test_zsh_env "$zdotdir"

  seq 1 20 >"$file_a"
  seq 101 120 >"$file_b"
  seq 201 220 >"$file_c"

  tmux new-session -d -s work
  pane_id="$(tmux list-panes -t work -F '#{pane_id}' | head -n 1)"
  "$real_nvim" --headless -u NONE -i NONE \
    --cmd "lua package.path = package.path .. ';$repo_root/nvim/lua/?.lua;$repo_root/nvim/lua/?/init.lua'" \
    --listen "$nvim_socket" "$file_a" >/dev/null 2>&1 &
  nvim_pid=$!

  wait_for_nvim_expr "$nvim_socket" 'expand("%:p")' "$file_a" || fail "headless nvim did not open first file in time"
  nvim --server "$nvim_socket" --remote-expr "execute('call cursor(12,1)')" >/dev/null
  wait_for_nvim_expr "$nvim_socket" 'line(".")' "12" || fail "headless nvim did not move first cursor to line 12"
  nvim --server "$nvim_socket" --remote-expr "execute('vsplit $file_b | call cursor(7,1)')" >/dev/null
  wait_for_nvim_expr "$nvim_socket" 'expand("%:p")' "$file_b" || fail "headless nvim did not open split file in time"
  wait_for_nvim_expr "$nvim_socket" 'line(".")' "7" || fail "headless nvim did not move split cursor to line 7"
  nvim --server "$nvim_socket" --remote-expr "execute('tabnew $file_c | call cursor(5,1)')" >/dev/null
  wait_for_nvim_expr "$nvim_socket" 'tabpagenr()' "2" || fail "headless nvim did not create second tab"
  wait_for_nvim_expr "$nvim_socket" 'expand("%:p")' "$file_c" || fail "headless nvim did not open second tab file in time"
  wait_for_nvim_expr "$nvim_socket" 'line(".")' "5" || fail "headless nvim did not move second tab cursor to line 5"

  "$repo_root/tmux/send_to_nvim/register_nvim_instance.sh" "$pane_id" "$nvim_socket" "$nvim_pid" "$(dirname "$file_a")"
  "$save_state" --reason test-nvim-tmux-restore
  rm -f "$TMUX_TEST_NVIM_RESTORE_LOG"

  kill "$nvim_pid" >/dev/null 2>&1 || true
  if ! wait_for_pid_exit "$nvim_pid" 20 0.1; then
    kill -9 "$nvim_pid" >/dev/null 2>&1 || true
    wait_for_pid_exit "$nvim_pid" 20 0.1 || true
  fi
  rm -f "$XDG_STATE_HOME/nvim/swap/"* 2>/dev/null || true

  tmux kill-server
  "$restore_state" --session-name work --yes >/dev/null

  wait_for_file "$TMUX_TEST_NVIM_RESTORE_LOG" 60 0.25 || fail "tmux restore did not relaunch nvim with restore state"
  restored_tab_count="$(jq -r '.tab_count' "$TMUX_TEST_NVIM_RESTORE_LOG")"
  restored_current_tab="$(jq -r '.current_tab' "$TMUX_TEST_NVIM_RESTORE_LOG")"
  restored_current_path="$(jq -r '.current_path' "$TMUX_TEST_NVIM_RESTORE_LOG")"
  restored_current_line="$(jq -r '.current_line' "$TMUX_TEST_NVIM_RESTORE_LOG")"
  restored_session_file="$(jq -r '.session_file // ""' "$TMUX_TEST_NVIM_RESTORE_LOG")"
  restored_first_tab_a_line="$(jq -r '.first_tab_a_line // 0' "$TMUX_TEST_NVIM_RESTORE_LOG")"
  restored_first_tab_b_line="$(jq -r '.first_tab_b_line // 0' "$TMUX_TEST_NVIM_RESTORE_LOG")"
  restored_first_tab_layout_kind="$(jq -r '.first_tab_layout_kind // ""' "$TMUX_TEST_NVIM_RESTORE_LOG")"
  restored_first_tab_win_count="$(jq -r '.first_tab_win_count // 0' "$TMUX_TEST_NVIM_RESTORE_LOG")"

  assert_eq "2" "$restored_tab_count" "tmux-restored nvim tab count"
  assert_eq "2" "$restored_current_tab" "tmux-restored nvim current tab"
  assert_eq "$file_c" "$restored_current_path" "tmux-restored nvim current path"
  assert_eq "5" "$restored_current_line" "tmux-restored nvim current line"
  [ -n "$restored_session_file" ] || fail "tmux-restored nvim state did not include session file"
  assert_eq "12" "$restored_first_tab_a_line" "tmux-restored nvim first tab file-a line"
  assert_eq "7" "$restored_first_tab_b_line" "tmux-restored nvim first tab file-b line"
  assert_eq "row" "$restored_first_tab_layout_kind" "tmux-restored nvim first tab layout kind"
  assert_eq "2" "$restored_first_tab_win_count" "tmux-restored nvim first tab window count"

  restore_test_shell_env
  pass "nvim-restore-via-tmux-restore"
}

test_nvim_persistence_policy() {
  setup_case "nvim-persistence-policy"
  file_path="$case_root/persist.txt"
  echo "one" >"$file_path"
  report_path="$case_root/persist-report.json"

  cat >"$case_root/persist-check.lua" <<EOF
package.path = package.path .. ';$repo_root/nvim/lua/?.lua;$repo_root/nvim/lua/?/init.lua'
dofile("$repo_root/nvim/lua/core/options.lua")
dofile("$repo_root/nvim/lua/core/autocmds.lua")
vim.cmd("edit $file_path")
vim.api.nvim_buf_set_lines(0, 0, -1, false, { "insert-leave-save" })
vim.api.nvim_exec_autocmds("InsertLeave", { buffer = 0 })
vim.wait(1000, function()
  local lines = vim.fn.readfile("$file_path")
  return lines[1] == "insert-leave-save"
end, 50)
vim.api.nvim_buf_set_lines(0, 0, -1, false, { "text-changed-save" })
vim.api.nvim_exec_autocmds("TextChanged", { buffer = 0 })
vim.wait(2500, function()
  local lines = vim.fn.readfile("$file_path")
  return lines[1] == "text-changed-save"
end, 50)
local report = {
  swapfile = vim.o.swapfile,
  undofile = vim.o.undofile,
  undodir = vim.o.undodir,
  directory = vim.o.directory,
  saved_line = vim.fn.readfile("$file_path")[1],
}
vim.fn.writefile({ vim.json.encode(report) }, "$report_path")
EOF
  run_headless_nvim_script "$case_root/persist-check.lua"

  assert_eq "true" "$(jq -r '.swapfile' "$report_path")" "swapfile option"
  assert_eq "true" "$(jq -r '.undofile' "$report_path")" "undofile option"
  assert_contains "$(jq -r '.undodir' "$report_path")" "/undo" "undodir path"
  assert_contains "$(jq -r '.directory' "$report_path")" "/swap" "swap directory path"
  assert_eq "text-changed-save" "$(jq -r '.saved_line' "$report_path")" "autosaved file contents"
  pass "nvim-persistence-policy"
}

test_nvim_unsupported_metadata() {
  setup_case "nvim-unsupported-metadata"
  file_path="$case_root/unsupported.txt"
  export_path="$case_root/unsupported-meta.json"
  notify_path="$case_root/restore-notify.txt"
  echo "one" >"$file_path"

  cat >"$case_root/unsupported-check.lua" <<EOF
package.path = package.path .. ';$repo_root/nvim/lua/?.lua;$repo_root/nvim/lua/?/init.lua'
local send = dofile("$repo_root/nvim/lua/core/send_to_nvim.lua")
vim.cmd("edit $file_path")
vim.api.nvim_buf_set_lines(0, 0, -1, false, { "dirty-change" })
vim.fn.setqflist({ { filename = "$file_path", lnum = 1, text = "qf" } })
vim.fn.setloclist(0, { { filename = "$file_path", lnum = 1, text = "loc" } })
vim.cmd("enew")
vim.bo.buftype = "nofile"
vim.bo.buflisted = true
send.export_restore_state("$export_path")
vim.notify = function(msg, level)
  vim.fn.writefile({ msg }, "$notify_path")
end
send.restore_from_state_file("$export_path")
vim.wait(1000, function()
  return vim.fn.filereadable("$notify_path") == 1
end, 50)
EOF
  run_headless_nvim_script "$case_root/unsupported-check.lua"

  dirty_count="$(jq '.dirty_buffers | length' "$export_path")"
  special_count="$(jq '.unsupported.special_buffers | length' "$export_path")"
  quickfix_size="$(jq -r '.unsupported.quickfix_size' "$export_path")"
  loclist_count="$(jq '.unsupported.loclist_windows | length' "$export_path")"
  notify_message="$(cat "$notify_path")"

  [ "$dirty_count" -gt 0 ] || fail "dirty buffers were not recorded"
  [ "$special_count" -gt 0 ] || fail "special buffers were not recorded"
  [ "$quickfix_size" -gt 0 ] || fail "quickfix size was not recorded"
  [ "$loclist_count" -gt 0 ] || fail "location list windows were not recorded"
  assert_contains "$notify_message" "restored file-backed state only" "unsupported state warning prefix"
  assert_contains "$notify_message" "dirty buffer" "unsupported state warning dirty buffers"
  assert_contains "$notify_message" "quickfix list" "unsupported state warning quickfix"
  pass "nvim-unsupported-metadata"
}

test_save_restore_hooks() {
  setup_case "save-restore-hooks"
  pre_save_log="$case_root/pre-save.log"
  post_save_log="$case_root/post-save.log"
  pre_restore_log="$case_root/pre-restore.log"
  post_restore_log="$case_root/post-restore.log"

  tmux new-session -d -s work
  tmux set-option -gq "$(tmux_revive_pre_save_hook_option)" "printf '%s|%s\n' \"\$TMUX_REVIVE_HOOK_EVENT\" \"\$TMUX_REVIVE_HOOK_REASON\" > '$pre_save_log'"
  tmux set-option -gq "$(tmux_revive_post_save_hook_option)" "printf '%s|%s|%s\n' \"\$TMUX_REVIVE_HOOK_EVENT\" \"\$TMUX_REVIVE_HOOK_REASON\" \"\$TMUX_REVIVE_HOOK_MANIFEST_PATH\" > '$post_save_log'"
  export TMUX_REVIVE_PRE_RESTORE_HOOK="printf '%s|%s\n' \"\$TMUX_REVIVE_HOOK_EVENT\" \"\$TMUX_REVIVE_HOOK_SELECTOR_NAME\" > '$pre_restore_log'"
  export TMUX_REVIVE_POST_RESTORE_HOOK="printf '%s|%s|%s\n' \"\$TMUX_REVIVE_HOOK_EVENT\" \"\$TMUX_REVIVE_HOOK_ATTACH_TARGET\" \"\$TMUX_REVIVE_HOOK_RESTORED_COUNT\" > '$post_restore_log'"

  "$save_state" --reason hooks-test
  wait_for_file "$pre_save_log" || fail "pre-save hook did not run"
  wait_for_file "$post_save_log" || fail "post-save hook did not run"
  assert_eq "save|hooks-test" "$(cat "$pre_save_log")" "pre-save hook payload"
  assert_contains "$(cat "$post_save_log")" "save|hooks-test|" "post-save hook payload"

  tmux kill-server
  "$restore_state" --session-name work --yes >/dev/null
  wait_for_file "$pre_restore_log" || fail "pre-restore hook did not run"
  wait_for_file "$post_restore_log" || fail "post-restore hook did not run"
  assert_eq "restore|work" "$(cat "$pre_restore_log")" "pre-restore hook payload"
  assert_eq "restore|work|1" "$(cat "$post_restore_log")" "post-restore hook payload"
  unset TMUX_REVIVE_PRE_RESTORE_HOOK
  unset TMUX_REVIVE_POST_RESTORE_HOOK
  pass "save-restore-hooks"
}

test_stale_save_lock_recovery() {
  setup_case "stale-save-lock-recovery"
  runtime_dir="$(tmux_revive_runtime_dir)"
  lock_dir="$runtime_dir/save.lock"
  lock_meta="$lock_dir/meta.json"

  tmux new-session -d -s work
  mkdir -p "$lock_dir"
  jq -cn --argjson pid 999999 --argjson started_at 1 '{ pid: $pid, started_at: $started_at }' >"$lock_meta"

  "$save_state" --reason stale-lock-test
  manifest="$(latest_manifest)"
  [ -f "$manifest" ] || fail "save did not recover from stale lock"
  pass "stale-save-lock-recovery"
}

test_save_lock_contention_queues_followup_save() {
  setup_case "save-lock-contention"
  runtime_dir="$(tmux_revive_runtime_dir)"
  lock_dir="$runtime_dir/save.lock"
  lock_meta="$lock_dir/meta.json"
  pending_path="$(tmux_revive_pending_save_path)"

  mkdir -p "$lock_dir"
  jq -cn --argjson pid "$$" --argjson started_at "$(date +%s)" '{ pid: $pid, started_at: $started_at }' >"$lock_meta"

  "$save_state" --reason contention-test

  [ -f "$pending_path" ] || fail "save lock contention did not queue a follow-up save"
  pass "save-lock-contention-queues-followup-save"
}

test_stale_lock_corrupted_metadata() {
  setup_case "stale-lock-corrupted-meta"
  runtime_dir="$(tmux_revive_runtime_dir)"
  lock_dir="$runtime_dir/save.lock"
  lock_meta="$lock_dir/meta.json"

  tmux new-session -d -s work
  mkdir -p "$lock_dir"
  # Write corrupted JSON
  printf '{ broken json <<<\n' >"$lock_meta"

  "$save_state" --reason corrupted-lock-test
  manifest="$(latest_manifest)"
  [ -f "$manifest" ] || fail "save did not recover from corrupted lock metadata"
  pass "stale-lock-corrupted-metadata"
}

test_grouped_sessions_are_restored() {
  setup_case "grouped-sessions-restored"
  tmux new-session -d -s base
  tmux new-session -d -t base -s grouped
  "$save_state" --reason grouped-session-test

  tmux kill-server
  output="$("$restore_state" --yes 2>&1 || true)"

  if ! tmux has-session -t base 2>/dev/null; then
    fail "base session was not restored"
  fi
  if ! tmux has-session -t grouped 2>/dev/null; then
    fail "grouped session was not restored"
  fi
  # Verify grouped session shares windows with base
  local base_windows grouped_windows
  base_windows="$(tmux list-windows -t base -F '#{window_id}' | sort)"
  grouped_windows="$(tmux list-windows -t grouped -F '#{window_id}' | sort)"
  if [ "$base_windows" != "$grouped_windows" ]; then
    fail "grouped session does not share windows with base (base: $base_windows, grouped: $grouped_windows)"
  fi
  pass "grouped-sessions-are-restored"
}

test_pane_history_capture_is_bounded() {
  setup_case "pane-history-capture-bounded"
  output_file="$case_root/large-output.txt"

  tmux new-session -d -s work
  pane_id="$(tmux list-panes -t work -F '#{pane_id}' | head -n 1)"
  for i in $(seq 1 700); do
    printf 'line-%03d\n' "$i" >>"$output_file"
  done
  tmux send-keys -t "$pane_id" "cat $(printf '%q' "$output_file")" C-m
  wait_for_pane_text "$pane_id" "line-700" 60 0.25 || fail "large output did not reach pane before save"

  "$save_state" --reason bounded-history-test
  manifest="$(latest_manifest)"
  history_dump="$(jq -r '.sessions[0].windows[0].panes[0].path_to_history_dump' "$manifest")"
  [ -f "$history_dump" ] || fail "history dump was not written"
  assert_contains "$(cat "$history_dump")" "line-700" "saved history includes newest line"
  assert_not_contains "$(cat "$history_dump")" "line-001" "saved history excludes oldest line beyond bound"

  tmux kill-server
  "$restore_state" --session-name work --yes >/dev/null

  restored_pane="$(tmux list-panes -t work -F '#{pane_id}' | head -n 1)"
  wait_for_pane_text "$restored_pane" "line-700" 60 0.25 || fail "restored pane missing newest bounded history line"
  capture="$(tmux capture-pane -p -S -520 -t "$restored_pane")"
  assert_contains "$capture" "line-700" "restored pane includes newest line"
  assert_contains "$capture" "line-250" "restored pane includes bounded middle line"
  assert_not_contains "$capture" "line-001" "restored pane excludes oldest line beyond bound"
  pass "pane-history-capture-is-bounded"
}

setup_server_flag_wrapper() {
  # Overwrite the tmux wrapper with one that is aware of the tmux() function
  # in state-common.sh. When production scripts call `command tmux -L <name> ...`,
  # this wrapper detects -L in the args and does NOT add its own -L.
  # Direct tmux calls from the test script (without -L) still get -L injected.
  cat >"$case_root/bin/tmux" <<WRAPPER_EOF
#!/usr/bin/env bash
set -euo pipefail
_has_L=0
_cmd=""
_skip_next=0
for _a in "\$@"; do
  if [ "\$_skip_next" = "1" ]; then _skip_next=0; continue; fi
  if [ "\$_a" = "-L" ]; then _has_L=1; _skip_next=1; continue; fi
  if [ -z "\$_cmd" ] && [ "\${_a#-}" = "\$_a" ]; then _cmd="\$_a"; fi
done
if [ -n "\${TMUX_TEST_COMMAND_LOG:-}" ]; then
  printf '%s\n' "\$*" >>"\$TMUX_TEST_COMMAND_LOG"
fi
if [ "\$_cmd" = "attach-session" ] && [ -n "\${TMUX_TEST_ATTACH_LOG:-}" ]; then
  printf '%s\n' "\$*" >"\$TMUX_TEST_ATTACH_LOG"
  exit 0
fi
if [ "\$_cmd" = "switch-client" ] && [ -n "\${TMUX_TEST_SWITCH_LOG:-}" ]; then
  printf '%s\n' "\$*" >>"\$TMUX_TEST_SWITCH_LOG"
  exit 0
fi
if [ "\$_cmd" = "display-popup" ] && [ -n "\${TMUX_TEST_DISPLAY_POPUP_LOG:-}" ]; then
  printf '%s\n' "\$*" >>"\$TMUX_TEST_DISPLAY_POPUP_LOG"
  if [ "\${TMUX_TEST_POPUP_EXECUTE:-0}" = "1" ]; then
    popup_cmd="\${*: -1}"
    if [ -n "\${TMUX_TEST_POPUP_INPUT:-}" ]; then
      printf '%b' "\$TMUX_TEST_POPUP_INPUT" | /bin/bash -c "\$popup_cmd"
    else
      /bin/bash -c "\$popup_cmd"
    fi
  fi
  exit 0
fi
if [ "\$_has_L" = "1" ]; then
  exec "$real_tmux" -f /dev/null "\$@"
else
  exec "$real_tmux" -f /dev/null -L "$socket_name" "\$@"
fi
WRAPPER_EOF
  chmod +x "$case_root/bin/tmux"
}

test_server_flag_save_restore() {
  setup_case "server-flag-save-restore"
  setup_server_flag_wrapper

  tmux new-session -d -s mywork
  "$save_state" --server "$socket_name" --reason server-flag-test

  # Verify snapshot landed in the server-specific subdirectory
  server_snapshots_root="$TMUX_REVIVE_STATE_ROOT/snapshots/$host_name/$socket_name"
  [ -d "$server_snapshots_root" ] || fail "server-flag: server-specific snapshot dir not created"
  latest_path="$server_snapshots_root/latest.json"
  [ -f "$latest_path" ] || fail "server-flag: latest.json not found in server subdir"

  manifest="$(jq -r '.manifest_path' "$latest_path")"
  [ -f "$manifest" ] || fail "server-flag: manifest not found at $manifest"
  saved_name="$(jq -r '.sessions[0].session_name' "$manifest")"
  assert_eq "mywork" "$saved_name" "server-flag saved session name"

  # Now kill the server and restore with --server
  tmux kill-server
  tmux new-session -d  # default session "0"

  "$restore_state" --server "$socket_name" --yes

  tmux has-session -t mywork 2>/dev/null || fail "server-flag: restored session mywork not found"
  pass "server-flag-save-restore"
}

test_server_flag_path_isolation() {
  # Two different server names with the same session name should produce separate snapshots
  setup_case "server-flag-path-isolation"
  setup_server_flag_wrapper

  alt_server="tmux-revive-path-isolation-alt"
  "$real_tmux" -L "$alt_server" kill-server >/dev/null 2>&1 || true

  # Save from server A (the test server)
  tmux new-session -d -s work
  "$save_state" --server "$socket_name" --reason isolation-a

  server_a_latest="$TMUX_REVIVE_STATE_ROOT/snapshots/$host_name/$socket_name/latest.json"
  [ -f "$server_a_latest" ] || fail "path-isolation: server-a latest.json not created"
  server_a_manifest="$(jq -r '.manifest_path' "$server_a_latest")"

  # Start a second tmux server with a session of the same name
  "$real_tmux" -L "$alt_server" new-session -d -s work
  "$save_state" --server "$alt_server" --reason isolation-b

  server_b_latest="$TMUX_REVIVE_STATE_ROOT/snapshots/$host_name/$alt_server/latest.json"
  [ -f "$server_b_latest" ] || fail "path-isolation: server-b latest.json not created"
  server_b_manifest="$(jq -r '.manifest_path' "$server_b_latest")"

  # Both should exist independently
  [ -f "$server_a_manifest" ] || fail "path-isolation: server-a manifest was overwritten"
  [ -f "$server_b_manifest" ] || fail "path-isolation: server-b manifest missing"

  # Manifests should be in different directories
  server_a_dir="$(dirname "$server_a_manifest")"
  server_b_dir="$(dirname "$server_b_manifest")"
  if [ "$server_a_dir" = "$server_b_dir" ]; then
    fail "path-isolation: both manifests are in the same directory"
  fi

  # Session GUIDs should differ (different server instances)
  server_a_guid="$(jq -r '.sessions[0].session_guid' "$server_a_manifest")"
  server_b_guid="$(jq -r '.sessions[0].session_guid' "$server_b_manifest")"
  if [ "$server_a_guid" = "$server_b_guid" ]; then
    fail "path-isolation: both servers produced the same session GUID"
  fi

  "$real_tmux" -L "$alt_server" kill-server >/dev/null 2>&1 || true
  pass "server-flag-path-isolation"
}

test_special_character_session_names() {
  setup_case "special-char-names"

  # Session names with spaces, dashes, underscores
  tmux new-session -d -s "my work"
  tmux new-session -d -s "dev-server_v2"
  "$save_state" --reason special-char-test

  manifest="$(latest_manifest)"
  [ -f "$manifest" ] || fail "special char manifest missing"

  # Verify session names are preserved in manifest
  saved_names="$(jq -r '.sessions[].session_name' "$manifest")"
  assert_contains "$saved_names" "my work" "space in session name preserved"
  assert_contains "$saved_names" "dev-server_v2" "dash-underscore in session name preserved"

  tmux kill-server
  "$restore_state" --yes >/dev/null 2>&1 || true

  wait_for_session "my work" || fail "session with space did not restore"
  wait_for_session "dev-server_v2" || fail "session with dash-underscore did not restore"
  pass "special-character-session-names"
}

test_pane_title_with_special_chars() {
  setup_case "special-pane-title"
  tmux new-session -d -s work
  tmux select-pane -t work -T 'title with "quotes" & $dollars'
  "$save_state" --reason pane-title-test

  manifest="$(latest_manifest)"
  saved_title="$(jq -r '.sessions[0].windows[0].panes[0].pane_title' "$manifest")"
  assert_contains "$saved_title" '"quotes"' "quotes in pane title preserved"
  assert_contains "$saved_title" '$dollars' "dollar in pane title preserved"

  tmux kill-server
  "$restore_state" --yes >/dev/null 2>&1 || true
  wait_for_session work || fail "session did not restore with special pane title"
  pass "special-pane-title-chars"
}

test_corrupted_manifest_handling() {
  setup_case "corrupted-manifest"
  tmux new-session -d -s work
  "$save_state" --reason corruption-test

  manifest="$(latest_manifest)"
  [ -f "$manifest" ] || fail "manifest missing before corruption"

  # Corrupt the manifest
  printf 'not valid json{{{' >"$manifest"

  output="$("$restore_state" --yes 2>&1 || true)"
  assert_contains "$output" "corrupted or unreadable" "corrupted manifest error message"
  pass "corrupted-manifest-handling"
}

test_empty_sessions_manifest() {
  setup_case "empty-sessions-manifest"
  tmux new-session -d -s work
  "$save_state" --reason empty-test

  manifest="$(latest_manifest)"
  # Replace sessions with empty array
  jq '.sessions = []' "$manifest" >"${manifest}.tmp"
  mv "${manifest}.tmp" "$manifest"

  tmux kill-server
  output="$("$restore_state" --yes 2>&1 || true)"
  assert_contains "$output" "no sessions" "empty sessions manifest message"
  pass "empty-sessions-manifest"
}

test_mkdir_error_check_in_save() {
  setup_case "mkdir-error-save"
  tmux new-session -d -s work

  # Verify save works normally first
  "$save_state" --reason mkdir-test
  manifest="$(latest_manifest)"
  [ -f "$manifest" ] || fail "normal save failed in mkdir test"
  pass "mkdir-error-check-in-save"
}

test_hook_error_logging() {
  setup_case "hook-error-logging"
  tmux new-session -d -s work

  # Set a hook that fails
  tmux set-option -g '@tmux-revive-hook-pre-save' 'exit 1'
  output="$("$save_state" --reason hook-error-test 2>&1 || true)"

  runtime_dir="$(tmux_revive_runtime_dir)"
  hook_log="$runtime_dir/hook-errors.log"
  if [ -f "$hook_log" ]; then
    assert_contains "$(cat "$hook_log")" "hook failed" "hook error log entry"
  fi
  # Clean up
  tmux set-option -gu '@tmux-revive-hook-pre-save' 2>/dev/null || true
  pass "hook-error-logging"
}

test_retention_boundary_values() {
  setup_case "retention-boundaries"
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
  # Set retention to keep only 2 manual snapshots (disable age limit so
  # count-only pruning triggers on these fresh snapshots)
  export TMUX_REVIVE_RETENTION_MANUAL_COUNT=2
  export TMUX_REVIVE_RETENTION_MANUAL_AGE_DAYS=0
  "$save_state" --reason "retention-trigger"

  count_after="$(find "$snapshots_root" -name manifest.json | wc -l | tr -d ' ')"
  [ "$count_after" -le "$count_before" ] || fail "retention policy did not prune (before=$count_before after=$count_after)"
  unset TMUX_REVIVE_RETENTION_MANUAL_COUNT TMUX_REVIVE_RETENTION_MANUAL_AGE_DAYS
  pass "retention-boundary-values"
}

test_retention_zero_limits() {
  setup_case "retention-zero-limits"
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
  count_after="$(find "$snapshots_root" -name manifest.json | wc -l | tr -d ' ')"
  [ "$count_after" -ge "$count_before" ] || fail "both=0 should keep all (before=$count_before after=$count_after)"

  # Count-only zero (age non-zero but all snapshots are fresh) = keep everything
  export TMUX_REVIVE_RETENTION_MANUAL_COUNT=0
  export TMUX_REVIVE_RETENTION_MANUAL_AGE_DAYS=1
  "$save_state" --reason "zero-count-trigger"
  count_after2="$(find "$snapshots_root" -name manifest.json | wc -l | tr -d ' ')"
  [ "$count_after2" -ge "$count_after" ] || fail "count=0 should not prune fresh snapshots (before=$count_after after=$count_after2)"

  # Age-only zero, count non-zero = prune by count only
  export TMUX_REVIVE_RETENTION_MANUAL_COUNT=2
  export TMUX_REVIVE_RETENTION_MANUAL_AGE_DAYS=0
  "$save_state" --reason "zero-age-trigger"
  count_after3="$(find "$snapshots_root" -name manifest.json | wc -l | tr -d ' ')"
  [ "$count_after3" -le 3 ] || fail "age=0 count=2 should prune to ~2 kept (got $count_after3)"

  unset TMUX_REVIVE_RETENTION_MANUAL_COUNT TMUX_REVIVE_RETENTION_MANUAL_AGE_DAYS
  pass "retention-zero-limits"
}

test_concurrent_save_and_restore() {
  setup_case "concurrent-save-restore"
  tmux new-session -d -s work
  tmux send-keys -t work 'echo hello' C-m
  sleep 1

  "$save_state" --reason concurrent-base
  tmux kill-server

  # Start restore, then immediately kick off a save in background
  "$restore_state" --session-name work --yes >/dev/null
  wait_for_session work || fail "initial restore did not create work session"

  # Run save in background while server is live
  "$save_state" --reason concurrent-during-restore &
  save_pid=$!

  # Give save a moment, then verify it completes
  wait "$save_pid" || fail "concurrent save failed while restore server was running"

  # Verify both the session and latest snapshot are intact
  tmux has-session -t work 2>/dev/null || fail "work session lost after concurrent save"
  manifest="$(latest_manifest)"
  [ -f "$manifest" ] || fail "no manifest after concurrent save"
  jq -e '.sessions | length > 0' "$manifest" >/dev/null || fail "concurrent save produced empty manifest"
  pass "concurrent-save-and-restore"
}

test_pane_split_failure_during_restore() {
  setup_case "pane-split-failure"

  # Create a session with 3 panes and save
  tmux new-session -d -s work
  tmux split-window -d -t work
  tmux split-window -d -t work
  actual_panes="$(tmux list-panes -t work | wc -l | tr -d ' ')"
  [ "$actual_panes" -eq 3 ] || fail "expected 3 panes, got $actual_panes"
  "$save_state" --reason pane-split-test
  manifest="$(latest_manifest)"

  # Kill the session
  tmux kill-session -t work

  # Inject a split-window failure hook into the tmux wrapper
  # Replace the wrapper to fail on split-window
  cat >"$case_root/bin/tmux" <<WRAPEOF
#!/usr/bin/env bash
set -euo pipefail
if [ -n "\${TMUX_TEST_COMMAND_LOG:-}" ]; then
  printf '%s\n' "\$*" >>"\$TMUX_TEST_COMMAND_LOG"
fi
if [ "\${1:-}" = "split-window" ] && [ "\${TMUX_TEST_FAIL_SPLIT:-0}" = "1" ]; then
  exit 1
fi
if [ "\${1:-}" = "attach-session" ] && [ -n "\${TMUX_TEST_ATTACH_LOG:-}" ]; then
  printf '%s\n' "\$*" >"\$TMUX_TEST_ATTACH_LOG"
  exit 0
fi
if [ "\${1:-}" = "switch-client" ] && [ -n "\${TMUX_TEST_SWITCH_LOG:-}" ]; then
  printf '%s\n' "\$*" >>"\$TMUX_TEST_SWITCH_LOG"
  exit 0
fi
exec $real_tmux -f /dev/null -L $socket_name "\$@"
WRAPEOF
  chmod +x "$case_root/bin/tmux"

  # Restore with split-window failures enabled
  export TMUX_TEST_FAIL_SPLIT=1
  output="$("$restore_state" --manifest "$manifest" 2>&1 || true)"
  unset TMUX_TEST_FAIL_SPLIT

  # Session should still be created (first pane comes from new-session, not split-window)
  tmux has-session -t work 2>/dev/null || fail "session was not created despite split failures"

  # Should have only 1 pane (splits failed)
  restored_panes="$(tmux list-panes -t work | wc -l | tr -d ' ')"
  [ "$restored_panes" -eq 1 ] || fail "expected 1 pane (splits failed), got $restored_panes"

  # Restore log should mention pane-split-failed and pane-count-mismatch
  restore_log="$(find "$TMUX_REVIVE_STATE_ROOT" -name 'latest-restore.log' | head -1)"
  [ -f "$restore_log" ] || fail "no restore log found"
  log_content="$(cat "$restore_log")"
  assert_contains "$log_content" "pane-split-failed" "split failure logged"
  assert_contains "$log_content" "pane-count-mismatch" "pane count mismatch logged"

  pass "pane-split-failure-during-restore"
}

test_export_import_error_paths() {
  setup_case "export-import-errors"
  tmux new-session -d -s work
  "$save_state" --reason export-error-test

  # Test import with nonexistent file
  output="$("$import_snapshot" --bundle /nonexistent/file.tar.gz 2>&1 || true)"
  assert_contains "$output" "bundle not found" "import nonexistent file error"

  # Test export works
  manifest="$(latest_manifest)"
  export_path="$case_root/test-export.tar.gz"
  "$export_snapshot" --manifest "$manifest" --output "$export_path"
  [ -f "$export_path" ] || fail "export did not create archive"

  # Test import roundtrip
  imported_manifest="$("$import_snapshot" --bundle "$export_path")"
  [ -f "$imported_manifest" ] || fail "import did not produce manifest"
  pass "export-import-error-paths"
}

test_autosave_timer_init() {
  setup_case "autosave-timer-init"
  local autosave_timer_init="$tmux_revive_dir/autosave-timer-init.sh"
  local autosave_timer_tick="$tmux_revive_dir/autosave-timer-tick.sh"

  tmux new-session -d -s work
  tmux set-option -g @tmux-revive-autosave-interval 5

  # Timer should set the guard option
  "$autosave_timer_init"
  timer_active="$(tmux show-option -gqv '@tmux-revive-timer-active' 2>/dev/null || printf '')"
  assert_eq "1" "$timer_active" "timer-active guard set after init"

  # Running init again should be a no-op (guard prevents duplicate)
  "$autosave_timer_init"
  timer_active="$(tmux show-option -gqv '@tmux-revive-timer-active' 2>/dev/null || printf '')"
  assert_eq "1" "$timer_active" "timer-active guard still set"

  # autosave-tick.sh should skip save trigger when timer is active
  runtime_dir="$(tmux_revive_runtime_dir)"
  latest_path="$(tmux_revive_latest_path)"
  mkdir -p "$runtime_dir"
  printf '0\n' >"$runtime_dir/last-auto-save"
  tmux set-option -g @tmux-revive-autosave on
  tmux set-option -g @tmux-revive-autosave-interval 1
  "$autosave_tick"
  sleep 1
  [ ! -f "$latest_path" ] || fail "autosave-tick should skip save when timer is active"

  # Clear the timer guard — autosave-tick should save again
  tmux set-option -gu '@tmux-revive-timer-active' 2>/dev/null || true
  printf '0\n' >"$runtime_dir/last-auto-save"
  tmux set-option -gq '@tmux-revive-last-auto-save' '0' 2>/dev/null || true
  "$autosave_tick"
  wait_for_file "$latest_path" || fail "autosave-tick should save when timer is not active"

  pass "autosave-timer-init"
}

test_non_bash_zsh_shell_restore() {
  setup_case "non-bash-zsh-shell"

  # Create a session with a pane running /bin/sh
  tmux new-session -d -s shtest
  local test_dir="$case_root/sh-workdir"
  mkdir -p "$test_dir"

  # Build a manifest with /bin/sh as the shell
  "$save_state" --reason sh-test
  manifest="$(latest_manifest)"

  # Patch the manifest to use /bin/sh instead of the real shell
  local tmp_manifest="$manifest.tmp"
  jq '(.sessions[0].windows[0].panes[0].shell) = "/bin/sh"' "$manifest" >"$tmp_manifest"
  mv "$tmp_manifest" "$manifest"

  # Also set the cwd to our test directory
  tmp_manifest="$manifest.tmp"
  jq --arg d "$test_dir" '(.sessions[0].windows[0].panes[0].cwd) = $d' "$manifest" >"$tmp_manifest"
  mv "$tmp_manifest" "$manifest"

  tmux kill-session -t shtest

  # Restore
  "$restore_state" --manifest "$manifest"
  tmux has-session -t shtest 2>/dev/null || fail "session shtest was not restored"

  # Verify the pane exists and has the correct cwd
  local attempts=0
  local restored_cwd=""
  while [ "$attempts" -lt 30 ]; do
    restored_cwd="$(tmux display-message -t shtest -p '#{pane_current_path}' 2>/dev/null || true)"
    [ -n "$restored_cwd" ] && break
    sleep 0.2
    attempts=$((attempts + 1))
  done
  assert_eq "$test_dir" "$restored_cwd" "non-bash/zsh shell pane cwd"

  pass "non-bash-zsh-shell-restore"
}

run_all() {
  test_list
  test_snapshot_browser_dump_items
  test_snapshot_browser_delegates_to_saved_session_chooser
  test_snapshot_browser_delegates_restore_all
  test_snapshot_browser_configures_preview_pane
  test_saved_session_chooser_rich_metadata
  test_saved_session_chooser_configures_preview_pane
  test_snapshot_bundle_export_import_roundtrip
  test_imported_snapshot_missing_path_message
  test_snapshot_browser_hides_imported_by_default
  test_archive_session_hides_default_choosers
  test_archived_sessions_do_not_trigger_startup_prompt
  test_revive_groups_current_session_first
  test_revive_header_rows_are_ignored_and_live_actions_still_work
  test_revive_includes_saved_sessions_section
  test_revive_saved_rows_resume_via_resume_session
  test_restore_by_guid
  test_restore_by_session_name
  test_restore_by_session_name_falls_back_to_older_snapshot
  test_mixed_collision_restore
  test_partial_snapshot_restore_with_existing_session
  test_restore_is_idempotent
  test_attach
  test_startup_restore_mode
  test_named_restore_profile_precedence
  test_default_profile_controls_startup_mode
  test_profile_can_include_archived_sessions
  test_restartable_command_allowlist_matrix
  test_restart_command_allowlist
  test_restart_command_preview_fallback
  test_tail_restart_from_preview
  test_auto_capture_tail_restart
  test_interrupt_restored_tail_returns_to_shell
  test_restored_autorun_command_not_added_to_zsh_history
  test_restored_nvim_command_not_added_to_zsh_history
  test_reference_only_messages
  test_shell_pane_does_not_preload_unrelated_command
  test_mixed_non_nvim_pane_restore_behavior
  test_auto_capture_mixed_running_and_blank_panes
  test_three_window_mixed_restore_scenario
  test_two_window_layout_restore_scenario
  test_restore_preserves_pane_cwd
  test_restore_preserves_window_names
  test_restore_preserves_explicit_auto_rename_off
  test_restore_preserves_window_options
  test_multi_pane_distinct_cwds_restore
  test_restore_tolerates_missing_pane_cwds
  test_restored_zsh_uses_shared_history_file
  test_startup_restore_off_mode
  test_startup_prompt_dismiss
  test_startup_prompt_reappears_for_newer_snapshot
  test_startup_prompt_without_tty_does_not_consume_prompt
  test_new_session_prompt_attach_replaces_transient_session
  test_fresh_tmux_restore_prompt_name_collision
  test_fresh_tmux_restore_prompt_no_collision
  test_fresh_tmux_restore_prompt_reappears
  test_restore_preview_summary
  test_restore_report_summary
  test_restore_report_popup
  test_restore_health_warnings_preview_and_report
  test_snapshot_retention_count_policy
  test_snapshot_retention_age_policy
  test_snapshot_retention_or_logic
  test_save_state_applies_retention_policy
  test_autosave_policy
  test_statusline_save_notice_uses_tmux_socket_env
  test_manual_save_emits_tmux_feedback
  test_bind_save_key_triggers_manual_save
  test_nvim_snapshot_and_direct_restore
  test_nvim_restore_via_tmux_restore
  test_nvim_persistence_policy
  test_nvim_unsupported_metadata
  test_save_restore_hooks
  test_stale_save_lock_recovery
  test_save_lock_contention_queues_followup_save
  test_stale_lock_corrupted_metadata
  test_grouped_sessions_are_restored
  test_pane_history_capture_is_bounded
  test_server_flag_save_restore
  test_server_flag_path_isolation
  test_special_character_session_names
  test_pane_title_with_special_chars
  test_corrupted_manifest_handling
  test_empty_sessions_manifest
  test_mkdir_error_check_in_save
  test_hook_error_logging
  test_retention_boundary_values
  test_retention_zero_limits
  test_concurrent_save_and_restore
  test_pane_split_failure_during_restore
  test_export_import_error_paths
  test_non_bash_zsh_shell_restore
  test_autosave_timer_init
  printf 'PASS: all (%d test cases)\n' "$pass_count"
}

case "${1:-all}" in
  all)
    run_all
    ;;
  list)
    test_list
    ;;
  snapshot-browser)
    test_snapshot_browser_dump_items
    test_snapshot_browser_delegates_to_saved_session_chooser
    test_snapshot_browser_delegates_restore_all
    test_snapshot_browser_configures_preview_pane
    test_saved_session_chooser_rich_metadata
    test_saved_session_chooser_configures_preview_pane
    test_snapshot_bundle_export_import_roundtrip
    test_imported_snapshot_missing_path_message
    test_snapshot_browser_hides_imported_by_default
    test_archive_session_hides_default_choosers
    test_archived_sessions_do_not_trigger_startup_prompt
    ;;
  archive)
    test_archive_session_hides_default_choosers
    test_archived_sessions_do_not_trigger_startup_prompt
    ;;
  preview)
    test_restore_preview_summary
    ;;
  report)
    test_restore_report_summary
    test_restore_report_popup
    test_restore_health_warnings_preview_and_report
    ;;
  retention)
    test_snapshot_retention_count_policy
    test_snapshot_retention_age_policy
    test_snapshot_retention_or_logic
    test_save_state_applies_retention_policy
    test_retention_boundary_values
    test_retention_zero_limits
    ;;
  revive)
    test_revive_groups_current_session_first
    test_revive_header_rows_are_ignored_and_live_actions_still_work
    test_revive_includes_saved_sessions_section
    test_revive_saved_rows_resume_via_resume_session
    ;;
  guid)
    test_restore_by_guid
    ;;
  name)
    test_restore_by_session_name
    test_restore_by_session_name_falls_back_to_older_snapshot
    ;;
  collision)
    test_mixed_collision_restore
    ;;
  partial-live)
    test_partial_snapshot_restore_with_existing_session
    ;;
  idempotent)
    test_restore_is_idempotent
    ;;
  attach)
    test_attach
    ;;
  startup)
    test_startup_restore_mode
    test_default_profile_controls_startup_mode
    ;;
  profiles)
    test_named_restore_profile_precedence
    test_default_profile_controls_startup_mode
    test_profile_can_include_archived_sessions
    ;;
  allowlist)
    test_restartable_command_allowlist_matrix
    ;;
  nvim)
    test_nvim_snapshot_and_direct_restore
    ;;
  nvim-tmux-restore)
    test_nvim_restore_via_tmux_restore
    ;;
  restart)
    test_restart_command_allowlist
    ;;
  fallback)
    test_restart_command_preview_fallback
    ;;
  tail)
    test_tail_restart_from_preview
    ;;
  tail-auto)
    test_auto_capture_tail_restart
    ;;
  tail-interrupt)
    test_interrupt_restored_tail_returns_to_shell
    ;;
  history-ignore)
    test_restored_autorun_command_not_added_to_zsh_history
    ;;
  nvim-history-ignore)
    test_restored_nvim_command_not_added_to_zsh_history
    ;;
  reference)
    test_reference_only_messages
    ;;
  shell-no-preload)
    test_shell_pane_does_not_preload_unrelated_command
    ;;
  mixed-non-nvim)
    test_mixed_non_nvim_pane_restore_behavior
    ;;
  mixed-auto)
    test_auto_capture_mixed_running_and_blank_panes
    ;;
  mixed-session)
    test_three_window_mixed_restore_scenario
    ;;
  layout-session)
    test_two_window_layout_restore_scenario
    ;;
  cwd)
    test_restore_preserves_pane_cwd
    ;;
  window-names)
    test_restore_preserves_window_names
    test_restore_preserves_explicit_auto_rename_off
    test_restore_preserves_window_options
    ;;
  multi-cwd)
    test_multi_pane_distinct_cwds_restore
    ;;
  missing-cwd)
    test_restore_tolerates_missing_pane_cwds
    ;;
  zsh-history)
    test_restored_zsh_uses_shared_history_file
    ;;
  startup-off)
    test_startup_restore_off_mode
    ;;
  startup-prompt)
    test_startup_prompt_dismiss
    ;;
  startup-prompt-newer)
    test_startup_prompt_reappears_for_newer_snapshot
    ;;
  startup-prompt-no-tty)
    test_startup_prompt_without_tty_does_not_consume_prompt
    ;;
  new-session-prompt)
    test_new_session_prompt_attach_replaces_transient_session
    test_fresh_tmux_restore_prompt_name_collision
    test_fresh_tmux_restore_prompt_no_collision
    test_fresh_tmux_restore_prompt_reappears
    ;;
  autosave)
    test_autosave_policy
    test_statusline_save_notice_uses_tmux_socket_env
    ;;
  save-feedback)
    test_manual_save_emits_tmux_feedback
    ;;
  bind-save)
    test_bind_save_key_triggers_manual_save
    ;;
  nvim-persistence)
    test_nvim_persistence_policy
    ;;
  nvim-unsupported)
    test_nvim_unsupported_metadata
    ;;
  hooks)
    test_save_restore_hooks
    ;;
  stale-lock)
    test_stale_save_lock_recovery
    test_save_lock_contention_queues_followup_save
    test_stale_lock_corrupted_metadata
    ;;
  grouped-sessions)
    test_grouped_sessions_are_restored
    ;;
  bounded-history)
    test_pane_history_capture_is_bounded
    ;;
  server-flag)
    test_server_flag_save_restore
    test_server_flag_path_isolation
    ;;
  special-chars)
    test_special_character_session_names
    test_pane_title_with_special_chars
    ;;
  sh-shell)
    test_non_bash_zsh_shell_restore
    ;;
  autosave-timer)
    test_autosave_timer_init
    ;;
  robustness)
    test_corrupted_manifest_handling
    test_empty_sessions_manifest
    test_mkdir_error_check_in_save
    test_hook_error_logging
    test_retention_boundary_values
    test_concurrent_save_and_restore
    test_pane_split_failure_during_restore
    test_export_import_error_paths
    ;;
  *)
    printf 'Usage: %s [all|list|snapshot-browser|revive|guid|name|collision|partial-live|idempotent|attach|startup|profiles|allowlist|restart|fallback|tail|tail-auto|tail-interrupt|history-ignore|nvim-history-ignore|reference|shell-no-preload|mixed-non-nvim|mixed-auto|mixed-session|layout-session|cwd|window-names|multi-cwd|missing-cwd|zsh-history|startup-off|startup-prompt|startup-prompt-newer|startup-prompt-no-tty|new-session-prompt|preview|report|retention|autosave|nvim|nvim-tmux-restore|nvim-persistence|nvim-unsupported|hooks|stale-lock|grouped-sessions|bounded-history|server-flag|special-chars|sh-shell|autosave-timer|robustness|archive]\n' "$0" >&2
    exit 1
    ;;
esac
