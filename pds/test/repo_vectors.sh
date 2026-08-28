#!/bin/sh
# P1-D fixed official repository transcript on eval and native.
set -eu

ROOT=${MEDAKA_ROOT:?set MEDAKA_ROOT to the repo root}
MEDAKA=${MEDAKA:-"$ROOT/medaka"}
DRIVER="$ROOT/pds/test/repo_vectors_main.mdk"
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

if ! MEDAKA_ROOT="$ROOT" MEDAKA_STRICT=1 "$MEDAKA" run "$DRIVER" "$CORPUS" > "$WORK/eval.out" 2> "$WORK/eval.err"; then
  cat "$WORK/eval.out" >&2
  cat "$WORK/eval.err" >&2
  fail 'eval driver failed'
fi
require_empty "$WORK/eval.err" eval

grep -F -q 'external: 15/15 official-atproto transcript checks' "$WORK/eval.out" || fail 'eval transcript count is incomplete'
grep -F -q 'hostile: 19/19 rejected on named routes' "$WORK/eval.out" || fail 'eval hostile count is incomplete'
[ "$(tail -1 "$WORK/eval.out")" = 'TOTAL: PASS' ] || fail 'eval did not end in TOTAL: PASS'

for action in CREATE UPDATE DELETE; do
  grep -F -q "OP $action PASS" "$WORK/eval.out" || fail "eval missed operation $action"
done
grep -F -q 'CAR PASS order=' "$WORK/eval.out" || fail 'eval missed exact CAR bytes/order'

for label in tid-alphabet tid-length tid-high-bit tid-range tid-nonmonotonic \
  duplicate-create missing-update missing-delete invalid-did invalid-path \
  invalid-record bad-key bad-sign required-prev commit-version commit-data \
  commit-rev missing-graph tampered-graph
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

echo 'PASS: repo — official TIDs/records/MST/commits/signatures/CAR; 19 hostile routes; eval == native'
