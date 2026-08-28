#!/bin/sh
# P1-B deterministic atproto MST: official-reference roots/node bytes and
# strict hostile validation on eval and native.
set -eu

ROOT=${MEDAKA_ROOT:?set MEDAKA_ROOT to the repo root}
MEDAKA=${MEDAKA:-"$ROOT/medaka"}
DRIVER="$ROOT/pds/test/mst_vectors_main.mdk"
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

if ! MEDAKA_ROOT="$ROOT" MEDAKA_STRICT=1 "$MEDAKA" run "$DRIVER" "$CORPUS" > "$WORK/eval.out" 2> "$WORK/eval.err"; then
  cat "$WORK/eval.out" >&2
  cat "$WORK/eval.err" >&2
  fail 'eval driver failed'
fi
require_empty "$WORK/eval.err" eval
grep -F -q 'external: 11/11 official-reference cases' "$WORK/eval.out" || fail 'eval did not grade all external cases'
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

for label in left-neighbor between-neighbor right-neighbor
do
  grep -F -q "MST CONTROL $label PASS" "$WORK/eval.out" || fail "eval missed lexical control $label"
done

if ! MEDAKA_ROOT="$ROOT" MEDAKA_STRICT=1 "$MEDAKA" build "$DRIVER" -o "$WORK/native" > "$WORK/native-build.log" 2>&1; then
  cat "$WORK/native-build.log" >&2
  fail 'native driver build failed'
fi
"$WORK/native" "$CORPUS" > "$WORK/native.out" 2> "$WORK/native.err"
require_empty "$WORK/native.err" native
cmp "$WORK/eval.out" "$WORK/native.out" || fail 'eval and native normalized output differ'

echo 'PASS: MST — 11 official-reference cases; 14 hostile routes; 3 lexical controls; eval == native'
