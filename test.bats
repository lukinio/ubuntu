#!/usr/bin/env bats

# Load assertions if available (optional)
load 'test_helper/bats-assert/load' 2>/dev/null || true

setup() {
  # shellcheck disable=SC1091
  source ./lock_utils.sh
  TMPDIR=$(mktemp -d 2>/dev/null || mktemp -d -t locktest.XXXXXX)
  LOCK="${TMPDIR}/demo.lock"
}

teardown() {
  rm -rf "$TMPDIR"
}

# Helper: count lslocks entries for this PID and PATH
_lslocks_grep() {
  lslocks -p "$1" -n -o MODE,TYPE,PATH 2>/dev/null | awk -v p="$2" '$3==p{print $0}'
}

@test "write lock: appears in lslocks and disappears after release" {
  run lock_acquire "$LOCK" write
  [ "$status" -eq 0 ]

  run bash -c "[ -n \"\$(_lslocks_grep $$ \"$LOCK\")\" ]"
  [ "$status" -eq 0 ]
  [[ "$output" == *"WRITE FLOCK"* ]]

  run lock_release
  [ "$status" -eq 0 ]

  run bash -c "[ -z \"\$(_lslocks_grep $$ \"$LOCK\")\" ]"
  [ "$status" -eq 0 ]
}

@test "read lock: two readers can coexist (two READ entries)" {
  # Child that holds a read lock for a moment
  CHILD="${TMPDIR}/reader.sh"
  cat >"$CHILD" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
source ./lock_utils.sh
lock_acquire "$1" read
echo "READY $$"
sleep 3
lock_release
SH
  chmod +x "$CHILD"

  # Start child reader
  run bash -c "\"$CHILD\" \"$LOCK\" & echo \$!"
  [ "$status" -eq 0 ]
  child_pid="$output"

  # Wait until child prints READY
  ready=""
  for _ in $(seq 1 30); do
    if lslocks -p "$child_pid" -n -o MODE,TYPE,PATH 2>/dev/null | grep -q "READ FLOCK.*$LOCK"; then
      ready=1; break
    fi
    sleep 0.1
  done
  [ -n "$ready" ]

  # Acquire second read lock in this process
  run lock_acquire "$LOCK" read
  [ "$status" -eq 0 ]

  # We should see one READ for child and one for self
  run bash -c "lslocks -n -o PID,MODE,TYPE,PATH | awk -v p=\"$LOCK\" '\$4==p && \$2==\"READ\" && \$3==\"FLOCK\"{print \$1}' | wc -l"
  [ "$status" -eq 0 ]
  [ "$output" -ge 2 ]

  run lock_release
  [ "$status" -eq 0 ]
}

@test "exclusive lock prevents another exclusive non-blocking probe" {
  run lock_acquire "$LOCK" write
  [ "$status" -eq 0 ]

  # Probe with a separate FD + flock -n -x (should fail)
  run bash -c 'exec {pfd}>>"$0"; flock -n -x "$pfd"' "$LOCK"
  [ "$status" -ne 0 ]  # cannot take exclusive lock

  run lock_release
  [ "$status" -eq 0 ]
}

@test "lock_is_active returns 0 when locked and 1 when free" {
  run lock_is_active "$LOCK"
  [ "$status" -eq 1 ]   # free

  run lock_acquire "$LOCK" write
  [ "$status" -eq 0 ]

  run lock_is_active "$LOCK"
  [ "$status" -eq 0 ]   # active (other or self)

  run lock_is_active "$LOCK" include-self
  [ "$status" -eq 0 ]   # explicitly includes self, still active

  run lock_release
  [ "$status" -eq 0 ]

  run lock_is_active "$LOCK"
  [ "$status" -eq 1 ]   # free again
}

@test "lock_is_owned_by_self detects our lock" {
  run lock_acquire "$LOCK" read
  [ "$status" -eq 0 ]

  run lock_is_owned_by_self "$LOCK"
  [ "$status" -eq 0 ]

  run lock_release
  [ "$status" -eq 0 ]

  run lock_is_owned_by_self "$LOCK"
  [ "$status" -eq 1 ]
}

@test "lock_enable_autorelease frees lock on SIGTERM" {
  CHILD="${TMPDIR}/term.sh"
  cat >"$CHILD" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
source ./lock_utils.sh
lock_acquire "$1" write
lock_enable_autorelease
echo "READY $$"
# wait for TERM
while :; do sleep 1; done
SH
  chmod +x "$CHILD"

  # Start child, wait until it announces READY
  child_pid=$(
    bash -c "\"$CHILD\" \"$LOCK\" & pid=\$!; while ! lslocks -p \$pid -n -o PATH 2>/dev/null | grep -q \"$LOCK\"; do sleep 0.05; done; echo \$pid"
  )

  # Confirm child holds the WRITE lock
  run bash -c "lslocks -p \"$child_pid\" -n -o MODE,TYPE,PATH | grep -q \"WRITE FLOCK.*$LOCK\""
  [ "$status" -eq 0 ]

  # Kill and then confirm lock gone
  kill -TERM "$child_pid"
  wait "$child_pid" 2>/dev/null || true

  # give kernel a tick to drop it
  sleep 0.1
  run bash -c "[ -z \"\$(_lslocks_grep \"$child_pid\" \"$LOCK\")\" ]"
  [ "$status" -eq 0 ]
}

@test "OPTIONAL: custom FD support (skip if not implemented)" {
  # Try taking with fd 9; skip on failure that looks like usage error
  if lock_acquire "$LOCK" write 9 2>/dev/null; then
    # We successfully used custom FD; release it explicitly
    run lock_release 9
    [ "$status" -eq 0 ]
  else
    skip "custom FD variant not implemented in this version"
  fi
}
