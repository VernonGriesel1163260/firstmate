#!/usr/bin/env bash
# Focused repro of tests/fm-watcher-lock.test.sh::test_lock_real_directory_default_wait
set -u
ROOT="{run-worktree}"
export MSYS=${MSYS_LNK_MODE:+winsymlinks:lnk}
W=$(mktemp -d /tmp/fm-dw.XXXXXX)
STATE="$W/state"; mkdir -p "$STATE"
LOCK="$STATE/.contend.lock"; mkdir -p "$LOCK"
DEAD=$(bash -c 'echo $$')
printf '%s\n' "$DEAD" > "$LOCK/pid"
printf 'preserve me\n' > "$LOCK/unrecognized-record"
touch -t 200001010000 "$LOCK" "$LOCK/pid" "$LOCK/unrecognized-record"

bash -c '. "$1"; fm_lock_acquire_wait "$2" || exit 10; fm_lock_release "$2"; echo "acquired-and-released"' \
  _ "$ROOT/bin/fm-wake-lib.sh" "$LOCK" > "$W/child.out" 2> "$W/child.err" &
CHILD=$!

for i in $(seq 1 40); do
  if [ -e "$LOCK/pid" ]; then
    printf 't=%04dms pid EXISTS\n' $((i * 100))
  else
    printf 't=%04dms pid GONE\n' $((i * 100))
  fi
  kill -0 "$CHILD" 2>/dev/null || { printf 'child exited at ~%dms\n' $((i * 100)); break; }
  sleep 0.1
done
wait "$CHILD"; echo "child rc=$?"
echo "--- child.out ---"; cat "$W/child.out"
echo "--- child.err ---"; cat "$W/child.err"
echo "--- state now ---"; ls -A "$STATE" 2>/dev/null
[ -d "$LOCK" ] && { echo "--- lock contents ---"; ls -A "$LOCK"; }
rm -rf "$W"
