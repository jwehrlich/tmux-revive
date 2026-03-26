# Polling/wait helpers for bats tests.
# Usage: load test_helper/wait-helpers

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
