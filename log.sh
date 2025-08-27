#!/bin/bash

set -Eeuo pipefail

# -------- Config --------
LOG_LEVEL="INFO"          # TRACE|DEBUG|INFO|WARN|ERROR|FATAL
LOG_TS_FMT="+%Y-%m-%dT%H:%M:%S%z"
LOG_COLOR=1               # 1=enable colors when tty, 0=disable
LOG_TAG="${LOG_TAG:-${0##*/}}"

# Internal: dynamic file descriptor for logging (opened by log_init)
LOG_FD=""
LOG_FD_ALLOCATED=0        # 1 if we opened a new FD to a file or dup'd to 1/2

# -------- Utilities --------
_level_to_num() {
  case "${1^^}" in
    TRACE) echo 10 ;;
    DEBUG) echo 20 ;;
    INFO)  echo 30 ;;
    WARN)  echo 40 ;;
    ERROR) echo 50 ;;
    FATAL) echo 60 ;;
    *)     echo 30 ;;  # default INFO
  esac
}

_should_log() {
  local want have
  want=$(_level_to_num "$1")
  have=$(_level_to_num "$LOG_LEVEL")
  [[ "$want" -ge "$have" ]]
}

_color_open() {
  # Only color if enabled and sink is a TTY
  if [[ "${LOG_COLOR}" -eq 1 && -n "$LOG_FD" && -t "$LOG_FD" ]]; then
    case "${1^^}" in
      TRACE) printf '\033[2m' ;;        # dim
      DEBUG) printf '\033[36m' ;;       # cyan
      INFO)  printf '\033[32m' ;;       # green
      WARN|WARNING)  printf '\033[33m' ;;       # yellow
      ERROR) printf '\033[31m' ;;       # red
      FATAL) printf '\033[35m' ;;       # magenta
      *)     ;;
    esac
  fi
}
_color_close() {
  if [[ "${LOG_COLOR}" -eq 1 && -n "$LOG_FD" && -t "$LOG_FD" ]]; then
    printf '\033[0m'
  fi
}

# -------- Public API --------
# log_init --file /path/to/log     (default, uses custom FD, doesn't touch 1/2)
# log_init --stdout                (send logs to stdout)
# log_init --stderr                (send logs to stderr)
# Optional: log_set_level LEVEL    (at runtime)
log_init() {
  local mode="${1:---file}" target="${2:-/tmp/${LOG_TAG}.log}"

  # Close previous FD if any
  if [[ -n "$LOG_FD" && "$LOG_FD_ALLOCATED" -eq 1 ]]; then
    # shellcheck disable=SC2093
    exec {LOG_FD}>&-
    LOG_FD=""
    LOG_FD_ALLOCATED=0
  fi

  case "$mode" in
    --file)
      # Open a dedicated FD pointing to a file (append)
      # shellcheck disable=SC3020
      exec {LOG_FD}>>"$target"
      LOG_FD_ALLOCATED=1
      ;;
    --stdout)
      # Duplicate stdout into our own FD (won't interfere with other writes)
      # shellcheck disable=SC3020
      exec {LOG_FD}>&1
      LOG_FD_ALLOCATED=1
      ;;
    --stderr)
      # Duplicate stderr into our own FD
      # shellcheck disable=SC3020
      exec {LOG_FD}>&2
      LOG_FD_ALLOCATED=1
      ;;
    *)
      echo "log_init: unknown mode '$mode' (use --file, --stdout, or --stderr)" >&2
      return 2
      ;;
  esac
}

log_set_level() { LOG_LEVEL="${1^^}"; }
log_enable_color() { LOG_COLOR="${1}"; }

log() {
  local lvl="${1:-INFO}"; shift || true
  _should_log "$lvl" || return 0

  local ts msg src
  printf -v ts '%(%s)T' -1                         # epoch for monotonic-ish
  ts="$(date "$LOG_TS_FMT" -d "@$ts")"             # human timestamp
  src="${BASH_SOURCE[1]##*/}:${BASH_LINENO[0]}"    # caller location
  msg="$*"

  if [[ -z "$LOG_FD" ]]; then
    # Safety: if not initialized, default to stderr FD 2
    LOG_FD=2
  fi

  # Compose prefix: 2025-08-21T22:00:00+0200 LEVEL tag[pid] src:
  {
    _color_open "$lvl"
    printf '%s %-5s %s[%d] %s: %s\n' "$ts" "${lvl^^}" "$LOG_TAG" "$$" "$src" "$msg"
    _color_close
  } >&"$LOG_FD"
}

log_close() {
  if [[ -n "$LOG_FD" && "$LOG_FD_ALLOCATED" -eq 1 ]]; then
    # shellcheck disable=SC2093
    exec {LOG_FD}>&-
    LOG_FD=""
    LOG_FD_ALLOCATED=0
  fi
}

# Auto-close on exit
trap 'log_close' EXIT

# -------- Example (remove in production) --------
# Initialize to a dedicated file descriptor (default); won’t touch 1 or 2.
# log_init --file "/tmp/${LOG_TAG}.log"
# Or choose stdout/stderr instead:
# log_init --stdout
# log_init --stderr
# log_set_level INFO
# log INFO  "Service starting"
# log DEBUG "Debug details x=42"
# echo "normal stdout result"
# printf "normal error\n" >&2
# log WARN  "Low disk space"
# log ERROR "Failed to connect"


# # log_init --file "test.log"
# log_init --stdout
# log_set_level TRACE
# log_enable_color 0

# log TRACE "test trace"
# log DEBUG "test debug"
# log INFO "test info"
# log WARN "test warning"
# log ERROR "test error"
# log FATAL "test fatal"
