#!/usr/bin/env bash
# lock_utils.sh - Acquire/release read/write locks visible via lslocks

# Acquire a lock
# Arguments:
#   $1 - lock file path
#   $2 - mode: read | write
# Sets: LOCKFD variable to file descriptor number
lock_acquire() {
  local lockfile="$1"
  local mode="$2"

  # Open an anonymous file descriptor for lock
  exec {LOCKFD}>"$lockfile" || return 1

  # Acquire shared or exclusive lock
  if [[ "$mode" == "read" ]]; then
    flock -s "$LOCKFD" || return 1
  elif [[ "$mode" == "write" ]]; then
    flock -x "$LOCKFD" || return 1
  else
    echo "lock_acquire: invalid mode '$mode'" >&2
    exec {LOCKFD}>&-; unset LOCKFD
    return 2
  fi

  return 0
}

# Release a previously acquired lock
# Closes the FD and unsets LOCKFD
lock_release() {
  if [[ -n "${LOCKFD:-}" ]]; then
    exec {LOCKFD}>&- || return 1
    unset LOCKFD
    return 0
  else
    echo "lock_release: no lock to release" >&2
    return 2
  fi
}
