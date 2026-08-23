#!/bin/sh
set -eu
ROOT=${MEDAKA_ROOT:?set MEDAKA_ROOT}
MEDAKA=${MEDAKA:-"$ROOT/medaka"}
DRIVER="$ROOT/pds/test/secp256k1_point_vectors_main.mdk"
CORPUS="$ROOT/pds/test/vectors/point_public_key_corpus.txt"
W=$(mktemp -d "${TMPDIR:-/tmp}/pds-point-gate.XXXXXX")
trap 'rm -rf "$W"' EXIT HUP INT TERM
awk 'NR == 17 || NR == 19 || NR == 25' "$CORPUS" > "$W/sample.txt"
MEDAKA_STRICT=1 "$MEDAKA" run "$DRIVER" "$W/sample.txt" > "$W/eval.out" 2>&1
[ "$(tail -1 "$W/eval.out")" = 'TOTAL: PASS' ] || { cat "$W/eval.out"; exit 1; }
MEDAKA_STRICT=1 "$MEDAKA" build "$DRIVER" -o "$W/driver" > "$W/build.out" 2>&1 || { cat "$W/build.out"; exit 1; }
"$W/driver" "$CORPUS" > "$W/native.out" 2>&1
[ "$(tail -1 "$W/native.out")" = 'TOTAL: PASS' ] || { cat "$W/native.out"; exit 1; }
grep -q '^counted: 25/25 rows ok$' "$W/native.out" || { cat "$W/native.out"; exit 1; }
echo 'PASS: 25 secp256k1 point rows; bounded eval sample and native full corpus'
