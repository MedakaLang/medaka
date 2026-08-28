#!/bin/sh
# P1-D representative eval plus the complete official transcript on native/Wasm.
set -eu

ROOT=${MEDAKA_ROOT:?set MEDAKA_ROOT to the repo root}
MEDAKA=${MEDAKA:-"$ROOT/medaka"}
DRIVER="$ROOT/pds/test/repo_vectors_main.mdk"
WASM_EMITTER=${MEDAKA_WASM_EMITTER:-"$ROOT/test/bin/wasm_emit_modules_main"}
WORK=$(mktemp -d "${TMPDIR:-/tmp}/pds-repo.XXXXXX")
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
sh "$ROOT/pds/test/vector_provenance.sh" --files-for P1-D-REPO > "$WORK/vector-files"
[ "$(wc -l < "$WORK/vector-files" | tr -d ' ')" = 1 ] || fail 'expected exactly one ledger-owned P1-D corpus'
CORPUS_REL=$(sed -n '1p' "$WORK/vector-files")
CORPUS="$ROOT/$CORPUS_REL"

if ! MEDAKA_ROOT="$ROOT" MEDAKA_STRICT=1 "$MEDAKA" run "$DRIVER" "$CORPUS" --representative > "$WORK/eval.out" 2> "$WORK/eval.err"; then
  cat "$WORK/eval.out" >&2
  cat "$WORK/eval.err" >&2
  fail 'eval driver failed'
fi
require_empty "$WORK/eval.err" eval

grep -F -q 'representative-external: 6/6 official-atproto initialization/create/CAR checks' "$WORK/eval.out" || fail 'eval representative external count is incomplete'
grep -F -q 'focused-rejected: 27/27 named routes' "$WORK/eval.out" || fail 'eval F1 rejection count is incomplete'
grep -F -q 'focused-controls: 8/8 valid routes' "$WORK/eval.out" || fail 'eval F1 boundary controls are incomplete'
grep -F -q 'OP CREATE PASS' "$WORK/eval.out" || fail 'eval missed the representative CREATE'
grep -F -q 'CREATE CAR PASS order=' "$WORK/eval.out" || fail 'eval missed representative exact CAR bytes/order'
[ "$(tail -1 "$WORK/eval.out")" = 'REPRESENTATIVE: PASS' ] || fail 'eval did not end in REPRESENTATIVE: PASS'

if ! MEDAKA_ROOT="$ROOT" MEDAKA_STRICT=1 "$MEDAKA" build "$DRIVER" -o "$WORK/native" > "$WORK/native-build.log" 2>&1; then
  cat "$WORK/native-build.log" >&2
  fail 'native driver build failed'
fi
"$WORK/native" "$CORPUS" > "$WORK/native.out" 2> "$WORK/native.err"
require_empty "$WORK/native.err" native

grep -F -q 'external: 15/15 official-atproto transcript checks' "$WORK/native.out" || fail 'native transcript count is incomplete'
grep -F -q 'hostile: 19/19 rejected on named routes' "$WORK/native.out" || fail 'native hostile count is incomplete'
[ "$(tail -1 "$WORK/native.out")" = 'TOTAL: PASS' ] || fail 'native did not end in TOTAL: PASS'

if [ ! -x "$WASM_EMITTER" ] || ! command -v node >/dev/null 2>&1 || ! command -v wasm-tools >/dev/null 2>&1; then
  [ "${MEDAKA_REQUIRE_WASM:-0}" != 1 ] || fail 'Wasm is required but emitter/node/wasm-tools is unavailable'
  echo 'PASS: repo — representative official eval; full official transcript native; Wasm unavailable'
  exit 0
fi

if ! MEDAKA_ROOT="$ROOT" MEDAKA_WASM_EMITTER="$WASM_EMITTER" MEDAKA_STRICT=1 "$MEDAKA" build --target wasm "$DRIVER" -o "$WORK/driver.wasm" > "$WORK/wasm-build.log" 2>&1; then
  cat "$WORK/wasm-build.log" >&2
  fail 'Wasm driver build failed'
fi
MDK_ARGS="$CORPUS" node "$ROOT/test/wasm/run.js" "$WORK/driver.wasm" > "$WORK/wasm-raw.out" 2> "$WORK/wasm.err"
require_empty "$WORK/wasm.err" wasm
if [ "$(tail -1 "$WORK/wasm-raw.out")" = 0 ]; then
  sed '$d' "$WORK/wasm-raw.out" > "$WORK/wasm.out"
else
  cp "$WORK/wasm-raw.out" "$WORK/wasm.out"
fi
cmp "$WORK/native.out" "$WORK/wasm.out" || fail 'native and Wasm normalized output differ'

echo 'PASS: repo — representative official eval; full official TIDs/records/MST/commits/signatures/CAR on native == Wasm; 19 hostile routes'
