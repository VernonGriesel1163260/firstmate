#!/usr/bin/env bash
# Full default-wait dance (the scenario test_lock_real_directory_default_wait
# drives): ordinary wait polls a stale, temporarily-unreapable lock; the
# residue-holder side removes the blocker once reclamation has been attempted
# (pid record gone); the waiter then reaps, acquires, and releases.
set -u
export MSYS=winsymlinks:lnk
ROOT="{run-worktree}"
W=$(mktemp -d /tmp/fm-dw2.XXXXXX)
STATE="$W/state"; mkdir -p "$STATE"
LOCK="$STATE/.contend.lock"; mkdir -p "$LOCK"
DEAD=$(bash -c 'echo $$')
printf '%s\n' "$DEAD" > "$LOCK/pid"
printf 'preserve me\n' > "$LOCK/unrecognized-record"
touch -t 200001010000 "$LOCK" "$LOCK/pid" "$LOCK/unrecognized-record"

bash -c '. "$1"; fm_lock_acquire_wait "$2" || exit 10; fm_lock_release "$2"' \
  _ "$ROOT/bin/fm-wake-lib.sh" "$LOCK" > "$W/child.out" 2> "$W/child.err" &
CHILD=$!

# Parent side (stands in for the python driver): watch for reclamation
# (pid record removed), then remove the unrecognized blocker.
RESULT=unknown
for i in $(seq 1 100); do
  if [ ! -e "$LOCK/pid" ]; then
    echo "reclamation attempted at ~$((i * 50))ms; child still waiting: $(kill -0 $CHILD 2>/dev/null && echo yes || echo NO)"
    [ -e "$LOCK/unrecognized-record" ] && { echo "record preserved during wait: $(cat "$LOCK/unrecognized-record")"; rm -f "$LOCK/unrecognized-record"; }
    wait "$CHILD"; RESULT=$?
    break
  fi
  kill -0 "$CHILD" 2>/dev/null || { wait "$CHILD"; RESULT=$?; echo "child exited early rc=$RESULT"; break; }
  sleep 0.05
done
echo "final rc=$RESULT"
echo "--- child.err ---"; cat "$W/child.err"
echo "--- state ---"; ls -A "$STATE"
rm -rf "$W"
[ "$RESULT" = 0 ] && echo "DANCE RESULT: PASS" || echo "DANCE RESULT: FAIL"
