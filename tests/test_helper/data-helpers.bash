# Data/manifest helpers for bats tests.
# Usage: load test_helper/data-helpers

latest_manifest() {
  jq -r '.manifest_path' "$(tmux_revive_latest_path)"
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
  # macOS: date -r EPOCH; Linux: date -d @EPOCH
  created_at="$(date -u -r "$epoch" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d "@$epoch" +%Y-%m-%dT%H:%M:%SZ)"
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

run_headless_nvim_script() {
  local script_path="$1"
  XDG_STATE_HOME="$XDG_STATE_HOME" \
  XDG_DATA_HOME="$XDG_DATA_HOME" \
  "$real_nvim" --headless -u NONE -i NONE \
    --cmd "lua package.path = package.path .. ';$repo_root/nvim/lua/?.lua;$repo_root/nvim/lua/?/init.lua'" \
    "+lua dofile([[$script_path]])" +qa!
}
