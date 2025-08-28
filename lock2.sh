#!/usr/bin/env bash
# lock_utils.sh — Acquire/release read/write locks visible via lslocks

# Acquire a lock
# Args:
#   $1 - lock file path
#   $2 - mode: read | write
# Sets: LOCKFD (fd number), LOCKFILE (path)
lock_acquire() {
  local lockfile="$1"
  local mode="$2"

  [[ -n "$lockfile" && -n "$mode" ]] || {
    echo "lock_acquire: usage: lock_acquire <lockfile> <read|write>" >&2
    return 2
  }

  # Open FD without truncating (creates file if missing).
  exec {LOCKFD}>>"$lockfile" || return 1
  LOCKFILE="$lockfile"

  case "$mode" in
    read)  flock -s "$LOCKFD" || { exec {LOCKFD}>&-; unset LOCKFD LOCKFILE; return 1; } ;;
    write) flock -x "$LOCKFD" || { exec {LOCKFD}>&-; unset LOCKFD LOCKFILE; return 1; } ;;
    *)     echo "lock_acquire: invalid mode '$mode' (read|write)" >&2
           exec {LOCKFD}>&-; unset LOCKFD LOCKFILE; return 2 ;;
  esac
  return 0
}

# Release a previously acquired lock (closes FD and unsets vars)
lock_release() {
  if [[ -n "${LOCKFD:-}" ]]; then
    exec {LOCKFD}>&- || return 1
    unset LOCKFD LOCKFILE
    return 0
  else
    echo "lock_release: no lock to release" >&2
    return 2
  fi
}

# Append a handler to existing traps (does NOT overwrite prior ones).
# Usage: trap_add 'command...' SIG1 SIG2 ...
trap_add() {
  local handler="$1"; shift
  local sig old
  for sig in "$@"; do
    old=$(trap -p "$sig" | awk -F"'" '{print $2}')
    if [[ -n "$old" ]]; then
      trap "$old; $handler" "$sig"
    else
      trap "$handler" "$sig"
    fi
  done
}

# Enable auto-release of the current lock on exit/termination.
# You can pass a custom signal list; defaults shown below.
lock_enable_autorelease() {
  local signals=("${@:-EXIT INT TERM HUP QUIT}")
  trap_add 'lock_release >/dev/null 2>&1 || true' "${signals[@]}"
}

# Check if *any* process holds a lock on PATH.
# Returns 0 if active (locked by anyone), 1 if free.
# If $2 == "include-self", locks held by this PID also count as active.
lock_is_active() {
  local path="$1"
  local include_self="${2:-}"
  [[ -n "$path" ]] || { echo "lock_is_active: usage: lock_is_active <path> [include-self]" >&2; return 2; }

  if command -v lslocks >/dev/null 2>&1; then
    # Prefer lslocks (machine-friendly; supports -n/-o and often --json). :contentReference[oaicite:1]{index=1}
    while read -r pid type mode rest; do
      # 'rest' captures the remainder of the line (PATH), preserving spaces
      local file="$rest"
      # strip any leading whitespace from PATH
      file="${file#"${file%%[![:space:]]*}"}"
      [[ "$file" == "$path" ]] || continue
      # Count as active if it's another PID, or if include-self requested
      if [[ "$include_self" == "include-self" || "$pid" -ne "$$" ]]; then
        return 0
      fi
    done < <(lslocks -n -o PID,TYPE,MODE,PATH 2>/dev/null)
    return 1
  else
    # Fallback: try to grab an exclusive lock non-blocking on a separate FD.
    # If we *can* grab it, there was no conflicting lock; release immediately.
    local pfd
    exec {pfd}>>"$path" || return 1
    if flock -n -x "$pfd"; then
      exec {pfd}>&-
      return 1   # free
    else
      exec {pfd}>&-
      return 0   # active
    fi
  fi
}

# Optional: check if *this* process currently owns a lock on PATH.
# Returns 0 if owned by $$, 1 otherwise.
lock_is_owned_by_self() {
  local path="$1"
  [[ -n "$path" ]] || { echo "lock_is_owned_by_self: usage: lock_is_owned_by_self <path>" >&2; return 2; }
  if command -v lslocks >/dev/null 2>&1; then
    lslocks -p "$$" -n -o PID,PATH 2>/dev/null | awk -v p="$path" '$2==p {found=1} END{exit !found}'
  else
    # Without lslocks, best-effort: if LOCKFILE matches and FD open, assume yes
    [[ "${LOCKFILE:-}" == "$path" && -n "${LOCKFD:-}" ]] && return 0 || return 1
  fi
}

# --- Example ---
# lock_acquire "/tmp/demo.lock" write || exit 1
# lock_enable_autorelease         # ensure release on EXIT/INT/TERM/HUP/QUIT
# if lock_is_active "/tmp/demo.lock"; then echo "Someone holds the lock"; fi
# ... critical section ...
# lock_release
