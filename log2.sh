#!/usr/bin/env bash
set -Eeuo pipefail

# -------- Config --------
LOG_LEVEL="INFO"          # TRACE|DEBUG|INFO|WARN|ERROR|FATAL
LOG_TS_FMT="+%Y-%m-%dT%H:%M:%S%z"
LOG_COLOR=1
LOG_TAG="${LOG_TAG:-${0##*/}}"

# Internals
LOG_FD=""                 # target FD when not splitting
LOG_FD_ALLOCATED=0        # 1 if we opened/dup'd an FD
LOG_SPLIT_CONSOLE=0       # TRACE..WARN->1, ERROR..FATAL->2

_level_to_num(){ case "${1^^}" in TRACE)echo 10;;DEBUG)echo 20;;INFO)echo 30;;WARN|WARNING)echo 40;;ERROR)echo 50;;FATAL)echo 60;;*)echo 30;; esac; }
_should_log(){ local want=$(_level_to_num "$1") have=$(_level_to_num "$LOG_LEVEL"); [[ $want -ge $have ]]; }

_color_open(){ # $1=level, $2=fd
  if [[ "$LOG_COLOR" -eq 1 && -t "$2" ]]; then
    case "${1^^}" in TRACE)printf '\033[2m';;DEBUG)printf '\033[36m';;INFO)printf '\033[32m';;WARN|WARNING)printf '\033[33m';;ERROR)printf '\033[31m';;FATAL)printf '\033[35m';; esac
  fi
}
_color_close(){ [[ "$LOG_COLOR" -eq 1 && -t "$1" ]] && printf '\033[0m'; }


_log_close_allocated() {
  if [[ "$LOG_FD_ALLOCATED" -eq 1 && -n "$LOG_FD" ]]; then
    if [[ "$LOG_FD_DYNAMIC" -eq 1 ]]; then
      exec {LOG_FD}>&-        # only valid for dynamic-FD allocations
    else
      eval "exec ${LOG_FD}>&-"  # required for exact numeric FD (e.g., 9)
    fi
  fi
  LOG_FD="" LOG_FD_ALLOCATED=0 LOG_FD_DYNAMIC=0
}


# log_init [--file PATH] [--stdout] [--stderr]
#         [--fd N PATH]        # <-- opens/initializes FD N to PATH (append)
#         [--fd-use N]         # reuse an already-open FD
#         [--console-split] [--level LEVEL] [--color 0|1]
log_init() {
  local mode="--file" file_target="/tmp/${LOG_TAG}.log"
  local want_fd="" want_fd_use="" want_level="" want_color=""

  # close previous
  if [[ -n "$LOG_FD" && "$LOG_FD_ALLOCATED" -eq 1 ]]; then
    _log_close_allocated
  fi

  # parse
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --file)          mode="--file"; shift; [[ $# -gt 0 && "${1:0:2}" != "--" ]] && file_target="$1" && shift ;;
      --stdout)        mode="--stdout"; shift ;;
      --stderr)        mode="--stderr"; shift ;;
      --fd)            mode="--fd"; shift; want_fd="${1:-}"; [[ -z "$want_fd" ]] && { echo "log_init: --fd needs <N> <PATH>" >&2; return 2; }; shift
                        [[ $# -gt 0 && "${1:0:2}" != "--" ]] || { echo "log_init: --fd needs <N> <PATH>" >&2; return 2; }
                        file_target="$1"; shift ;;
      --fd-use)        mode="--fd-use"; shift; want_fd_use="${1:-}"; [[ -z "$want_fd_use" ]] && { echo "log_init: --fd-use needs <N>" >&2; return 2; }; shift ;;
      --console-split) LOG_SPLIT_CONSOLE=1; mode="--console-split"; shift ;;
      --level)         shift; want_level="${1:-}"; [[ -z "$want_level" ]] && { echo "log_init: --level needs a value" >&2; return 2; }; shift ;;
      --color)         shift; want_color="${1:-}"; [[ -z "$want_color" ]] && { echo "log_init: --color needs 0 or 1" >&2; return 2; }; shift ;;
      *) echo "log_init: unknown arg '$1'" >&2; return 2 ;;
    esac
  done

  [[ -n "$want_level" ]] && LOG_LEVEL="${want_level^^}"
  [[ -n "$want_color" ]] && LOG_COLOR="$want_color"

  case "$mode" in
  --stdout)
    exec {LOG_FD}>&1; LOG_FD_ALLOCATED=1; LOG_FD_DYNAMIC=1 ;;
  --stderr)
    exec {LOG_FD}>&2; LOG_FD_ALLOCATED=1; LOG_FD_DYNAMIC=1 ;;
  --fd-use)  # reuse already-open FD N
    exec {LOG_FD}>&"$want_fd_use"; LOG_FD_ALLOCATED=1; LOG_FD_DYNAMIC=1 ;;
  --fd)      # open exact FD N to PATH (append)
    [[ "$want_fd" =~ ^[0-9]+$ ]] || { echo "log_init: FD must be a number" >&2; return 2; }
    [[ "$want_fd" -eq 0 || "$want_fd" -eq 1 || "$want_fd" -eq 2 ]] && \
      echo "log_init: warning: opening FD $want_fd will (re)wire stdio" >&2
    eval "exec ${want_fd}>>\"$file_target\""
    LOG_FD="$want_fd"; LOG_FD_ALLOCATED=1; LOG_FD_DYNAMIC=0 ;;
  --file|*)
    exec {LOG_FD}>>"$file_target"; LOG_FD_ALLOCATED=1; LOG_FD_DYNAMIC=1 ;;
esac
}

log_set_level()    { LOG_LEVEL="${1^^}"; }
log_enable_color() { LOG_COLOR="${1}";   }

log() {
  local lvl="${1:-INFO}"; shift || true
  _should_log "$lvl" || return 0

  local ts src msg target_fd
  printf -v ts '%(%s)T' -1
  ts="$(date "$LOG_TS_FMT" -d "@$ts")"
  src="${BASH_SOURCE[1]##*/}:${BASH_LINENO[0]}"
  msg="$*"

  if [[ "$LOG_SPLIT_CONSOLE" -eq 1 ]]; then
    if [[ $(_level_to_num "$lvl") -ge $(_level_to_num "ERROR") ]]; then target_fd=2; else target_fd=1; fi
  else
    target_fd="${LOG_FD:-2}"
  fi

  { _color_open "$lvl" "$target_fd"
    printf '%s %-5s %s[%d] %s: %s\n' "$ts" "${lvl^^}" "$LOG_TAG" "$$" "$src" "$msg"
    _color_close "$target_fd"
  } >&"$target_fd"
}

log_close() {
  if [[ -n "$LOG_FD" && "$LOG_FD_ALLOCATED" -eq 1 ]]; then
    # shellcheck disable=SC2093
    exec {LOG_FD}>&- || true
    LOG_FD="" LOG_FD_ALLOCATED=0
  fi
}




trap '_log_close_allocated' EXIT



log_init --fd 9 my1.log --level DEBUG --color 0

log info "etst"