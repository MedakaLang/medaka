#!/bin/sh
# P4-B lexicon-JSON<->DAG-CBOR round-trip, graded against the official
# @atproto/lex-cbor + @atproto/lex-json reference corpus
# (pds/test/vectors/lexjson_reference_corpus.txt).
set -eu

ROOT=${MEDAKA_ROOT:?set MEDAKA_ROOT to the repo root}
MEDAKA=${MEDAKA:-"$ROOT/medaka"}
DRIVER="$ROOT/pds/test/lexjson_vectors_main.mdk"
WORK=$(mktemp -d "${TMPDIR:-/tmp}/pds-lexjson.XXXXXX")
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

sh "$ROOT/pds/test/vector_provenance.sh" --files-for P4-B-IPLD-JSON > "$WORK/vector-files"
[ "$(wc -l < "$WORK/vector-files" | tr -d ' ')" = 1 ] || fail 'expected exactly one ledger-owned P4-B-IPLD-JSON corpus'
CORPUS_REL=$(sed -n '1p' "$WORK/vector-files")
CORPUS="$ROOT/$CORPUS_REL"

if ! MEDAKA_ROOT="$ROOT" MEDAKA_STRICT=1 "$MEDAKA" build "$DRIVER" -o "$WORK/native" > "$WORK/build.log" 2>&1; then
  cat "$WORK/build.log" >&2
  fail 'lexjson driver build failed'
fi

if ! "$WORK/native" "$CORPUS" > "$WORK/native.out" 2> "$WORK/native.err"; then
  cat "$WORK/native.out" >&2
  cat "$WORK/native.err" >&2
  fail 'lexjson driver run failed'
fi
require_empty "$WORK/native.err" native

LINE=$(grep -E '^lexjson: [0-9]+/[0-9]+ round-trip \(both directions\)$' "$WORK/native.out") \
  || fail 'missing or malformed round-trip counted line'
echo "$LINE" | awk -F'[ /]+' '{
  if ($2 == 0) { print "FAIL: round-trip line has a 0-denominator count"; exit 1 }
  if ($2 != $3) { print "FAIL: round-trip line is not a full pass"; exit 1 }
}' || exit 1

grep -F -q 'malformed: 3/3 rejected' "$WORK/native.out" || fail 'malformed-input rejection count incomplete'

[ "$(tail -1 "$WORK/native.out")" = 'TOTAL: PASS' ] || {
  cat "$WORK/native.out" >&2
  fail 'lexjson driver did not end in TOTAL: PASS'
}

cat "$WORK/native.out"
echo "PASS: lexjson — 1 official @atproto/lex-cbor+lex-json reference corpus round-tripped both directions; 3 malformed-input cases rejected"
