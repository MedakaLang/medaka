#!/bin/sh
# diff_compiler_stack_overflow.sh — P0-2(a)+(b) "no silent death" regression.
#
# Deep non-tail recursion and non-productive self-referential values used to die
# with a BARE SIGBUS/SIGSEGV and ZERO output on both `medaka run` (the
# tree-walking interpreter recurses on the host C stack with no TCO) and `medaka
# build`+exec (the compiled program overflows the 256 MB worker stack, or a
# cyclic native thunk faults on a wild self-reference). This gate locks that
# every such death is now a CLEAN, CODED, nonzero-exit diagnostic — never a raw
# signal. The distinguishing signal is a `runtime error [E-...]` message on
# stderr AND a nonzero exit (a raw signal death has neither).
#
# Three mechanisms are exercised:
#   - E-STACK-OVERFLOW: eval depth guard (run) + native signal backstop (build).
#   - E-CYCLIC-VALUE:   forceCell black-holing (run only; the compiled binary has
#                       no interpreter, so its cyclic fault is caught by the same
#                       native signal backstop and reported as a coded message —
#                       E-STACK-OVERFLOW or E-FATAL-SIGNAL — which is still a
#                       clean coded death, not a silent one).
#
# Cases:
#   deep_recursion — run trips E-STACK-OVERFLOW (depth guard); build+exec trips
#                    E-STACK-OVERFLOW (signal backstop). Both nonzero.
#   cyclic_value   — run traps E-CYCLIC-VALUE; build+exec is nonzero with SOME
#                    coded `runtime error [E-...]` (never a silent signal).
#   deep_ok        — a moderately-deep-but-finite program (below the guard limit):
#                    run and build+exec both print 10000, exit 0 (proves the
#                    guard/backstop do not perturb legitimate execution).
#
# Usage:  sh test/diff_compiler_stack_overflow.sh
# Exit:   0 all cases pass; 1 on any mismatch; 2 if native medaka/emitter/clang
#         missing (opt-in skip, same discipline as the other build gates).
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MEDAKA="$ROOT/medaka"
EMITTER="${MEDAKA_EMITTER:-$ROOT/medaka_emitter}"
FIX="$ROOT/test/stack_overflow_fixtures"
CC="${CC:-clang}"

[ -x "$MEDAKA" ]  || { echo "build native first: make medaka (missing $MEDAKA)"; exit 2; }
[ -x "$EMITTER" ] || { echo "build native first: make medaka (missing $EMITTER)"; exit 2; }
command -v "$CC" >/dev/null 2>&1 || { echo "no C compiler ($CC) on PATH — skipping"; exit 2; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
pass=0; fail=0

bound() { perl -e 'alarm 90; exec @ARGV' "$@"; }

# assert: run AND build+exec both exit nonzero AND both emit `pattern` on stderr.
check_trap() {
  name="$1"; pattern="$2"; src="$FIX/$name.mdk"; bin="$TMP/$name.bin"

  bound "$MEDAKA" run "$src" >"$TMP/$name.run.out" 2>"$TMP/$name.run.err"
  run_code=$?
  bound env MEDAKA_ROOT="$ROOT" MEDAKA_EMITTER="$EMITTER" "$MEDAKA" build "$src" -o "$bin" \
    >"$TMP/$name.build.out" 2>"$TMP/$name.build.err"
  if [ $? -ne 0 ]; then
    fail=$((fail+1)); printf 'FAIL %-16s (build did not compile)\n' "$name"; return
  fi
  bound "$bin" >"$TMP/$name.exec.out" 2>"$TMP/$name.exec.err"
  exec_code=$?

  if [ "$run_code" -ne 0 ] && grep -q "$pattern" "$TMP/$name.run.err" \
     && [ "$exec_code" -ne 0 ] && grep -q "$pattern" "$TMP/$name.exec.err"; then
    pass=$((pass+1)); printf 'ok   %-16s (run=%s build+exec=%s, both %s)\n' "$name" "$run_code" "$exec_code" "$pattern"
  else
    fail=$((fail+1))
    printf 'FAIL %-16s run=%s(%s) exec=%s(%s) want=%s\n' "$name" "$run_code" \
      "$(tr -d '\n' <"$TMP/$name.run.err" | head -c 70)" "$exec_code" \
      "$(tr -d '\n' <"$TMP/$name.exec.err" | head -c 70)" "$pattern"
  fi
}

# assert: run traps `run_pattern`; build+exec is nonzero with any coded diagnostic.
check_cyclic() {
  name="$1"; run_pattern="$2"; src="$FIX/$name.mdk"; bin="$TMP/$name.bin"

  bound "$MEDAKA" run "$src" >"$TMP/$name.run.out" 2>"$TMP/$name.run.err"
  run_code=$?
  bound env MEDAKA_ROOT="$ROOT" MEDAKA_EMITTER="$EMITTER" "$MEDAKA" build "$src" -o "$bin" \
    >"$TMP/$name.build.out" 2>"$TMP/$name.build.err"
  if [ $? -ne 0 ]; then
    fail=$((fail+1)); printf 'FAIL %-16s (build did not compile)\n' "$name"; return
  fi
  bound "$bin" >"$TMP/$name.exec.out" 2>"$TMP/$name.exec.err"
  exec_code=$?

  if [ "$run_code" -ne 0 ] && grep -q "$run_pattern" "$TMP/$name.run.err" \
     && [ "$exec_code" -ne 0 ] && grep -q 'runtime error \[E-' "$TMP/$name.exec.err"; then
    pass=$((pass+1)); printf 'ok   %-16s (run=%s %s; build+exec=%s coded)\n' "$name" "$run_code" "$run_pattern" "$exec_code"
  else
    fail=$((fail+1))
    printf 'FAIL %-16s run=%s(%s) exec=%s(%s) want run=%s\n' "$name" "$run_code" \
      "$(tr -d '\n' <"$TMP/$name.run.err" | head -c 70)" "$exec_code" \
      "$(tr -d '\n' <"$TMP/$name.exec.err" | head -c 70)" "$run_pattern"
  fi
}

# assert: run and build+exec both exit 0 with matching stdout (guard/backstop inert).
check_ok() {
  name="$1"; expected="$2"; src="$FIX/$name.mdk"; bin="$TMP/$name.bin"

  run_out="$(bound "$MEDAKA" run "$src" 2>/dev/null)"; run_code=$?
  bound env MEDAKA_ROOT="$ROOT" MEDAKA_EMITTER="$EMITTER" "$MEDAKA" build "$src" -o "$bin" \
    >/dev/null 2>"$TMP/$name.build.err"
  if [ $? -ne 0 ]; then fail=$((fail+1)); printf 'FAIL %-16s (build)\n' "$name"; return; fi
  exec_out="$(bound "$bin" 2>/dev/null)"; exec_code=$?

  if [ "$run_code" -eq 0 ] && [ "$exec_code" -eq 0 ] \
     && [ "$run_out" = "$expected" ] && [ "$exec_out" = "$expected" ]; then
    pass=$((pass+1)); printf 'ok   %-16s (run=build+exec=%s)\n' "$name" "$expected"
  else
    fail=$((fail+1))
    printf 'FAIL %-16s run=%s/%s exec=%s/%s exp=%s\n' "$name" "$run_code" "$run_out" "$exec_code" "$exec_out" "$expected"
  fi
}

check_trap   deep_recursion 'E-STACK-OVERFLOW'
check_cyclic cyclic_value   'E-CYCLIC-VALUE'
check_ok     deep_ok        10000

echo
printf 'diff_compiler_stack_overflow.sh: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
