#!/bin/sh
# P1-B deterministic atproto MST: official-reference roots/node bytes and
# strict hostile validation on eval, native, and Wasm.
set -eu

ROOT=${MEDAKA_ROOT:?set MEDAKA_ROOT to the repo root}
MEDAKA=${MEDAKA:-"$ROOT/medaka"}
DRIVER="$ROOT/pds/test/mst_vectors_main.mdk"
PERF_DRIVER="$ROOT/pds/test/performance_resource_main.mdk"
WASM_EMITTER=${MEDAKA_WASM_EMITTER:-"$ROOT/test/bin/wasm_emit_modules_main"}
WORK=$(mktemp -d "${TMPDIR:-/tmp}/pds-mst.XXXXXX")
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

sh "$ROOT/pds/test/vector_provenance.sh" --files-for P1-B-MST > "$WORK/vector-files"
[ "$(wc -l < "$WORK/vector-files" | tr -d ' ')" = 1 ] || fail 'expected exactly one ledger-owned P1-B corpus'
CORPUS_REL=$(sed -n '1p' "$WORK/vector-files")
CORPUS="$ROOT/$CORPUS_REL"

sh "$ROOT/pds/test/vector_provenance.sh" --files-for P1-B-MST-PROOF > "$WORK/proof-files"
[ "$(wc -l < "$WORK/proof-files" | tr -d ' ')" = 1 ] || fail 'expected exactly one ledger-owned covering-proof corpus'
PROOF_CORPUS="$ROOT/$(sed -n '1p' "$WORK/proof-files")"

if ! MEDAKA_ROOT="$ROOT" MEDAKA_STRICT=1 "$MEDAKA" run "$DRIVER" "$CORPUS" "$PROOF_CORPUS" > "$WORK/eval.out" 2> "$WORK/eval.err"; then
  cat "$WORK/eval.out" >&2
  cat "$WORK/eval.err" >&2
  fail 'eval driver failed'
fi
require_empty "$WORK/eval.err" eval
grep -F -q 'external: 11/11 official-reference cases' "$WORK/eval.out" || fail 'eval did not grade all external cases'
grep -F -q 'covering proofs: 17/17 official-reference rows' "$WORK/eval.out" || fail 'eval did not grade all covering-proof rows'
grep -F -q 'narrower than the whole tree: 13/17 proof rows' "$WORK/eval.out" || fail 'covering proofs did not stay narrower than the full node set'
grep -F -q 'hostile: 14/14 rejected on named routes' "$WORK/eval.out" || fail 'eval hostile route count is incomplete'
grep -F -q 'controls: 3/3 valid lexical neighbors' "$WORK/eval.out" || fail 'eval lexical controls are incomplete'
[ "$(tail -1 "$WORK/eval.out")" = 'TOTAL: PASS' ] || fail 'eval did not end in TOTAL: PASS'

for name in \
  empty leading-zero-bits-0 leading-zero-bits-2 leading-zero-bits-4 \
  leading-zero-bits-6 prefix-compression permutation-forward \
  permutation-reverse replace delete delete-to-empty
do
  grep -F -q "CASE $name PASS " "$WORK/eval.out" || fail "eval missed external case $name"
done

for label in empty-key duplicates depth order prefix undercompressed misplaced-left \
  misplaced-between misplaced-right misplaced-transitive malformed-links truncation \
  unreachable invalid-node
do
  grep -F -q "HOSTILE $label PASS route=" "$WORK/eval.out" || fail "eval missed exceptional route $label"
done

for name in proof-single-node proof-two-layer proof-three-layer
do
  grep -F -q "PROOFCASE $name " "$WORK/eval.out" || fail "eval missed covering-proof case $name"
done

for label in left-neighbor between-neighbor right-neighbor
do
  grep -F -q "MST CONTROL $label PASS" "$WORK/eval.out" || fail "eval missed lexical control $label"
done

if ! MEDAKA_ROOT="$ROOT" MEDAKA_STRICT=1 "$MEDAKA" build "$DRIVER" -o "$WORK/native" > "$WORK/native-build.log" 2>&1; then
  cat "$WORK/native-build.log" >&2
  fail 'native driver build failed'
fi
"$WORK/native" "$CORPUS" "$PROOF_CORPUS" > "$WORK/native.out" 2> "$WORK/native.err"
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
  MDK_ARGS="$CORPUS $PROOF_CORPUS" node "$ROOT/test/wasm/run.js" "$WORK/driver.wasm" > "$WORK/wasm-raw.out" 2> "$WORK/wasm.err"
  require_empty "$WORK/wasm.err" wasm
  # A Unit main prints nothing on Wasm (the trailing `0` this once expected was
  # #2424): the runner's stdout is the program's output, byte for byte.
  cp "$WORK/wasm-raw.out" "$WORK/wasm.out"
  cmp "$WORK/native.out" "$WORK/wasm.out" || fail 'native and Wasm normalized output differ'
  ENGINE_GRADE='eval == native == Wasm'
fi

if ! MEDAKA_ROOT="$ROOT" MEDAKA_STRICT=1 "$MEDAKA" build "$PERF_DRIVER" -o "$WORK/perf-native" > "$WORK/perf-build.log" 2>&1; then
  cat "$WORK/perf-build.log" >&2
  fail 'MST scaling driver build failed'
fi

measure_mst() {
  label=$1
  size=$2
  start=$(perl -MTime::HiRes=time -e 'printf "%.6f", time')
  "$WORK/perf-native" mst "$size" > "$WORK/$label.out"
  finish=$(perl -MTime::HiRes=time -e 'printf "%.6f", time')
  grep -F -q "MST $size UNREACHABLE" "$WORK/$label.out" || fail "MST scaling route failed at $size rows"
  awk -v start="$start" -v finish="$finish" 'BEGIN { printf "%.6f", finish - start }'
}

MST_SMALL=$(measure_mst mst-1000 1000)
MST_LARGE=$(measure_mst mst-2000 2000)
if ! awk -v small="$MST_SMALL" -v large="$MST_LARGE" 'BEGIN {
  ratio = large / small
  exit ! (large <= 3.5 && ratio <= 3.2)
}'; then
  fail "MST scaling exceeded bounds: 1000=$MST_SMALL s 2000=$MST_LARGE s"
fi
echo "MST scaling: 1000=$MST_SMALL s 2000=$MST_LARGE s"

# The assertion above times `mstValidateBlocks` REJECTING a hostile
# UNREACHABLE corpus — never the write path (`mstInsert`), the export path
# (`repoExportGraph`), or the startup path (`repoFromBlocks`/`rehydrate`).
# All three quadratics this sprint fixed lived under this one green gate;
# these three routes exercise those paths directly so a regression in any of
# them reds here instead of hiding behind an unrelated assertion again.

measure_mst_insert() {
  label=$1
  size=$2
  start=$(perl -MTime::HiRes=time -e 'printf "%.6f", time')
  "$WORK/perf-native" mst-insert "$size" > "$WORK/$label.out"
  finish=$(perl -MTime::HiRes=time -e 'printf "%.6f", time')
  grep -F -q "MSTINSERT $size $size" "$WORK/$label.out" || fail "MST insert route failed at $size rows"
  awk -v start="$start" -v finish="$finish" 'BEGIN { printf "%.6f", finish - start }'
}

MSTINSERT_SMALL=$(measure_mst_insert mst-insert-1000 1000)
MSTINSERT_LARGE=$(measure_mst_insert mst-insert-2000 2000)
if ! awk -v small="$MSTINSERT_SMALL" -v large="$MSTINSERT_LARGE" 'BEGIN {
  ratio = large / small
  exit ! (large <= 3.0 && ratio <= 3.2)
}'; then
  fail "MST insert scaling exceeded bounds: 1000=$MSTINSERT_SMALL s 2000=$MSTINSERT_LARGE s"
fi
echo "MST insert scaling: 1000=$MSTINSERT_SMALL s 2000=$MSTINSERT_LARGE s"

measure_export() {
  label=$1
  size=$2
  start=$(perl -MTime::HiRes=time -e 'printf "%.6f", time')
  "$WORK/perf-native" export "$size" > "$WORK/$label.out"
  finish=$(perl -MTime::HiRes=time -e 'printf "%.6f", time')
  grep -F -q "EXPORT $size " "$WORK/$label.out" || fail "export route failed at $size rows"
  awk -v start="$start" -v finish="$finish" 'BEGIN { printf "%.6f", finish - start }'
}

EXPORT_SMALL=$(measure_export export-1000 1000)
EXPORT_LARGE=$(measure_export export-2000 2000)
if ! awk -v small="$EXPORT_SMALL" -v large="$EXPORT_LARGE" 'BEGIN {
  ratio = large / small
  exit ! (large <= 1.5 && ratio <= 2.5)
}'; then
  fail "export scaling exceeded bounds: 1000=$EXPORT_SMALL s 2000=$EXPORT_LARGE s"
fi
echo "export scaling: 1000=$EXPORT_SMALL s 2000=$EXPORT_LARGE s"

measure_rehydrate() {
  label=$1
  size=$2
  start=$(perl -MTime::HiRes=time -e 'printf "%.6f", time')
  "$WORK/perf-native" rehydrate "$size" > "$WORK/$label.out"
  finish=$(perl -MTime::HiRes=time -e 'printf "%.6f", time')
  grep -F -q "REHYDRATE $size OK" "$WORK/$label.out" || fail "rehydrate route failed at $size rows"
  awk -v start="$start" -v finish="$finish" 'BEGIN { printf "%.6f", finish - start }'
}

REHYDRATE_SMALL=$(measure_rehydrate rehydrate-1000 1000)
REHYDRATE_LARGE=$(measure_rehydrate rehydrate-2000 2000)
if ! awk -v small="$REHYDRATE_SMALL" -v large="$REHYDRATE_LARGE" 'BEGIN {
  ratio = large / small
  exit ! (large <= 1.5 && ratio <= 2.5)
}'; then
  fail "rehydrate scaling exceeded bounds: 1000=$REHYDRATE_SMALL s 2000=$REHYDRATE_LARGE s"
fi
echo "rehydrate scaling: 1000=$REHYDRATE_SMALL s 2000=$REHYDRATE_LARGE s"

echo "PASS: MST — 11 official-reference cases; 17 covering-proof rows (13 narrower than the whole tree); 14 hostile routes; 3 lexical controls; $ENGINE_GRADE"
