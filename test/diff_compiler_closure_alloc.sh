#!/bin/sh
# #2237: regression pin for capture-free closure allocation (S-1 static-cell
# hoisting + S-2 eta-closure sweep).
#
# BEFORE S-1/S-2: a capture-free `where` binding or a bare top-level function
# passed as a value ("eta closure") allocated a fresh closure cell on every
# call — 32 bytes/call, so 2,000,000 calls cost ~64 MB. AFTER: the closure
# cell is hoisted to a constant global, so the same 2,000,000 calls cost a
# ONE-TIME 32 bytes total, independent of the call count.
#
# This gate builds three probes and asserts total allocBytes() for the
# capture-free/eta cases stays under a generous small-constant threshold —
# NOT exactly 32 (that would be brittle to incidental allocator bookkeeping),
# but far enough below the old 63,996,384-byte behavior that a regression
# cannot hide in the noise. 2,000,000 calls is chosen so the OLD per-call
# behavior blows past the threshold by four orders of magnitude.
set -u

ROOT="$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)"
MEDAKA="${MEDAKA_BIN:-$ROOT/medaka}"
FIX="$ROOT/test/closure_alloc_fixtures"
WORK="${TMPDIR:-/tmp}/medaka-closure-alloc-$$"
trap 'rm -rf "$WORK"' EXIT HUP INT TERM
mkdir -p "$WORK"

THRESHOLD=10000

[ -x "$MEDAKA" ] || {
  echo "SKIP: $MEDAKA not built — run: make medaka"
  exit 2
}

fail=0
checked=0
ok() { checked=$((checked + 1)); echo "ok   $1"; }
bad() { checked=$((checked + 1)); fail=$((fail + 1)); echo "FAIL $1: $2"; }
run_t() { perl -e 'alarm shift; exec @ARGV' "$@"; }

build_one() {
  name="$1"
  MEDAKA_STRICT=1 run_t 90 "$MEDAKA" build "$FIX/$name.mdk" -o "$WORK/$name" >"$WORK/$name.buildlog" 2>&1
  rc=$?
  if [ "$rc" -ne 0 ]; then
    bad "$name-build" "rc=$rc: $(tail -1 "$WORK/$name.buildlog")"
    return 1
  fi
  ok "$name-build"
  return 0
}

# build_indirect NAME — same as build_one, but keeps the emitted IR at
# $WORK/$name.ll (--keep-ir) so check_indirect_ir below can inspect the call
# shape at the escaping helper's call site.
build_indirect() {
  name="$1"
  MEDAKA_STRICT=1 run_t 90 "$MEDAKA" build "$FIX/$name.mdk" -o "$WORK/$name" --keep-ir \
    >"$WORK/$name.buildlog" 2>&1
  rc=$?
  if [ "$rc" -ne 0 ]; then
    bad "$name-build" "rc=$rc: $(tail -1 "$WORK/$name.buildlog")"
    return 1
  fi
  ok "$name-build"
  return 0
}

# check_result NAME LABEL EXPECTED — runs the built probe and asserts the
# printed result matches EXPECTED. Unlike check_probe, no allocBytes line is
# required: the #2241 escape fixtures below pin an IR SHAPE (direct vs.
# indirect call), not an allocation count.
check_result() {
  name="$1"
  label="$2"
  expected="$3"
  out="$(run_t 60 "$WORK/$name" 2>&1)"
  rc=$?
  if [ "$rc" -ne 0 ]; then
    bad "$name-run" "rc=$rc: $out"
    return 1
  fi
  result_line=$(echo "$out" | grep "^$label result=")
  if [ "$result_line" != "$label result=$expected" ]; then
    bad "$name-result" "expected '$label result=$expected', got '$result_line'"
    return 1
  fi
  ok "$name-result"
}

# check_indirect_ir NAME — #2241 end-of-sprint review finding: asserts the
# kept IR at $WORK/$name.ll shows the historical INDIRECT call shape (the
# escaping helper's closure cell code_ptr loaded and `inttoptr`'d, then
# called through the resulting pointer — emitIndirectCallWords/
# emitPapClosureIndirect/emitApplyAny) and NEVER a direct `call i64
# @mdk_lamN(` call — i.e. #2241's direct-call optimization (`e.directFn`)
# correctly declined to fire for this escaping occurrence.
#
# Scoped to THIS FIXTURE's own defines only (`@mdk_<name>__*` — the
# module-qualified mangling every top-level fn gets — plus
# `@mdk_program_main`, where a bare top-level `main` CAF is inlined): a
# whole-file grep false-positives on unrelated `@mdk_lamN` direct calls the
# prelude/stdlib legitimately makes elsewhere in the same build (#2241
# review: a prior version of this check matched interpolation/debug-format
# internals, not this fixture's own escaping call site).
check_indirect_ir() {
  name="$1"
  ll="$WORK/$name.ll"
  if [ ! -f "$ll" ]; then
    bad "$name-ir" "no kept IR at $ll"
    return 1
  fi
  scoped="$WORK/$name.scoped.ll"
  awk -v pfx="@mdk_${name}__" '
    /^define / { keep = (index($0, pfx) > 0 || index($0, "@mdk_program_main") > 0) }
    keep { print }
  ' "$ll" >"$scoped"
  if [ ! -s "$scoped" ]; then
    bad "$name-ir-scope" "no defines matched $pfx or @mdk_program_main in $ll"
    return 1
  fi
  if grep -Eq 'call i64 @mdk_lam[0-9]+\(' "$scoped"; then
    bad "$name-ir-no-direct" "found a direct @mdk_lamN call in this fixture's own code — escape case must stay indirect"
  else
    ok "$name-ir-no-direct"
  fi
  if grep -q 'inttoptr i64 .* to ptr' "$scoped"; then
    ok "$name-ir-indirect-shape"
  else
    bad "$name-ir-indirect-shape" "no code_ptr load/inttoptr found in this fixture's own code — expected the indirect call shape"
  fi
}

# check_probe NAME LABEL EXPECTED_RESULT — runs the built probe, asserts the
# printed result matches EXPECTED_RESULT (equivalence sanity: a divergent
# result means the probe isn't measuring the same computation), and writes
# the parsed allocBytes integer to $WORK/$name.alloc on success.
check_probe() {
  name="$1"
  label="$2"
  expected_result="$3"
  out="$(run_t 60 "$WORK/$name" 2>&1)"
  rc=$?
  if [ "$rc" -ne 0 ]; then
    bad "$name-run" "rc=$rc: $out"
    return 1
  fi
  result_line=$(echo "$out" | grep "^$label result=")
  alloc_line=$(echo "$out" | grep "^$label allocBytes=")
  if [ "$result_line" != "$label result=$expected_result" ]; then
    bad "$name-result" "expected '$label result=$expected_result', got '$result_line'"
    return 1
  fi
  ok "$name-result"
  alloc="${alloc_line#"$label allocBytes="}"
  alloc="${alloc%.0}"
  case "$alloc" in
    ''|*[!0-9]*)
      bad "$name-alloc-parse" "could not parse allocBytes from: $alloc_line"
      return 1
      ;;
  esac
  echo "$alloc" >"$WORK/$name.alloc"
  return 0
}

check_threshold() {
  name="$1"
  label="$2"
  if [ -f "$WORK/$name.alloc" ]; then
    alloc=$(cat "$WORK/$name.alloc")
    if [ "$alloc" -lt "$THRESHOLD" ]; then
      ok "$label (allocBytes=$alloc < $THRESHOLD)"
    else
      bad "$label" "allocBytes=$alloc (>= $THRESHOLD; per-call closure allocation returned)"
    fi
  fi
}

# check_min_alloc NAME LABEL — the inverse of check_threshold: asserts
# allocBytes stayed AT OR ABOVE THRESHOLD, i.e. the per-call allocation is
# still happening. Used for the capturing-lambda parity fixture, where
# staying above threshold (not below it) is the healthy state.
check_min_alloc() {
  name="$1"
  label="$2"
  if [ -f "$WORK/$name.alloc" ]; then
    alloc=$(cat "$WORK/$name.alloc")
    if [ "$alloc" -ge "$THRESHOLD" ]; then
      ok "$label (allocBytes=$alloc >= $THRESHOLD; still allocates per call)"
    else
      bad "$label" "allocBytes=$alloc (< $THRESHOLD; capturing lambda unexpectedly hoisted)"
    fi
  fi
}

build_one flat && check_probe flat flat 33000000
build_one where_nocapture && check_probe where_nocapture where-nocapture 33000000
build_one eta && check_probe eta eta 2000000
# CAPTURE CORRECTNESS (#2237 review finding F2): a genuinely-capturing
# `where` helper, called at three distinct call sites with three different
# captured values in the same run. VALUE assertion only — no
# check_threshold call, since a capturing closure legitimately allocates on
# every call and that is not what this fixture pins.
build_one capture_correctness && check_probe capture_correctness capture-correctness 13012011
# BARE-LAMBDA HOIST (#2255 item 2): a capture-free anonymous `x => ...`
# lambda literal (CLam) used as a first-class value -- the emitLamGo/
# emitLamPat path this slice hoists, distinct from eta.mdk's named-function
# eta-closure path.
build_one lambda_value_nocapture &&
  check_probe lambda_value_nocapture lambda-nocapture 2000000
# BARE-LAMBDA CAPTURE PARITY: the same construct but the lambda DOES close
# over an enclosing value, so it must still allocate a fresh cell every call.
build_one lambda_value_capture &&
  check_probe lambda_value_capture lambda-capture 1999999000000

# DIRECT-CALL ESCAPES (#2241 end-of-sprint review finding): a where-bound
# saturated-only-LOOKING local function that escapes via one of the four
# non-saturated occurrences satOnlyUses must reject — passed as an argument,
# returned, partially applied, over-applied — so each must still route
# through the historical indirect path, never #2241's direct-call
# optimization.
build_indirect direct_call_escape_argument && check_result direct_call_escape_argument escape-argument 12
check_indirect_ir direct_call_escape_argument
build_indirect direct_call_escape_returned && check_result direct_call_escape_returned escape-returned 7
check_indirect_ir direct_call_escape_returned
build_indirect direct_call_escape_partial && check_result direct_call_escape_partial escape-partial 15
check_indirect_ir direct_call_escape_partial
build_indirect direct_call_escape_overapplied && check_result direct_call_escape_overapplied escape-overapplied 15
check_indirect_ir direct_call_escape_overapplied

check_threshold flat flat-alloc-baseline
check_threshold where_nocapture where-nocapture-alloc
check_threshold eta eta-closure-alloc
check_threshold lambda_value_nocapture lambda-nocapture-alloc
check_min_alloc lambda_value_capture lambda-capture-alloc

if [ "$checked" -lt 10 ]; then
  echo "FAIL anti-rot floor: checked $checked, expected at least 10"
  fail=$((fail + 1))
fi

if [ "$fail" -eq 0 ]; then
  echo "closure_alloc: PASS ($checked checks)"
else
  echo "closure_alloc: FAILED ($fail of $checked checks)"
fi
exit "$fail"
