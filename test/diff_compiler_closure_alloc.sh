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

build_one flat && check_probe flat flat 33000000
build_one where_nocapture && check_probe where_nocapture where-nocapture 33000000
build_one eta && check_probe eta eta 2000000

check_threshold flat flat-alloc-baseline
check_threshold where_nocapture where-nocapture-alloc
check_threshold eta eta-closure-alloc

if [ "$checked" -lt 6 ]; then
  echo "FAIL anti-rot floor: checked $checked, expected at least 6"
  fail=$((fail + 1))
fi

if [ "$fail" -eq 0 ]; then
  echo "closure_alloc: PASS ($checked checks)"
else
  echo "closure_alloc: FAILED ($fail of $checked checks)"
fi
exit "$fail"
