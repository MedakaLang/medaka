#!/bin/sh
# diff_compiler_check_ir_floor.sh — the constant-factor floor gate in the perf suite:
# a deterministic cachegrind-`Ir` ABSOLUTE CEILING per CLI verb on a hello-world
# workload. Introduced by S-5-floor-ratchet (epic #2036 Wave 2) covering `check` only;
# widened to `check`/`build`/`run`/`test` by S-verb-ir-ceilings (#2332, sprint 10
# "hold-the-gains"). The gate NAME is deliberately unchanged (`check_ir_floor`) so the
# registry row, shard assignment and CI plumbing stay put — read it as "the check-in
# floor gate", not "the `check`-verb floor gate".
#
# Companion to test/perf_baseline.sh, which MEASURES these same cachegrind Ir numbers
# every run but is deliberately assertion-free (test/CI-COVERAGE-TOOLS.txt) — nothing
# there fails when a constant factor a sprint spent effort removing silently comes back.
# This gate is the assertion half.
#
# WHY AN ABSOLUTE CEILING IS SOUND HERE (same argument as diff_compiler_ir_size.sh's
# header): cachegrind Ir for a fixed program on a fixed binary is DETERMINISTIC — it
# counts retired instructions, not wall-clock, so it carries none of a timer's OS-jitter
# noise. Each hello-world run is cheap (~2-3s of valgrind emulation, not a scaling
# sweep), so this is FOUR Cachegrind points, not a ladder — see
# diff_compiler_ir_scaling.sh / diff_compiler_stage_ir_scaling.sh /
# diff_compiler_perf_scaling.sh for the ratio-graded ladders this gate deliberately does
# NOT try to be.
#
# ⚠️ diff_compiler_stage_ir_scaling.sh refuses a whole-process `build` Ir arm because
# fixed process cost DILUTES a RATIO. That refusal does not transfer here: an ABSOLUTE
# ceiling is only made MORE stable by fixed cost, not less.
#
# WHAT THIS GATE IS NOT: it does not assert anything about per-verb WALL-CLOCK targets
# (a separate, separately-reviewed proposal) — this is a different metric (Ir, not
# wall-clock), derived from measurements taken on this tree.
#
# WORKLOAD SCOPE: hello-world only. A `gzip/` project-workload arm was measured and
# deliberately NOT added (S-verb-ir-ceilings): one project-workload cachegrind run costs
# 8.6s (`check`) to 11.0s (`build`) against ~2-3s for a hello run, so four project arms
# would take this gate from ~11s to ~50s and out of its registered `cost = "cheap"`
# merge-tier class. The project-scale Ir signal lives in the ratio ladders above and in
# compiler/PERF-BASELINE.md's `## Table`. This is a known, stated gap, not an oversight.
#
# CEILING DERIVATION (measured on the sprint-10 box, same method as test/perf_baseline.sh's
# `ir_of`: `valgrind --tool=cachegrind --cache-sim=no --branch-sim=no`, with
# GC_INITIAL_HEAP_SIZE pinned to 1GiB; two back-to-back runs per verb, on
# test/native_cli_fixtures/run/hello.mdk, at sprint/hold-the-gains base 696450f05):
#
#   verb    run 1        run 2        spread    CEIL (= measured x1.20, rounded up to 5M)
#   check   608,364,935  608,364,935  0.000%    735,000,000
#   build   432,798,160  432,798,346  0.00004%  520,000,000
#   run     650,931,402  650,931,287  0.00002%  785,000,000
#   test    417,591,437  417,591,437  0.000%    505,000,000
#
# The 20% headroom convention is inherited unchanged from this gate's original `check`
# arm: enough to absorb legitimate prelude/typecheck/emit drift across future slices
# without flaking, while still catching the multi-tens-of-percent constant-factor
# regression class the perf epic exists to prevent. For scale, the pre-fix `check` figure
# this gate was born to catch (~1,382,929,374 Ir at b6d029cd) is +88% over its ceiling.
#
# Note that these four numbers are all LOWER than compiler/PERF-BASELINE.md's `## Table`
# (regenerated 49cf34646, 2026-08-31: check 625M, build 621M, run 845M, test 606M). The
# `## Table` predates an unrelated `test-vehicle-floor` sprint merging into main; the
# numbers here are the freshly measured ones for THIS tree and are what the ceilings are
# derived from. Neither set is wrong; they describe different trees.
#
# WHY EACH ARM EARNS ITS PLACE:
#   check  — front-door load+resolve+typecheck+policy cost; the original arm.
#   build  — adds Core IR lowering and LLVM emission. Cachegrind does NOT trace the
#            forked `clang` child, so this Ir is the compiler's OWN cost, not clang's.
#   run    — the eval engine's cost; the only arm that grades compiler/eval/eval.mdk's
#            interpreter, which `check` and `build` never enter.
#   test   — the doctest/property driver's load+scan path (hello has no doctests, so this
#            arm grades the FIXED cost of getting to "no doctests found", which is
#            exactly the constant factor this gate is about).
#
# Usage:  sh test/diff_compiler_check_ir_floor.sh
#         CHECK_IR_CEIL=<n> sh test/diff_compiler_check_ir_floor.sh   # per-verb override
#         BUILD_IR_CEIL / RUN_IR_CEIL / TEST_IR_CEIL                  # ... for testing
# Exit:   0 every measured Ir is at or under its ceiling
#         1 any verb over ceiling, or the harness could not measure something (never a
#           silent no-op)
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

# CEILINGS — see the derivation table above. Each is ~20% over a value measured on this
# tree. Do NOT quietly bump one if it starts failing — re-measure, understand what
# regrew, and only then adjust WITH a comment (same discipline as
# diff_compiler_ir_size.sh).
CEIL_check="${CHECK_IR_CEIL:-735000000}"
CEIL_build="${BUILD_IR_CEIL:-520000000}"
# `run` re-measured 2026-09-02 at 791,372,632 Ir after the effects-lane PR (#2491): the
# prelude grew by the `Deferred*` family (3 interfaces, `deferFlatMap`/`deferWhen`/
# `deferUnless`) and `run` type-checks and elaborates the prelude, so ~0.8% more Ir is
# the size of the prelude, not an algorithmic regression (the one such regression that
# PR introduced — a per-signed-clause polarity-table scan — was removed, which is what
# brought `check` back under its unchanged ceiling). New ceiling ~1.1% over the measured.
CEIL_run="${RUN_IR_CEIL:-800000000}"
CEIL_test="${TEST_IR_CEIL:-505000000}"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/mdk-checkirfloor.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT INT TERM

# measure_ir VERB -> echoes the cachegrind Ir total, or "" if it could not be read.
# The heap is pinned so allocator growth policy cannot make the count workload-dependent.
measure_ir() {
  _verb="$1"
  GC_INITIAL_HEAP_SIZE=1073741824
  export GC_INITIAL_HEAP_SIZE
  case "$_verb" in
    check) set -- "$MEDAKA" check "$HELLO_FILE" ;;
    build) set -- "$MEDAKA" build "$HELLO_FILE" -o "$WORK/hello.bin" ;;
    run)   set -- "$MEDAKA" run "$HELLO_FILE" ;;
    test)  set -- "$MEDAKA" test "$HELLO_FILE" ;;
    *)     echo "measure_ir: unknown verb '$_verb'" >&2; return 1 ;;
  esac
  valgrind --tool=cachegrind --cache-sim=no --branch-sim=no \
    --cachegrind-out-file="$WORK/cg.$_verb.out" \
    "$@" >/dev/null 2>"$WORK/vg.$_verb.err"
  _vg_status=$?
  unset GC_INITIAL_HEAP_SIZE
  if [ "$_vg_status" -ne 0 ]; then
    printf 'measure_ir: wrapped `medaka %s` exited %s under valgrind — not grading a corrupted Ir count.\n' "$_verb" "$_vg_status" >&2
    return 1
  fi
  grep -a 'I  *refs:' "$WORK/vg.$_verb.err" | sed 's/.*I *refs: *//' | tr -d ' ,'
}

fails=0
measured=0

for verb in check build run test; do
  eval "ceil=\$CEIL_$verb"
  ir="$(measure_ir "$verb")"

  case "$ir" in
    ''|*[!0-9]*)
      printf 'FAIL: could not measure cachegrind Ir for `medaka %s` on hello — harness bug.\n' "$verb" >&2
      cat "$WORK/vg.$verb.err" >&2
      fails=$((fails + 1))
      continue
      ;;
  esac

  measured=$((measured + 1))

  if [ "$ir" -gt "$ceil" ]; then
    printf 'FAIL (CEILING): hello-world `%s` cost %s Ir, over the %s ceiling.\n' "$verb" "$ir" "$ceil"
    fails=$((fails + 1))
  else
    printf 'PASS: hello-world `%s` = %s Ir (ceiling %s).\n' "$verb" "$ir" "$ceil"
  fi
done

if [ "$measured" -eq 0 ]; then
  echo "FAIL: measured nothing at all — this gate must never be a silent no-op." >&2
  exit 1
fi

if [ "$fails" -gt 0 ]; then
  printf '\n%s verb(s) over ceiling or unmeasurable.\n' "$fails"
  printf '  This is the constant-factor-regression class this gate ratchets against\n'
  printf '  (epic #2036): a CLI verb'\''s fixed startup/typecheck/emit/eval cost regrew.\n'
  printf '  Compare against compiler/PERF-BASELINE.md and re-run test/perf_baseline.sh to\n'
  printf '  see where the instructions went. Do NOT just raise the ceiling — find what regrew.\n'
  exit 1
fi

printf '\nall %s verb(s) under ceiling.\n' "$measured"
exit 0
