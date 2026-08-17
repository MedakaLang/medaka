#!/bin/sh
# pds/test/encodings_vectors.sh — vector gate for S-encodings (#1701 encodings
# base58btc + multiformats).
#
# Runs pds/test/encodings_vectors_main.mdk against pds/test/vectors/, and
# FAILS unless:
#   1. the driver's LAST stdout line is exactly "TOTAL: PASS";
#   2. the count of "PASS\t"-prefixed lines is at least the committed floor
#      (F-19's lesson — a driver silently reading zero rows would otherwise
#      print "TOTAL: PASS" having checked nothing).
#
# POSIX sh (dual-platform floor — this box's /bin/sh is dash: no
# 'printf \xNN', no 'timeout'). Model: pds/test/inlang_test_oracle.sh.
#
# Enrolled as a CI gate automatically by the landed 'sqlite' shard glob
# 'pds/test/*' — this file lives DIRECTLY under pds/test/, so no ci.yml edit
# is needed (F-16).
set -u

ROOT="${MEDAKA_ROOT:?set MEDAKA_ROOT to the repo root}"
MEDAKA="${MEDAKA:-$ROOT/medaka}"
export MEDAKA_ROOT

[ -x "$MEDAKA" ] || { echo "build medaka first (missing $MEDAKA)"; exit 2; }

# Floor = the "PASS\t" line count committed today (29 — see the slice report
# for the paste). Raise this when you add a checked cell.
PASS_FLOOR=29

VECTORS_DIR="${1:-$ROOT/pds/test/vectors}"

out="$(mktemp "${TMPDIR:-/tmp}/encodings-vectors-out.XXXXXX")"
trap 'rm -f "$out"' EXIT

"$MEDAKA" run "$ROOT/pds/test/encodings_vectors_main.mdk" "$VECTORS_DIR" > "$out" 2>&1
code=$?

last_line="$(tail -n 1 "$out")"
pass_count="$(grep -c '^PASS	' "$out")"

if [ "$code" -ne 0 ]; then
  echo "FAIL: encodings_vectors_main.mdk exited $code"
  cat "$out"
  exit 1
fi

if [ "$last_line" != "TOTAL: PASS" ]; then
  echo "FAIL: last stdout line was '$last_line', expected 'TOTAL: PASS'"
  cat "$out"
  exit 1
fi

# A non-numeric count makes `[` ERROR rather than compare, and with `set -e`
# off control falls through to the PASS branch — so the floor guard could
# never fail on the one thing it exists to catch (RUN-PDS0-040, F20). Check
# numeric-ness first.
case "$pass_count" in
  ''|*[!0-9]*)
    echo "FAIL: PASS-line count is not a number ('$pass_count') — the driver's summary line did not parse; the anti-rot floor could not be graded."
    cat "$out"
    exit 1 ;;
esac
if [ "$pass_count" -lt "$PASS_FLOOR" ]; then
  echo "FAIL: only $pass_count PASS lines, expected >= $PASS_FLOOR (vacuous-green guard: the driver may have silently read zero rows)"
  cat "$out"
  exit 1
fi

echo "PASS: encodings_vectors — $pass_count PASS lines (floor $PASS_FLOOR)"
exit 0
