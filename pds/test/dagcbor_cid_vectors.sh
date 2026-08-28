#!/bin/sh
# Canonical DAG-CBOR/DRISL + CID foundation: external vectors, strict hostile
# rejection routes, and eval/native/Wasm normalized-output parity.
set -eu

ROOT=${MEDAKA_ROOT:?set MEDAKA_ROOT to the repo root}
MEDAKA=${MEDAKA:-"$ROOT/medaka"}
DRIVER="$ROOT/pds/test/dagcbor_cid_vectors_main.mdk"
WASM_EMITTER=${MEDAKA_WASM_EMITTER:-"$ROOT/test/bin/wasm_emit_modules_main"}
WORK=$(mktemp -d "${TMPDIR:-/tmp}/pds-dagcbor-cid.XXXXXX")
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

sh "$ROOT/pds/test/vector_provenance.sh" --files-for P1-A-CBOR-CID > "$WORK/vector-files"
[ "$(wc -l < "$WORK/vector-files" | tr -d ' ')" = 1 ] || fail 'expected exactly one ledger-owned P1-A corpus'
CORPUS_REL=$(sed -n '1p' "$WORK/vector-files")
CORPUS="$ROOT/$CORPUS_REL"

MEDAKA_ROOT="$ROOT" MEDAKA_STRICT=1 "$MEDAKA" run "$DRIVER" "$CORPUS" > "$WORK/eval.out" 2> "$WORK/eval.err"
require_empty "$WORK/eval.err" eval
grep -F -q 'external: 17/17 IPLD rows' "$WORK/eval.out" || fail 'eval did not grade all external rows'
grep -F -q 'malformed: 24/24 rejected on named routes' "$WORK/eval.out" || fail 'eval malformed route count is incomplete'
[ "$(tail -1 "$WORK/eval.out")" = 'TOTAL: PASS' ] || fail 'eval did not end in TOTAL: PASS'

for label in \
  shortest-integer-positive shortest-integer-negative shortest-length-bytes \
  shortest-length-text shortest-length-array shortest-length-map map-ordering \
  map-duplicate map-non-string-key tag42-only tag42-shortest tag42-identity \
  tag42-cid-codec-route cid-codec cid-hash cid-length base32-padding \
  base32-case base32-alphabet truncation trailing-bytes indefinite-length \
  float invalid-utf8
do
  grep -F -q "MALFORMED $label PASS route=" "$WORK/eval.out" || fail "eval missed exceptional route $label"
done

MEDAKA_ROOT="$ROOT" MEDAKA_STRICT=1 "$MEDAKA" build "$DRIVER" -o "$WORK/native" > "$WORK/native-build.log" 2>&1
"$WORK/native" "$CORPUS" > "$WORK/native.out" 2> "$WORK/native.err"
require_empty "$WORK/native.err" native
cmp "$WORK/eval.out" "$WORK/native.out" || fail 'eval and native normalized output differ'

if [ ! -x "$WASM_EMITTER" ] || ! command -v node >/dev/null 2>&1 || ! command -v wasm-tools >/dev/null 2>&1; then
  [ "${MEDAKA_REQUIRE_WASM:-0}" != 1 ] || fail 'Wasm is required but emitter/node/wasm-tools is unavailable'
  echo 'PASS: DAG-CBOR/CID — 17 external rows; 24 hostile routes; eval == native; Wasm unavailable'
  exit 0
fi

MEDAKA_ROOT="$ROOT" MEDAKA_WASM_EMITTER="$WASM_EMITTER" MEDAKA_STRICT=1 "$MEDAKA" build --target wasm "$DRIVER" -o "$WORK/driver.wasm" > "$WORK/wasm-build.log" 2>&1
MDK_ARGS="$CORPUS" node "$ROOT/test/wasm/run.js" "$WORK/driver.wasm" > "$WORK/wasm-raw.out" 2> "$WORK/wasm.err"
require_empty "$WORK/wasm.err" wasm
[ "$(tail -1 "$WORK/wasm-raw.out")" = 0 ] || fail 'Wasm runner result was not zero'
sed '$d' "$WORK/wasm-raw.out" > "$WORK/wasm.out"
cmp "$WORK/native.out" "$WORK/wasm.out" || fail 'native and Wasm normalized output differ'

echo 'PASS: DAG-CBOR/CID — 17 external rows; 24 hostile routes; eval == native == Wasm'
