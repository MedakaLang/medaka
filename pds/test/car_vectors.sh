#!/bin/sh
# P1-C pure verified blockstore and strict atproto-profile CARv1 on all engines.
set -eu

ROOT=${MEDAKA_ROOT:?set MEDAKA_ROOT to the repo root}
MEDAKA=${MEDAKA:-"$ROOT/medaka"}
DRIVER="$ROOT/pds/test/car_vectors_main.mdk"
PERF_DRIVER="$ROOT/pds/test/performance_resource_main.mdk"
WASM_EMITTER=${MEDAKA_WASM_EMITTER:-"$ROOT/test/bin/wasm_emit_modules_main"}
WORK=$(mktemp -d "${TMPDIR:-/tmp}/pds-car.XXXXXX")
trap 'rm -rf "$WORK"' EXIT HUP INT TERM

fail() {
  echo "FAIL: $1" >&2
  exit 1
}

require_empty() {
  [ ! -s "$1" ] || {
    cat "$1" >&2
    fail "$2 emitted stderr"
  }
}

[ -x "$MEDAKA" ] || fail "build medaka first (missing $MEDAKA)"

sh "$ROOT/pds/test/vector_provenance.sh" --files-for P1-C-CAR-STORE > "$WORK/vector-files"
[ "$(wc -l < "$WORK/vector-files" | tr -d ' ')" = 1 ] || fail 'expected exactly one ledger-owned P1-C corpus'
CORPUS_REL=$(sed -n '1p' "$WORK/vector-files")
CORPUS="$ROOT/$CORPUS_REL"

if ! MEDAKA_ROOT="$ROOT" MEDAKA_STRICT=1 "$MEDAKA" run "$DRIVER" "$CORPUS" > "$WORK/eval.out" 2> "$WORK/eval.err"; then
  cat "$WORK/eval.out" >&2
  cat "$WORK/eval.err" >&2
  fail 'eval driver failed'
fi
require_empty "$WORK/eval.err" eval
grep -F -q 'external: 1/1 official-atproto CAR cases' "$WORK/eval.out" || fail 'eval did not grade the external CAR'
grep -F -q 'success: 4/4 interoperability routes' "$WORK/eval.out" || fail 'eval interoperability route count is incomplete'
grep -F -q 'hostile: 12/12 rejected on named routes' "$WORK/eval.out" || fail 'eval hostile route count is incomplete'
[ "$(tail -1 "$WORK/eval.out")" = 'TOTAL: PASS' ] || fail 'eval did not end in TOTAL: PASS'

for label in canonical-reencode identical-duplicate arbitrary-order unrelated-block; do
  grep -F -q "SUCCESS $label PASS" "$WORK/eval.out" || fail "eval missed success route $label"
done

for label in nonminimal-varint overflow-varint zero-section overlong-section truncation \
  trailing-corruption wrong-version wrong-header malformed-cid nonblessed-cid \
  missing-root cid-mismatch
do
  grep -F -q "HOSTILE $label PASS route=" "$WORK/eval.out" || fail "eval missed exceptional route $label"
done

if ! MEDAKA_ROOT="$ROOT" MEDAKA_STRICT=1 "$MEDAKA" build "$DRIVER" -o "$WORK/native" > "$WORK/native-build.log" 2>&1; then
  cat "$WORK/native-build.log" >&2
  fail 'native driver build failed'
fi
"$WORK/native" "$CORPUS" > "$WORK/native.out" 2> "$WORK/native.err"
require_empty "$WORK/native.err" native
cmp "$WORK/eval.out" "$WORK/native.out" || fail 'eval and native normalized output differ'

if [ ! -x "$WASM_EMITTER" ] || ! command -v node >/dev/null 2>&1 || ! command -v wasm-tools >/dev/null 2>&1; then
  [ "${MEDAKA_REQUIRE_WASM:-0}" != 1 ] || fail 'Wasm is required but emitter/node/wasm-tools is unavailable'
  ENGINE_GRADE='eval == native; Wasm unavailable'
else
  if ! MEDAKA_ROOT="$ROOT" MEDAKA_WASM_EMITTER="$WASM_EMITTER" MEDAKA_STRICT=1 "$MEDAKA" build --target wasm "$DRIVER" -o "$WORK/driver.wasm" > "$WORK/wasm-build.log" 2>&1; then
    cat "$WORK/wasm-build.log" >&2
    fail 'Wasm driver build failed'
  fi
  MDK_ARGS="$CORPUS" node "$ROOT/test/wasm/run.js" "$WORK/driver.wasm" > "$WORK/wasm-raw.out" 2> "$WORK/wasm.err"
  require_empty "$WORK/wasm.err" wasm
  [ "$(tail -1 "$WORK/wasm-raw.out")" = 0 ] || fail 'Wasm runner result was not zero'
  sed '$d' "$WORK/wasm-raw.out" > "$WORK/wasm.out"
  cmp "$WORK/native.out" "$WORK/wasm.out" || fail 'native and Wasm normalized output differ'
  ENGINE_GRADE='eval == native == Wasm'
fi

if ! MEDAKA_ROOT="$ROOT" MEDAKA_STRICT=1 "$MEDAKA" build "$PERF_DRIVER" -o "$WORK/perf-native" > "$WORK/perf-build.log" 2>&1; then
  cat "$WORK/perf-build.log" >&2
  fail 'CAR scaling/resource driver build failed'
fi

"$WORK/perf-native" limits > "$WORK/limits.out"
grep -F -q 'limits: 7/7 adjacent controls; 7/7 hostile routes' "$WORK/limits.out" || fail 'resource ceiling controls incomplete'
[ "$(tail -1 "$WORK/limits.out")" = 'LIMITS: PASS' ] || fail 'resource ceiling controls failed'

measure_car() {
  label=$1
  size=$2
  start=$(perl -MTime::HiRes=time -e 'printf "%.6f", time')
  "$WORK/perf-native" car "$size" > "$WORK/$label.out"
  finish=$(perl -MTime::HiRes=time -e 'printf "%.6f", time')
  grep -F -q "CAR $size " "$WORK/$label.out" || fail "CAR scaling route failed at $size blocks"
  awk -v start="$start" -v finish="$finish" 'BEGIN { printf "%.6f", finish - start }'
}

CAR_SMALL=$(measure_car car-1000 1000)
CAR_LARGE=$(measure_car car-2000 2000)
if ! awk -v small="$CAR_SMALL" -v large="$CAR_LARGE" 'BEGIN {
  ratio = large / small
  exit ! (large <= 12.0 && ratio <= 3.2)
}'; then
  fail "CAR scaling exceeded bounds: 1000=$CAR_SMALL s 2000=$CAR_LARGE s"
fi
echo "CAR scaling: 1000=$CAR_SMALL s 2000=$CAR_LARGE s"

echo "PASS: CAR — 1 official-atproto fixture; 4 success routes; 12 hostile routes; $ENGINE_GRADE"
