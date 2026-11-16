#!/usr/bin/env bash
# Live validation driver for fm/fm-win-bounded-lock-waits.
# Drives the real bin/fm-captain-hold.sh against disposable FM_HOME fixtures.
# MSYS=winsymlinks:lnk is exported so this host's Git Bash can create the
# symlink-backed lock records the lock protocol requires (stock Git Bash
# copies instead; native symlinks need a privilege this host lacks).
set -u
export MSYS=winsymlinks:lnk
ROOT="{run-worktree}"
EV="~/.no-mistakes/evidence/01M7H5BDWSB53KKVF742PTVQTF"
WORK=$(mktemp -d "/tmp/fm-live-lock.XXXXXX")
REPORT="$EV/live-meta-lock-scenarios.report.txt"
: > "$REPORT"

say() { printf '%s\n' "$*" >> "$REPORT"; }
HOLDER_PIDS=''
cleanup() {
  local p
  for p in $HOLDER_PIDS; do kill "$p" 2>/dev/null || true; done
  rm -rf "$WORK"
}
trap cleanup EXIT

# run_captain <home> <bound-or-'-'> <args...>
run_captain() {
  local home=$1 bound=$2; shift 2
  if [ "$bound" = - ]; then
    unset FM_CAPTAIN_META_LOCK_BOUND
  else
    export FM_CAPTAIN_META_LOCK_BOUND="$bound"
  fi
  ( cd "$ROOT" && PATH="$home/fakebin:$PATH" FM_GATE_REFUSE_BYPASS=1 \
      FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
      FM_CONFIG_OVERRIDE="$home/config" \
      "$ROOT/bin/fm-captain-hold.sh" "$@" ) 2>"$WORK/err.txt" 1>"$WORK/out.txt"
  echo $?
}

make_fixture() { # <name>
  local home="$WORK/$1"
  mkdir -p "$home/state" "$home/data" "$home/config" "$home/projects" "$home/fakebin"
  printf 'decisions_reviewed=1\ndecision_keys=\n' > "$home/state/sample-origin.meta"
  printf '%s\n' "$home"
}

start_holder() { # prints live pid that stays alive 120s
  bash -c 'echo $$; exec sleep 120' > "$WORK/pid" &
  sleep 0.4
  cat "$WORK/pid"
}

snapshot_state() { # <home>
  say "--- state after ---"
  ls -A "$1/state" >> "$REPORT" 2>&1
  say "--- meta after ---"
  cat "$1/state/sample-origin.meta" >> "$REPORT"
}

### S0: complete on a clean home acquires the fresh metadata lock without waiting
say "== S0 fresh complete acquires metadata lock fast (no contention) =="
HOME0=$(make_fixture s0)
T0=$(date +%s%N)
RC=$(run_captain "$HOME0" - complete sample-origin --none)
MS=$(( ($(date +%s%N) - T0) / 1000000 ))
say "exit=$RC elapsed_ms=$MS"
say "--- stderr ---"; cat "$WORK/err.txt" >> "$REPORT"
say "--- stdout ---"; cat "$WORK/out.txt" >> "$REPORT"
snapshot_state "$HOME0"
if ! grep -q "metadata lock acquisition failed" "$WORK/err.txt" && [ "$MS" -lt 6000 ]; then
  say "S0 RESULT: PASS (bounded change leaves ordinary acquisition immediate)"
else
  say "S0 RESULT: FAIL"
fi

### S1: complete refuses on held origin metadata lock (direct holder, default bound)
say ""
say "== S1 complete bounded refusal, direct holder pid published in lock dir =="
HOME1=$(make_fixture s1)
LOCK1="$HOME1/state/.meta-sample-origin.lock"
mkdir -p "$LOCK1"
HPID1=$(start_holder)
HOLDER_PIDS="$HOLDER_PIDS $HPID1"
printf '%s\n' "$HPID1" > "$LOCK1/pid"
T0=$(date +%s%N)
RC=$(run_captain "$HOME1" - complete sample-origin --none)
MS=$(( ($(date +%s%N) - T0) / 1000000 ))
say "exit=$RC elapsed_ms=$MS (default bound, no FM_CAPTAIN_META_LOCK_BOUND in env)"
say "--- stderr ---"; cat "$WORK/err.txt" >> "$REPORT"
snapshot_state "$HOME1"
if [ "$RC" = 1 ] \
   && grep -q "origin metadata lock acquisition failed after 10s" "$WORK/err.txt" \
   && grep -qF "$LOCK1" "$WORK/err.txt" \
   && grep -q "holder pid=$HPID1" "$WORK/err.txt" \
   && [ "$(cat "$HOME1/state/sample-origin.meta")" = "$(printf 'decisions_reviewed=1\ndecision_keys=\n')" ] \
   && [ ! -e "$HOME1/state/sample-origin.status" ]; then
  say "S1 RESULT: PASS"
else
  say "S1 RESULT: FAIL"
fi

### S2: refusal names hidden nested .owner.* holder evidence (incident shape)
say ""
say "== S2 complete refusal names hidden nested .lock.owner.* holder =="
HOME2=$(make_fixture s2)
LOCK2="$HOME2/state/.meta-sample-origin.lock"
OWNER2="$LOCK2/.meta-sample-origin.lock.owner.fixture"
mkdir -p "$OWNER2"
HPID2=$(start_holder)
HOLDER_PIDS="$HOLDER_PIDS $HPID2"
printf '%s\n' "$HPID2" > "$OWNER2/pid"
T0=$(date +%s%N)
RC=$(run_captain "$HOME2" 2 complete sample-origin --none)
MS=$(( ($(date +%s%N) - T0) / 1000000 ))
say "exit=$RC elapsed_ms=$MS (FM_CAPTAIN_META_LOCK_BOUND=2)"
say "--- stderr ---"; cat "$WORK/err.txt" >> "$REPORT"
snapshot_state "$HOME2"
if [ "$RC" = 1 ] \
   && grep -q "origin metadata lock acquisition failed after 2s" "$WORK/err.txt" \
   && grep -qF "$OWNER2" "$WORK/err.txt" \
   && grep -q "holder pid=$HPID2" "$WORK/err.txt" \
   && [ "$(cat "$OWNER2/pid")" = "$HPID2" ]; then
  say "S2 RESULT: PASS"
else
  say "S2 RESULT: FAIL"
fi

### S3: verify stays lock-free while the metadata lock is held
say ""
say "== S3 verify remains lock-free while metadata lock held (same held lock as S2) =="
T0=$(date +%s%N)
RC=$(run_captain "$HOME2" - verify sample-origin)
MS=$(( ($(date +%s%N) - T0) / 1000000 ))
say "exit=$RC elapsed_ms=$MS"
say "--- stdout ---"; cat "$WORK/out.txt" >> "$REPORT"
snapshot_state "$HOME2"
if [ "$RC" = 0 ] && grep -q "verified: sample-origin captain-call inventory" "$WORK/out.txt" \
   && [ ! -e "$HOME2/state/sample-origin.status" ]; then
  say "S3 RESULT: PASS"
else
  say "S3 RESULT: FAIL"
fi

### S4: invalid FM_CAPTAIN_META_LOCK_BOUND is a loud named failure
say ""
say "== S4 invalid FM_CAPTAIN_META_LOCK_BOUND named refusal (no contention) =="
for BAD in abc 0; do
  HOME4=$(make_fixture "s4-$BAD-$RANDOM")
  T0=$(date +%s%N)
  RC=$(run_captain "$HOME4" "$BAD" complete sample-origin --none)
  MS=$(( ($(date +%s%N) - T0) / 1000000 ))
  say "bound='$BAD' exit=$RC elapsed_ms=$MS"
  say "--- stderr ---"; cat "$WORK/err.txt" >> "$REPORT"
  snapshot_state "$HOME4"
  if [ "$RC" = 1 ] && grep -q "FM_CAPTAIN_META_LOCK_BOUND must be positive integer seconds" "$WORK/err.txt"; then
    say "S4(bound='$BAD') RESULT: PASS"
  else
    say "S4(bound='$BAD') RESULT: FAIL"
  fi
done

### S4b: empty FM_CAPTAIN_META_LOCK_BOUND falls back to the documented default 10
say ""
say "== S4b empty FM_CAPTAIN_META_LOCK_BOUND uses documented default 10 =="
HOME4B=$(make_fixture "s4b-$RANDOM")
LOCK4B="$HOME4B/state/.meta-sample-origin.lock"
mkdir -p "$LOCK4B"
HPID4B=$(start_holder)
HOLDER_PIDS="$HOLDER_PIDS $HPID4B"
printf '%s\n' "$HPID4B" > "$LOCK4B/pid"
T0=$(date +%s%N)
RC=$(run_captain "$HOME4B" '' complete sample-origin --none)
MS=$(( ($(date +%s%N) - T0) / 1000000 ))
say "exit=$RC elapsed_ms=$MS (FM_CAPTAIN_META_LOCK_BOUND set to empty string)"
say "--- stderr ---"; cat "$WORK/err.txt" >> "$REPORT"
if [ "$RC" = 1 ] \
   && grep -q "origin metadata lock acquisition failed after 10s" "$WORK/err.txt" \
   && grep -q "holder pid=$HPID4B" "$WORK/err.txt"; then
  say "S4b RESULT: PASS (empty bound resolves to the documented default)"
else
  say "S4b RESULT: FAIL"
fi

say ""
grep -c "RESULT: PASS" "$REPORT" | xargs echo "PASS COUNT:"
grep -c "RESULT: FAIL" "$REPORT" | xargs echo "FAIL COUNT:"
