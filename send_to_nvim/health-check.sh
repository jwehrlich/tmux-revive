#!/usr/bin/env bash
#
# Watchdog for registered Neovim persistence servers.
#
# Detects and reaps nvim instances that have gone bad, before (or after) they
# balloon in memory. Two signals:
#
#   1. Responsiveness — pings each server's RPC socket. A server whose main loop
#      is wedged (e.g. parked at a hit-enter prompt) stops answering. Reaped only
#      after N *consecutive* failed checks, so a transiently busy nvim is safe.
#   2. Footprint ceiling — reaps immediately if memory exceeds a cap. Defaults
#      to 4096 MB: far above any healthy session, far below the multi-GB runaway
#      this guards against. Set the ceiling to 0 to disable. The responsiveness
#      check remains the primary, portable mechanism.
#
# Stale entries (dead pid) are swept too. Designed to be driven periodically
# (see autosave-tick.sh) and to never abort its caller.
#
# Config (env, matching the TMUX_MANAGE_* convention):
#   TMUX_MANAGE_NVIM_HEALTH_FAILS         consecutive bad pings before reaping (default 3)
#   TMUX_MANAGE_NVIM_HEALTH_PING_TIMEOUT  per-ping timeout, seconds (default 5)
#   TMUX_MANAGE_NVIM_FOOTPRINT_CEILING_MB reap above this footprint MB; 0=off (default 4096)
#   TMUX_MANAGE_NVIM_HEALTH_DIR           counter/log dir (default <registry>/.health)
#   TMUX_MANAGE_NVIM_HEALTH_LOG           log file (default <health dir>/health.log)
#   TMUX_MANAGE_NVIM_PING_CMD             override ping (tests): receives <server>
#   TMUX_MANAGE_NVIM_FOOTPRINT_CMD        override footprint (tests): receives <pid>, echoes MB
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
registry_root="${TMUX_SEND_TO_NVIM_STATE_DIR:-$HOME/.tmux/tmp/sessions/registry}"
[ -d "$registry_root" ] || exit 0

fails_threshold="${TMUX_MANAGE_NVIM_HEALTH_FAILS:-3}"
ping_timeout="${TMUX_MANAGE_NVIM_HEALTH_PING_TIMEOUT:-5}"
footprint_ceiling="${TMUX_MANAGE_NVIM_FOOTPRINT_CEILING_MB:-4096}"
health_dir="${TMUX_MANAGE_NVIM_HEALTH_DIR:-$registry_root/.health}"
log_file="${TMUX_MANAGE_NVIM_HEALTH_LOG:-$health_dir/health.log}"
case "$fails_threshold"   in ''|*[!0-9]*) fails_threshold=3 ;; esac
case "$ping_timeout"      in ''|*[!0-9]*) ping_timeout=5 ;; esac
case "$footprint_ceiling" in ''|*[!0-9]*) footprint_ceiling=4096 ;; esac

mkdir -p "$health_dir"

log_line() {
  printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >>"$log_file" 2>/dev/null || true
}

ping_server() {
  # 0 = responsive, non-zero = unresponsive/timed out
  local server="$1"
  if [ -n "${TMUX_MANAGE_NVIM_PING_CMD:-}" ]; then
    "$TMUX_MANAGE_NVIM_PING_CMD" "$server"
    return $?
  fi
  TMUX_SEND_TO_NVIM_PROBE_TICKS="$((ping_timeout * 10))" \
  TMUX_SEND_TO_NVIM_PROBE_INTERVAL_SEC="0.1" \
    "$script_dir/probe_nvim_server.sh" "$server"
}

footprint_mb() {
  local pid="$1"
  if [ -n "${TMUX_MANAGE_NVIM_FOOTPRINT_CMD:-}" ]; then
    "$TMUX_MANAGE_NVIM_FOOTPRINT_CMD" "$pid"
    return
  fi
  case "$(uname -s)" in
    Darwin)
      # Physical footprint includes compressed/swapped pages, which is where the
      # leak hid (RSS stayed tiny). Parse e.g. "Physical footprint: 11.7G".
      vmmap --summary "$pid" 2>/dev/null \
        | sed -n 's/.*Physical footprint: *\([0-9.]*\)\([KMG]\).*/\1 \2/p' | head -1 \
        | awk '{ if($2=="G") printf "%d",$1*1024; else if($2=="M") printf "%d",$1; else if($2=="K") printf "%d",$1/1024; else print 0 }'
      ;;
    Linux)
      awk '/^VmRSS:/{ printf "%d", $2/1024 }' "/proc/$pid/status" 2>/dev/null
      ;;
    *) printf '0' ;;
  esac
}

reap() {
  local pid="$1" entry="$2" reason="$3"
  log_line "reaping nvim pid=$pid ($reason) entry=$(basename "$entry")"
  kill -9 "$pid" 2>/dev/null || true
  rm -f "$entry" "$health_dir/$pid.fails"
}

while IFS= read -r entry; do
  [ -n "$entry" ] || continue
  server="$(jq -r '.server // ""' "$entry" 2>/dev/null || printf '')"
  pid="$(jq -r '.nvim_pid // ""' "$entry" 2>/dev/null || printf '')"
  case "$pid" in ''|*[!0-9]*) continue ;; esac

  # Sweep entries whose owning nvim is already gone.
  if ! kill -0 "$pid" 2>/dev/null; then
    rm -f "$entry" "$health_dir/$pid.fails"
    continue
  fi

  # Footprint backstop (opt-in).
  if [ "$footprint_ceiling" -gt 0 ]; then
    fp="$(footprint_mb "$pid" 2>/dev/null || printf '0')"
    case "$fp" in ''|*[!0-9]*) fp=0 ;; esac
    if [ "$fp" -ge "$footprint_ceiling" ]; then
      reap "$pid" "$entry" "footprint ${fp}MB >= ${footprint_ceiling}MB"
      continue
    fi
  fi

  # Responsiveness, with consecutive-failure hysteresis.
  [ -n "$server" ] || continue
  fails_file="$health_dir/$pid.fails"
  if ping_server "$server"; then
    rm -f "$fails_file"
  else
    n=0
    [ -f "$fails_file" ] && n="$(cat "$fails_file" 2>/dev/null || printf '0')"
    case "$n" in ''|*[!0-9]*) n=0 ;; esac
    n=$((n + 1))
    printf '%s\n' "$n" >"$fails_file"
    if [ "$n" -ge "$fails_threshold" ]; then
      reap "$pid" "$entry" "unresponsive x$n"
    else
      log_line "nvim pid=$pid unresponsive ($n/$fails_threshold)"
    fi
  fi
done < <(find "$registry_root" -type f -name '*.json' 2>/dev/null)

exit 0
