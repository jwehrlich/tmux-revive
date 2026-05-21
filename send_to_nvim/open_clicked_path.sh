#!/usr/bin/env sh
# open_clicked_path.sh — Handle ctrl+click in tmux to open files in Neovim.
# Called from .tmux.conf via run-shell -b.
set -eu

src_pane="${1:-}"
mouse_x="${2:-}"
mouse_y="${3:-}"
client_tty="${4:-}"

[ -n "$src_pane" ] || exit 1
[ -n "$mouse_x" ] || exit 1
[ -n "$mouse_y" ] || exit 1
[ -n "$client_tty" ] || exit 1

script_dir="$(CDPATH= cd -- "$(dirname "$0")" && pwd)"
registry_root="${TMUX_SEND_TO_NVIM_STATE_DIR:-$HOME/.tmux/tmp/sessions/registry}"

# Batch tmux metadata into a single query (3 commands → 1)
_tmux_meta="$(tmux display-message -p -t "$src_pane" '#{session_id}	#{window_id}	#{pane_current_path}')"
session_id="${_tmux_meta%%	*}"; _tmux_meta="${_tmux_meta#*	}"
src_window="${_tmux_meta%%	*}"
src_cwd="${_tmux_meta#*	}"
session_dir="$registry_root/$session_id"

# ── Status feedback (non-modal, bottom of screen) ───────────────────────────

_spinner_pid=""

start_spinner() {
  _smsg="${1:-Opening in nvim}"
  (
    while true; do
      for _c in '⠋' '⠙' '⠹' '⠸' '⠼' '⠴' '⠦' '⠧' '⠇' '⠏'; do
        tmux display-message -c "$client_tty" -d 2000 " $_c $_smsg"
        sleep 0.15
      done
    done
  ) &
  _spinner_pid=$!
}

stop_spinner() {
  if [ -n "${_spinner_pid:-}" ]; then
    kill "$_spinner_pid" 2>/dev/null || true
    wait "$_spinner_pid" 2>/dev/null || true
    _spinner_pid=""
  fi
}

status_ok() {
  stop_spinner
  tmux display-message -c "$client_tty" -d 1500 " ✓ $1"
}

status_err() {
  stop_spinner
  tmux display-message -c "$client_tty" -d 4000 " ✗ $1"
}

cleanup() {
  stop_spinner
  rm -f "${candidate_stderr:-}"
}
trap cleanup EXIT INT TERM

# ── Resolve clicked path (single Perl process) ──────────────────────────────

start_spinner "Opening file in nvim…"

repo_root="$(git -C "$src_cwd" rev-parse --show-toplevel 2>/dev/null || true)"

# Capture raw view for the clicked line and joined view for context.
raw_line="$(tmux capture-pane -p -t "$src_pane" -S "$mouse_y" -E "$mouse_y")"
joined_view="$(tmux capture-pane -pJ -t "$src_pane")"

[ -n "$raw_line" ] || {
  status_err "No file path at click location"
  exit 0
}

# find_candidates.pl replaces 3+ Perl processes with 1:
#   pick_raw_fragment + extract_paths.sh + parse_target + resolve_path
# Output: absolute_path\tline\tcol  (tab-separated, one per candidate)
candidate_output=""
candidate_status=0
candidate_stderr="$(mktemp /tmp/send_to_nvim.stderr.XXXXXX)"

candidate_output="$(
  printf '%s\n' "$joined_view" \
    | perl "$script_dir/find_candidates.pl" "$raw_line" "$mouse_x" "$src_cwd" "$repo_root" \
    2>"$candidate_stderr"
)" || candidate_status=$?

case "$candidate_status" in
  1)
    status_err "No file path at click location"
    exit 0
    ;;
  2)
    not_found_path=""
    if [ -s "$candidate_stderr" ]; then
      not_found_path="$(cut -f2 "$candidate_stderr")"
    fi
    status_err "File not found: ${not_found_path:-unknown}"
    exit 0
    ;;
esac

candidate_count="$(printf '%s\n' "$candidate_output" | grep -c '.' || true)"

if [ "$candidate_count" -eq 0 ]; then
  status_err "No file path at click location"
  exit 0
fi

if [ "$candidate_count" -gt 1 ]; then
  status_err "Ambiguous file target at click location"
  exit 0
fi

# Parse the single candidate (IFS read — no subprocess)
IFS="$(printf '\t')" read -r absolute_target line_target col_target <<EOF
$candidate_output
EOF

# ── Find and dispatch to Neovim ──────────────────────────────────────────────

[ -d "$session_dir" ] || {
  status_err "No nvim session found"
  exit 0
}

# Build sorted registry for this tmux window in a single pass with Perl
# (replaces jq+awk per file + sort).
registry_data="$(
  perl -MJSON::PP -e '
    my $src_window = shift @ARGV;
    my @entries;
    for my $file (@ARGV) {
      open my $fh, "<", $file or next;
      my $json = do { local $/; <$fh> };
      close $fh;
      my $d = eval { decode_json($json) } or next;
      next unless ($d->{window_id} // "") eq $src_window;
      push @entries, join("\t",
        $d->{last_active_epoch} // 0,
        $d->{pane_id}  // "",
        $d->{window_id} // "",
        $d->{server}   // "",
        $file
      );
    }
    # Sort by epoch descending
    print join("\n", sort { (split /\t/, $b)[0] <=> (split /\t/, $a)[0] } @entries), "\n"
      if @entries;
  ' "$src_window" "$session_dir"/*.json 2>/dev/null
)" || true

[ -n "$registry_data" ] || {
  status_err "No nvim session found in current window"
  exit 0
}

# Build JSON payload without jq (simple key-value, safe for known numeric/path inputs)
_build_payload() {
  _bp_path="$1" _bp_line="$2" _bp_col="$3"
  _bp_escaped="$(printf '%s' "$_bp_path" | sed 's/\\/\\\\/g; s/"/\\"/g')"
  _bp_line_val="null"; [ -z "$_bp_line" ] || _bp_line_val="$_bp_line"
  _bp_col_val="null";  [ -z "$_bp_col" ]  || _bp_col_val="$_bp_col"
  printf '{"path":"%s","line":%s,"col":%s}' "$_bp_escaped" "$_bp_line_val" "$_bp_col_val"
}

_target_basename="$(basename -- "$absolute_target")"

while IFS="$(printf '\t')" read -r _last_active target_pane target_window target_server entry_path; do
  [ -n "$target_pane" ] || continue
  [ "$target_window" = "$src_window" ] || continue

  # Check pane exists
  tmux display-message -p -t "$target_pane" '#{pane_id}' >/dev/null 2>&1 || {
    rm -f "$entry_path"
    continue
  }

  # Probe nvim server (inline — avoids separate script + Perl sleep loop)
  nvim --server "$target_server" --remote-expr '1' >/dev/null 2>&1 || {
    rm -f "$entry_path"
    continue
  }

  # Dispatch to nvim
  case "$absolute_target" in /*) ;; *) continue ;; esac
  [ -f "$absolute_target" ] || continue

  payload="$(_build_payload "$absolute_target" "$line_target" "$col_target")"

  nvim --server "$target_server" --remote-send \
    "<C-\\><C-N>:lua require('core.send_to_nvim').remote_open(vim.json.decode([==[$payload]==]))<CR>" \
    >/dev/null 2>&1 || {
    rm -f "$entry_path"
    continue
  }

  # Switch to the nvim pane if not already there
  current_pane="$(tmux display-message -p -c "$client_tty" '#{pane_id}' 2>/dev/null || true)"
  if [ "$current_pane" != "$target_pane" ]; then
    tmux switch-client -c "$client_tty" -t "$target_pane"
  fi

  status_ok "Opened $_target_basename"
  status_ok "Opened $_target_basename"
  exit 0
done <<EOF
$registry_data
EOF

status_err "No nvim session found"
