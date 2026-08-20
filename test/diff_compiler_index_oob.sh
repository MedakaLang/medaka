#!/bin/sh
# diff_compiler_index_oob.sh — #1787 E-INDEX-OOB message parity, run vs build+exec.
#
# The prelude's `impl Index (Array a) Int a` / `impl IndexMut …` (and String's and
# MutArray's) guard every `a[i]` and `a[i] := v`.  Until #1787 they raised
# `indexError` with an INTERPOLATED message that the native backend then THREW AWAY:
# @mdk_oob takes no argument, so the same program printed
#
#   run:            runtime error [E-INDEX-OOB]: index 7 out of bounds
#   build+exec:     runtime error [E-INDEX-OOB]: index out of bounds
#
# for years, and nothing noticed.  #1787 routes the guards through `indexErrorAt`,
# whose abort (@mdk_oob_at / $mdk_write_err_int) formats the index itself.  This gate
# locks that the two engines now print the SAME line, INCLUDING the number.
#
# ── WHY THIS IS ITS OWN GATE AND NOT A DOCTEST ────────────────────────────────
# EVERY DOCTEST RUNS UNDER THE INTERPRETER, AND THE INTERPRETER WAS THE ENGINE THAT
# WAS ALREADY RIGHT.  A doctest asserting `index 9 out of bounds` passed throughout
# the years native was printing something else — which is precisely how the
# divergence survived.  Only a real `build` + exec can see it, so this gate does one.
#
# diff_compiler_engines.sh cannot cover it either: its eval arm classifies ANY
# interpreter `runtime error [E-` as `na` (the interpreter has no `exit` primitive, so
# a nonzero exit is never a program-level exit), so an E-INDEX-OOB fixture is
# ledgered `eval:intended-abort` and never compared.  See test/ENGINE-DIVERGENCE.md.
#
# ── WHAT IS ASSERTED (never "nonzero", never "it aborted") ────────────────────
# Per the must-fail suite's doctrine, an assertion that accepts any failure launders
# an unrelated regression as evidence.  Each trapping case pins THREE things:
#   * exit code EXACTLY 1 — not "nonzero".  A SIGSEGV exits 139; a clean abort 1.
#   * stdout EMPTY.
#   * stderr EXACTLY the interpreter's own message, byte for byte, INCLUDING THE
#     INDEX.  Pinning the number and not just the E-INDEX-OOB code is the whole
#     point: the pre-#1787 native line carried the code and no number, and a guard
#     that fired on the wrong side of a boundary would still carry the code.
# `run`'s message has a `file:L:C:` prefix native aborts do not, so run is compared
# on the SUFFIX and build+exec on the WHOLE line.
#
# THE CONTROL (index_ok) IS LOAD-BEARING: it pins that every in-bounds index at the
# exact boundaries the guards must not reject — first (0) and last (len - 1), read
# AND write, Array + String + MutArray — still returns its value on BOTH engines.
# Without it, "fixing" this gate by making a guard reject everything reads as green.
# If the control breaks, the environment broke, not the bug.
#
# NOT COVERED HERE (deliberate): the WasmGC arm.  `--target wasm` needs a separately
# built emitter ($MEDAKA_WASM_EMITTER, via test/wasm/build_wasm_oracle.sh) that this
# gate's shard does not build — the same carve-out diff_compiler_slice_oob.sh makes.
# wasm's side of the SAME parity is held by test/wasm/fixtures_modules/w7_array_oob.mdk
# under test/wasm/diff_wasm_modules.sh, which since #531 compares stderr and exit code.
#
# Usage:  sh test/diff_compiler_index_oob.sh
# Exit:   0 all cases pass; 1 on any mismatch; 2 if native medaka/emitter/clang missing
#         (opt-in skip, same discipline as the other build gates).
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MEDAKA="${MEDAKA:-$ROOT/medaka}"
EMITTER="${MEDAKA_EMITTER:-$ROOT/medaka_emitter}"
FIX="$ROOT/test/index_oob_fixtures"
CC="${CC:-clang}"

[ -x "$MEDAKA" ]  || { echo "build native first: make medaka (missing $MEDAKA)"; exit 2; }
[ -x "$EMITTER" ] || { echo "build native first: make medaka (missing $EMITTER)"; exit 2; }
command -v "$CC" >/dev/null 2>&1 || { echo "no C compiler ($CC) on PATH — skipping"; exit 2; }
[ -d "$FIX" ] || { echo "missing fixture dir: $FIX"; exit 2; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
pass=0; fail=0

# `timeout` is coreutils-only (absent on macOS) — same perl shim the other gates use.
# NOTE it reports 142 on expiry where timeout reports 124; nothing here reads that.
bound() { perl -e 'alarm 60; exec @ARGV' "$@"; }

# assert a trapping fixture: run and build+exec BOTH abort with the exact E-INDEX-OOB
# line naming `idx`, exit exactly 1, and print nothing on stdout.
check_oob() {
  name="$1"; idx="$2"; src="$FIX/$name.mdk"; bin="$TMP/$name.bin"
  want="runtime error [E-INDEX-OOB]: index $idx out of bounds"

  bound "$MEDAKA" run "$src" >"$TMP/$name.run.out" 2>"$TMP/$name.run.err"
  run_code=$?
  bound env MEDAKA_ROOT="$ROOT" MEDAKA_EMITTER="$EMITTER" "$MEDAKA" build "$src" -o "$bin" \
    >"$TMP/$name.build.out" 2>"$TMP/$name.build.err"
  if [ $? -ne 0 ]; then
    fail=$((fail+1)); printf 'FAIL %-24s (build did not compile)\n' "$name"; return
  fi
  bound "$bin" >"$TMP/$name.exec.out" 2>"$TMP/$name.exec.err"
  exec_code=$?

  run_err="$(cat "$TMP/$name.run.err")"
  exec_err="$(cat "$TMP/$name.exec.err")"
  run_out="$(cat "$TMP/$name.run.out")"
  exec_out="$(cat "$TMP/$name.exec.out")"

  # run's line is `<file>:L:C: <want>`; native aborts carry no location prefix.
  run_ok=0
  [ "$run_code" -eq 1 ] && [ -z "$run_out" ] \
    && case "$run_err" in *": $want") run_ok=1 ;; esac
  exec_ok=0
  [ "$exec_code" -eq 1 ] && [ -z "$exec_out" ] && [ "$exec_err" = "$want" ] && exec_ok=1

  if [ "$run_ok" -eq 1 ] && [ "$exec_ok" -eq 1 ]; then
    pass=$((pass+1))
    printf 'ok   %-24s (run=build+exec=1, both "index %s out of bounds", stdout empty)\n' \
      "$name" "$idx"
  else
    fail=$((fail+1))
    printf 'FAIL %-24s want=%s\n' "$name" "$want"
    printf '       run  exit=%s stdout=%.40s stderr=%s\n' "$run_code" "$run_out" "$run_err"
    printf '       exec exit=%s stdout=%.40s stderr=%s\n' "$exec_code" "$exec_out" "$exec_err"
  fi
}

# assert the control: run and build+exec both exit 0 with identical, correct stdout.
check_ok() {
  name="$1"; src="$FIX/$name.mdk"; bin="$TMP/$name.bin"
  expected='5
7
50
70
a
c
8
9'

  run_out="$(bound "$MEDAKA" run "$src" 2>/dev/null)"; run_code=$?
  bound env MEDAKA_ROOT="$ROOT" MEDAKA_EMITTER="$EMITTER" "$MEDAKA" build "$src" -o "$bin" \
    >/dev/null 2>"$TMP/$name.build.err"
  if [ $? -ne 0 ]; then
    fail=$((fail+1)); printf 'CONTROL-BROKE %-14s (build)\n' "$name"; return
  fi
  exec_out="$(bound "$bin" 2>/dev/null)"; exec_code=$?

  if [ "$run_code" -eq 0 ] && [ "$exec_code" -eq 0 ] \
     && [ "$run_out" = "$expected" ] && [ "$exec_out" = "$expected" ]; then
    pass=$((pass+1))
    printf 'ok   %-24s (control: in-bounds boundaries, run == build+exec)\n' "$name"
  else
    fail=$((fail+1))
    printf 'CONTROL-BROKE %-14s an IN-BOUNDS index changed — a guard over-rejects, or the\n' "$name"
    printf '       environment broke. This is NOT the #1787 divergence reappearing.\n'
    printf '       run  exit=%s\n%s\n' "$run_code" "$run_out"
    printf '       exec exit=%s\n%s\n' "$exec_code" "$exec_out"
    printf '       want\n%s\n' "$expected"
  fi
}

check_oob index_oob_read      '9'
check_oob index_oob_write     '9'
check_oob index_oob_negative  '-3'
check_oob index_oob_string    '10'
check_oob index_oob_mut_array '4'
check_ok  index_ok

echo
printf 'diff_compiler_index_oob.sh: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
