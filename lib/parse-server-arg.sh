#!/usr/bin/env bash
# Pre-parse --server argument from "$@" before sourcing state-common.sh.
# Must be sourced, not executed. Usage:
#   source "$script_dir/lib/parse-server-arg.sh"
#   source "$script_dir/lib/state-common.sh"
for __arg in "$@"; do
  if [ "$__arg" = "--server" ]; then __found_server=1; continue; fi
  if [ "${__found_server:-0}" = "1" ]; then export TMUX_REVIVE_TMUX_SERVER="$__arg"; break; fi
done
unset __arg __found_server
