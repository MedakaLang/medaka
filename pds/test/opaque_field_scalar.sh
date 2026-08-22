#!/bin/sh
# Compile-time API boundary gate for #1723. `Fe` and `Sc` contain mutable
# arrays, so opacity is the invariant that prevents callers from corrupting
# shared sentinels or forging non-canonical values. This is intentionally a
# check gate, not a runtime test: the bad programs must be rejected before
# they can execute.
#
# Auto-enrolled in the `sqlite` CI shard by the `pds/test/*` glob.
set -u

ROOT="${MEDAKA_ROOT:?set MEDAKA_ROOT to the repo root}"
MEDAKA="${MEDAKA:-$ROOT/medaka}"
export MEDAKA_ROOT

[ -x "$MEDAKA" ] || { echo "build medaka first (missing $MEDAKA)"; exit 2; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT HUP INT TERM

# These are distinct permanent attack cells: two exact `Array.set` sentinel
# mutations and two raw-array forgeries. Keep this floor in sync with the list.
FAIL_FLOOR=4
PASS_FLOOR=1
FAIL_CELLS="
pds/test/opaque_field_sentinel_attack.mdk
pds/test/opaque_scalar_sentinel_attack.mdk
pds/test/opaque_field_raw_forgery.mdk
pds/test/opaque_scalar_raw_forgery.mdk
"
PASS_CELLS="pds/test/opaque_field_scalar_control.mdk"

fail_ran=0
for rel in $FAIL_CELLS; do
  path="$ROOT/$rel"
  out="$WORK/fail-$fail_ran.out"
  if [ ! -f "$path" ]; then
    echo "FAIL: missing required opacity attack cell $rel"
    exit 1
  fi
  if "$MEDAKA" check "$path" >"$out" 2>&1; then
    echo "FAIL: $rel checked successfully; the opaque API attack is reachable"
    cat "$out"
    exit 1
  fi
  if ! grep -q 'Type mismatch' "$out"; then
    echo "FAIL: $rel failed for an unexpected reason, not the opaque type boundary"
    cat "$out"
    exit 1
  fi
  fail_ran=$((fail_ran + 1))
  echo "PASS: rejected opacity attack $rel"
done

pass_ran=0
for rel in $PASS_CELLS; do
  path="$ROOT/$rel"
  out="$WORK/pass-$pass_ran.out"
  if [ ! -f "$path" ]; then
    echo "FAIL: missing required opacity control $rel"
    exit 1
  fi
  if ! "$MEDAKA" check "$path" >"$out" 2>&1; then
    echo "FAIL: public opaque API control did not check: $rel"
    cat "$out"
    exit 1
  fi
  pass_ran=$((pass_ran + 1))
  echo "PASS: checked opacity control $rel"
done

if [ "$fail_ran" -lt "$FAIL_FLOOR" ]; then
  echo "FAIL: only $fail_ran opacity attack cells ran, expected >= $FAIL_FLOOR"
  exit 1
fi
if [ "$pass_ran" -lt "$PASS_FLOOR" ]; then
  echo "FAIL: only $pass_ran opacity control cells ran, expected >= $PASS_FLOOR"
  exit 1
fi

echo "PASS: field/scalar opacity — $fail_ran rejected attack cells, $pass_ran public control cells"
