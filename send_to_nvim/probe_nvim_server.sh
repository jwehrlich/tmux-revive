#!/usr/bin/env sh
set -eu

server="${1:-}"
[ -n "$server" ] || exit 1

ticks="${TMUX_SEND_TO_NVIM_PROBE_TICKS:-5}"
interval="${TMUX_SEND_TO_NVIM_PROBE_INTERVAL_SEC:-0.05}"

nvim --server "$server" --remote-expr '1' >/dev/null 2>&1 &
probe_pid=$!

tick=0
while [ "$tick" -lt "$ticks" ]; do
  if ! kill -0 "$probe_pid" 2>/dev/null; then
    wait "$probe_pid"
    exit $?
  fi

  perl -e 'select undef, undef, undef, shift' "$interval"
  tick=$((tick + 1))
done

kill "$probe_pid" 2>/dev/null || true
wait "$probe_pid" 2>/dev/null || true
exit 1
