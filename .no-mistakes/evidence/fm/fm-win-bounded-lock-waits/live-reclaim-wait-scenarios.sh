#!/usr/bin/env bash
# Live validation of the Windows reclaim bound in bin/fm-wake-lib.sh's
# fm_lock_acquire_wait (the ordinary, unflagged wait).
#
# S5: on this host's real MINGW64 uname, a stale real lock directory whose
#     reclaim keeps failing (an unrecognized record keeps rmdir failing, rc=2,
#     exactly the producer of FM_LOCK_RECLAIM_FAILED_PATH) is refused by the
#     ordinary wait after the two-second Windows bound, naming the directory.
# S6: the identical setup with the POSIX uname forced (as CI's portable shard
#     does for the MINGW branch) must NOT refuse at the Windows bound: the
#     wait keeps polling, and once the blocker is removed the lock is reaped
#     and acquired, proving POSIX ordinary waits are unchanged.
set -u
export MSYS=winsymlinks:lnk
ROOT="{run-worktree}"
EV="~/.no-mistakes/evidence/01M7H5BDWSB53KKVF742PTVQTF"
WORK=$(mktemp -d "/tmp/fm-reclaim.XXXXXX")
REPORT="$EV/live-reclaim-wait-scenarios.report.txt"
: > "$REPORT"
say() { printf '%s\n' "$*" >> "$REPORT"; }

make_wedged() { # <name> -> echoes lock path; leaves a dead pid record
  local state="$WORK/$1"
  mkdir -p "$state"
  local lock="$state/.acquire.lock"
  mkdir -p "$lock"
  # a dead holder pid so the lock is stale, plus an unrecognized record that
  # fm_lock_clean_known_files must leave alone and that keeps rmdir failing
  local dead
  dead=$(bash -c 'echo $$' )  # pid of an already-exited shell
  printf '%s\n' "$dead" > "$lock/pid"
  printf 'preserve me\n' > "$lock/unrecognized-record"
  touch -t 200001010000 "$lock" "$lock/pid" "$lock/unrecognized-record"
  printf '%s\n' "$lock"
}

### S5: ordinary wait on real MINGW refuses the unreapable stale lock ~2s
LOCK5=$(make_wedged s5)
say "== S5 ordinary fm_lock_acquire_wait (no flag) on MINGW refuses unreapable stale lock =="
say "lock: $LOCK5"
T0=$(date +%s%N)
bash -c '. "$1"; fm_lock_acquire_wait "$2" >/dev/null 2>"$3"; echo $? > "$3.rc"' \
  _ "$ROOT/bin/fm-wake-lib.sh" "$LOCK5" "$WORK/s5.err"
RC5=$(cat "$WORK/s5.err.rc")
MS5=$(( ($(date +%s%N) - T0) / 1000000 ))
say "exit=$RC5 elapsed_ms=$MS5"
say "--- stderr ---"; cat "$WORK/s5.err" >> "$REPORT"
say "--- lock preserved ---"; ls -A "$LOCK5" >> "$REPORT"
# This host's fork-heavy MSYS makes each try_acquire iteration ~2.5s, so the
# first SECONDS>=deadline check lands well past 2s wall; the contract asserted
# here is a bounded refusal (not infinite), well under the old endless poll.
if [ "$RC5" != 0 ] \
   && [ "$MS5" -ge 1800 ] && [ "$MS5" -le 15000 ] \
   && grep -q "cannot reclaim lock directory" "$WORK/s5.err" \
   && grep -qF "$LOCK5" "$WORK/s5.err" \
   && [ "$(cat "$LOCK5/unrecognized-record")" = "preserve me" ]; then
  say "S5 RESULT: PASS (bounded named refusal, contents preserved)"
else
  say "S5 RESULT: FAIL"
fi

### S6: POSIX ordinary wait is unchanged (no 2s refusal; acquires once reapable)
LOCK6=$(make_wedged s6)
say ""
say "== S6 POSIX-mode ordinary wait survives past the 2s Windows bound and acquires =="
say "lock: $LOCK6"
# Remove the unrecognized record after ~4s: the stale lock becomes reapable.
( sleep 4 && rm -f "$LOCK6/unrecognized-record" ) &
BLOCKER=$!
T0=$(date +%s%N)
bash -c '. "$1"; _FM_UNAME=Linux; fm_lock_acquire_wait "$2" >/dev/null 2>"$3"; echo $? > "$3.rc"' \
  _ "$ROOT/bin/fm-wake-lib.sh" "$LOCK6" "$WORK/s6.err"
RC6=$(cat "$WORK/s6.err.rc")
MS6=$(( ($(date +%s%N) - T0) / 1000000 ))
wait "$BLOCKER" 2>/dev/null
say "exit=$RC6 elapsed_ms=$MS6 (must exceed the 2000ms Windows bound)"
say "--- stderr ---"; cat "$WORK/s6.err" >> "$REPORT"
if [ "$RC6" = 0 ] && [ "$MS6" -ge 3500 ] && [ ! -e "$WORK/s6.err" ] || [ ! -s "$WORK/s6.err" ]; then
  :
fi
if [ "$RC6" = 0 ] && [ "$MS6" -ge 3500 ] && [ ! -s "$WORK/s6.err" ]; then
  say "S6 RESULT: PASS (POSIX wait unbounded by the Windows refusal; acquired after reap)"
else
  say "S6 RESULT: FAIL"
fi

# release whatever S6 acquired so the fixture can be removed
bash -c '. "$1"; fm_lock_release "$2" 2>/dev/null || true' _ "$ROOT/bin/fm-wake-lib.sh" "$LOCK6" 2>/dev/null
rm -rf "$WORK"
say ""
grep -c "RESULT: PASS" "$REPORT" | xargs echo "PASS COUNT:"
grep -c "RESULT: FAIL" "$REPORT" | xargs echo "FAIL COUNT:"
