#!/bin/sh
# shell-because: instrumentation — valgrind/cachegrind/wall-clock instrumentation plus statistics; wrap gains nothing
# diff_compiler_emitted_code_floor.sh — the FIRST absolute gate on what the
# native backend actually EMITS: binary size (bytes) and running-time
# cachegrind Ir, per fixture. Epic #2036 G1 (constant-factor axis) / G2
# (emitted code has no coverage). Modeled on the two existing absolute-
# ceiling precedents — do not invent a third shape:
#   test/wasm/diff_wasm_emitted_size.sh    — bytes ceiling, wasm's equivalent
#   test/diff_compiler_check_ir_floor.sh   — Ir ceiling + this determinism
#                                             argument's shape
#
# CORPUS: two whole-program fixtures already used by test/bench.sh and
# test/bench_fixtures/c/*.c's C sanity ceilings — fib.mdk (pure compute, no
# heap alloc) and bintrees.mdk (ADT/GC pressure) — chosen for the same
# "hello.mdk"-style single-fixture economy the two precedent gates use, not a
# sweep: cost = "cheap", two fixtures, two metrics each, no scaling ladder.
# fib and bintrees were picked specifically because they are the two
# fixtures test/bench_fixtures/c/*.c already gives a hand-written C
# equivalent for, so a future reader comparing this gate's ceilings against
# that C sanity ceiling is comparing the same two programs.
#
# WHY AN ABSOLUTE CEILING IS SOUND HERE, AND WHY IT NEEDS MORE HEADROOM THAN
# diff_compiler_check_ir_floor.sh: cachegrind Ir for a fixed program on a
# fixed BINARY is deterministic — it counts retired instructions, not
# wall-clock. But this gate's subject binary is not fixed the way
# check_ir_floor's `medaka` binary is: it is itself the OUTPUT of `medaka
# build`, i.e. of `clang` compiling this tree's emitted LLVM IR. CI's
# ubuntu-latest clang is not this box's Debian clang 19 — codegen decisions
# (inlining, register allocation, instruction selection) can legitimately
# differ across clang versions/targets in a way check_ir_floor's own-process
# Ir count never faces (there is no second compiler between "the fixed
# binary" and "the Ir it retires"). This is a HEADROOM problem, not a metric
# problem: bytes and Ir are still the right absolute things to ceiling, they
# just need room for cross-toolchain drift on top of the usual
# regression-vs-ceiling margin.
#
# CEILING DERIVATION (measured on this box, sprint-branch head b0061717a,
# Debian clang 19.1.7; two back-to-back runs per fixture, GC_INITIAL_HEAP_SIZE
# pinned to 1GiB like check_ir_floor's measure_ir, same
# `valgrind --tool=cachegrind --cache-sim=no --branch-sim=no` method):
#
#   fixture    bytes   Ir run 1       Ir run 2       spread     CEIL (bytes, x1.2, round to 1K) / CEIL (Ir, x1.2, round to 5M)
#   fib        18432   2,913,500,084  2,913,500,002  0.000003%  23,000 / 3,500,000,000
#   bintrees   18560   2,396,152,784  2,396,146,781  0.00025%   23,000 / 2,880,000,000
#
# The 20% headroom is the same convention check_ir_floor uses, on top of
# which this gate carries the extra cross-toolchain risk noted above: if the
# first CI run reds on a cross-toolchain delta rather than a real
# regression, that is the EXPECTED discovery for this gate (not a bug) —
# widen with the reason recorded, do not switch metrics or drop the gate.
#
# Usage:  sh test/diff_compiler_emitted_code_floor.sh
#         FIB_BYTES_CEIL / BINTREES_BYTES_CEIL / FIB_IR_CEIL / BINTREES_IR_CEIL
#                                                             — per-metric override
# Exit:   0 every measured metric is at or under its ceiling
#         1 any metric over ceiling, or the harness could not measure something
#         2 native medaka/emitter/valgrind not available (opt-in skip, same as
#           the other cachegrind-based gates)
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MEDAKA="$ROOT/medaka"
EMITTER="${MEDAKA_EMITTER:-$ROOT/medaka_emitter}"
FIB_SRC="$ROOT/test/bench_fixtures/fib.mdk"
BINTREES_SRC="$ROOT/test/bench_fixtures/bintrees.mdk"

[ -x "$MEDAKA" ]  || { echo "build native first: make medaka (missing $MEDAKA)"; exit 2; }
[ -x "$EMITTER" ] || { echo "build native first: make medaka (missing $EMITTER)"; exit 2; }
[ -f "$FIB_SRC" ] || { echo "missing fixture: $FIB_SRC"; exit 2; }
[ -f "$BINTREES_SRC" ] || { echo "missing fixture: $BINTREES_SRC"; exit 2; }
command -v valgrind >/dev/null 2>&1 || { echo "no valgrind on PATH — required for the Ir co-metric"; exit 2; }

export MEDAKA_ROOT="$ROOT" MEDAKA_EMITTER="$EMITTER"

# CEILINGS — see the derivation table above. Do NOT quietly bump one if it
# starts failing — re-measure, understand what regrew (or confirm it is
# cross-toolchain drift), and only then adjust WITH a comment.
CEIL_fib_bytes="${FIB_BYTES_CEIL:-23000}"
CEIL_bintrees_bytes="${BINTREES_BYTES_CEIL:-23000}"
CEIL_fib_ir="${FIB_IR_CEIL:-3500000000}"
CEIL_bintrees_ir="${BINTREES_IR_CEIL:-2880000000}"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/mdk-emittedfloor.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT INT TERM

# measure FIXTURE SRC -> sets $M_BYTES and $M_IR, or leaves both empty on
# failure. The heap is pinned so allocator growth policy cannot make the
# count workload-dependent (same rationale as check_ir_floor's measure_ir).
measure() {
  _name="$1"; _src="$2"
  _bin="$WORK/$_name.bin"
  M_BYTES=""
  M_IR=""
  if ! MEDAKA_STRICT=1 "$MEDAKA" build "$_src" -o "$_bin" >/dev/null 2>"$WORK/build.$_name.err"; then
    printf 'measure: `medaka build %s` failed — not grading a fixture that will not build.\n' "$_src" >&2
    cat "$WORK/build.$_name.err" >&2
    return 1
  fi
  M_BYTES="$(wc -c <"$_bin" | tr -d ' ')"

  GC_INITIAL_HEAP_SIZE=1073741824
  export GC_INITIAL_HEAP_SIZE
  valgrind --tool=cachegrind --cache-sim=no --branch-sim=no \
    --cachegrind-out-file="$WORK/cg.$_name.out" \
    "$_bin" >/dev/null 2>"$WORK/vg.$_name.err"
  _vg_status=$?
  unset GC_INITIAL_HEAP_SIZE
  if [ "$_vg_status" -ne 0 ]; then
    printf 'measure: `%s` exited %s under valgrind — not grading a corrupted Ir count.\n' "$_bin" "$_vg_status" >&2
    return 1
  fi
  M_IR="$(grep -a 'I  *refs:' "$WORK/vg.$_name.err" | sed 's/.*I *refs: *//' | tr -d ' ,')"
}

fails=0
measured=0

for pair in "fib:$FIB_SRC" "bintrees:$BINTREES_SRC"; do
  name="${pair%%:*}"
  src="${pair#*:}"
  eval "ceil_bytes=\$CEIL_${name}_bytes"
  eval "ceil_ir=\$CEIL_${name}_ir"

  if ! measure "$name" "$src"; then
    printf 'FAIL: could not measure `%s` — harness bug or build failure.\n' "$name" >&2
    fails=$((fails + 1))
    continue
  fi

  case "$M_BYTES" in
    ''|*[!0-9]*)
      printf 'FAIL: could not read binary size for `%s`.\n' "$name" >&2
      fails=$((fails + 1))
      continue
      ;;
  esac
  case "$M_IR" in
    ''|*[!0-9]*)
      printf 'FAIL: could not measure cachegrind Ir for `%s`.\n' "$name" >&2
      cat "$WORK/vg.$name.err" >&2
      fails=$((fails + 1))
      continue
      ;;
  esac

  measured=$((measured + 1))

  if [ "$M_BYTES" -gt "$ceil_bytes" ]; then
    printf 'FAIL (CEILING): %s binary is %s bytes, over the %s ceiling.\n' "$name" "$M_BYTES" "$ceil_bytes"
    fails=$((fails + 1))
  else
    printf 'PASS: %s binary = %s bytes (ceiling %s).\n' "$name" "$M_BYTES" "$ceil_bytes"
  fi

  if [ "$M_IR" -gt "$ceil_ir" ]; then
    printf 'FAIL (CEILING): %s run cost %s Ir, over the %s ceiling.\n' "$name" "$M_IR" "$ceil_ir"
    fails=$((fails + 1))
  else
    printf 'PASS: %s run = %s Ir (ceiling %s).\n' "$name" "$M_IR" "$ceil_ir"
  fi
done

if [ "$measured" -eq 0 ]; then
  echo "FAIL: measured nothing at all — this gate must never be a silent no-op." >&2
  exit 1
fi

if [ "$fails" -gt 0 ]; then
  printf '\n%s check(s) over ceiling or unmeasurable.\n' "$fails"
  printf '  This is the emitted-code-cost regression class this gate ratchets against\n'
  printf '  (epic #2036 G1/G2): the native backend'\''s emitted binary grew, or the\n'
  printf '  program it runs got more expensive. If this is a fresh CI runner'\''s clang\n'
  printf '  disagreeing with this box'\''s, re-derive the ceiling with the reason recorded\n'
  printf '  in this file'\''s header — do not just raise it silently.\n'
  exit 1
fi

printf '\nall %s fixture(s) under ceiling.\n' "$measured"
exit 0
