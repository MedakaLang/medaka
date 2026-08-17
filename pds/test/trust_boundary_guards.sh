#!/bin/sh
# pds/test/trust_boundary_guards.sh — the PANIC half of RUN-PDS0-036's
# hostile-input guards.
#
# Two of the four guards installed by that ruling abort the process instead of
# returning a value (`sha256`'s 0..255 element domain and `uvarintEncode`'s
# non-negative argument, both on `-> Array Int` signatures where `Result` is
# not available). Medaka has no catchable panics, so neither can be asserted
# from an in-language `medaka test` file: the first abort would shadow every
# later assertion. This gate runs pds/test/guard_probes_main.mdk ONE CASE PER
# PROCESS and grades the outcome from outside.
#
# Every guard is graded in BOTH directions:
#   PANIC cell   — must exit NON-ZERO *and* print the guard's own message.
#                  Grading the message, not just the code, is load-bearing: an
#                  exit-code-only check cannot tell this guard from an
#                  unrelated abort (a typo, a missing import, an OOM), so it
#                  would stay green after the guard was deleted.
#   CONTROL cell — must exit 0 and print its expected "OK …" line. This is the
#                  half that catches an over-tight bound; sha256-edges uses the
#                  two INCLUSIVE endpoints 0 and 255 for exactly that reason.
#
# SCOPE, stated honestly: this is the EVAL arm only (`medaka run`). The native
# arm of the sha256 domain scan is covered by pds/test/sha256_vectors.sh phase
# B, which hashes the corpus — including its 1,000,000-byte `Repeat` vector —
# through the built binary; a non-tail-recursive domain scan shows up THERE as
# a native stack overflow. The uvarintEncode guard has no native cell.
#
# POSIX sh (dual-platform floor — this box's /bin/sh is dash: no
# 'printf \xNN', no 'timeout'). Model: pds/test/encodings_vectors.sh.
#
# Enrolled as a CI gate automatically by the landed 'sqlite' shard glob
# 'pds/test/*' — this file lives DIRECTLY under pds/test/, so no ci.yml edit
# and no CI-COVERAGE-EXCEPTIONS row is needed. See pds/README.md's "CI
# classification policy".
set -u

ROOT="${MEDAKA_ROOT:?set MEDAKA_ROOT to the repo root}"
MEDAKA="${MEDAKA:-$ROOT/medaka}"
export MEDAKA_ROOT

[ -x "$MEDAKA" ] || { echo "build medaka first (missing $MEDAKA)"; exit 2; }

PROBE="$ROOT/pds/test/guard_probes_main.mdk"
[ -f "$PROBE" ] || { echo "FAIL: missing probe program $PROBE"; exit 1; }

# Anti-rot floor: the number of cells committed today. A run that silently
# executed fewer than this is NOT a pass ("this didn't run" is
# indistinguishable from "this passed" — docs/ops/TESTING-DESIGN.md §0).
CELL_FLOOR=5

out="$(mktemp "${TMPDIR:-/tmp}/trust-boundary-out.XXXXXX")"
trap 'rm -f "$out"' EXIT

cells=0
failed=0

# Never pipe the probe: a pipe reports the LAST stage's status, so a failing
# run reads as exit 0. Redirect to a file, read $?, then read the file.
run_case() {
  "$MEDAKA" run "$PROBE" "$1" > "$out" 2>&1
  code=$?
  cells=$((cells + 1))
}

# expect_panic <case> <substring the guard's own message must contain>
expect_panic() {
  run_case "$1"
  if [ "$code" -eq 0 ]; then
    echo "FAIL: $1 — expected a panic, got exit 0"
    cat "$out"
    failed=$((failed + 1))
    return
  fi
  if ! grep -q "$2" "$out"; then
    echo "FAIL: $1 — aborted (exit $code) but without the guard's message '$2'"
    echo "       an abort from some OTHER cause is not this guard firing."
    cat "$out"
    failed=$((failed + 1))
    return
  fi
  echo "ok   $1 — panicked (exit $code) with the guard's own message"
}

# expect_ok <case> <expected stdout line>
expect_ok() {
  run_case "$1"
  if [ "$code" -ne 0 ]; then
    echo "FAIL: $1 — control case must not fire the guard, but exited $code"
    cat "$out"
    failed=$((failed + 1))
    return
  fi
  if ! grep -q "^$2\$" "$out"; then
    echo "FAIL: $1 — control case exited 0 but did not print '$2'"
    cat "$out"
    failed=$((failed + 1))
    return
  fi
  echo "ok   $1 — legitimate input unaffected"
}

expect_panic sha256-over  "sha256: every element must be a byte in 0..255"
expect_panic sha256-under "sha256: every element must be a byte in 0..255"
expect_ok    sha256-edges "OK sha256-edges len=32"

expect_panic uvarint-neg "unsigned-varint encodes non-negative values only"
expect_ok    uvarint-ok  "OK uvarint-ok len=2"

if [ "$failed" -ne 0 ]; then
  echo "FAIL: trust_boundary_guards — $failed of $cells cells failed"
  exit 1
fi

if [ "$cells" -lt "$CELL_FLOOR" ]; then
  echo "FAIL: only $cells cells ran, expected >= $CELL_FLOOR (vacuous-green guard)"
  exit 1
fi

echo "PASS: trust_boundary_guards — $cells cells"
exit 0
