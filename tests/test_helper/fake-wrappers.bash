# Fake tmux/nvim/fzf wrapper generators for bats tests.
# Usage: load test_helper/fake-wrappers
#
# Expects $case_root, $real_tmux, $real_nvim, $socket_name to be set
# (provided by _setup_case in common-setup.bash).

_create_tmux_wrapper() {
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
}

_create_nvim_wrapper() {
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
      first_tab_paths: ((.tabs[0].wins // []) | map(.path)),
      first_tab_a_line: ([.tabs[0].wins[] | select(.path | endswith("file-a.txt")) | .cursor[0]] | first // null),
      first_tab_b_line: ([.tabs[0].wins[] | select(.path | endswith("file-b.txt")) | .cursor[0]] | first // null),
      first_tab_layout_kind: (.tabs[0].layout.kind // ""),
      first_tab_win_count: ((.tabs[0].wins // []) | length)
    }' "\$TMUX_NVIM_RESTORE_STATE" >"\$restore_log"
  exit 0
fi
exec "$real_nvim" "\$@"
EOF
  chmod +x "$case_root/bin/nvim"
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

setup_fake_fzf_auto_first() {
  # Create a fake fzf that auto-selects the first item with the given key.
  # Usage: setup_fake_fzf_auto_first "enter"   # select first and press enter
  #        setup_fake_fzf_auto_first "ctrl-a"   # select first and press ctrl-a
  #        setup_fake_fzf_auto_first ""          # dismiss (exit 1)
  local key="${1:-}"
  cat >"$case_root/bin/fzf" <<'FZFEOF'
#!/usr/bin/env bash
set -euo pipefail
key="$1"
shift
# Drain all args
while [ $# -gt 0 ]; do shift; done
if [ -n "${TMUX_TEST_FZF_ARGS_LOG:-}" ]; then
  printf '%s\n' "$*" >>"$TMUX_TEST_FZF_ARGS_LOG"
fi
# Read all items from stdin
items=""
while IFS= read -r line; do
  items="${items}${line}
"
done
if [ -z "$key" ]; then
  exit 1
fi
first_item="$(printf '%s' "$items" | head -n 1)"
printf '\n%s\n%s\n' "$key" "$first_item"
FZFEOF
  # Inject the key as $1
  cat >"$case_root/bin/fzf" <<FZFEOF
#!/usr/bin/env bash
set -euo pipefail
if [ -n "\${TMUX_TEST_FZF_ARGS_LOG:-}" ]; then
  printf '%s\n' "\$*" >>"\$TMUX_TEST_FZF_ARGS_LOG"
fi
items=""
while IFS= read -r line || [ -n "\$line" ]; do
  items="\${items}\${line}
"
done
key="$key"
if [ -z "\$key" ]; then
  exit 1
fi
first_item="\$(printf '%s' "\$items" | head -n 1)"
printf '\n%s\n%s\n' "\$key" "\$first_item"
FZFEOF
  chmod +x "$case_root/bin/fzf"
}

setup_fake_fzf_select_saved() {
  # Create a fake fzf that selects a saved row matching a session name.
  # Usage: setup_fake_fzf_select_saved "my-session"  # select saved row for "my-session" and press enter
  local target_session="$1"
  local key="${2:-enter}"
  cat >"$case_root/bin/fzf" <<FZFEOF
#!/usr/bin/env bash
set -euo pipefail
if [ -n "\${TMUX_TEST_FZF_ARGS_LOG:-}" ]; then
  printf '%s\n' "\$*" >>"\$TMUX_TEST_FZF_ARGS_LOG"
fi
items=""
while IFS= read -r line || [ -n "\$line" ]; do
  items="\${items}\${line}
"
done
# Find saved row matching session name (field 4 in TSV)
match="\$(printf '%s' "\$items" | awk -F '\t' '\$1 == "saved" && \$4 == "$target_session" { print; exit }')"
if [ -z "\$match" ]; then
  exit 1
fi
printf '\n%s\n%s\n' "$key" "\$match"
FZFEOF
  chmod +x "$case_root/bin/fzf"
}

setup_server_flag_wrapper() {
  # Overwrite the tmux wrapper with one that is aware of -L flags from
  # production scripts. When scripts call `command tmux -L <name> ...`,
  # this wrapper detects -L and does NOT add its own. Direct tmux calls
  # from test code (without -L) still get -L injected.
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
