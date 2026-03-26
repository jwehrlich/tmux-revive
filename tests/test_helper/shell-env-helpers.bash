# Shell environment helpers for bats tests (zsh setup, env save/restore).
# Usage: load test_helper/shell-env-helpers

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
