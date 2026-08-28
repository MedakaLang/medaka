#!/bin/sh
# P1-C pure verified blockstore and strict atproto-profile CARv1 on eval/native.
set -eu

ROOT=${MEDAKA_ROOT:?set MEDAKA_ROOT to the repo root}
MEDAKA=${MEDAKA:-"$ROOT/medaka"}
DRIVER="$ROOT/pds/test/car_vectors_main.mdk"
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

echo 'PASS: CAR — 1 official-atproto fixture; 4 success routes; 12 hostile routes; eval == native'
