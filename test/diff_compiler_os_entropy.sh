#!/bin/sh
# #1726: native/eval OS-entropy contract and anti-rot structure.
# The value itself is intentionally nondeterministic, so this gate grades exact
# length/domain, loud rejection, and independence across fresh processes.
set -u

ROOT="$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)"
MEDAKA="$ROOT/medaka"
FIX="$ROOT/test/os_entropy_fixtures"
WORK="${TMPDIR:-/tmp}/medaka-os-entropy-$$"
trap 'rm -rf "$WORK"' EXIT HUP INT TERM
mkdir -p "$WORK"

[ -x "$MEDAKA" ] || {
  echo "SKIP: ./medaka not built — run: make medaka"
  exit 2
}

fail=0
checked=0
ok() { checked=$((checked + 1)); echo "ok   $1"; }
bad() { checked=$((checked + 1)); fail=$((fail + 1)); echo "FAIL $1: $2"; }
run_t() { perl -e 'alarm shift; exec @ARGV' "$@"; }

eval_a="$(MEDAKA_STRICT=1 run_t 30 "$MEDAKA" run "$FIX/positive.mdk" 2>&1)"
eval_a_rc=$?
eval_b="$(MEDAKA_STRICT=1 run_t 30 "$MEDAKA" run "$FIX/positive.mdk" 2>&1)"
eval_b_rc=$?
case "$eval_a:$eval_b" in
  ok:*:ok:*) ok eval-length-domain ;;
  *) bad eval-length-domain "expected two ok:<32-byte-list> results; got rc=$eval_a_rc [$eval_a], rc=$eval_b_rc [$eval_b]" ;;
esac
if [ "$eval_a_rc" -eq 0 ] && [ "$eval_b_rc" -eq 0 ] && [ "$eval_a" != "$eval_b" ]; then
  ok eval-fresh-process-independence
else
  bad eval-fresh-process-independence "fresh processes repeated or failed: [$eval_a] / [$eval_b]"
fi

MEDAKA_STRICT=1 run_t 60 "$MEDAKA" build "$FIX/positive.mdk" -o "$WORK/positive" >"$WORK/build-positive.log" 2>&1
build_rc=$?
if [ "$build_rc" -eq 0 ]; then ok native-build; else bad native-build "rc=$build_rc: $(tail -1 "$WORK/build-positive.log")"; fi
if [ "$build_rc" -eq 0 ]; then
  native_a="$(run_t 30 "$WORK/positive" 2>&1)"; native_a_rc=$?
  native_b="$(run_t 30 "$WORK/positive" 2>&1)"; native_b_rc=$?
  case "$native_a:$native_b" in
    ok:*:ok:*) ok native-length-domain ;;
    *) bad native-length-domain "expected two ok:<32-byte-list> results; got rc=$native_a_rc [$native_a], rc=$native_b_rc [$native_b]" ;;
  esac
  if [ "$native_a_rc" -eq 0 ] && [ "$native_b_rc" -eq 0 ] && [ "$native_a" != "$native_b" ]; then
    ok native-fresh-process-independence
  else
    bad native-fresh-process-independence "fresh processes repeated or failed: [$native_a] / [$native_b]"
  fi
else
  bad native-length-domain "positive binary was not built"
  bad native-fresh-process-independence "positive binary was not built"
fi

eval_neg="$(MEDAKA_STRICT=1 run_t 30 "$MEDAKA" run "$FIX/negative.mdk" 2>&1)"
eval_neg_rc=$?
case "$eval_neg_rc:$eval_neg" in
  0:*) bad eval-negative-length "unexpected success: [$eval_neg]" ;;
  *:*"osEntropyBytes: length must be non-negative"*) ok eval-negative-length ;;
  *) bad eval-negative-length "wrong failure rc=$eval_neg_rc: [$eval_neg]" ;;
esac

MEDAKA_STRICT=1 run_t 60 "$MEDAKA" build "$FIX/negative.mdk" -o "$WORK/negative" >"$WORK/build-negative.log" 2>&1
negative_build_rc=$?
if [ "$negative_build_rc" -ne 0 ]; then
  bad native-negative-build "rc=$negative_build_rc: $(tail -1 "$WORK/build-negative.log")"
else
  native_neg="$(run_t 30 "$WORK/negative" 2>&1)"
  native_neg_rc=$?
  case "$native_neg_rc:$native_neg" in
    0:*) bad native-negative-length "unexpected success: [$native_neg]" ;;
    *:*"osEntropyBytes: length must be non-negative"*) ok native-negative-length ;;
    *) bad native-negative-length "wrong failure rc=$native_neg_rc: [$native_neg]" ;;
  esac
fi

eval_large="$(MEDAKA_STRICT=1 run_t 30 "$MEDAKA" run "$FIX/too_large.mdk" 2>&1)"
eval_large_rc=$?
case "$eval_large_rc:$eval_large" in
  0:*) bad eval-large-length "unexpected success: [$eval_large]" ;;
  *:*"osEntropyBytes: requested length is too large"*) ok eval-large-length ;;
  *) bad eval-large-length "wrong failure rc=$eval_large_rc: [$eval_large]" ;;
esac

MEDAKA_STRICT=1 run_t 60 "$MEDAKA" build "$FIX/too_large.mdk" -o "$WORK/too-large" >"$WORK/build-too-large.log" 2>&1
large_build_rc=$?
if [ "$large_build_rc" -ne 0 ]; then
  bad native-large-build "rc=$large_build_rc: $(tail -1 "$WORK/build-too-large.log")"
else
  native_large="$(run_t 30 "$WORK/too-large" 2>&1)"
  native_large_rc=$?
  case "$native_large_rc:$native_large" in
    0:*) bad native-large-length "unexpected success: [$native_large]" ;;
    *:*"osEntropyBytes: requested length is too large"*) ok native-large-length ;;
    *) bad native-large-length "wrong failure rc=$native_large_rc: [$native_large]" ;;
  esac
fi

# Structural cells protect the security contract around the executable checks.
if grep -q '^extern osEntropyBytes : Int -> <Rand> Array Int$' "$ROOT/stdlib/runtime.mdk"; then
  ok effect-annotation
else
  bad effect-annotation "exact <Rand> declaration missing"
fi
if sed -n '/^externBindings _ = \[/,/^pDebugStringLit/p' "$ROOT/compiler/eval/eval.mdk" |
    grep -q '"osEntropyBytes"'; then
  bad oracle-isolation "binding leaked into deterministic externBindings"
else
  ok oracle-isolation
fi
if sed -n '/^testCapableExterns _ = \[/,/^]/p' "$ROOT/compiler/eval/eval.mdk" |
    grep -q '"osEntropyBytes"'; then
  bad test-isolation "binding leaked into testCapableExterns"
else
  ok test-isolation
fi
if sed -n '/^long long mdk_os_entropy_bytes(/,/^}/p' "$ROOT/runtime/medaka_rt.c" |
    grep -q 'mdk_next_u64'; then
  bad no-deterministic-fallback "OS entropy helper calls deterministic SplitMix"
else
  ok no-deterministic-fallback
fi
if grep -q '^osEntropyBytes	wasm	WASM-GAP	' "$ROOT/test/CAPABILITY-EXCEPTIONS.txt"; then
  ok wasm-decision
else
  bad wasm-decision "explicit WASM-GAP row missing"
fi

if [ "$checked" -lt 14 ]; then
  echo "FAIL anti-rot floor: checked $checked, expected at least 14"
  fail=$((fail + 1))
fi

if [ "$fail" -eq 0 ]; then
  echo "os_entropy: PASS ($checked checks)"
else
  echo "os_entropy: FAILED ($fail of $checked checks)"
fi
exit "$fail"
