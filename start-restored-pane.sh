#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/parse-server-arg.sh
source "$script_dir/lib/parse-server-arg.sh"
# shellcheck source=lib/state-common.sh
source "$script_dir/lib/state-common.sh"

mode="shell"
cwd="${HOME}"
shell_bin="${SHELL:-/bin/sh}"
transcript_path=""
command_to_run=""
filter_line=""
extra_envs=()

build_env_exec_prefix() {
  env_exec_prefix=(env)
  if [ "${#extra_envs[@]}" -gt 0 ]; then
    env_exec_prefix+=("${extra_envs[@]}")
  fi
}

while [ $# -gt 0 ]; do
  case "$1" in
    --mode)
      mode="${2:-shell}"
      shift 2
      ;;
    --cwd)
      cwd="${2:-$HOME}"
      shift 2
      ;;
    --shell)
      shell_bin="${2:-$shell_bin}"
      shift 2
      ;;
    --transcript)
      transcript_path="${2:-}"
      shift 2
      ;;
    --command)
      command_to_run="${2:-}"
      shift 2
      ;;
    --filter-line)
      filter_line="${2:-}"
      shift 2
      ;;
    --env)
      extra_envs+=("${2:-}")
      shift 2
      ;;
    *)
      printf 'Unknown argument: %s\n' "$1" >&2
      exit 1
      ;;
  esac
done

print_transcript() {
  [ -n "$transcript_path" ] || return 0
  if [ ! -f "$transcript_path" ]; then
    printf '\n%s\n%s\n' "We could not load the transcript during restore:" "$transcript_path"
    return 0
  fi

  if [ -n "$filter_line" ]; then
    awk -v skip="$filter_line" '$0 != skip { print }' "$transcript_path"
  else
    cat "$transcript_path"
  fi
}

if [ ! -x "$shell_bin" ]; then
  printf 'start-restored-pane: shell not found or not executable: %s (falling back to %s)\n' "$shell_bin" "$SHELL" >&2
  shell_bin="$SHELL"
fi

shell_name="$(tmux_revive_shell_name "$shell_bin")"
tmp_dir=""
env_exec_prefix=()

cleanup() {
  if [ -n "$tmp_dir" ] && [ -d "$tmp_dir" ]; then
    rm -rf "$tmp_dir" >/dev/null 2>&1 || true
  fi
}

apply_extra_envs() {
  local assignment key value
  if [ "${#extra_envs[@]}" -eq 0 ]; then
    return 0
  fi
  for assignment in "${extra_envs[@]}"; do
    key="${assignment%%=*}"
    value="${assignment#*=}"
    export "$key=$value"
  done
}

make_wrapper_dir() {
  local prefix="$1"
  tmp_dir="$(mktemp -d "${TMPDIR:-/tmp}/${prefix}.XXXXXX")" || {
    printf 'tmux-revive: failed to create temp directory\n' >&2
    exit 1
  }
}

wrapper_transcript_snippet() {
  cat <<'EOF'
if [ -n "${TMUX_REVIVE_RESTORE_TRANSCRIPT:-}" ]; then
  if [ -f "${TMUX_REVIVE_RESTORE_TRANSCRIPT}" ]; then
    printf '%s\n' '--- tmux-restore transcript begin ---'
    printf 'source: %s\n' "$TMUX_REVIVE_RESTORE_TRANSCRIPT"
    if [ -n "${TMUX_REVIVE_RESTORE_FILTER_LINE:-}" ]; then
      awk -v skip="$TMUX_REVIVE_RESTORE_FILTER_LINE" '$0 != skip { print }' "$TMUX_REVIVE_RESTORE_TRANSCRIPT"
    else
      cat "$TMUX_REVIVE_RESTORE_TRANSCRIPT"
    fi
    printf '%s\n' '--- tmux-restore transcript end ---'
  else
    printf '\n%s\n%s\n' "We could not load the transcript during restore:" "$TMUX_REVIVE_RESTORE_TRANSCRIPT"
  fi
fi
EOF
}

write_shell_wrapper() {
  local wrapper_path="$1"
  local real_rc_path="$2"
  local histfile_path="$3"
  local history_load_snippet="$4"
  local command_restore_snippet="$5"
  local real_rc_quoted histfile_quoted cwd_quoted

  real_rc_quoted="$(printf '%q' "$real_rc_path")"
  histfile_quoted="$(printf '%q' "$histfile_path")"
  cwd_quoted="$(printf '%q' "$cwd")"

  local tmp_dir_quoted
  tmp_dir_quoted="$(printf '%q' "$tmp_dir")"
  cat >"$wrapper_path" <<EOF
if [ -f $real_rc_quoted ]; then
  source $real_rc_quoted
fi
export HISTFILE=$histfile_quoted
$history_load_snippet
cd -- $cwd_quoted 2>/dev/null || printf 'tmux-revive: saved directory not found, using fallback: %s\n' $cwd_quoted >&2
$(wrapper_transcript_snippet)
$command_restore_snippet
# Clean up wrapper tmp dir now that it has been sourced
rm -rf $tmp_dir_quoted >/dev/null 2>&1 || true
EOF
}

make_zsh_wrapper() {
  local real_zdotdir="${ZDOTDIR:-$HOME}"
  local history_load_snippet command_restore_snippet histfile_path
  histfile_path="$(tmux_revive_shell_history_file "$shell_bin")"
  history_load_snippet='if [ -f "$HISTFILE" ]; then
  builtin fc -R "$HISTFILE" 2>/dev/null || true
fi'
  command_restore_snippet='if [ -n "${TMUX_REVIVE_RESTORE_COMMAND:-}" ]; then
  setopt hist_ignore_space 2>/dev/null || true
  tmux_revive_queue_restore_command() {
    emulate -L zsh
    local restore_command=" $TMUX_REVIVE_RESTORE_COMMAND"
    unset TMUX_REVIVE_RESTORE_COMMAND
    autoload -Uz add-zle-hook-widget 2>/dev/null || return 0
    tmux_revive_inject_restore_command() {
      zle -U "$restore_command"$'\''\n'\''
      add-zle-hook-widget -d line-init tmux_revive_inject_restore_command 2>/dev/null || true
      unfunction tmux_revive_inject_restore_command 2>/dev/null || true
    }
    add-zle-hook-widget line-init tmux_revive_inject_restore_command 2>/dev/null || true
  }
  tmux_revive_queue_restore_command || true
  unfunction tmux_revive_queue_restore_command 2>/dev/null || true
fi'
  make_wrapper_dir "tmux-revive-zsh"
  write_shell_wrapper "$tmp_dir/.zshrc" "$real_zdotdir/.zshrc" "$histfile_path" "$history_load_snippet" "$command_restore_snippet"
}

make_bash_wrapper() {
  local history_load_snippet command_restore_snippet histfile_path
  histfile_path="$(tmux_revive_shell_history_file "$shell_bin")"
  history_load_snippet='if [ -f "$HISTFILE" ]; then
  history -r "$HISTFILE" 2>/dev/null || true
fi
export HISTCONTROL="${HISTCONTROL:+${HISTCONTROL}:}ignorespace"'
  command_restore_snippet='if [ -n "${TMUX_REVIVE_RESTORE_COMMAND:-}" ]; then
  set +o history 2>/dev/null || true
  eval " $TMUX_REVIVE_RESTORE_COMMAND"
  set -o history 2>/dev/null || true
  unset TMUX_REVIVE_RESTORE_COMMAND
fi'
  local bash_rc="$HOME/.bashrc"
  if [ ! -f "$bash_rc" ] && [ -f "$HOME/.bash_profile" ]; then
    bash_rc="$HOME/.bash_profile"
  fi
  make_wrapper_dir "tmux-revive-bash"
  write_shell_wrapper "$tmp_dir/bashrc" "$bash_rc" "$histfile_path" "$history_load_snippet" "$command_restore_snippet"
}

run_shell() {
  build_env_exec_prefix
  case "$shell_name" in
    zsh)
      make_zsh_wrapper
      exec "${env_exec_prefix[@]}" ZDOTDIR="$tmp_dir" SHELL="$shell_bin" TMUX_REVIVE_RESTORE_TRANSCRIPT="$transcript_path" TMUX_REVIVE_RESTORE_FILTER_LINE="$filter_line" "$shell_bin" -i
      ;;
    bash)
      make_bash_wrapper
      exec "${env_exec_prefix[@]}" TMUX_REVIVE_RESTORE_TRANSCRIPT="$transcript_path" TMUX_REVIVE_RESTORE_FILTER_LINE="$filter_line" "$shell_bin" --rcfile "$tmp_dir/bashrc" -i
      ;;
    *)
      cd -- "$cwd" 2>/dev/null || printf 'tmux-revive: saved directory not found, using fallback: %s\n' "$cwd" >&2
      print_transcript
      exec "${env_exec_prefix[@]}" "$shell_bin" -i
      ;;
  esac
}

run_command() {
  trap ':' INT
  apply_extra_envs
  build_env_exec_prefix
  cd -- "$cwd" 2>/dev/null || printf 'tmux-revive: saved directory not found, using fallback: %s\n' "$cwd" >&2
  print_transcript
  case "$shell_name" in
    zsh)
      make_zsh_wrapper
      eval "$command_to_run" || true
      trap - INT
      exec "${env_exec_prefix[@]}" ZDOTDIR="$tmp_dir" SHELL="$shell_bin" "$shell_bin" -i
      ;;
    bash)
      make_bash_wrapper
      eval "$command_to_run" || true
      trap - INT
      exec "${env_exec_prefix[@]}" "$shell_bin" --rcfile "$tmp_dir/bashrc" -i
      ;;
    *)
      eval "$command_to_run" || true
      trap - INT
      exec "$shell_bin" -i
      ;;
  esac
}

trap cleanup EXIT

if ! tmux_revive_shell_supports_wrapper "$shell_bin"; then
  print_transcript
fi

case "$mode" in
  shell)
    run_shell
    ;;
  run)
    [ -n "$command_to_run" ] || run_shell
    run_command
    ;;
  *)
    printf 'Unknown mode: %s\n' "$mode" >&2
    exit 1
    ;;
esac
