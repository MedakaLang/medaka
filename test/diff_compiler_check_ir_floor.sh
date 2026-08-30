#!/bin/sh
# diff_compiler_check_ir_floor.sh — the FIRST constant-factor floor gate in the perf suite
# (S-5-floor-ratchet, epic #2036 Wave 2). Companion to test/perf_baseline.sh's
# `check`/`hello` co-metric: that harness MEASURES the same cachegrind Ir number every
# run, but is deliberately assertion-free (test/CI-COVERAGE-TOOLS.txt) — nothing fails if
# the constant factor this sprint spent effort removing (the `check`/hello floor, per
# compiler/PERF-BASELINE.md's regenerated `## Table`, dropped from a `b6d029cd` figure of
# ~1,382,929,374 Ir down to ~625M post-fix, a cumulative -54.8%) silently comes back.
#
# WHY AN ABSOLUTE CEILING IS SOUND HERE (same argument as diff_compiler_ir_size.sh's
# header): cachegrind Ir for a fixed program on a fixed binary is DETERMINISTIC — it
# counts retired instructions, not wall-clock, so it carries none of a timer's OS-jitter
# noise. A single hello-world `check` run is cheap (~a few seconds of valgrind emulation,
# not a scaling sweep), so this is ONE Cachegrind point, not a ladder — see
# diff_compiler_ir_scaling.sh / diff_compiler_stage_ir_scaling.sh / diff_compiler_perf_scaling.sh
# for the ratio-graded ladders this gate deliberately does NOT try to be.
#
# WHAT THIS GATE IS NOT: it does not assert anything about Val's per-verb wall-clock
# targets (S-4's proposal, reviewed separately) — this is a different metric (Ir, not
# wall-clock) derived from THIS sprint's own measured post-fix number, independent of that
# decision.
#
# CEILING DERIVATION (measured on this box, same method as test/perf_baseline.sh's `ir_of`:
# `valgrind --tool=cachegrind --cache-sim=no --branch-sim=no`, GC_INITIAL_HEAP_SIZE pinned
# to 1GiB): two back-to-back runs of `medaka check` on test/native_cli_fixtures/run/hello.mdk
# measured Ir = 626,002,847 and 626,003,988 (deterministic within noise, <0.001% apart).
# CEIL is set at 750,000,000 — ~20% headroom over the measured ~626M: enough to absorb
# small legitimate prelude/typecheck drift across future slices without flaking, while
# still catching the ~2.2x regression class this sprint fixed (the pre-fix ~1.38B figure
# would fail this gate at +84% over ceiling).
#
# Usage:  sh test/diff_compiler_check_ir_floor.sh
#         CHECK_IR_CEIL=<n> sh test/diff_compiler_check_ir_floor.sh   # override for testing
# Exit:   0 the measured Ir is at or under the ceiling
#         1 over ceiling, or the harness could not measure anything (never a silent no-op)
#         2 native medaka/emitter/valgrind not available (opt-in skip, same as the other
#           cachegrind-based gates)
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MEDAKA="$ROOT/medaka"
EMITTER="${MEDAKA_EMITTER:-$ROOT/medaka_emitter}"
HELLO_FILE="$ROOT/test/native_cli_fixtures/run/hello.mdk"

[ -x "$MEDAKA" ]  || { echo "build native first: make medaka (missing $MEDAKA)"; exit 2; }
[ -x "$EMITTER" ] || { echo "build native first: make medaka (missing $EMITTER)"; exit 2; }
[ -f "$HELLO_FILE" ] || { echo "missing fixture: $HELLO_FILE"; exit 2; }
command -v valgrind >/dev/null 2>&1 || { echo "no valgrind on PATH — required for the Ir co-metric"; exit 2; }

export MEDAKA_ROOT="$ROOT" MEDAKA_EMITTER="$EMITTER"

# CEILING — see derivation comment above. ~20% headroom over the measured ~626M post-fix
# Ir. Do NOT quietly bump this if it starts failing — re-measure, understand what regrew,
# and only then adjust WITH a comment (same discipline as diff_compiler_ir_size.sh).
CEIL="${CHECK_IR_CEIL:-750000000}"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/mdk-checkirfloor.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT INT TERM

GC_INITIAL_HEAP_SIZE=1073741824
export GC_INITIAL_HEAP_SIZE
valgrind --tool=cachegrind --cache-sim=no --branch-sim=no \
  --cachegrind-out-file="$WORK/cg.out" \
  "$MEDAKA" check "$HELLO_FILE" >/dev/null 2>"$WORK/vg.err"
unset GC_INITIAL_HEAP_SIZE

ir="$(grep -a 'I  *refs:' "$WORK/vg.err" | sed 's/.*I *refs: *//' | tr -d ' ,')"

case "$ir" in
  ''|*[!0-9]*)
    echo "FAIL: could not measure cachegrind Ir for 'medaka check $HELLO_FILE' — harness bug." >&2
    cat "$WORK/vg.err" >&2
    exit 1
    ;;
esac

if [ "$ir" -gt "$CEIL" ]; then
  printf 'FAIL (CEILING): hello-world `check` cost %s Ir, over the %s ceiling.\n' "$ir" "$CEIL"
  printf '  This is the constant-factor-regression class S-5-floor-ratchet ratcheted against\n'
  printf '  (epic #2036 Wave 2): the check-path startup/typecheck cost regrew. Compare against\n'
  printf '  compiler/PERF-BASELINE.md and re-run test/perf_baseline.sh to see where time went.\n'
  printf '  Do NOT just raise the ceiling — find what regrew.\n'
  exit 1
fi

printf 'PASS: hello-world `check` = %s Ir (ceiling %s).\n' "$ir" "$CEIL"
exit 0
